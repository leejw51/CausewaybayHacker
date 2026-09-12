//! The C++ runner against the real `c++` driver (SPEC §5, §9.6).
//!
//! The same limits the Rust and Go runners are held to, asserted the same
//! way. What is particular to this land is the way it fails: a C++ program
//! that dereferenced nothing says nothing and dies of a signal, and the
//! harness has to turn that silence into something §7.1 can read.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

use cwbhacker_runner::{Event, Submission, TestSpec, Verdict};

fn cxx_is_installed() -> bool {
    std::process::Command::new("c++")
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
        attempt_id: "att_cpp_test",
        lang: "cpp",
        source,
        spec,
        workdir: tmp.path().join("build/cpp/att_cpp_test"),
        cache_root: tmp.path().join("build/cpp"),
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

const HELLO: &str = r#"#include <iostream>

int main() {
    std::cout << "hello, causewaybay\n";
}
"#;

#[test]
fn cxx_is_available_at_all() {
    assert!(
        cxx_is_installed(),
        "the C++ land needs a `c++` on PATH; `cwbhacker doctor` reports it"
    );
}

#[test]
fn a_correct_cpp_program_is_accepted_and_streams_its_stages() {
    if !cxx_is_installed() {
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
fn stdin_reaches_a_cpp_program() {
    if !cxx_is_installed() {
        return;
    }
    let source = r#"#include <iostream>

int main() {
    int n;
    std::cin >> n;
    long long total = 0;
    for (int i = 0; i < n; i++) {
        int v;
        std::cin >> v;
        total += v;
    }
    std::cout << total << "\n";
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

/// `-pthread` is part of the toolchain line, and a quest in `cpp.advanced`
/// depends on it linking.
#[test]
fn threads_link_and_run() {
    if !cxx_is_installed() {
        return;
    }
    let source = r#"#include <iostream>
#include <thread>
#include <mutex>

int main() {
    std::mutex m;
    int total = 0;
    std::thread a([&] { std::lock_guard<std::mutex> g(m); total += 1; });
    std::thread b([&] { std::lock_guard<std::mutex> g(m); total += 2; });
    a.join();
    b.join();
    std::cout << total << "\n";
}
"#;
    let run = run(
        source,
        &stdio(serde_json::json!([
            { "name": "sums", "stdin": "", "expect": "3\n", "visible": true }
        ])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::Accepted,
        "{}\n{}",
        run.report.compiler_stderr,
        run.report.runtime_stderr
    );
}

#[test]
fn a_wrong_answer_is_a_wrong_answer_not_a_crash() {
    if !cxx_is_installed() {
        return;
    }
    let run = run(
        "#include <iostream>\nint main() { std::cout << \"goodbye\\n\"; }\n",
        &stdio(serde_json::json!([
            { "name": "greets", "stdin": "", "expect": "hello, causewaybay\n", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::WrongAnswer);
    assert_eq!(run.report.cases[0].got.as_deref(), Some("goodbye\n"));
}

/// SPEC §7.1's C++ column through the real compiler: the classification has
/// to work on what `c++` actually prints, whichever of clang and gcc it is.
#[test]
fn an_undeclared_identifier_is_a_compile_error_classified_as_unknown_name() {
    if !cxx_is_installed() {
        return;
    }
    let run = run(
        "#include <iostream>\nint main() {\n    std::cout << tolal;\n}\n",
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "x", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::CompileError);
    let found = cwbhacker_core::mistakes::classify_compile("cpp", &run.report.compiler_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "unknown-name"
                && m.code.as_deref() == Some("cpp:undeclared-identifier")),
        "{found:?}\n{}",
        run.report.compiler_stderr
    );
    assert_eq!(found[0].line, Some(3), "spans are lost: {found:?}");
}

#[test]
fn a_missing_semicolon_is_syntax() {
    if !cxx_is_installed() {
        return;
    }
    let run = run(
        "#include <iostream>\nint main() {\n    std::cout << \"hi\"\n}\n",
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "x", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::CompileError);
    let found = cwbhacker_core::mistakes::classify_compile("cpp", &run.report.compiler_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "syntax" && m.code.as_deref() == Some("cpp:expected-token")),
        "{found:?}\n{}",
        run.report.compiler_stderr
    );
}

/// `-Wall` is part of the toolchain line for this: without it neither
/// compiler mentions an unused variable, and the row is lost.
#[test]
fn an_unused_variable_is_a_warning_and_still_a_mistake() {
    if !cxx_is_installed() {
        return;
    }
    let run = run(
        "#include <iostream>\nint main() {\n    int unused = 3;\n    std::cout << \"hi\\n\";\n}\n",
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "hi\n", "visible": true }
        ])),
    );
    // The program still runs; the warning is on the side.
    assert_eq!(run.report.verdict, Verdict::Accepted);
    let found = cwbhacker_core::mistakes::classify_compile("cpp", &run.report.compiler_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "unused" && m.code.as_deref() == Some("cpp:unused")),
        "{found:?}\n{}",
        run.report.compiler_stderr
    );
}

/// The one this land is about. Nothing checks you: the program dies of
/// SIGSEGV with nothing on stderr, and the harness has to say so.
#[test]
fn a_null_dereference_is_a_runtime_error_classified_as_nil_deref() {
    if !cxx_is_installed() {
        return;
    }
    // `volatile` so -O2 cannot fold the dereference away and turn a crash
    // into a quiet return.
    let source = "#include <cstdio>\nint main() {\n    int *volatile p = nullptr;\n    std::printf(\"%d\\n\", *p);\n}\n";
    let run = run(
        source,
        &stdio(serde_json::json!([
            { "name": "boom", "stdin": "", "expect": "x", "visible": true }
        ])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::RuntimeError,
        "{}",
        run.report.runtime_stderr
    );
    assert!(
        run.report.runtime_stderr.contains("signal"),
        "the harness should have named the signal: {:?}",
        run.report.runtime_stderr
    );
    let found = cwbhacker_core::mistakes::classify_runtime("cpp", &run.report.runtime_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "nil-deref" && m.code.as_deref() == Some("cpp:segfault")),
        "{found:?}: {}",
        run.report.runtime_stderr
    );
}

#[test]
fn an_uncaught_out_of_range_is_index_range() {
    if !cxx_is_installed() {
        return;
    }
    let source = "#include <vector>\n#include <iostream>\nint main() {\n    std::vector<int> v(3);\n    std::cout << v.at(7);\n}\n";
    let run = run(
        source,
        &stdio(serde_json::json!([
            { "name": "boom", "stdin": "", "expect": "x", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::RuntimeError);
    let found = cwbhacker_core::mistakes::classify_runtime("cpp", &run.report.runtime_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "index-range" && m.code.as_deref() == Some("cpp:out-of-range")),
        "{found:?}: {}",
        run.report.runtime_stderr
    );
}

#[test]
fn an_infinite_cpp_loop_times_out() {
    if !cxx_is_installed() {
        return;
    }
    let started = Instant::now();
    // `volatile` again: an empty infinite loop is undefined behaviour in
    // C++, and clang is entitled to delete it.
    let run = run(
        "int main() {\n    volatile int keep = 1;\n    while (keep) {\n    }\n}\n",
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
fn too_much_cpp_output_is_an_output_limit() {
    if !cxx_is_installed() {
        return;
    }
    let source = "#include <iostream>\n#include <string>\nint main() {\n    std::string line(1024, 'x');\n    for (;;) {\n        std::cout << line << '\\n';\n    }\n}\n";
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

#[test]
fn the_compiler_streams_while_it_works() {
    if !cxx_is_installed() {
        return;
    }
    let run = run(
        "int main() {\n    undefined_thing();\n}\n",
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
fn cpp_stdio_is_open_and_the_other_harnesses_are_refused() {
    let stdio_spec = stdio(serde_json::json!([
        { "name": "any", "stdin": "", "expect": "x", "visible": true }
    ]));
    assert_eq!(cwbhacker_runner::unsupported("cpp", &stdio_spec), None);
    for harness in ["cargo", "gotest"] {
        let wrong = spec(serde_json::json!({
            "harness": harness,
            "cases": [ { "name": "t", "visible": true } ]
        }));
        let reason = cwbhacker_runner::unsupported("cpp", &wrong)
            .unwrap_or_else(|| panic!("the {harness} harness must be refused for cpp"));
        assert!(reason.contains("cpp"), "{reason}");
    }
}

/// SPEC §1: nothing outside the home is written. The build directory this
/// test hands over is the only place that may grow.
#[test]
fn the_cpp_toolchain_writes_only_under_the_home_it_was_given() {
    if !cxx_is_installed() {
        return;
    }
    let home = tempfile::tempdir().unwrap();
    let spec = stdio(serde_json::json!([
        { "name": "greets", "stdin": "", "expect": "hello, causewaybay\n", "visible": true }
    ]));
    let submission = Submission {
        attempt_id: "att_footprint",
        lang: "cpp",
        source: HELLO,
        spec: &spec,
        workdir: home.path().join("build/cpp/att_footprint"),
        cache_root: home.path().join("build/cpp"),
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
        .join("build/cpp/att_footprint/main.cpp")
        .is_file());
    assert!(home.path().join("build/cpp/att_footprint/prog").is_file());
}
