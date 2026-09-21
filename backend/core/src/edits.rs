//! The coding page's undo/redo stack (PROTOCOL §4.11c).
//!
//! One stack per `(address, quest_id)`, and it is a stack **with a cursor**,
//! which is the whole trick: a plain push/pop stack can undo but has nowhere
//! to keep what it undid, so it cannot redo. `cursor` is how many entries are
//! applied — the source the editor is showing is `entries[cursor - 1]`, and
//! the quest's own `starter` when the cursor is 0.
//!
//! * **push** truncates everything above the cursor (an edit after an undo
//!   drops the redo tail, the way every editor behaves), appends, and moves
//!   the cursor up. A push of the source that is already current is a no-op,
//!   so a client on an autosave timer cannot fill the stack with copies of one
//!   thought.
//! * **undo** and **redo** move the cursor and write nothing else. That is
//!   what makes them cheap and what makes them reversible.
//! * **clear** drops the history and leaves the editor's text alone: clearing
//!   the history is not an edit.
//!
//! The index is in SQLite and the source is on disk, content-addressed under
//! `edits/<address>/<quest_id>/<sha>.<ext>` — the reasoning for splitting them
//! is in `migrations/0010_edit_stack.sql`, next to the tables.
//!
//! Every function takes the address from the caller's session, never from a
//! payload (SPEC §3.5), and every one of them resolves the quest first, so the
//! only `quest_id` that ever reaches a path is one the content importer wrote
//! and `ids::parse_quest_id` validated.

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::error::{bad_request, internal, Result};
use crate::paths::{ensure_dir, write_private, Home};
use crate::quests;
use crate::time::now_stamp;

/// How deep one quest's history goes. A trainer that grows without bound in
/// the player's home directory is a bug, and a hundred steps is already more
/// than anybody walks back through by hand: past the cap a push drops the
/// oldest entry, which is the one nobody was ever going to reach.
pub const MAX_ENTRIES: usize = 100;

/// The same 256 KiB `quest.submit` and the playground accept. One number for
/// "a source file this server will take" is easier to hold in your head than
/// three, and it lives here rather than in the server crate because the
/// refusal belongs to the model, not to the socket.
pub const MAX_SOURCE_BYTES: usize = 256 * 1024;

/// The whole answer to every one of the five messages (PROTOCOL §5.12). A
/// client never has to model the stack itself: it renders what it is told.
#[derive(Debug, Clone, Serialize)]
pub struct EditState {
    pub quest_id: String,
    /// The text at the cursor. `None` — `null` on the wire — means "the
    /// quest's starter", which is deliberately not spelled out here: the
    /// starter is content the client already has, and repeating it in every
    /// reply would put a copy of it on the wire five times a minute.
    pub source: Option<String>,
    pub cursor: i64,
    pub depth: i64,
    pub can_undo: bool,
    pub can_redo: bool,
}

/// One row of `edit_stack`, with the source left on disk where it lives.
#[derive(Debug, Clone)]
struct Entry {
    sha: String,
    /// The size of the source this entry names. Nothing in this module reads
    /// it — it is carried from the row and written straight back — and it is
    /// here on purpose: `cwbhacker prune` and SPEC §2.3's accounting of what
    /// the cap costs on disk both want to know how big a player's history is
    /// without opening a hundred files to find out.
    bytes: i64,
    created_at: String,
}

