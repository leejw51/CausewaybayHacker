//! XP, levels and badges (PROTOCOL §4.20, PLAN.md milestone 3).
//!
//! One rule runs the whole thing: **nothing is awarded for something that did
//! not happen.** Every badge below is a query against the record — attempts,
//! progress, mistakes, stars — and if the data cannot answer the question
//! honestly, the badge does not exist. A badge that fires on the wrong thing
//! is worse than one nobody ever earns, because it makes every other badge
//! mean nothing.
//!
//! Two that were wanted and are deliberately absent, for exactly that reason:
//!
//! * **NIGHT OWL** — every timestamp here is UTC and the server has no idea
//!   what time it is where the player is sitting. "Cleared something at 3am"
//!   would fire for an afternoon in another timezone.
//! * **SPEED / FAST CLEAR** — `best_ms` is compile-plus-run time, not how long
//!   somebody took to solve it. What *is* honest is PROTOCOL §4.8b's
//!   `within_limit`, because the server owns that clock: BEAT THE CLOCK and
//!   INTERVIEW READY are built on it, and a badge for "solved it in under two
//!   minutes" still is not, because nothing measures thinking.
//!
//! Everything is evaluated by asking "is this true now?" after a submit. The
//! `UNIQUE (address, kind, award_id)` index in 0004 makes that safe to run as
//! often as we like, and self-healing: a rule added later is granted the next
//! time a player submits, without a migration that guesses at history.

use rusqlite::{params, Connection};
use serde::Serialize;

use crate::error::Result;
use crate::time::now_stamp;

#[derive(Debug, Clone, Serialize)]
pub struct Award {
    pub kind: String,
    pub id: String,
    pub title: String,
    pub detail: serde_json::Value,
    pub created_at: String,
}

// ---------------------------------------------------------------------------
// XP and levels
// ---------------------------------------------------------------------------

/// What a category is worth, relative to `basic`. A three-star clear on a
/// HACKER quest should not be worth what `first-light` is worth.
pub fn category_weight(category: &str) -> i64 {
    match category {
        "hacker" => 3,
        "advanced" => 2,
        _ => 1,
    }
}

/// The XP one cleared quest is worth: stars × difficulty × category.
///
/// An easy first clear is 25–75; a three-star five-difficulty HACKER quest is
/// 1125. The spread is the point — the map should feel different at the far
/// end from how it feels at the start.
pub fn xp_for_clear(stars: i64, difficulty: i64, category: &str) -> i64 {
    25 * stars.max(0) * difficulty.max(1) * category_weight(category)
}

/// Total XP, derived from the record rather than stored.
///
/// A counter would be one more thing that can disagree with the truth; this
/// cannot, because it *is* the truth, recomputed. It is a single indexed join
/// over a table with at most a few hundred rows per player.
pub fn total_xp(conn: &Connection, address: &str) -> Result<i64> {
    Ok(conn.query_row(
        "SELECT COALESCE(sum(25 * p.stars * q.difficulty *
                  CASE q.category WHEN 'hacker' THEN 3 WHEN 'advanced' THEN 2 ELSE 1 END), 0)
           FROM progress p JOIN quests q ON q.id = p.quest_id
          WHERE p.address = ?1 AND p.state = 'cleared'",
        params![address],
        |r| r.get(0),
    )?)
}

/// The XP at which a level begins: level 2 at 100, 3 at 300, 4 at 600 — the
/// triangular curve, so each level costs a little more than the last without
/// the thing ever stalling.
pub fn xp_for_level(level: i64) -> i64 {
    let n = level.max(1) - 1;
    100 * n * (n + 1) / 2
}

pub fn level_for_xp(xp: i64) -> i64 {
    let mut level = 1;
    while xp_for_level(level + 1) <= xp {
        level += 1;
    }
    level
}

// ---------------------------------------------------------------------------
// The rules
// ---------------------------------------------------------------------------

struct Candidate {
    kind: &'static str,
    id: String,
    title: String,
    detail: serde_json::Value,
}

fn count(conn: &Connection, sql: &str, address: &str) -> Result<i64> {
    Ok(conn.query_row(sql, params![address], |r| r.get(0))?)
}

