//! The `gotest` harness against the real toolchain (SPEC §5, §9.6).
//!
//! Mirrors `go_runner.rs` — a passing suite, a failing test, a compile error
//! classified, a timeout, an output flood, `GOPROXY=off` refusing a fetch —
//! and adds the failure modes that only exist once the tests are code: a
//! submission that ran no tests, and a quest whose own tests are broken.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use cwbhacker_runner::{Event, Submission, TestSpec, Verdict};

fn go_is_installed() -> bool {
    cwbhacker_runner::gotest::is_installed()
}

fn spec(json: serde_json::Value) -> TestSpec {
    TestSpec::parse(&json).expect("spec parses")
}

fn gotest(cases: serde_json::Value) -> TestSpec {
    spec(serde_json::json!({
        "harness": "gotest",
        "timeout_ms": 5000,
        "compile_timeout_ms": 90000,
        "cases": cases,
    }))
}

fn with_quest_tests(cases: serde_json::Value, test_source: &str) -> TestSpec {
    spec(serde_json::json!({
        "harness": "gotest",
        "timeout_ms": 5000,
        "compile_timeout_ms": 90000,
        "cases": cases,
        "test_source": test_source,
    }))
}

/// One Go build cache for the whole suite.
///
/// Not a shortcut: it is what SPEC §5.1 describes — "the first run is the slow
/// one and the rest are not" — and it is also the only way eighteen tests can
/// run in parallel on one machine without eighteen cold toolchain builds
/// fighting over the CPU and blowing every wall clock in the file. The one
/// test that needs a virgin home says so and makes its own.
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
    let attempt_id = format!("att_gotest_{}", NEXT.fetch_add(1, Ordering::Relaxed));
    let logs = Arc::new(AtomicUsize::new(0));
    let stages = Arc::new(std::sync::Mutex::new(Vec::new()));
    let (l, s) = (logs.clone(), stages.clone());
    let submission = Submission {
        attempt_id: &attempt_id,
        lang: "go",
        source,
        spec,
        workdir: home.join("build/go").join(&attempt_id),
        cache_root: home.join("build/go"),
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

const PASSING: &str = r#"package main

import "testing"

func Add(a, b int64) int64 { return a + b }

func TestAddsTwoNumbers(t *testing.T) {
	if Add(2, 3) != 5 {
		t.Fatalf("Add(2, 3) = %d, want 5", Add(2, 3))
	}
}

func TestAddsZero(t *testing.T) {
	if Add(0, 0) != 0 {
		t.Fatalf("Add(0, 0) = %d, want 0", Add(0, 0))
	}
}
"#;

#[test]
fn the_gate_is_open_for_gotest() {
    let s = gotest(serde_json::json!([{ "name": "TestAddsTwoNumbers", "visible": true }]));
    assert_eq!(
        cwbhacker_runner::unsupported("go", &s),
        None,
        "the gotest harness is built; the gate must be open"
    );
    // …and is still not a Rust harness.
    assert!(cwbhacker_runner::unsupported("rust", &s).is_some());
}

#[test]
fn a_passing_suite_is_accepted_and_streams_its_stages() {
    if !go_is_installed() {
        return;
    }
    let run = run(
        PASSING,
        &gotest(serde_json::json!([
            { "name": "TestAddsTwoNumbers", "visible": true },
            { "name": "TestAddsZero", "visible": true }
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
    assert!(run.logs > 0, "nothing streamed while go worked");
}

#[test]
fn a_failing_test_names_itself_and_keeps_what_it_said() {
    if !go_is_installed() {
        return;
    }
    let source = r#"package main

import "testing"

func Add(a, b int64) int64 { return a - b }

func TestAddsTwoNumbers(t *testing.T) {
	if got := Add(2, 3); got != 5 {
		t.Errorf("two and three make five, got %d", got)
	}
}

func TestAddsZero(t *testing.T) {
	if Add(0, 0) != 0 {
		t.Fatal("zero")
	}
}
"#;
    let run = run(
        source,
        &gotest(serde_json::json!([
            { "name": "TestAddsTwoNumbers", "visible": true },
            { "name": "TestAddsZero", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::WrongAnswer);
    assert_eq!(run.report.tests_passed, 1);
    let failed = run.case("TestAddsTwoNumbers");
    assert!(!failed.passed);
    assert!(
        failed
            .got
            .as_deref()
            .unwrap_or("")
            .contains("two and three make five"),
        "{:?}",
        failed.got
    );
    assert!(run.case("TestAddsZero").passed);
}

/// Go's subtests are tests, and a case may name one exactly. A parent never
/// stands in for a child: `TestTable` does not satisfy `TestTable/negative`.
#[test]
fn a_subtest_is_reported_under_its_own_name() {
    if !go_is_installed() {
        return;
    }
    let source = r#"package main

import "testing"

func Add(a, b int64) int64 { return a + b }

func TestTable(t *testing.T) {
	cases := []struct {
		name string
		a, b, want int64
	}{
		{"positive", 2, 3, 5},
		{"negative", -2, -3, -5},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Add(c.a, c.b); got != c.want {
				t.Errorf("got %d want %d", got, c.want)
			}
		})
	}
}
"#;
    let run = run(
        source,
        &gotest(serde_json::json!([
            { "name": "TestTable/negative", "visible": true }
        ])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::Accepted,
        "{}",
        run.report.runtime_stderr
    );
    assert!(run.case("TestTable/negative").passed);
    assert!(run.case("TestTable").passed);
}

#[test]
fn a_test_the_quest_asked_for_and_cannot_find_fails_by_name() {
    if !go_is_installed() {
        return;
    }
    let run = run(
        PASSING,
        &gotest(serde_json::json!([
            { "name": "TestAddsTwoNumbers", "visible": true },
            { "name": "TestHandlesOverflow", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::WrongAnswer);
    assert!(run
        .case("TestHandlesOverflow")
        .got
        .as_deref()
        .unwrap_or("")
        .contains("no test named `TestHandlesOverflow` ran"));
}

/// `go test` on a package with no `TestXxx` says `no tests to run` and exits
/// 0. Left alone that clears every gotest quest with an empty file.
#[test]
fn a_submission_with_no_tests_never_passes() {
    if !go_is_installed() {
        return;
    }
    let run = run(
        "package main\n\nfunc Add(a, b int64) int64 { return a + b }\n",
        &gotest(serde_json::json!([{ "name": "TestAddsTwoNumbers", "visible": true }])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::WrongAnswer,
        "an empty suite cleared the node: {:?}",
        run.report
    );
    assert!(
        run.report.runtime_stderr.contains("ran no tests"),
        "{}",
        run.report.runtime_stderr
    );
}

/// `t.Skip()` must not be a cheat code for the test that was failing.
#[test]
fn a_skipped_test_has_not_passed() {
    if !go_is_installed() {
        return;
    }
    let source = r#"package main

import "testing"

func Add(a, b int64) int64 { return a - b }

func TestAddsTwoNumbers(t *testing.T) {
	t.Skip("not today")
	if Add(2, 3) != 5 {
		t.Fatal("nope")
	}
}
"#;
    let run = run(
        source,
        &gotest(serde_json::json!([{ "name": "TestAddsTwoNumbers", "visible": true }])),
    );
    assert_eq!(run.report.verdict, Verdict::WrongAnswer);
    let case = run.case("TestAddsTwoNumbers");
    assert!(!case.passed);
    assert!(
        case.got.as_deref().unwrap_or("").contains("skipped"),
        "{:?}",
        case.got
    );
}

/// SPEC §7.1's Go column, through `go test -c` rather than `go build`. The
/// classifier reads the same prose either way, so the harness must not mangle
/// it on the way through.
#[test]
fn a_compile_error_is_classified_and_keeps_its_spans() {
    if !go_is_installed() {
        return;
    }
    let source = r#"package main

import "testing"

func TestAdds(t *testing.T) {
	if Add(2, 3) != 5 {
		t.Fatal("nope")
	}
}
"#;
    let run = run(
        source,
        &gotest(serde_json::json!([{ "name": "TestAdds", "visible": true }])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::CompileError,
        "{}",
        run.report.compiler_stderr
    );
    let found = cwbhacker_core::mistakes::classify_compile("go", &run.report.compiler_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "unknown-name" && m.code.as_deref() == Some("go:undefined")),
        "{found:?} / {}",
        run.report.compiler_stderr
    );
    assert!(
        found
            .iter()
            .filter(|m| m.kind == "unknown-name")
            .all(|m| m.line.is_some()),
        "spans are lost: {found:?}"
    );
}

#[test]
fn a_test_that_loops_forever_is_a_timeout_and_names_what_hung() {
    if !go_is_installed() {
        return;
    }
    let source = r#"package main

import "testing"

func TestSpinsForever(t *testing.T) {
	for {
	}
}
"#;
    let mut spec = gotest(serde_json::json!([{ "name": "TestSpinsForever", "visible": true }]));
    // Deliberately not the tightest budget that works. The claim under test is
    // "a timeout names the test", not "two seconds is enough on a machine
    // running seventeen other Go builds": a test that only passes on an idle
    // laptop is a test that will be deleted for flakiness.
    spec.timeout_ms = 5000;
    let started = std::time::Instant::now();
    let run = run(source, &spec);
    assert_eq!(run.report.verdict, Verdict::Timeout);
    assert!(
        run.report.runtime_stderr.contains("TestSpinsForever"),
        "a timeout should name the test that hung: {}",
        run.report.runtime_stderr
    );
    assert!(
        started.elapsed() < std::time::Duration::from_secs(90),
        "the timeout did not end the run"
    );
}

/// Unlike libtest, `go test` streams a test's output as it goes, so the byte
/// cap fires exactly the way it does for a stdio submission.
#[test]
fn too_much_output_is_an_output_limit() {
    if !go_is_installed() {
        return;
    }
    let source = r#"package main

import (
	"strings"
	"testing"
)

func TestShouts(t *testing.T) {
	line := strings.Repeat("x", 1024)
	for {
		t.Log(line)
	}
}
"#;
    let mut spec = gotest(serde_json::json!([{ "name": "TestShouts", "visible": true }]));
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

/// SPEC §9.6: `GOPROXY=off` → a quest that tries to fetch fails cleanly rather
/// than hanging on the network. The test harness must not have opened a door
/// the stdio one keeps shut.
#[test]
fn a_quest_that_tries_to_fetch_fails_cleanly() {
    if !go_is_installed() {
        return;
    }
    let source = r#"package main

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNeedsTheInternet(t *testing.T) {
	assert.Equal(t, 1, 1)
}
"#;
    let started = std::time::Instant::now();
    let run = run(
        source,
        &gotest(serde_json::json!([{ "name": "TestNeedsTheInternet", "visible": true }])),
    );
    assert!(
        matches!(
            run.report.verdict,
            Verdict::CompileError | Verdict::InternalError
        ),
        "{:?}: {}",
        run.report.verdict,
        run.report.compiler_stderr
    );
    assert_ne!(run.report.verdict, Verdict::Accepted);
    assert!(
        started.elapsed() < std::time::Duration::from_secs(60),
        "the runner waited on the network"
    );
    let said = format!(
        "{}{}",
        run.report.compiler_stderr, run.report.runtime_stderr
    );
    assert!(
        said.contains("GOPROXY=off") || said.contains("module lookup disabled"),
        "the refusal does not explain itself: {said}"
    );
}

/// The failure mode that belongs to this harness alone. Nothing may be
/// recorded against a player for a file they never wrote.
#[test]
fn a_quest_whose_own_tests_are_broken_is_not_the_players_fault() {
    if !go_is_installed() {
        return;
    }
    let broken = r#"package main

import "testing"

func TestAddsTwoNumbers(t *testing.T {
	if Add(2, 3) != 5 {
		t.Fatal("nope")
	}
}
"#;
    let run = run(
        "package main\n\nfunc Add(a, b int64) int64 { return a + b }\n",
        &with_quest_tests(
            serde_json::json!([{ "name": "TestAddsTwoNumbers", "visible": true }]),
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
    assert!(
        cwbhacker_core::mistakes::classify_compile("go", &run.report.compiler_stderr).is_empty(),
        "a mistake was recorded for a quest's own broken tests"
    );
}

/// And the half that is easy to get backwards: the quest's tests are fine and
/// the player's code is missing what they call. That is the player's failure,
/// and it must name what was wanted.
#[test]
fn tests_that_cannot_find_the_players_function_are_the_players_failure() {
    if !go_is_installed() {
        return;
    }
    let quest_tests = r#"package main

import "testing"

func TestAddsTwoNumbers(t *testing.T) {
	if Add(2, 3) != 5 {
		t.Fatal("nope")
	}
}
"#;
    let run = run(
        "package main\n\nfunc Plus(a, b int64) int64 { return a + b }\n",
        &with_quest_tests(
            serde_json::json!([{ "name": "TestAddsTwoNumbers", "visible": true }]),
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
        run.report.runtime_stderr.contains("Add"),
        "the player is not told what the tests wanted: {}",
        run.report.runtime_stderr
    );
}

#[test]
fn a_quest_supplied_test_the_pack_did_not_declare_stays_hidden() {
    if !go_is_installed() {
        return;
    }
    let quest_tests = r#"package main

import "testing"

func TestAddsTwoNumbers(t *testing.T) {
	if Add(2, 3) != 5 {
		t.Fatal("nope")
	}
}

func TestSecretlyChecksTheEdges(t *testing.T) {
	if Add(-1, 1) != 0 {
		t.Fatal("nope")
	}
}
"#;
    let run = run(
        "package main\n\nfunc Add(a, b int64) int64 { return a + b }\n",
        &with_quest_tests(
            serde_json::json!([{ "name": "TestAddsTwoNumbers", "visible": true }]),
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
    let hidden = run.case("TestSecretlyChecksTheEdges");
    assert!(
        !hidden.visible,
        "a quest's own extra test leaked as visible"
    );
    assert!(hidden.got.is_none());
}

/// SPEC §1: nothing outside the home is written.
#[test]
fn the_go_toolchain_writes_only_under_the_home_it_was_given() {
    if !go_is_installed() {
        return;
    }
    let go_home = std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default());
    let before = (
        go_home.join("Library/Caches/go-build").exists(),
        go_home.join("go").exists(),
    );
    let home = tempfile::tempdir().unwrap();
    let run = run_in(
        home.path(),
        PASSING,
        &gotest(serde_json::json!([{ "name": "TestAddsTwoNumbers", "visible": true }])),
    );
    assert_eq!(run.report.verdict, Verdict::Accepted);
    assert!(
        run.home.join("build/go/gocache").is_dir(),
        "GOCACHE did not land where it was pointed"
    );
    assert_eq!(
        (
            go_home.join("Library/Caches/go-build").exists(),
            go_home.join("go").exists()
        ),
        before,
        "the runner touched the developer's own Go caches"
    );
}

/// `-race` arrives with `gotest`, behind a flag in the test spec, and nowhere
/// else.
///
/// What this test proves is narrow and deliberate: the flag reaches the build,
/// the binary runs under §5.3's limits, and a blatant unsynchronised counter
/// is caught. What it does **not** prove — and what `docs/decisions.md` says
/// out loud — is that a race quest is judgeable. The detector reports only
/// races that actually raced on that run.
#[test]
fn the_race_flag_builds_and_catches_a_blatant_race() {
    if !go_is_installed() {
        return;
    }
    let source = r#"package main

import (
	"sync"
	"testing"
)

func TestCounter(t *testing.T) {
	x := 0
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 1000; j++ {
				x++
			}
		}()
	}
	wg.Wait()
	_ = x
}
"#;
    let spec = spec(serde_json::json!({
        "harness": "gotest",
        "race": true,
        "timeout_ms": 20000,
        "compile_timeout_ms": 120000,
        "cases": [{ "name": "TestCounter", "visible": true }],
    }));
    let run = run(source, &spec);
    let refusal = format!(
        "{}{}",
        run.report.compiler_stderr, run.report.runtime_stderr
    );
    if refusal.contains("cgo") || refusal.contains("C compiler") {
        // A platform or a machine without the race runtime — `-race` needs cgo
        // nearly everywhere, and cgo needs a C compiler that a bare CI box may
        // not have.
        // Saying so beats a red test that means "this machine cannot", and no
        // shipped quest depends on `-race` anyway — see `docs/decisions.md`.
        return;
    }
    assert_eq!(
        run.report.verdict,
        Verdict::WrongAnswer,
        "the race detector did not fail the test: {} / {}",
        run.report.stdout,
        run.report.runtime_stderr
    );
    // The detector's report goes to **stderr**, not to the test stream: the
    // `--- FAIL` line says only "race detected during execution of test".
    let said = format!("{}{}", run.report.stdout, run.report.runtime_stderr);
    assert!(said.contains("DATA RACE"), "no race was reported: {said}");
}

/// The same program without the flag: it passes. That is the whole argument
/// for why `race` is a flag and not the default — and for why a quest that
/// turns it on is promising something about the scheduler.
#[test]
fn without_the_flag_the_same_race_is_invisible() {
    if !go_is_installed() {
        return;
    }
    let source = r#"package main

import (
	"sync"
	"testing"
)

func TestCounter(t *testing.T) {
	x := 0
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 1000; j++ {
				x++
			}
		}()
	}
	wg.Wait()
	_ = x
}
"#;
    let run = run(
        source,
        &gotest(serde_json::json!([{ "name": "TestCounter", "visible": true }])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::Accepted,
        "{}",
        run.report.runtime_stderr
    );
}

/// PROTOCOL §4.9b, for the shape that makes it hard — see the same test in
/// `cargo_harness.rs`. `go test` would run every `TestXxx` in the quest's file
/// and stream each one to `run.log`; a RUN must not tell the player whether
/// the hidden ones pass.
#[test]
fn a_run_neither_executes_nor_reports_the_quests_hidden_tests() {
    if !go_is_installed() {
        return;
    }
    let quest_tests = r#"package main

import "testing"

func TestAddsTwoNumbers(t *testing.T) {
	if Add(2, 3) != 5 {
		t.Fatal("nope")
	}
}

func TestSecretlyChecksTheEdges(t *testing.T) {
	t.Fatal("the hidden one fails")
}
"#;
    let submitted = with_quest_tests(
        serde_json::json!([{ "name": "TestAddsTwoNumbers", "visible": true }]),
        quest_tests,
    );
    let source = "package main\n\nfunc Add(a, b int64) int64 { return a + b }\n";

    let submit = run(source, &submitted);
    assert_eq!(submit.report.verdict, Verdict::WrongAnswer);
    assert!(!submit.case("TestSecretlyChecksTheEdges").passed);

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
        !everything.contains("TestSecretlyChecksTheEdges"),
        "the hidden test leaked into a run: {everything}"
    );
}

/// `race` is a `gotest` option. Asking for it anywhere else is an authoring
/// mistake the importer refuses, rather than a flag that is quietly ignored —
/// a quest that believed it was judged under `-race` and was not is worse than
/// one that failed to import.
#[test]
fn race_is_refused_outside_the_gotest_harness() {
    for harness in ["stdio", "cargo"] {
        let parsed = TestSpec::parse(&serde_json::json!({
            "harness": harness,
            "race": true,
            "cases": [{ "name": "any", "stdin": "", "expect": "x", "visible": true }]
        }));
        assert!(parsed.is_err(), "race = true was accepted on {harness}");
    }
}
