//! The `gotest` harness (SPEC §5.1, §5.2): `go test`, parsed from the JSON
//! event stream, mapped onto the same `Report` the stdio harness produces.
//!
//! Like `cargo.rs` this runs in **two phases**, and for the same reason
//! (§5.3). `go test -run . -json` compiles and runs in one process, so its
//! limits would have to be the *compiler's* limits: no address-space cap, no
//! stripped `PATH`, no `HOME` in the build directory — the toolchain needs all
//! three. The player's tests would then be the only code in the game running
//! outside §5.3. So instead:
//!
//! * `go test -c -o prog .` compiles, under `compile_timeout_ms`, with the
//!   §5.1 environment: `GOCACHE`/`GOMODCACHE`/`GOPATH` under `build/go/`,
//!   `GOPROXY=off`, `GOFLAGS=-mod=mod`, `GOTOOLCHAIN=local`, `CGO_ENABLED=0`.
//!   All of it is reused from `go.rs` rather than written twice.
//! * `prog -test.v -test.run .` then runs under exactly the limits a stdio
//!   submission gets, and its output is handed to `go tool test2json` — the
//!   same program `go test -json` pipes through internally. The JSON event
//!   stream the brief asks for is therefore the real one, produced by Go's own
//!   parser, with the player's code held to §5.3 rather than to the
//!   toolchain's environment.

use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use crate::proc::{self, Limits};
use crate::suite::{self, Status, SuiteRun, TestOutcome};
use crate::{Event, Report, Submission, Verdict};

/// The player's file when the quest ships its own tests, and when it does not.
///
/// Go only registers `TestXxx` from a file ending `_test.go`, so a quest that
/// asks the player to *write* tests must put their source in one. Which file
/// it is is decided by the spec, never by scanning the source: a rule a player
/// cannot predict is a rule that will surprise them at the worst moment.
const PLAYER_IMPL: &str = "solution.go";
const PLAYER_TEST: &str = "solution_test.go";
const QUEST_FILE: &str = "quest_test.go";

pub fn run(sub: &Submission) -> Report {
    match compile_and_judge(sub) {
        Ok(report) => report,
        Err(e) => Report::internal(format!("runner: {e}")),
    }
}

/// `go.rs`'s environment (§5.1), with the two things a *module* build needs
/// on top: module mode stated rather than inferred, and a scratch directory
/// that is not an ancestor of the module.
fn module_env(command: &mut Command, sub: &Submission) {
    crate::go::toolchain_env(command, sub);
    command
        .env("GO111MODULE", "on")
        .env("TMPDIR", sub.workdir.join("tmp"));
}

fn player_file(sub: &Submission) -> &'static str {
    if sub.spec.test_source.is_some() {
        PLAYER_IMPL
    } else {
        PLAYER_TEST
    }
}

