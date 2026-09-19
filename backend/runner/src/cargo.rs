//! The `cargo` harness (SPEC §5.1, §5.2): a generated minimal `Cargo.toml`,
//! `cargo test --offline`, and the suite loop over what libtest reported.
//!
//! It is **two phases on purpose**, and the reason is SPEC §5.3. A plain
//! `cargo test` compiles and runs in one process, so either the compiler runs
//! under a 1 GiB address-space cap and a stripped `PATH` — which is not a
//! thing a toolchain survives — or the player's tests run with the toolchain's
//! environment and no limits at all. Neither is acceptable, so:
//!
//! * `cargo test --offline --no-run --message-format=json` compiles, under
//!   `compile_timeout_ms`, with a working environment and the scratch pointed
//!   into `build/rust/` (§5.1).
//! * the test binaries it names are then executed exactly the way `harness.rs`
//!   executes a stdio submission: own process group, stripped environment,
//!   rlimits, output cap enforced while draining, SIGTERM then SIGKILL.
//!
//! `--message-format=json` is also what keeps SPEC §7.1 working: cargo wraps
//! each `rustc` diagnostic in `{"reason":"compiler-message","message":{…}}`,
//! and unwrapping it gives back exactly the JSON-per-line stream
//! `mistakes::classify_rust_json` already reads.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use crate::proc::{self, Limits};
use crate::rust::{rendered_of, CompileLines};
use crate::suite::{self, Status, SuiteRun, TestOutcome};
use crate::{Event, Report, Submission, Verdict};

/// Where the player's code lives, and where the quest's own tests live if it
/// ships any. Both are relative, because that is how `rustc` spells them in a
/// diagnostic when it is run from the package root.
const PLAYER_FILE: &str = "src/lib.rs";
const QUEST_FILE: &str = "tests/quest.rs";

pub fn run(sub: &Submission) -> Report {
    match compile_and_judge(sub) {
        Ok(report) => report,
        Err(e) => Report::internal(format!("runner: {e}")),
    }
}

fn compile_and_judge(sub: &Submission) -> std::io::Result<Report> {
    let root = &sub.workdir;
    std::fs::create_dir_all(root.join("src"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700));
    }
    std::fs::write(root.join("Cargo.toml"), manifest(sub.attempt_id))?;
    std::fs::write(root.join(PLAYER_FILE), sub.source)?;
    if let Some(tests) = &sub.spec.test_source {
        std::fs::create_dir_all(root.join("tests"))?;
        std::fs::write(root.join(QUEST_FILE), tests)?;
    }

    (sub.events)(Event::Stage("compiling"));
    // cargo's stdout is the JSON stream and its stderr is prose ("Compiling
    // quest v0.0.0", "error: could not compile …"). The player gets the prose
    // as it comes and, out of the JSON, each diagnostic's `rendered` text —
    // never the object around it, and nothing at all for the artifact and
    // build-finished records. The JSON itself is kept: it is the report's
    // `compiler_stderr`, which is what classification reads.
    let lines = CompileLines::new(sub.events.clone(), cargo_line);
    let compile_logs = lines.sink();

    let mut cargo = Command::new("cargo");
    cargo
        .current_dir(root)
        .arg("test")
        .arg("--offline")
        .arg("--no-run")
        .arg("--message-format=json");
    toolchain_env(&mut cargo, sub);

    let compile = proc::run(
        cargo,
        b"",
        &Limits {
            timeout: Duration::from_millis(sub.spec.compile_timeout_ms),
            max_stdout: 8 << 20,
            max_stderr: 4 << 20,
            apply_rlimits: false,
            address_space: false,
        },
        // The labels the sink tells the pipes apart by: stdout is the JSON,
        // stderr is prose.
        "cargo-json",
        "cargo-stderr",
        compile_logs,
    );
    lines.flush();
    let compile = compile?;
    let compile_ms = compile.elapsed_ms as i64;
    let cargo_stdout = String::from_utf8_lossy(&compile.stdout).to_string();
    let cargo_stderr = String::from_utf8_lossy(&compile.stderr).to_string();

    if compile.timed_out {
        return Ok(suite::no_binary(
            sub,
            Verdict::Timeout,
            compile_ms,
            player_diagnostics(&cargo_stdout),
            "the compiler ran out of time".into(),
            None,
        ));
    }

    let parsed = parse_cargo_json(&cargo_stdout);
    let compiler_stderr = parsed.player_json.join("\n");

    if compile.exit_code != Some(0) || parsed.binaries.is_empty() {
        return Ok(compile_failure(
            sub,
            compile_ms,
            compiler_stderr,
            &parsed,
            &cargo_stderr,
            compile.exit_code.map(i64::from),
        ));
    }

    (sub.events)(Event::Stage("running"));
    let run = execute(sub, &parsed.binaries)?;
    Ok(suite::assemble(sub, compile_ms, compiler_stderr, run))
}

