//! Watching a run happen.
//!
//! Streaming is a terminal's home ground: there is no canvas to repaint, no
//! frame budget, and `rustc`'s own output is already text. So `run.log` chunks
//! are shown **as they arrive**, and `run.stage` gets one dim line with the
//! server's own elapsed clock beside it.
//!
//! Two rules from PROTOCOL §4.18 shape the whole thing:
//!
//! * *"Chunks are UTF-8 and may split anywhere, including mid-line; a client
//!   must buffer rather than assume lines."* Nothing here treats a chunk as a
//!   line. `stdout` and `stderr` are printed byte for byte the instant they
//!   land; `compile` is accumulated into a `pending` buffer and consumed a
//!   completed line at a time, for the reason below.
//! * *"`seq` counts from 0 per stream per attempt, so a client can detect a
//!   gap."* `LogStreams` counts, and a gap is said out loud rather than
//!   quietly producing wrong output.
//!
//! **What the `compile` stream actually carries.** §4.18's example shows
//! `"chunk": "error[E0382]: borrow of moved value: \`s\`\n"` — rendered text.
//! The server does not send that. SPEC §5.1 compiles with
//! `rustc --error-format=json`, and `backend/server/src/submit.rs` streams the
//! compiler's stderr verbatim, so what arrives on `compile` for a Rust attempt
//! is one JSON diagnostic object per line, each several kilobytes of
//! explanation. Printed raw it is unreadable — which is a plausible reason
//! nobody had watched this stream before. So a line that parses as a rustc
//! diagnostic is shown as its own `rendered` field, which is exactly the text
//! §4.18's example promised; anything else (Go's `go build`, a linker, a
//! panic) is passed through untouched.
//!
//! And §4.21: events keep arriving *"including after the request they relate
//! to has already been answered"*, so `progress.update` and `award` are
//! collected rather than printed into the middle of the compiler's output.

use std::collections::HashMap;
use std::io::Write;
use std::time::Instant;

use causewaybay_hacker_cli::client::LogStreams;
use causewaybay_hacker_cli::proto::{Award, Frame, ProgressUpdate, RunLog, RunStage};
use causewaybay_hacker_cli::render::Paint;

pub struct Watcher {
    paint: Paint,
    pub streams: LogStreams,
    started: Instant,
    /// Partial text per stream — §4.18's "buffer rather than assume lines".
    pending: HashMap<String, String>,
    /// Which stream the cursor is currently inside, so a switch from `compile`
    /// to `stdout` gets a header and a same-stream chunk does not.
    current: Option<String>,
    /// Whether the last byte printed was a newline, so a header lands on a
    /// line of its own without inventing blank lines.
    at_line_start: bool,
    pub stages: Vec<(String, i64)>,
    /// When the first `run.log` chunk of each stream arrived, measured from
    /// the moment the request went out. This is the number that says whether
    /// output really streamed or merely arrived with the reply.
    pub first_chunk_ms: Vec<(String, u128)>,
    pub progress: Vec<ProgressUpdate>,
    pub awards: Vec<Award>,
    pub bye: Option<String>,
    /// §2.3 / §8.3: a type this client does not know is ignored, not an error.
    pub ignored_types: Vec<String>,
    quiet: bool,
    raw: bool,
}

impl Watcher {
    pub fn new(paint: Paint, quiet: bool) -> Watcher {
        Watcher {
            paint,
            streams: LogStreams::default(),
            started: Instant::now(),
            pending: HashMap::new(),
            current: None,
            at_line_start: true,
            stages: Vec::new(),
            first_chunk_ms: Vec::new(),
            progress: Vec::new(),
            awards: Vec::new(),
            bye: None,
            ignored_types: Vec::new(),
            quiet,
            raw: false,
        }
    }

    /// Show the compile stream exactly as it comes off the wire, JSON and all.
    pub fn raw(mut self, raw: bool) -> Watcher {
        self.raw = raw;
        self
    }

    /// Restart the clock at the instant the request leaves.
    pub fn mark_sent(&mut self) {
        self.started = Instant::now();
    }

    pub fn elapsed_ms(&self) -> u128 {
        self.started.elapsed().as_millis()
    }

    /// The event sink handed to `Conn::request_with`.
    pub fn on_frame(&mut self, frame: &Frame) {
        match frame.kind.as_str() {
            "run.stage" => {
                if let Ok(stage) = serde_json::from_value::<RunStage>(frame.payload.clone()) {
                    self.on_stage(&stage);
                }
            }
            "run.log" => {
                if let Ok(log) = serde_json::from_value::<RunLog>(frame.payload.clone()) {
                    self.on_log(&log);
                }
            }
            "progress.update" => {
                if let Ok(update) = serde_json::from_value::<ProgressUpdate>(frame.payload.clone())
                {
                    self.progress.push(update);
                }
            }
            "award" => {
                if let Ok(award) = serde_json::from_value::<Award>(frame.payload.clone()) {
                    self.awards.push(award);
                }
            }
            "server.bye" => {
                self.bye = Some(
                    frame
                        .payload
                        .get("reason")
                        .and_then(|v| v.as_str())
                        .unwrap_or("unstated")
                        .to_string(),
                );
            }
            // §2.3: "A client must ignore an unknown `type` rather than
            // erroring or closing. That is what lets the server add events
            // without breaking an old client."
            other => self.ignored_types.push(other.to_string()),
        }
    }

