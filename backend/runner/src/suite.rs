//! The test-harness case loop, shared by `cargo` and `gotest` (SPEC §5.2).
//!
//! `harness.rs` is the same idea for `stdio`: once the toolchain has produced
//! a binary, turning what it did into a verdict is the same job in both lands,
//! and two copies of that loop would drift. This module is the second one —
//! **not** because the rule was relaxed, but because a test harness judges a
//! different thing. The stdio loop compares bytes on stdout; this one asks the
//! test runner which named tests passed. Sharing *this* between `cargo` and
//! `gotest` is what stops `tests::adds` being forgiven a skip in one land and
//! not the other.
//!
//! Three rules live here and nowhere else, because all three are ways a node
//! could otherwise be cleared without writing a working test:
//!
//! 1. **A suite that ran no tests never passes.** `cargo test` on a file with
//!    no `#[test]` prints `test result: ok. 0 passed` and exits 0; `go test`
//!    on a file with no `TestXxx` says `no tests to run` and exits 0. Left
//!    alone, an empty submission clears every quest on these harnesses, which
//!    is exactly the hole SPEC §12's "no `expect` may be empty" closes for
//!    stdio.
//! 2. **A skipped or ignored test did not pass.** Otherwise `#[ignore]` and
//!    `t.Skip()` are a cheat code for the one test that was failing.
//! 3. **A test the quest asked for and cannot find is a failure, named.** The
//!    player is told which test is missing, because "you did not write it" and
//!    "you wrote it and it failed" are different lessons.

use std::collections::BTreeSet;

use crate::{CaseResult, Event, Report, Submission, Verdict};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Passed,
    Failed,
    /// `#[ignore]` in Rust, `t.Skip()` in Go. Not a pass (rule 2).
    Skipped,
}

/// One test as the language's own runner reported it.
#[derive(Debug, Clone)]
pub struct TestOutcome {
    pub name: String,
    pub status: Status,
    /// The assertion text, panic or skip reason — whatever the runner printed
    /// under that test. Empty for a plain pass.
    pub message: String,
}

/// Everything the run phase produced, before it is judged.
#[derive(Debug, Clone, Default)]
pub struct SuiteRun {
    pub outcomes: Vec<TestOutcome>,
    pub stdout: String,
    pub stderr: String,
    pub exit_code: Option<i64>,
    pub elapsed_ms: i64,
    pub stdout_bytes: i64,
    pub timed_out: bool,
    pub overflow: bool,
    /// The last test seen to *start*. When a hang kills the whole binary this
    /// is the only name anybody has for what hung (libtest prints nothing on
    /// a kill), so it is worth carrying.
    pub last_started: Option<String>,
    /// A note the language module wants the player to read — "the suite timed
    /// out while running `x`", say. Never a diagnostic; those are kept whole.
    pub note: String,
}

/// Does a case declared in the content pack name this test?
///
/// Quests are authored against names a human types: `adds`, or `tests::adds`,
/// or `TestAdds`. The runner sees what the test runner calls them —
/// `tests::adds` from libtest, `TestAdds` or `TestAdds/empty_input` from Go.
///
/// * An exact name always matches.
/// * A declared name with no path separator also matches the leaf of a Rust
///   module path, so `adds` finds `tests::adds`.
/// * A Go subtest is never matched by its parent's name: `TestAdds` does not
///   satisfy a case that asked for `TestAdds/empty_input`, and asking for
///   `TestAdds` does not silently accept only one of its subtests.
pub fn same_test(declared: &str, actual: &str) -> bool {
    if declared == actual {
        return true;
    }
    if declared.contains('/') || actual.contains('/') {
        return false;
    }
    actual.ends_with(&format!("::{declared}"))
}

/// The tests a RUN is allowed to execute, or `None` for "all of them".
///
/// PROTOCOL §4.9b: a run must not tell the player whether the hidden cases
/// pass. For stdio that is guaranteed by never handing the hidden cases to the
/// runner; here the hidden tests live inside the quest's own test *file*, so
/// the guarantee has to be made where the tests are selected to run — before
/// anything of theirs reaches `run.log`, the report, or the verdict.
///
/// When the player wrote the tests there is nothing to protect and everything
/// runs: seeing your own tests go green is the whole point of pressing RUN.
pub fn only(sub: &Submission) -> Option<Vec<String>> {
    if sub.spec.only_declared && sub.spec.test_source.is_some() {
        Some(sub.spec.cases.iter().map(|c| c.name.clone()).collect())
    } else {
        None
    }
}

