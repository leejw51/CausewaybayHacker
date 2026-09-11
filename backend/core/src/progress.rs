//! Progress, stars and the lock graph (SPEC §6.3, §12).
//!
//! `locked` / `open` are **derived** at read time from `quest_deps` and the
//! set of cleared quests; only the cleared fact and the counters are stored.
//! A persisted `locked` row goes stale the moment the content changes its
//! dependencies, and then a player is staring at a node the map says they
//! already unlocked.

use std::collections::HashSet;

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::error::Result;
use crate::time::now_stamp;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Locked,
    Open,
    Cleared,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Locked => "locked",
            State::Open => "open",
            State::Cleared => "cleared",
        }
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Row {
    pub stars: i64,
    pub best_ms: Option<i64>,
    pub attempts: i64,
    pub hints_used: i64,
    pub first_clear_at: Option<String>,
    pub cleared: bool,
}

pub fn get(conn: &Connection, address: &str, quest_id: &str) -> Result<Row> {
    let row = conn
        .query_row(
            "SELECT state, stars, best_ms, attempts, hints_used, first_clear_at
               FROM progress WHERE address = ?1 AND quest_id = ?2",
            params![address, quest_id],
            |r| {
                let state: String = r.get(0)?;
                Ok(Row {
                    cleared: state == "cleared",
                    stars: r.get(1)?,
                    best_ms: r.get(2)?,
                    attempts: r.get(3)?,
                    hints_used: r.get(4)?,
                    first_clear_at: r.get(5)?,
                })
            },
        )
        .optional()?;
    Ok(row.unwrap_or_default())
}

pub fn cleared_set(conn: &Connection, address: &str) -> Result<HashSet<String>> {
    let mut stmt =
        conn.prepare("SELECT quest_id FROM progress WHERE address = ?1 AND state = 'cleared'")?;
    let rows = stmt.query_map(params![address], |r| r.get::<_, String>(0))?;
    Ok(rows.collect::<rusqlite::Result<HashSet<_>>>()?)
}

/// Derive the state of one quest. `requires` empty means open from the start
/// (SPEC §12); otherwise every requirement must be cleared.
pub fn derive_state(quest_id: &str, requires: &[String], cleared: &HashSet<String>) -> State {
    if cleared.contains(quest_id) {
        return State::Cleared;
    }
    if requires.iter().all(|r| cleared.contains(r)) {
        State::Open
    } else {
        State::Locked
    }
}

fn ensure_row(conn: &Connection, address: &str, quest_id: &str) -> Result<()> {
    conn.execute(
        "INSERT OR IGNORE INTO progress
           (address, quest_id, state, stars, attempts, hints_used, updated_at)
         VALUES (?1, ?2, 'open', 0, 0, 0, ?3)",
        params![address, quest_id, now_stamp()],
    )?;
    Ok(())
}

pub fn bump_attempt(conn: &Connection, address: &str, quest_id: &str) -> Result<()> {
    ensure_row(conn, address, quest_id)?;
    conn.execute(
        "UPDATE progress SET attempts = attempts + 1, updated_at = ?3
          WHERE address = ?1 AND quest_id = ?2",
        params![address, quest_id, now_stamp()],
    )?;
    Ok(())
}

/// `quest.hint` (SPEC §6.2). Returns the running total, which is also what
/// costs the third star.
pub fn use_hint(conn: &Connection, address: &str, quest_id: &str, index: i64) -> Result<i64> {
    ensure_row(conn, address, quest_id)?;
    // A hint already paid for is not charged twice: hints_used is the high
    // water mark of how far into the list the player went.
    conn.execute(
        "UPDATE progress SET hints_used = MAX(hints_used, ?3), updated_at = ?4
          WHERE address = ?1 AND quest_id = ?2",
        params![address, quest_id, index + 1, now_stamp()],
    )?;
    Ok(get(conn, address, quest_id)?.hints_used)
}

/// SPEC §6.3: 3 — cleared with no failed attempt and no hint; 2 — cleared with
/// hints or ≤2 failed attempts; 1 — cleared.
///
/// Read as an ordered cascade, because the two upper rungs overlap as written:
/// a clear with one failure and no hint satisfies neither "no failure" nor
/// "hints", and 2 is plainly the intent.
pub fn stars_for(failures_before_clear: i64, hints_used: i64) -> i64 {
    if failures_before_clear == 0 && hints_used == 0 {
        3
    } else if hints_used > 0 || failures_before_clear <= 2 {
        2
    } else {
        1
    }
}

/// Record a clear. Stars never regress on a re-clear and `first_clear_at` is
/// written once — the fact of having cleared it is what the map stamps, and a
/// sloppy retry should not take a star back.
pub fn record_clear(
    conn: &Connection,
    address: &str,
    quest_id: &str,
    elapsed_ms: i64,
) -> Result<Row> {
    ensure_row(conn, address, quest_id)?;
    let before = get(conn, address, quest_id)?;
    let failures: i64 = conn.query_row(
        "SELECT count(*) FROM attempts
          WHERE address = ?1 AND quest_id = ?2 AND verdict <> 'accepted'",
        params![address, quest_id],
        |r| r.get(0),
    )?;
    let stars = stars_for(failures, before.hints_used).max(before.stars);
    let best = match before.best_ms {
        Some(b) if b <= elapsed_ms => b,
        _ => elapsed_ms,
    };
    let now = now_stamp();
    conn.execute(
        "UPDATE progress
            SET state = 'cleared', stars = ?3, best_ms = ?4,
                first_clear_at = COALESCE(first_clear_at, ?5), updated_at = ?5
          WHERE address = ?1 AND quest_id = ?2",
        params![address, quest_id, stars, best, now],
    )?;
    get(conn, address, quest_id)
}

/// How many quests this player has cleared, for the `cleared_total` on
/// `progress.update`.
pub fn cleared_total(conn: &Connection, address: &str) -> Result<i64> {
    Ok(conn.query_row(
        "SELECT count(*) FROM progress WHERE address = ?1 AND state = 'cleared'",
        params![address],
        |r| r.get(0),
    )?)
}
