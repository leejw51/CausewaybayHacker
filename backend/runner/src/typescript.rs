//! The TypeScript runner: `tsc -p .` as the compile phase, then
//! `node --enable-source-maps main.js` once per case through the stdio
//! harness (SPEC §5.1, §5.2).
//!
//! TypeScript is the one land whose compiler checks a program and then throws
//! the checking away: `tsc` proves the types, erases them, and what `node`
//! runs is JavaScript that never heard of them. Both halves are the lesson.
//! A type error is `compile_error` with `tsc`'s own `TS2322` on the line —
//! Node 22+ could run `main.ts` directly by stripping the types, and would
//! then run a program `tsc` rejects, which is the one thing a land about
//! types must not do. And a program that type-checks and still reads
//! `.left` off `undefined` at runtime is `runtime_error`, because that is
//! what erasure means.
//!
//! Three files go into the attempt directory, not one:
//!
//! * `main.ts`, the player's;
//! * `node.d.ts`, the whole of Node a quest can see (`typescript/node.d.ts`,
//!   compiled into this binary). It is not `@types/node`, whose version would
//!   have to be pinned beside `tsc`'s on every machine the server runs on;
//! * `tsconfig.json`, `strict` and nothing clever (`typescript/tsconfig.json`).
//!   A bare-flag command line cannot say `"types": []`, which is what keeps a
//!   globally installed `@types/node` from leaking in on one machine and not
//!   another.
//!
//! `inlineSourceMap` plus `--enable-source-maps` is what makes a runtime
//! stack trace say `main.ts:12:7` rather than a line of emitted JavaScript
//! the player never saw — §7.1 files the mistake against that line.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use crate::harness::{judge_argv_limited, not_run};
use crate::proc::{self, Limits};
use crate::spec::Harness;
use crate::{Event, Report, Submission, Verdict};

/// The ambient declarations every quest is checked against.
pub const NODE_DTS: &str = include_str!("typescript/node.d.ts");
/// The compiler options, the same file `tests/content/verify_pack.py` copies.
pub const TSCONFIG: &str = include_str!("typescript/tsconfig.json");

pub fn run(sub: &Submission) -> Report {
    match sub.spec.harness {
        Harness::Stdio => {}
        Harness::Cargo | Harness::Gotest => {
            return Report::internal(format!(
                "the {} harness is not a typescript harness (SPEC §5.2)",
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
    std::fs::write(sub.workdir.join("main.ts"), sub.source)?;
    std::fs::write(sub.workdir.join("node.d.ts"), NODE_DTS)?;
    std::fs::write(sub.workdir.join("tsconfig.json"), TSCONFIG)?;
    let emitted = sub.workdir.join("main.js");

    // Both resolved here, with the ambient `PATH`, for the reason `python.rs`
    // gives: the harness runs the program with `PATH=/usr/bin:/bin`, and
    // neither `node` nor a global `tsc` lives there on any machine that has
    // them — Homebrew, nvm and the official installer all put them elsewhere.
    let (Some(tsc), Some(node)) = (which("tsc"), which("node")) else {
        return Ok(Report::internal(format!(
            "TypeScript Land needs tsc and node on PATH: {}",
            crate::format::TYPESCRIPT_HINT
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

    // `tsc` is a `#!/usr/bin/env node` script, so the compile needs `PATH`
    // to find `node` — which `toolchain_base` keeps and `strip_env` does not.
    let mut compiler = Command::new(&tsc);
    compiler.current_dir(&sub.workdir).arg("-p").arg(".");
    toolchain_env(&mut compiler, sub);
    // `tsc` turns on Node's compile cache for itself, under `TMPDIR` — which
    // is the attempt directory, so every attempt paid for a cache it threw
    // away. Pointed at the land's cache root it is inside the home (§1) and
    // the second compile of the day starts warm, as `CARGO_HOME` does for Rust.
    compiler.env("NODE_COMPILE_CACHE", sub.cache_root.join("node-compile-cache"));

    let compile = proc::run(
        compiler,
        b"",
        &Limits {
            timeout: Duration::from_millis(sub.spec.compile_timeout_ms),
            max_stdout: 4 << 20,
            max_stderr: 4 << 20,
            apply_rlimits: false,
            address_space: false,
        },
        "compile",
        "compile",
        compile_logs,
    )?;

    // **`tsc` reports on stdout**, one `main.ts(3,5): error TS2322: …` per
    // line, and says nothing at all on stderr unless it crashed. Folded
    // together, stdout first, so §7.1 sees the diagnostics it classifies.
    let mut compiler_stderr = String::from_utf8_lossy(&compile.stdout).to_string();
    compiler_stderr.push_str(&String::from_utf8_lossy(&compile.stderr));
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
    // `noEmitOnError` means a rejected program leaves no `main.js`; the
    // existence check is for the day someone turns it off.
    if compile.exit_code != Some(0) || !emitted.exists() {
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
    // Memory is bounded by V8's own heap limit rather than `RLIMIT_AS`
    // (`judge_argv_limited`): a program that outgrows it dies of
    // "JavaScript heap out of memory", which is the honest message.
    judge_argv_limited(
        sub,
        &node,
        &[
            "--enable-source-maps".as_ref(),
            "--max-old-space-size=512".as_ref(),
            "main.js".as_ref(),
        ],
        compile_ms,
        compiler_stderr,
        false,
    )
}

/// The toolchain allowlist, scratch inside the attempt directory (§1).
pub(crate) fn toolchain_env(command: &mut Command, sub: &Submission) {
    crate::harness::toolchain_base(command, &sub.workdir);
}

/// The first executable `program` on the ambient `PATH`, as an absolute path.
pub(crate) fn which(program: &str) -> Option<PathBuf> {
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
