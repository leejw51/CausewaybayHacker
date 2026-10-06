//! The real runner against the real `rustc` (SPEC §5, §9.6).
//!
//! These compile and run actual programs. They are slow by the standards of a
//! unit test and they are the only thing that proves the limits work: a
//! timeout that is only asserted in a comment is not a timeout.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

use cwbhacker_runner::{Event, Submission, TestSpec, Verdict};

fn spec(json: serde_json::Value) -> TestSpec {
    TestSpec::parse(&json).expect("spec parses")
}

struct Harness {
    _tmp: tempfile::TempDir,
    workdir: std::path::PathBuf,
    cache: std::path::PathBuf,
}

fn harness() -> Harness {
    let tmp = tempfile::tempdir().unwrap();
    let workdir = tmp.path().join("build/rust/att_test");
    let cache = tmp.path().join("build/rust");
    Harness {
        _tmp: tmp,
        workdir,
        cache,
    }
}

fn run(source: &str, spec: &TestSpec) -> cwbhacker_runner::Report {
    run_counting(source, spec).0
}

fn run_counting(source: &str, spec: &TestSpec) -> (cwbhacker_runner::Report, usize, Vec<String>) {
    let h = harness();
    let logs = Arc::new(AtomicUsize::new(0));
    let stages = Arc::new(std::sync::Mutex::new(Vec::new()));
    let (l, s) = (logs.clone(), stages.clone());
    let submission = Submission {
        attempt_id: "att_test",
        lang: "rust",
        source,
        spec,
        workdir: h.workdir.clone(),
        cache_root: h.cache.clone(),
        events: Arc::new(move |event| match event {
            Event::Log { .. } => {
                l.fetch_add(1, Ordering::Relaxed);
            }
            Event::Stage(stage) => s.lock().unwrap().push(stage.to_string()),
        }),
    };
    let report = cwbhacker_runner::run(&submission);
    let stages = stages.lock().unwrap().clone();
    (report, logs.load(Ordering::Relaxed), stages)
}

fn stdio(cases: serde_json::Value) -> TestSpec {
    spec(serde_json::json!({
        "harness": "stdio",
        "timeout_ms": 5000,
        "match": "trim",
        "cases": cases,
    }))
}

#[test]
fn a_correct_program_is_accepted_and_streams_its_stages() {
    let (report, _logs, stages) = run_counting(
        "fn main() { println!(\"hello, causewaybay\"); }",
        &stdio(serde_json::json!([
            { "name": "greets", "stdin": "", "expect": "hello, causewaybay\n", "visible": true }
        ])),
    );
    assert_eq!(
        report.verdict,
        Verdict::Accepted,
        "{}",
        report.compiler_stderr
    );
    assert_eq!(report.tests_passed, 1);
    assert_eq!(report.tests_total, 1);
    assert_eq!(stages, vec!["compiling", "running", "judging"]);
    assert_eq!(report.cases[0].got.as_deref(), Some("hello, causewaybay\n"));
}

#[test]
fn a_hidden_case_never_carries_its_data() {
    let report = run(
        "fn main() { println!(\"wrong\"); }",
        &stdio(serde_json::json!([
            { "name": "shown",  "stdin": "", "expect": "right\n", "visible": true },
            { "name": "hidden", "stdin": "", "expect": "right\n", "visible": false }
        ])),
    );
    assert_eq!(report.verdict, Verdict::WrongAnswer);
    // Both cases ran: a wrong answer is worth finishing the sheet for.
    assert_eq!(report.cases.len(), 2);
    assert!(report.cases[0].expect.is_some());
    assert!(report.cases[1].expect.is_none());
    assert!(report.cases[1].got.is_none());
    assert!(report.cases[1].stdin.is_none());
}

#[test]
fn trim_matching_forgives_a_trailing_newline() {
    let report = run(
        "fn main() { print!(\"6\"); }",
        &stdio(serde_json::json!([
            { "name": "sum", "stdin": "", "expect": "6\n", "visible": true }
        ])),
    );
    assert_eq!(report.verdict, Verdict::Accepted);
}

