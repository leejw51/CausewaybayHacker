//! The Lua runner: `luajit -b main.lua main.luac` as the compile phase, then
//! `luajit main.lua` once per case through the stdio harness (SPEC §5.1,
//! §5.2).
//!
//! LuaJIT, and only LuaJIT. It is the interpreter the LÖVE client runs on,
//! so a program that works on the desk works on the dragon — and it is a
//! Lua 5.1 with LuaJIT's extensions, which is not Lua 5.4: `print(6 / 2)` is
//! `3` here and `3.0` there, `//` does not parse here, `table.unpack` does
//! not exist here. A pack verified on one is wrong on the other, so the
//! runner does not fall back from one to the other: a machine without
//! `luajit` is refused before an attempt exists (`crate::unsupported`), with
//! the command to fix it.
//!
//! Lua has no compiler and the two-phase shape is kept anyway, for the
//! reason `python.rs` gives: a syntax error is the one mistake the
//! interpreter can find without running a line, and `-b` — compile to
//! bytecode, into a file that is thrown away — finds it and prints
//! `luajit: main.lua:3: unexpected symbol near '='` and nothing else. A
//! program that cannot start is a `compile_error` in every land.

use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use crate::harness::{judge_argv, not_run};
use crate::proc::{self, Limits};
use crate::spec::Harness;
use crate::typescript::which;
use crate::{Event, Report, Submission, Verdict};

pub fn run(sub: &Submission) -> Report {
    match sub.spec.harness {
        Harness::Stdio => {}
        Harness::Cargo | Harness::Gotest => {
            return Report::internal(format!(
                "the {} harness is not a lua harness (SPEC §5.2)",
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
    std::fs::write(sub.workdir.join("main.lua"), sub.source)?;

    // Resolved once, with the ambient `PATH`: the interpreter that checks
    // the file is the interpreter that runs it, and Homebrew's is not on
    // `/usr/bin:/bin`, which is all the harness gives the program.
    let Some(luajit) = which("luajit") else {
        return Ok(Report::internal(format!(
            "Lua Land needs luajit on PATH: {}",
            crate::format::LUA_HINT
        )));
    };

    (sub.events)(Event::Stage("compiling"));
    let events = sub.events.clone();
    let compile_logs: proc::LogSink = Arc::new(move |_stream, chunk| {
        events(Event::Log {
            stream: "compile".into(),
            chunk: chunk.to_string(),
        });
    });

    let mut check = Command::new(&luajit);
    check
        .current_dir(&sub.workdir)
        .arg("-b")
        .arg("main.lua")
        .arg("main.luac");
    toolchain_env(&mut check, sub);

    let compile = proc::run(
        check,
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

    // The one line is on stderr; anything on stdout belongs with it.
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
    // The source is run, not the bytecode: an error's line number and the
    // traceback name `main.lua`, which is what §7.1 files the mistake
    // against. The bytecode file was only ever the syntax check.
    judge_argv(
        sub,
        &luajit,
        &["main.lua".as_ref()],
        compile_ms,
        compiler_stderr,
    )
}

/// The toolchain allowlist (`harness::toolchain_base`), scratch inside the
/// attempt (§1). `main.luac` lands beside the source and is pruned with it.
pub(crate) fn toolchain_env(command: &mut Command, sub: &Submission) {
    crate::harness::toolchain_base(command, &sub.workdir);
}

/// Whether `luajit` answers `luajit -v` on this process's `PATH`.
pub fn is_installed() -> bool {
    which("luajit").is_some_and(|luajit| {
        Command::new(luajit)
            .arg("-v")
            .stdin(std::process::Stdio::null())
            .output()
            .map(|out| out.status.success())
            .unwrap_or(false)
    })
}
