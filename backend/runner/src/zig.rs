//! The Zig runner: `zig build-exe main.zig -O Debug` as the compile phase,
//! then the binary once per case through the stdio harness (SPEC §5.1,
//! §5.2).
//!
//! `-O Debug` is the point of the land, not a shortcut. ZIG LAND is about
//! the checks Zig makes explicit — an index past the end, an optional
//! unwrapped while null, an integer that overflows, a branch marked
//! `unreachable` — and in Debug every one of them is on and every one of
//! them dies saying what it is: `panic: index out of bounds: index 3, len
//! 3`, on the player's line. `ReleaseFast` would make three of the four
//! silent undefined behaviour, which is the lesson the land exists to
//! un-teach. It is also the fast compile: under a second warm against four
//! for an optimised build, and the Debug binary still clears a four-million
//! operation Fenwick case in a quarter of a second, so §5.3's clock is not
//! a problem it creates.
//!
//! Two caches, both named. `zig` keeps compiled `std` in a global cache it
//! derives from `HOME` when nobody says otherwise, and `toolchain_base`
//! points `HOME` at the attempt directory (§1), so without the flag every
//! attempt would rebuild the standard library from scratch. The global cache
//! goes under the land's `cache_root` — the same place `CARGO_HOME` lives —
//! and the local one inside the attempt, pruned with it.

use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use crate::harness::{judge, not_run};
use crate::proc::{self, Limits};
use crate::spec::Harness;
use crate::typescript::which;
use crate::{Event, Report, Submission, Verdict};

pub fn run(sub: &Submission) -> Report {
    match sub.spec.harness {
        Harness::Stdio => {}
        Harness::Cargo | Harness::Gotest => {
            return Report::internal(format!(
                "the {} harness is not a zig harness (SPEC §5.2)",
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
    std::fs::write(sub.workdir.join("main.zig"), sub.source)?;
    let binary = sub.workdir.join("prog");

    // Resolved with the ambient `PATH` for the reason `python.rs` gives: the
    // harness does not run the compiler, but a `zig` that is only on the
    // player's PATH through Homebrew is not on `/usr/bin:/bin` either, and
    // the absolute path is what the boot report and this agree on.
    let Some(zig) = which("zig") else {
        return Ok(Report::internal(format!(
            "Zig Land needs zig on PATH: {}",
            crate::format::ZIG_HINT
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

    let mut compiler = Command::new(&zig);
    compiler
        .current_dir(&sub.workdir)
        .arg("build-exe")
        .arg("main.zig")
        .arg("-O")
        .arg("Debug")
        .arg("--color")
        .arg("off")
        .arg("--cache-dir")
        .arg(sub.workdir.join("zig-cache"))
        .arg("--global-cache-dir")
        .arg(sub.cache_root.join("zig-global"))
        .arg("-femit-bin=prog");
    toolchain_env(&mut compiler, sub);

    let compile = proc::run(
        compiler,
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

    // `zig` reports on stderr, `main.zig:3:20: error: …` with the source
    // line and a caret under it, and says nothing on stdout. Anything on
    // stdout belongs with it.
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
    if compile.exit_code != Some(0) || !binary.exists() {
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

/// The toolchain allowlist (`harness::toolchain_base`), with the scratch
/// inside the attempt (§1). The two cache directories are given on the
/// command line rather than through the environment, because that is the
/// only way `zig` takes them.
pub(crate) fn toolchain_env(command: &mut Command, sub: &Submission) {
    crate::harness::toolchain_base(command, &sub.workdir);
}

/// Whether `zig` answers `zig version` on this process's `PATH`.
pub fn is_installed() -> bool {
    which("zig").is_some_and(|zig| {
        Command::new(zig)
            .arg("version")
            .stdin(std::process::Stdio::null())
            .output()
            .map(|out| out.status.success())
            .unwrap_or(false)
    })
}
