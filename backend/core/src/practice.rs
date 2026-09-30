//! What to play next in a land, when the player would rather be told (§4.14d).
//!
//! Three tiers, and each only speaks when the one before it has nothing:
//!
//! 1. **`first`** — the first quest not yet cleared, in road order
//!    (VERY BASIC, BASIC, ADVANCED, HACKER) and then node order. A player
//!    working through a land is sent to the next street, not a random one.
//! 2. **`review`** — everything is cleared, but some quests still *owe*: each
//!    failed submit is a debt, and each clean clear after the first pays one
//!    back. A random pick, weighted by what is owed, so the quest failed five
//!    times comes up five times as often as the one failed once — a mistake
//!    made once is the one most likely to be made again.
//! 3. **`rotate`** — nothing is owed. A random pick among the quests practised
//!    longest ago, so repetition goes round the whole land evenly.
//!
//! Tiers two and three never hand back the quest submitted last, unless it is
//! the only one there is: "again" straight after a clear is not practice.
//!
//! Only submits count, as in [`crate::snapshot::weakest`]: RUN is iteration,
//! not a verdict (§4.9b).

use rand::Rng;
use rusqlite::{params, Connection};
use serde::Serialize;

use crate::error::Result;

#[derive(Debug, Clone, Serialize)]
pub struct Next {
    pub quest_id: String,
    pub land: String,
    pub category: String,
    pub node: i64,
    pub title: String,
    /// `"first"`, `"review"` or `"rotate"` — which tier chose it.
    pub reason: &'static str,
    /// Failed submits still to be paid back with clean clears. 0 outside `review`.
    pub owed: i64,
}

/// How many of the longest-unpractised quests `rotate` chooses among. Enough
/// that the order is not a fixed cycle, few enough that it stays even.
const ROTATE_POOL: usize = 5;

struct Row {
    quest_id: String,
    category: String,
    node: i64,
    title: String,
    cleared: bool,
    failures: i64,
    accepted: i64,
    /// The rowid of the latest submit, 0 for never: insertion order, which a
    /// one-second timestamp cannot tell apart.
    last: i64,
}

/// The next quest in `land` for `address`. `None` only for a land with no quests.
pub fn next(conn: &Connection, address: &str, land: &str) -> Result<Option<Next>> {
    next_with(conn, address, land, &mut rand::thread_rng())
}

/// [`next`], with the dice passed in so a test can fix them.
pub fn next_with(
    conn: &Connection,
    address: &str,
    land: &str,
    rng: &mut impl Rng,
) -> Result<Option<Next>> {
    let mut stmt = conn.prepare(
        "SELECT q.id, q.category, q.node, q.title,
                coalesce(p.state = 'cleared', 0),
                coalesce(sum(CASE WHEN a.verdict <> 'accepted' THEN 1 ELSE 0 END), 0),
                coalesce(sum(CASE WHEN a.verdict = 'accepted' THEN 1 ELSE 0 END), 0),
                coalesce(max(a.rowid), 0)
           FROM quests q
           LEFT JOIN progress p ON p.address = ?1 AND p.quest_id = q.id
           LEFT JOIN attempts a ON a.address = ?1 AND a.quest_id = q.id AND a.mode = 'submit'
          WHERE q.land = ?2
          GROUP BY q.id
          ORDER BY CASE q.category
                     WHEN 'verybasic' THEN 0 WHEN 'basic' THEN 1
                     WHEN 'advanced' THEN 2 WHEN 'hacker' THEN 3 ELSE 4 END,
                   q.node",
    )?;
    let rows: Vec<Row> = stmt
        .query_map(params![address, land], |r| {
            Ok(Row {
                quest_id: r.get(0)?,
                category: r.get(1)?,
                node: r.get(2)?,
                title: r.get(3)?,
                cleared: r.get::<_, i64>(4)? != 0,
                failures: r.get(5)?,
                accepted: r.get(6)?,
                last: r.get(7)?,
            })
        })?
        .collect::<rusqlite::Result<_>>()?;

    let pick = |row: &Row, reason: &'static str, owed: i64| Next {
        quest_id: row.quest_id.clone(),
        land: land.to_string(),
        category: row.category.clone(),
        node: row.node,
        title: row.title.clone(),
        reason,
        owed,
    };

    if let Some(row) = rows.iter().find(|r| !r.cleared) {
        return Ok(Some(pick(row, "first", 0)));
    }
    if rows.is_empty() {
        return Ok(None);
    }

    // The quest just submitted sits out, unless it is all there is.
    let latest = rows.iter().map(|r| r.last).max().unwrap_or(0);
    let pool: Vec<&Row> = if rows.len() > 1 && latest > 0 {
        rows.iter().filter(|r| r.last != latest).collect()
    } else {
        rows.iter().collect()
    };

    let owed = |r: &Row| (r.failures - (r.accepted - 1).max(0)).max(0);
    let debts: Vec<(&Row, i64)> = pool
        .iter()
        .map(|r| (*r, owed(r)))
        .filter(|(_, o)| *o > 0)
        .collect();
    if !debts.is_empty() {
        let total: i64 = debts.iter().map(|(_, o)| o).sum();
        let mut roll = rng.gen_range(0..total);
        for (row, o) in &debts {
            if roll < *o {
                return Ok(Some(pick(row, "review", *o)));
            }
            roll -= o;
        }
    }

    let mut stale = pool;
    // Oldest practice first; never-submitted (0) before anything submitted.
    stale.sort_by_key(|r| r.last);
    stale.truncate(ROTATE_POOL);
    let row = stale[rng.gen_range(0..stale.len())];
    Ok(Some(pick(row, "rotate", 0)))
}
