//! The playground (PROTOCOL §4.9c): free code, run it, and a scratchpad that
//! follows the player between clients.

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use cwbhacker_core::error::{bad_request, internal, unavailable, Result};
use cwbhacker_core::{attempts, ids, mistakes, snippets};
use cwbhacker_runner::{Event, Submission, TestSpec, Verdict};
use serde_json::json;

use crate::handlers::Session;
use crate::proto::{opt_str_field, str_field, Out};
use crate::state::Shared;
use crate::submit::{Streamer, MAX_SOURCE_BYTES};

/// A scratchpad has no test spec to take a clock from, so it gets the same
/// defaults a quest does when it does not say (SPEC §5.2).
const PLAYGROUND_TIMEOUT_MS: u64 = 5_000;
const PLAYGROUND_COMPILE_TIMEOUT_MS: u64 = 60_000;

/// Blocking. Call it from `spawn_blocking`.
/// The address is taken and deliberately unused: nothing about a playground
/// run is scoped to a player because nothing about it is stored. The argument
/// stays so the signature matches the other two execution paths and so this
/// comment has somewhere to live.
pub fn run(
    state: &Shared,
    _address: &str,
    payload: &serde_json::Value,
    out: &Out,
) -> Result<serde_json::Value> {
    let lang = str_field(payload, "lang")?;
    let source = str_field(payload, "source")?;
    let stdin = opt_str_field(payload, "stdin").unwrap_or_default();
    if source.len() > MAX_SOURCE_BYTES {
        return Err(bad_request(format!(
            "source is {} bytes; the limit is {MAX_SOURCE_BYTES}",
            source.len()
        )));
    }

    // SPEC §5.3's limits apply unchanged. This is the one place a player runs
    // genuinely arbitrary code, so it is the last place to relax any of them:
    // same runner, same timeout, same output cap, same stripped environment,
    // same process group.
    let spec = TestSpec::playground(&stdin, PLAYGROUND_TIMEOUT_MS, PLAYGROUND_COMPILE_TIMEOUT_MS);
    if let Some(reason) = cwbhacker_runner::unsupported(&lang, &spec) {
        return Err(unavailable(reason, 2));
    }

    // The id is minted so the client can correlate the stream, and then
    // deliberately thrown away — nothing about this run is stored.
    let attempt_id = ids::attempt_id();
    let queued = state.running.fetch_add(1, Ordering::SeqCst);
    let streamer = Arc::new(Streamer {
        attempt_id: attempt_id.clone(),
        out: out.clone(),
        started: Instant::now(),
        seqs: Mutex::new(Vec::new()),
        streamed: Default::default(),
        truncated: Default::default(),
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

    // -----------------------------------------------------------------
    // Nothing is recorded. No `attempts` row, no `mistakes` row, nothing
    // touching `progress`, `stars` or `accuracy`.
    //
    // This is the opposite of the RUN/SUBMIT rule in PROTOCOL §4.9b, where a
    // quest RUN *does* feed the curriculum, and it looks like an inconsistency
    // until you see the join. A quest RUN is an attempt at a known problem, so
    // its errors say something about what the player cannot yet do, and SPEC
    // §7.3's `weakness` plan reaches them through that quest's `concepts`. A
    // playground has no quest and therefore no concepts: a `mistakes` row from
    // here could never be joined to anything, and it would be dead weight in
    // the one table the whole curriculum is derived from.
    //
    // And a scratchpad is where somebody deliberately writes something broken
    // to see what the compiler says. That is the last thing that should count
    // against them.
    //
    // Please do not "fix" this.
    // -----------------------------------------------------------------
    let mut diagnostics = mistakes::classify_compile(&lang, &report.compiler_stderr);
    diagnostics.extend(mistakes::classify_runtime(&lang, &report.runtime_stderr));

    let human_stderr = if report.compiler_stderr.trim().is_empty() {
        report.runtime_stderr.clone()
    } else {
        let rendered = if lang == "rust" {
            mistakes::rendered_from_json(&report.compiler_stderr)
        } else {
            report.compiler_stderr.clone()
        };
        format!("{rendered}{}", report.runtime_stderr)
    };

    let outcome = match report.verdict {
        Verdict::CompileError => "compile_error",
        Verdict::Timeout => "timeout",
        Verdict::OutputLimit => "output_limit",
        Verdict::RuntimeError => "runtime_error",
        // There is nothing to be right or wrong about in a scratchpad, so the
        // harness's comparison against an empty expectation is discarded.
        Verdict::Accepted | Verdict::WrongAnswer => "ok",
        Verdict::InternalError => {
            return Err(internal(format!("the runner: {}", report.runtime_stderr)))
        }
    };

    Ok(json!({
        "run": {
            "attempt_id": attempt_id,
            "lang": lang,
            "outcome": outcome,
            "compile_ms": report.compile_ms,
            "run_ms": report.run_ms,
            "exit_code": report.exit_code,
            "stdout": report.stdout,
            "stderr": attempts::truncate_stderr(&human_stderr),
            "diagnostics": diagnostics,
        }
    }))
}

pub fn list(state: &Shared, session: &Session) -> Result<serde_json::Value> {
    let address = session.address()?;
    let conn = state.store.conn();
    Ok(json!({ "snippets": snippets::list(&conn, address)? }))
}

pub fn load(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let id = str_field(payload, "id")?;
    let conn = state.store.conn();
    Ok(json!({ "snippet": snippets::get(&conn, address, &id)? }))
}

pub fn save(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let id = opt_str_field(payload, "id");
    let name = opt_str_field(payload, "name");
    let lang = str_field(payload, "lang")?;
    let source = str_field(payload, "source")?;
    let conn = state.store.conn();
    let snippet = snippets::save(
        &conn,
        state.store.home(),
        address,
        id.as_deref(),
        name.as_deref(),
        &lang,
        &source,
    )?;
    Ok(json!({ "snippet": snippet }))
}

pub fn delete(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let id = str_field(payload, "id")?;
    let conn = state.store.conn();
    snippets::delete(&conn, state.store.home(), address, &id)?;
    Ok(json!({ "id": id, "deleted": true }))
}
