//! Where a player is, kept by the server (SPEC §1.3).
//!
//! Not a client preference. The web client and the LÖVE client talk to one
//! server, and a player who solves a quest in the browser and then opens the
//! desktop client is the same person in the same place — so the answer has to
//! live where both of them can be told it, which is here. Before this, each
//! client kept its own: the web one reconstructed the lobby with `land =
//! "rust"` every time, so walking out of a quest lost the land, and logging
//! out lost it everywhere.
//!
//! **Nothing new is asked of the client.** The server already receives every
//! move as a request — `world.map` names the land and category the player just
//! chose, `quest.get` names the stage they just opened — so the bookmark is
//! written from the traffic that was already there rather than from a "save my
//! place" message a client could forget to send. That also means the two
//! clients cannot drift: neither of them is the one keeping score.
//!
//! One row per player, overwritten in place. This is a bookmark, not a
//! history; the history is `attempts`, and it is kept forever.

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::error::Result;
use crate::time::now_stamp;

/// Where to put the player back. `category` and `quest_id` are absent when
/// they were in a lobby rather than on a stage, which is a real place to be:
/// "I picked rust and was reading the category list" should restore to that
/// list, not to a quest they never opened.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Position {
    pub land: String,
    pub category: Option<String>,
    pub quest_id: Option<String>,
    pub updated_at: String,
}

/// The player chose a land, and possibly a category within it (`world.lands`,
/// `world.map`). Clears `quest_id`: they have walked back out to a lobby, and
/// restoring them into the quest they left would ignore the walk.
pub fn mark_lobby(
    conn: &Connection,
    address: &str,
    land: &str,
    category: Option<&str>,
) -> Result<()> {
    conn.execute(
        "INSERT INTO user_position (address, land, category, quest_id, updated_at)
              VALUES (?1, ?2, ?3, NULL, ?4)
         ON CONFLICT (address) DO UPDATE SET
              land = ?2, category = ?3, quest_id = NULL, updated_at = ?4",
        params![address, land, category, now_stamp()],
    )?;
    Ok(())
}

/// The player opened a stage (`quest.get`). The land and category come from
/// the quest itself rather than from the client, so a client that jumps
/// straight to a quest id — AUTO SELECT does exactly that — still leaves a
/// bookmark that names the whole place.
pub fn mark_quest(conn: &Connection, address: &str, quest_id: &str) -> Result<()> {
    conn.execute(
        "INSERT INTO user_position (address, land, category, quest_id, updated_at)
              SELECT ?1, q.land, q.category, q.id, ?3 FROM quests q WHERE q.id = ?2
         ON CONFLICT (address) DO UPDATE SET
              land = excluded.land, category = excluded.category,
              quest_id = excluded.quest_id, updated_at = excluded.updated_at",
        params![address, quest_id, now_stamp()],
    )?;
    Ok(())
}

/// Where they were, if anywhere.
///
/// A bookmark onto a quest that no longer exists — a pack reimported without
/// it — degrades to the lobby of that land rather than vanishing. The land and
/// category outlive any particular pack, and sending a client to a quest id it
/// cannot open is worse than sending it one screen out.
pub fn get(conn: &Connection, address: &str) -> Result<Option<Position>> {
    let row = conn
        .query_row(
            "SELECT p.land, p.category, p.quest_id, p.updated_at,
                    (p.quest_id IS NOT NULL AND EXISTS
                       (SELECT 1 FROM quests q WHERE q.id = p.quest_id))
               FROM user_position p WHERE p.address = ?1",
            params![address],
            |r| {
                let quest_still_there: bool = r.get::<_, i64>(4)? != 0;
                Ok(Position {
                    land: r.get(0)?,
                    category: r.get(1)?,
                    quest_id: if quest_still_there { r.get(2)? } else { None },
                    updated_at: r.get(3)?,
                })
            },
        )
        .optional()?;
    Ok(row)
}

/// Forget where they were. Nothing calls this today; `quest.reset` and the
/// account tools are where it would belong, and it is here so that a caller
/// does not reach for a DELETE of its own.
pub fn clear(conn: &Connection, address: &str) -> Result<()> {
    conn.execute(
        "DELETE FROM user_position WHERE address = ?1",
        params![address],
    )?;
    Ok(())
}
