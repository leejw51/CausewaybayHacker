//! The Go runner against the real `go` toolchain (SPEC §5, §9.6).
//!
//! The same limits the Rust runner is held to, asserted the same way: a
//! timeout that is only claimed in a comment is not a timeout, and the Go
//! land must not be judged more leniently than the Rust one.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

use cwbhacker_runner::{Event, Submission, TestSpec, Verdict};

fn go_is_installed() -> bool {
    std::process::Command::new("go")
        .arg("version")
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

fn spec(json: serde_json::Value) -> TestSpec {
    TestSpec::parse(&json).expect("spec parses")
}

fn stdio(cases: serde_json::Value) -> TestSpec {
    spec(serde_json::json!({
        "harness": "stdio",
        "timeout_ms": 5000,
        "compile_timeout_ms": 60000,
        "match": "trim",
        "cases": cases,
    }))
}

struct Run {
    report: cwbhacker_runner::Report,
    logs: usize,
    stages: Vec<String>,
}

fn run(source: &str, spec: &TestSpec) -> Run {
    let tmp = tempfile::tempdir().unwrap();
    let logs = Arc::new(AtomicUsize::new(0));
    let stages = Arc::new(std::sync::Mutex::new(Vec::new()));
    let (l, s) = (logs.clone(), stages.clone());
    let submission = Submission {
        attempt_id: "att_go_test",
        lang: "go",
        source,
        spec,
        workdir: tmp.path().join("build/go/att_go_test"),
        // One cache for the whole test binary would be faster, but a per-test
        // one proves the runner creates what it needs rather than relying on
        // something an earlier test left behind.
        cache_root: tmp.path().join("build/go"),
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
    }
}

const HELLO: &str = r#"package main

import "fmt"

func main() {
	fmt.Println("hello, causewaybay")
}
"#;

#[test]
fn go_is_available_at_all() {
    assert!(
        go_is_installed(),
        "the Go land needs a `go` on PATH; `cwbhacker doctor` reports it"
    );
}

#[test]
fn a_correct_go_program_is_accepted_and_streams_its_stages() {
    if !go_is_installed() {
        return;
    }
    let run = run(
        HELLO,
        &stdio(serde_json::json!([
            { "name": "greets", "stdin": "", "expect": "hello, causewaybay\n", "visible": true }
        ])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::Accepted,
        "{}",
        run.report.compiler_stderr
    );
    assert_eq!(run.report.tests_passed, 1);
    assert_eq!(run.stages, vec!["compiling", "running", "judging"]);
}

#[test]
fn stdin_reaches_a_go_program() {
    if !go_is_installed() {
        return;
    }
    let source = r#"package main

import (
	"bufio"
	"fmt"
	"os"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	var n int
	fmt.Fscan(reader, &n)
	total := 0
	for i := 0; i < n; i++ {
		var v int
		fmt.Fscan(reader, &v)
		total += v
	}
	fmt.Println(total)
}
"#;
    let run = run(
        source,
        &stdio(serde_json::json!([
            { "name": "sample", "stdin": "3\n1 2 3\n", "expect": "6\n", "visible": true },
            { "name": "bigger", "stdin": "5\n10 20 30 40 50\n", "expect": "150\n", "visible": false }
        ])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::Accepted,
        "{}",
        run.report.runtime_stderr
    );
    assert_eq!(run.report.tests_passed, 2);
}

#[test]
fn a_wrong_answer_is_a_wrong_answer_not_a_crash() {
    if !go_is_installed() {
        return;
    }
    let run = run(
        "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"goodbye\")\n}\n",
        &stdio(serde_json::json!([
            { "name": "greets", "stdin": "", "expect": "hello, causewaybay\n", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::WrongAnswer);
    assert_eq!(run.report.cases[0].got.as_deref(), Some("goodbye\n"));
}

/// SPEC §7.1's Go column through the real compiler: the classification has to
/// work on what `go build` actually prints.
#[test]
fn an_undefined_name_is_a_compile_error_classified_as_unknown_name() {
    if !go_is_installed() {
        return;
    }
    let run = run(
        "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(tolal)\n}\n",
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "x", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::CompileError);
    let found = cwbhacker_core::mistakes::classify_compile("go", &run.report.compiler_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "unknown-name" && m.code.as_deref() == Some("go:undefined")),
        "{found:?}"
    );
    assert!(found.iter().all(|m| m.line.is_some()), "spans are lost");
}

#[test]
fn an_unused_import_is_a_compile_error_in_go() {
    if !go_is_installed() {
        return;
    }
    let run = run(
        "package main\n\nimport (\n\t\"fmt\"\n\t\"os\"\n)\n\nfunc main() {\n\tfmt.Println(\"hi\")\n}\n",
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "hi\n", "visible": true }
        ])),
    );
    // Go refuses to build at all, which is the lesson.
    assert_eq!(run.report.verdict, Verdict::CompileError);
    let found = cwbhacker_core::mistakes::classify_compile("go", &run.report.compiler_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "unused" && m.code.as_deref() == Some("go:imported-not-used")),
        "{found:?}"
    );
}

#[test]
fn a_go_panic_is_a_runtime_error() {
    if !go_is_installed() {
        return;
    }
    let source = "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tv := []int{1, 2, 3}\n\ti := 5\n\tfmt.Println(v[i])\n}\n";
    let run = run(
        source,
        &stdio(serde_json::json!([
            { "name": "boom", "stdin": "", "expect": "x", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::RuntimeError);
    let found = cwbhacker_core::mistakes::classify_runtime("go", &run.report.runtime_stderr);
    assert!(
        found.iter().any(|m| m.kind == "index-range"),
        "{}",
        run.report.runtime_stderr
    );
}

/// A deadlock is a runtime failure in Go, not a compile error, and
/// `content/go/advanced.toml` teaches it.
#[test]
fn a_deadlock_is_detected_at_runtime() {
    if !go_is_installed() {
        return;
    }
    let source = "package main\n\nfunc main() {\n\tch := make(chan int)\n\t<-ch\n}\n";
    let run = run(
        source,
        &spec(serde_json::json!({
            "harness": "stdio",
            "timeout_ms": 5000,
            "compile_timeout_ms": 60000,
            "match": "trim",
            "cases": [ { "name": "waits", "stdin": "", "expect": "x", "visible": true } ]
        })),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::RuntimeError,
        "Go's own runtime notices it and dies: {}",
        run.report.runtime_stderr
    );
    let found = cwbhacker_core::mistakes::classify_runtime("go", &run.report.runtime_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "deadlock" && m.code.as_deref() == Some("go:deadlock")),
        "{}",
        run.report.runtime_stderr
    );
}

#[test]
fn an_infinite_go_loop_times_out() {
    if !go_is_installed() {
        return;
    }
    let started = Instant::now();
    let run = run(
        "package main\n\nfunc main() {\n\tfor {\n\t}\n}\n",
        &spec(serde_json::json!({
            "harness": "stdio",
            "timeout_ms": 700,
            "compile_timeout_ms": 60000,
            "match": "trim",
            "cases": [ { "name": "spins", "stdin": "", "expect": "x", "visible": true } ]
        })),
    );
    assert_eq!(run.report.verdict, Verdict::Timeout);
    assert!(
        started.elapsed().as_secs() < 60,
        "the runner waited far longer than the timeout"
    );
}

#[test]
fn too_much_go_output_is_an_output_limit() {
    if !go_is_installed() {
        return;
    }
    let source = "package main\n\nimport (\n\t\"fmt\"\n\t\"strings\"\n)\n\nfunc main() {\n\tline := strings.Repeat(\"x\", 1024)\n\tfor {\n\t\tfmt.Println(line)\n\t}\n}\n";
    let run = run(
        source,
        &spec(serde_json::json!({
            "harness": "stdio",
            "timeout_ms": 10000,
            "compile_timeout_ms": 60000,
            "max_stdout_bytes": 4096,
            "match": "trim",
            "cases": [ { "name": "floods", "stdin": "", "expect": "x", "visible": true } ]
        })),
    );
    assert_eq!(run.report.verdict, Verdict::OutputLimit);
}

/// SPEC §9.6: `GOPROXY=off` — a quest does not fetch the internet, and one
/// that tries fails cleanly rather than hanging on a dial.
#[test]
fn a_quest_that_tries_to_fetch_fails_cleanly() {
    if !go_is_installed() {
        return;
    }
    let started = Instant::now();
    let source = "package main\n\nimport (\n\t\"fmt\"\n\n\t\"github.com/pkg/errors\"\n)\n\nfunc main() {\n\tfmt.Println(errors.New(\"nope\"))\n}\n";
    let run = run(
        source,
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "x", "visible": true }
        ])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::CompileError,
        "a network fetch must be a compile error, not a hang: {}",
        run.report.compiler_stderr
    );
    assert!(
        started.elapsed().as_secs() < 60,
        "it took {:?}, which smells like a dial rather than a refusal",
        started.elapsed()
    );
    // And whatever go said about it is kept, classified or not.
    let found = cwbhacker_core::mistakes::classify_compile("go", &run.report.compiler_stderr);
    assert!(!found.is_empty(), "{}", run.report.compiler_stderr);
}

#[test]
fn the_compiler_streams_while_it_works() {
    if !go_is_installed() {
        return;
    }
    let run = run(
        "package main\n\nfunc main() {\n\tundefined_thing()\n}\n",
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "x", "visible": true }
        ])),
    );
    assert!(
        run.logs > 0,
        "no run.log chunks were emitted while compiling"
    );
}

