//! The playground's scratchpads (PROTOCOL §4.9c, §5.9).
//!
//! Server-side and per user, so the same scratchpad opens in the browser and
//! in the LÖVE client. Every function here takes the address from the
//! connection's session — a snippet id is a random 16 hex, but guessing one
//! must not be enough to read somebody's notes, so every query is scoped by
//! owner as well as by id (SPEC §3.5).

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::error::{bad_request, not_found, Result};
use crate::ids;
use crate::paths::{ensure_dir, write_private, Home};
use crate::time::now_stamp;

/// An autosave timer plus an unbounded table is a disk-filling bug waiting for
/// a stuck client, so both dimensions are capped and both refusals say what
/// the limit is. The numbers are in `docs/decisions.md` with the reasoning.
pub const MAX_SNIPPETS_PER_USER: i64 = 64;
/// The same 256 KiB `quest.submit` accepts. One number for "a source file this
/// server will take" is easier to hold in your head than two.
pub const MAX_SNIPPET_BYTES: usize = 256 * 1024;
/// A pad's saved input, and the input a playground run feeds its program.
/// One number for both, for the same reason as the source cap: the input a
/// player types into a scratchpad is a few lines, and 64 KiB is well past
/// anything a hand produces while still being nothing to a disk.
pub const MAX_STDIN_BYTES: usize = 64 * 1024;
pub const MAX_NAME_CHARS: usize = 80;

#[derive(Debug, Clone, Serialize)]
pub struct Snippet {
    pub id: String,
    pub name: String,
    pub lang: String,
    pub source: String,
    /// What the program reads when it runs. A scratchpad has no test cases,
    /// so this is the only input it will ever get, and it belongs to the pad
    /// rather than to whichever client happened to be open.
    pub stdin: String,
    pub created_at: String,
    pub updated_at: String,
}

/// The listing shape: everything but the source, plus its size (PROTOCOL
/// §5.9). A scratchpad list should not carry a megabyte of code nobody asked
/// for yet.
#[derive(Debug, Clone, Serialize)]
pub struct SnippetBrief {
    pub id: String,
    pub name: String,
    pub lang: String,
    pub bytes: i64,
    pub created_at: String,
    pub updated_at: String,
}

fn check_lang(lang: &str) -> Result<()> {
    match lang {
        "rust" | "go" | "cpp" | "python" => Ok(()),
        other => Err(bad_request(format!("unknown language '{other}'"))),
    }
}

fn clean_name(name: Option<&str>) -> Option<String> {
    let name = name?.trim();
    if name.is_empty() {
        return None;
    }
    Some(name.chars().take(MAX_NAME_CHARS).collect())
}

pub fn get(conn: &Connection, address: &str, id: &str) -> Result<Snippet> {
    conn.query_row(
        "SELECT id, name, lang, source, stdin, created_at, updated_at
           FROM snippets WHERE id = ?1 AND address = ?2",
        params![id, address],
        |r| {
            Ok(Snippet {
                id: r.get(0)?,
                name: r.get(1)?,
                lang: r.get(2)?,
                source: r.get(3)?,
                stdin: r.get(4)?,
                created_at: r.get(5)?,
                updated_at: r.get(6)?,
            })
        },
    )
    .optional()?
    // Somebody else's snippet is not found, not forbidden: whether an id
    // exists is itself none of this user's business.
    .ok_or_else(|| not_found("no such snippet"))
}

