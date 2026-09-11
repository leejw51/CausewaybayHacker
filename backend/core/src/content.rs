//! Content packs (SPEC §12): one TOML file per land + category, imported at
//! startup and by `cwbhacker import`.
//!
//! The importer **upserts by `quests.id`** and never deletes. `progress` has
//! `ON DELETE CASCADE` against `quests`, so a delete-then-insert import would
//! wipe every player's progress on the next restart — which is precisely the
//! thing milestone 1 exists to prove does not happen (SPEC §2.2: a quest whose
//! checksum changed keeps its progress rows).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{bad_request, internal, Result};
use crate::ids::parse_quest_id;
use crate::paths::{write_private, Home};

#[derive(Debug, Clone, Deserialize)]
pub struct Pack {
    pub pack: String,
    pub land: String,
    pub category: String,
    #[serde(default = "one")]
    pub version: i64,
    #[serde(default, rename = "quest")]
    pub quests: Vec<QuestDef>,
}

fn one() -> i64 {
    1
}

#[derive(Debug, Clone, Deserialize)]
pub struct QuestDef {
    pub id: String,
    pub node: i64,
    pub title: String,
    #[serde(default = "one")]
    pub difficulty: i64,
    #[serde(default)]
    pub story: String,
    #[serde(default)]
    pub concepts: Vec<String>,
    #[serde(default)]
    pub requires: Vec<String>,
    #[serde(default)]
    pub map: MapDef,
    pub brief: String,
    pub starter: String,
    pub solution: String,
    #[serde(default)]
    pub hints: Vec<String>,
    pub tests: toml::Value,
    #[serde(default)]
    pub time_limit_s: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MapDef {
    #[serde(default = "half")]
    pub x: f64,
    #[serde(default = "half")]
    pub y: f64,
    #[serde(default = "quest_kind")]
    pub kind: String,
}

fn half() -> f64 {
    0.5
}
fn quest_kind() -> String {
    "quest".to_string()
}

impl Default for MapDef {
    fn default() -> Self {
        MapDef {
            x: 0.5,
            y: 0.5,
            kind: "quest".into(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ImportReport {
    pub packs: Vec<PackReport>,
    /// Files that could not be read or did not validate. A bad pack never
    /// stops the server: the rest of the content still imports, and the
    /// operator gets the path and the reason.
    pub failures: Vec<(String, String)>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PackReport {
    pub path: String,
    pub pack: String,
    pub quests: usize,
    pub inserted: usize,
    pub updated: usize,
}

/// Walk `dir` for `*.toml` and import each one.
///
/// A missing directory is not an error. The content is written by another
/// person in another directory and may not exist yet; the server logs the
/// absolute path it looked at — a silent zero-quest import that looks like a
/// broken map everywhere else is the failure mode worth spending a line on.
pub fn import_dir(conn: &Connection, home: &Home, dir: &Path) -> Result<ImportReport> {
    let mut report = ImportReport::default();
    if !dir.exists() {
        tracing::warn!(path = %dir.display(), "no content directory; importing nothing");
        return Ok(report);
    }
    let mut files = Vec::new();
    collect_toml(dir, &mut files)?;
    files.sort();
    if files.is_empty() {
        tracing::warn!(path = %dir.display(), "content directory holds no .toml packs");
    }
    for file in files {
        match import_file(conn, home, &file) {
            Ok(pack) => {
                tracing::info!(path = %file.display(), pack = %pack.pack, quests = pack.quests, "imported pack");
                report.packs.push(pack);
            }
            Err(e) => {
                tracing::warn!(path = %file.display(), error = %e, "skipping pack");
                report
                    .failures
                    .push((file.display().to_string(), e.to_string()));
            }
        }
    }
    Ok(report)
}

fn collect_toml(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            collect_toml(&path, out)?;
        } else if path.extension().and_then(|e| e.to_str()) == Some("toml") {
            out.push(path);
        }
    }
    Ok(())
}

pub fn import_file(conn: &Connection, home: &Home, path: &Path) -> Result<PackReport> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| internal(format!("cannot read {}: {e}", path.display())))?;
    let pack: Pack = toml::from_str(&text)
        .map_err(|e| bad_request(format!("{} is not a valid pack: {e}", path.display())))?;
    validate(&pack)?;
    let counts = apply(conn, &pack)?;
    // §1: `content/` under the home is "quest packs the server loaded". Keep a
    // copy so the home records what this database was actually built from.
    let name = format!("{}.toml", pack.pack.replace(['/', '\\'], "_"));
    write_private(&home.content_dir().join(name), text.as_bytes())?;
    Ok(PackReport {
        path: path.display().to_string(),
        pack: pack.pack,
        quests: pack.quests.len(),
        inserted: counts.0,
        updated: counts.1,
    })
}

/// SPEC §12's rules, all of them, before a single row is written.
pub fn validate(pack: &Pack) -> Result<()> {
    if !matches!(pack.land.as_str(), "rust" | "go") {
        return Err(bad_request(format!("unknown land '{}'", pack.land)));
    }
    if !matches!(pack.category.as_str(), "basic" | "advanced" | "hacker") {
        return Err(bad_request(format!("unknown category '{}'", pack.category)));
    }
    let mut nodes = BTreeSet::new();
    let mut ids = BTreeSet::new();
    for quest in &pack.quests {
        let (land, category, node, _slug) = parse_quest_id(&quest.id).ok_or_else(|| {
            bad_request(format!(
                "quest id '{}' is not <land>.<category>.<node:02d>.<slug>",
                quest.id
            ))
        })?;
        if land != pack.land || category != pack.category {
            return Err(bad_request(format!(
                "quest id '{}' disagrees with the pack's {}.{}",
                quest.id, pack.land, pack.category
            )));
        }
        if node as i64 != quest.node {
            return Err(bad_request(format!(
                "quest '{}' says node {} but its id says {node}",
                quest.id, quest.node
            )));
        }
        if !ids.insert(quest.id.clone()) {
            return Err(bad_request(format!("duplicate quest id '{}'", quest.id)));
        }
        if !nodes.insert(quest.node) {
            return Err(bad_request(format!("duplicate node {}", quest.node)));
        }
        if !(1..=5).contains(&quest.difficulty) {
            return Err(bad_request(format!(
                "quest '{}' has difficulty {} outside 1..5",
                quest.id, quest.difficulty
            )));
        }
        if !matches!(quest.map.kind.as_str(), "quest" | "boss" | "gate") {
            return Err(bad_request(format!(
                "quest '{}' has map.kind '{}'",
                quest.id, quest.map.kind
            )));
        }
        if quest.solution.trim().is_empty() {
            // §12: a quest without a working reference answer does not get
            // imported. CI runs it; the importer at least insists it exists.
            return Err(bad_request(format!("quest '{}' has no solution", quest.id)));
        }
        let tests = tests_json(quest)?;
        let cases = tests
            .get("cases")
            .and_then(|c| c.as_array())
            .ok_or_else(|| bad_request(format!("quest '{}' has no tests.cases array", quest.id)))?;
        if cases.is_empty() {
            return Err(bad_request(format!(
                "quest '{}' has no test cases",
                quest.id
            )));
        }
        if !cases
            .iter()
            .any(|c| c.get("visible").and_then(|v| v.as_bool()).unwrap_or(false))
        {
            return Err(bad_request(format!(
                "quest '{}' has no visible case; a player would be guessing at the output format",
                quest.id
            )));
        }
    }
    // 1-based and contiguous: the map draws a path through the nodes, and a
    // gap is a path to nowhere.
    for (i, node) in nodes.iter().enumerate() {
        if *node != (i as i64) + 1 {
            return Err(bad_request(format!(
                "nodes must be 1-based and contiguous; found {node} at position {}",
                i + 1
            )));
        }
    }
    Ok(())
}

fn tests_json(quest: &QuestDef) -> Result<serde_json::Value> {
    serde_json::to_value(&quest.tests)
        .map_err(|e| bad_request(format!("quest '{}' has unreadable tests: {e}", quest.id)))
}

/// sha256 over the quest's own source fields — the thing §2.1 calls "the
/// pack's quest source". Serialized deterministically so the same content
/// always produces the same checksum.
pub fn checksum(quest: &QuestDef) -> Result<String> {
    let canonical = serde_json::json!({
        "id": quest.id,
        "node": quest.node,
        "title": quest.title,
        "brief": quest.brief,
        "story": quest.story,
        "difficulty": quest.difficulty,
        "starter": quest.starter,
        "solution": quest.solution,
        "hints": quest.hints,
        "concepts": quest.concepts,
        "requires": quest.requires,
        "tests": tests_json(quest)?,
        "time_limit_s": quest.time_limit_s,
        "map": { "x": quest.map.x, "y": quest.map.y, "kind": quest.map.kind },
    });
    let mut hasher = Sha256::new();
    hasher.update(serde_json::to_vec(&canonical)?);
    Ok(hex::encode(hasher.finalize()))
}

fn apply(conn: &Connection, pack: &Pack) -> Result<(usize, usize)> {
    let before: i64 = conn.query_row(
        "SELECT count(*) FROM quests WHERE pack = ?1",
        params![pack.pack],
        |r| r.get(0),
    )?;
    conn.execute_batch("BEGIN")?;
    let result = (|| -> Result<usize> {
        // UNIQUE(land, category, node): if two quests swap places, upserting
        // them one at a time collides mid-way. Park this pack's nodes on
        // negative numbers first so the real values are free, then put back
        // anything the pack no longer mentions.
        conn.execute(
            "UPDATE quests SET node = -node WHERE pack = ?1 AND node > 0",
            params![pack.pack],
        )?;
        for quest in &pack.quests {
            let sum = checksum(quest)?;
            conn.execute(
                "INSERT INTO quests (id, pack, land, category, node, title, brief, story,
                                     difficulty, time_limit_s, starter, solution, hints,
                                     concepts, tests, checksum, map_x, map_y, map_kind)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19)
                 ON CONFLICT(id) DO UPDATE SET
                   pack=?2, land=?3, category=?4, node=?5, title=?6, brief=?7, story=?8,
                   difficulty=?9, time_limit_s=?10, starter=?11, solution=?12, hints=?13,
                   concepts=?14, tests=?15, checksum=?16, map_x=?17, map_y=?18, map_kind=?19",
                params![
                    quest.id,
                    pack.pack,
                    pack.land,
                    pack.category,
                    quest.node,
                    quest.title,
                    quest.brief,
                    quest.story,
                    quest.difficulty,
                    quest.time_limit_s,
                    quest.starter,
                    quest.solution,
                    serde_json::to_string(&quest.hints)?,
                    serde_json::to_string(&quest.concepts)?,
                    serde_json::to_string(&tests_json(quest)?)?,
                    sum,
                    quest.map.x,
                    quest.map.y,
                    quest.map.kind,
                ],
            )?;
        }
        // Quests dropped from the pack keep their rows (and their progress);
        // they just get their node back. OR IGNORE because the pack may have
        // taken that node over.
        conn.execute(
            "UPDATE OR IGNORE quests SET node = -node WHERE pack = ?1 AND node < 0",
            params![pack.pack],
        )?;
        // Dependency edges are pack-owned and cheap to rebuild. They carry no
        // user state, unlike the quest rows themselves.
        for quest in &pack.quests {
            conn.execute(
                "DELETE FROM quest_deps WHERE quest_id = ?1",
                params![quest.id],
            )?;
            for requires in &quest.requires {
                let known: i64 = conn.query_row(
                    "SELECT count(*) FROM quests WHERE id = ?1",
                    params![requires],
                    |r| r.get(0),
                )?;
                if known == 0 {
                    return Err(bad_request(format!(
                        "quest '{}' requires '{requires}', which no pack supplies",
                        quest.id
                    )));
                }
                conn.execute(
                    "INSERT OR IGNORE INTO quest_deps (quest_id, requires_id) VALUES (?1, ?2)",
                    params![quest.id, requires],
                )?;
            }
        }
        Ok(pack.quests.len())
    })();
    match result {
        Ok(_) => conn.execute_batch("COMMIT")?,
        Err(e) => {
            let _ = conn.execute_batch("ROLLBACK");
            return Err(e);
        }
    }
    let after: i64 = conn.query_row(
        "SELECT count(*) FROM quests WHERE pack = ?1",
        params![pack.pack],
        |r| r.get(0),
    )?;
    let inserted = (after - before).max(0) as usize;
    Ok((inserted, pack.quests.len().saturating_sub(inserted)))
}
