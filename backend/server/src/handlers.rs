//! The PROTOCOL §4 message catalogue, minus `quest.submit` (which lives in
//! `submit.rs` because it streams).
//!
//! **Every handler that touches user data uses `session.address`.** An address
//! in a payload is ignored, not trusted (SPEC §3.5). The only two handlers
//! that read an address from a payload at all are `auth.challenge` and
//! `auth.login`, and both of them make the client prove it with a signature.

use cwbhacker_core::error::{bad_request, not_found, unauthorized, Error, Result};
use cwbhacker_core::Connection;
use cwbhacker_core::{
    attempts, auth, awards, drills, edits, eth, interviews, mistakes, progress, quests, search,
    stats, users, world,
};
use serde_json::json;

use crate::proto::{bool_field, i64_field, opt_i64_field, opt_str_field, str_field};
use crate::state::Shared;

/// The address this connection proved it owns. `None` until `auth.login` or
/// `auth.resume` succeeds; a connection never goes back (PROTOCOL §3.1).
#[derive(Debug, Clone, Default)]
pub struct Session {
    pub address: Option<String>,
}

impl Session {
    pub fn address(&self) -> Result<&str> {
        self.address
            .as_deref()
            .ok_or_else(|| unauthorized("log in first"))
    }

    /// PROTOCOL §3.1: a connection never goes back to ANONYMOUS, and to change
    /// user you open a new one. Authenticating twice on one socket would leave
    /// it registered in the hub under the address it used to have, so the old
    /// user's windows would hear about the new user's clears.
    pub fn must_be_anonymous(&self) -> Result<()> {
        match self.address {
            None => Ok(()),
            Some(_) => Err(bad_request(
                "this connection is already authenticated; open a new one to change user",
            )),
        }
    }

    /// The same rule for `auth.resume`, which §4.4 also lets a client use to
    /// refresh its token. Re-resuming as **the same** user is that refresh and
    /// is allowed; resuming as a different one is the connection changing
    /// user, which is the thing §3.1 forbids.
    pub fn must_not_change_user(&self, address: &str) -> Result<()> {
        match self.address.as_deref() {
            None => Ok(()),
            Some(current) if current.eq_ignore_ascii_case(address) => Ok(()),
            Some(_) => Err(bad_request(
                "this connection belongs to another address; open a new one to change user",
            )),
        }
    }
}

/// PROTOCOL §5.1. `address` is the EIP-55 spelling: checksummed on the wire in
/// both directions, lowercase only inside the server (SPEC §3.4).
pub fn user_json(conn: &Connection, user: &users::User) -> Result<serde_json::Value> {
    // XP is stars weighted by difficulty and category, and the level curve is
    // triangular (`awards.rs`). The protocol fixes the fields and not the
    // curve; the curve is written down in docs/decisions.md so the two clients
    // draw the same number.
    let xp = awards::total_xp(conn, &user.address)?;
    let level = awards::level_for_xp(xp);
    Ok(json!({
        "address": user.address_eip55,
        "name": user.name,
        "created_at": user.created_at,
        "last_seen_at": user.last_seen_at,
        "settings": user.settings,
        "level": level,
        "xp": xp,
        "xp_into_level": xp - awards::xp_for_level(level),
        "xp_for_next": awards::xp_for_level(level + 1) - awards::xp_for_level(level),
    }))
}

/// PROTOCOL §4.1: allowed in any state, and `t` is an RFC3339 timestamp.
pub fn ping() -> serde_json::Value {
    json!({ "t": cwbhacker_core::time::now_stamp() })
}

pub fn auth_challenge(state: &Shared, payload: &serde_json::Value) -> Result<serde_json::Value> {
    let address = str_field(payload, "address")?;
    let challenge = state.challenges.issue(&address)?;
    Ok(json!({
        "nonce": challenge.nonce,
        "message": challenge.message,
        "expires_at": challenge.expires_at,
    }))
}

