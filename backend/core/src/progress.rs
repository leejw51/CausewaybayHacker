//! Progress and stars (SPEC §6.3, PROTOCOL §4.7).
//!
//! State is **derived** at read time and is `cleared` or `open` — never
//! `locked`. Nothing in the map is gated: `requires` describes the suggested
//! route, and a player may enter any node at any time. A trainer is not a
//! platformer, and somebody with an interview on Thursday needs the
//! dynamic-programming street on Tuesday.
//!
//! `State::Locked` and the `progress.state` CHECK keep the value so rows
//! written before this read back, and so §3.3's closed error set keeps its
//! `locked` code. Nothing writes it and nothing derives it.

use std::collections::HashSet;

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::error::Result;
use crate::time::now_stamp;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    /// Legacy. Never derived and never written since PROTOCOL §4.7; kept so
    /// rows and clients from before it still make sense.
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
    /// When this player first opened the quest, on a timed one (PROTOCOL
    /// §4.8b). `None` on an untimed quest, and on one cleared before the clock
    /// existed — which is not invented after the fact.
    pub opened_at: Option<String>,
    /// When this quest was last RESET, if it was (0019). Stars are counted
    /// from the failures after it.
    pub reset_at: Option<String>,
    pub cleared: bool,
    /// XP this call granted: the clear's worth on a first clear, a fifth of
    /// it on a re-clear (`practice`, capped), zero otherwise (PROTOCOL §4.9).
    /// Never read back from the database — it is what *happened*, not a
    /// column.
    pub xp_gained: i64,
    /// How many times this quest has been re-cleared since its first clear:
    /// accepted submits after `first_clear_at`. The map colours the stamp by
    /// it (PROTOCOL §5.2 `practised`).
    pub practised: i64,
}

/// The most `practice` grants one quest pays. Ten re-clears is a habit;
/// past that the XP stops and the stamp keeps counting.
pub const PRACTICE_CAP: i64 = 10;

/// Accepted submits beyond the one that cleared it: the practice count.
/// Counted, not dated — the clearing submit and a re-clear a second later
/// share a timestamp at this resolution, and "all accepted submits but one"
/// is the same number without the race.
pub fn practised(conn: &Connection, address: &str, quest_id: &str) -> Result<i64> {
    let accepted: i64 = conn.query_row(
        "SELECT count(*) FROM attempts
          WHERE address = ?1 AND quest_id = ?2 AND mode = 'submit' AND verdict = 'accepted'",
        params![address, quest_id],
        |r| r.get(0),
    )?;
    Ok((accepted - 1).max(0))
}