fn compile_and_judge(sub: &Submission) -> std::io::Result<Report> {
    let root = &sub.workdir;
    std::fs::create_dir_all(root)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700));
    }
    // `go` ignores a `go.mod` that sits inside `os.TempDir()` — and
    // `os.TempDir()` is `$TMPDIR`, which the toolchain environment points at
    // the build directory. Left alone, every gotest quest silently drops out
    // of module mode ("go: warning: ignoring go.mod in system temp root"),
    // which in turn drops the language version and takes generics with it.
    // The scratch therefore gets its own subdirectory, one level down.
    std::fs::create_dir_all(root.join("tmp"))?;
    std::fs::write(root.join("go.mod"), go_mod(sub))?;
    std::fs::write(root.join(player_file(sub)), sub.source)?;
    if let Some(tests) = &sub.spec.test_source {
        std::fs::write(root.join(QUEST_FILE), tests)?;
    }
    let binary = root.join("prog");

    (sub.events)(Event::Stage("compiling"));
    let events = sub.events.clone();
    let compile_logs: proc::LogSink = Arc::new(move |_stream, chunk| {
        events(Event::Log {
            stream: "compile".into(),
            chunk: chunk.to_string(),
        });
    });

    let mut go = Command::new("go");
    go.current_dir(root)
        .arg("test")
        .arg("-c")
        .arg("-o")
        .arg(&binary);
    if sub.spec.race {
        go.arg("-race");
    }
    go.arg(".");
    module_env(&mut go, sub);
    if sub.spec.race {
        // `-race` needs cgo on every platform but the handful where the race
        // runtime is linked in directly, and a build that silently is not
        // instrumented would be worse than one that fails.
        go.env("CGO_ENABLED", "1");
    }

    let compile = proc::run(
        go,
        b"",
        &Limits {
            timeout: Duration::from_millis(sub.spec.compile_timeout_ms),
            max_stdout: 1 << 20,
            max_stderr: 4 << 20,
            apply_rlimits: false,
            address_space: false,
        },
        "compile",
        "compile",
        compile_logs,
    )?;
    let compile_ms = compile.elapsed_ms as i64;
    let mut prose = String::from_utf8_lossy(&compile.stderr).to_string();
    if !compile.stdout.is_empty() {
        prose.push_str(&String::from_utf8_lossy(&compile.stdout));
    }

    if compile.timed_out {
        return Ok(suite::no_binary(
            sub,
            Verdict::Timeout,
            compile_ms,
            prose,
            "the compiler ran out of time".into(),
            None,
        ));
    }

    if !binary.exists() {
        // `go test -c` on a package with no `_test.go` file prints
        // `?  quest  [no test files]`, writes no binary, and exits 0. That is
        // not a compile error and it is certainly not a pass: it is the
        // zero-tests rule in `suite.rs`, reached by a different road.
        if compile.exit_code == Some(0) {
            return Ok(suite::assemble(
                sub,
                compile_ms,
                String::new(),
                SuiteRun {
                    exit_code: Some(0),
                    stdout: prose,
                    ..Default::default()
                },
            ));
        }
        return Ok(compile_failure(
            sub,
            compile_ms,
            &prose,
            compile.exit_code.map(i64::from),
        ));
    }
    if compile.exit_code != Some(0) {
        return Ok(compile_failure(
            sub,
            compile_ms,
            &prose,
            compile.exit_code.map(i64::from),
        ));
    }

    (sub.events)(Event::Stage("running"));
    let mut run = execute(sub, &binary, prose.clone())?;
    // A build that succeeded may still have said something — a vet note, a
    // warning. It is the player's compiler output and it is kept; only the
    // framing `go test` wraps around it is set aside, and even that is kept,
    // one field over.
    let split = Prose::of(&prose, player_file(sub));
    if !split.noise.is_empty() {
        run.note = if run.note.is_empty() {
            split.noise.join("\n")
        } else {
            format!("{}\n{}", run.note, split.noise.join("\n"))
        };
    }
    Ok(suite::assemble(sub, compile_ms, split.players(), run))
}

/// `go test -c` prints three different kinds of line and they are owed three
/// different fates: a diagnostic about the player's file is theirs to see and
/// to be classified from (SPEC §7.1), a diagnostic about the quest's own test
/// file is not theirs at all, and the runner's framing — `FAIL\tquest [build
/// failed]`, `?   quest [no test files]` — is neither.
///
/// Nothing is dropped. The framing moves to `runtime_stderr`, because a
/// spanless `FAIL` line in `compiler_stderr` becomes an `other` row in the
/// mistakes table with no code and no line, and SPEC §7's drills are built
/// from that table.
#[derive(Debug, Default)]
struct Prose {
    player: Vec<String>,
    quest: Vec<String>,
    unattributed: Vec<String>,
    noise: Vec<String>,
}

impl Prose {
    fn of(prose: &str, mine: &str) -> Prose {
        let mut out = Prose::default();
        for line in prose.lines() {
            if line.trim().is_empty() {
                continue;
            }
            if is_framing(line) {
                out.noise.push(line.to_string());
            } else if line.contains(QUEST_FILE) {
                out.quest.push(line.to_string());
            } else if line.contains(mine) {
                out.player.push(line.to_string());
            } else {
                out.unattributed.push(line.to_string());
            }
        }
        out
    }

    /// Everything a `rustc`-shaped classifier would want: the player's own
    /// diagnostics plus the package header and any line that named no file.
    fn players(&self) -> String {
        let mut kept = self.unattributed.clone();
        kept.extend(self.player.iter().cloned());
        kept.join("\n")
    }
}

