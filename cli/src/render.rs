//! Turning the protocol's shapes into something worth reading in a terminal.
//!
//! PROTOCOL §3.3: *"`message` is English, one line, for a log or a developer —
//! **not** for the player. A client renders its own text from `code`."* So
//! `explain` below is this client's half of that contract, and it is
//! exhaustive over §3.3's closed set on purpose: adding a code to the enum
//! without writing a sentence for it will not compile.

use crate::error::{Code, Error};
use crate::proto::{Attempt, Quest};

// ------------------------------------------------------------------ colour

/// ANSI, but only when somebody is watching. `NO_COLOR` is honoured because a
/// terminal client that ignores it is a terminal client written by someone who
/// does not use terminals.
pub fn colour_enabled() -> bool {
    use std::io::IsTerminal;
    if std::env::var_os("NO_COLOR").is_some() {
        return false;
    }
    if std::env::var("TERM").map(|t| t == "dumb").unwrap_or(false) {
        return false;
    }
    std::io::stdout().is_terminal()
}

pub struct Paint {
    on: bool,
}

impl Paint {
    pub fn new() -> Paint {
        Paint {
            on: colour_enabled(),
        }
    }
    pub fn plain() -> Paint {
        Paint { on: false }
    }
    fn wrap(&self, code: &str, text: &str) -> String {
        if self.on {
            format!("\x1b[{code}m{text}\x1b[0m")
        } else {
            text.to_string()
        }
    }
    pub fn bold(&self, text: &str) -> String {
        self.wrap("1", text)
    }
    pub fn dim(&self, text: &str) -> String {
        self.wrap("2", text)
    }
    pub fn green(&self, text: &str) -> String {
        self.wrap("32", text)
    }
    pub fn red(&self, text: &str) -> String {
        self.wrap("31", text)
    }
    pub fn yellow(&self, text: &str) -> String {
        self.wrap("33", text)
    }
    pub fn cyan(&self, text: &str) -> String {
        self.wrap("36", text)
    }
    pub fn magenta(&self, text: &str) -> String {
        self.wrap("35", text)
    }
}

impl Default for Paint {
    fn default() -> Self {
        Paint::new()
    }
}

// ------------------------------------------------------------------ errors

/// The player-facing sentence for a wire error, written from `code`.
///
/// §3.3 draws one line hard: **`unavailable` is not `internal`.** A feature
/// that is real and merely unbuilt says so; reporting it as a crash "tells the
/// player their machine is broken and invites them to retry something that
/// will never work."
pub fn explain(error: &Error) -> String {
    let milestone = milestone_phrase(error);
    match error.code.effective() {
        Code::ProtoVersion => {
            let supported = error
                .detail
                .get("supported")
                .map(|v| v.to_string())
                .unwrap_or_else(|| "[1]".into());
            format!("this client speaks protocol v1; the server wants {supported}. Update cwbh.")
        }
        Code::BadRequest => format!(
            "the server refused the frame this client sent. That is a bug in cwbh: {}",
            error.message
        ),
        Code::Unauthorized => "not logged in. Run `cwbh login`.".to_string(),
        Code::AuthExpired => "that challenge expired — logins are good for two minutes. Try again.".to_string(),
        Code::AuthNonceUsed => "that challenge was already spent. Try `cwbh login` again.".to_string(),
        Code::AuthBadSignature => {
            "the signature did not recover to that address — the key is not the one the server expected.".to_string()
        }
        Code::NotFound => format!("no such thing on this server: {}", error.message),
        // §4.7: no longer emitted. If one ever arrives, say something true.
        Code::Locked => "that node is locked on this server.".to_string(),
        Code::RateLimited => {
            let wait = error
                .detail
                .get("retry_after_ms")
                .and_then(|v| v.as_i64())
                .map(|ms| format!(" Wait {:.1}s.", ms as f64 / 1000.0))
                .unwrap_or_default();
            format!("too many requests.{wait}")
        }
        Code::Busy => {
            "a run is already in flight on this connection. One at a time (PROTOCOL §3.2).".to_string()
        }
        Code::Unavailable => match &milestone {
            Some(m) => format!("that part of Causeway Bay is not open yet — it arrives in {m}."),
            None => "that part of Causeway Bay is not open yet.".to_string(),
        },
        Code::Internal => {
            let trace = error
                .detail_str("trace_id")
                .map(|t| format!(" (trace {t})"))
                .unwrap_or_default();
            format!("the server broke{trace}. Worth retrying; the log is in ~/.causewaybayhacker/logs.")
        }
        Code::Disconnected => format!("the connection dropped: {}", error.message),
        Code::Malformed => format!(
            "this client could not read the server's reply — the two disagree about a payload \
             shape (PROTOCOL §5): {}",
            error.message
        ),
        Code::Usage | Code::InvalidMnemonic | Code::InvalidPrivateKey | Code::Io => {
            error.message.clone()
        }
        // `effective()` has already mapped Unknown to Internal, so this arm is
        // unreachable — but writing it out keeps the match exhaustive without
        // a wildcard, which is what makes a new code a compile error.
        Code::Unknown(_) => error.message.clone(),
    }
}

