//! AI mode (SPEC §7.3): three plans, all built from the tables the server
//! already keeps. No external model is required for any of them, and none is
//! used — the "AI" here is a join against a record of what the player actually
//! did, which is both cheaper and more honest than asking a language model to
//! guess.
//!
//! A plan is a **fixed ordered list**, written into `drills.plan` at creation.
//! A reconnect resumes the same session rather than reshuffling under the
//! player, which matters because the point of a drill is to finish it.

use std::collections::{BTreeMap, HashSet};

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::error::{bad_request, not_found, Result};
use crate::{ids, mistakes, progress, quests};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Repeat,
    Weakness,
    Spaced,
}

impl Mode {
    pub fn parse(s: &str) -> Result<Mode> {
        Ok(match s {
            "repeat" => Mode::Repeat,
            "weakness" => Mode::Weakness,
            "spaced" => Mode::Spaced,
            other => return Err(bad_request(format!("unknown drill mode '{other}'"))),
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Repeat => "repeat",
            Mode::Weakness => "weakness",
            Mode::Spaced => "spaced",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Drill {
    pub id: String,
    pub mode: Mode,
    pub plan: Vec<String>,
    pub cursor: i64,
    pub reason: String,
    pub created_at: String,
    pub finished_at: Option<String>,
}

pub const DEFAULT_SIZE: usize = 5;
pub const MAX_SIZE: usize = 20;

// ---------------------------------------------------------------------------
// Building a plan
// ---------------------------------------------------------------------------

struct Built {
    plan: Vec<String>,
    reason: String,
}

pub fn create(
    conn: &Connection,
    address: &str,
    mode: Mode,
    land: Option<&str>,
    size: usize,
) -> Result<Drill> {
    let size = size.clamp(1, MAX_SIZE);
    let built = match mode {
        Mode::Repeat => repeat(conn, address, land, size)?,
        Mode::Weakness => weakness(conn, address, land, size)?,
        Mode::Spaced => spaced(conn, address, land, size)?,
    };
    let id = ids::drill_id();
    conn.execute(
        "INSERT INTO drills (id, address, mode, plan, cursor, reason, created_at)
         VALUES (?1, ?2, ?3, ?4, 0, ?5, ?6)",
        params![
            id,
            address,
            mode.as_str(),
            serde_json::to_string(&built.plan)?,
            built.reason,
            crate::time::now_stamp()
        ],
    )?;
    get(conn, address, &id)
}

/// "Do it again until it sticks": the quests failed most, newest first.
fn repeat(conn: &Connection, address: &str, land: Option<&str>, size: usize) -> Result<Built> {
    let mut stmt = conn.prepare(
        "SELECT a.quest_id, count(*) AS fails, max(a.created_at) AS last
           FROM attempts a JOIN quests q ON q.id = a.quest_id
          WHERE a.address = ?1 AND a.mode = 'submit' AND a.verdict <> 'accepted'
            AND (?2 IS NULL OR q.land = ?2)
          GROUP BY a.quest_id
          ORDER BY fails DESC, last DESC
          LIMIT ?3",
    )?;
    let plan: Vec<String> = stmt
        .query_map(params![address, land, size as i64], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if !plan.is_empty() {
        let worst: i64 = conn.query_row(
            "SELECT count(*) FROM attempts
              WHERE address = ?1 AND quest_id = ?2 AND mode = 'submit' AND verdict <> 'accepted'",
            params![address, plan[0]],
            |r| r.get(0),
        )?;
        return Ok(Built {
            reason: format!(
                "the {} quests you have failed most — starting with one you have missed {worst} times",
                plan.len()
            ),
            plan,
        });
    }
    // Nothing failed yet. Not the same fallback as the other two modes: this
    // one is about going back over hard ground, so it offers the ground you
    // have started on and not finished.
    let started = uncleared_attempted(conn, address, land, size)?;
    if !started.is_empty() {
        return Ok(Built {
            reason: "nothing has beaten you yet — here is what you started and have not finished"
                .into(),
            plan: started,
        });
    }
    Ok(Built {
        plan: next_uncleared(conn, address, land, size)?,
        reason: "nothing to repeat yet: you have not failed anything. Here is the road ahead"
            .into(),
    })
}

/// The one that actually teaches (SPEC §7.3).
///
/// Group by `mistake_stats.kind`, take the top kinds still worth practising
/// (`cleared_since < 5`), then pull quests whose `concepts` overlap that
/// kind's set — **including quests already cleared**. Finding
/// *borrow-after-move* and handing over five different shapes of it is the
/// whole idea; a drill that only offered unsolved quests would run out
/// precisely when a player is getting good.
///
/// The kind → concepts table is `docs/concepts.md`'s, via
/// `mistakes::concepts_for`. Inventing a mapping here would make the join
/// reach nothing.
fn weakness(conn: &Connection, address: &str, land: Option<&str>, size: usize) -> Result<Built> {
    let mut stmt = conn.prepare(
        "SELECT kind, count FROM mistake_stats
          WHERE address = ?1 AND cleared_since < 5
          ORDER BY count DESC, last_at DESC
          LIMIT 6",
    )?;
    let kinds: Vec<(String, i64)> = stmt
        .query_map(params![address], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(stmt);

    let mut plan = Vec::new();
    let mut seen = HashSet::new();
    let mut headline: Option<(String, i64)> = None;
    for (kind, times) in &kinds {
        // `other` maps to no concepts **by design** (docs/concepts.md): an
        // unrecognised compiler code carries no information about which idea
        // is missing, so guessing one would be worse than not guessing. The
        // fallback is the concepts of the quests the mistake actually happened
        // on — which is a fact rather than a guess.
        let owned: Vec<String>;
        let concepts: Vec<&str> = if kind == "other" {
            owned = concepts_of_quests_where_made(conn, address, kind)?;
            owned.iter().map(String::as_str).collect()
        } else {
            mistakes::concepts_for(kind).to_vec()
        };
        if concepts.is_empty() {
            continue;
        }
        let concepts = concepts.as_slice();
        let matches = quests_touching(conn, land, concepts)?;
        if matches.is_empty() {
            continue;
        }
        if headline.is_none() {
            headline = Some((kind.clone(), *times));
        }
        for quest_id in matches {
            if plan.len() >= size {
                break;
            }
            if seen.insert(quest_id.clone()) {
                plan.push(quest_id);
            }
        }
        if plan.len() >= size {
            break;
        }
    }

    if let Some((kind, times)) = headline {
        return Ok(Built {
            reason: format!(
                "you hit {} {times} times — these are {} other shapes of the same idea",
                mistakes::label(&kind),
                plan.len()
            ),
            plan,
        });
    }
    // No mistakes worth drilling. Say what that means rather than handing back
    // an empty list in silence — and make it a genuinely different list from
    // the other two modes: one quest per idea the player has not touched yet.
    let breadth = untouched_concepts(conn, address, land, size)?;
    Ok(Built {
        reason: if breadth.is_empty() {
            "no weak spots and nothing new to show you — you have run out of map".into()
        } else {
            "you have no mistakes worth drilling yet, so this is a spread of ideas you have not \
             met — come back when something has gone wrong"
                .into()
        },
        plan: breadth,
    })
}

/// Cleared quests due for review, on an SM-2-ish interval from
/// `first_clear_at` and the star count: 3 stars comes back in 14 days, 1 in 2.
fn spaced(conn: &Connection, address: &str, land: Option<&str>, size: usize) -> Result<Built> {
    let mut stmt = conn.prepare(
        "SELECT p.quest_id, p.stars, p.first_clear_at
           FROM progress p JOIN quests q ON q.id = p.quest_id
          WHERE p.address = ?1 AND p.state = 'cleared' AND p.first_clear_at IS NOT NULL
            AND (?2 IS NULL OR q.land = ?2)",
    )?;
    let cleared: Vec<(String, i64, String)> = stmt
        .query_map(params![address, land], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(stmt);

    let now = crate::time::now();
    let mut due: Vec<(i64, String)> = Vec::new();
    let mut soonest: Vec<(i64, String)> = Vec::new();
    for (quest_id, stars, first_clear_at) in cleared {
        let Some(cleared_at) = crate::time::parse(&first_clear_at) else {
            continue;
        };
        let due_at = cleared_at + chrono::Duration::days(review_interval_days(stars));
        // Most overdue first: the thing you are likeliest to have lost.
        let overdue = (now - due_at).num_minutes();
        if overdue >= 0 {
            due.push((overdue, quest_id));
        } else {
            soonest.push((-overdue, quest_id));
        }
    }
    due.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    if !due.is_empty() {
        let plan: Vec<String> = due.into_iter().take(size).map(|(_, id)| id).collect();
        return Ok(Built {
            reason: format!("{} cleared quests are due for review", plan.len()),
            plan,
        });
    }
    // Nothing due. Again, deliberately not the same list as the other modes:
    // the most recently cleared, so a player can look over their own work.
    soonest.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    let plan: Vec<String> = soonest.into_iter().take(size).map(|(_, id)| id).collect();
    Ok(Built {
        reason: if plan.is_empty() {
            "nothing to review yet — clear something first and it will come back to you".into()
        } else {
            "nothing is due yet; these are the ones that come back soonest".into()
        },
        plan,
    })
}

/// 3 stars → 14 days, 1 star → 2. The middle is interpolated; the two ends are
/// SPEC §7.3's.
pub fn review_interval_days(stars: i64) -> i64 {
    match stars {
        3 => 14,
        2 => 7,
        _ => 2,
    }
}

/// The concepts of the quests where a player actually made this kind of
/// mistake. The fallback for `other`, whose row in `docs/concepts.md` is
/// deliberately empty.
fn concepts_of_quests_where_made(
    conn: &Connection,
    address: &str,
    kind: &str,
) -> Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT DISTINCT q.concepts FROM mistakes m JOIN quests q ON q.id = m.quest_id
          WHERE m.address = ?1 AND m.kind = ?2",
    )?;
    let rows: Vec<String> = stmt
        .query_map(params![address, kind], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut out: Vec<String> = Vec::new();
    for raw in rows {
        for concept in serde_json::from_str::<Vec<String>>(&raw).unwrap_or_default() {
            if !out.contains(&concept) {
                out.push(concept);
            }
        }
    }
    Ok(out)
}

fn quests_touching(
    conn: &Connection,
    land: Option<&str>,
    concepts: &[&str],
) -> Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT id, concepts, node FROM quests
          WHERE (?1 IS NULL OR land = ?1) ORDER BY land, category, node",
    )?;
    let rows: Vec<(String, String, i64)> = stmt
        .query_map(params![land], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut scored: Vec<(usize, String)> = Vec::new();
    for (id, raw, _node) in rows {
        let quest_concepts: Vec<String> = serde_json::from_str(&raw).unwrap_or_default();
        let overlap = quest_concepts
            .iter()
            .filter(|c| concepts.contains(&c.as_str()))
            .count();
        if overlap > 0 {
            scored.push((overlap, id));
        }
    }
    // Most on-topic first; the first concept in a kind's row is the one that
    // most directly teaches it, so a quest carrying it ranks above one that
    // merely brushes past.
    scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    Ok(scored.into_iter().map(|(_, id)| id).collect())
}

fn uncleared_attempted(
    conn: &Connection,
    address: &str,
    land: Option<&str>,
    size: usize,
) -> Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT DISTINCT a.quest_id FROM attempts a
           JOIN quests q ON q.id = a.quest_id
           LEFT JOIN progress p ON p.quest_id = a.quest_id AND p.address = a.address
          WHERE a.address = ?1 AND (?2 IS NULL OR q.land = ?2)
            AND (p.state IS NULL OR p.state <> 'cleared')
          ORDER BY a.quest_id LIMIT ?3",
    )?;
    let out: Vec<String> = stmt
        .query_map(params![address, land, size as i64], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(out)
}

fn next_uncleared(
    conn: &Connection,
    address: &str,
    land: Option<&str>,
    size: usize,
) -> Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT q.id FROM quests q
           LEFT JOIN progress p ON p.quest_id = q.id AND p.address = ?1
          WHERE (?2 IS NULL OR q.land = ?2) AND (p.state IS NULL OR p.state <> 'cleared')
          ORDER BY q.land, q.category, q.node LIMIT ?3",
    )?;
    let out: Vec<String> = stmt
        .query_map(params![address, land, size as i64], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(out)
}

/// One quest per idea the player has not met — a breadth sampler, so a new
/// player's `weakness` drill is genuinely different from their `repeat` and
/// `spaced` ones rather than the same five nodes three times.
fn untouched_concepts(
    conn: &Connection,
    address: &str,
    land: Option<&str>,
    size: usize,
) -> Result<Vec<String>> {
    let cleared = progress::cleared_set(conn, address)?;
    let mut met: HashSet<String> = HashSet::new();
    for quest_id in &cleared {
        if let Ok(quest) = quests::get(conn, quest_id) {
            met.extend(quest.concepts);
        }
    }
    let mut stmt = conn.prepare(
        "SELECT id, concepts FROM quests WHERE (?1 IS NULL OR land = ?1)
          ORDER BY land, category, node",
    )?;
    let rows: Vec<(String, String)> = stmt
        .query_map(params![land], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut picked: BTreeMap<String, String> = BTreeMap::new();
    for (id, raw) in rows {
        if cleared.contains(&id) {
            continue;
        }
        let concepts: Vec<String> = serde_json::from_str(&raw).unwrap_or_default();
        for concept in concepts {
            if met.contains(&concept) || picked.contains_key(&concept) {
                continue;
            }
            picked.insert(concept, id.clone());
            break;
        }
        if picked.len() >= size {
            break;
        }
    }
    let mut out: Vec<String> = Vec::new();
    for id in picked.into_values() {
        if !out.contains(&id) {
            out.push(id);
        }
    }
    out.truncate(size);
    Ok(out)
}

// ---------------------------------------------------------------------------
// Walking a plan
// ---------------------------------------------------------------------------

pub fn get(conn: &Connection, address: &str, drill_id: &str) -> Result<Drill> {
    conn.query_row(
        "SELECT id, mode, plan, cursor, reason, created_at, finished_at
           FROM drills WHERE id = ?1 AND address = ?2",
        params![drill_id, address],
        |r| {
            let mode: String = r.get(1)?;
            let plan: String = r.get(2)?;
            Ok(Drill {
                id: r.get(0)?,
                mode: Mode::parse(&mode).unwrap_or(Mode::Repeat),
                plan: serde_json::from_str(&plan).unwrap_or_default(),
                cursor: r.get(3)?,
                reason: r.get(4)?,
                created_at: r.get(5)?,
                finished_at: r.get(6)?,
            })
        },
    )
    .optional()?
    .ok_or_else(|| not_found("no such drill"))
}

pub struct Step {
    pub quest_id: String,
    pub position: i64,
    pub total: i64,
    pub why: String,
}

/// The next quest in the plan, and **why** it is next — one sentence,
/// generated from the tables. It is what makes the mode feel like a coach
/// rather than a shuffle.
pub fn next(conn: &Connection, address: &str, drill_id: &str) -> Result<Step> {
    let drill = get(conn, address, drill_id)?;
    let index = drill.cursor as usize;
    let quest_id = drill
        .plan
        .get(index)
        .cloned()
        .ok_or_else(|| not_found("the drill is finished"))?;
    conn.execute(
        "UPDATE drills SET cursor = ?3 WHERE id = ?1 AND address = ?2",
        params![drill_id, address, drill.cursor + 1],
    )?;
    Ok(Step {
        why: why(conn, address, drill.mode, &quest_id)?,
        quest_id,
        position: drill.cursor + 1,
        total: drill.plan.len() as i64,
    })
}

fn why(conn: &Connection, address: &str, mode: Mode, quest_id: &str) -> Result<String> {
    Ok(match mode {
        Mode::Repeat => {
            let fails: i64 = conn.query_row(
                "SELECT count(*) FROM attempts
                  WHERE address = ?1 AND quest_id = ?2 AND mode = 'submit'
                    AND verdict <> 'accepted'",
                params![address, quest_id],
                |r| r.get(0),
            )?;
            match fails {
                0 => "you have not beaten this one yet".to_string(),
                1 => "this one caught you once".to_string(),
                n => format!("this one has caught you {n} times"),
            }
        }
        Mode::Weakness => {
            let quest = quests::get(conn, quest_id)?;
            let mut stmt = conn.prepare(
                "SELECT kind, count FROM mistake_stats
                  WHERE address = ?1 AND cleared_since < 5 AND kind <> 'other'
                  ORDER BY count DESC, last_at DESC",
            )?;
            let kinds: Vec<(String, i64)> = stmt
                .query_map(params![address], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let hit = kinds.iter().find(|(kind, _)| {
                mistakes::concepts_for(kind)
                    .iter()
                    .any(|c| quest.concepts.iter().any(|q| q == c))
            });
            match hit {
                Some((kind, times)) => format!(
                    "you hit {} {times} times, and this one is about {}",
                    mistakes::label(kind),
                    quest.concepts.first().map(String::as_str).unwrap_or("it")
                ),
                None => format!(
                    "a different shape of {}",
                    quest.concepts.first().map(String::as_str).unwrap_or("this")
                ),
            }
        }
        Mode::Spaced => {
            let row = progress::get(conn, address, quest_id)?;
            match row.first_clear_at.as_deref().and_then(crate::time::parse) {
                Some(cleared_at) => {
                    let days = (crate::time::now() - cleared_at).num_days();
                    format!(
                        "you cleared this {days} days ago with {} star{}; {} days is when it fades",
                        row.stars,
                        if row.stars == 1 { "" } else { "s" },
                        review_interval_days(row.stars)
                    )
                }
                None => "worth another look".to_string(),
            }
        }
    })
}

#[derive(Debug, Clone, Serialize)]
pub struct Summary {
    pub attempted: i64,
    pub cleared: i64,
    pub kinds_improved: Vec<String>,
}

/// What the session did, measured against what the player did *during* it —
/// attempts made after the drill was created, on quests in its plan.
pub fn finish(conn: &Connection, address: &str, drill_id: &str) -> Result<Summary> {
    let drill = get(conn, address, drill_id)?;
    let mut attempted = 0;
    let mut cleared = 0;
    for quest_id in &drill.plan {
        let tries: i64 = conn.query_row(
            "SELECT count(*) FROM attempts
              WHERE address = ?1 AND quest_id = ?2 AND mode = 'submit' AND created_at >= ?3",
            params![address, quest_id, drill.created_at],
            |r| r.get(0),
        )?;
        if tries > 0 {
            attempted += 1;
        }
        let won: i64 = conn.query_row(
            "SELECT count(*) FROM attempts
              WHERE address = ?1 AND quest_id = ?2 AND mode = 'submit'
                AND verdict = 'accepted' AND created_at >= ?3",
            params![address, quest_id, drill.created_at],
            |r| r.get(0),
        )?;
        if won > 0 {
            cleared += 1;
        }
    }
    // A kind improved is one the player made before this drill and has not
    // made since it started. Measured, not assumed.
    //
    // The comparison is on SPEC §2.2's timestamps, which have second
    // granularity — so a drill created and finished inside one second cannot
    // tell "before" from "during". That is the honest answer for a session
    // that lasted less than a second, and it is the only case it affects.
    let mut stmt = conn.prepare(
        "SELECT DISTINCT kind FROM mistakes
          WHERE address = ?1 AND created_at < ?2
            AND kind NOT IN (SELECT kind FROM mistakes WHERE address = ?1 AND created_at >= ?2)
          ORDER BY kind",
    )?;
    let kinds_improved: Vec<String> = stmt
        .query_map(params![address, drill.created_at], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(stmt);

    conn.execute(
        "UPDATE drills SET finished_at = ?3 WHERE id = ?1 AND address = ?2",
        params![drill_id, address, crate::time::now_stamp()],
    )?;
    Ok(Summary {
        attempted,
        cleared,
        kinds_improved,
    })
}
