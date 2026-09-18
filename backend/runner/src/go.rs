//! The Go runner: `go build -o prog main.go` and then the stdio harness over
//! the quest's cases (SPEC §5.1, §5.2).
//!
//! The shape is deliberately the same as `rust.rs` — compile with a working
//! environment and the scratch redirected, then run the binary under §5.3's
//! limits — because the two lands must judge identically. What differs is the
//! compiler's environment and the fact that Go reports its errors as prose
//! rather than as JSON with codes in it (SPEC §7.1, handled in core).

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
        // `go test`, parsed from its own JSON event stream: `gotest.rs`.
        Harness::Gotest => return crate::gotest::run(sub),
        Harness::Cargo => {
            return Report::internal(format!(
                "the {} harness is not a go harness (SPEC §5.2)",
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
    std::fs::write(sub.workdir.join("main.go"), sub.source)?;
    let binary = sub.workdir.join("prog");

    (sub.events)(Event::Stage("compiling"));
    let events = sub.events.clone();
    let compile_logs: proc::LogSink = Arc::new(move |_stream, chunk| {
        events(Event::Log {
            stream: "compile".into(),
            chunk: chunk.to_string(),
        });
    });

    let mut go = Command::new("go");
    go.current_dir(&sub.workdir)
        .arg("build")
        .arg("-o")
        .arg(&binary)
        .arg("main.go");
    toolchain_env(&mut go, sub);

    let compile = proc::run(
        go,
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

    // `go build` says nothing on success and writes its diagnostics to
    // stderr; anything it put on stdout belongs with them.
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

/// SPEC §5.1: every cache Go keeps lives under `build/go/`, and `GOPROXY=off`
/// — a quest does not fetch the internet.
///
/// The toolchain allowlist (`harness::toolchain_base`: `PATH` and `GOROOT`,
/// nothing of the server's own) with everything Go would otherwise put in
/// the user's own home pointed inside ours.
pub(crate) fn toolchain_env(command: &mut Command, sub: &Submission) {
    crate::harness::toolchain_base(command, &sub.workdir);
    command
        .env("GOCACHE", sub.cache_root.join("gocache"))
        .env("GOMODCACHE", sub.cache_root.join("gomodcache"))
        .env("GOPATH", sub.cache_root.join("gopath"))
        .env("GOFLAGS", "-mod=mod")
        .env("GOPROXY", "off")
        // Without this a `go.mod` naming a newer toolchain sends `go` to the
        // network, which `GOPROXY=off` then fails in a way that reads as a
        // broken quest rather than as a refused download.
        .env("GOTOOLCHAIN", "local")
        .env("GO111MODULE", "auto")
        .env("CGO_ENABLED", "0");
}