/// §3.3 requires `unavailable` to carry `detail.milestone`, and shows a client
/// saying *"the GO land opens in the next chapter"* — which reads as a phrase.
/// The server sends an **integer** (`{"milestone": 2}`, from
/// `backend/server/src/handlers.rs`). The type is not written down anywhere, so
/// this accepts either rather than silently dropping the one it did not expect
/// and printing a sentence with a hole in it.
fn milestone_phrase(error: &Error) -> Option<String> {
    match error.detail.get("milestone") {
        Some(serde_json::Value::String(text)) if !text.is_empty() => Some(text.clone()),
        Some(serde_json::Value::Number(n)) => Some(format!("milestone {n}")),
        _ => None,
    }
}

// ------------------------------------------------------------------ pieces

pub fn stars(count: i64) -> String {
    let filled = count.clamp(0, 3) as usize;
    format!("{}{}", "★".repeat(filled), "☆".repeat(3 - filled))
}

pub fn difficulty(level: i64) -> String {
    let level = level.clamp(0, 5) as usize;
    format!("{}{}", "●".repeat(level), "·".repeat(5 - level))
}

pub fn state_mark(paint: &Paint, state: &str) -> String {
    match state {
        "cleared" => paint.green("✓"),
        _ => paint.dim("·"),
    }
}

pub fn verdict(paint: &Paint, verdict: &str) -> String {
    match verdict {
        "accepted" => paint.green("ACCEPTED"),
        "wrong_answer" => paint.red("WRONG ANSWER"),
        "compile_error" => paint.red("COMPILE ERROR"),
        "runtime_error" => paint.red("RUNTIME ERROR"),
        "timeout" => paint.yellow("TIMEOUT"),
        "output_limit" => paint.yellow("OUTPUT LIMIT"),
        "internal_error" => paint.red("INTERNAL ERROR"),
        // An added verdict renders as itself rather than as nothing.
        other => paint.yellow(&other.to_uppercase().replace('_', " ")),
    }
}

