//! The TypeScript runner against the real `tsc` and `node` (SPEC §5, §9.6).
//!
//! The same limits every land is held to, plus the two halves that are
//! TypeScript's own: a program `tsc` rejects is a `compile_error` and never
//! runs — even though `node` could strip the types and run it anyway — and a
//! program `tsc` accepts can still read a property off `undefined`, because
//! the types are gone by the time it runs. Both are asserted through §7.1's
//! classifier, so the `ts:` column is tested on real output.
//!
//! Every test returns early on a machine without `tsc` and `node`, as the
//! Python tests do without `python3`; `the_gate_agrees_with_the_probe`
//! runs everywhere and pins what such a machine is told instead.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

use cwbhacker_runner::{Event, Submission, TestSpec, Verdict};

fn installed() -> bool {
    cwbhacker_runner::format::typescript_is_installed()
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

fn one_case() -> TestSpec {
    stdio(serde_json::json!([
        { "name": "any", "stdin": "", "expect": "x", "visible": true }
    ]))
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
        attempt_id: "att_ts_test",
        lang: "typescript",
        source,
        spec,
        workdir: tmp.path().join("build/typescript/att_ts_test"),
        cache_root: tmp.path().join("build/typescript"),
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

const HELLO: &str = "console.log(\"hello, causewaybay\");\n";

#[test]
fn a_correct_program_is_accepted_and_streams_its_stages() {
    if !installed() {
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
    assert_eq!(run.stages, vec!["compiling", "running", "judging"]);
    assert!(run.logs > 0, "the run streamed nothing");
}

/// The one stdin idiom every quest uses, and the `import` form beside it.
#[test]
fn stdin_reaches_a_typescript_program_both_ways() {
    if !installed() {
        return;
    }
    let cases = serde_json::json!([
        { "name": "sample", "stdin": "3\n1 2 3\n", "expect": "6\n", "visible": true },
        { "name": "bigger", "stdin": "5\n10 20 30 40 50\n", "expect": "150\n", "visible": false }
    ]);
    for source in [
        "const input: string = require(\"fs\").readFileSync(0, \"utf8\");\n\
         const [n, ...rest] = input.split(/\\s+/).filter(Boolean).map(Number);\n\
         console.log(rest.slice(0, n).reduce((a, b) => a + b, 0));\n",
        "import { readFileSync } from \"fs\";\n\
         const nums: number[] = readFileSync(0, \"utf8\").trim().split(/\\s+/).map(Number);\n\
         let total = 0;\n\
         for (const v of nums.slice(1, 1 + nums[0])) total += v;\n\
         console.log(total);\n",
    ] {
        let run = run(source, &stdio(cases.clone()));
        assert_eq!(
            run.report.verdict,
            Verdict::Accepted,
            "{}\n{}",
            run.report.compiler_stderr,
            run.report.runtime_stderr
        );
        assert_eq!(run.report.tests_passed, 2);
    }
}

#[test]
fn a_wrong_answer_is_a_wrong_answer_not_a_crash() {
    if !installed() {
        return;
    }
    let run = run(
        "console.log(\"goodbye\");\n",
        &stdio(serde_json::json!([
            { "name": "greets", "stdin": "", "expect": "hello, causewaybay\n", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::WrongAnswer);
    assert_eq!(run.report.cases[0].got.as_deref(), Some("goodbye\n"));
}

/// The half of the land that is the checker: a type error never runs, and
/// its identity is `tsc`'s own code, on the player's line.
#[test]
fn a_type_error_is_a_compile_error_with_tscs_code() {
    if !installed() {
        return;
    }
    let run = run("const fare: number = 12;\nconst shown: string = fare;\nconsole.log(shown);\n", &one_case());
    assert_eq!(run.report.verdict, Verdict::CompileError, "{}", run.report.compiler_stderr);
    assert_eq!(run.stages, vec!["compiling"], "nothing ran: {:?}", run.stages);
    let found = cwbhacker_core::mistakes::classify_compile("typescript", &run.report.compiler_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "type-mismatch" && m.code.as_deref() == Some("TS2322")),
        "{found:?}\n{}",
        run.report.compiler_stderr
    );
    assert_eq!(found[0].line, Some(2), "{found:?}");
}

/// `strict` is on: "possibly undefined" is caught before the run.
#[test]
fn strict_null_checks_are_on() {
    if !installed() {
        return;
    }
    let run = run(
        "const boards = new Map<string, number>();\nconsole.log(boards.get(\"tin hau\").toFixed(1));\n",
        &one_case(),
    );
    assert_eq!(run.report.verdict, Verdict::CompileError);
    let found = cwbhacker_core::mistakes::classify_compile("typescript", &run.report.compiler_stderr);
    assert!(found.iter().any(|m| m.kind == "nil-deref"), "{found:?}\n{}", run.report.compiler_stderr);
}

/// What is not in `node.d.ts` is not there: `@types/node` does not leak in
/// from wherever `tsc` was installed.
#[test]
fn only_the_declared_node_api_exists() {
    if !installed() {
        return;
    }
    let run = run("const os = require(\"os\");\nconsole.log(Buffer.from(\"x\"));\n", &one_case());
    assert_eq!(run.report.verdict, Verdict::CompileError, "{}", run.report.runtime_stderr);
    let found = cwbhacker_core::mistakes::classify_compile("typescript", &run.report.compiler_stderr);
    assert!(found.iter().any(|m| m.kind == "unknown-name" || m.kind == "type-mismatch"), "{found:?}");
}

#[test]
fn a_syntax_error_is_a_compile_error() {
    if !installed() {
        return;
    }
    let run = run("function f( {\n  return 1;\n}\n", &one_case());
    assert_eq!(run.report.verdict, Verdict::CompileError);
    let found = cwbhacker_core::mistakes::classify_compile("typescript", &run.report.compiler_stderr);
    assert!(found.iter().any(|m| m.kind == "syntax"), "{found:?}\n{}", run.report.compiler_stderr);
}

/// The other half, the erasure: `tsc` is satisfied (an index is not checked
/// without `noUncheckedIndexedAccess`), and at runtime the element is not
/// there. The line is the source-mapped `main.ts` line, not the emitted JS.
#[test]
fn undefined_at_runtime_is_nil_deref_on_the_ts_line() {
    if !installed() {
        return;
    }
    let source = "interface Screen { id: number }\n\
                  const screens: Screen[] = [];\n\
                  \n\
                  function first(): number {\n\
                  \x20 return screens[0].id;\n\
                  }\n\
                  console.log(first());\n";
    let run = run(source, &one_case());
    assert_eq!(run.report.verdict, Verdict::RuntimeError, "{}", run.report.compiler_stderr);
    let found = cwbhacker_core::mistakes::classify_runtime("typescript", &run.report.runtime_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "nil-deref" && m.code.as_deref() == Some("ts:undefined-property")),
        "{found:?}: {}",
        run.report.runtime_stderr
    );
    assert_eq!(found[0].line, Some(5), "{found:?}\n{}", run.report.runtime_stderr);
}

#[test]
fn unbounded_recursion_is_classified_as_recursion() {
    if !installed() {
        return;
    }
    let run = run("function down(n: number): number {\n  return down(n + 1) + 1;\n}\nconsole.log(down(0));\n", &one_case());
    assert_eq!(run.report.verdict, Verdict::RuntimeError);
    let found = cwbhacker_core::mistakes::classify_runtime("typescript", &run.report.runtime_stderr);
    assert!(
        found.iter().any(|m| m.code.as_deref() == Some("ts:recursion")),
        "{found:?}: {}",
        run.report.runtime_stderr
    );
}

#[test]
fn a_thrown_error_nobody_caught_is_unhandled() {
    if !installed() {
        return;
    }
    let run = run(
        "const feed: unknown = JSON.parse(\"{\\\"screens\\\": [1, 2\");\nconsole.log(feed);\n",
        &one_case(),
    );
    assert_eq!(run.report.verdict, Verdict::RuntimeError);
    let found = cwbhacker_core::mistakes::classify_runtime("typescript", &run.report.runtime_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "unhandled-error" && m.code.as_deref() == Some("ts:json-parse")),
        "{found:?}: {}",
        run.report.runtime_stderr
    );
    let run2 = crate::run("throw \"offline\";\n", &one_case());
    let found = cwbhacker_core::mistakes::classify_runtime("typescript", &run2.report.runtime_stderr);
    assert!(
        found.iter().any(|m| m.code.as_deref() == Some("ts:throw")),
        "{found:?}: {}",
        run2.report.runtime_stderr
    );
}

#[test]
fn an_infinite_loop_times_out() {
    if !installed() {
        return;
    }
    let started = Instant::now();
    let run = run(
        "while (true) {}\n",
        &spec(serde_json::json!({
            "harness": "stdio",
            "timeout_ms": 700,
            "compile_timeout_ms": 60000,
            "match": "trim",
            "cases": [ { "name": "spins", "stdin": "", "expect": "x", "visible": true } ]
        })),
    );
    assert_eq!(run.report.verdict, Verdict::Timeout);
    assert!(started.elapsed().as_secs() < 60, "the runner waited far longer than the timeout");
}

/// A callback that never yields holds the event loop the same way: the
/// timer it was meant to let run never fires, and the case times out.
#[test]
fn a_blocked_event_loop_times_out() {
    if !installed() {
        return;
    }
    let run = run(
        "let done = false;\nsetTimeout(() => { done = true; }, 0);\nwhile (!done) {}\nconsole.log(\"x\");\n",
        &spec(serde_json::json!({
            "harness": "stdio",
            "timeout_ms": 700,
            "compile_timeout_ms": 60000,
            "match": "trim",
            "cases": [ { "name": "frozen", "stdin": "", "expect": "x", "visible": true } ]
        })),
    );
    assert_eq!(run.report.verdict, Verdict::Timeout);
}

#[test]
fn too_much_output_is_an_output_limit() {
    if !installed() {
        return;
    }
    let run = run(
        "const line = \"x\".repeat(1024);\nfor (;;) console.log(line);\n",
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

/// Where `tsc` and `node` are missing the land is refused before an attempt
/// exists, with the command to fix it; where they are present it is open.
/// Asserted against the probe, so it holds on both kinds of machine.
#[test]
fn the_gate_agrees_with_the_probe() {
    let refusal = cwbhacker_runner::unsupported("typescript", &one_case());
    assert_eq!(refusal.is_none(), installed(), "{refusal:?}");
    if let Some(reason) = refusal {
        assert!(reason.contains("npm install"), "a refusal without the fix: {reason}");
    }
    for harness in ["cargo", "gotest"] {
        let wrong = spec(serde_json::json!({
            "harness": harness,
            "cases": [ { "name": "t", "visible": true } ]
        }));
        let reason = cwbhacker_runner::unsupported("typescript", &wrong)
            .unwrap_or_else(|| panic!("the {harness} harness must be refused for typescript"));
        assert!(reason.contains("typescript"), "{reason}");
    }
}

#[test]
fn typescript_formats_only_where_prettier_is_installed() {
    let have = std::process::Command::new("prettier")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    assert_eq!(cwbhacker_runner::format::is_supported("typescript"), have);
    let out = cwbhacker_runner::format::format("typescript", HELLO).unwrap();
    if have {
        assert_eq!(out.problem, None);
        assert!(out.source.contains("hello"), "{}", out.source);
    } else {
        assert_eq!(out.source, HELLO);
        assert!(!out.changed);
        assert!(out.problem.unwrap().contains("prettier"));
    }
}

/// SPEC §1: the three files the runner writes and the one `tsc` emits, and
/// nothing else, all inside the attempt directory.
#[test]
fn the_runner_writes_only_under_the_home_it_was_given() {
    if !installed() {
        return;
    }
    let home = tempfile::tempdir().unwrap();
    let spec = stdio(serde_json::json!([
        { "name": "greets", "stdin": "", "expect": "hello, causewaybay\n", "visible": true }
    ]));
    let submission = Submission {
        attempt_id: "att_footprint",
        lang: "typescript",
        source: HELLO,
        spec: &spec,
        workdir: home.path().join("build/typescript/att_footprint"),
        cache_root: home.path().join("build/typescript"),
        events: cwbhacker_runner::no_events(),
    };
    let report = cwbhacker_runner::run(&submission);
    assert_eq!(report.verdict, Verdict::Accepted, "{}", report.compiler_stderr);
    let mut entries: Vec<String> = std::fs::read_dir(home.path().join("build/typescript/att_footprint"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
        .collect();
    entries.sort();
    assert_eq!(
        entries,
        vec!["main.js", "main.ts", "node.d.ts", "tsconfig.json"],
        "the attempt directory grew: {entries:?}"
    );
}