/// §4.3, in order: burn the nonce first, then check the signature. A bad
/// signature must not leave the nonce available for another try.
pub fn auth_login(
    state: &Shared,
    session: &mut Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    session.must_be_anonymous()?;
    let address = str_field(payload, "address")?;
    let signature = str_field(payload, "signature")?;
    let name = opt_str_field(payload, "name");
    let nonce = opt_str_field(payload, "nonce");
    // Finding the challenge, checking the signature and spending the nonce are
    // one operation, because which challenge was signed is part of the answer
    // (PROTOCOL §4.3).
    let address = state
        .challenges
        .login(&address, &signature, nonce.as_deref())?;

    let conn = state.store.conn();
    let user = users::upsert_named(&conn, &address, name.as_deref())?;
    users::write_profile(state.store.home(), &user)?;
    let token = auth::mint_session(&conn, &address)?;
    let user = user_json(&conn, &user)?;
    drop(conn);

    session.address = Some(address);
    Ok(json!({ "token": token, "user": user }))
}

/// §4.4. The token is **rotated**: the one that comes back is the one to keep.
pub fn auth_resume(
    state: &Shared,
    session: &mut Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let token = str_field(payload, "token")?;
    let conn = state.store.conn();
    let (address, fresh) = auth::rotate_session(&conn, &token)?;
    session.must_not_change_user(&address)?;
    let user = users::upsert(&conn, &address)?;
    let user = user_json(&conn, &user)?;
    drop(conn);
    session.address = Some(address);
    Ok(json!({ "token": fresh, "user": user }))
}

pub fn profile_update(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let name = opt_str_field(payload, "name");
    // §4.5: `settings` is opaque and a partial one replaces the whole object.
    // The server never reads inside it.
    let settings = payload.get("settings").filter(|v| v.is_object());
    let conn = state.store.conn();
    let user = users::update_profile(&conn, address, name.as_deref(), settings)?;
    let json = user_json(&conn, &user)?;
    drop(conn);
    users::write_profile(state.store.home(), &user)?;
    Ok(json!({ "user": json }))
}

pub fn world_lands(state: &Shared, session: &Session) -> Result<serde_json::Value> {
    let address = session.address()?;
    let conn = state.store.conn();
    Ok(json!({ "lands": world::lands(&conn, address)? }))
}

pub fn world_map(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let land = str_field(payload, "land")?;
    let category = str_field(payload, "category")?;
    // PROTOCOL §4.7: `locale?` is the client's UI language. Titles come back
    // in it where a translation exists and each node says which it got.
    let locale = opt_str_field(payload, "locale");
    let conn = state.store.conn();
    let map = world::map_localized(&conn, address, &land, &category, locale.as_deref())?;
    Ok(json!({
        "land": land,
        "category": category,
        "nodes": map.nodes,
        "edges": map.edges,
    }))
}

/// Open the quest. There is nothing to refuse any more (PROTOCOL §4.7): a
/// player may enter any node at any time, and `requires` is advice the client
/// draws rather than a gate the server enforces. The function stays because
/// three handlers want the same three things, and because "the quest does not
/// exist" is still a real answer.
fn readable_quest(
    conn: &Connection,
    address: &str,
    quest_id: &str,
) -> Result<(quests::Quest, progress::State, progress::Row)> {
    let quest = quests::get(conn, quest_id)?;
    let state = world::state_of(conn, address, quest_id)?;
    Ok((quest, state, progress::get(conn, address, quest_id)?))
}

pub fn quest_get(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let quest_id = str_field(payload, "quest_id")?;
    let conn = state.store.conn();
    let (quest, quest_state, row) = readable_quest(&conn, address, &quest_id)?;
    // PROTOCOL §4.8: the prose in the client's language when a translation
    // exists, English (and `text_locale: "en"`) otherwise. An unknown locale
    // string is the second case, not an error.
    let quest = quest.localized(&conn, opt_str_field(payload, "locale").as_deref())?;
    // PROTOCOL §4.8b: opening a timed quest starts its clock, once. Untimed
    // quests never get one — there is nothing for it to count down to.
    let opened_at = if quest.time_limit_s.is_some() {
        progress::open_clock(&conn, address, &quest_id)?
    } else {
        None
    };
    // PROTOCOL §4.9e: while an interview on this quest is live, the answer
    // and the hints are absent — not rate-limited, and not restored when the
    // clock runs out. A screen does not come with hints.
    if under_interview(&conn, address, &quest_id)? {
        return Ok(json!({
            "quest": quest.to_wire_under_interview(quest_state, row.stars, opened_at.as_deref())
        }));
    }
    let draft = attempts::latest_source(&conn, address, &quest_id)?;
    Ok(json!({
        "quest": quest.to_wire(
            quest_state,
            row.stars,
            row.hints_used,
            opened_at.as_deref(),
            draft.as_deref(),
        )
    }))
}

