//! The Python runner against the real `python3` (SPEC §5, §9.6).
//!
//! The same limits the compiled lands are held to, asserted the same way,
//! plus the two things that are Python's own: a `SyntaxError` is a compile
//! error and not the first case's runtime error, and the interpreter that
//! runs the program is the one that checked it, not whatever `/usr/bin`
//! happens to hold.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

use cwbhacker_runner::{Event, Submission, TestSpec, Verdict};

fn python_is_installed() -> bool {
    std::process::Command::new("python3")
        .arg("--version")
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
        attempt_id: "att_py_test",
        lang: "python",
        source,
        spec,
        workdir: tmp.path().join("build/python/att_py_test"),
        cache_root: tmp.path().join("build/python"),
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

const HELLO: &str = "print(\"hello, causewaybay\")\n";

#[test]
fn python_is_available_at_all() {
    assert!(
        python_is_installed(),
        "the Python land needs a `python3` on PATH; `cwbhacker doctor` reports it"
    );
}

#[test]
fn a_correct_python_program_is_accepted_and_streams_its_stages() {
    if !python_is_installed() {
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
        "{}\n{}",
        run.report.compiler_stderr,
        run.report.runtime_stderr
    );
    assert_eq!(run.report.tests_passed, 1);
    // The compile phase is `py_compile`, and it is still a stage: the
    // client's progress line must not skip from queued to running.
    assert_eq!(run.stages, vec!["compiling", "running", "judging"]);
}

#[test]
fn stdin_reaches_a_python_program() {
    if !python_is_installed() {
        return;
    }
    let source = "import sys\ndata = sys.stdin.read().split()\nn = int(data[0])\nprint(sum(int(v) for v in data[1:1 + n]))\n";
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
    if !python_is_installed() {
        return;
    }
    let run = run(
        "print(\"goodbye\")\n",
        &stdio(serde_json::json!([
            { "name": "greets", "stdin": "", "expect": "hello, causewaybay\n", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::WrongAnswer);
    assert_eq!(run.report.cases[0].got.as_deref(), Some("goodbye\n"));
}

/// The compile phase: a file that does not parse never runs a case, and the
/// verdict says `compile_error` the way it would in any other land.
#[test]
fn a_syntax_error_is_a_compile_error_not_a_runtime_error() {
    if !python_is_installed() {
        return;
    }
    let run = run(
        "def f(:\n    pass\n",
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "x", "visible": true }
        ])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::CompileError,
        "{}",
        run.report.compiler_stderr
    );
    assert_eq!(
        run.stages,
        vec!["compiling"],
        "nothing ran: {:?}",
        run.stages
    );
    let found = cwbhacker_core::mistakes::classify_compile("python", &run.report.compiler_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "syntax" && m.code.as_deref() == Some("py:syntax")),
        "{found:?}\n{}",
        run.report.compiler_stderr
    );
    assert_eq!(
        found[0].line,
        Some(1),
        "the parser's line is lost: {found:?}"
    );
}

#[test]
fn an_indentation_error_is_a_compile_error_too() {
    if !python_is_installed() {
        return;
    }
    let run = run(
        "if True:\nprint(1)\n",
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "x", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::CompileError);
    let found = cwbhacker_core::mistakes::classify_compile("python", &run.report.compiler_stderr);
    assert!(
        found.iter().any(|m| m.kind == "syntax"),
        "{found:?}\n{}",
        run.report.compiler_stderr
    );
    assert_eq!(found[0].line, Some(2), "{found:?}");
}

/// SPEC §7.1's Python column through the real interpreter.
#[test]
fn a_name_error_is_a_runtime_error_classified_as_unknown_name() {
    if !python_is_installed() {
        return;
    }
    let run = run(
        "x = 1\nprint(tolal)\n",
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "x", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::RuntimeError);
    let found = cwbhacker_core::mistakes::classify_runtime("python", &run.report.runtime_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "unknown-name" && m.code.as_deref() == Some("py:name-error")),
        "{found:?}: {}",
        run.report.runtime_stderr
    );
    assert_eq!(found[0].line, Some(2), "{found:?}");
}

