//! The attempt record (SPEC §2.1) and its copy on disk (§1).
//!
//! Attempts are never deleted by the server — they are the training data §7
//! reads. `cwbhacker prune` is the only thing that removes them.

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::paths::{ensure_dir, write_private, Home};
use crate::time::now_stamp;

/// SPEC §2.2: `attempts.stderr` is truncated at 64 KiB with a trailing
/// `…truncated N bytes` line; the untruncated copy is on disk.
pub const STDERR_CAP: usize = 64 * 1024;

pub fn truncate_stderr(stderr: &str) -> String {
    if stderr.len() <= STDERR_CAP {
        return stderr.to_string();
    }
    // Land on a char boundary: the ellipsis in the suffix is multi-byte and
    // so, very often, is the compiler's own output.
    let mut cut = STDERR_CAP;
    while cut > 0 && !stderr.is_char_boundary(cut) {
        cut -= 1;
    }
    let dropped = stderr.len() - cut;
    format!("{}\n…truncated {dropped} bytes", &stderr[..cut])
}

/// RUN or SUBMIT (PROTOCOL §4.9b). A run is an attempt too — it compiles, it
/// runs, it fails in the same ways — but it is not part of the *record*: only
/// a submit moves progress, counts toward a node's attempts, or enters
/// accuracy. Both feed the mistake tables.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Run,
    Submit,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Run => "run",
            Mode::Submit => "submit",
        }
    }

    pub fn is_submit(self) -> bool {
        self == Mode::Submit
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct AttemptRecord {
    pub id: String,
    pub address: String,
    pub quest_id: String,
    pub lang: String,
    pub mode: Mode,
    pub source: String,
    pub verdict: String,
    pub compile_ms: i64,
    pub run_ms: i64,
    pub exit_code: Option<i64>,
    pub stdout_bytes: i64,
    pub stderr: String,
    pub tests_passed: i64,
    pub tests_total: i64,
    /// PROTOCOL §4.8b. `None` on an untimed quest, and on every attempt made
    /// before the clock existed.
    pub within_limit: Option<bool>,
    pub created_at: String,
}

pub fn insert(conn: &Connection, record: &AttemptRecord) -> Result<()> {
    conn.execute(
        "INSERT INTO attempts (id, address, quest_id, lang, mode, source, verdict, compile_ms,
                               run_ms, exit_code, stdout_bytes, stderr, tests_passed,
                               tests_total, created_at, within_limit)
         VALUES (?1,?2,?3,?4,?15,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?16)",
        params![
            record.id,
            record.address,
            record.quest_id,
            record.lang,
            record.source,
            record.verdict,
            record.compile_ms,
            record.run_ms,
            record.exit_code,
            record.stdout_bytes,
            truncate_stderr(&record.stderr),
            record.tests_passed,
            record.tests_total,
            record.created_at,
            record.mode.as_str(),
            record.within_limit,
        ],
    )?;
    Ok(())
}

/// The name the source is saved under, per land — the one the runner compiles
/// it as, so a file opened from the home is the file that was judged.
pub fn source_filename(lang: &str) -> &'static str {
    match lang {
        "go" => "main.go",
        "cpp" => "main.cpp",
        // PYTORCH is the Python interpreter with torch in its site-packages,
        // so its programs are `main.py` too (SPEC §5.1).
        "python" | "pytorch" => "main.py",
        "typescript" => "main.ts",
        _ => "main.rs",
    }
}

/// `users/<address>/attempts/<attempt_id>/` — the source as the player typed
/// it, the two streams whole, and the verdict as JSON.
pub fn write_to_disk(
    home: &Home,
    record: &AttemptRecord,
    stdout: &str,
    stderr: &str,
    result: &serde_json::Value,
) -> Result<()> {
    let dir = home.attempt_dir(&record.address, &record.id);
    ensure_dir(&dir)?;
    let filename = source_filename(&record.lang);
    write_private(&dir.join(filename), record.source.as_bytes())?;
    write_private(&dir.join("stdout.txt"), stdout.as_bytes())?;
    write_private(&dir.join("stderr.txt"), stderr.as_bytes())?;
    write_private(&dir.join("result.json"), serde_json::to_vec_pretty(result)?)?;
    Ok(())
}