/// Turn what the test runner reported into the one `Report` shape the stdio
/// harness also produces.
pub fn assemble(
    sub: &Submission,
    compile_ms: i64,
    compiler_stderr: String,
    run: SuiteRun,
) -> Report {
    // A quest that ships its own tests keeps their names to itself: they are
    // the hidden half of the judging, and a name is data too.
    let quest_owned = sub.spec.test_source.is_some();

    let mut cases: Vec<CaseResult> = Vec::new();
    let mut claimed: BTreeSet<usize> = BTreeSet::new();
    let mut notes: Vec<String> = Vec::new();

    for declared in &sub.spec.cases {
        let found = run
            .outcomes
            .iter()
            .enumerate()
            .find(|(i, o)| !claimed.contains(i) && same_test(&declared.name, &o.name));
        let (passed, message) = match found {
            Some((i, outcome)) => {
                claimed.insert(i);
                match outcome.status {
                    Status::Passed => (true, String::new()),
                    Status::Failed => (false, outcome.message.clone()),
                    Status::Skipped => (
                        false,
                        format!(
                            "the test was skipped, and a skipped test has not passed{}",
                            suffix(&outcome.message)
                        ),
                    ),
                }
            }
            None => (
                false,
                format!(
                    "no test named `{}` ran; the quest asks for one",
                    declared.name
                ),
            ),
        };
        if !passed && !declared.visible {
            // A hidden case still reports pass or fail and its name (§5.2).
            notes.push(format!("`{}` did not pass", declared.name));
        }
        cases.push(CaseResult {
            name: declared.name.clone(),
            passed,
            visible: declared.visible,
            // A test harness has no stdin and no expected output: the test is
            // the expectation. Carrying empty strings here would render as
            // "expected: (nothing)" in a client built for stdio.
            stdin: None,
            expect: None,
            got: if declared.visible && !message.is_empty() {
                Some(message)
            } else {
                None
            },
        });
    }

    // Tests the player wrote that no case declared are still judged. This is
    // the whole point of the harness for a "write the tests yourself" quest:
    // the pack cannot know the names, so it declares what it must have and the
    // rest still has to pass.
    for (i, outcome) in run.outcomes.iter().enumerate() {
        if claimed.contains(&i) {
            continue;
        }
        let visible = !quest_owned;
        cases.push(CaseResult {
            name: outcome.name.clone(),
            passed: outcome.status == Status::Passed,
            visible,
            stdin: None,
            expect: None,
            got: match outcome.status {
                Status::Passed => None,
                Status::Skipped if visible => Some(format!(
                    "skipped, which is not a pass{}",
                    suffix(&outcome.message)
                )),
                _ if visible => Some(outcome.message.clone()),
                _ => None,
            },
        });
    }

    let passed = cases.iter().filter(|c| c.passed).count() as i64;
    let total = cases.len() as i64;

    let verdict = if run.timed_out {
        Verdict::Timeout
    } else if run.overflow {
        Verdict::OutputLimit
    } else if run.outcomes.is_empty() {
        if run.exit_code == Some(0) {
            notes.push(
                "the suite ran no tests at all; a submission with no test that runs \
                 cannot pass this quest"
                    .into(),
            );
            Verdict::WrongAnswer
        } else {
            Verdict::RuntimeError
        }
    } else if passed < total {
        Verdict::WrongAnswer
    } else if run.exit_code != Some(0) {
        // Every test passed and the process still died — a panic outside a
        // test, a `TestMain` that failed, a crash on the way out. Saying
        // `accepted` here would be inventing a pass.
        notes.push(format!(
            "every test passed but the test binary exited with {}",
            run.exit_code
                .map(|c| c.to_string())
                .unwrap_or_else(|| "a signal".into())
        ));
        Verdict::RuntimeError
    } else {
        Verdict::Accepted
    };

    if !run.note.is_empty() {
        notes.push(run.note.clone());
    }
    let mut runtime_stderr = notes.join("\n");
    if !run.stderr.trim().is_empty() {
        if !runtime_stderr.is_empty() {
            runtime_stderr.push('\n');
        }
        runtime_stderr.push_str(&run.stderr);
    }

    (sub.events)(Event::Stage("judging"));
    Report {
        verdict,
        compile_ms,
        run_ms: run.elapsed_ms,
        exit_code: run.exit_code,
        stdout_bytes: run.stdout_bytes,
        tests_passed: passed,
        tests_total: total,
        cases,
        compiler_stderr,
        runtime_stderr,
        stdout: run.stdout,
    }
}

/// A compile that never produced a test binary: every declared case failed,
/// and the verdict is the caller's to name — `compile_error` when it was the
/// player's code, `internal_error` when it was the quest's own test file.
pub fn no_binary(
    sub: &Submission,
    verdict: Verdict,
    compile_ms: i64,
    compiler_stderr: String,
    runtime_stderr: String,
    exit_code: Option<i64>,
) -> Report {
    Report {
        verdict,
        compile_ms,
        run_ms: 0,
        exit_code,
        stdout_bytes: 0,
        tests_passed: 0,
        tests_total: sub.spec.cases.len() as i64,
        cases: crate::harness::not_run(sub),
        compiler_stderr,
        runtime_stderr,
        stdout: String::new(),
    }
}

/// The player's code compiled; the quest's tests did not compile *against*
/// it. That is a failed submission, and the player is owed the reason without
/// being shown the test file that produced it.
///
/// Identical wording in both lands on purpose: this is the message a player
/// will meet at their most confused, and "the server being unfair" is exactly
/// what two different phrasings would read as.
pub fn tests_do_not_fit(messages: &[String]) -> String {
    let mut out = String::from(
        "your code compiled, but the quest's tests do not compile against it \
         — check the names, the signatures and the visibility the brief asks for:",
    );
    for message in messages {
        out.push_str("\n  - ");
        out.push_str(message.trim());
    }
    out
}

/// The quest's own test file is broken. Never the player's fault, never a
/// `compile_error`, and never a `mistakes` row: an attempt whose verdict the
/// server invented flows into the drills and teaches somebody to fix something
/// they never did.
pub fn quest_is_broken(file: &str, detail: &str) -> String {
    format!(
        "this quest's own tests ({file}) do not compile, which is not something \
         you did. Nothing has been recorded against you. The pack needs fixing: {detail}"
    )
}

fn suffix(message: &str) -> String {
    let m = message.trim();
    if m.is_empty() {
        String::new()
    } else {
        format!(": {m}")
    }
}
