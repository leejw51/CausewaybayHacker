//! `quest.submit` (SPEC §6.2): compile, run, judge, record.
//!
//! This is the one handler that blocks for seconds, so it runs on a blocking
//! thread and streams `run.stage` / `run.log` through the connection's writer
//! while the original request is still unanswered (§5.4).

use std::sync::Arc;

use cwbhacker_core::error::{bad_request, locked, Result};
use cwbhacker_core::{attempts, ids, mistakes, progress, quests, world};
use cwbhacker_runner::{Event, Submission, TestSpec, Verdict};
use serde_json::json;
use tokio::sync::mpsc::UnboundedSender;

use crate::proto::{opt_str_field, str_field, ServerFrame};
use crate::state::Shared;

/// Blocking. Call it from `spawn_blocking`.
pub fn run(
    state: &Shared,
    address: &str,
    payload: &serde_json::Value,
    out: &UnboundedSender<ServerFrame>,
) -> Result<serde_json::Value> {
    let quest_id = str_field(payload, "quest_id")?;
    let source = str_field(payload, "source")?;
    let quest = {
        let conn = state.store.conn();
        let quest = quests::get(&conn, &quest_id)?;
        if world::state_of(&conn, address, &quest_id)? == progress::State::Locked {
            return Err(locked("that node is still locked"));
        }
        quest
    };
    // The lang is the quest's land. A payload that disagrees is a bug in the
    // client, not a choice the player gets to make.
    let lang = opt_str_field(payload, "lang").unwrap_or_else(|| quest.land.clone());
    if lang != quest.land {
        return Err(bad_request(format!(
            "quest '{quest_id}' is a {} quest, not {lang}",
            quest.land
        )));
    }
    let spec = TestSpec::parse(&quest.tests)?;

    let attempt_id = ids::attempt_id();
    {
        let conn = state.store.conn();
        progress::bump_attempt(&conn, address, &quest_id)?;
    }

    let _ = out.send(ServerFrame::event(
        "run.stage",
        json!({ "attempt_id": attempt_id, "stage": "queued" }),
    ));

    let home = state.store.home();
    let events_tx = out.clone();
    let events_attempt = attempt_id.clone();
    let submission = Submission {
        attempt_id: &attempt_id,
        lang: &lang,
        source: &source,
        spec: &spec,
        workdir: home.attempt_build_dir(&lang, &attempt_id),
        cache_root: home.build_lang_dir(&lang),
        events: Arc::new(move |event| match event {
            Event::Stage(stage) => {
                let _ = events_tx.send(ServerFrame::event(
                    "run.stage",
                    json!({ "attempt_id": events_attempt, "stage": stage }),
                ));
            }
            Event::Log { stream, chunk } => {
                let _ = events_tx.send(ServerFrame::event(
                    "run.log",
                    json!({ "attempt_id": events_attempt, "stream": stream, "chunk": chunk }),
                ));
            }
        }),
    };

    let report = cwbhacker_runner::run(&submission);

    // §7.1, always — not only on a compile error. `unused_variables` and
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

    let cleared;
    let stars;
    let cleared_total;
    {
        let conn = state.store.conn();
        attempts::insert(&conn, &record)?;
        mistakes::record(&conn, &attempt_id, address, &quest_id, &found)?;
        if report.verdict == Verdict::Accepted {
            let row = progress::record_clear(
                &conn,
                address,
                &quest_id,
                report.compile_ms + report.run_ms,
            )?;
            cleared = true;
            stars = row.stars;
        } else {
            let row = progress::get(&conn, address, &quest_id)?;
            cleared = row.cleared;
            stars = row.stars;
        }
        cleared_total = progress::cleared_total(&conn, address)?;
    }

    // The whole streams go to disk; the database keeps the truncated copy
    // (§2.2). Attempts are never deleted by the server — they are §7's data.
    let result_json = report.to_json();
    attempts::write_to_disk(
        state.store.home(),
        &record,
        &report.stdout,
        &format!("{}{}", report.compiler_stderr, report.runtime_stderr),
        &result_json,
    )?;

    if report.verdict == Verdict::Accepted {
        let _ = out.send(ServerFrame::event(
            "progress.update",
            json!({
                "quest_id": quest_id,
                "state": "cleared",
                "stars": stars,
                "cleared_total": cleared_total,
            }),
        ));
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
            "stderr": attempts::truncate_stderr(&human_stderr),
            "cases": report.cases,
            "mistakes": found,
            "stars": stars,
            "cleared": cleared,
            "created_at": record.created_at,
        }
    }))
}
