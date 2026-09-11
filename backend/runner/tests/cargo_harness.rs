//! The `cargo` harness against the real toolchain (SPEC §5, §9.6).
//!
//! Mirrors `rust_runner.rs` case for case — a passing suite, a failing
//! assertion, a compile error classified, a timeout, an output flood — plus
//! the two failure modes that only exist once the tests themselves are code:
//! a submission that ran **no** tests, and a quest whose **own** tests are
//! broken.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use cwbhacker_runner::{Event, Submission, TestSpec, Verdict};

fn cargo_is_installed() -> bool {
    cwbhacker_runner::cargo::is_installed()
}

fn spec(json: serde_json::Value) -> TestSpec {
    TestSpec::parse(&json).expect("spec parses")
}

/// A cargo spec with the compile budget the harness actually needs. The first
/// build in a fresh cache is the slow one (§5.1), and every test here gets a
/// fresh cache on purpose.
fn cargo_spec(cases: serde_json::Value) -> TestSpec {
    spec(serde_json::json!({
        "harness": "cargo",
        "timeout_ms": 5000,
        "compile_timeout_ms": 90000,
        "cases": cases,
    }))
}

fn with_quest_tests(cases: serde_json::Value, test_source: &str) -> TestSpec {
    spec(serde_json::json!({
        "harness": "cargo",
        // A quest that ships its own tests builds *two* binaries and runs both
        // inside one budget, and `timeout_ms` is a real wall clock: this file
        // runs nineteen toolchains at once, and a starved process can lose five
        // seconds to the scheduler without executing anything. The claim under
        // test is never "it is fast".
        "timeout_ms": 15000,
        "compile_timeout_ms": 90000,
        "cases": cases,
        "test_source": test_source,
    }))
}

/// One cargo home and one target directory for the whole suite.
///
/// This is what SPEC §5.1 describes — "so the first run is the slow one and
/// the rest are not" — and it is also what keeps nineteen tests from starting
/// nineteen cold cargo builds at once and starving each other's *run* phase of
/// CPU until a five-second wall clock expires on a test that takes a
/// microsecond. The one test that needs a virgin home makes its own.
fn shared_home() -> &'static std::path::Path {
    static HOME: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
    HOME.get_or_init(|| tempfile::tempdir().unwrap()).path()
}

struct Run {
    report: cwbhacker_runner::Report,
    logs: usize,
    stages: Vec<String>,
    home: std::path::PathBuf,
}

impl Run {
    fn case(&self, name: &str) -> &cwbhacker_runner::CaseResult {
        self.report
            .cases
            .iter()
            .find(|c| c.name == name)
            .unwrap_or_else(|| panic!("no case '{name}' in {:?}", self.report.cases))
    }
}

fn run(source: &str, spec: &TestSpec) -> Run {
    run_in(shared_home(), source, spec)
}

fn run_in(home: &std::path::Path, source: &str, spec: &TestSpec) -> Run {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let attempt_id = format!("att_cargo_{}", NEXT.fetch_add(1, Ordering::Relaxed));
    let logs = Arc::new(AtomicUsize::new(0));
    let stages = Arc::new(std::sync::Mutex::new(Vec::new()));
    let (l, s) = (logs.clone(), stages.clone());
    let submission = Submission {
        attempt_id: &attempt_id,
        lang: "rust",
        source,
        spec,
        workdir: home.join("build/rust").join(&attempt_id),
        cache_root: home.join("build/rust"),
        events: Arc::new(move |event| match event {
            Event::Log { .. } => {
                l.fetch_add(1, Ordering::Relaxed);
            }
            Event::Stage(stage) => s.lock().unwrap().push(stage.to_string()),
        }),
    };
    let report = cwbhacker_runner::run(&submission);
    let stages = stages.lock().unwrap().clone();
    Run {
        report,
        logs: logs.load(Ordering::Relaxed),
        stages,
        home: home.to_path_buf(),
    }
}