/// Indent a block so compiler output and briefs sit inside the page.
pub fn indent(text: &str, prefix: &str) -> String {
    text.lines()
        .map(|line| {
            if line.is_empty() {
                String::new()
            } else {
                format!("{prefix}{line}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Make whitespace visible in a test case's expected/actual output. A trailing
/// newline that is the entire difference between pass and fail has to be
/// something you can see.
pub fn visible_whitespace(text: &str) -> String {
    text.replace('\n', "⏎\n")
}

pub fn quest_header(paint: &Paint, quest: &Quest) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "{}  {}\n",
        paint.bold(&quest.title),
        paint.dim(&quest.id)
    ));
    out.push_str(&format!(
        "  {} {}   difficulty {}   {} {}\n",
        state_mark(paint, &quest.state),
        quest.state,
        difficulty(quest.difficulty),
        stars(quest.stars),
        if quest.hints_total > 0 {
            paint.dim(&format!(
                "  hints {}/{}",
                quest.hints_used, quest.hints_total
            ))
        } else {
            String::new()
        }
    ));
    out
}

/// One line summarising an attempt, used by `run`, `submit` and `play`.
pub fn attempt_line(paint: &Paint, attempt: &Attempt) -> String {
    let tests = format!("{}/{}", attempt.tests_passed, attempt.tests_total);
    let timing = format!("compile {}ms  run {}ms", attempt.compile_ms, attempt.run_ms);
    format!(
        "{}  {} tests  {}",
        verdict(paint, &attempt.verdict),
        if attempt.tests_passed == attempt.tests_total && attempt.tests_total > 0 {
            paint.green(&tests)
        } else {
            paint.red(&tests)
        },
        paint.dim(&timing)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::Error;

    #[test]
    fn unavailable_is_not_a_crash_report() {
        let error = Error::new(Code::Unavailable, "search (SPEC §8) is not built yet")
            .with_detail(serde_json::json!({ "milestone": "the next chapter" }));
        let text = explain(&error);
        assert!(text.contains("not open yet"));
        assert!(text.contains("the next chapter"));
        assert!(!text.to_lowercase().contains("broke"));
        assert!(!text.to_lowercase().contains("retry"));
    }

    /// The live server's actual shape, which §3.3 does not pin: an integer.
    #[test]
    fn a_numeric_milestone_still_reaches_the_sentence() {
        let error = Error::new(
            Code::Unavailable,
            "search (SPEC §8) is not in this build yet",
        )
        .with_detail(serde_json::json!({ "milestone": 2 }));
        assert!(
            explain(&error).contains("milestone 2"),
            "{}",
            explain(&error)
        );
        // And an absent one does not leave a hole in the sentence.
        let bare = Error::new(Code::Unavailable, "x");
        assert!(!explain(&bare).contains("arrives in"));
    }

    #[test]
    fn internal_offers_a_retry_and_a_trace() {
        let error = Error::new(Code::Internal, "boom")
            .with_detail(serde_json::json!({ "trace_id": "t-9" }));
        let text = explain(&error);
        assert!(text.contains("t-9"));
        assert!(text.contains("retrying"));
    }

    /// §8.4: an unknown code behaves exactly as `internal` does — including
    /// the sentence the player reads.
    #[test]
    fn an_unknown_code_reads_as_internal() {
        let unknown = Error::new(Code::from_wire("ionic_storm"), "boom");
        let internal = Error::new(Code::Internal, "boom");
        assert_eq!(explain(&unknown), explain(&internal));
    }

    #[test]
    fn every_code_has_a_sentence() {
        for code in [
            Code::ProtoVersion,
            Code::BadRequest,
            Code::Unauthorized,
            Code::AuthExpired,
            Code::AuthNonceUsed,
            Code::AuthBadSignature,
            Code::NotFound,
            Code::Locked,
            Code::RateLimited,
            Code::Busy,
            Code::Unavailable,
            Code::Internal,
        ] {
            let text = explain(&Error::new(code.clone(), "log line"));
            assert!(!text.trim().is_empty(), "{code:?} has no sentence");
        }
    }

    #[test]
    fn stars_and_difficulty_are_fixed_width() {
        assert_eq!(stars(0).chars().count(), 3);
        assert_eq!(stars(3).chars().count(), 3);
        assert_eq!(stars(9).chars().count(), 3);
        assert_eq!(difficulty(5).chars().count(), 5);
    }

    #[test]
    fn an_unseen_verdict_still_renders() {
        let paint = Paint::plain();
        assert_eq!(verdict(&paint, "memory_limit"), "MEMORY LIMIT");
    }
}
