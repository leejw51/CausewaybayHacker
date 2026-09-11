//! The SPEC §6.2 message catalogue, minus `quest.submit` (which lives in
//! `submit.rs` because it streams).
//!
//! **Every handler that touches user data uses `session.address`.** An address
//! in a payload is ignored, not trusted (SPEC §3.5). The only two handlers
//! that read an address from a payload at all are `auth.challenge` and
//! `auth.login`, and both of them prove it with a signature.

use cwbhacker_core::error::{bad_request, locked, not_found, unauthorized, Code, Error, Result};
use cwbhacker_core::{attempts, auth, mistakes, progress, quests, stats, users, world};
use serde_json::json;

use crate::proto::{i64_field, opt_i64_field, opt_str_field, str_field};
use crate::state::Shared;

/// The address this connection proved it owns. `None` until `auth.login` or
/// `auth.resume` succeeds (SPEC §6.4).
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
}

pub fn user_json(user: &users::User) -> serde_json::Value {
    json!({
        "address": user.address,
        "address_eip55": user.address_eip55,
        "name": user.name,
        "created_at": user.created_at,
        "last_seen_at": user.last_seen_at,
        "settings": user.settings,
    })
}

pub fn ping() -> serde_json::Value {
    json!({
        "t": cwbhacker_core::time::now().timestamp_millis(),
        "at": cwbhacker_core::time::now_stamp(),
    })
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

/// §3.2 step 4, in order: burn the nonce first, then check the signature. A
/// bad signature must not leave the nonce available for another try.
pub fn auth_login(
    state: &Shared,
    session: &mut Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = str_field(payload, "address")?;
    let signature = str_field(payload, "signature")?;
    let nonce = opt_str_field(payload, "nonce");
    let message = state.challenges.redeem_for(&address, nonce.as_deref())?;
    let address = auth::verify_login(&address, &message, &signature)?;

    let conn = state.store.conn();
    let user = users::upsert(&conn, &address)?;
    users::write_profile(state.store.home(), &user)?;
    let token = auth::mint_session(&conn, &address)?;
    drop(conn);

    session.address = Some(address);
    Ok(json!({ "token": token, "user": user_json(&user) }))
}

pub fn auth_resume(
    state: &Shared,
    session: &mut Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let token = str_field(payload, "token")?;
    let conn = state.store.conn();
    let address = auth::resume_session(&conn, &token)?;
    let user = users::upsert(&conn, &address)?;
    drop(conn);
    session.address = Some(address);
    Ok(json!({ "token": token, "user": user_json(&user) }))
}

pub fn profile_update(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let name = opt_str_field(payload, "name");
    let settings = payload.get("settings").filter(|v| v.is_object());
    let conn = state.store.conn();
    let user = users::update_profile(&conn, address, name.as_deref(), settings)?;
    drop(conn);
    users::write_profile(state.store.home(), &user)?;
    Ok(json!({ "user": user_json(&user) }))
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
    let conn = state.store.conn();
    let map = world::map(&conn, address, &land, &category)?;
    Ok(json!({ "nodes": map.nodes, "edges": map.edges }))
}

pub fn quest_get(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let quest_id = str_field(payload, "quest_id")?;
    let conn = state.store.conn();
    let quest = quests::get(&conn, &quest_id)?;
    let state_of = world::state_of(&conn, address, &quest_id)?;
    if state_of == progress::State::Locked {
        return Err(locked("that node is still locked"));
    }
    let row = progress::get(&conn, address, &quest_id)?;
    Ok(json!({
        "quest": quest.to_wire(row.cleared),
        "progress": {
            "state": state_of,
            "stars": row.stars,
            "attempts": row.attempts,
            "hints_used": row.hints_used,
            "best_ms": row.best_ms,
            "first_clear_at": row.first_clear_at,
        }
    }))
}

/// One hint at a time, and the count is what costs the third star (§6.3).
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
    let quest = quests::get(&conn, &quest_id)?;
    if world::state_of(&conn, address, &quest_id)? == progress::State::Locked {
        return Err(locked("that node is still locked"));
    }
    let hint = quest
        .hints
        .get(index as usize)
        .cloned()
        .ok_or_else(|| not_found("no hint at that index"))?;
    let hints_used = progress::use_hint(&conn, address, &quest_id, index)?;
    Ok(json!({ "hint": hint, "hints_used": hints_used, "hint_count": quest.hints.len() }))
}

pub fn quest_reset(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let quest_id = str_field(payload, "quest_id")?;
    let conn = state.store.conn();
    let quest = quests::get(&conn, &quest_id)?;
    if world::state_of(&conn, address, &quest_id)? == progress::State::Locked {
        return Err(locked("that node is still locked"));
    }
    // A reset hands back the starter code. It does not undo a clear: the map
    // stamp is permanent (§0), and a player asking for the blank page again
    // is not asking to lose it.
    Ok(json!({ "starter": quest.starter }))
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
    let limit = opt_i64_field(payload, "limit").unwrap_or(20).clamp(1, 200);
    let conn = state.store.conn();
    Ok(json!({ "mistakes": mistakes::stats(&conn, address, limit)? }))
}

pub fn stats_history(
    state: &Shared,
    session: &Session,
    payload: &serde_json::Value,
) -> Result<serde_json::Value> {
    let address = session.address()?;
    let quest_id = opt_str_field(payload, "quest_id");
    let limit = opt_i64_field(payload, "limit").unwrap_or(50);
    let conn = state.store.conn();
    Ok(json!({
        "attempts": attempts::history(&conn, address, quest_id.as_deref(), limit)?
    }))
}

/// Milestone 2 lives behind this. A clean refusal from §6.1's closed set, not
/// a panic and not a silent empty list that looks like "no results".
pub fn unimplemented(what: &str) -> Error {
    Error::new(Code::NotFound, format!("{what} is not in this build yet"))
        .with_detail(json!({ "milestone": 2 }))
}
