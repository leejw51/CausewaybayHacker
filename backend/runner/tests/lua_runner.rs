//! The Lua runner against the real `luajit` (SPEC §5, §9.6).
//!
//! The same limits every land is held to, plus what is Lua's own: a syntax
//! error is caught by the bytecode step and is a `compile_error` with the
//! parser's line, and a program that runs and follows a `nil` dies of
//! `attempt to index … (a nil value)`, which is a `runtime_error` whose line
//! is the player's. Both are asserted through §7.1's classifier, so the
//! `lua:` column is tested on real output.
//!
//! Every test returns early on a machine without `luajit`;
//! `the_gate_agrees_with_the_probe` runs everywhere and pins what such a
//! machine is told instead.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

use cwbhacker_core::mistakes;
use cwbhacker_runner::{Event, Submission, TestSpec, Verdict};

fn installed() -> bool {
    cwbhacker_runner::lua::is_installed()
}

fn spec(json: serde_json::Value) -> TestSpec {
    TestSpec::parse(&json).expect("spec parses")
}

fn stdio(cases: serde_json::Value) -> TestSpec {
    spec(serde_json::json!({
        "harness": "stdio",
        "timeout_ms": 5000,
        "compile_timeout_ms": 30000,
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
        attempt_id: "att_lua_test",
        lang: "lua",
        source,
        spec,
        workdir: tmp.path().join("build/lua/att_lua_test"),
        cache_root: tmp.path().join("build/lua"),
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

/// The two stdin idioms: all of it at once, and a line at a time.
#[test]
fn stdin_reaches_a_lua_program_both_ways() {
    if !installed() {
        return;
    }
    let cases = serde_json::json!([
        { "name": "sample", "stdin": "3\n1 2 3\n", "expect": "6\n", "visible": true },
        { "name": "bigger", "stdin": "5\n10 20 30 40 50\n", "expect": "150\n", "visible": false }
    ]);
    for source in [
        "local input = io.read(\"*a\")\n\
         local nums = {}\n\
         for tok in input:gmatch(\"%S+\") do nums[#nums + 1] = tonumber(tok) end\n\
         local total = 0\n\
         for i = 2, nums[1] + 1 do total = total + nums[i] end\n\
         print(total)\n",
        "local n = tonumber(io.read(\"*l\"))\n\
         local total = 0\n\
         for tok in io.read(\"*l\"):gmatch(\"%S+\") do total = total + tonumber(tok) end\n\
         io.write(total, \"\\n\")\n",
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
        assert!(
            run.report.cases[1].got.is_none(),
            "a hidden case keeps its data"
        );
    }
}

#[test]
fn a_wrong_answer_is_a_wrong_answer_not_a_crash() {
    if !installed() {
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

/// The bytecode step is the compile phase: a program that does not parse
/// never runs, and the line is the parser's.
#[test]
fn a_syntax_error_is_compile_error_and_classifies() {
    if !installed() {
        return;
    }
    let run = run("local x = 1\nlocal y = = 2\nprint(x + y)\n", &one_case());
    assert_eq!(run.report.verdict, Verdict::CompileError);
    assert_eq!(
        run.stages,
        vec!["compiling"],
        "a rejected program never runs"
    );
    assert!(
        run.report.compiler_stderr.contains("main.lua:2:"),
        "{}",
        run.report.compiler_stderr
    );
    let found = mistakes::classify_compile("lua", &run.report.compiler_stderr);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].kind, "syntax");
    assert_eq!(found[0].code.as_deref(), Some("lua:syntax"));
    assert_eq!(found[0].line, Some(2));
    assert!(!run.report.compiler_stderr.contains("stack traceback"));
}

/// The land's own failures: a nil followed, a global that was never
/// defined, a type that does not add. Each is a `runtime_error` with the
/// player's line, and each files under its own identity.
#[test]
fn runtime_errors_classify_by_what_was_tried_on_what() {
    if !installed() {
        return;
    }
    let cases = serde_json::json!([
        { "name": "any", "stdin": "3\n", "expect": "x\n", "visible": true }
    ]);
    let nil = run(
        "local n = tonumber(io.read(\"*l\"))\nlocal root = { value = n }\nprint(root.left.value)\n",
        &stdio(cases.clone()),
    );
    assert_eq!(
        nil.report.verdict,
        Verdict::RuntimeError,
        "{}",
        nil.report.runtime_stderr
    );
    assert_eq!(nil.report.exit_code, Some(1));
    let found = mistakes::classify_runtime("lua", &nil.report.runtime_stderr);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].kind, "nil-deref");
    assert_eq!(found[0].code.as_deref(), Some("lua:index-nil"));
    assert_eq!(found[0].line, Some(3));
    assert!(
        found[0].message.contains("attempt to index"),
        "{}",
        found[0].message
    );

    let global = run(
        "local n = tonumber(io.read(\"*l\"))\nprint(totl + n)\n",
        &stdio(cases.clone()),
    );
    assert_eq!(global.report.verdict, Verdict::RuntimeError);
    let found = mistakes::classify_runtime("lua", &global.report.runtime_stderr);
    assert_eq!(found[0].kind, "unknown-name", "{found:?}");
    assert_eq!(found[0].code.as_deref(), Some("lua:undefined-global"));
    assert_eq!(found[0].line, Some(2));

    let call = run(
        "local n = tonumber(io.read(\"*l\"))\ngreet(n)\n",
        &stdio(cases.clone()),
    );
    let found = mistakes::classify_runtime("lua", &call.report.runtime_stderr);
    assert_eq!(found[0].kind, "unknown-name", "{found:?}");

    let compare = run(
        "local n = io.read(\"*l\")\nif n < 5 then print(\"small\") end\n",
        &stdio(cases.clone()),
    );
    assert_eq!(compare.report.verdict, Verdict::RuntimeError);
    let found = mistakes::classify_runtime("lua", &compare.report.runtime_stderr);
    assert_eq!(found[0].kind, "type-mismatch", "{found:?}");
    assert_eq!(found[0].code.as_deref(), Some("lua:compare-type"));

    let raised = run(
        "local n = tonumber(io.read(\"*l\"))\nif n > 2 then error(\"no such lantern\") end\n",
        &stdio(cases),
    );
    assert_eq!(raised.report.verdict, Verdict::RuntimeError);
    let found = mistakes::classify_runtime("lua", &raised.report.runtime_stderr);
    assert_eq!(found[0].kind, "unhandled-error", "{found:?}");
    assert_eq!(found[0].code.as_deref(), Some("lua:error"));
    assert_eq!(found[0].message, "no such lantern");
}

/// Deep recursion is the one failure that is an algorithm, not a crash.
#[test]
fn a_stack_overflow_is_filed_as_a_wrong_answer() {
    if !installed() {
        return;
    }
    let run = run(
        "local function depth(n) if n == 0 then return 0 end return 1 + depth(n - 1) end\nprint(depth(1000000))\n",
        &one_case(),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::RuntimeError,
        "{}",
        run.report.runtime_stderr
    );
    let found = mistakes::classify_runtime("lua", &run.report.runtime_stderr);
    assert_eq!(found[0].kind, "wrong-answer", "{found:?}");
    assert_eq!(found[0].code.as_deref(), Some("lua:stack-overflow"));
}

#[test]
fn a_timeout_is_killed_and_stops_the_sheet() {
    if !installed() {
        return;
    }
    let started = Instant::now();
    let run = run(
        "while true do end\n",
        &spec(serde_json::json!({
            "harness": "stdio",
            "timeout_ms": 1000,
            "compile_timeout_ms": 30000,
            "cases": [
                { "name": "a", "stdin": "", "expect": "x", "visible": true },
                { "name": "b", "stdin": "", "expect": "x", "visible": false }
            ]
        })),
    );
    assert_eq!(run.report.verdict, Verdict::Timeout);
    assert!(
        started.elapsed().as_secs() < 30,
        "the second case must not be run after a timeout"
    );
    assert!(!run.report.cases[1].passed);
}

#[test]
fn output_past_the_cap_is_output_limit() {
    if !installed() {
        return;
    }
    let run = run(
        "for i = 1, 200000 do print(\"causewaybay\") end\n",
        &spec(serde_json::json!({
            "harness": "stdio",
            "timeout_ms": 5000,
            "compile_timeout_ms": 30000,
            "max_stdout_bytes": 4096,
            "cases": [{ "name": "a", "stdin": "", "expect": "x", "visible": true }]
        })),
    );
    assert_eq!(run.report.verdict, Verdict::OutputLimit);
}

/// The scratch stays inside the attempt (§1): the source, the bytecode the
/// check wrote, and nothing anywhere else.
#[test]
fn the_attempt_directory_holds_the_source_and_the_bytecode() {
    if !installed() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let submission = Submission {
        attempt_id: "att_lua_dir",
        lang: "lua",
        source: HELLO,
        spec: &one_case(),
        workdir: tmp.path().join("build/lua/att_lua_dir"),
        cache_root: tmp.path().join("build/lua"),
        events: cwbhacker_runner::no_events(),
    };
    let report = cwbhacker_runner::run(&submission);
    assert_ne!(
        report.verdict,
        Verdict::InternalError,
        "{}",
        report.runtime_stderr
    );
    assert!(submission.workdir.join("main.lua").is_file());
    assert!(submission.workdir.join("main.luac").is_file());
    let outside: Vec<_> = std::fs::read_dir(tmp.path().join("build/lua"))
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    assert_eq!(outside, vec!["att_lua_dir".to_string()]);
}

#[test]
fn the_other_harnesses_are_refused() {
    if !installed() {
        return;
    }
    for harness in ["cargo", "gotest"] {
        let run = run(
            HELLO,
            &spec(serde_json::json!({ "harness": harness, "timeout_ms": 5000, "cases": [] })),
        );
        assert_eq!(run.report.verdict, Verdict::InternalError);
        assert!(run.report.runtime_stderr.contains("not a lua harness"));
    }
}

/// Runs everywhere: what the gate says must match what the probe says.
#[test]
fn the_gate_agrees_with_the_probe() {
    let stdio = one_case();
    let refused = cwbhacker_runner::unsupported("lua", &stdio, std::path::Path::new(""));
    if installed() {
        assert_eq!(refused, None, "luajit is here, so the land is open");
    } else {
        let why = refused.expect("no luajit, so the land is refused");
        assert!(why.contains("luajit"), "{why}");
    }
    let gotest = spec(serde_json::json!({ "harness": "gotest", "timeout_ms": 5000, "cases": [] }));
    assert!(cwbhacker_runner::unsupported("lua", &gotest, std::path::Path::new("")).is_some());
    let row = cwbhacker_runner::format::toolchains()
        .into_iter()
        .find(|t| t.land == "lua")
        .expect("the toolchain report has a lua row");
    assert_eq!(row.compiler, "luajit", "luajit, never lua");
    assert_eq!(row.formatter, "stylua");
    assert_eq!(row.compiles, installed());
    assert_eq!(row.formats, cwbhacker_runner::format::is_supported("lua"));
}

/// Lua's formatter is not in the box: the answer is whatever the machine
/// says, and a machine without `stylua` refuses without touching the source.
#[test]
fn the_formatter_is_stylua_or_an_honest_refusal() {
    let untidy = "local function main()\nlocal x=1\nprint( x )\nend\nmain()\n";
    let out = cwbhacker_runner::format::format("lua", untidy).unwrap();
    if cwbhacker_runner::format::is_supported("lua") {
        assert!(out.changed, "{out:?}");
        assert!(out.source.contains("local x = 1"), "{}", out.source);
        let broken = "local function main(\nlocal x = 1\n";
        let out = cwbhacker_runner::format::format("lua", broken).unwrap();
        assert_eq!(out.source, broken);
        assert!(out.problem.is_some());
    } else {
        assert!(!out.changed);
        assert_eq!(out.source, untidy);
        assert!(
            out.problem.as_deref().unwrap_or("").contains("stylua"),
            "{out:?}"
        );
    }
}