pub fn get(conn: &Connection, address: &str, quest_id: &str) -> Result<Row> {
    let row = conn
        .query_row(
            "SELECT state, stars, best_ms, attempts, hints_used, first_clear_at, opened_at,
                    reset_at
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
                    opened_at: r.get(6)?,
                    reset_at: r.get(7)?,
                    xp_gained: 0,
                    practised: 0,
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

/// Derive the state of one quest: cleared, or open. There is no third answer.
///
/// This used to consult `quest_deps` and answer `locked` when a requirement
/// was unfinished. It no longer does (PROTOCOL §4.7) — the dependencies are
/// still carried on the wire as the suggested route, and the client still
/// draws the line between nodes, but they gate nothing.
pub fn derive_state(quest_id: &str, cleared: &HashSet<String>) -> State {
    if cleared.contains(quest_id) {
        State::Cleared
    } else {
        State::Open
    }
}

/// Start the clock, once (PROTOCOL §4.8b).
///
/// The first `quest.get` on a timed quest stamps it; every later one returns
/// the same stamp, so a reload, a reconnect or a second window shows one clock
/// rather than a fresh one. `COALESCE` is what makes that true even if two
/// windows ask at the same moment.
///
/// A quest already cleared does not start one: its clock is done, and
/// replaying it for practice is untimed.
pub fn open_clock(conn: &Connection, address: &str, quest_id: &str) -> Result<Option<String>> {
    let row = get(conn, address, quest_id)?;
    if row.cleared {
        return Ok(row.opened_at);
    }
    ensure_row(conn, address, quest_id)?;
    let now = now_stamp();
    conn.execute(
        "UPDATE progress SET opened_at = COALESCE(opened_at, ?3), updated_at = ?4
          WHERE address = ?1 AND quest_id = ?2",
        params![address, quest_id, now, now],
    )?;
    Ok(get(conn, address, quest_id)?.opened_at)
}

/// `opened_at + time_limit_s`, when there is one of each.
pub fn deadline(opened_at: Option<&str>, time_limit_s: Option<i64>) -> Option<String> {
    let opened = crate::time::parse(opened_at?)?;
    Some(crate::time::stamp(
        opened + chrono::Duration::seconds(time_limit_s?.max(0)),
    ))
}

/// Whether a submit arriving now is inside the clock. `None` on an untimed
/// quest, and on one whose clock never started.
///
/// The clock blocks nothing: a late submit is judged exactly like an early
/// one and simply is not `within_limit`.
pub fn within_limit(opened_at: Option<&str>, time_limit_s: Option<i64>) -> Option<bool> {
    let deadline = deadline(opened_at, time_limit_s)?;
    let deadline = crate::time::parse(&deadline)?;
    Some(crate::time::now() <= deadline)
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

/// PROTOCOL §4.11b (`quest.solve`): reveal the whole answer, which is at
/// least as much help as any hint, so it costs at least as much. Reuses the
/// same high-water-mark column hints do, rather than inventing a fourth star
/// tier or a second "did they cheat" column — `stars_for` only ever checks
/// `hints_used > 0`, so the exact number just has to be honest and nonzero.
/// `hints_total.max(1)` covers a quest authored with zero hints: solving it
/// still has to cost something.
pub fn use_solve(
    conn: &Connection,
    address: &str,
    quest_id: &str,
    hints_total: i64,
) -> Result<i64> {
    ensure_row(conn, address, quest_id)?;
    conn.execute(
        "UPDATE progress SET hints_used = MAX(hints_used, ?3), updated_at = ?4
          WHERE address = ?1 AND quest_id = ?2",
        params![address, quest_id, hints_total.max(1), now_stamp()],
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
    // Only the failures that came before the first clear count. A player who
    // clears a node, comes back to play with it and fails four times has not
    // retroactively made their original clear a worse one.
    // Submits only (PROTOCOL §4.9b): a star is about the record, and pressing
    // RUN while you work the problem out is not a failed attempt.
    // …and only the failures since the last RESET (0019): a road walked
    // again from the start is judged on this walk, not on the one before it.
    let failures: i64 = conn.query_row(
        "SELECT count(*) FROM attempts
          WHERE address = ?1 AND quest_id = ?2 AND mode = 'submit'
            AND verdict <> 'accepted'
            AND (?3 IS NULL OR created_at < ?3)
            AND (?4 IS NULL OR created_at > ?4)",
        params![address, quest_id, before.first_clear_at, before.reset_at],
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
    // The grant, on the first clear only: stars are fixed at that moment
    // (the failures counted are the ones before `first_clear_at`), so there
    // is nothing for a later clear to add. Written here, beside the clear it
    // records, so the ledger cannot say something the progress table does
    // not. The UNIQUE index refuses a second row for the same clear, and
    // `INSERT OR IGNORE` makes a replayed clear a no-op rather than an error.
    let mut xp_gained = 0;
    let (difficulty, category): (i64, String) = conn.query_row(
        "SELECT difficulty, category FROM quests WHERE id = ?1",
        params![quest_id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let worth = crate::awards::xp_for_clear(stars, difficulty, &category);
    if !before.cleared {
        let written = conn.execute(
            "INSERT OR IGNORE INTO xp_ledger
                (address, quest_id, reason, amount, stars, created_at)
             VALUES (?1, ?2, 'clear', ?3, ?4, ?5)",
            params![address, quest_id, worth, stars, now],
        )?;
        if written == 1 {
            xp_gained = worth;
        }
    } else {
        // Practice: a re-clear is worth a fifth of the clear, never less than
        // five, and at most PRACTICE_CAP times — repetition is the point of
        // the grammar roads, farming is not.
        let granted: i64 = conn.query_row(
            "SELECT count(*) FROM xp_ledger
              WHERE address = ?1 AND quest_id = ?2 AND reason = 'practice'",
            params![address, quest_id],
            |r| r.get(0),
        )?;
        if granted < PRACTICE_CAP {
            let amount = (worth / 5).max(5);
            conn.execute(
                "INSERT INTO xp_ledger
                    (address, quest_id, reason, amount, stars, created_at)
                 VALUES (?1, ?2, 'practice', ?3, ?4, ?5)",
                params![address, quest_id, amount, stars, now],
            )?;
            xp_gained = amount;
        }
    }
    let mut row = get(conn, address, quest_id)?;
    row.xp_gained = xp_gained;
    row.practised = practised(conn, address, quest_id)?;
    Ok(row)
}

/// Walk one road again from the start (PROTOCOL §4.7b).
///
/// Every quest of `land`/`category` goes back to untouched for this player:
/// no stamp, no stars, no counts, no clock. What is deliberately kept is
/// everything that is a *record* rather than a *state* — the attempts and
/// the mistakes, which are SPEC §7's training data and which the server
/// never deletes, and the XP ledger, which is history. A re-clear after a
/// reset therefore pays nothing: the `clear` row is already in the ledger
/// and its unique index refuses the second one. Practice is free; farming is
/// not possible.
///
/// Returns how many quests were reset — zero when the player had never
/// touched this road, which is not an error, just nothing to do. Touched
/// includes "pressed RUN on and never submitted": that quest has a draft to
/// take back even though it has no stamp to clear.
pub fn reset_road(conn: &Connection, address: &str, land: &str, category: &str) -> Result<i64> {
    let now = now_stamp();
    // A quest the player has only ever pressed RUN on has no progress row —
    // `bump_attempt` is a submit-only call, on purpose, because iterating with
    // RUN must not read as failing repeatedly. It does have attempts, though,
    // and therefore a draft, and a reset that could not date it would leave
    // that quest opening on the code from before the reset. So every quest on
    // this road the player has attempted gets a row first, and the UPDATE
    // below dates all of them together. A row created here is 'open' with
    // nothing in it, which is what the UPDATE would have made of it anyway.
    conn.execute(
        "INSERT OR IGNORE INTO progress
           (address, quest_id, state, stars, attempts, hints_used, updated_at)
         SELECT ?1, q.id, 'open', 0, 0, 0, ?4
           FROM quests q
          WHERE q.land = ?2 AND q.category = ?3
            AND EXISTS (SELECT 1 FROM attempts a
                         WHERE a.address = ?1 AND a.quest_id = q.id)",
        params![address, land, category, now],
    )?;
    let changed = conn.execute(
        "UPDATE progress
            SET state = 'open', stars = 0, best_ms = NULL, attempts = 0,
                hints_used = 0, first_clear_at = NULL, opened_at = NULL,
                reset_at = ?4, updated_at = ?4
          WHERE address = ?1
            AND quest_id IN (SELECT id FROM quests WHERE land = ?2 AND category = ?3)",
        params![address, land, category, now],
    )?;
    Ok(changed as i64)
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

/// Every star this player holds. `User.xp` used to be derived from this; it
/// is read from the ledger now (`awards::total_xp`), and this stays for the
/// stats screen.
pub fn stars_total(conn: &Connection, address: &str) -> Result<i64> {
    Ok(conn.query_row(
        "SELECT COALESCE(sum(stars), 0) FROM progress WHERE address = ?1",
        params![address],
        |r| r.get(0),
    )?)
}
