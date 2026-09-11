//! `world.lands` and `world.map` (SPEC §6.2, §6.3).

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
}

pub fn lands(conn: &Connection, address: &str) -> Result<Vec<Land>> {
    let mut stmt = conn.prepare(
        "SELECT q.land, q.category, count(*),
                sum(CASE WHEN p.state = 'cleared' THEN 1 ELSE 0 END)
           FROM quests q
           LEFT JOIN progress p ON p.quest_id = q.id AND p.address = ?1
          GROUP BY q.land, q.category
          ORDER BY q.land, q.category",
    )?;
    let rows: Vec<(String, String, i64, Option<i64>)> = stmt
        .query_map(params![address], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let mut lands: Vec<Land> = Vec::new();
    for (land, category, total, cleared) in rows {
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
            cleared: cleared.unwrap_or(0),
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
            state: progress::derive_state(&quest.id, &requires, &cleared),
            quest_id: quest.id.clone(),
            node: quest.node,
            title: quest.title.clone(),
            difficulty: quest.difficulty,
            stars: row.stars,
            x: quest.map.x,
            y: quest.map.y,
            kind: quest.map.kind.clone(),
        });
    }
    Ok(Map {
        nodes,
        edges: quests::edges(conn, land, category)?,
    })
}

/// The one place that answers "may this player open this quest?" — used by
/// `quest.get` and by the submit path, so the two cannot disagree.
pub fn state_of(conn: &Connection, address: &str, quest_id: &str) -> Result<State> {
    let requires = quests::requirements(conn, quest_id)?;
    let cleared = progress::cleared_set(conn, address)?;
    Ok(progress::derive_state(quest_id, &requires, &cleared))
}
