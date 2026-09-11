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
    attempts, auth, awards, eth, mistakes, progress, quests, stats, users, world,
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
    let conn = state.store.conn();
    let map = world::map(&conn, address, &land, &category)?;
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
    // PROTOCOL §4.8b: opening a timed quest starts its clock, once. Untimed
    // quests never get one — there is nothing for it to count down to.
    let opened_at = if quest.time_limit_s.is_some() {
        progress::open_clock(&conn, address, &quest_id)?
    } else {
        None
    };
    Ok(json!({
        "quest": quest.to_wire(quest_state, row.stars, row.hints_used, opened_at.as_deref())
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