#[test]
fn stdin_reaches_the_program() {
    let source = r#"
use std::io::Read;
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let mut parts = input.split_whitespace();
    let n: usize = parts.next().unwrap().parse().unwrap();
    let total: i64 = parts.take(n).map(|t| t.parse::<i64>().unwrap()).sum();
    println!("{total}");
}
"#;
    let report = run(
        source,
        &stdio(serde_json::json!([
            { "name": "sample", "stdin": "3\n1 2 3\n", "expect": "6\n", "visible": true },
            { "name": "bigger", "stdin": "5\n10 20 30 40 50\n", "expect": "150\n", "visible": false }
        ])),
    );
    assert_eq!(
        report.verdict,
        Verdict::Accepted,
        "{}",
        report.runtime_stderr
    );
    assert_eq!(report.tests_passed, 2);
}

/// SPEC §7.1 through the real compiler: the classification has to work on what
/// `rustc` actually emits, not on what a fixture says it emits.
#[test]
fn a_type_mismatch_is_a_compile_error_classified_as_type_mismatch() {
    let report = run(
        "fn main() { let x: i32 = \"not a number\"; println!(\"{x}\"); }",
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "", "visible": true }
        ])),
    );
    assert_eq!(report.verdict, Verdict::CompileError);
    let found = cwbhacker_core::mistakes::classify_rust_json(&report.compiler_stderr);
    assert!(
        found
            .iter()
            .any(|m| m.kind == "type-mismatch" && m.code.as_deref() == Some("E0308")),
        "expected E0308, got {found:?}"
    );
    assert!(found.iter().all(|m| m.line.is_some()), "spans are lost");
}

#[test]
fn a_move_error_is_classified_as_borrow_after_move() {
    let source = r#"
fn main() {
    let s = String::from("x");
    let t = s;
    println!("{s} {t}");
}
"#;
    let report = run(
        source,
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "", "visible": true }
        ])),
    );
    assert_eq!(report.verdict, Verdict::CompileError);
    let found = cwbhacker_core::mistakes::classify_rust_json(&report.compiler_stderr);
    assert!(
        found.iter().any(|m| m.kind == "borrow-after-move"),
        "expected borrow-after-move, got {found:?}"
    );
}

#[test]
fn an_unused_variable_is_a_mistake_on_a_program_that_works() {
    let report = run(
        "fn main() { let unused_thing = 3; println!(\"ok\"); }",
        &stdio(serde_json::json!([
            { "name": "ok", "stdin": "", "expect": "ok\n", "visible": true }
        ])),
    );
    assert_eq!(report.verdict, Verdict::Accepted);
    let found = cwbhacker_core::mistakes::classify_rust_json(&report.compiler_stderr);
    assert!(
        found.iter().any(|m| m.kind == "unused"),
        "a warning on an accepted attempt is still a mistake: {found:?}"
    );
}

#[test]
fn an_infinite_loop_times_out_and_does_not_hang_the_runner() {
    let started = Instant::now();
    let report = run(
        "fn main() { loop { std::hint::spin_loop(); } }",
        &spec(serde_json::json!({
            "harness": "stdio",
            "timeout_ms": 700,
            "match": "trim",
            "cases": [ { "name": "spins", "stdin": "", "expect": "", "visible": true } ]
        })),
    );
    assert_eq!(report.verdict, Verdict::Timeout);
    assert!(
        started.elapsed().as_secs() < 30,
        "the runner waited far longer than the timeout"
    );
}

#[test]
fn a_child_that_outlives_the_parent_dies_with_the_process_group() {
    // The program leaves a long sleep behind and then spins. If the group kill
    // were a plain kill on the pid, the sleep would hold the pipe open and
    // this test would sit here for thirty seconds.
    let source = r#"
fn main() {
    let _ = std::process::Command::new("/bin/sleep").arg("30").spawn();
    loop { std::hint::spin_loop(); }
}
"#;
    let started = Instant::now();
    let report = run(
        source,
        &spec(serde_json::json!({
            "harness": "stdio",
            "timeout_ms": 700,
            "match": "trim",
            "cases": [ { "name": "spawns", "stdin": "", "expect": "", "visible": true } ]
        })),
    );
    assert_eq!(report.verdict, Verdict::Timeout);
    assert!(
        started.elapsed().as_secs() < 25,
        "the orphaned child kept the runner waiting: {:?}",
        started.elapsed()
    );
}