/// `go test`'s own result lines, and the toolchain's asides. Not diagnostics.
fn is_framing(line: &str) -> bool {
    let trimmed = line.trim_end();
    trimmed == "FAIL"
        || trimmed == "PASS"
        || trimmed.starts_with("FAIL\t")
        || trimmed.starts_with("ok\t")
        || trimmed.starts_with("ok  \t")
        || trimmed.starts_with("?\t")
        || trimmed.starts_with("?   \t")
        || trimmed.starts_with("go: warning:")
        || trimmed.ends_with("[build failed]")
        || trimmed.ends_with("[setup failed]")
        || trimmed.ends_with("[no test files]")
}

/// `module quest`, and the language version the installed toolchain speaks.
///
/// A `go.mod` with no `go` directive is treated as go1.16, which means
/// generics do not compile and a quest about them fails for a reason nothing
/// on screen explains. `GOTOOLCHAIN=local` is already set, so naming the
/// version that is actually here can never send `go` to the network.
fn go_mod(sub: &Submission) -> String {
    format!("module quest\n\ngo {}\n", language_version(sub))
}

fn language_version(sub: &Submission) -> String {
    let mut go = Command::new("go");
    go.arg("env").arg("GOVERSION");
    module_env(&mut go, sub);
    let out = match go.output() {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        // Older than anything this game supports, and the safe floor: 1.21 is
        // the oldest release with generics that is still current enough to
        // build a quest.
        _ => return "1.21".into(),
    };
    // `go1.27.1` → `1.27`.
    let trimmed = out.trim_start_matches("go");
    let mut parts = trimmed.split('.');
    match (parts.next(), parts.next()) {
        (Some(major), Some(minor)) if !major.is_empty() && !minor.is_empty() => {
            format!("{major}.{minor}")
        }
        _ => "1.21".into(),
    }
}

fn execute(sub: &Submission, binary: &Path, _compile_prose: String) -> std::io::Result<SuiteRun> {
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
    command.arg("-test.v");
    match suite::only(sub) {
        // A RUN of a quest that ships its own tests: only the declared ones
        // may execute, so nothing about the rest can reach the player through
        // `run.log`, the report or the verdict (PROTOCOL §4.9b). Go filters
        // per path segment, so the pattern names top-level tests and a
        // declared subtest is reached through its parent.
        Some(names) => {
            let mut tops: Vec<String> = Vec::new();
            for name in &names {
                let top = name.split('/').next().unwrap_or(name).to_string();
                if !tops.contains(&top) {
                    tops.push(top);
                }
            }
            let pattern = if tops.is_empty() {
                // Matches no test: a test name is never empty.
                "^$".to_string()
            } else {
                format!("^({})$", tops.join("|"))
            };
            command.arg("-test.run").arg(pattern);
        }
        None => {
            command.arg("-test.run").arg(".");
        }
    }
    // Go's own timeout, set just inside the wall clock, so a hang is reported
    // as `panic: test timed out` **naming the test** instead of arriving as a
    // killed process with nothing to say. The wall clock in `proc` is still
    // the authority: if the panic handler itself wedges, §5.3 ends it.
    let inner = sub.spec.timeout_ms.saturating_sub(500).max(500);
    command.arg(format!("-test.timeout={inner}ms"));

    let outcome = proc::run(
        command,
        b"",
        &Limits {
            timeout: Duration::from_millis(sub.spec.timeout_ms),
            max_stdout: sub.spec.max_stdout_bytes,
            max_stderr: 256 * 1024,
            apply_rlimits: true,
            // The one exception in the whole runner, and it is documented in
            // `proc::Limits`: the race runtime reserves far more virtual
            // address space than 1 GiB before it executes a line.
            address_space: !sub.spec.race,
        },
        "stdout",
        "stderr",
        logs,
    )?;

    let stdout = String::from_utf8_lossy(&outcome.stdout).to_string();
    let stderr = String::from_utf8_lossy(&outcome.stderr).to_string();
    let (outcomes, last_started) = parse(sub, &stdout);

    // Go turns its own timeout into a panic, which would otherwise read as a
    // runtime error. It is a timeout, and it knows which test.
    let go_timed_out = stdout.contains("panic: test timed out after")
        || stderr.contains("panic: test timed out after");
    let note = if outcome.timed_out {
        match &last_started {
            Some(name) => format!("the suite ran out of time while running `{name}`"),
            None => "the suite ran out of time".into(),
        }
    } else if go_timed_out {
        match &last_started {
            Some(name) => format!("`{name}` did not finish inside {inner} ms"),
            None => format!("a test did not finish inside {inner} ms"),
        }
    } else {
        String::new()
    };

    Ok(SuiteRun {
        outcomes,
        stdout,
        stderr,
        exit_code: outcome.exit_code.map(i64::from),
        elapsed_ms: outcome.elapsed_ms as i64,
        stdout_bytes: outcome.stdout_produced as i64,
        timed_out: outcome.timed_out || go_timed_out,
        overflow: outcome.stdout_overflow,
        last_started,
        note,
    })
}