/// SPEC §12 in miniature: the smallest package that compiles one file and its
/// tests.
///
/// Two things here are load-bearing.
///
/// **`[workspace]`** is not decoration. Without it cargo walks *up* from the
/// build directory looking for a workspace root, and one stray `Cargo.toml`
/// above `~/.causewaybayhacker/` turns every quest into "current package
/// believes it's in a workspace when it's not".
///
/// **The package name carries the attempt id**, while the *library* stays
/// `quest`. `CARGO_TARGET_DIR` is shared across attempts by §5.1's design, and
/// cargo's artifact filenames hash the package name — so with a fixed name,
/// two attempts building at once write the same `target/debug/deps/quest-…`
/// and one player can be judged against the other's code. That is not
/// theoretical: it is what this harness's own test suite did the first time it
/// shared a target directory, and two users submitting at the same moment is
/// an ordinary Tuesday for a server. The quest's tests still say
/// `use quest::add;`, because the lib target's name never changes.
fn manifest(attempt_id: &str) -> String {
    format!(
        "\
[package]
name = \"quest-{}\"
version = \"0.0.0\"
edition = \"2021\"
publish = false

[lib]
name = \"quest\"
path = \"src/lib.rs\"
# A doctest is a third way to run code and a fourth way to fail, and no quest
# is judged on one.
doctest = false

# Not a member of anything. See above.
[workspace]
",
        slug(attempt_id)
    )
}

/// Cargo package names take letters, digits, `-` and `_`. An attempt id is
/// already `att_…`, but nothing here should depend on that.
fn slug(attempt_id: &str) -> String {
    let cleaned: String = attempt_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    if cleaned.is_empty() {
        "attempt".to_string()
    } else {
        cleaned
    }
}

/// The toolchain allowlist (`harness::toolchain_base`: enough for the rustup
/// shim to pick a toolchain, nothing of the server's own) with every path
/// cargo writes redirected, so the promise in SPEC §1 holds — nothing
/// outside the home.
fn toolchain_env(command: &mut Command, sub: &Submission) {
    crate::harness::toolchain_base(command, &sub.workdir);
    command
        .env("CARGO_HOME", sub.cache_root.join("cargo-home"))
        .env("CARGO_TARGET_DIR", sub.cache_root.join("target"))
        .env("CARGO_TERM_COLOR", "never")
        // Offline is already on the command line; this makes it true for any
        // child cargo spawns as well.
        .env("CARGO_NET_OFFLINE", "true");
}

#[derive(Debug, Default)]
struct CargoOutput {
    /// `rustc` diagnostics about the player's own file, one JSON object per
    /// line — the exact shape `mistakes::classify_rust_json` reads.
    player_json: Vec<String>,
    /// Errors whose span is in the quest's test file, already reduced to their
    /// message. They are **never** forwarded verbatim: the rendered form
    /// quotes the source, and the quest's tests are not the player's to read.
    quest_errors: Vec<QuestError>,
    binaries: Vec<PathBuf>,
}

#[derive(Debug, Clone)]
struct QuestError {
    code: Option<String>,
    message: String,
}