#[test]
fn too_much_output_is_an_output_limit_not_a_full_disk() {
    let report = run(
        "fn main() { loop { println!(\"{}\", \"x\".repeat(1024)); } }",
        &spec(serde_json::json!({
            "harness": "stdio",
            "timeout_ms": 10000,
            "max_stdout_bytes": 4096,
            "match": "trim",
            "cases": [ { "name": "floods", "stdin": "", "expect": "", "visible": true } ]
        })),
    );
    assert_eq!(report.verdict, Verdict::OutputLimit);
    assert!(
        report.cases[0].got.as_deref().unwrap_or("").len() <= 4096 + 1024,
        "the cap was applied after the fact, not while draining"
    );
}

#[test]
fn a_panic_is_a_runtime_error() {
    let report = run(
        "fn main() { let v: Vec<i32> = vec![1,2,3]; println!(\"{}\", v[7]); }",
        &stdio(serde_json::json!([
            { "name": "boom", "stdin": "", "expect": "", "visible": true }
        ])),
    );
    assert_eq!(report.verdict, Verdict::RuntimeError);
    let found = cwbhacker_core::mistakes::classify_runtime("rust", &report.runtime_stderr);
    assert!(found.iter().any(|m| m.kind == "index-range"), "{found:?}");
}

#[test]
fn the_compiler_streams_while_it_works() {
    let (_report, logs, _stages) = run_counting(
        "fn main() { let x: i32 = \"nope\"; }",
        &stdio(serde_json::json!([
            { "name": "any", "stdin": "", "expect": "", "visible": true }
        ])),
    );
    assert!(logs > 0, "no run.log chunks were emitted while compiling");
}

/// What is streamed on `compile` is what the player would see in a terminal
/// — the `rendered` text of each diagnostic, with its `^^^` under the span —
/// and not the JSON object rustc wrapped it in. The report's
/// `compiler_stderr` is a different thing and stays the raw JSON, because
/// classification (SPEC §7.1) reads that.
#[test]
fn the_compile_stream_is_rendered_text_and_not_rustc_json() {
    let h = harness();
    let compile = Arc::new(std::sync::Mutex::new(String::new()));
    let sink = compile.clone();
    let spec = stdio(serde_json::json!([
        { "name": "any", "stdin": "", "expect": "", "visible": true }
    ]));
    let submission = Submission {
        attempt_id: "att_test",
        lang: "rust",
        source: "fn main() { let x: i32 = \"nope\"; }",
        spec: &spec,
        workdir: h.workdir.clone(),
        cache_root: h.cache.clone(),
        events: Arc::new(move |event| {
            if let Event::Log { stream, chunk } = event {
                if stream == "compile" {
                    sink.lock().unwrap().push_str(&chunk);
                }
            }
        }),
    };
    let report = cwbhacker_runner::run(&submission);
    assert_eq!(report.verdict, Verdict::CompileError);

    let streamed = compile.lock().unwrap().clone();
    assert!(
        streamed.contains("error") && streamed.contains("^"),
        "the stream should read like rustc's terminal output: {streamed:?}"
    );
    assert!(
        !streamed.contains("$message_type") && !streamed.contains("\"rendered\""),
        "raw rustc JSON leaked into the compile stream: {streamed:?}"
    );
    assert!(
        report.compiler_stderr.trim_start().starts_with('{'),
        "compiler_stderr must stay the raw JSON for classification: {}",
        report.compiler_stderr
    );
}

/// Both test harnesses are built now (`cargo_harness.rs`, `gotest_harness.rs`).
/// What is still refused is a harness asked of the wrong land, and it refuses
/// cleanly rather than compiling the wrong thing and calling the answer wrong.
#[test]
fn a_harness_from_the_other_land_refuses_cleanly_rather_than_panicking() {
    let h = harness();
    let spec = spec(serde_json::json!({
        "harness": "gotest",
        "cases": [ { "name": "any", "stdin": "", "expect": "x", "visible": true } ]
    }));
    let submission = Submission {
        attempt_id: "att_gotest_in_rust",
        lang: "rust",
        source: "fn main() {}",
        spec: &spec,
        workdir: h.workdir.clone(),
        cache_root: h.cache.clone(),
        events: cwbhacker_runner::no_events(),
    };
    let report = cwbhacker_runner::run(&submission);
    assert_eq!(report.verdict, Verdict::InternalError);
    assert!(report.runtime_stderr.contains("not a rust harness"));
}

