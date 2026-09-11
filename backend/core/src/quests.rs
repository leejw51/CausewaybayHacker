//! Reading content back out: the quest row, and the world and map shapes the
//! wire asks for (SPEC §6.2, §6.3).

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::error::{not_found, Result};

#[derive(Debug, Clone, Serialize)]
pub struct Quest {
    pub id: String,
    pub pack: String,
    pub land: String,
    pub category: String,
    pub node: i64,
    pub title: String,
    pub brief: String,
    pub story: String,
    pub difficulty: i64,
    pub time_limit_s: Option<i64>,
    pub starter: String,
    #[serde(skip)]
    pub solution: String,
    pub hints: Vec<String>,
    pub concepts: Vec<String>,
    pub tests: serde_json::Value,
    pub checksum: String,
    pub map: MapPos,
}

#[derive(Debug, Clone, Serialize)]
pub struct MapPos {
    pub x: f64,
    pub y: f64,
    pub kind: String,
}

impl Quest {
    /// The PROTOCOL §5.3 `Quest`. `solution` is **omitted entirely** unless
    /// the player has cleared it — not null, not empty — and `tests` carries
    /// only the visible cases plus a count of the hidden ones.
    pub fn to_wire(
        &self,
        state: crate::progress::State,
        stars: i64,
        hints_used: i64,
        opened_at: Option<&str>,
        draft: Option<&str>,
    ) -> serde_json::Value {
        let cleared = state == crate::progress::State::Cleared;
        let mut value = serde_json::json!({
            "id": self.id,
            "land": self.land,
            "category": self.category,
            "node": self.node,
            "title": self.title,
            "brief": self.brief,
            "story": self.story,
            "difficulty": self.difficulty,
            "time_limit_s": self.time_limit_s,
            "starter": self.starter,
            // The source of the player's most recent run or submit on this
            // quest, or null on a first visit — so the editor opens where
            // they left off instead of the bare starter. See
            // attempts::latest_source for what "most recent" means.
            "draft": draft,
            "concepts": self.concepts,
            "hints_total": self.hints.len(),
            "hints_used": hints_used,
            "state": state,
            "stars": stars,
            // PROTOCOL §4.8b: the same pair every time, so a reload shows one
            // clock rather than a fresh one. Both null on an untimed quest.
            "opened_at": opened_at,
            "deadline_at": crate::progress::deadline(opened_at, self.time_limit_s),
            "tests": self.tests_wire(),
        });
        if cleared {
            value["solution"] = serde_json::Value::String(self.solution.clone());
        }
        value
    }

    /// The same quest with the answer and the hints taken away, for the
    /// duration of an interview (PROTOCOL §4.9e). Not rate-limited, not
    /// "hidden behind a click" — absent. A live screen does not come with
    /// hints, and one that did would rehearse the wrong hour.
    pub fn to_wire_under_interview(
        &self,
        state: crate::progress::State,
        stars: i64,
        opened_at: Option<&str>,
    ) -> serde_json::Value {
        // No draft either, on the same reasoning as no hints and no solution:
        // a live screen starts from the starter, the way a real interview
        // does, not from whatever the player had half-written before it began.
        let mut value = self.to_wire(state, stars, 0, opened_at, None);
        if let Some(object) = value.as_object_mut() {
            object.remove("solution");
            object.insert("hints_total".into(), serde_json::json!(0));
            object.insert("under_interview".into(), serde_json::json!(true));
        }
        value
    }

    fn tests_wire(&self) -> serde_json::Value {
        let empty = Vec::new();
        let cases = self
            .tests
            .get("cases")
            .and_then(|c| c.as_array())
            .unwrap_or(&empty);
        let mut visible = Vec::new();
        let mut hidden = 0;
        for case in cases {
            let is_visible = case
                .get("visible")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            if is_visible {
                visible.push(serde_json::json!({
                    "name": case.get("name").cloned().unwrap_or_default(),
                    "stdin": case.get("stdin").cloned().unwrap_or_default(),
                    "expect": case.get("expect").cloned().unwrap_or_default(),
                }));
            } else {
                // A hidden case is a count and nothing else. A player who can
                // enumerate them can game them.
                hidden += 1;
            }
        }
        serde_json::json!({
            "match": self.tests.get("match").and_then(|m| m.as_str()).unwrap_or("trim"),
            "timeout_ms": self.tests.get("timeout_ms").and_then(|t| t.as_u64()).unwrap_or(5000),
            "visible": visible,
            "hidden_count": hidden,
        })
    }
}

const COLUMNS: &str = "id, pack, land, category, node, title, brief, story, difficulty,
                       time_limit_s, starter, solution, hints, concepts, tests, checksum,
                       map_x, map_y, map_kind";

fn row_to_quest(row: &rusqlite::Row<'_>) -> rusqlite::Result<Quest> {
    let hints: String = row.get(12)?;
    let concepts: String = row.get(13)?;
    let tests: String = row.get(14)?;
    Ok(Quest {
        id: row.get(0)?,
        pack: row.get(1)?,
        land: row.get(2)?,
        category: row.get(3)?,
        node: row.get(4)?,
        title: row.get(5)?,
        brief: row.get(6)?,
        story: row.get(7)?,
        difficulty: row.get(8)?,
        time_limit_s: row.get(9)?,
        starter: row.get(10)?,
        solution: row.get(11)?,
        hints: serde_json::from_str(&hints).unwrap_or_default(),
        concepts: serde_json::from_str(&concepts).unwrap_or_default(),
        tests: serde_json::from_str(&tests).unwrap_or_else(|_| serde_json::json!({})),
        checksum: row.get(15)?,
        map: MapPos {
            x: row.get(16)?,
            y: row.get(17)?,
            kind: row.get(18)?,
        },
    })
}

pub fn get(conn: &Connection, quest_id: &str) -> Result<Quest> {
    conn.query_row(
        &format!("SELECT {COLUMNS} FROM quests WHERE id = ?1"),
        params![quest_id],
        row_to_quest,
    )
    .optional()?
    .ok_or_else(|| not_found(format!("no quest '{quest_id}'")))
}

pub fn list(conn: &Connection, land: &str, category: &str) -> Result<Vec<Quest>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {COLUMNS} FROM quests WHERE land = ?1 AND category = ?2 ORDER BY node"
    ))?;
    let rows = stmt.query_map(params![land, category], row_to_quest)?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn list_all(conn: &Connection) -> Result<Vec<Quest>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {COLUMNS} FROM quests ORDER BY land, category, node"
    ))?;
    let rows = stmt.query_map([], row_to_quest)?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// The edges of the map: `(requires_id, quest_id)`, i.e. "from → to", which is
/// the direction the map draws a path in.
pub fn edges(conn: &Connection, land: &str, category: &str) -> Result<Vec<(String, String)>> {
    let mut stmt = conn.prepare(
        "SELECT d.requires_id, d.quest_id
           FROM quest_deps d
           JOIN quests q ON q.id = d.quest_id
          WHERE q.land = ?1 AND q.category = ?2
          ORDER BY d.requires_id, d.quest_id",
    )?;
    let rows = stmt.query_map(params![land, category], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn requirements(conn: &Connection, quest_id: &str) -> Result<Vec<String>> {
    let mut stmt = conn
        .prepare("SELECT requires_id FROM quest_deps WHERE quest_id = ?1 ORDER BY requires_id")?;
    let rows = stmt.query_map(params![quest_id], |r| r.get(0))?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}