pub fn list(conn: &Connection, address: &str) -> Result<Vec<SnippetBrief>> {
    let mut stmt = conn.prepare(
        "SELECT id, name, lang, length(source), created_at, updated_at
           FROM snippets WHERE address = ?1 ORDER BY updated_at DESC, id DESC",
    )?;
    let rows = stmt.query_map(params![address], |r| {
        Ok(SnippetBrief {
            id: r.get(0)?,
            name: r.get(1)?,
            lang: r.get(2)?,
            bytes: r.get(3)?,
            created_at: r.get(4)?,
            updated_at: r.get(5)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// Create or update. `id` omitted creates; `name` omitted on create is
/// assigned from the date (PROTOCOL §4.9c).
///
/// **Idempotent on purpose.** This is what a client calls on an autosave
/// timer, so saving byte-identical content returns the row untouched — the
/// same `updated_at` — rather than writing a new timestamp every few seconds
/// and making a list sorted by it jump around while nobody is typing.
///
/// Eight arguments, which is one past what clippy will sit still for. Three
/// are the context every call in this module takes and five are the pad
/// itself; grouping the five into a struct for the one call site there is
/// would move the same fields behind a name that says nothing the parameter
/// list does not already say.
#[allow(clippy::too_many_arguments)]
pub fn save(
    conn: &Connection,
    home: &Home,
    address: &str,
    id: Option<&str>,
    name: Option<&str>,
    lang: &str,
    source: &str,
    stdin: Option<&str>,
) -> Result<Snippet> {
    check_lang(lang)?;
    if source.len() > MAX_SNIPPET_BYTES {
        return Err(bad_request(format!(
            "a snippet is at most {MAX_SNIPPET_BYTES} bytes; this one is {}",
            source.len()
        )));
    }
    if let Some(stdin) = stdin {
        if stdin.len() > MAX_STDIN_BYTES {
            return Err(bad_request(format!(
                "a snippet's stdin is at most {MAX_STDIN_BYTES} bytes; this one is {}",
                stdin.len()
            )));
        }
    }
    let now = now_stamp();
    let name = clean_name(name);

    let snippet = match id {
        Some(id) => {
            let existing = get(conn, address, id)?;
            if existing.source == source
                && existing.lang == lang
                && name.as_ref().is_none_or(|n| *n == existing.name)
                && stdin.is_none_or(|v| v == existing.stdin)
            {
                // Nothing changed. An autosave that finds the file unchanged
                // should cost one SELECT and no write at all.
                return Ok(existing);
            }
            conn.execute(
                "UPDATE snippets SET name = ?3, lang = ?4, source = ?5, stdin = ?6,
                        updated_at = ?7
                  WHERE id = ?1 AND address = ?2",
                params![
                    id,
                    address,
                    name.unwrap_or(existing.name),
                    lang,
                    source,
                    // Absent means "not mentioned", which is what an older
                    // client sends: keep what the pad already had rather than
                    // emptying it on somebody's behalf.
                    stdin.unwrap_or(&existing.stdin),
                    now
                ],
            )?;
            get(conn, address, id)?
        }
        None => {
            let count: i64 = conn.query_row(
                "SELECT count(*) FROM snippets WHERE address = ?1",
                params![address],
                |r| r.get(0),
            )?;
            if count >= MAX_SNIPPETS_PER_USER {
                return Err(bad_request(format!(
                    "you have {count} snippets and the limit is {MAX_SNIPPETS_PER_USER}; \
                     delete one first"
                )));
            }
            let id = ids::snippet_id();
            let name = name.unwrap_or_else(|| format!("scratch {}", &now[..10]));
            conn.execute(
                "INSERT INTO snippets
                     (id, address, name, lang, source, stdin, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)",
                params![id, address, name, lang, source, stdin.unwrap_or(""), now],
            )?;
            get(conn, address, &id)?
        }
    };
    write_to_disk(home, address, &snippet)?;
    Ok(snippet)
}

pub fn delete(conn: &Connection, home: &Home, address: &str, id: &str) -> Result<()> {
    // Read it first so a delete of somebody else's id is `not_found` rather
    // than a silent no-op that looks like success.
    let _ = get(conn, address, id)?;
    conn.execute(
        "DELETE FROM snippets WHERE id = ?1 AND address = ?2",
        params![id, address],
    )?;
    let _ = std::fs::remove_dir_all(home.snippet_dir(address, id));
    Ok(())
}

/// SPEC §1: the player's own work lives in the home as well as in the
/// database, for the same reason attempts do — a database is a worse place to
/// lose something from, and a scratchpad is worth being able to open with an
/// editor.
fn write_to_disk(home: &Home, address: &str, snippet: &Snippet) -> Result<()> {
    let dir = home.snippet_dir(address, &snippet.id);
    ensure_dir(&dir)?;
    let filename = crate::attempts::source_filename(&snippet.lang);
    write_private(&dir.join(filename), snippet.source.as_bytes())?;
    write_private(
        &dir.join("snippet.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "id": snippet.id,
            "name": snippet.name,
            "lang": snippet.lang,
            "created_at": snippet.created_at,
            "updated_at": snippet.updated_at,
        }))?,
    )
}