const PASSING: &str = r#"
pub fn add(a: i64, b: i64) -> i64 { a + b }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds_two_numbers() {
        assert_eq!(add(2, 3), 5);
    }

    #[test]
    fn adds_zero() {
        assert_eq!(add(0, 0), 0);
    }
}
"#;

#[test]
fn cargo_is_available_at_all() {
    assert!(
        cargo_is_installed(),
        "the cargo harness needs a `cargo` on PATH; `cwbhacker doctor` reports it"
    );
}

#[test]
fn the_gate_is_open_for_cargo() {
    let s = cargo_spec(serde_json::json!([{ "name": "adds_two_numbers", "visible": true }]));
    assert_eq!(
        cwbhacker_runner::unsupported("rust", &s),
        None,
        "the cargo harness is built; the gate must be open"
    );
    // …and is still not a Go harness.
    assert!(cwbhacker_runner::unsupported("go", &s).is_some());
}

#[test]
fn a_passing_suite_is_accepted_and_streams_its_stages() {
    if !cargo_is_installed() {
        return;
    }
    let run = run(
        PASSING,
        &cargo_spec(serde_json::json!([
            { "name": "adds_two_numbers", "visible": true },
            { "name": "adds_zero", "visible": true }
        ])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::Accepted,
        "{} / {}",
        run.report.compiler_stderr,
        run.report.runtime_stderr
    );
    assert_eq!(run.report.tests_passed, 2);
    assert_eq!(run.report.tests_total, 2);
    assert_eq!(run.stages, vec!["compiling", "running", "judging"]);
    assert!(run.logs > 0, "nothing streamed while cargo worked");
}

/// The whole point of the harness: when a test fails, the player is told
/// **which** test, by name, and what it said.
#[test]
fn a_failing_assertion_names_the_test_that_failed() {
    if !cargo_is_installed() {
        return;
    }
    let source = r#"
pub fn add(a: i64, b: i64) -> i64 { a - b }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds_two_numbers() {
        assert_eq!(add(2, 3), 5, "two and three make five");
    }

    #[test]
    fn adds_zero() {
        assert_eq!(add(0, 0), 0);
    }
}
"#;
    let run = run(
        source,
        &cargo_spec(serde_json::json!([
            { "name": "adds_two_numbers", "visible": true },
            { "name": "adds_zero", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::WrongAnswer);
    assert_eq!(run.report.tests_passed, 1);
    let failed = run.case("adds_two_numbers");
    assert!(!failed.passed);
    let got = failed.got.as_deref().unwrap_or("");
    assert!(
        got.contains("two and three make five"),
        "the assertion message is lost: {got:?}"
    );
    assert!(run.case("adds_zero").passed);
}

/// A declared case naming a test the player never wrote is a failure that says
/// so, rather than a pass by absence.
#[test]
fn a_test_the_quest_asked_for_and_cannot_find_fails_by_name() {
    if !cargo_is_installed() {
        return;
    }
    let run = run(
        PASSING,
        &cargo_spec(serde_json::json!([
            { "name": "adds_two_numbers", "visible": true },
            { "name": "handles_overflow", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::WrongAnswer);
    let missing = run.case("handles_overflow");
    assert!(!missing.passed);
    assert!(
        missing
            .got
            .as_deref()
            .unwrap_or("")
            .contains("no test named `handles_overflow` ran"),
        "{:?}",
        missing.got
    );
}

/// The hole this harness would otherwise open. `cargo test` on a file with no
/// `#[test]` in it prints `test result: ok. 0 passed` and exits 0 — the exact
/// analogue of SPEC §12's empty `expect`, which an empty `fn main() {}` clears
/// for free.
#[test]
fn a_submission_with_no_tests_never_passes() {
    if !cargo_is_installed() {
        return;
    }
    let run = run(
        "pub fn add(a: i64, b: i64) -> i64 { a + b }\n",
        &cargo_spec(serde_json::json!([{ "name": "adds_two_numbers", "visible": true }])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::WrongAnswer,
        "an empty suite cleared the node: {:?}",
        run.report
    );
    assert_eq!(run.report.tests_passed, 0);
    assert!(
        run.report.runtime_stderr.contains("ran no tests"),
        "{}",
        run.report.runtime_stderr
    );
}

/// `#[ignore]` must not be a cheat code for the test that was failing.
#[test]
fn an_ignored_test_has_not_passed() {
    if !cargo_is_installed() {
        return;
    }
    let source = r#"
pub fn add(a: i64, b: i64) -> i64 { a - b }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore]
    fn adds_two_numbers() {
        assert_eq!(add(2, 3), 5);
    }
}
"#;
    let run = run(
        source,
        &cargo_spec(serde_json::json!([{ "name": "adds_two_numbers", "visible": true }])),
    );
    assert_eq!(run.report.verdict, Verdict::WrongAnswer);
    let case = run.case("adds_two_numbers");
    assert!(!case.passed);
    assert!(
        case.got.as_deref().unwrap_or("").contains("skipped"),
        "{:?}",
        case.got
    );
}

/// SPEC §7.1 through the real toolchain. cargo wraps each `rustc` diagnostic
/// in its own envelope; unwrapping it has to leave the classifier's input
/// exactly as it was for a plain `rustc --error-format=json`, spans included.
#[test]
fn a_compile_error_is_classified_and_keeps_its_spans() {
    if !cargo_is_installed() {
        return;
    }
    let run = run(
        "pub fn add(a: i64, b: i64) -> i64 { let x: i32 = \"nope\"; a + b }\n",
        &cargo_spec(serde_json::json!([{ "name": "adds_two_numbers", "visible": true }])),
    );
    assert_eq!(run.report.verdict, Verdict::CompileError);
    let found = cwbhacker_core::mistakes::classify_rust_json(&run.report.compiler_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "type-mismatch" && m.code.as_deref() == Some("E0308")),
        "expected E0308, got {found:?}"
    );
    assert!(
        found.iter().all(|m| m.line.is_some()),
        "spans are lost: {found:?}"
    );
    // Every declared case is reported as not run, never as passed.
    assert_eq!(run.report.tests_passed, 0);
    assert!(run.report.cases.iter().all(|c| !c.passed));
}

#[test]
fn a_test_that_loops_forever_is_a_timeout_and_names_what_hung() {
    if !cargo_is_installed() {
        return;
    }
    let source = r#"
pub fn add(a: i64, b: i64) -> i64 { a + b }

#[cfg(test)]
mod tests {
    #[test]
    fn spins_forever() {
        loop { std::hint::spin_loop(); }
    }
}
"#;
    let mut spec = cargo_spec(serde_json::json!([{ "name": "spins_forever", "visible": true }]));
    spec.timeout_ms = 1500;
    let started = std::time::Instant::now();
    let run = run(source, &spec);
    assert_eq!(run.report.verdict, Verdict::Timeout);
    assert!(
        run.report.runtime_stderr.contains("spins_forever"),
        "a cargo timeout should still name the last test to start: {}",
        run.report.runtime_stderr
    );
    assert!(
        started.elapsed() < std::time::Duration::from_secs(90),
        "the timeout did not end the run"
    );
}

/// The output cap, checked against what this harness actually does — which is
/// not what the stdio harness does.
///
/// libtest **captures** a test's stdout and stderr into memory and only prints
/// it if the test fails, so a test in an infinite `println!` produces nothing
/// on the pipe the runner is draining and the byte cap never fires. What stops
/// it is the wall clock (and, where the platform honours `RLIMIT_AS`, the
/// address-space cap). The point of this test is that the flood is stopped and
/// is never an `accepted`; the honest name for the verdict is whichever of the
/// two got there first. See `docs/decisions.md`.
#[test]
fn a_test_that_floods_stdout_is_stopped_even_though_libtest_buffers_it() {
    if !cargo_is_installed() {
        return;
    }
    let source = r#"
#[cfg(test)]
mod tests {
    #[test]
    fn shouts() {
        loop { println!("{}", "x".repeat(1024)); }
    }
}
"#;
    let mut spec = cargo_spec(serde_json::json!([{ "name": "shouts", "visible": true }]));
    spec.max_stdout_bytes = 64 * 1024;
    spec.timeout_ms = 2000;
    let started = std::time::Instant::now();
    let run = run(source, &spec);
    assert!(
        matches!(run.report.verdict, Verdict::Timeout | Verdict::OutputLimit),
        "a flooding test was judged {:?}",
        run.report.verdict
    );
    assert!(
        started.elapsed() < std::time::Duration::from_secs(90),
        "the flood was not stopped"
    );
    assert_eq!(run.report.tests_passed, 0);
}

/// And the cap does fire when the bytes really do reach the pipe: a test that
/// writes to the inherited descriptor goes around libtest's capture, which is
/// the case `max_stdout_bytes` is there for.
#[test]
fn output_that_escapes_the_capture_hits_the_byte_cap() {
    if !cargo_is_installed() {
        return;
    }
    let source = r#"
#[cfg(test)]
mod tests {
    use std::io::Write;

    #[test]
    fn shouts_past_the_capture() {
        // `File::from_raw_fd`-free way to reach the real stdout: the capture
        // libtest installs is a thread-local on Rust's `print!`, not on the
        // descriptor.
        let mut out = std::fs::OpenOptions::new().write(true).open("/dev/stdout").unwrap();
        let line = vec![b'x'; 1024];
        loop {
            out.write_all(&line).unwrap();
        }
    }
}
"#;
    let mut spec = cargo_spec(serde_json::json!([
        { "name": "shouts_past_the_capture", "visible": true }
    ]));
    spec.max_stdout_bytes = 64 * 1024;
    spec.timeout_ms = 10_000;
    let run = run(source, &spec);
    assert_eq!(
        run.report.verdict,
        Verdict::OutputLimit,
        "{} / {}",
        run.report.runtime_stderr,
        run.report.stdout.len()
    );
}

/// The failure mode that belongs to this harness alone: the quest ships tests,
/// and **the quest's tests** are what will not compile. The player did nothing
/// wrong, so nothing may be recorded against them — an attempt carries a
/// verdict, a verdict carries mistakes, and SPEC §7's drills are built from
/// that table.
#[test]
fn a_quest_whose_own_tests_are_broken_is_not_the_players_fault() {
    if !cargo_is_installed() {
        return;
    }
    let broken = r#"
use quest::add;

#[test]
fn adds_two_numbers( {
    assert_eq!(add(2, 3), 5);
}
"#;
    let run = run(
        PASSING,
        &with_quest_tests(
            serde_json::json!([{ "name": "adds_two_numbers", "visible": true }]),
            broken,
        ),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::InternalError,
        "a broken quest read as the player's compile error: {} / {}",
        run.report.compiler_stderr,
        run.report.runtime_stderr
    );
    assert!(
        run.report.runtime_stderr.contains("not something you did"),
        "{}",
        run.report.runtime_stderr
    );
    // Nothing for the curriculum to learn from: no diagnostic of the player's
    // is on file, so no mistake row can be built.
    assert!(
        cwbhacker_core::mistakes::classify_rust_json(&run.report.compiler_stderr).is_empty(),
        "a mistake was recorded for a quest's own broken tests"
    );
}

/// The other half of the same rule, and the one that is easy to get wrong: the
/// quest's tests are fine, and they do not compile **because the player's code
/// is missing what they call**. That is a failed submission, not a broken
/// quest, and it must say which name the tests wanted.
#[test]
fn tests_that_cannot_find_the_players_function_are_the_players_failure() {
    if !cargo_is_installed() {
        return;
    }
    let quest_tests = r#"
use quest::add;

#[test]
fn adds_two_numbers() {
    assert_eq!(add(2, 3), 5);
}
"#;
    let run = run(
        "pub fn plus(a: i64, b: i64) -> i64 { a + b }\n",
        &with_quest_tests(
            serde_json::json!([{ "name": "adds_two_numbers", "visible": true }]),
            quest_tests,
        ),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::CompileError,
        "{} / {}",
        run.report.compiler_stderr,
        run.report.runtime_stderr
    );
    assert!(
        run.report
            .runtime_stderr
            .contains("do not compile against it"),
        "{}",
        run.report.runtime_stderr
    );
    assert!(
        run.report.runtime_stderr.contains("add"),
        "the player is not told what the tests could not find: {}",
        run.report.runtime_stderr
    );
}

/// A quest that ships its own tests keeps their names: they are the hidden
/// half of the judging (§5.2's "hidden cases report pass/fail and the case
/// name, never the data").
#[test]
fn a_quest_supplied_test_the_pack_did_not_declare_stays_hidden() {
    if !cargo_is_installed() {
        return;
    }
    let quest_tests = r#"
use quest::add;

#[test]
fn adds_two_numbers() {
    assert_eq!(add(2, 3), 5);
}

#[test]
fn secretly_checks_the_edges() {
    assert_eq!(add(-1, 1), 0);
}
"#;
    let run = run(
        "pub fn add(a: i64, b: i64) -> i64 { a + b }\n",
        &with_quest_tests(
            serde_json::json!([{ "name": "adds_two_numbers", "visible": true }]),
            quest_tests,
        ),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::Accepted,
        "{} / {}",
        run.report.compiler_stderr,
        run.report.runtime_stderr
    );
    assert_eq!(run.report.tests_total, 2);
    let hidden = run.case("secretly_checks_the_edges");
    assert!(
        !hidden.visible,
        "a quest's own extra test leaked as visible"
    );
    assert!(hidden.got.is_none());
}

/// SPEC §1: nothing outside the home is written. cargo is the tool most likely
/// to break it — with `CARGO_HOME` unset it writes to `~/.cargo` and with
/// `CARGO_TARGET_DIR` unset it drops a `target/` beside the source.
#[test]
fn cargo_writes_only_under_the_home_it_was_given() {
    if !cargo_is_installed() {
        return;
    }
    let home = tempfile::tempdir().unwrap();
    let run = run_in(
        home.path(),
        PASSING,
        &cargo_spec(serde_json::json!([{ "name": "adds_two_numbers", "visible": true }])),
    );
    assert_eq!(run.report.verdict, Verdict::Accepted);
    assert!(
        run.home.join("build/rust/target").is_dir(),
        "CARGO_TARGET_DIR did not land where it was pointed"
    );
    assert!(
        run.home.join("build/rust").read_dir().unwrap().any(|e| e
            .unwrap()
            .path()
            .join("Cargo.toml")
            .is_file()),
        "the generated manifest did not land in the attempt's own directory"
    );
}

/// The generated manifest must declare its own workspace, or one stray
/// `Cargo.toml` anywhere above the build directory makes every cargo quest
/// fail with "current package believes it's in a workspace when it's not".
#[test]
fn the_generated_manifest_is_its_own_workspace() {
    let manifest = cwbhacker_runner::cargo::generated_manifest("att_one");
    assert!(manifest.contains("[workspace]"), "{manifest}");
    // The *library* is always `quest`, so a quest's tests can say
    // `use quest::add;`…
    assert!(manifest.contains("name = \"quest\"\npath"), "{manifest}");
    // …while the *package* carries the attempt, so two attempts building into
    // one shared target directory cannot overwrite each other's test binary.
    assert!(manifest.contains("name = \"quest-att_one\""), "{manifest}");
    assert_ne!(
        cwbhacker_runner::cargo::generated_manifest("att_two"),
        manifest
    );
    assert!(manifest.contains("edition = \"2021\""), "{manifest}");
    assert!(manifest.contains("doctest = false"), "{manifest}");
}

/// SPEC §5.2's 30 s default is one `rustc`; a test harness compiles more than
/// that before it reaches the quest, and a `timeout` verdict on a correct
/// answer is the worst thing the runner can say to anybody.
#[test]
fn the_test_harnesses_get_a_longer_compile_budget_by_default() {
    let stdio = TestSpec::parse(&serde_json::json!({
        "harness": "stdio",
        "cases": [{ "name": "any", "stdin": "", "expect": "x", "visible": true }]
    }))
    .unwrap();
    assert_eq!(stdio.compile_timeout_ms, 30_000);

    for harness in ["cargo", "gotest"] {
        let spec = TestSpec::parse(&serde_json::json!({
            "harness": harness,
            "cases": [{ "name": "any", "visible": true }]
        }))
        .unwrap();
        assert_eq!(spec.compile_timeout_ms, 60_000, "{harness}");
    }

    // A pack that names a budget still gets the one it named.
    let named = TestSpec::parse(&serde_json::json!({
        "harness": "cargo",
        "compile_timeout_ms": 12_000,
        "cases": [{ "name": "any", "visible": true }]
    }))
    .unwrap();
    assert_eq!(named.compile_timeout_ms, 12_000);
}

/// PROTOCOL §4.9b, for the shape that makes it hard: the quest ships the tests,
/// so the hidden ones are not *cases* that can be filtered out of the spec —
/// they are functions in a file, and `cargo test` would run them, stream them
/// and fail the run on them.
///
/// A RUN must not tell the player whether the hidden tests pass. Here the
/// hidden one fails: a SUBMIT says so, and a RUN comes back green without the
/// name appearing anywhere in the report.
#[test]
fn a_run_neither_executes_nor_reports_the_quests_hidden_tests() {
    if !cargo_is_installed() {
        return;
    }
    let quest_tests = r#"
use quest::add;

#[test]
fn adds_two_numbers() {
    assert_eq!(add(2, 3), 5);
}

#[test]
fn secretly_checks_the_edges() {
    assert_eq!(add(-1, 1), 99, "the hidden one fails");
}
"#;
    let submitted = with_quest_tests(
        serde_json::json!([{ "name": "adds_two_numbers", "visible": true }]),
        quest_tests,
    );
    let source = "pub fn add(a: i64, b: i64) -> i64 { a + b }\n";

    // A submit runs everything and fails on the hidden test.
    let submit = run(source, &submitted);
    assert_eq!(submit.report.verdict, Verdict::WrongAnswer);
    assert!(!submit.case("secretly_checks_the_edges").passed);

    // A run sees only what was declared.
    let run = run(source, &submitted.visible_only());
    assert_eq!(
        run.report.verdict,
        Verdict::Accepted,
        "a run was failed by a hidden test: {} / {}",
        run.report.stdout,
        run.report.runtime_stderr
    );
    assert_eq!(run.report.tests_total, 1);
    let everything = format!(
        "{}{}{:?}",
        run.report.stdout, run.report.runtime_stderr, run.report.cases
    );
    assert!(
        !everything.contains("secretly_checks_the_edges"),
        "the hidden test leaked into a run: {everything}"
    );
}

/// `race = true` is a gotest option, and asking for it here is an authoring
/// mistake the importer should refuse rather than a flag to ignore.
#[test]
fn race_is_refused_on_the_cargo_harness() {
    let err = TestSpec::parse(&serde_json::json!({
        "harness": "cargo",
        "race": true,
        "cases": [{ "name": "adds", "visible": true }]
    }));
    assert!(err.is_err(), "race = true was accepted on a cargo quest");
}