#[test]
fn go_stdio_is_no_longer_refused_before_dispatch() {
    let stdio_spec = stdio(serde_json::json!([
        { "name": "any", "stdin": "", "expect": "x", "visible": true }
    ]));
    assert_eq!(
        cwbhacker_runner::unsupported("go", &stdio_spec),
        None,
        "the Go land is built; the gate must be open"
    );
}

/// SPEC §1: nothing outside the home is written — a promise about the
/// *runner*, not a claim about the code it runs.
///
/// Go is the language most likely to break it: with `GOCACHE`, `GOMODCACHE`
/// or `GOPATH` unset it warms the developer's own `~/Library/Caches/go-build`
/// and `~/go`, and then one machine's run differs from another's for reasons
/// nobody can see. The build directory this test hands over is the only place
/// that may grow.
#[test]
fn the_go_toolchain_writes_only_under_the_home_it_was_given() {
    if !go_is_installed() {
        return;
    }
    let home = tempfile::tempdir().unwrap();
    let go_home = std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default());
    let go_cache = go_home.join("Library/Caches/go-build");
    let gopath = go_home.join("go");
    let before = (go_cache.exists(), gopath.exists());

    let spec = stdio(serde_json::json!([
        { "name": "greets", "stdin": "", "expect": "hello, causewaybay\n", "visible": true }
    ]));
    let submission = Submission {
        attempt_id: "att_footprint",
        lang: "go",
        source: HELLO,
        spec: &spec,
        workdir: home.path().join("build/go/att_footprint"),
        cache_root: home.path().join("build/go"),
        events: cwbhacker_runner::no_events(),
    };
    let report = cwbhacker_runner::run(&submission);
    assert_eq!(
        report.verdict,
        Verdict::Accepted,
        "{}",
        report.compiler_stderr
    );

    // The caches it was told to use exist…
    assert!(
        home.path().join("build/go/gocache").is_dir(),
        "GOCACHE did not land where it was pointed"
    );
    assert!(home.path().join("build/go/att_footprint/prog").is_file());
    // …and the ones it was not told to use were not conjured up.
    assert_eq!(
        (go_cache.exists(), gopath.exists()),
        before,
        "the runner touched the developer's own Go caches"
    );
}
