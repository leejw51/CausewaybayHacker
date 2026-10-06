//! The Zig runner against the real `zig` (SPEC §5, §9.6).
//!
//! The same limits every land is held to, plus what is Zig's own: a program
//! `zig` rejects is a `compile_error` with the message on the player's line,
//! and a program that compiles and then trips one of Debug's safety checks —
//! an index past the end, an optional unwrapped while null — is a
//! `runtime_error` whose `panic:` names the check. Both are asserted through
//! §7.1's classifier, so the `zig:` column is tested on real output.
//!
//! Every test returns early on a machine without `zig`, as the TypeScript
//! tests do without `tsc`; `the_gate_agrees_with_the_probe` runs everywhere
//! and pins what such a machine is told instead.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

use cwbhacker_core::mistakes;
use cwbhacker_runner::{Event, Submission, TestSpec, Verdict};

fn installed() -> bool {
    cwbhacker_runner::zig::is_installed()
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

/// One temporary home per test, so the global zig cache is warm across the
/// cases of a test and every test starts from nothing.
fn run_in(tmp: &std::path::Path, source: &str, spec: &TestSpec) -> Run {
    let logs = Arc::new(AtomicUsize::new(0));
    let stages = Arc::new(std::sync::Mutex::new(Vec::new()));
    let (l, s) = (logs.clone(), stages.clone());
    let attempt = format!("att_zig_{}", logs.as_ref() as *const _ as usize);
    let submission = Submission {
        attempt_id: &attempt,
        lang: "zig",
        source,
        spec,
        workdir: tmp.join("build/zig").join(&attempt),
        cache_root: tmp.join("build/zig"),
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

fn run(source: &str, spec: &TestSpec) -> Run {
    let tmp = tempfile::tempdir().unwrap();
    run_in(tmp.path(), source, spec)
}

/// The stdout idiom every quest uses: a buffered writer, flushed.
const HELLO: &str = "const std = @import(\"std\");\n\
pub fn main(init: std.process.Init) !void {\n\
    var buf: [256]u8 = undefined;\n\
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);\n\
    const w = &out.interface;\n\
    try w.print(\"hello, causewaybay\\n\", .{});\n\
    try w.flush();\n\
}\n";

/// Reads every integer on stdin, prints their sum.
const SUM: &str = "const std = @import(\"std\");\n\
pub fn main(init: std.process.Init) !void {\n\
    var in_buf: [4096]u8 = undefined;\n\
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_buf);\n\
    const input = try stdin.interface.allocRemaining(init.gpa, .unlimited);\n\
    defer init.gpa.free(input);\n\
    var out_buf: [256]u8 = undefined;\n\
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buf);\n\
    const w = &out.interface;\n\
    defer w.flush() catch {};\n\
    var it = std.mem.tokenizeAny(u8, input, \" \\n\");\n\
    const n = try std.fmt.parseInt(usize, it.next().?, 10);\n\
    var total: i64 = 0;\n\
    var i: usize = 0;\n\
    while (i < n) : (i += 1) total += try std.fmt.parseInt(i64, it.next().?, 10);\n\
    try w.print(\"{d}\\n\", .{total});\n\
}\n";

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

#[test]
fn stdin_reaches_a_zig_program() {
    if !installed() {
        return;
    }
    let run = run(
        SUM,
        &stdio(serde_json::json!([
            { "name": "sample", "stdin": "3\n1 2 3\n", "expect": "6\n", "visible": true },
            { "name": "bigger", "stdin": "5\n10 20 30 40 50\n", "expect": "150\n", "visible": false }
        ])),
    );
    assert_eq!(
        run.report.verdict,
        Verdict::Accepted,
        "{}\n{}",
        run.report.compiler_stderr,
        run.report.runtime_stderr
    );
    assert_eq!(run.report.tests_passed, 2);
    // The hidden case keeps its data to itself (§5.2).
    assert!(run.report.cases[1].stdin.is_none());
    assert!(run.report.cases[1].got.is_none());
}

#[test]
fn a_wrong_answer_is_a_wrong_answer_not_a_crash() {
    if !installed() {
        return;
    }
    let run = run(
        &HELLO.replace("hello, causewaybay", "goodbye"),
        &stdio(serde_json::json!([
            { "name": "greets", "stdin": "", "expect": "hello, causewaybay\n", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::WrongAnswer);
    assert_eq!(run.report.cases[0].got.as_deref(), Some("goodbye\n"));
}

/// `std.debug.print` goes to stderr, which is the mistake the land's tips
/// warn about first: the program runs, prints, and the judge sees nothing.
#[test]
fn debug_print_is_stderr_and_so_a_wrong_answer() {
    if !installed() {
        return;
    }
    let run = run(
        "const std = @import(\"std\");\n\
         pub fn main() void {\n\
             std.debug.print(\"hello, causewaybay\\n\", .{});\n\
         }\n",
        &stdio(serde_json::json!([
            { "name": "greets", "stdin": "", "expect": "hello, causewaybay\n", "visible": true }
        ])),
    );
    assert_eq!(run.report.verdict, Verdict::WrongAnswer);
    assert_eq!(run.report.cases[0].got.as_deref(), Some(""));
    assert!(
        run.report.runtime_stderr.contains("hello, causewaybay"),
        "the greeting went to stderr: {:?}",
        run.report.runtime_stderr
    );
}

/// A type error never runs, and its identity is the message's shape on the
/// player's line. An unused local is a compile error in Zig, and the land
/// files it as `unused`.
#[test]
fn a_type_error_is_compile_error_and_classifies() {
    if !installed() {
        return;
    }
    let typed = run(
        "const std = @import(\"std\");\n\
         pub fn main() void {\n\
             const fare: i32 = \"twelve\";\n\
             std.debug.print(\"{d}\\n\", .{fare});\n\
         }\n",
        &one_case(),
    );
    assert_eq!(typed.report.verdict, Verdict::CompileError);
    assert_eq!(
        typed.stages,
        vec!["compiling"],
        "a rejected program never runs"
    );
    assert!(
        typed.report.compiler_stderr.contains("main.zig:3:"),
        "{}",
        typed.report.compiler_stderr
    );
    let found = mistakes::classify_compile("zig", &typed.report.compiler_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "type-mismatch" && m.code.as_deref() == Some("zig:expected-type")),
        "{found:?}"
    );
    assert_eq!(found[0].line, Some(3));

    let unused = run(
        "pub fn main() void {\n    var count: i32 = 0;\n}\n",
        &one_case(),
    );
    assert_eq!(unused.report.verdict, Verdict::CompileError);
    let found = mistakes::classify_compile("zig", &unused.report.compiler_stderr);
    assert!(
        found.iter().any(|m| m.kind == "unused"),
        "{found:?}\n{}",
        unused.report.compiler_stderr
    );
}

/// The other half of the land: a program that compiles and then trips a
/// Debug safety check dies naming the check, on the player's line.
#[test]
fn a_safety_panic_is_runtime_error_and_classifies() {
    if !installed() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let oob = run_in(
        tmp.path(),
        "const std = @import(\"std\");\n\
         pub fn main(init: std.process.Init) !void {\n\
             var in_buf: [64]u8 = undefined;\n\
             var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_buf);\n\
             const input = try stdin.interface.allocRemaining(init.gpa, .unlimited);\n\
             const n = try std.fmt.parseInt(usize, std.mem.trim(u8, input, \" \\n\"), 10);\n\
             const xs = [_]i32{ 1, 2, 3 };\n\
             std.debug.print(\"{d}\\n\", .{xs[n]});\n\
         }\n",
        &stdio(serde_json::json!([
            { "name": "past", "stdin": "3\n", "expect": "x\n", "visible": true }
        ])),
    );
    assert_eq!(
        oob.report.verdict,
        Verdict::RuntimeError,
        "{}\n{}",
        oob.report.compiler_stderr,
        oob.report.runtime_stderr
    );
    assert!(
        oob.report.runtime_stderr.contains("index out of bounds"),
        "{}",
        oob.report.runtime_stderr
    );
    let found = mistakes::classify_runtime("zig", &oob.report.runtime_stderr);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].kind, "index-range");
    assert_eq!(found[0].code.as_deref(), Some("zig:index-out-of-bounds"));
    assert_eq!(
        found[0].line,
        Some(8),
        "the player's frame, not the runtime's"
    );

    let null = run_in(
        tmp.path(),
        "const std = @import(\"std\");\n\
         pub fn main(init: std.process.Init) !void {\n\
             var in_buf: [64]u8 = undefined;\n\
             var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_buf);\n\
             const input = try stdin.interface.allocRemaining(init.gpa, .unlimited);\n\
             const child: ?i32 = if (input.len > 4) 1 else null;\n\
             std.debug.print(\"{d}\\n\", .{child.?});\n\
         }\n",
        &stdio(serde_json::json!([
            { "name": "null", "stdin": "\n", "expect": "x\n", "visible": true }
        ])),
    );
    assert_eq!(null.report.verdict, Verdict::RuntimeError);
    let found = mistakes::classify_runtime("zig", &null.report.runtime_stderr);
    assert_eq!(found[0].kind, "nil-deref", "{found:?}");
    assert_eq!(found[0].code.as_deref(), Some("zig:null-unwrap"));

    // An error `main` returned and nobody handled.
    let returned = run_in(
        tmp.path(),
        "const std = @import(\"std\");\n\
         pub fn main() !void {\n\
             const n = try std.fmt.parseInt(i64, \"x1\", 10);\n\
             std.debug.print(\"{d}\\n\", .{n});\n\
         }\n",
        &one_case(),
    );
    assert_eq!(returned.report.verdict, Verdict::RuntimeError);
    assert_eq!(returned.report.exit_code, Some(1));
    let found = mistakes::classify_runtime("zig", &returned.report.runtime_stderr);
    assert_eq!(found[0].kind, "unhandled-error", "{found:?}");
    assert_eq!(found[0].code.as_deref(), Some("zig:error-returned"));
}

#[test]
fn a_timeout_is_killed_and_stops_the_sheet() {
    if !installed() {
        return;
    }
    let started = Instant::now();
    let run = run(
        "pub fn main() void {\n    while (true) {}\n}\n",
        &spec(serde_json::json!({
            "harness": "stdio",
            "timeout_ms": 1000,
            "compile_timeout_ms": 60000,
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
        "const std = @import(\"std\");\n\
         pub fn main(init: std.process.Init) !void {\n\
             var buf: [4096]u8 = undefined;\n\
             var out = std.Io.File.stdout().writerStreaming(init.io, &buf);\n\
             const w = &out.interface;\n\
             var i: usize = 0;\n\
             while (i < 200000) : (i += 1) try w.print(\"causewaybay\\n\", .{});\n\
             try w.flush();\n\
         }\n",
        &spec(serde_json::json!({
            "harness": "stdio",
            "timeout_ms": 5000,
            "compile_timeout_ms": 60000,
            "max_stdout_bytes": 4096,
            "cases": [{ "name": "a", "stdin": "", "expect": "x", "visible": true }]
        })),
    );
    assert_eq!(run.report.verdict, Verdict::OutputLimit);
}

/// The compile cache is the land's, not the attempt's: the second attempt
/// in the same home compiles against a warm `std`, and both attempts leave
/// their scratch inside their own directories (§1).
#[test]
fn the_global_cache_lives_under_the_land_and_the_local_one_under_the_attempt() {
    if !installed() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let first = run_in(tmp.path(), HELLO, &one_case());
    assert_ne!(first.report.verdict, Verdict::InternalError);
    assert!(
        tmp.path().join("build/zig/zig-global").is_dir(),
        "the global cache is under the land's cache root"
    );
    let attempts: Vec<_> = std::fs::read_dir(tmp.path().join("build/zig"))
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().starts_with("att_zig_"))
        .collect();
    assert_eq!(attempts.len(), 1);
    assert!(attempts[0].path().join("zig-cache").is_dir());
    assert!(attempts[0].path().join("prog").is_file());
    let second = run_in(tmp.path(), HELLO, &one_case());
    assert!(
        second.report.compile_ms <= first.report.compile_ms.max(1500),
        "the second compile ({} ms) should be no slower than the first ({} ms)",
        second.report.compile_ms,
        first.report.compile_ms
    );
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
        assert!(run.report.runtime_stderr.contains("not a zig harness"));
    }
}

/// Runs everywhere: what the gate says must match what the probe says.
#[test]
fn the_gate_agrees_with_the_probe() {
    let stdio = one_case();
    let refused = cwbhacker_runner::unsupported("zig", &stdio, std::path::Path::new(""));
    if installed() {
        assert_eq!(refused, None, "zig is here, so the land is open");
    } else {
        let why = refused.expect("no zig, so the land is refused");
        assert!(why.contains("zig"), "{why}");
        assert!(why.contains("0.16"), "the hint names the version: {why}");
    }
    let cargo = spec(serde_json::json!({ "harness": "cargo", "timeout_ms": 5000, "cases": [] }));
    assert!(cwbhacker_runner::unsupported("zig", &cargo, std::path::Path::new("")).is_some());
    // The boot report has a row, and it agrees with the formatter gate.
    let row = cwbhacker_runner::format::toolchains()
        .into_iter()
        .find(|t| t.land == "zig")
        .expect("the toolchain report has a zig row");
    assert_eq!(row.compiler, "zig");
    assert_eq!(row.formatter, "zig fmt");
    assert_eq!(row.compiles, installed());
    assert_eq!(row.formats, cwbhacker_runner::format::is_supported("zig"));
}

/// `zig fmt` ships with `zig`, so a land that runs can format; and it
/// refuses a file it cannot parse without touching it.
#[test]
fn zig_fmt_formats_and_refuses_cleanly() {
    if !installed() {
        return;
    }
    let out =
        cwbhacker_runner::format::format("zig", "pub fn main() void {const x=1;_=x;}\n").unwrap();
    assert!(out.changed, "{:?}", out);
    assert!(out.source.contains("    const x = 1;"), "{}", out.source);
    assert!(out.problem.is_none());
    let broken = "pub fn main() void { const x = = 1; }\n";
    let out = cwbhacker_runner::format::format("zig", broken).unwrap();
    assert!(!out.changed);
    assert_eq!(out.source, broken);
    assert!(out.problem.is_some(), "it must say why");
}
