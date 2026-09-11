//! The Rust runner: `rustc --edition 2021 -O --error-format=json main.rs -o prog`
//! and then the stdio harness over the quest's cases (SPEC §5.1, §5.2).

use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use crate::proc::{self, Limits};
use crate::spec::Harness;
use crate::{CaseResult, Event, Report, Submission, Verdict};

pub fn run(sub: &Submission) -> Report {
    if sub.spec.harness != Harness::Stdio {
        // `cargo` harnesses (dependencies, `#[test]`) are milestone 2. Saying
        // so beats compiling the wrong thing and calling the answer wrong.
        return Report::internal(format!(
            "the {:?} harness is not in this build yet (SPEC §5.1, milestone 2)",
            sub.spec.harness
        ));
    }
    match compile_and_judge(sub) {
        Ok(report) => report,
        Err(e) => Report::internal(format!("runner: {e}")),
    }
}

fn compile_and_judge(sub: &Submission) -> std::io::Result<Report> {
    std::fs::create_dir_all(&sub.workdir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&sub.workdir, std::fs::Permissions::from_mode(0o700));
    }
    let source_path = sub.workdir.join("main.rs");
    std::fs::write(&source_path, sub.source)?;
    let binary = sub.workdir.join("prog");

    (sub.events)(Event::Stage("compiling"));
    let events = sub.events.clone();
    let compile_logs: proc::LogSink = Arc::new(move |_stream, chunk| {
        events(Event::Log {
            stream: "compile".into(),
            chunk: chunk.to_string(),
        });
    });

    let mut rustc = Command::new("rustc");
    rustc
        .current_dir(&sub.workdir)
        .arg("--edition")
        .arg("2021")
        .arg("-O")
        .arg("--error-format=json")
        .arg("main.rs")
        .arg("-o")
        .arg(&binary);
    // The compiler runs with a working environment. `rustc` is very often a
    // rustup shim that needs HOME and RUSTUP_HOME to pick a toolchain at all,
    // and §5.3's stripped environment is aimed at the code the player wrote,
    // which is the next step down. What does get redirected is the scratch:
    // nothing outside the home is written (§1).
    rustc
        .env("CARGO_HOME", sub.cache_root.join("cargo-home"))
        .env("CARGO_TARGET_DIR", sub.cache_root.join("target"))
        .env("TMPDIR", &sub.workdir);

    let compile = proc::run(
        rustc,
        b"",
        &Limits {
            timeout: Duration::from_millis(sub.spec.compile_timeout_ms),
            max_stdout: 1 << 20,
            max_stderr: 4 << 20,
            apply_rlimits: false,
        },
        "compile",
        "compile",
        compile_logs,
    )?;

    let compiler_stderr = String::from_utf8_lossy(&compile.stderr).to_string();
    let compile_ms = compile.elapsed_ms as i64;

    if compile.timed_out {
        return Ok(Report {
            verdict: Verdict::Timeout,
            compile_ms,
            run_ms: 0,
            exit_code: None,
            stdout_bytes: 0,
            tests_passed: 0,
            tests_total: sub.spec.cases.len() as i64,
            cases: not_run(sub),
            compiler_stderr,
            runtime_stderr: "the compiler ran out of time".into(),
            stdout: String::new(),
        });
    }
    if !binary.exists() || compile.exit_code != Some(0) {
        return Ok(Report {
            verdict: Verdict::CompileError,
            compile_ms,
            run_ms: 0,
            exit_code: compile.exit_code.map(i64::from),
            stdout_bytes: 0,
            tests_passed: 0,
            tests_total: sub.spec.cases.len() as i64,
            cases: not_run(sub),
            compiler_stderr,
            runtime_stderr: String::new(),
            stdout: String::new(),
        });
    }

    (sub.events)(Event::Stage("running"));
    judge(sub, &binary, compile_ms, compiler_stderr)
}

fn judge(
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

fn result_for(case: &crate::Case, passed: bool, got: Option<String>) -> CaseResult {
    CaseResult {
        name: case.name.clone(),
        passed,
        visible: case.visible,
        stdin: case.visible.then(|| case.stdin.clone()),
        expect: case.visible.then(|| case.expect.clone()),
        got: if case.visible { got } else { None },
    }
}

fn not_run(sub: &Submission) -> Vec<CaseResult> {
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