/// The JSON event stream, by way of Go's own parser.
///
/// `go tool test2json` is the program `go test -json` uses; handing it the
/// captured output gets the identical `{"Action":"run"|"pass"|"fail"|"skip"}`
/// stream without having to trust a hand-written reader of verbose test
/// output. If the tool is missing the fallback below reads the `--- PASS:`
/// lines directly, because a toolchain oddity should not turn a real
/// submission into an internal error.
fn parse(sub: &Submission, stdout: &str) -> (Vec<TestOutcome>, Option<String>) {
    match test2json(sub, stdout) {
        Some(events) => parse_events(&events),
        None => parse_verbose(stdout),
    }
}

fn test2json(sub: &Submission, stdout: &str) -> Option<String> {
    let mut go = Command::new("go");
    go.arg("tool")
        .arg("test2json")
        .arg("-t")
        .arg("-p")
        .arg("quest");
    module_env(&mut go, sub);
    let outcome = proc::run(
        go,
        stdout.as_bytes(),
        &Limits {
            timeout: Duration::from_secs(10),
            max_stdout: 16 << 20,
            max_stderr: 256 * 1024,
            apply_rlimits: false,
            address_space: false,
        },
        "test2json",
        "test2json",
        proc::no_logs(),
    )
    .ok()?;
    if outcome.stdout.is_empty() {
        return None;
    }
    Some(String::from_utf8_lossy(&outcome.stdout).to_string())
}

fn parse_events(events: &str) -> (Vec<TestOutcome>, Option<String>) {
    let mut outcomes: Vec<TestOutcome> = Vec::new();
    let mut last_started = None;
    for line in events.lines() {
        let value: serde_json::Value = match serde_json::from_str(line.trim()) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let test = match value.get("Test").and_then(|v| v.as_str()) {
            Some(t) if !t.is_empty() => t.to_string(),
            // A package-level event (`start`, the final `fail`): not a test.
            _ => continue,
        };
        let action = value.get("Action").and_then(|v| v.as_str()).unwrap_or("");
        let output = value.get("Output").and_then(|v| v.as_str()).unwrap_or("");
        match action {
            "run" => {
                last_started = Some(test.clone());
                if !outcomes.iter().any(|o| o.name == test) {
                    outcomes.push(TestOutcome {
                        name: test,
                        // Until an event says otherwise a test that started
                        // and never finished has not passed.
                        status: Status::Failed,
                        message: String::new(),
                    });
                }
            }
            "output" => {
                if let Some(o) = outcomes.iter_mut().find(|o| o.name == test) {
                    // The framing lines are the parser's, not the player's.
                    let trimmed = output.trim_start();
                    if trimmed.starts_with("=== RUN")
                        || trimmed.starts_with("=== PAUSE")
                        || trimmed.starts_with("=== CONT")
                        || trimmed.starts_with("=== NAME")
                        || trimmed.starts_with("--- PASS")
                        || trimmed.starts_with("--- FAIL")
                        || trimmed.starts_with("--- SKIP")
                    {
                        continue;
                    }
                    o.message.push_str(output);
                }
            }
            "pass" | "fail" | "skip" => {
                let status = match action {
                    "pass" => Status::Passed,
                    "skip" => Status::Skipped,
                    _ => Status::Failed,
                };
                match outcomes.iter_mut().find(|o| o.name == test) {
                    Some(o) => o.status = status,
                    None => outcomes.push(TestOutcome {
                        name: test,
                        status,
                        message: String::new(),
                    }),
                }
            }
            _ => {}
        }
    }
    for outcome in &mut outcomes {
        outcome.message = outcome.message.trim().to_string();
    }
    (outcomes, last_started)
}

