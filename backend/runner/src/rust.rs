//! The Rust runner: `rustc --edition 2021 -O --error-format=json main.rs -o prog`
//! and then the stdio harness over the quest's cases (SPEC §5.1, §5.2).

use std::collections::HashMap;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::harness::{judge, not_run};
use crate::proc::{self, Limits};
use crate::spec::Harness;
use crate::{Event, Events, Report, Submission, Verdict};

/// The compile stream the player reads (PROTOCOL §4.18 `stream: "compile"`),
/// made out of a compiler's `--error-format=json` output one line at a time.
///
/// The pipes hand over chunks that split anywhere (§4.18 says so of the
/// wire, and it is just as true of an 8 KiB read from a pipe), so each pipe
/// gets its own line buffer keyed by the label `proc::run` calls it by. Only
/// a whole line is a diagnostic; the tail is kept until the next chunk, and
/// [`CompileLines::flush`] sends whatever is left once the compiler has
/// exited. The report's `compiler_stderr` is untouched by any of this — it
/// stays the raw JSON, because classification (SPEC §7.1) reads that.
pub(crate) struct CompileLines {
    events: Events,
    render: fn(&str) -> Option<String>,
    tails: Mutex<HashMap<String, String>>,
}

impl CompileLines {
    pub(crate) fn new(events: Events, render: fn(&str) -> Option<String>) -> Arc<Self> {
        Arc::new(CompileLines {
            events,
            render,
            tails: Mutex::new(HashMap::new()),
        })
    }

    /// The `proc::LogSink` that feeds this.
    pub(crate) fn sink(self: &Arc<Self>) -> proc::LogSink {
        let lines = self.clone();
        Arc::new(move |label, chunk| lines.push(label, chunk))
    }

    fn push(&self, label: &str, chunk: &str) {
        let mut tails = self.tails.lock().unwrap();
        let tail = tails.entry(label.to_string()).or_default();
        tail.push_str(chunk);
        // Every complete line goes out now; what follows the last newline
        // waits for the rest of itself.
        while let Some(at) = tail.find('\n') {
            let line: String = tail.drain(..=at).collect();
            self.emit(line.trim_end_matches(['\n', '\r']));
        }
    }

    /// After the compiler has exited: a last line with no newline is still
    /// a line.
    pub(crate) fn flush(&self) {
        let mut tails = self.tails.lock().unwrap();
        for (_, tail) in tails.drain() {
            let line = tail.trim_end_matches(['\n', '\r']);
            if !line.is_empty() {
                self.emit(line);
            }
        }
    }

    fn emit(&self, line: &str) {
        if let Some(mut text) = (self.render)(line) {
            if !text.ends_with('\n') {
                text.push('\n');
            }
            (self.events)(Event::Log {
                stream: "compile".into(),
                chunk: text,
            });
        }
    }
}

/// One line of `rustc --error-format=json`, as the player should read it:
/// a diagnostic's `rendered` text, nothing for a diagnostic that has none,
/// and a line that is not JSON at all (a linker error, an ICE note) as it
/// came.
pub(crate) fn rendered_line(line: &str) -> Option<String> {
    match serde_json::from_str::<serde_json::Value>(line) {
        Ok(value) if value.is_object() => rendered_of(&value),
        _ => Some(line.to_string()),
    }
}

/// A diagnostic object's `rendered`, or `None` when it is absent, null or
/// empty — a JSON line with nothing to show is not shown as JSON instead.
pub(crate) fn rendered_of(diagnostic: &serde_json::Value) -> Option<String> {
    diagnostic
        .get("rendered")
        .and_then(|v| v.as_str())
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

pub fn run(sub: &Submission) -> Report {
    match sub.spec.harness {
        Harness::Stdio => {}
        // `#[test]` and a generated manifest: a different job, in `cargo.rs`.
        Harness::Cargo => return crate::cargo::run(sub),
        Harness::Gotest => {
            // Refused rather than approximated. The server asks
            // [`crate::unsupported`] first and never gets here.
            return Report::internal(format!(
                "the {} harness is not a rust harness (SPEC §5.2)",
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
    let source_path = sub.workdir.join("main.rs");
    std::fs::write(&source_path, sub.source)?;
    let binary = sub.workdir.join("prog");

    (sub.events)(Event::Stage("compiling"));
    // rustc's diagnostics are JSON, one per line, on stderr; the player is
    // shown each one's `rendered` text and never the object around it.
    let lines = CompileLines::new(sub.events.clone(), rendered_line);
    let compile_logs = lines.sink();

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
    // The compiler runs in the toolchain allowlist (`harness::toolchain_base`:
    // enough for the rustup shim to pick a toolchain, and nothing of the
    // server's own) with the scratch redirected so nothing outside the home
    // is written (§1).
    crate::harness::toolchain_base(&mut rustc, &sub.workdir);
    rustc
        .env("CARGO_HOME", sub.cache_root.join("cargo-home"))
        .env("CARGO_TARGET_DIR", sub.cache_root.join("target"));

    let compile = proc::run(
        rustc,
        b"",
        &Limits {
            timeout: Duration::from_millis(sub.spec.compile_timeout_ms),
            max_stdout: 1 << 20,
            max_stderr: 4 << 20,
            apply_rlimits: false,
            address_space: false,
        },
        // Two labels, because the two pipes are drained by two threads and
        // each needs its own line buffer. Both reach the player as
        // `stream: "compile"`.
        "rustc-stdout",
        "rustc-stderr",
        compile_logs,
    );
    lines.flush();
    let compile = compile?;

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