/// The stack as it stands: the entries in order, and how many of them are
/// applied. The cursor is clamped on the way out rather than trusted — it is
/// an integer in a table with no CHECK against a count that lives in another
/// one, and a state that says "show entry 7 of 3" would panic an index.
fn load(conn: &Connection, address: &str, quest_id: &str) -> Result<(Vec<Entry>, i64)> {
    let mut stmt = conn.prepare(
        "SELECT sha, bytes, created_at FROM edit_stack
          WHERE address = ?1 AND quest_id = ?2 ORDER BY seq",
    )?;
    let entries = stmt
        .query_map(params![address, quest_id], |r| {
            Ok(Entry {
                sha: r.get(0)?,
                bytes: r.get(1)?,
                created_at: r.get(2)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<Entry>>>()?;
    let cursor: i64 = conn
        .query_row(
            "SELECT cursor FROM edit_cursor WHERE address = ?1 AND quest_id = ?2",
            params![address, quest_id],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or(0);
    let cursor = cursor.clamp(0, entries.len() as i64);
    Ok((entries, cursor))
}

fn sha_of(source: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(source.as_bytes());
    hex::encode(hasher.finalize())
}

/// The land's source extension — `rs`, `go`, `cpp`, `py` — taken off the name
/// the runner compiles that land's file under, so there is one table of
/// extensions in this repo rather than two that can disagree.
fn extension(land: &str) -> &'static str {
    let filename = crate::attempts::source_filename(land);
    match filename.rsplit_once('.') {
        Some((_, ext)) => ext,
        // `source_filename` returns a literal with a dot in it in every arm;
        // this is unreachable, and a panic here would be a panic in a handler.
        None => "txt",
    }
}

fn blob_path(
    home: &Home,
    address: &str,
    quest_id: &str,
    sha: &str,
    ext: &str,
) -> std::path::PathBuf {
    home.edit_dir(address, quest_id)
        .join(format!("{sha}.{ext}"))
}

fn read_blob(home: &Home, address: &str, quest_id: &str, sha: &str, ext: &str) -> Result<String> {
    let path = blob_path(home, address, quest_id, sha, ext);
    std::fs::read_to_string(&path).map_err(|e| {
        // The row is the index and the file is the truth, so a row whose file
        // is gone is a broken home rather than an empty stack. Say which file,
        // because the remedy — clear the stack — is one button away and the
        // player can only press it if they are told what went wrong.
        // The name and not the path: the path is inside the home, and the
        // home's location on this disk is nobody's business over the wire.
        internal(format!(
            "the edit history of {quest_id} names {} and it cannot be read: {e}",
            path.file_name().unwrap_or_default().to_string_lossy()
        ))
    })
}

/// The state to hand back, once the rows are already known.
fn state_of(
    home: &Home,
    address: &str,
    quest_id: &str,
    ext: &str,
    entries: &[Entry],
    cursor: i64,
) -> Result<EditState> {
    let source = match cursor {
        0 => None,
        n => Some(read_blob(
            home,
            address,
            quest_id,
            &entries[n as usize - 1].sha,
            ext,
        )?),
    };
    Ok(EditState {
        quest_id: quest_id.to_string(),
        source,
        cursor,
        depth: entries.len() as i64,
        can_undo: cursor > 0,
        can_redo: cursor < entries.len() as i64,
    })
}

/// Resolve the quest — `not_found` if there is no such id — and hand back the
/// two things every operation here needs from it.
fn quest_of(conn: &Connection, quest_id: &str) -> Result<(&'static str, String)> {
    let quest = quests::get(conn, quest_id)?;
    Ok((extension(&quest.land), quest.starter))
}

/// `edit.state`. A read, and the message a client sends when the quest screen
/// opens.
pub fn state(conn: &Connection, home: &Home, address: &str, quest_id: &str) -> Result<EditState> {
    let address = address.to_ascii_lowercase();
    let (ext, _) = quest_of(conn, quest_id)?;
    let (entries, cursor) = load(conn, &address, quest_id)?;
    state_of(home, &address, quest_id, ext, &entries, cursor)
}

/// `edit.push`. The only message that writes an entry.
pub fn push(
    conn: &Connection,
    home: &Home,
    address: &str,
    quest_id: &str,
    source: &str,
) -> Result<EditState> {
    let address = address.to_ascii_lowercase();
    let (ext, starter) = quest_of(conn, quest_id)?;
    if source.len() > MAX_SOURCE_BYTES {
        return Err(bad_request(format!(
            "source is {} bytes; the limit is {MAX_SOURCE_BYTES}",
            source.len()
        )));
    }
    let (entries, cursor) = load(conn, &address, quest_id)?;

    // "The current source" is the entry under the cursor, or the starter when
    // the cursor is 0 — the same definition the rest of this module uses. It
    // matters at 0: without it, opening a quest and letting the autosave timer
    // fire once would push the untouched starter as entry 1 and leave the
    // player an UNDO button that visibly does nothing.
    let current = match cursor {
        0 => starter,
        n => read_blob(home, &address, quest_id, &entries[n as usize - 1].sha, ext)?,
    };
    if current == source {
        return state_of(home, &address, quest_id, ext, &entries, cursor);
    }

    let sha = sha_of(source);
    // The blob goes down before the row that names it, so a crash between the
    // two leaves an unreferenced file — which costs bytes — rather than a row
    // pointing at nothing, which costs the player their history.
    let dir = home.edit_dir(&address, quest_id);
    ensure_dir(&dir)?;
    write_private(&blob_path(home, &address, quest_id, &sha, ext), source)?;

    // The new stack, worked out in memory first: truncate the redo tail,
    // append, and drop the oldest if that took it over the cap.
    let mut next: Vec<Entry> = entries[..cursor as usize].to_vec();
    next.push(Entry {
        sha: sha.clone(),
        bytes: source.len() as i64,
        created_at: now_stamp(),
    });
    let mut next_cursor = next.len() as i64;
    if next.len() > MAX_ENTRIES {
        next.remove(0);
        // The cursor points at the same entry it did before the trim, which is
        // now one place lower.
        next_cursor -= 1;
    }

    rewrite(conn, &address, quest_id, &next, next_cursor)?;
    // After the commit, never before: a rollback must not take with it bytes
    // that rows still alive are naming.
    unlink_orphans(home, &address, quest_id, ext, &entries, &next);
    state_of(home, &address, quest_id, ext, &next, next_cursor)
}

/// `edit.undo` — one step down, and nothing at the bottom.
pub fn undo(conn: &Connection, home: &Home, address: &str, quest_id: &str) -> Result<EditState> {
    step(conn, home, address, quest_id, -1)
}

/// `edit.redo` — one step up, and nothing past the top.
pub fn redo(conn: &Connection, home: &Home, address: &str, quest_id: &str) -> Result<EditState> {
    step(conn, home, address, quest_id, 1)
}

/// Both moves are the same move. Out of range is **not** an error: a client
/// that holds the button down at the bottom of the stack should be told where
/// it is, not handed a failure it has nothing to do with. `can_undo` and
/// `can_redo` in the reply are how it knows to stop.
fn step(
    conn: &Connection,
    home: &Home,
    address: &str,
    quest_id: &str,
    by: i64,
) -> Result<EditState> {
    let address = address.to_ascii_lowercase();
    let (ext, _) = quest_of(conn, quest_id)?;
    let (entries, cursor) = load(conn, &address, quest_id)?;
    let moved = (cursor + by).clamp(0, entries.len() as i64);
    if moved != cursor {
        set_cursor(conn, &address, quest_id, moved)?;
    }
    state_of(home, &address, quest_id, ext, &entries, moved)
}

/// `edit.clear`. The history goes; the text in the editor stays, because
/// clearing the history is not an edit — the reply says `cursor: 0`, and
/// `source: null` there means "the starter", which the client is free to
/// ignore in favour of what the player is looking at.
pub fn clear(conn: &Connection, home: &Home, address: &str, quest_id: &str) -> Result<EditState> {
    let address = address.to_ascii_lowercase();
    let (ext, _) = quest_of(conn, quest_id)?;
    rewrite(conn, &address, quest_id, &[], 0)?;
    // Every sha is unreferenced now, so the directory goes whole. Ignored on
    // failure for the same reason `snippets::delete` ignores it: the rows are
    // the index, and a file left behind is untidy rather than wrong.
    let _ = std::fs::remove_dir_all(home.edit_dir(&address, quest_id));
    state_of(home, &address, quest_id, ext, &[], 0)
}

/// Every stack on one road, dropped — the edit half of `world.reset`
/// (PROTOCOL §4.7b).
///
/// A road that goes back to untouched has to take the undo history with it.
/// The stack is *state*, not a record: it is what the editor opens on, since
/// §4.11c gives it precedence over the draft, so leaving it behind would mean
/// a reset node that still opens on the code that cleared it — with the stamp
/// gone from the map and the answer still in the buffer, which is the one
/// thing a reset is for. The attempts and the mistakes stay; they are the
/// record, and nothing here touches them.
///
/// Returns how many stacks had anything in them. Quests the player never
/// opened have no rows and cost one query each.
pub fn clear_road(
    conn: &Connection,
    home: &Home,
    address: &str,
    land: &str,
    category: &str,
) -> Result<i64> {
    let address = address.to_ascii_lowercase();
    // The ids come from the quests table rather than from the caller, so the
    // only path this ever builds is one the importer wrote (module docs).
    let ids: Vec<String> = {
        let mut stmt =
            conn.prepare("SELECT id FROM quests WHERE land = ?1 AND category = ?2 ORDER BY node")?;
        let rows = stmt.query_map(params![land, category], |r| r.get::<_, String>(0))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    let mut cleared = 0;
    for id in ids {
        let (entries, _) = load(conn, &address, &id)?;
        if entries.is_empty() {
            continue;
        }
        clear(conn, home, &address, &id)?;
        cleared += 1;
    }
    Ok(cleared)
}

/// Replace one stack's rows wholesale, in one transaction.
///
/// Rewriting all of it rather than patching the difference is the point: `seq`
/// is the 1-based position, it is part of the primary key, and dropping the
/// oldest entry therefore has to renumber every survivor. An in-place
/// `seq = seq - 1` can collide with a row that has not moved yet, so the
/// entries are worked out in memory and written down from scratch. At a cap of
/// a hundred that is a hundred small inserts inside one transaction, which is
/// cheaper than the second code path it replaces is to be sure of.
fn rewrite(
    conn: &Connection,
    address: &str,
    quest_id: &str,
    entries: &[Entry],
    cursor: i64,
) -> Result<()> {
    conn.execute_batch("BEGIN IMMEDIATE")?;
    let applied = (|| -> rusqlite::Result<()> {
        conn.execute(
            "DELETE FROM edit_stack WHERE address = ?1 AND quest_id = ?2",
            params![address, quest_id],
        )?;
        let mut insert = conn.prepare(
            "INSERT INTO edit_stack (address, quest_id, seq, sha, bytes, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        )?;
        for (i, entry) in entries.iter().enumerate() {
            insert.execute(params![
                address,
                quest_id,
                i as i64 + 1,
                entry.sha,
                entry.bytes,
                entry.created_at
            ])?;
        }
        drop(insert);
        if entries.is_empty() {
            conn.execute(
                "DELETE FROM edit_cursor WHERE address = ?1 AND quest_id = ?2",
                params![address, quest_id],
            )?;
        } else {
            conn.execute(
                "INSERT INTO edit_cursor (address, quest_id, cursor) VALUES (?1, ?2, ?3)
                 ON CONFLICT (address, quest_id) DO UPDATE SET cursor = excluded.cursor",
                params![address, quest_id, cursor],
            )?;
        }
        Ok(())
    })();
    match applied {
        Ok(()) => conn.execute_batch("COMMIT")?,
        Err(e) => {
            let _ = conn.execute_batch("ROLLBACK");
            return Err(e.into());
        }
    }
    Ok(())
}

fn set_cursor(conn: &Connection, address: &str, quest_id: &str, cursor: i64) -> Result<()> {
    conn.execute(
        "INSERT INTO edit_cursor (address, quest_id, cursor) VALUES (?1, ?2, ?3)
         ON CONFLICT (address, quest_id) DO UPDATE SET cursor = excluded.cursor",
        params![address, quest_id, cursor],
    )?;
    Ok(())
}

/// Unlink the blobs the rewrite orphaned. Content addressing means a sha that
/// still appears anywhere in the new stack is still in use — an undo/redo
/// cycle back to text the player wrote an hour ago names the file that is
/// already there — so only the shas that have left entirely are removed.
///
/// A cascade from a content reimport that drops a quest is the one case this
/// does not cover: the rows go with the quest and nothing calls in here, so
/// the tree under `edits/<address>/<quest_id>/` is left behind. That is a job
/// for `cwbhacker prune`, which is where sweeping the home already lives.
fn unlink_orphans(
    home: &Home,
    address: &str,
    quest_id: &str,
    ext: &str,
    before: &[Entry],
    after: &[Entry],
) {
    for entry in before {
        if after.iter().any(|e| e.sha == entry.sha) {
            continue;
        }
        let path = blob_path(home, address, quest_id, &entry.sha, ext);
        if let Err(e) = std::fs::remove_file(&path) {
            if e.kind() != std::io::ErrorKind::NotFound {
                tracing::warn!(path = %path.display(), error = %e, "could not unlink an edit");
            }
        }
    }
}