/// PROTOCOL §4.11b. The whole answer, priced like the biggest hint there is:
/// `progress::use_solve` bumps `hints_used` to at least one, which is all
/// `stars_for` needs to stop this ever reading as a perfect clear. Nothing
/// about this writes an `attempts` row — asking for the answer is not a run,
/// and recording one would put a submission in the table that never happened.
pub fn quest_solve(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let quest_id = str_field(payload, "quest_id")?;
    let conn = state.store.conn();
    let (quest, _, _) = readable_quest(&conn, address, &quest_id)?;
    if under_interview(&conn, address, &quest_id)? {
        // Same reasoning as quest_hint: a live screen does not come with an
        // answer key, absent rather than refused-for-now.
        return Err(not_found("there is no solution on a live screen"));
    }
    let hints_used = progress::use_solve(&conn, address, &quest_id, quest.hints.len() as i64)?;
    Ok(json!({
        "source": quest.solution,
        "hints_used": hints_used,
    }))
}

fn under_interview(conn: &Connection, address: &str, quest_id: &str) -> Result<bool> {
    Ok(interviews::live(conn, address)?
        .is_some_and(|session| session.quest_id == quest_id && session.finished_at.is_none()))
}

pub fn interview_start(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let land = str_field(payload, "land")?;
    let category = opt_str_field(payload, "category");
    let conn = state.store.conn();
    let live = interviews::start(&conn, address, &land, category.as_deref())?;
    interview_json(&conn, address, &live)
}

pub fn interview_approach(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let session_id = str_field(payload, "session_id")?;
    let text = str_field(payload, "text")?;
    let conn = state.store.conn();
    let live = interviews::set_approach(&conn, address, &session_id, &text)?;
    interview_json(&conn, address, &live)
}

pub fn interview_finish(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let session_id = str_field(payload, "session_id")?;
    let conn = state.store.conn();
    Ok(json!({ "report": interviews::finish(&conn, address, &session_id)? }))
}

fn interview_json(
    conn: &Connection,
    address: &str,
    live: &interviews::Session,
) -> Result<serde_json::Value> {
    let quest = quests::get(conn, &live.quest_id)?;
    let quest_state = world::state_of(conn, address, &live.quest_id)?;
    let row = progress::get(conn, address, &live.quest_id)?;
    Ok(json!({
        "session": {
            "id": live.id,
            "quest": quest.to_wire_under_interview(
                quest_state,
                row.stars,
                Some(live.opened_at.as_str()),
            ),
            "opened_at": live.opened_at,
            "deadline_at": live.deadline_at,
            "approach": live.approach,
            "approach_at": live.approach_at,
            "finished_at": live.finished_at,
        }
    }))
}

/// §4.10. Taking a hint is permanent and costs stars; taking the same one
/// twice costs nothing more.
pub fn quest_hint(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let quest_id = str_field(payload, "quest_id")?;
    let index = i64_field(payload, "index")?;
    if index < 0 {
        return Err(bad_request("hint index must be 0 or more"));
    }
    let conn = state.store.conn();
    let (quest, _, _) = readable_quest(&conn, address, &quest_id)?;
    if under_interview(&conn, address, &quest_id)? {
        // Absent, not refused-for-now: there is no hint to be had on a live
        // screen (PROTOCOL §4.9e).
        return Err(not_found("there are no hints in an interview"));
    }
    // §4.10's `locale?`: the same index into the translated array, whose
    // length the importer guarantees equals the English one.
    let quest = quest.localized(&conn, opt_str_field(payload, "locale").as_deref())?;
    let hint = quest
        .hints
        .get(index as usize)
        .cloned()
        .ok_or_else(|| not_found("no hint at that index"))?;
    let hints_used = progress::use_hint(&conn, address, &quest_id, index)?;
    Ok(json!({
        "hint": hint,
        "index": index,
        "total": quest.hints.len(),
        "hints_used": hints_used,
    }))
}