/// The fallback: `--- PASS: TestFoo (0.00s)` and friends, straight off the
/// verbose output. Used only when `go tool test2json` could not be reached.
fn parse_verbose(stdout: &str) -> (Vec<TestOutcome>, Option<String>) {
    let mut outcomes = Vec::new();
    let mut last_started = None;
    for line in stdout.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("=== RUN") {
            last_started = Some(rest.trim().to_string());
            continue;
        }
        for (marker, status) in [
            ("--- PASS: ", Status::Passed),
            ("--- FAIL: ", Status::Failed),
            ("--- SKIP: ", Status::Skipped),
        ] {
            if let Some(rest) = trimmed.strip_prefix(marker) {
                let name = rest.split_whitespace().next().unwrap_or("").to_string();
                if !name.is_empty() {
                    outcomes.push(TestOutcome {
                        name,
                        status,
                        message: String::new(),
                    });
                }
            }
        }
    }
    (outcomes, last_started)
}

/// Go says who is at fault by naming a file, which is the whole of the
/// provenance rule here: a diagnostic about `quest_test.go` is about a file the
/// player never wrote and cannot see.
fn compile_failure(
    sub: &Submission,
    compile_ms: i64,
    prose: &str,
    exit_code: Option<i64>,
) -> Report {
    let split = Prose::of(prose, player_file(sub));
    let quest_msgs = messages(&split.quest);
    let noise = split.noise.join("\n");

    if !split.player.is_empty() {
        let mut runtime = if quest_msgs.is_empty() {
            String::new()
        } else {
            suite::tests_do_not_fit(&quest_msgs)
        };
        if !noise.is_empty() {
            if !runtime.is_empty() {
                runtime.push('\n');
            }
            runtime.push_str(&noise);
        }
        return suite::no_binary(
            sub,
            Verdict::CompileError,
            compile_ms,
            split.players(),
            runtime,
            exit_code,
        );
    }

    if !quest_msgs.is_empty() {
        let mut runtime = if quest_msgs.iter().all(|m| is_about_the_players_api(m)) {
            suite::tests_do_not_fit(&quest_msgs)
        } else {
            suite::quest_is_broken(QUEST_FILE, &quest_msgs.join("; "))
        };
        let verdict = if quest_msgs.iter().all(|m| is_about_the_players_api(m)) {
            Verdict::CompileError
        } else {
            Verdict::InternalError
        };
        if !noise.is_empty() {
            runtime.push('\n');
            runtime.push_str(&noise);
        }
        // No `compiler_stderr`: a span in a file the player cannot see would
        // land a wrong line number in the mistakes table.
        return suite::no_binary(sub, verdict, compile_ms, String::new(), runtime, exit_code);
    }

    // Nothing named either file: `go` itself failed. `GOPROXY=off` refusing a
    // fetch lands here, and it is the player's to see — they wrote the import.
    suite::no_binary(
        sub,
        Verdict::CompileError,
        compile_ms,
        split.players(),
        noise,
        exit_code,
    )
}

/// `./quest_test.go:9:10: undefined: Add` → `undefined: Add`.
fn messages(lines: &[String]) -> Vec<String> {
    lines
        .iter()
        .map(|line| {
            let mut parts = line.splitn(4, ':');
            match (parts.next(), parts.next(), parts.next(), parts.next()) {
                (Some(_file), Some(l), Some(c), Some(rest))
                    if l.trim().parse::<u32>().is_ok() && c.trim().parse::<u32>().is_ok() =>
                {
                    rest.trim().to_string()
                }
                _ => line.trim().to_string(),
            }
        })
        .filter(|m| !m.is_empty())
        .collect()
}

/// Does this error mean "the tests reached for something your code does not
/// have", or does it mean the test file is broken?
fn is_about_the_players_api(message: &str) -> bool {
    const PLAYER_SHAPED: &[&str] = &[
        "undefined:",
        "not enough arguments",
        "too many arguments",
        "cannot use",
        "has no field or method",
        "is not a type",
        "not enough return values",
        "too many return values",
        "cannot call non-function",
        "assignment mismatch",
        "does not implement",
        "cannot convert",
        "undefined (type",
    ];
    PLAYER_SHAPED.iter().any(|m| message.contains(m))
}

/// Whether this build can reach a Go toolchain. For the tests; the server
/// asks [`crate::unsupported`].
pub fn is_installed() -> bool {
    Command::new("go")
        .arg("version")
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}