/// The capability check the server asks **before** it creates an attempt.
/// Getting this wrong is not a runner bug, it is a curriculum bug: an attempt
/// that should never have existed carries a verdict into `mistake_stats`.
#[test]
fn unsupported_names_what_this_build_cannot_judge() {
    let stdio_spec = stdio(serde_json::json!([
        { "name": "any", "stdin": "", "expect": "x", "visible": true }
    ]));
    assert_eq!(
        cwbhacker_runner::unsupported("rust", &stdio_spec, std::path::Path::new("")),
        None
    );

    // Both lands are built; the gate is open for stdio in either.
    assert_eq!(
        cwbhacker_runner::unsupported("go", &stdio_spec, std::path::Path::new("")),
        None
    );

    // The cargo harness is built: the gate is open for it in the Rust land…
    let cargo_spec = spec(serde_json::json!({
        "harness": "cargo",
        "cases": [ { "name": "any", "stdin": "", "expect": "x", "visible": true } ]
    }));
    assert_eq!(
        cwbhacker_runner::unsupported("rust", &cargo_spec, std::path::Path::new("")),
        None
    );
    // …and shut in the Go one, which is an authoring mistake, not a gap.
    assert!(cwbhacker_runner::unsupported("go", &cargo_spec, std::path::Path::new("")).is_some());

    assert!(
        cwbhacker_runner::unsupported("cobol", &stdio_spec, std::path::Path::new("")).is_some()
    );
}

// ---------------------------------------------------------------------------
// The crate shelf (SPEC §5.1): a stdio quest that names `crates`.
// ---------------------------------------------------------------------------

fn crate_spec(crates: serde_json::Value) -> TestSpec {
    spec(serde_json::json!({
        "harness": "stdio",
        "timeout_ms": 5000,
        "crates": crates,
        "cases": [
            { "name": "sum", "stdin": "[{\"amount\":30},{\"amount\":12}]\n", "expect": "TOTAL 42\n", "visible": true }
        ]
    }))
}

#[test]
fn a_crate_quest_is_refused_until_the_shelf_is_warm() {
    let tmp = tempfile::tempdir().unwrap();
    let s = crate_spec(serde_json::json!(["serde", "serde_json"]));
    let why = cwbhacker_runner::unsupported("rust", &s, tmp.path())
        .expect("a cold shelf refuses a crate quest before an attempt row exists");
    assert!(why.contains("cwbhacker warm"), "{why}");
    assert!(why.contains("FRAMEWORKS"), "{why}");
    // The same quest with no crates is a plain rustc build and needs nothing.
    let plain = spec(serde_json::json!({
        "harness": "stdio",
        "cases": [ { "name": "x", "stdin": "", "expect": "x", "visible": true } ]
    }));
    assert_eq!(
        cwbhacker_runner::unsupported("rust", &plain, tmp.path()),
        None
    );
    // A marker from exactly this shelf opens the road …
    std::fs::write(
        cwbhacker_runner::shelf::marker_path(tmp.path()),
        format!("{}\n", cwbhacker_runner::shelf::digest()),
    )
    .unwrap();
    assert_eq!(cwbhacker_runner::unsupported("rust", &s, tmp.path()), None);
    // … and crates stay a Rust key whatever the shelf's state.
    assert!(cwbhacker_runner::unsupported("go", &s, tmp.path())
        .unwrap()
        .contains("rust key"));
}

#[test]
fn a_crate_off_the_shelf_is_refused_at_parse() {
    let err = TestSpec::parse(&serde_json::json!({
        "harness": "stdio",
        "crates": ["serde", "diesel"],
        "cases": [ { "name": "x", "stdin": "", "expect": "x", "visible": true } ]
    }))
    .expect_err("diesel is not on the shelf");
    let text = format!("{err:?}");
    assert!(text.contains("diesel"), "{text}");
    assert!(
        text.contains("tokio"),
        "the refusal names the shelf: {text}"
    );
    // The key's shape is checked too.
    assert!(TestSpec::parse(&serde_json::json!({
        "harness": "stdio",
        "crates": "serde",
        "cases": [ { "name": "x", "stdin": "", "expect": "x", "visible": true } ]
    }))
    .is_err());
    // And a crate quest's compile budget is cargo's, not rustc's.
    let s = crate_spec(serde_json::json!(["tokio"]));
    assert_eq!(s.compile_timeout_ms, 60_000);
    assert_eq!(s.crates, vec!["tokio".to_string()]);
}

