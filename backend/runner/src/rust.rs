//! The Rust runner: `rustc --edition 2021 -O --error-format=json main.rs -o prog`
//! and then the stdio harness over the quest's cases (SPEC §5.1, §5.2).

use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use crate::harness::{judge, not_run};
use crate::proc::{self, Limits};
use crate::spec::Harness;
use crate::{Event, Report, Submission, Verdict};

pub fn run(sub: &Submission) -> Report {
    if sub.spec.harness != Harness::Stdio {
        // `cargo` harnesses (dependencies, `#[test]`) are milestone 2. Saying
        // so beats compiling the wrong thing and calling the answer wrong.
        return Report::internal(format!(
            "the {} harness is not in this build yet (SPEC §5.1)",
            sub.spec.harness.as_str()
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
