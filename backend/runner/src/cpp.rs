//! The C++ runner: `c++ -std=c++20 -O2 -pthread -Wall main.cpp -o prog` and
//! then the stdio harness over the quest's cases (SPEC §5.1, §5.2).
//!
//! `c++` is the system driver — clang on macOS, gcc on Linux — and the two
//! agree on the shape of a diagnostic (`main.cpp:5:18: error: …`) even where
//! they disagree on its wording, which is what §7.1's C++ column is written
//! against. There is no package cache to redirect: a C++ quest is one file and
//! the standard library, so the only things pointed into the build directory
//! are the scratch (`TMPDIR`) and `HOME`.
//!
//! `-Wall` is not decoration. Without it neither compiler mentions an unused
//! variable, and `cpp:unused` is a row of the taxonomy the same way
//! `unused_variables` is for Rust.

use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use crate::harness::{judge, not_run};
use crate::proc::{self, Limits};
use crate::spec::Harness;
use crate::{Event, Report, Submission, Verdict};

pub fn run(sub: &Submission) -> Report {
    match sub.spec.harness {
        Harness::Stdio => {}
        // Refused rather than approximated. The server asks
        // [`crate::unsupported`] first and never gets here.
        Harness::Cargo | Harness::Gotest => {
            return Report::internal(format!(
                "the {} harness is not a c++ harness (SPEC §5.2)",
                sub.spec.harness.as_str()
            ));
        }
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
    std::fs::write(sub.workdir.join("main.cpp"), sub.source)?;
    let binary = sub.workdir.join("prog");

    (sub.events)(Event::Stage("compiling"));
    let events = sub.events.clone();
    let compile_logs: proc::LogSink = Arc::new(move |_stream, chunk| {
        events(Event::Log {
            stream: "compile".into(),
            chunk: chunk.to_string(),
        });
    });

    let mut cxx = Command::new("c++");
    cxx.current_dir(&sub.workdir)
        .arg("-std=c++20")
        .arg("-O2")
        .arg("-pthread")
        .arg("-Wall")
        .arg("main.cpp")
        .arg("-o")
        .arg(&binary);
    toolchain_env(&mut cxx, sub);

    let compile = proc::run(
        cxx,
        b"",
        &Limits {
            timeout: Duration::from_millis(sub.spec.compile_timeout_ms),
            max_stdout: 1 << 20,
            max_stderr: 4 << 20,
            apply_rlimits: false,
            address_space: false,
        },
        "compile",
        "compile",
        compile_logs,
    )?;

    // Both drivers write their diagnostics to stderr and say nothing on
    // success; anything on stdout belongs with them.
    let mut compiler_stderr = String::from_utf8_lossy(&compile.stderr).to_string();
    if !compile.stdout.is_empty() {
        compiler_stderr.push_str(&String::from_utf8_lossy(&compile.stdout));
    }
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

/// The compiler keeps the ambient environment — it has to find its own SDK
/// and linker, and on macOS that is a path only Xcode knows — while the
/// scratch is pointed inside the home (§1). §5.3's stripped environment
/// applies one step down, to the program the player wrote.
pub(crate) fn toolchain_env(command: &mut Command, sub: &Submission) {
    command
        .env("TMPDIR", &sub.workdir)
        .env("HOME", &sub.workdir);
}