#[test]
fn the_bin_manifest_names_the_attempt_and_carries_the_whole_shelf() {
    let m = cwbhacker_runner::cargo::generated_bin_manifest("att_7", &["serde".to_string()]);
    assert!(m.contains("name = \"quest-att_7\""), "{m}");
    assert!(m.contains("[[bin]]"), "{m}");
    assert!(m.contains("path = \"src/main.rs\""), "{m}");
    assert!(!m.contains("[lib]"), "{m}");
    assert!(m.contains("[workspace]"), "{m}");
    // Every shelf crate, not the one the quest named: one dependency graph.
    for name in cwbhacker_runner::shelf::names() {
        assert!(m.contains(&format!("\n{name} = ")), "{name} missing:\n{m}");
    }
    // The library shape is unchanged, and still carries no dependencies.
    let lib = cwbhacker_runner::cargo::generated_manifest("att_7");
    assert!(
        lib.contains("[lib]") && !lib.contains("[dependencies]"),
        "{lib}"
    );
}

/// The real thing: the shelf warmed into a fresh cache (the network, and
/// the whole of `tokio` compiled), then a `serde_json` + `tokio` program
/// built offline against it and judged, then one that does not compile.
#[test]
#[ignore = "fetches and compiles the whole crate shelf; run it with --ignored"]
fn a_crate_quest_builds_against_the_warm_shelf_and_is_judged() {
    let h = harness();
    std::fs::create_dir_all(&h.cache).unwrap();
    cwbhacker_runner::shelf::warm(&h.cache, &|line| eprintln!("{line}")).expect("the shelf warms");
    assert!(cwbhacker_runner::shelf::is_warm(&h.cache));

    let s = crate_spec(serde_json::json!(["serde", "serde_json", "tokio"]));
    assert_eq!(cwbhacker_runner::unsupported("rust", &s, &h.cache), None);
    let source = r#"
use serde::Deserialize;
#[derive(Deserialize)]
struct Order { amount: i64 }
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut input = String::new();
    std::io::Read::read_to_string(&mut std::io::stdin(), &mut input)?;
    let orders: Vec<Order> = serde_json::from_str(&input)?;
    let total = tokio::spawn(async move { orders.iter().map(|o| o.amount).sum::<i64>() }).await?;
    println!("TOTAL {total}");
    Ok(())
}
"#;
    let run_in = |source: &str| {
        let stages = Arc::new(std::sync::Mutex::new(Vec::new()));
        let st = stages.clone();
        let submission = Submission {
            attempt_id: "att_shelf",
            lang: "rust",
            source,
            spec: &s,
            workdir: h.workdir.clone(),
            cache_root: h.cache.clone(),
            events: Arc::new(move |event| {
                if let Event::Stage(stage) = event {
                    st.lock().unwrap().push(stage.to_string())
                }
            }),
        };
        let _ = std::fs::remove_dir_all(&h.workdir);
        let report = cwbhacker_runner::run(&submission);
        let seen = stages.lock().unwrap().clone();
        (report, seen)
    };

    let (report, stages) = run_in(source);
    assert_eq!(report.verdict, Verdict::Accepted, "{report:?}");
    assert_eq!(report.tests_passed, 1);
    assert_eq!(stages, vec!["compiling", "running", "judging"]);
    assert!(
        h.workdir.join("prog").is_file(),
        "the binary moved into the attempt"
    );
    assert!(
        h.workdir.join("Cargo.lock").is_file(),
        "the shelf's lockfile was copied in"
    );

    // A type error in the player's file: compile_error, with rustc's JSON
    // kept for the classifier (E0308, as rustc spells it).
    let (report, _) = run_in(&source.replace("let total = tokio", "let total: String = tokio"));
    assert_eq!(report.verdict, Verdict::CompileError, "{report:?}");
    assert!(
        report.compiler_stderr.contains("E0308"),
        "{}",
        report.compiler_stderr
    );
}
