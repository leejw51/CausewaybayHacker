//! The Python runner: `python3 -m py_compile main.py` as the compile phase,
//! then `python3 -I main.py` once per case through the stdio harness
//! (SPEC §5.1, §5.2).
//!
//! Python has no compiler, and the two-phase shape is kept anyway. A
//! `SyntaxError` is the one mistake the interpreter can find without running
//! a line, and a player who wrote one should get `compile_error` and the
//! parser's own pointer at the line, not `runtime_error` on the first case
//! with the same message buried under a traceback. It also keeps the verdicts
//! the same across lands: a program that cannot start is a compile error in
//! every one of them.
//!
//! `-I` is isolated mode: no user site-packages, no `PYTHON*` variables, and
//! the script's directory not on `sys.path`. §5.3 already strips the
//! environment; this closes the doors the interpreter would otherwise open
//! for itself.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use crate::harness::{judge_argv, not_run};
use crate::proc::{self, Limits};
use crate::spec::Harness;
use crate::{Event, Report, Submission, Verdict};

pub fn run(sub: &Submission) -> Report {
    match sub.spec.harness {
        Harness::Stdio => {}
        Harness::Cargo | Harness::Gotest => {
            return Report::internal(format!(
                "the {} harness is not a python harness (SPEC §5.2)",
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
    std::fs::write(sub.workdir.join("main.py"), sub.source)?;

    // Resolved once, here, with the ambient `PATH`: the interpreter that
    // checks the file is the interpreter that runs it. The harness runs the
    // program with `PATH=/usr/bin:/bin`, where on a macOS with Homebrew or
    // conda there is a different `python3`, or a stub that offers to install
    // one.
    let Some(interpreter) = which("python3") else {
        return Ok(Report::internal(
            "there is no python3 on PATH; `cwbhacker doctor` reports it",
        ));
    };

    (sub.events)(Event::Stage("compiling"));
    let events = sub.events.clone();
    let compile_logs: proc::LogSink = Arc::new(move |_stream, chunk| {
        events(Event::Log {
            stream: "compile".into(),
            chunk: chunk.to_string(),
        });
    });

    let mut py = Command::new(&interpreter);
    py.current_dir(&sub.workdir)
        .arg("-m")
        .arg("py_compile")
        .arg("main.py");
    toolchain_env(&mut py, sub);

    let compile = proc::run(
        py,
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

    // `py_compile` prints the SyntaxError on stderr and, for an
    // IndentationError, a `Sorry: …` line with no newline after it. Anything
    // on stdout belongs with them.
    let mut compiler_stderr = String::from_utf8_lossy(&compile.stderr).to_string();
    if !compile.stdout.is_empty() {
        compiler_stderr.push_str(&String::from_utf8_lossy(&compile.stdout));
    }
    if !compiler_stderr.is_empty() && !compiler_stderr.ends_with('\n') {
        compiler_stderr.push('\n');
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
    if compile.exit_code != Some(0) {
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
    judge_argv(
        sub,
        &interpreter,
        &["-I".as_ref(), "main.py".as_ref()],
        compile_ms,
        compiler_stderr,
    )
}

/// The interpreter keeps the ambient environment for the compile phase (a
/// conda or pyenv `python3` is a shim that needs it) with the scratch pointed
/// inside the home (§1). `py_compile` writes `__pycache__/main.cpython-*.pyc`
/// beside the file — that is what it is for — and the directory it lands in
/// is the attempt's own, pruned with it.
pub(crate) fn toolchain_env(command: &mut Command, sub: &Submission) {
    command
        .env("TMPDIR", &sub.workdir)
        .env("HOME", &sub.workdir);
}

/// The first executable `program` on the ambient `PATH`, as an absolute path.
fn which(program: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(program))
        .find(|candidate| is_executable(candidate))
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}
