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
    /// Quests the pack no longer has. Their progress goes with them: there is
    /// nothing left for it to be progress *on*.
    pub removed: usize,
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
    reject_basic_strings(&text, path)?;
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
        inserted: counts.inserted,
        updated: counts.updated,
        removed: counts.removed,
    })
}

/// SPEC §12: every field holding code is a TOML **literal** string.
///
/// `"""` is a multi-line *basic* string and processes backslash escapes, so a
/// `'\n'` inside a quest's Rust or Go source is rewritten to a real newline
/// before `rustc` ever sees it. The quest then fails in a way that reads as a
/// compiler bug, which is a day of somebody's life. Caught here, on the raw
/// text, because by the time TOML has parsed it the damage is invisible.
fn reject_basic_strings(text: &str, path: &Path) -> Result<()> {
    const CODE_FIELDS: &[&str] = &["brief", "story", "starter", "solution"];
    for (number, line) in text.lines().enumerate() {
        let trimmed = line.trim_start();
        for field in CODE_FIELDS {
            let Some(rest) = trimmed.strip_prefix(field) else {
                continue;
            };
            let rest = rest.trim_start();
            let Some(rest) = rest.strip_prefix('=') else {
                continue;
            };
            if rest.trim_start().starts_with("\"\"\"") {
                return Err(bad_request(format!(
                    "{}:{}: `{field}` is quoted with a TOML basic string, which eats the \
                     backslash escapes in the code it holds. Use a literal string instead.",
                    path.display(),
                    number + 1
                )));
            }
        }
    }
    Ok(())
}

