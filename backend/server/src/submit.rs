//! `quest.submit` (PROTOCOL §4.9): compile, run, judge, record.
//!
//! This is the one handler that blocks for seconds, so it runs on a blocking
//! thread and streams `run.stage` / `run.log` through the connection's writer
//! while the original request is still unanswered. The reply is correlated by
//! the request's `id`, which is why the events must not go through it.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use cwbhacker_core::error::{bad_request, unavailable, Result};
use cwbhacker_core::{attempts, ids, mistakes, progress, quests, world};
use cwbhacker_runner::{Event, Submission, TestSpec, Verdict};
use serde_json::json;

use crate::handlers::locked_error;
use crate::proto::{opt_str_field, send, str_field, Out, ServerFrame};
use crate::state::Shared;

/// PROTOCOL §4.9: a source over 256 KiB is `bad_request`. A quest's answer is
/// a screenful; a quarter of a megabyte is a paste accident or an attack.
pub const MAX_SOURCE_BYTES: usize = 256 * 1024;

/// §4.18: the server caps total streamed bytes per attempt at 256 KiB and then
/// sends one final chunk saying so. The whole text is still on disk and the
/// 64 KiB copy is still in the `Attempt`.
const MAX_STREAM_BYTES: usize = 256 * 1024;
const TRUNCATION_CHUNK: &str = "\n…output truncated\n";

/// Per-attempt streaming bookkeeping: a `seq` counter per stream, and one
/// shared byte budget across all of them.
struct Streamer {
    attempt_id: String,
    out: Out,
    started: Instant,
    seqs: Mutex<Vec<(String, u64)>>,
    streamed: AtomicUsize,
    truncated: AtomicUsize,
}

impl Streamer {
    fn next_seq(&self, stream: &str) -> u64 {
        let mut seqs = self.seqs.lock().unwrap();
        match seqs.iter_mut().find(|(name, _)| name == stream) {
            Some((_, seq)) => {
                let current = *seq;
                *seq += 1;
                current
            }
            None => {
                seqs.push((stream.to_string(), 1));
                0
            }
        }
    }

    fn log(&self, stream: &str, chunk: &str) {
        let used = self.streamed.fetch_add(chunk.len(), Ordering::Relaxed);
        if used >= MAX_STREAM_BYTES {
            // One final chunk, once, and then silence for the rest of the run.
            if self.truncated.fetch_add(1, Ordering::Relaxed) == 0 {
                self.emit(stream, TRUNCATION_CHUNK);
            }
            return;
        }
        let room = MAX_STREAM_BYTES - used;
        if chunk.len() <= room {
            self.emit(stream, chunk);
        } else {
            let mut cut = room;
            while cut > 0 && !chunk.is_char_boundary(cut) {
                cut -= 1;
            }
            self.emit(stream, &chunk[..cut]);
            if self.truncated.fetch_add(1, Ordering::Relaxed) == 0 {
                self.emit(stream, TRUNCATION_CHUNK);
            }
        }
    }

    fn emit(&self, stream: &str, chunk: &str) {
        send(
            &self.out,
            ServerFrame::event(
                "run.log",
                json!({
                    "attempt_id": self.attempt_id,
                    "stream": stream,
                    "chunk": chunk,
                    "seq": self.next_seq(stream),
                }),
            ),
        );
    }

    fn stage(&self, stage: &str, queued: usize) {
        send(
            &self.out,
            ServerFrame::event(
                "run.stage",
                json!({
                    "attempt_id": self.attempt_id,
                    "stage": stage,
                    "queued": queued,
                    "elapsed_ms": self.started.elapsed().as_millis() as i64,
                }),
            ),
        );
    }
}