/// PROTOCOL §4.8's `draft`: the source of the player's most recent attempt
/// (run or submit, either counts) at this quest — so opening a quest you have
/// worked on before restores where you left off instead of the bare starter.
/// Not a separate save path: every run and submit already write this row
/// (§2.2), so this is a read of data that already exists, not a new one.
///
/// `since` is the road's `progress.reset_at` (0019), and it is what makes
/// RESET on the map mean what it says. A reset road goes back to untouched,
/// and a node whose editor opens on the solution the player wrote before the
/// reset is not untouched — it is the answer, handed back. The attempts
/// themselves stay where they are, because they are SPEC §7's training data
/// and the server never deletes them; what changes is only which of them this
/// screen is allowed to call "where you left off". `None` means the road has
/// never been reset, and then every attempt counts, as it always did.
pub fn latest_source(
    conn: &Connection,
    address: &str,
    quest_id: &str,
    since: Option<&str>,
) -> Result<Option<String>> {
    conn.query_row(
        "SELECT source FROM attempts WHERE address = ?1 AND quest_id = ?2
            AND (?3 IS NULL OR created_at > ?3)
          ORDER BY created_at DESC, rowid DESC LIMIT 1",
        params![address, quest_id, since],
        |row| row.get(0),
    )
    .optional()
    .map_err(Into::into)
}

/// PROTOCOL §5.7. `kinds` is what makes a history list readable at a glance:
/// the verdict says it failed, the kinds say how.
#[derive(Debug, Clone, Serialize)]
pub struct AttemptBrief {
    pub id: String,
    pub quest_id: String,
    pub mode: String,
    pub verdict: String,
    pub tests_passed: i64,
    pub tests_total: i64,
    pub created_at: String,
    pub kinds: Vec<String>,
}

/// `stats.history`. Always scoped to one address — the caller passes the
/// session's, never a payload's (SPEC §3.5).
pub fn history(
    conn: &Connection,
    address: &str,
    quest_id: Option<&str>,
    limit: i64,
) -> Result<Vec<AttemptBrief>> {
    let limit = limit.clamp(1, 500);
    let mut out = Vec::new();
    let map = |r: &rusqlite::Row<'_>| {
        Ok(AttemptBrief {
            id: r.get(0)?,
            quest_id: r.get(1)?,
            verdict: r.get(2)?,
            tests_passed: r.get(3)?,
            tests_total: r.get(4)?,
            created_at: r.get(5)?,
            mode: r.get(6)?,
            kinds: Vec::new(),
        })
    };
    // Both modes. A player looking at their own history wants to see the
    // iteration, not a tidied-up list of the times they pressed SUBMIT.
    const COLS: &str = "id, quest_id, verdict, tests_passed, tests_total, created_at, mode";
    match quest_id {
        Some(quest_id) => {
            let mut stmt = conn.prepare(&format!(
                "SELECT {COLS} FROM attempts WHERE address = ?1 AND quest_id = ?2
                  ORDER BY created_at DESC, rowid DESC LIMIT ?3"
            ))?;
            for row in stmt.query_map(params![address, quest_id, limit], map)? {
                out.push(row?);
            }
        }
        None => {
            let mut stmt = conn.prepare(&format!(
                "SELECT {COLS} FROM attempts WHERE address = ?1
                  ORDER BY created_at DESC, rowid DESC LIMIT ?2"
            ))?;
            for row in stmt.query_map(params![address, limit], map)? {
                out.push(row?);
            }
        }
    }
    // One small query per row. At a history limit of fifty this is cheaper
    // than the join it replaces is to read.
    for brief in &mut out {
        let mut stmt =
            conn.prepare("SELECT DISTINCT kind FROM mistakes WHERE attempt_id = ?1 ORDER BY kind")?;
        brief.kinds = stmt
            .query_map(params![brief.id], |r| r.get(0))?
            .collect::<rusqlite::Result<Vec<String>>>()?;
    }
    Ok(out)
}

pub fn new_record(
    id: String,
    address: &str,
    quest_id: &str,
    lang: &str,
    mode: Mode,
    source: String,
) -> AttemptRecord {
    AttemptRecord {
        id,
        address: address.to_ascii_lowercase(),
        quest_id: quest_id.to_string(),
        lang: lang.to_string(),
        mode,
        source,
        verdict: "internal_error".into(),
        compile_ms: 0,
        run_ms: 0,
        exit_code: None,
        stdout_bytes: 0,
        stderr: String::new(),
        tests_passed: 0,
        tests_total: 0,
        within_limit: None,
        created_at: now_stamp(),
    }
}