    fn on_stage(&mut self, stage: &RunStage) {
        self.stages.push((stage.stage.clone(), stage.elapsed_ms));
        if self.quiet {
            return;
        }
        self.end_line();
        let queue = if stage.stage == "queued" && stage.queued > 0 {
            format!(" ({} ahead)", stage.queued)
        } else {
            String::new()
        };
        println!(
            "  {} {}{}",
            self.paint.dim(&format!("{:>6}ms", stage.elapsed_ms)),
            self.paint.cyan(&stage.stage),
            self.paint.dim(&queue)
        );
        let _ = std::io::stdout().flush();
    }

    fn on_log(&mut self, log: &RunLog) {
        let contiguous = self
            .streams
            .accept(&log.attempt_id, &log.stream, log.seq, &log.chunk);
        if !self.first_chunk_ms.iter().any(|(s, _)| *s == log.stream) {
            self.first_chunk_ms
                .push((log.stream.clone(), self.started.elapsed().as_millis()));
        }
        if self.quiet {
            return;
        }

        self.stream_header(&log.stream);
        if !contiguous {
            self.end_line();
            println!(
                "  {}",
                self.paint
                    .yellow(&format!("(a chunk of {} went missing)", log.stream))
            );
        }

        if log.stream != "compile" || self.raw {
            // Program output. Printed exactly as it came, with no line
            // assumption anywhere — half a line is visible the instant it
            // exists, which is the whole point.
            self.emit(&log.chunk);
            return;
        }

        // The compile stream. Accumulate, then consume whole lines; a chunk
        // that splits a diagnostic in half waits for its other half rather
        // than being rendered as garbage.
        let pending = self.pending.entry(log.stream.clone()).or_default();
        pending.push_str(&log.chunk);
        let mut ready: Vec<String> = Vec::new();
        while let Some(index) = pending.find('\n') {
            let line: String = pending.drain(..=index).collect();
            ready.push(line);
        }
        for line in ready {
            let text = render_compile_line(&line);
            self.emit(&text);
        }
    }

    fn stream_header(&mut self, stream: &str) {
        if self.current.as_deref() == Some(stream) {
            return;
        }
        self.end_line();
        println!(
            "  {} {}",
            self.paint
                .dim(&format!("{:>6}ms", self.started.elapsed().as_millis())),
            self.paint.magenta(&format!("─── {} ───", stream))
        );
        self.current = Some(stream.to_string());
        self.at_line_start = true;
    }

    fn emit(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        print!("{text}");
        let _ = std::io::stdout().flush();
        self.at_line_start = text.ends_with('\n');
    }

    /// Close off a partial line before printing something of our own, without
    /// inventing a blank one.
    pub fn end_line(&mut self) {
        if !self.at_line_start {
            println!();
            self.at_line_start = true;
        }
    }

    /// Flush whatever never got its newline. A compiler killed by a timeout
    /// leaves exactly this.
    pub fn finish(&mut self) {
        let leftovers: Vec<String> = self
            .pending
            .values_mut()
            .filter(|p| !p.is_empty())
            .map(std::mem::take)
            .collect();
        for leftover in leftovers {
            let text = render_compile_line(&leftover);
            self.emit(&text);
        }
        self.end_line();
        let _ = std::io::stdout().flush();
    }

    /// One line of evidence: did output really stream, or did it arrive with
    /// the reply?
    pub fn timing_note(&self) -> String {
        let total = self.elapsed_ms();
        let mut parts: Vec<String> = self
            .first_chunk_ms
            .iter()
            .map(|(stream, ms)| format!("first {stream} chunk at {ms}ms"))
            .collect();
        parts.push(format!("reply at {total}ms"));
        parts.push(format!("{} bytes streamed", self.streams.total_bytes()));
        parts.join(", ")
    }
}

/// A `compile` line, made readable.
///
/// `rustc --error-format=json` emits one object per line carrying both the
/// machine-readable spans and a `rendered` string that is the human text the
/// compiler would otherwise have printed. Showing `rendered` gives the player
/// exactly what `cargo build` would have shown them. Anything that is not such
/// an object — `go build`'s plain output, a linker's complaint, a panic — is
/// passed through untouched, because guessing at it would be worse.
pub fn render_compile_line(line: &str) -> String {
    let trimmed = line.trim_end_matches(['\n', '\r']);
    if !trimmed.starts_with('{') {
        return line.to_string();
    }
    let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) else {
        return line.to_string();
    };
    match value.get("rendered").and_then(|v| v.as_str()) {
        Some(rendered) if !rendered.is_empty() => rendered.to_string(),
        // A diagnostic with no `rendered` (rustc omits it for some notes) is
        // still worth a line; the message alone beats several kilobytes of
        // span offsets.
        _ => match value.get("message").and_then(|v| v.as_str()) {
            Some(message) => format!("{message}\n"),
            None => line.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rustc_diagnostic_becomes_the_text_rustc_would_have_printed() {
        let line = r#"{"$message_type":"diagnostic","message":"mismatched types","code":{"code":"E0308"},"level":"error","spans":[],"children":[],"rendered":"error[E0308]: mismatched types\n --> main.rs:5:18\n"}"#;
        assert_eq!(
            render_compile_line(&format!("{line}\n")),
            "error[E0308]: mismatched types\n --> main.rs:5:18\n"
        );
    }

    #[test]
    fn a_diagnostic_without_rendered_falls_back_to_its_message() {
        let line = r#"{"$message_type":"diagnostic","message":"aborting","rendered":null}"#;
        assert_eq!(render_compile_line(line), "aborting\n");
    }

    /// Go's compiler, a linker, a panic: not JSON, so not touched.
    #[test]
    fn plain_compiler_output_passes_through() {
        for line in [
            "./main.go:7:2: declared and not used: n\n",
            "# command-line-arguments\n",
            "{ this is not json }\n",
            "",
        ] {
            assert_eq!(render_compile_line(line), line);
        }
    }
}