/// Blocking. Call it from `spawn_blocking`.
pub fn run(
    state: &Shared,
    address: &str,
    connection_id: u64,
    payload: &serde_json::Value,
    out: &Out,
) -> Result<serde_json::Value> {
    let quest_id = str_field(payload, "quest_id")?;
    let source = str_field(payload, "source")?;
    if source.len() > MAX_SOURCE_BYTES {
        return Err(bad_request(format!(
            "source is {} bytes; the limit is {MAX_SOURCE_BYTES}",
            source.len()
        )));
    }
    let (quest, was_cleared) = {
        let conn = state.store.conn();
        let quest = quests::get(&conn, &quest_id)?;
        if world::state_of(&conn, address, &quest_id)? == progress::State::Locked {
            return Err(locked_error(&conn, address, &quest_id));
        }
        let cleared = progress::get(&conn, address, &quest_id)?.cleared;
        (quest, cleared)
    };
    let lang = opt_str_field(payload, "lang").unwrap_or_else(|| quest.land.clone());
    if lang != quest.land {
        return Err(bad_request(format!(
            "quest '{quest_id}' is a {} quest, not {lang}",
            quest.land
        )));
    }
    let spec = TestSpec::parse(&quest.tests)?;

    // Refused before anything is written. A submission this build cannot judge
    // must leave no attempt row behind: an attempt carries a verdict, a
    // verdict carries mistakes, and `mistake_stats` is what the drills teach
    // from (SPEC §7). A fabricated verdict there teaches the player to fix
    // something they never did, and there is no way to tell it afterwards
    // from something they really got wrong.
    if let Some(reason) = cwbhacker_runner::unsupported(&lang, &spec) {
        return Err(unavailable(reason, 2));
    }

    let attempt_id = ids::attempt_id();
    {
        let conn = state.store.conn();
        progress::bump_attempt(&conn, address, &quest_id)?;
    }

    let queued = state.running.fetch_add(1, Ordering::SeqCst);
    let streamer = Arc::new(Streamer {
        attempt_id: attempt_id.clone(),
        out: out.clone(),
        started: Instant::now(),
        seqs: Mutex::new(Vec::new()),
        streamed: AtomicUsize::new(0),
        truncated: AtomicUsize::new(0),
    });
    streamer.stage("queued", queued);

    let home = state.store.home();
    let events = streamer.clone();
    let submission = Submission {
        attempt_id: &attempt_id,
        lang: &lang,
        source: &source,
        spec: &spec,
        workdir: home.attempt_build_dir(&lang, &attempt_id),
        cache_root: home.build_lang_dir(&lang),
        events: Arc::new(move |event| match event {
            Event::Stage(stage) => events.stage(stage, 0),
            Event::Log { stream, chunk } => events.log(&stream, &chunk),
        }),
    };

    let report = cwbhacker_runner::run(&submission);
    state.running.fetch_sub(1, Ordering::SeqCst);

    // SPEC §7.1, always — not only on a compile error. `unused_variables` and
    // `unused_imports` are warnings on a build that succeeded, and dropping
    // them loses a whole row of the taxonomy.
    let mut found = mistakes::classify_rust_json(&report.compiler_stderr);
    found.extend(mistakes::classify_runtime(&report.runtime_stderr));
    if let Some(m) = mistakes::verdict_mistake(
        report.verdict.as_str(),
        match report.verdict {
            Verdict::Timeout => "the program ran out of time",
            _ => "the output did not match",
        },
    ) {
        found.push(m);
    }

    let human_stderr = if report.compiler_stderr.trim().is_empty() {
        report.runtime_stderr.clone()
    } else {
        let rendered = mistakes::rendered_from_json(&report.compiler_stderr);
        if report.runtime_stderr.trim().is_empty() {
            rendered
        } else {
            format!("{rendered}{}", report.runtime_stderr)
        }
    };

    let mut record = attempts::new_record(
        attempt_id.clone(),
        address,
        &quest_id,
        &lang,
        source.clone(),
    );
    record.verdict = report.verdict.as_str().to_string();
    record.compile_ms = report.compile_ms;
    record.run_ms = report.run_ms;
    record.exit_code = report.exit_code;
    record.stdout_bytes = report.stdout_bytes;
    record.stderr = human_stderr.clone();
    record.tests_passed = report.tests_passed;
    record.tests_total = report.tests_total;

    let accepted = report.verdict == Verdict::Accepted;
    // §5.4: `cleared` answers "did *this* submission clear the node", so
    // re-solving something already cleared reports accepted with cleared false.
    let just_cleared = accepted && !was_cleared;
    let stars;
    let cleared_total;
    let unlocked;
    {
        let conn = state.store.conn();
        attempts::insert(&conn, &record)?;
        mistakes::record(&conn, &attempt_id, address, &quest_id, &found)?;
        if accepted {
            let row = progress::record_clear(
                &conn,
                address,
                &quest_id,
                report.compile_ms + report.run_ms,
            )?;
            stars = row.stars;
        } else {
            stars = progress::get(&conn, address, &quest_id)?.stars;
        }
        cleared_total = progress::cleared_total(&conn, address)?;
        unlocked = if just_cleared {
            world::unlocked_by(&conn, address, &quest_id)?
        } else {
            Vec::new()
        };
    }

    // The whole streams go to disk; the database keeps the truncated copy
    // (SPEC §2.2). Attempts are never deleted by the server — they are §7's
    // training data.
    attempts::write_to_disk(
        state.store.home(),
        &record,
        &report.stdout,
        &format!("{}{}", report.compiler_stderr, report.runtime_stderr),
        &report.to_json(),
    )?;

    if just_cleared {
        let update = ServerFrame::event(
            "progress.update",
            json!({
                "quest_id": quest_id,
                "state": "cleared",
                "stars": stars,
                "cleared_total": cleared_total,
                "unlocked": unlocked,
            }),
        );
        send(out, update.clone());
        // §4.19: the same user's other windows hear about it too.
        state.hub.broadcast(address, connection_id, &update);
        send(
            out,
            ServerFrame::event(
                "award",
                json!({
                    "kind": "stamp",
                    "id": "cleared",
                    "title": "CLEARED",
                    "detail": { "quest_id": quest_id, "stars": stars },
                }),
            ),
        );
    }

    Ok(json!({
        "attempt": {
            "id": attempt_id,
            "quest_id": quest_id,
            "verdict": record.verdict,
            "tests_passed": report.tests_passed,
            "tests_total": report.tests_total,
            "compile_ms": report.compile_ms,
            "run_ms": report.run_ms,
            "exit_code": report.exit_code,
            "stderr": attempts::truncate_stderr(&human_stderr),
            "cases": report.cases,
            "mistakes": found,
            "stars": stars,
            "cleared": just_cleared,
            "created_at": record.created_at,
        }
    }))
}