/// Everything the player has earned as of right now.
fn earned(conn: &Connection, address: &str) -> Result<Vec<Candidate>> {
    let mut out = Vec::new();
    let mut badge = |id: &str, title: &str, detail: serde_json::Value| {
        out.push(Candidate {
            kind: "badge",
            id: id.to_string(),
            title: title.to_string(),
            detail,
        })
    };

    let cleared = count(
        conn,
        "SELECT count(*) FROM progress WHERE address = ?1 AND state = 'cleared'",
        address,
    )?;
    if cleared >= 1 {
        badge("first-clear", "FIRST CLEAR", serde_json::json!({}));
    }
    if cleared >= 25 {
        badge(
            "quarter-century",
            "TWENTY-FIVE STREETS",
            serde_json::json!({ "cleared": cleared }),
        );
    }

    // Two lands, not all of them. The one badge that says "you are not only a
    // Rust person", and two is enough to have said it — the threshold stayed
    // at 2 when C++ and Python landed, on purpose. Raising it to four would
    // recompute this badge away from everyone who had earned it with Rust and
    // Go, and a badge that can be taken back by a content release is not a
    // badge. `lands` is in the detail, so the card can still say how many.
    let lands: i64 = conn.query_row(
        "SELECT count(DISTINCT q.land) FROM progress p JOIN quests q ON q.id = p.quest_id
          WHERE p.address = ?1 AND p.state = 'cleared'",
        params![address],
        |r| r.get(0),
    )?;
    if lands >= 2 {
        badge(
            "polyglot",
            "POLYGLOT",
            serde_json::json!({ "lands": lands }),
        );
    }

    let perfect = count(
        conn,
        "SELECT count(*) FROM progress WHERE address = ?1 AND state = 'cleared' AND stars = 3",
        address,
    )?;
    if perfect >= 10 {
        badge(
            "perfectionist",
            "PERFECTIONIST",
            serde_json::json!({ "three_stars": perfect }),
        );
    }

    let unaided = count(
        conn,
        "SELECT count(*) FROM progress
          WHERE address = ?1 AND state = 'cleared' AND hints_used = 0",
        address,
    )?;
    if unaided >= 10 {
        badge(
            "no-hints",
            "NO HINTS NEEDED",
            serde_json::json!({ "cleared": unaided }),
        );
    }

    let hacker = conn.query_row(
        "SELECT count(*) FROM progress p JOIN quests q ON q.id = p.quest_id
          WHERE p.address = ?1 AND p.state = 'cleared' AND q.category = 'hacker'",
        params![address],
        |r| r.get::<_, i64>(0),
    )?;
    if hacker >= 5 {
        badge(
            "big-o",
            "BIG O MASTER",
            serde_json::json!({ "hacker_cleared": hacker }),
        );
    }

    // A whole category finished. The id carries which one, so the UNIQUE index
    // keeps them apart.
    let mut stmt = conn.prepare(
        "SELECT q.land, q.category, count(*),
                sum(CASE WHEN p.state = 'cleared' THEN 1 ELSE 0 END)
           FROM quests q
           LEFT JOIN progress p ON p.quest_id = q.id AND p.address = ?1
          GROUP BY q.land, q.category",
    )?;
    let maps: Vec<(String, String, i64, i64)> = stmt
        .query_map(params![address], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get::<_, Option<i64>>(3)?.unwrap_or(0),
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(stmt);
    for (land, category, total, done) in maps {
        if total > 0 && done == total {
            badge(
                &format!("cleared-{land}-{category}"),
                &format!(
                    "{} {} CLEARED",
                    land.to_uppercase(),
                    category.to_uppercase()
                ),
                serde_json::json!({ "land": land, "category": category, "total": total }),
            );
        }
    }

    // The combo: the current run of accepted submits with no failure in it.
    // Submits only — a run is not a considered answer (PROTOCOL §4.9b).
    let combo = current_combo(conn, address)?;
    for at in [5, 10, 25] {
        if combo >= at {
            badge(
                &format!("combo-{at}"),
                &format!("COMBO x{at}"),
                serde_json::json!({ "combo": combo }),
            );
        }
    }

    // PROTOCOL §4.8b's `within_limit` is the rare fact that makes a
    // speed-shaped badge honest: the server owns the clock, so "inside the
    // limit" is something the game actually knows rather than something a
    // client timer claimed.
    let in_time: i64 = conn.query_row(
        "SELECT count(DISTINCT a.quest_id) FROM attempts a JOIN quests q ON q.id = a.quest_id
          WHERE a.address = ?1 AND a.mode = 'submit' AND a.verdict = 'accepted'
            AND a.within_limit = 1 AND q.category = 'hacker'",
        params![address],
        |r| r.get(0),
    )?;
    if in_time >= 1 {
        badge(
            "beat-the-clock",
            "BEAT THE CLOCK",
            serde_json::json!({ "quests": in_time }),
        );
    }
    if in_time >= 5 {
        badge(
            "interview-ready",
            "INTERVIEW READY",
            serde_json::json!({ "quests": in_time }),
        );
    }

    let submits = count(
        conn,
        "SELECT count(*) FROM attempts WHERE address = ?1 AND mode = 'submit'",
        address,
    )?;
    if submits >= 100 {
        badge(
            "century",
            "ONE HUNDRED SUBMISSIONS",
            serde_json::json!({ "submits": submits }),
        );
    }
    let runs = count(
        conn,
        "SELECT count(*) FROM attempts WHERE address = ?1 AND mode = 'run'",
        address,
    )?;
    if runs >= 50 {
        badge(
            "iterator",
            "FIFTY ITERATIONS",
            serde_json::json!({ "runs": runs }),
        );
    }

    // A mistake you used to make and have stopped making. `count >= 5` is "you
    // really did keep doing this"; `cleared_since >= 5` is §7.3's own
    // definition of learned, and only submits advance it.
    let mut stmt = conn.prepare(
        "SELECT kind, count FROM mistake_stats
          WHERE address = ?1 AND count >= 5 AND cleared_since >= 5 ORDER BY kind",
    )?;
    let tamed: Vec<(String, i64)> = stmt
        .query_map(params![address], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(stmt);
    for (kind, times) in tamed {
        out.push(Candidate {
            kind: "badge",
            id: format!("tamed-{kind}"),
            title: format!("{} TAMED", crate::mistakes::label(&kind).to_uppercase()),
            detail: serde_json::json!({ "kind": kind, "made_it": times }),
        });
    }

    // Streaks are their own `kind` so a client can play a different sound.
    let streak = crate::stats::summary(conn, address)?.streak_days;
    for at in [3, 7, 30] {
        if streak >= at {
            out.push(Candidate {
                kind: "streak",
                id: format!("streak-{at}"),
                title: format!("{at} DAYS RUNNING"),
                detail: serde_json::json!({ "days": streak }),
            });
        }
    }

    // Every level reached, so somebody who jumps two at once is told twice
    // rather than silently skipped.
    let level = level_for_xp(total_xp(conn, address)?);
    for n in 2..=level {
        out.push(Candidate {
            kind: "level",
            id: format!("level-{n}"),
            title: format!("LEVEL {n}"),
            detail: serde_json::json!({ "level": n, "xp_at": xp_for_level(n) }),
        });
    }
    Ok(out)
}

/// The current run of accepted submits, newest first, stopping at the first
/// failure. Defined exactly so the badge means exactly one thing.
pub fn current_combo(conn: &Connection, address: &str) -> Result<i64> {
    let mut stmt = conn.prepare(
        "SELECT verdict FROM attempts
          WHERE address = ?1 AND mode = 'submit'
          ORDER BY created_at DESC, rowid DESC LIMIT 200",
    )?;
    let verdicts: Vec<String> = stmt
        .query_map(params![address], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(verdicts.iter().take_while(|v| *v == "accepted").count() as i64)
}

/// Grant whatever is newly true, and return only what was actually new.
///
/// Safe to call after every submit: the UNIQUE index turns "award it again"
/// into "nothing happened", so this never needs to know what it granted last
/// time.
pub fn evaluate(conn: &Connection, address: &str) -> Result<Vec<Award>> {
    let now = now_stamp();
    let mut fresh = Vec::new();
    for candidate in earned(conn, address)? {
        let inserted = conn.execute(
            "INSERT OR IGNORE INTO awards (address, kind, award_id, title, detail, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                address,
                candidate.kind,
                candidate.id,
                candidate.title,
                candidate.detail.to_string(),
                now
            ],
        )?;
        if inserted == 1 {
            fresh.push(Award {
                kind: candidate.kind.to_string(),
                id: candidate.id,
                title: candidate.title,
                detail: candidate.detail,
                created_at: now.clone(),
            });
        }
    }
    Ok(fresh)
}

/// Everything this player has earned, newest first.
pub fn list(conn: &Connection, address: &str) -> Result<Vec<Award>> {
    let mut stmt = conn.prepare(
        "SELECT kind, award_id, title, detail, created_at FROM awards
          WHERE address = ?1 ORDER BY created_at DESC, id DESC",
    )?;
    let rows = stmt.query_map(params![address], |r| {
        let detail: String = r.get(3)?;
        Ok(Award {
            kind: r.get(0)?,
            id: r.get(1)?,
            title: r.get(2)?,
            detail: serde_json::from_str(&detail).unwrap_or_else(|_| serde_json::json!({})),
            created_at: r.get(4)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}
