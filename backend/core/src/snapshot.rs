//! `users/<address>/progress.json` — the player's own record, on disk (SPEC §1).
//!
//! The same bargain `users::write_profile` makes, for the rest of what the
//! database knows: **sqlite is the truth, and this is so a player can read
//! their own directory without it.** Nothing reads this file back. If it
//! disagrees with `hacker.db` the file is wrong, and the next write fixes it.
//!
//! It answers, for one address: where they are, what every quest cost them,
//! how deep the undo stack on each one goes — and which stages they are
//! worst at, which is the only part that is a judgement rather than a copy.
//!
//! The undo/redo sources are **not** copied in here. `paths::edits_dir` says
//! why they live outside `users/`: that tree is the trail behind the work, not
//! the work, and `cwbhacker prune` may throw all of it away without losing
//! anything that was ever submitted. What lands here is where each stack
//! stands — depth, cursor, whether undo and redo are available — which is the
//! part that survives a prune as a statement about the player.

use rusqlite::{params, Connection};
use serde::Serialize;

use crate::error::Result;
use crate::paths::{write_private, Home};
use crate::stats;
use crate::time::now_stamp;

/// What `progress.json` holds. Field order is the order a person reads it in:
/// where am I, how am I doing overall, what should I practise, then the full
/// table underneath.
#[derive(Debug, Clone, Serialize)]
pub struct Snapshot {
    pub address: String,
    pub written_at: String,
    /// The last quest touched, and the land it is in. `None` for an account
    /// that has never attempted anything — which is not the same as being at
    /// the start of rust, and is not reported as if it were.
    pub position: Option<Position>,
    pub totals: stats::Summary,
    /// Weakest first. See [`weakest`] for what "weak" is taken to mean.
    pub weakest: Vec<Weak>,
    /// Every quest this player has touched, in play order.
    pub quests: Vec<QuestRecord>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Position {
    pub land: String,
    pub category: String,
    pub node: i64,
    pub quest_id: String,
    pub title: String,
    pub cleared: bool,
    /// When they were last on it.
    pub at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct QuestRecord {
    pub quest_id: String,
    pub land: String,
    pub category: String,
    pub node: i64,
    pub title: String,
    pub state: String,
    pub stars: i64,
    /// Submits only. The RUN button is deliberately not counted here — a
    /// player iterating honestly with it must not read as failing (§4.9b).
    pub submits: i64,
    pub failures: i64,
    pub hints_used: i64,
    pub best_ms: Option<i64>,
    pub first_clear_at: Option<String>,
    pub opened_at: Option<String>,
    pub last_attempt_at: Option<String>,
    /// Where the undo stack stands. The sources stay in `edits/` (§2.3).
    pub edits: EditPosition,
}

#[derive(Debug, Clone, Serialize)]
pub struct EditPosition {
    pub depth: i64,
    pub cursor: i64,
    pub can_undo: bool,
    pub can_redo: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct Weak {
    pub quest_id: String,
    pub land: String,
    pub category: String,
    pub node: i64,
    pub title: String,
    pub failures: i64,
    pub submits: i64,
    /// failures / submits, 0.0 when there is nothing to divide.
    pub failure_rate: f64,
    pub hints_used: i64,
    pub cleared: bool,
    /// Which of the two rankings below put it here, so the file explains
    /// itself to somebody reading it without this source next to them.
    pub reason: &'static str,
}

/// The stages this player is worst at, worst first.
///
/// "Worst" is a choice, and the obvious one is wrong: ranking by raw failure
/// count returns the quests they *practised* most, which for a player working
/// steadily through a land is simply the ones they have reached. Two groups,
/// in this order:
///
/// 1. **`stuck`** — failed submits and still not cleared. Whatever else is
///    true, they are on it now and it is beating them.
/// 2. **`costly`** — cleared, but it took failures to get there. Real
///    weakness, already survived; worth revisiting, after anything live.
///
/// Within each group, more failures first, then a higher failure rate, so a
/// quest failed four times out of four outranks one failed four times out of
/// twenty. Quests never submitted are not weakness and are not here.
pub fn weakest(conn: &Connection, address: &str, limit: usize) -> Result<Vec<Weak>> {
    let mut stmt = conn.prepare(
        "SELECT q.id, q.land, q.category, q.node, q.title,
                count(a.id),
                sum(CASE WHEN a.verdict <> 'accepted' THEN 1 ELSE 0 END),
                coalesce(p.hints_used, 0),
                coalesce(p.state = 'cleared', 0)
           FROM attempts a
           JOIN quests q ON q.id = a.quest_id
           LEFT JOIN progress p ON p.address = a.address AND p.quest_id = a.quest_id
          WHERE a.address = ?1 AND a.mode = 'submit'
          GROUP BY q.id
         HAVING sum(CASE WHEN a.verdict <> 'accepted' THEN 1 ELSE 0 END) > 0",
    )?;
    let mut rows: Vec<Weak> = stmt
        .query_map(params![address], |r| {
            let submits: i64 = r.get(5)?;
            let failures: i64 = r.get(6)?;
            let cleared: bool = r.get::<_, i64>(8)? != 0;
            Ok(Weak {
                quest_id: r.get(0)?,
                land: r.get(1)?,
                category: r.get(2)?,
                node: r.get(3)?,
                title: r.get(4)?,
                failures,
                submits,
                failure_rate: if submits == 0 {
                    0.0
                } else {
                    failures as f64 / submits as f64
                },
                hints_used: r.get(7)?,
                cleared,
                reason: if cleared { "costly" } else { "stuck" },
            })
        })?
        .collect::<rusqlite::Result<_>>()?;

    rows.sort_by(|a, b| {
        // Uncleared first, then failures, then rate. `quest_id` last so the
        // order is total: two quests tied on every count must not swap between
        // writes, or the file churns for no reason.
        a.cleared
            .cmp(&b.cleared)
            .then(b.failures.cmp(&a.failures))
            .then(
                b.failure_rate
                    .partial_cmp(&a.failure_rate)
                    .unwrap_or(std::cmp::Ordering::Equal),
            )
            .then(a.quest_id.cmp(&b.quest_id))
    });
    rows.truncate(limit);
    Ok(rows)
}

/// How many entries `weakest` returns into `progress.json`.
pub const WEAKEST_IN_FILE: usize = 20;

/// Build the snapshot. Read-only; `write` is what puts it on disk.
pub fn build(conn: &Connection, address: &str) -> Result<Snapshot> {
    let mut stmt = conn.prepare(QUEST_SQL)?;
    let quests: Vec<QuestRecord> = stmt
        .query_map(params![address], |r| {
            let depth: i64 = r.get(14)?;
            // Clamped rather than trusted, exactly as `edits::load` does it:
            // a cursor row can outlive the entries it pointed at.
            let cursor: i64 = r.get::<_, i64>(15)?.clamp(0, depth);
            Ok(QuestRecord {
                quest_id: r.get(0)?,
                land: r.get(1)?,
                category: r.get(2)?,
                node: r.get(3)?,
                title: r.get(4)?,
                state: r.get(5)?,
                stars: r.get(6)?,
                submits: r.get(7)?,
                failures: r.get(8)?,
                hints_used: r.get(9)?,
                best_ms: r.get(10)?,
                first_clear_at: r.get(11)?,
                opened_at: r.get(12)?,
                last_attempt_at: r.get(13)?,
                edits: EditPosition {
                    depth,
                    cursor,
                    can_undo: cursor > 0,
                    can_redo: cursor < depth,
                },
            })
        })?
        .collect::<rusqlite::Result<_>>()?;

    // The most recent thing they touched, by attempt rather than by progress
    // row: `updated_at` moves when a hint is taken or a clock opens, and
    // "where was I" means the quest they were last actually working on.
    //
    // `rowid` breaks the tie because `created_at` is second-resolution and two
    // submits inside one second are common — a player alt-tabbing between two
    // quests would otherwise get whichever the query happened to reach first,
    // and "where was I" would flicker.
    let position = conn
        .query_row(
            "SELECT q.land, q.category, q.node, q.id, q.title,
                    coalesce(p.state = 'cleared', 0), a.created_at
               FROM attempts a
               JOIN quests q ON q.id = a.quest_id
               LEFT JOIN progress p ON p.address = a.address AND p.quest_id = a.quest_id
              WHERE a.address = ?1
              ORDER BY a.created_at DESC, a.rowid DESC LIMIT 1",
            params![address],
            |r| {
                Ok(Position {
                    land: r.get(0)?,
                    category: r.get(1)?,
                    node: r.get(2)?,
                    quest_id: r.get(3)?,
                    title: r.get(4)?,
                    cleared: r.get::<_, i64>(5)? != 0,
                    at: r.get(6)?,
                })
            },
        )
        .ok();

    Ok(Snapshot {
        address: address.to_ascii_lowercase(),
        written_at: now_stamp(),
        position,
        totals: stats::summary(conn, address)?,
        weakest: weakest(conn, address, WEAKEST_IN_FILE)?,
        quests,
    })
}

const QUEST_SQL: &str = "\
    SELECT q.id, q.land, q.category, q.node, q.title,
           coalesce(p.state, 'open'),
           coalesce(p.stars, 0),
           coalesce(s.submits, 0),
           coalesce(s.failures, 0),
           coalesce(p.hints_used, 0),
           p.best_ms, p.first_clear_at, p.opened_at, s.last_at,
           coalesce(e.depth, 0), coalesce(c.cursor, 0)
      FROM quests q
      LEFT JOIN progress p ON p.address = ?1 AND p.quest_id = q.id
      LEFT JOIN (SELECT quest_id,
                        sum(mode = 'submit') AS submits,
                        sum(mode = 'submit' AND verdict <> 'accepted') AS failures,
                        max(created_at) AS last_at
                   FROM attempts WHERE address = ?1 GROUP BY quest_id) s
             ON s.quest_id = q.id
      LEFT JOIN (SELECT quest_id, count(*) AS depth
                   FROM edit_stack WHERE address = ?1 GROUP BY quest_id) e
             ON e.quest_id = q.id
      LEFT JOIN edit_cursor c ON c.address = ?1 AND c.quest_id = q.id
     WHERE p.address IS NOT NULL OR s.quest_id IS NOT NULL OR e.quest_id IS NOT NULL
     ORDER BY q.land, q.category, q.node";

/// Write it to `users/<address>/progress.json`, `0600` like everything else
/// in the tree.
pub fn write(conn: &Connection, home: &Home, address: &str) -> Result<()> {
    let snap = build(conn, address)?;
    home.ensure_user_dirs(address)?;
    write_private(
        &home.progress_path(address),
        serde_json::to_vec_pretty(&snap)?,
    )
}