/// §4.11: an editor convenience, not an undo. Progress, attempts, stars and
/// hints are all left exactly as they were.
pub fn quest_reset(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let quest_id = str_field(payload, "quest_id")?;
    let conn = state.store.conn();
    // §4.8b: resetting the editor is not a new attempt at the interview, so
    // the clock is deliberately untouched here.
    let (quest, _, _) = readable_quest(&conn, address, &quest_id)?;
    Ok(json!({ "starter": quest.starter }))
}

/// PROTOCOL §4.11c, all five of them. The stack is `edits.rs`; what is here is
/// the wire: the address comes from the session and never from the payload
/// (SPEC §3.5), and **every reply is the whole `EditState`**, so a client that
/// missed a frame, reloaded, or opened a second window is never left holding a
/// stack of its own that has drifted from the server's.
///
/// The five share this one body because the only thing that differs between
/// them is which function moves the cursor. Writing them out separately would
/// be five copies of the session lookup and the serialization, and the fifth
/// copy is where the bug would live.
fn edit_op(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
    op: impl FnOnce(&Connection, &cwbhacker_core::Home, &str, &str) -> Result<edits::EditState>,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let quest_id = str_field(payload, "quest_id")?;
    // One guard, taken once: `Store::conn` is not reentrant (`store.rs`).
    let conn = state.store.conn();
    let edit_state = op(&conn, state.store.home(), address, &quest_id)?;
    Ok(serde_json::to_value(edit_state)?)
}

/// `edit.state` — what the quest screen asks for when it opens.
pub fn edit_state(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    edit_op(state, session, payload, edits::state)
}

/// `edit.push` — one step onto the stack. `source` over 256 KiB is
/// `bad_request`, the same cap `quest.submit` uses, and a push of the text
/// that is already current is a no-op rather than a refusal: the client sends
/// this on an idle timer and being told off for not having typed anything
/// would be noise.
pub fn edit_push(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let source = str_field(payload, "source")?;
    edit_op(
        state,
        session,
        payload,
        move |conn, home, address, quest| edits::push(conn, home, address, quest, &source),
    )
}

pub fn edit_undo(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    edit_op(state, session, payload, edits::undo)
}

pub fn edit_redo(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    edit_op(state, session, payload, edits::redo)
}

/// `edit.clear` — the button the brief asks for. It empties the history and
/// touches nothing else: no attempt, no progress, and no edit. The client
/// keeps whatever text it is showing.
pub fn edit_clear(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    edit_op(state, session, payload, edits::clear)
}

pub fn stats_summary(state: &Shared, session: &Session) -> Result<serde_json::Value> {
    let address = session.address()?;
    let conn = state.store.conn();
    Ok(serde_json::to_value(stats::summary(&conn, address)?)?)
}

pub fn stats_mistakes(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let limit = opt_i64_field(payload, "limit").unwrap_or(10).clamp(1, 50);
    let include_learned = bool_field(payload, "include_learned");
    let conn = state.store.conn();
    Ok(json!({
        "mistakes": mistakes::stats(&conn, address, limit, include_learned)?
    }))
}

pub fn search_query(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let q = opt_str_field(payload, "q").unwrap_or_default();
    let mode = search::Mode::parse(
        payload
            .get("mode")
            .and_then(|m| m.as_str())
            .unwrap_or("unified"),
    )?;
    let limit = opt_i64_field(payload, "limit").unwrap_or(20).clamp(1, 100) as usize;
    let filters = payload.get("filters");
    let pick = |name: &str| {
        filters
            .and_then(|f| f.get(name))
            .and_then(|v| v.as_str())
            .map(str::to_string)
    };
    let filters = search::Filters {
        land: pick("land"),
        category: pick("category"),
        state: pick("state"),
    };
    let started = std::time::Instant::now();
    let conn = state.store.conn();
    let hits = search::query(
        &conn,
        state.embedder.as_ref(),
        address,
        &q,
        mode,
        &filters,
        limit,
    )?;
    Ok(json!({
        "hits": hits,
        "mode": mode.as_str(),
        "took_ms": started.elapsed().as_millis() as i64,
    }))
}

fn drill_json(drill: &drills::Drill) -> serde_json::Value {
    json!({
        "id": drill.id,
        "mode": drill.mode,
        "plan": drill.plan,
        "cursor": drill.cursor,
        "reason": drill.reason,
        "created_at": drill.created_at,
    })
}