impl QuestError {
    /// Does this error say "your code is not what the tests called for", or
    /// does it say "the tests are broken"?
    ///
    /// The distinction decides whether the player is told they failed or the
    /// quest is. Getting it backwards in the generous direction shows a player
    /// `internal_error` for a function they forgot to write; getting it
    /// backwards in the other direction blames them for a typo in a file they
    /// have never seen. The list is the codes that can only arise from the
    /// test file *reaching for the player's API*.
    fn is_about_the_players_api(&self) -> bool {
        const PLAYER_SHAPED: &[&str] = &[
            "E0425", // cannot find value/function in this scope
            "E0433", // failed to resolve: use of undeclared crate or module
            "E0412", // cannot find type
            "E0432", // unresolved import
            "E0599", // no method named …
            "E0609", // no field named …
            "E0308", // mismatched types
            "E0061", // wrong number of arguments
            "E0107", // wrong number of generic arguments
            "E0603", // private
            "E0624", // associated function is private
            "E0277", // trait bound: the player's type does not implement it
        ];
        match self.code.as_deref() {
            Some(code) => PLAYER_SHAPED.contains(&code),
            None => false,
        }
    }
}

fn parse_cargo_json(stdout: &str) -> CargoOutput {
    let mut out = CargoOutput::default();
    for line in stdout.lines() {
        let line = line.trim();
        if !line.starts_with('{') {
            continue;
        }
        let value: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        match value.get("reason").and_then(|v| v.as_str()) {
            Some("compiler-message") => {
                let message = match value.get("message") {
                    Some(m) => m,
                    None => continue,
                };
                if owner(message) == Owner::Quest {
                    if message.get("level").and_then(|v| v.as_str()) == Some("error") {
                        out.quest_errors.push(QuestError {
                            code: message
                                .get("code")
                                .and_then(|c| c.get("code"))
                                .and_then(|v| v.as_str())
                                .map(str::to_string),
                            message: message
                                .get("message")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string(),
                        });
                    }
                    continue;
                }
                out.player_json.push(message.to_string());
            }
            Some("compiler-artifact") => {
                let is_test = value
                    .get("profile")
                    .and_then(|p| p.get("test"))
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                if let (true, Some(exe)) =
                    (is_test, value.get("executable").and_then(|v| v.as_str()))
                {
                    out.binaries.push(PathBuf::from(exe));
                }
            }
            // `build-finished`, `build-script-executed`, and whatever cargo
            // grows next: not dropped on the floor by accident, just not
            // something this harness has a use for.
            _ => {}
        }
    }
    out
}

#[derive(PartialEq, Eq)]
enum Owner {
    Player,
    Quest,
}

