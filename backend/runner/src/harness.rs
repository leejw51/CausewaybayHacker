//! The stdio harness (SPEC §5.2): run the compiled program once per case,
//! compare its output, and turn the whole sheet into a verdict.
//!
//! Language-agnostic on purpose. Once `rustc` or `go build` has produced a
//! binary, judging it is the same job, and two copies of this loop would drift
//! — a `trim` that forgave a trailing newline in one land and not the other is
//! exactly the kind of difference a player reads as the server being unfair.

use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use crate::proc::{self, Limits};
use crate::{Case, CaseResult, Event, Report, Submission, Verdict};

pub fn judge(
    sub: &Submission,
    binary: &Path,
    compile_ms: i64,
    compiler_stderr: String,
) -> std::io::Result<Report> {
    let mut cases = Vec::with_capacity(sub.spec.cases.len());
    let mut verdict = Verdict::Accepted;
    let mut run_ms = 0i64;
    let mut stdout_bytes = 0i64;
    let mut runtime_stderr = String::new();
    let mut first_stdout = String::new();
    let mut exit_code = None;
    let mut passed = 0i64;

    for case in &sub.spec.cases {
        let events = sub.events.clone();
        let logs: proc::LogSink = Arc::new(move |stream, chunk| {
            events(Event::Log {
                stream: stream.to_string(),
                chunk: chunk.to_string(),
            });
        });

        let mut command = Command::new(binary);
        command.current_dir(&sub.workdir);
        strip_env(&mut command, &sub.workdir);

        let outcome = proc::run(
            command,
            case.stdin.as_bytes(),
            &Limits {
                timeout: Duration::from_millis(sub.spec.timeout_ms),
                max_stdout: sub.spec.max_stdout_bytes,
                max_stderr: 256 * 1024,
                apply_rlimits: true,
            },
            "stdout",
            "stderr",
            logs,
        )?;

        run_ms += outcome.elapsed_ms as i64;
        stdout_bytes += outcome.stdout_produced as i64;
        let got = String::from_utf8_lossy(&outcome.stdout).to_string();
        if first_stdout.is_empty() {
            first_stdout = got.clone();
        }
        if runtime_stderr.is_empty() && !outcome.stderr.is_empty() {
            runtime_stderr = String::from_utf8_lossy(&outcome.stderr).to_string();
        }
        if exit_code.is_none() {
            exit_code = outcome.exit_code.map(i64::from);
        }

        let case_verdict = if outcome.timed_out {
            Some(Verdict::Timeout)
        } else if outcome.stdout_overflow {
            Some(Verdict::OutputLimit)
        } else if outcome.exit_code != Some(0) {
            Some(Verdict::RuntimeError)
        } else if sub.spec.match_mode.matches(&got, &case.expect) {
            None
        } else {
            Some(Verdict::WrongAnswer)
        };

        let ok = case_verdict.is_none();
        if ok {
            passed += 1;
        }
        cases.push(result_for(case, ok, Some(got)));

        if let Some(failure) = case_verdict {
            if verdict == Verdict::Accepted {
                verdict = failure;
            }
            // A wrong answer is worth finishing the sheet for — the player
            // wants to see which cases pass. A timeout, an overflow or a
            // crash is not: five more of the same costs five more timeouts.
            if failure != Verdict::WrongAnswer {
                for rest in sub.spec.cases.iter().skip(cases.len()) {
                    cases.push(result_for(rest, false, None));
                }
                break;
            }
        }
    }

    (sub.events)(Event::Stage("judging"));
    Ok(Report {
        verdict,
        compile_ms,
        run_ms,
        exit_code,
        stdout_bytes,
        tests_passed: passed,
        tests_total: sub.spec.cases.len() as i64,
        cases,
        compiler_stderr,
        runtime_stderr,
        stdout: first_stdout,
    })
}

fn result_for(case: &Case, passed: bool, got: Option<String>) -> CaseResult {
    CaseResult {
        name: case.name.clone(),
        passed,
        visible: case.visible,
        stdin: case.visible.then(|| case.stdin.clone()),
        expect: case.visible.then(|| case.expect.clone()),
        got: if case.visible { got } else { None },
    }
}

pub fn not_run(sub: &Submission) -> Vec<CaseResult> {
    sub.spec
        .cases
        .iter()
        .map(|case| result_for(case, false, None))
        .collect()
}

/// SPEC §5.3: `PATH`, `HOME` pointed at the build dir, and nothing else.
fn strip_env(command: &mut Command, workdir: &Path) {
    command
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", workdir)
        .env("TMPDIR", workdir)
        .env("LANG", "C")
        .env("LC_ALL", "C");
}
