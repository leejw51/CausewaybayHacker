//! `world.lands` and `world.map` (PROTOCOL §4.6, §4.7, §5.2).

use rusqlite::{params, Connection};
use serde::Serialize;

use crate::error::Result;
use crate::progress::{self, State};
use crate::quests;

#[derive(Debug, Clone, Serialize)]
pub struct Land {
    pub land: String,
    pub categories: Vec<CategoryStat>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CategoryStat {
    pub category: String,
    pub total: i64,
    pub cleared: i64,
    pub stars: i64,
    /// Whether there is anything here to play.
    ///
    /// It used to mean "the first node is unlocked", which since PROTOCOL §4.7
    /// is always true. The field stays because clients read it, and it is kept
    /// honest rather than hard-coded: a category with no quests imported is
    /// not open, and saying so is more useful to a land-select screen than a
    /// constant `true`.
    pub open: bool,
}

pub fn lands(conn: &Connection, address: &str) -> Result<Vec<Land>> {
    let mut stmt = conn.prepare(
        "SELECT q.land, q.category, count(*),
                sum(CASE WHEN p.state = 'cleared' THEN 1 ELSE 0 END),
                COALESCE(sum(p.stars), 0)
           FROM quests q
           LEFT JOIN progress p ON p.quest_id = q.id AND p.address = ?1
          GROUP BY q.land, q.category
          ORDER BY q.land, q.category",
    )?;
    let rows: Vec<(String, String, i64, Option<i64>, i64)> = stmt
        .query_map(params![address], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let mut lands: Vec<Land> = Vec::new();
    for (land, category, total, cleared_count, stars) in rows {
        let entry = match lands.iter_mut().find(|l| l.land == land) {
            Some(entry) => entry,
            None => {
                lands.push(Land {
                    land: land.clone(),
                    categories: Vec::new(),
                });
                lands.last_mut().expect("just pushed")
            }
        };
        entry.categories.push(CategoryStat {
            category,
            total,
            cleared: cleared_count.unwrap_or(0),
            stars,
            open: total > 0,
        });
    }
    Ok(lands)
}

#[derive(Debug, Clone, Serialize)]
pub struct MapNode {
    pub quest_id: String,
    pub node: i64,
    pub title: String,
    pub difficulty: i64,
    pub state: State,
    pub stars: i64,
    pub x: f64,
    pub y: f64,
    pub kind: String,
    pub requires: Vec<String>,
    pub attempts: i64,
}

pub struct Map {
    pub nodes: Vec<MapNode>,
    pub edges: Vec<(String, String)>,
}

pub fn map(conn: &Connection, address: &str, land: &str, category: &str) -> Result<Map> {
    let quests = quests::list(conn, land, category)?;
    let cleared = progress::cleared_set(conn, address)?;
    let mut nodes = Vec::with_capacity(quests.len());
    for quest in &quests {
        let requires = quests::requirements(conn, &quest.id)?;
        let row = progress::get(conn, address, &quest.id)?;
        nodes.push(MapNode {
            // `requires` still travels: it is the suggested route and the line
            // the map draws. It is not consulted here, because it gates
            // nothing (PROTOCOL §4.7).
            state: progress::derive_state(&quest.id, &cleared),
            quest_id: quest.id.clone(),
            node: quest.node,
            title: quest.title.clone(),
            difficulty: quest.difficulty,
            stars: row.stars,
            x: quest.map.x,
            y: quest.map.y,
            kind: quest.map.kind.clone(),
            requires,
            attempts: row.attempts,
        });
    }
    Ok(Map {
        nodes,
        edges: quests::edges(conn, land, category)?,
    })
}

/// Cleared, or open. Kept as one function so `quest.get`, `quest.hint`,
/// `quest.reset` and the two execution paths cannot disagree about what a node
/// is — they no longer disagree about whether it may be *entered*, because the
/// answer to that is always yes.
pub fn state_of(conn: &Connection, address: &str, quest_id: &str) -> Result<State> {
    let cleared = progress::cleared_set(conn, address)?;
    Ok(progress::derive_state(quest_id, &cleared))
}

/// What clearing `quest_id` just finished the prerequisites for — PROTOCOL
/// §4.19's `unlocked`, so a client updates the overworld without refetching.
///
/// Since §4.7 nothing is gated, so this no longer means "these became
/// playable"; it means "these are what the suggested route says comes next,
/// and you have now done everything they asked for". The same set, a softer
/// claim, and still the thing a map wants to light up.
pub fn unlocked_by(conn: &Connection, address: &str, quest_id: &str) -> Result<Vec<String>> {
    let cleared = progress::cleared_set(conn, address)?;
    let mut stmt = conn.prepare(
        "SELECT DISTINCT quest_id FROM quest_deps WHERE requires_id = ?1 ORDER BY quest_id",
    )?;
    let dependents: Vec<String> = stmt
        .query_map(params![quest_id], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut out = Vec::new();
    for dependent in dependents {
        let requires = quests::requirements(conn, &dependent)?;
        if requires.iter().all(|r| cleared.contains(r)) && !cleared.contains(&dependent) {
            out.push(dependent);
        }
    }
    Ok(out)
}