/// Whose file is this diagnostic about? A diagnostic with no span at all is
/// the player's: `rustc`'s spanless errors are things like "main function not
/// found", and attributing those to the quest would hide them.
fn owner(message: &serde_json::Value) -> Owner {
    let spans = match message.get("spans").and_then(|s| s.as_array()) {
        Some(s) if !s.is_empty() => s,
        _ => return Owner::Player,
    };
    let primary = spans
        .iter()
        .find(|s| {
            s.get("is_primary")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
        })
        .or_else(|| spans.first());
    let file = primary
        .and_then(|s| s.get("file_name"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if file.replace('\\', "/").ends_with(QUEST_FILE) {
        Owner::Quest
    } else {
        Owner::Player
    }
}

/// Only the player's diagnostics, for the paths that need them before the full
/// parse has happened (a compile timeout).
fn player_diagnostics(stdout: &str) -> String {
    parse_cargo_json(stdout).player_json.join("\n")
}

fn compile_failure(
    sub: &Submission,
    compile_ms: i64,
    compiler_stderr: String,
    parsed: &CargoOutput,
    cargo_stderr: &str,
    exit_code: Option<i64>,
) -> Report {
    if !parsed.player_json.is_empty() && has_error(&parsed.player_json) {
        // The ordinary case, and the only one that records a mistake: the
        // player's own file did not compile.
        return suite::no_binary(
            sub,
            Verdict::CompileError,
            compile_ms,
            compiler_stderr,
            String::new(),
            exit_code,
        );
    }
    if !parsed.quest_errors.is_empty() {
        let messages: Vec<String> = parsed
            .quest_errors
            .iter()
            .map(|e| e.message.clone())
            .collect();
        return if parsed
            .quest_errors
            .iter()
            .all(QuestError::is_about_the_players_api)
        {
            // The tests compile fine against a correct answer; they do not
            // compile against this one. That is a failed submission, and the
            // player is told what the tests could not find — without the
            // rendered snippet, which would quote the hidden test file.
            suite::no_binary(
                sub,
                Verdict::CompileError,
                compile_ms,
                // Deliberately empty: a diagnostic whose span is in a file the
                // player cannot see would put a wrong line number in the
                // mistakes table, and SPEC §7's drills are built from it.
                String::new(),
                suite::tests_do_not_fit(&messages),
                exit_code,
            )
        } else {
            suite::no_binary(
                sub,
                Verdict::InternalError,
                compile_ms,
                String::new(),
                suite::quest_is_broken("tests/quest.rs", &messages.join("; ")),
                exit_code,
            )
        };
    }
    // cargo failed and said nothing a compiler said — a bad manifest, a
    // missing toolchain, an offline miss. Not the player's doing.
    suite::no_binary(
        sub,
        Verdict::InternalError,
        compile_ms,
        compiler_stderr,
        format!(
            "cargo could not build this quest:\n{}",
            without_home_paths(cargo_stderr.trim(), sub)
        ),
        exit_code,
    )
}

/// Cargo names files by absolute path, and every path it could name here is
/// under the home — the attempt's workdir or the shared cache. The player is
/// owed the message, not the location of the home on this disk.
fn without_home_paths(text: &str, sub: &Submission) -> String {
    let mut out = text.to_string();
    for (root, label) in [(&sub.workdir, "<attempt>"), (&sub.cache_root, "<cache>")] {
        let root = root.to_string_lossy();
        if !root.is_empty() {
            out = out.replace(root.as_ref(), label);
        }
    }
    out
}

fn has_error(json_lines: &[String]) -> bool {
    json_lines.iter().any(|line| {
        serde_json::from_str::<serde_json::Value>(line)
            .ok()
            .and_then(|v| {
                v.get("level")
                    .and_then(|l| l.as_str())
                    .map(|l| l == "error")
            })
            .unwrap_or(false)
    })
}

/// Run every test binary cargo built, under §5.3's limits.
///
/// There can be two: the unit tests inside `src/lib.rs` and, when the quest
/// ships its own, the integration test in `tests/quest.rs`. They are one suite
/// as far as the player is concerned.
fn execute(sub: &Submission, binaries: &[PathBuf]) -> std::io::Result<SuiteRun> {
    let mut run = SuiteRun::default();
    let budget = Duration::from_millis(sub.spec.timeout_ms);
    let started = std::time::Instant::now();

    for binary in binaries {
        let events = sub.events.clone();
        let logs: proc::LogSink = Arc::new(move |stream, chunk| {
            events(Event::Log {
                stream: stream.to_string(),
                chunk: chunk.to_string(),
            });
        });
        let mut command = Command::new(binary);
        command.current_dir(&sub.workdir);
        crate::harness::strip_env(&mut command, &sub.workdir);
        // One thread, so the order is the order the player wrote and the last
        // line of a killed suite names what hung. libtest has no timeout of
        // its own — the wall clock in `proc` is the only one.
        command.arg("--test-threads=1");
        if let Some(names) = suite::only(sub) {
            // A RUN of a quest that ships its own tests: only the declared
            // ones may execute (PROTOCOL §4.9b). libtest filters by substring
            // unless told otherwise, and a substring filter would drag in
            // `adds_zero` on its way to `adds` — so the names are resolved
            // against the binary's own listing first and passed `--exact`.
            command.arg("--exact");
            let listed = list_tests(sub, binary);
            let mut matched = 0usize;
            for name in &names {
                for actual in listed.iter().filter(|a| suite::same_test(name, a)) {
                    command.arg(actual);
                    matched += 1;
                }
            }
            if matched == 0 {
                // `--exact` with no filter at all would run everything. Name
                // something that cannot exist instead.
                command.arg("::no-such-test::");
            }
        }

        let remaining = budget.saturating_sub(started.elapsed());
        let outcome = proc::run(
            command,
            b"",
            &Limits {
                timeout: remaining.max(Duration::from_millis(1)),
                max_stdout: sub.spec.max_stdout_bytes,
                max_stderr: 256 * 1024,
                apply_rlimits: true,
                address_space: true,
            },
            "stdout",
            "stderr",
            logs,
        )?;

        let stdout = String::from_utf8_lossy(&outcome.stdout).to_string();
        let (mut outcomes, last_started) = parse_libtest(&stdout);
        run.outcomes.append(&mut outcomes);
        run.stdout.push_str(&stdout);
        run.stderr
            .push_str(&String::from_utf8_lossy(&outcome.stderr));
        run.stdout_bytes += outcome.stdout_produced as i64;
        run.elapsed_ms += outcome.elapsed_ms as i64;
        if last_started.is_some() {
            run.last_started = last_started;
        }
        if run.exit_code.is_none() || outcome.exit_code != Some(0) {
            run.exit_code = outcome.exit_code.map(i64::from);
        }
        if outcome.timed_out {
            run.timed_out = true;
            let hung = hung_test(sub, binary, &run.outcomes).or_else(|| run.last_started.clone());
            run.note = match hung {
                Some(name) => format!("the suite ran out of time while running `{name}`"),
                None => "the suite ran out of time".into(),
            };
            break;
        }
        if outcome.stdout_overflow {
            run.overflow = true;
            break;
        }
    }
    Ok(run)
}

/// Which test was still running when the wall clock ran out.
///
/// libtest prints `test tests::x ... ` *before* running it, but through a line
/// buffer, so on a kill that half-line is usually still in the buffer and the
/// name is lost — the one thing a player most wants to know. What survives is
/// the list: `--list` re-enumerates the tests in the order `--test-threads=1`
/// runs them (libtest sorts by name), and the first one with no result is the
/// one that hung. Paid for only on a timeout, which is not the common path.
fn hung_test(sub: &Submission, binary: &Path, done: &[TestOutcome]) -> Option<String> {
    list_tests(sub, binary)
        .into_iter()
        .find(|name| !done.iter().any(|o| &o.name == name))
}

/// The binary's own list of tests, in the order `--test-threads=1` runs them.
/// Registration only — no test body executes — and still under §5.3's limits,
/// because a static initializer is the player's code too.
fn list_tests(sub: &Submission, binary: &Path) -> Vec<String> {
    let mut command = Command::new(binary);
    command.current_dir(&sub.workdir);
    crate::harness::strip_env(&mut command, &sub.workdir);
    command.arg("--list").arg("--format").arg("terse");
    let outcome = match proc::run(
        command,
        b"",
        &Limits {
            timeout: Duration::from_secs(5),
            max_stdout: 1 << 20,
            max_stderr: 64 * 1024,
            apply_rlimits: true,
            address_space: true,
        },
        "list",
        "list",
        proc::no_logs(),
    ) {
        Ok(outcome) => outcome,
        Err(_) => return Vec::new(),
    };
    String::from_utf8_lossy(&outcome.stdout)
        .lines()
        // `tests::adds: test`
        .filter_map(|line| {
            line.split_once(": test")
                .map(|(name, _)| name.trim().to_string())
        })
        .collect()
}

/// libtest's own output, which has looked like this since 1.0 and which
/// `--format json` is still nightly-only, so it is what there is:
///
/// ```text
/// running 2 tests
/// test tests::adds ... ok
/// test tests::fails ... FAILED
///
/// failures:
///
/// ---- tests::fails stdout ----
/// thread 'tests::fails' panicked at src/lib.rs:9:18:
/// assertion `left == right` failed
/// ```
fn parse_libtest(stdout: &str) -> (Vec<TestOutcome>, Option<String>) {
    let mut outcomes: Vec<TestOutcome> = Vec::new();
    let mut last_started = None;
    let mut current: Option<(String, Vec<String>)> = None;
    let mut messages: Vec<(String, String)> = Vec::new();

    for line in stdout.lines() {
        // A failure block: `---- tests::fails stdout ----`
        if let Some(rest) = line.strip_prefix("---- ") {
            if let Some((name, _)) = rest.rsplit_once(" ----") {
                if let Some((n, body)) = current.take() {
                    messages.push((n, body.join("\n").trim().to_string()));
                }
                let name = name.trim_end_matches(" stdout").trim().to_string();
                current = Some((name, Vec::new()));
                continue;
            }
        }
        if line.starts_with("test result:") || line.trim() == "failures:" {
            if let Some((n, body)) = current.take() {
                messages.push((n, body.join("\n").trim().to_string()));
            }
            continue;
        }
        if let Some((name, body)) = current.as_mut() {
            let _ = name;
            body.push(line.to_string());
            continue;
        }
        if let Some(rest) = line.strip_prefix("test ") {
            if let Some((name, status)) = rest.split_once(" ... ") {
                let name = name.trim().to_string();
                let status = status.trim();
                if status.is_empty() {
                    // Written before the test runs, so a killed suite leaves
                    // this line unfinished and it names what hung.
                    last_started = Some(name);
                    continue;
                }
                last_started = Some(name.clone());
                let status = if status == "ok" {
                    Status::Passed
                } else if status.starts_with("ignored") {
                    Status::Skipped
                } else {
                    Status::Failed
                };
                let message = if status == Status::Skipped {
                    status_note(rest)
                } else {
                    String::new()
                };
                outcomes.push(TestOutcome {
                    name,
                    status,
                    message,
                });
            } else if rest.trim_end().ends_with("...") {
                last_started = Some(rest.trim_end().trim_end_matches("...").trim().to_string());
            }
        }
    }
    if let Some((n, body)) = current.take() {
        messages.push((n, body.join("\n").trim().to_string()));
    }
    for (name, message) in messages {
        if let Some(o) = outcomes.iter_mut().find(|o| o.name == name) {
            if o.status != Status::Passed {
                o.message = message;
            }
        }
    }
    (outcomes, last_started)
}

/// `ignored, needs a network` → `needs a network`.
fn status_note(rest: &str) -> String {
    rest.split_once(" ... ")
        .map(|(_, s)| s.trim())
        .unwrap_or("")
        .strip_prefix("ignored")
        .unwrap_or("")
        .trim_start_matches(',')
        .trim()
        .to_string()
}

/// Whether this build can reach `cargo` at all. Used by the tests, and by
/// nothing else: the server asks [`crate::unsupported`].
/// One line of `cargo --message-format=json`, as the player should read it.
/// A `compiler-message` record is unwrapped to its diagnostic's `rendered`
/// text; every other `reason` (`compiler-artifact`, `build-script-executed`,
/// `build-finished`) is bookkeeping and is not streamed. cargo's own prose
/// arrives on the other pipe and is not JSON, so it goes through as it came.
fn cargo_line(line: &str) -> Option<String> {
    match serde_json::from_str::<serde_json::Value>(line) {
        Ok(value) if value.is_object() => {
            if value.get("reason").and_then(|r| r.as_str()) == Some("compiler-message") {
                value.get("message").and_then(rendered_of)
            } else {
                None
            }
        }
        _ => Some(line.to_string()),
    }
}

pub fn is_installed() -> bool {
    Command::new("cargo")
        .arg("--version")
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

/// Exposed for the tests, which assert the generated manifest keeps the
/// package out of any workspace above it.
pub fn generated_manifest(attempt_id: &str) -> String {
    manifest(attempt_id)
}