/// The boss of `python.basic`: `'NoneType' object has no attribute`.
#[test]
fn an_attribute_of_none_is_nil_deref() {
    if !python_is_installed() {
        return;
    }
    let source = "stall = None\n\ndef price():\n    return stall.price\n\nprint(price())\n";
    let run = run(
        source,
        &stdio(serde_json::json!([
            { "name": "boom", "stdin": "", "expect": "x", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::RuntimeError);
    let found = cwbhacker_core::mistakes::classify_runtime("python", &run.report.runtime_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "nil-deref" && m.code.as_deref() == Some("py:none-attribute")),
        "{found:?}: {}",
        run.report.runtime_stderr
    );
    // The innermost frame in the player's file, not the call site.
    assert_eq!(found[0].line, Some(4), "{found:?}");
}

#[test]
fn an_infinite_python_loop_times_out() {
    if !python_is_installed() {
        return;
    }
    let started = Instant::now();
    let run = run(
        "while True:\n    pass\n",
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
fn too_much_python_output_is_an_output_limit() {
    if !python_is_installed() {
        return;
    }
    let run = run(
        "line = 'x' * 1024\nwhile True:\n    print(line)\n",
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

/// `-I`: no user site, no `PYTHON*` variables, and the script directory off
/// `sys.path`. A quest cannot import something the player installed.
#[test]
fn the_interpreter_runs_isolated() {
    if !python_is_installed() {
        return;
    }
    let run = run(
        "import sys\nprint(int(sys.flags.isolated))\nprint(sys.version_info >= (3, 10))\n",
        &stdio(serde_json::json!([
            { "name": "flags", "stdin": "", "expect": "1\nTrue\n", "visible": true }
        ])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::Accepted,
        "{}",
        run.report.cases[0].got.as_deref().unwrap_or("")
    );
}

#[test]
fn the_compile_phase_streams_while_it_works() {
    if !python_is_installed() {
        return;
    }
    let run = run(
        "def f(:\n    pass\n",
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
fn python_stdio_is_open_and_the_other_harnesses_are_refused() {
    let stdio_spec = stdio(serde_json::json!([
        { "name": "any", "stdin": "", "expect": "x", "visible": true }
    ]));
    assert_eq!(cwbhacker_runner::unsupported("python", &stdio_spec), None);
    for harness in ["cargo", "gotest"] {
        let wrong = spec(serde_json::json!({
            "harness": harness,
            "cases": [ { "name": "t", "visible": true } ]
        }));
        let reason = cwbhacker_runner::unsupported("python", &wrong)
            .unwrap_or_else(|| panic!("the {harness} harness must be refused for python"));
        assert!(reason.contains("python"), "{reason}");
    }
}

/// PyTorch Land shares this runner, and shares this test — except that its
/// stdio gate is not unconditional. `torch` is a package rather than a
/// program, so the land can be present in the content and absent from the
/// machine, and a submission to it must be refused *before* an attempt row
/// exists: a `ModuleNotFoundError` is a real exception and would be filed as
/// the player's own mistake (SPEC §7). Asserted against the probe rather
/// than against a constant, so it holds on a machine with torch and on one
/// without, which is the only way CI and a laptop can run the same test.
#[test]
fn pytorch_stdio_is_open_only_where_torch_is_importable() {
    let stdio_spec = stdio(serde_json::json!([
        { "name": "any", "stdin": "", "expect": "x", "visible": true }
    ]));
    let refusal = cwbhacker_runner::unsupported("pytorch", &stdio_spec);
    assert_eq!(
        refusal.is_none(),
        cwbhacker_runner::format::torch_is_installed(),
        "the gate and the probe disagree about torch: {refusal:?}"
    );
    if let Some(reason) = refusal {
        assert!(reason.contains("torch"), "{reason}");
        assert!(
            reason.contains("pip install"),
            "a refusal without the command to fix it: {reason}"
        );
    }
    for harness in ["cargo", "gotest"] {
        let wrong = spec(serde_json::json!({
            "harness": harness,
            "cases": [ { "name": "t", "visible": true } ]
        }));
        let reason = cwbhacker_runner::unsupported("pytorch", &wrong)
            .unwrap_or_else(|| panic!("the {harness} harness must be refused for pytorch"));
        assert!(reason.contains("pytorch"), "{reason}");
    }
}

/// Python's formatter is `black`, which does not ship with the interpreter:
/// the gate answers for the machine it is on, and a machine without it says
/// so before anything is spawned rather than mangling the source.
#[test]
fn python_formats_only_where_black_is_installed() {
    let have = std::process::Command::new("python3")
        .args(["-m", "black", "--version"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    assert_eq!(cwbhacker_runner::format::is_supported("python"), have);
    let out = cwbhacker_runner::format::format("python", HELLO).unwrap();
    if have {
        // HELLO is already tidy, so the answer is "nothing to do", not a
        // rewrite — and never a mangling.
        assert_eq!(out.problem, None);
        assert!(out.source.contains("hello"), "{}", out.source);
    } else {
        assert_eq!(out.source, HELLO);
        assert!(!out.changed);
        assert!(out.problem.unwrap().contains("black"));
    }
}

/// SPEC §1: nothing outside the home is written. `py_compile`'s `.pyc` lands
/// in the attempt directory's own `__pycache__`, which is inside the home
/// and pruned with the attempt; nothing else appears.
#[test]
fn the_interpreter_writes_only_under_the_home_it_was_given() {
    if !python_is_installed() {
        return;
    }
    let home = tempfile::tempdir().unwrap();
    let spec = stdio(serde_json::json!([
        { "name": "greets", "stdin": "", "expect": "hello, causewaybay\n", "visible": true }
    ]));
    let submission = Submission {
        attempt_id: "att_footprint",
        lang: "python",
        source: HELLO,
        spec: &spec,
        workdir: home.path().join("build/python/att_footprint"),
        cache_root: home.path().join("build/python"),
        events: cwbhacker_runner::no_events(),
    };
    let report = cwbhacker_runner::run(&submission);
    assert_eq!(
        report.verdict,
        Verdict::Accepted,
        "{}",
        report.compiler_stderr
    );
    assert!(home
        .path()
        .join("build/python/att_footprint/main.py")
        .is_file());
    let mut entries: Vec<String> =
        std::fs::read_dir(home.path().join("build/python/att_footprint"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
            .filter(|name| name != "__pycache__")
            .collect();
    entries.sort();
    assert_eq!(
        entries,
        vec!["main.py"],
        "the attempt directory grew: {entries:?}"
    );
}
