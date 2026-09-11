//! `stats.summary` (SPEC §6.2). Everything is scoped to one address.

use rusqlite::{params, Connection};
use serde::Serialize;

use crate::error::Result;

#[derive(Debug, Clone, Serialize)]
pub struct Summary {
    pub cleared: i64,
    pub total: i64,
    pub attempts: i64,
    /// accepted / total, 0.0 when there is nothing to divide.
    pub accuracy: f64,
    /// Consecutive days, ending today or yesterday, with at least one
    /// attempt. Day-shaped rather than attempt-shaped because that is what a
    /// player means by a streak; PROTOCOL §4.13 names the field and not the
    /// rule, so this one is written down in docs/decisions.md.
    pub streak_days: i64,
    pub stars: i64,
    pub by_land: Vec<LandStat>,
}

#[derive(Debug, Clone, Serialize)]
pub struct LandStat {
    pub land: String,
    pub cleared: i64,
    pub total: i64,
}

pub fn summary(conn: &Connection, address: &str) -> Result<Summary> {
    let cleared: i64 = conn.query_row(
        "SELECT count(*) FROM progress WHERE address = ?1 AND state = 'cleared'",
        params![address],
        |r| r.get(0),
    )?;
    // PROTOCOL §4.9b: accuracy is submits over submits. Iterating honestly
    // with the RUN button must not read as failing repeatedly — and since
    // `accuracy` is `accepted / attempts`, the denominator has to be the same
    // population as the numerator or the number means nothing.
    let attempts: i64 = conn.query_row(
        "SELECT count(*) FROM attempts WHERE address = ?1 AND mode = 'submit'",
        params![address],
        |r| r.get(0),
    )?;
    let accepted: i64 = conn.query_row(
        "SELECT count(*) FROM attempts
          WHERE address = ?1 AND mode = 'submit' AND verdict = 'accepted'",
        params![address],
        |r| r.get(0),
    )?;
    let accuracy = if attempts == 0 {
        0.0
    } else {
        accepted as f64 / attempts as f64
    };

    let mut stmt = conn.prepare(
        "SELECT q.land,
                count(*),
                sum(CASE WHEN p.state = 'cleared' THEN 1 ELSE 0 END)
           FROM quests q
           LEFT JOIN progress p ON p.quest_id = q.id AND p.address = ?1
          GROUP BY q.land ORDER BY q.land",
    )?;
    let mut by_land = Vec::new();
    for row in stmt.query_map(params![address], |r| {
        Ok(LandStat {
            land: r.get(0)?,
            total: r.get(1)?,
            cleared: r.get::<_, Option<i64>>(2)?.unwrap_or(0),
        })
    })? {
        by_land.push(row?);
    }

    let total: i64 = conn.query_row("SELECT count(*) FROM quests", [], |r| r.get(0))?;
    Ok(Summary {
        cleared,
        total,
        attempts,
        accuracy,
        streak_days: streak(conn, address)?,
        stars: crate::progress::stars_total(conn, address)?,
        by_land,
    })
}

/// Both modes, deliberately: a streak is "days you turned up", and a day spent
/// iterating with the RUN button is a day you turned up.
fn streak(conn: &Connection, address: &str) -> Result<i64> {
    let mut stmt = conn.prepare(
        "SELECT DISTINCT substr(created_at, 1, 10) AS day FROM attempts
          WHERE address = ?1 ORDER BY day DESC LIMIT 400",
    )?;
    let days: Vec<String> = stmt
        .query_map(params![address], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let today = crate::time::now().date_naive();
    let mut streak = 0i64;
    let mut expected = today;
    for (i, day) in days.iter().enumerate() {
        let parsed = match chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d") {
            Ok(d) => d,
            Err(_) => continue,
        };
        if i == 0 && parsed == today - chrono::Duration::days(1) {
            // Yesterday still counts: a streak should not break at midnight
            // while the player is asleep.
            expected = parsed;
        }
        if parsed == expected {
            streak += 1;
            expected -= chrono::Duration::days(1);
        } else {
            break;
        }
    }
    Ok(streak)
}