/// The closed vocabulary of `docs/concepts.md`. A slug outside it reaches no
/// quest, so SPEC §7.3's `weakness` drill would hand the player an empty list.
pub const CONCEPT_VOCABULARY: &[&str] = &[
    // grammar
    "io",
    "bindings",
    "imports",
    "types",
    "control-flow",
    "functions",
    "closures",
    "slices",
    "collections",
    "strings",
    "structs",
    "enums",
    "pattern-matching",
    "error-handling",
    "iteration",
    "traits",
    "interfaces",
    "generics",
    "dispatch",
    "panics",
    "zero-values",
    "testing",
    "serialization",
    // memory and aliasing — rust only
    "ownership",
    "borrowing",
    "lifetimes",
    "mutability",
    "smart-pointers",
    "interior-mutability",
    // concurrency
    "concurrency",
    "channels",
    "shared-state",
    "cancellation",
    "data-races",
    "deadlock",
    "async",
    "thread-safety",
    // algorithms — the `hacker` road
    "hashing",
    "two-pointers",
    "binary-search",
    "sorting",
    "stacks-queues",
    "graphs",
    "intervals",
    "dynamic-programming",
    "complexity",
    "recursion",
    "linked-lists",
    "trees",
    "tries",
    "heaps",
    "backtracking",
    "disjoint-set",
    "bit-manipulation",
    "matrix",
    "math",
    "prefix-sums",
    "greedy",
];

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
        // An empty expectation is satisfied by an empty `fn main() {}`, which
        // clears the node for free. Whitespace-only counts as empty under
        // every match mode but `exact`, and `exact` on nothing is worse still.
        for case in cases {
            let expect = case.get("expect").and_then(|v| v.as_str()).unwrap_or("");
            if expect.trim().is_empty() {
                let name = case.get("name").and_then(|v| v.as_str()).unwrap_or("?");
                return Err(bad_request(format!(
                    "quest '{}' case '{name}' expects nothing; an empty main would clear it",
                    quest.id
                )));
            }
        }
        let hidden = cases
            .iter()
            .filter(|c| !c.get("visible").and_then(|v| v.as_bool()).unwrap_or(false))
            .count();
        // §12's biconditional: `time_limit_s` is the *player's* clock and
        // belongs to the `hacker` road alone. It is not `tests.timeout_ms`,
        // which is one run's wall clock — a quest can give twenty minutes to
        // write something that must execute in five seconds.
        match (pack.category.as_str(), quest.time_limit_s) {
            ("hacker", None) => {
                return Err(bad_request(format!(
                    "quest '{}' is a hacker quest with no time_limit_s",
                    quest.id
                )))
            }
            ("hacker", Some(limit)) if limit <= 0 => {
                return Err(bad_request(format!(
                    "quest '{}' has a time_limit_s of {limit}",
                    quest.id
                )))
            }
            ("hacker", _) if hidden == 0 => {
                return Err(bad_request(format!(
                    "quest '{}' is a hacker quest with no hidden case",
                    quest.id
                )))
            }
            (other, Some(_)) if other != "hacker" => {
                return Err(bad_request(format!(
                    "quest '{}' is a {other} quest and must not carry time_limit_s; \
                     tests.timeout_ms is the per-run clock",
                    quest.id
                )))
            }
            _ => {}
        }
        let unknown: Vec<&String> = quest
            .concepts
            .iter()
            .filter(|c| !CONCEPT_VOCABULARY.contains(&c.as_str()))
            .collect();
        if !unknown.is_empty() {
            // A warning, not a refusal: `docs/concepts.md` can grow a slug
            // before this list does, and refusing to serve a whole pack over a
            // vocabulary lag is worse than one drill that reaches nothing.
            tracing::warn!(
                quest = %quest.id,
                concepts = ?unknown,
                "concept slugs outside docs/concepts.md; weakness drills will not reach this quest"
            );
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

/// Reconcile a pack with the database, in one transaction.
///
/// Three things have to be true at once, and the obvious implementation gets
/// the third wrong:
///
/// 1. **Progress survives an edit.** SPEC §2.2: a quest whose checksum changed
///    keeps its `progress` rows. So this is an upsert by `quests.id`, never a
///    delete-and-reinsert — `progress.quest_id` cascades.
/// 2. **A quest removed from the pack is removed.** Its progress goes with it;
///    there is nothing left for it to be progress *on*, and a row left behind
///    shows up on the map as a node the content no longer has.
/// 3. **Node numbers move without colliding.** `UNIQUE (land, category, node)`
///    is checked per statement, so inserting a new quest at node 5 while the
///    old node 5 still exists fails, and so does any renumbering that passes
///    through an occupied slot.
///
/// The third is what broke: the previous version parked nodes at `-node` and
/// tried to put back whatever the pack no longer mentioned, which left a
/// removed quest stranded on a negative node — and the *next* import then
/// collided with it and failed, every time, for good. Half the packs stopped
/// importing and the server served yesterday's content with a `WARN`.
///
/// So: delete what is gone first (which frees its node), park every survivor
/// somewhere nothing can collide with, then write the real numbers.
fn apply(conn: &Connection, pack: &Pack) -> Result<PackCounts> {
    let ids: Vec<String> = pack.quests.iter().map(|q| q.id.clone()).collect();
    // IMMEDIATE, not deferred: the write lock is taken before the first
    // statement rather than part-way through, so a second writer fails here
    // instead of half-way through a reconciliation. In WAL mode every reader
    // stays on the snapshot it started with until this commits, which is what
    // makes the map a client fetches mid-import either wholly the old one or
    // wholly the new one — never a boss sitting at node -12.
    conn.execute_batch("BEGIN IMMEDIATE")?;
    let result = reconcile(conn, pack, &ids);
    match result {
        Ok(counts) => {
            conn.execute_batch("COMMIT")?;
            Ok(counts)
        }
        Err(e) => {
            let _ = conn.execute_batch("ROLLBACK");
            Err(e)
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
struct PackCounts {
    inserted: usize,
    updated: usize,
    removed: usize,
}

fn reconcile(conn: &Connection, pack: &Pack, ids: &[String]) -> Result<PackCounts> {
    let mut stmt = conn.prepare("SELECT id FROM quests WHERE pack = ?1")?;
    let existing: Vec<String> = stmt
        .query_map(params![pack.pack], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    drop(stmt);
    let mut counts = PackCounts::default();

    // 1. Whatever the pack no longer has. Deleting it first also frees the
    //    node it was sitting on, which is half of why the renumbering below
    //    has room to work.
    for gone in existing.iter().filter(|id| !ids.contains(id)) {
        conn.execute("DELETE FROM quests WHERE id = ?1", params![gone])?;
        counts.removed += 1;
    }

    // 2. Park every surviving row of this pack somewhere no incoming node can
    //    reach. `-1_000_000 - rowid` is unique per row (rowid is), is far
    //    outside the 1-based range content uses, and — unlike the old `-node`
    //    — cannot collide with a row an earlier buggy import left stranded.
    conn.execute(
        "UPDATE quests SET node = -1000000 - rowid WHERE pack = ?1",
        params![pack.pack],
    )?;

    // 3. The real numbers, now that nothing is standing on them.
    for quest in &pack.quests {
        let sum = checksum(quest)?;
        let changed = conn.execute(
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
        );
        match changed {
            Ok(_) => {}
            Err(e) => {
                // The only way this still fails is another pack holding the
                // same land/category/node. Say which quest and why, rather
                // than handing an operator a raw constraint name.
                return Err(bad_request(format!(
                    "quest '{}' cannot take {}.{} node {}: another pack already holds it ({e})",
                    quest.id, pack.land, pack.category, quest.node
                )));
            }
        }
        if existing.contains(&quest.id) {
            counts.updated += 1;
        } else {
            counts.inserted += 1;
        }
    }

    // 4. Nothing may be left parked. If this fires, the reconciliation above
    //    has a hole in it and the right thing is to refuse the import rather
    //    than leave a node the map cannot draw.
    let stranded: i64 = conn.query_row(
        "SELECT count(*) FROM quests WHERE pack = ?1 AND node < 1",
        params![pack.pack],
        |r| r.get(0),
    )?;
    if stranded != 0 {
        return Err(internal(format!(
            "{stranded} quest(s) in '{}' were left without a node",
            pack.pack
        )));
    }

    // The text changed, so the vectors for it are stale. Dropping them is
    // enough: `search::reindex` rebuilds whatever is missing at the next
    // start, and 126 dot products is not worth being clever about.
    for quest in &pack.quests {
        conn.execute(
            "DELETE FROM quest_vec WHERE quest_id = ?1",
            params![quest.id],
        )?;
    }

    // Dependency edges are pack-owned and cheap to rebuild. They carry no user
    // state, unlike the quest rows themselves.
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
    Ok(counts)
}

/// What the database holds for one pack, against what the file says.
///
/// A pack that fails to import leaves the server running on the content it
/// loaded last time, and a `WARN` line is not enough — that is exactly how
/// half the packs went stale without anybody noticing. This is the check that
/// says so out loud, and `cwbhacker doctor` fails on it.
#[derive(Debug, Clone, Serialize)]
pub struct PackAudit {
    pub path: String,
    pub pack: String,
    pub in_file: usize,
    pub in_db: usize,
    /// Quest ids the file has and the database does not.
    pub missing: Vec<String>,
    /// Quest ids the database still holds for this pack and the file no longer
    /// names — a deleted quest that never got cleaned up.
    pub stale: Vec<String>,
    /// The file could not even be read or parsed.
    pub unreadable: Option<String>,
}

impl PackAudit {
    pub fn agrees(&self) -> bool {
        self.unreadable.is_none() && self.missing.is_empty() && self.stale.is_empty()
    }
}

pub fn audit_dir(conn: &Connection, dir: &Path) -> Result<Vec<PackAudit>> {
    let mut out = Vec::new();
    if !dir.exists() {
        return Ok(out);
    }
    let mut files = Vec::new();
    collect_toml(dir, &mut files)?;
    files.sort();
    for path in files {
        out.push(audit_file(conn, &path)?);
    }
    Ok(out)
}

pub fn audit_file(conn: &Connection, path: &Path) -> Result<PackAudit> {
    let unreadable = |reason: String| PackAudit {
        path: path.display().to_string(),
        pack: String::new(),
        in_file: 0,
        in_db: 0,
        missing: Vec::new(),
        stale: Vec::new(),
        unreadable: Some(reason),
    };
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) => return Ok(unreadable(e.to_string())),
    };
    let pack: Pack = match toml::from_str(&text) {
        Ok(pack) => pack,
        Err(e) => return Ok(unreadable(e.to_string())),
    };
    let want: Vec<String> = pack.quests.iter().map(|q| q.id.clone()).collect();
    let mut stmt =
        conn.prepare("SELECT id FROM quests WHERE pack = ?1 OR (land = ?2 AND category = ?3)")?;
    let have: Vec<String> = stmt
        .query_map(params![pack.pack, pack.land, pack.category], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(PackAudit {
        path: path.display().to_string(),
        in_file: want.len(),
        in_db: have.len(),
        missing: want
            .iter()
            .filter(|id| !have.contains(id))
            .cloned()
            .collect(),
        stale: have
            .iter()
            .filter(|id| !want.contains(id))
            .cloned()
            .collect(),
        pack: pack.pack,
        unreadable: None,
    })
}