pub fn ai_plan(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let mode = drills::Mode::parse(&str_field(payload, "mode")?)?;
    let land = opt_str_field(payload, "land");
    let size = opt_i64_field(payload, "size").unwrap_or(drills::DEFAULT_SIZE as i64);
    let conn = state.store.conn();
    let drill = drills::create(&conn, address, mode, land.as_deref(), size.max(1) as usize)?;
    Ok(json!({ "drill": drill_json(&drill) }))
}

pub fn ai_next(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let drill_id = str_field(payload, "drill_id")?;
    let conn = state.store.conn();
    let step = drills::next(&conn, address, &drill_id)?;
    // A drill step opens the quest screen the same way `quest.get` does, so
    // it takes the same `locale?` (PROTOCOL §4.16).
    let quest = quests::get(&conn, &step.quest_id)?
        .localized(&conn, opt_str_field(payload, "locale").as_deref())?;
    let quest_state = world::state_of(&conn, address, &step.quest_id)?;
    let row = progress::get(&conn, address, &step.quest_id)?;
    let opened_at = if quest.time_limit_s.is_some() {
        progress::open_clock(&conn, address, &step.quest_id)?
    } else {
        None
    };
    let draft = attempts::latest_source(&conn, address, &step.quest_id)?;
    Ok(json!({
        "quest": quest.to_wire(
            quest_state,
            row.stars,
            row.hints_used,
            opened_at.as_deref(),
            draft.as_deref(),
        ),
        "position": step.position,
        "total": step.total,
        "why": step.why,
    }))
}

pub fn ai_finish(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let drill_id = str_field(payload, "drill_id")?;
    let conn = state.store.conn();
    Ok(json!({ "summary": drills::finish(&conn, address, &drill_id)? }))
}

/// `code.format` (PROTOCOL §4.9d). Never recorded: formatting is not an
/// attempt at the problem. Blocking — it runs a subprocess — so the caller
/// puts it on a blocking thread.
pub fn code_format(payload: &serde_json::Value) -> Result<serde_json::Value> {
    let lang = str_field(payload, "lang")?;
    let source = str_field(payload, "source")?;
    if source.len() > crate::submit::MAX_SOURCE_BYTES {
        return Err(bad_request(format!(
            "source is {} bytes; the limit is {}",
            source.len(),
            crate::submit::MAX_SOURCE_BYTES
        )));
    }
    if !cwbhacker_runner::format::is_supported(&lang) {
        return Err(bad_request(format!("there is no formatter for '{lang}'")));
    }
    let formatted = cwbhacker_runner::format::format(&lang, &source)
        .map_err(|e| cwbhacker_core::error::internal(format!("the formatter: {e}")))?;
    let mut out = json!({
        "source": formatted.source,
        "changed": formatted.changed,
    });
    if let Some(problem) = formatted.problem {
        out["problem"] = json!(problem);
    }
    Ok(out)
}

/// Everything this player has earned (badges, levels, streaks), newest first.
/// The live `award` event is easy to miss — a client wants to be able to draw
/// the shelf as well as the fanfare.
pub fn stats_awards(state: &Shared, session: &Session) -> Result<serde_json::Value> {
    let address = session.address()?;
    let conn = state.store.conn();
    Ok(json!({ "awards": awards::list(&conn, address)? }))
}

pub fn stats_history(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let quest_id = opt_str_field(payload, "quest_id");
    let limit = opt_i64_field(payload, "limit").unwrap_or(20).clamp(1, 200);
    let conn = state.store.conn();
    Ok(json!({
        "attempts": attempts::history(&conn, address, quest_id.as_deref(), limit)?
    }))
}

/// A convenience for the CLI and for tests: the EIP-55 spelling of whatever
/// the session holds.
pub fn display_address(address: &str) -> String {
    eth::to_eip55(address)
}

/// Milestone 2 lives behind this. `unavailable` rather than `not_found`,
/// because the thing exists and is specified — it is the build that is
/// early — and a client renders the two differently: "no such quest" against
/// "the GO land opens in the next chapter".
pub fn unimplemented(what: &str) -> Error {
    cwbhacker_core::error::unavailable(format!("{what} is not in this build yet"), 2)
}
