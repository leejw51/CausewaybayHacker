//! Running a submission (SPEC §5).
//!
//! One attempt, one directory under `~/.causewaybayhacker/build/<lang>/<id>/`.
//! Nothing is written outside the home — no `/tmp`, no project directory.

use std::path::PathBuf;
use std::sync::Arc;

use serde::Serialize;

pub mod cargo;
pub mod format;
pub mod go;
pub mod gotest;
pub mod harness;
pub mod proc;
pub mod reap;
pub mod rust;
pub mod spec;
pub mod suite;

pub use spec::{Case, Harness, MatchMode, TestSpec};

/// What the player sees while the attempt is in flight (SPEC §6.2's
/// `run.stage` and `run.log`).
#[derive(Debug, Clone)]
pub enum Event {
    Stage(&'static str),
    Log { stream: String, chunk: String },
}

pub type Events = Arc<dyn Fn(Event) + Send + Sync>;

pub fn no_events() -> Events {
    Arc::new(|_| {})
}

pub struct Submission<'a> {
    pub attempt_id: &'a str,
    pub lang: &'a str,
    pub source: &'a str,
    pub spec: &'a TestSpec,
    /// `build/<lang>/<attempt_id>/`, already chosen by the caller from the
    /// home; the runner does not know where the home is.
    pub workdir: PathBuf,
    /// Where `CARGO_HOME` / `CARGO_TARGET_DIR` point, so the first build is
    /// the slow one and the rest are not (§5.1).
    pub cache_root: PathBuf,
    pub events: Events,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Accepted,
    WrongAnswer,
    CompileError,
    RuntimeError,
    Timeout,
    OutputLimit,
    InternalError,
}

impl Verdict {
    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Accepted => "accepted",
            Verdict::WrongAnswer => "wrong_answer",
            Verdict::CompileError => "compile_error",
            Verdict::RuntimeError => "runtime_error",
            Verdict::Timeout => "timeout",
            Verdict::OutputLimit => "output_limit",
            Verdict::InternalError => "internal_error",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CaseResult {
    pub name: String,
    pub passed: bool,
    pub visible: bool,
    /// Only ever populated for a visible case: a hidden case reports pass or
    /// fail and its name, never its data (§5.2).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stdin: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expect: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub got: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Report {
    pub verdict: Verdict,
    pub compile_ms: i64,
    pub run_ms: i64,
    pub exit_code: Option<i64>,
    pub stdout_bytes: i64,
    pub tests_passed: i64,
    pub tests_total: i64,
    pub cases: Vec<CaseResult>,
    /// `rustc`'s JSON diagnostics, kept raw so §7.1 can classify them.
    pub compiler_stderr: String,
    pub runtime_stderr: String,
    pub stdout: String,
}

impl Report {
    pub fn internal(message: impl Into<String>) -> Report {
        Report {
            verdict: Verdict::InternalError,
            compile_ms: 0,
            run_ms: 0,
            exit_code: None,
            stdout_bytes: 0,
            tests_passed: 0,
            tests_total: 0,
            cases: Vec::new(),
            compiler_stderr: String::new(),
            runtime_stderr: message.into(),
            stdout: String::new(),
        }
    }

    /// What lands in `attempts/<id>/result.json`.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::to_value(self).unwrap_or_else(|_| serde_json::json!({}))
    }
}

/// Why this build cannot judge a submission, if it cannot.
///
/// Asked **before** an attempt is created. An attempt whose verdict the server
/// invented flows into `mistakes`, then `mistake_stats`, then the drills, and
/// the player is taught to fix something they never did — the whole curriculum
/// is derived from that table (SPEC §7), so nothing may enter it that did not
/// really happen.
pub fn unsupported(lang: &str, spec: &TestSpec) -> Option<String> {
    match (lang, spec.harness) {
        // All three harnesses are built. What is still refused is a harness
        // asked of the wrong land, which is an authoring mistake rather than a
        // missing feature and should say so.
        ("rust" | "go", Harness::Stdio) => None,
        ("rust", Harness::Cargo) => None,
        ("go", Harness::Gotest) => None,
        ("rust", Harness::Gotest) => {
            Some("the gotest harness is not a rust harness (SPEC §5.2)".into())
        }
        ("go", Harness::Cargo) => Some("the cargo harness is not a go harness (SPEC §5.2)".into()),
        (other, _) => Some(format!("there is no runner for '{other}'")),
    }
}

/// Dispatch on the land. A language or harness this build cannot judge comes
/// back as an `internal_error` report rather than a panic — though the server
/// refuses one before it gets here, having asked [`unsupported`] first.
pub fn run(sub: &Submission) -> Report {
    match sub.lang {
        "rust" => rust::run(sub),
        "go" => go::run(sub),
        other => Report::internal(format!("unknown language '{other}'")),
    }
}
