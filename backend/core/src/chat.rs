//! The chatroom under a playground snippet (PROTOCOL §4.9f, §5.14;
//! docs/agent.md §6).
//!
//! The AI agent is called from the browser and the server never sees a key;
//! what the server keeps is the transcript. One room per snippet, per user:
//! every row here is scoped by the session's address exactly as the snippet
//! is, so another player's id answers `not_found` and nothing else (SPEC
//! §3.5). The database holds the messages for listing and search; the
//! snippet's folder holds the same messages as `chat.jsonl` and the photos
//! as files, because the home is human-shaped on purpose (SPEC §1).
//!
//! Photos are **fetched, not pushed**. The websocket carries a 4 MiB frame and
//! a picture can be most of that, so a row keeps a file name and a 32-hex
//! capability token, and `GET /photos/{id}/{token}.{ext}` serves the bytes to
//! whoever holds the token. There is no other HTTP auth in this server; an
//! unguessable URL handed only to the owner over the socket is the honest fit.

use std::collections::HashMap;
use std::path::PathBuf;

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::error::{bad_request, not_found, Result};
use crate::ids;
use crate::paths::{ensure_dir, set_private, write_private, Home};
use crate::search::{self, Embedder, Mode};
use crate::snippets;
use crate::time::now_stamp;

/// A room is a conversation about one pad, not an archive: past this the
/// client is told to CLEAR, and the refusal names the number.
pub const MAX_MESSAGES_PER_SNIPPET: i64 = 500;
/// Decoded bytes. Under the 4 MiB websocket frame with room for the base64
/// overhead and the envelope around it.
pub const MAX_PHOTO_BYTES: usize = 3 * 1024 * 1024;
/// A message is prose, or a model's reply with a program in it; a quarter of
/// a snippet's own cap is room for either and a wall against a stuck client.
pub const MAX_TEXT_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Serialize)]
pub struct Message {
    /// The identity: an int64 SQLite hands out and never reuses. It names the
    /// row, the photo file and the photo URL.
    pub id: i64,
    /// The sync cursor (PROTOCOL §4.9f): milliseconds since the epoch at post
    /// time, or one past the last `timeid` handed out when the clock has not
    /// moved on. Strictly increasing across every room this server has, so
    /// "everything after N" is one query whatever room it is in. Never 0.
    pub timeid: i64,
    pub snippet_id: String,
    pub role: String,
    pub kind: String,
    pub text: String,
    /// `/photos/<message_id>/<token>.<ext>` on image rows, `null` otherwise.
    /// The token is in the URL rather than beside it so the client has one
    /// string to put in an `<img>` and nothing to assemble.
    pub photo_url: Option<String>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub created_at: String,
    /// The text was changed after it was said; `timeid` moved with it.
    pub edited: bool,
    /// A tombstone: the text is gone, the photo is gone, `timeid` moved so a
    /// client past the original hears about it. Hidden from a room read from
    /// the start; delivered to a cursor.
    pub deleted: bool,
}

/// One search result (PROTOCOL §5.14): the message, the pad it was said in,
/// and the same three scores `SearchHit` carries so a screen can show *why*.
#[derive(Debug, Clone, Serialize)]
pub struct Hit {
    pub message: Message,
    pub snippet_name: String,
    pub score: f64,
    pub bm25: Option<f64>,
    pub cosine: Option<f64>,
    pub snippet: String,
}

/// The image types a browser will show inline and a model will produce.
/// The extension is what the file is named and what the URL ends in.
fn extension_for(mime: &str) -> Result<&'static str> {
    match mime {
        "image/png" => Ok("png"),
        "image/jpeg" => Ok("jpg"),
        "image/webp" => Ok("webp"),
        other => Err(bad_request(format!(
            "image_type '{other}' is not one of image/png, image/jpeg, image/webp"
        ))),
    }
}

fn mime_for(extension: &str) -> Option<&'static str> {
    match extension {
        "png" => Some("image/png"),
        "jpg" => Some("image/jpeg"),
        "webp" => Some("image/webp"),
        _ => None,
    }
}

fn check_role(role: &str) -> Result<()> {
    match role {
        "user" | "agent" | "tool" => Ok(()),
        other => Err(bad_request(format!(
            "role '{other}' is not one of user, agent, tool"
        ))),
    }
}

const COLUMNS: &str =
    "id, snippet_id, role, kind, text, photo, photo_token, provider, model, created_at, timeid, edited, deleted";

fn read_message(r: &rusqlite::Row<'_>) -> rusqlite::Result<Message> {
    let id: i64 = r.get(0)?;
    let photo: Option<String> = r.get(5)?;
    let token: Option<String> = r.get(6)?;
    let photo_url = match (photo, token) {
        (Some(photo), Some(token)) => {
            let ext = photo.rsplit_once('.').map(|(_, e)| e).unwrap_or("");
            Some(format!("/photos/{id}/{token}.{ext}"))
        }
        _ => None,
    };
    Ok(Message {
        id,
        snippet_id: r.get(1)?,
        role: r.get(2)?,
        kind: r.get(3)?,
        text: r.get(4)?,
        photo_url,
        provider: r.get(7)?,
        model: r.get(8)?,
        created_at: r.get(9)?,
        timeid: r.get(10)?,
        edited: r.get::<_, i64>(11)? != 0,
        deleted: r.get::<_, i64>(12)? != 0,
    })
}

/// The largest `timeid` a JavaScript client can hold exactly (2^53 - 1). An
/// int64 goes further, but a browser reading past this would round, and a
/// rounded cursor skips messages. PocketSkynet draws the same line.
pub const MAX_SAFE_TIMEID: i64 = 9_007_199_254_740_991;

/// The next `timeid`: `max(last handed out, now in ms) + 1`, read and bumped
/// in one statement on the one connection this server writes through
/// (`store.rs`), so two posts cannot draw the same number, a clock that
/// stepped back cannot hand out an old one, and a cleared room — whose rows
/// are gone — cannot let the next post land under what a client already saw.
fn next_timeid(conn: &Connection) -> Result<i64> {
    let now = crate::time::now().timestamp_millis();
    let timeid: i64 = conn.query_row(
        "INSERT INTO chat_clock (one, last_timeid) VALUES (1, max(?1, 0) + 1)
         ON CONFLICT (one) DO UPDATE SET last_timeid = max(chat_clock.last_timeid, ?1) + 1
         RETURNING last_timeid",
        params![now],
        |r| r.get(0),
    )?;
    if timeid > MAX_SAFE_TIMEID {
        return Err(bad_request(
            "the chat clock has run past what a client can count",
        ));
    }
    Ok(timeid)
}

fn get(conn: &Connection, address: &str, id: i64) -> Result<Option<Message>> {
    Ok(conn
        .query_row(
            &format!("SELECT {COLUMNS} FROM snippet_messages WHERE id = ?1 AND address = ?2"),
            params![id, address],
            read_message,
        )
        .optional()?)
}

/// The room, oldest first, so a client appends as it reads. `limit` keeps
/// the **newest** that many — a room past the limit shows its recent end,
/// not its first day — and they still come back in the order they were
/// said. `after` is the sync cursor: only messages with a `timeid` past it,
/// which is how a client that already holds the room asks for the rest.
/// A read from the start (`after == 0`) leaves the tombstones out — nobody
/// holds a copy to retire — while a cursor gets them, because somebody does.
pub fn list(
    conn: &Connection,
    address: &str,
    snippet_id: &str,
    limit: usize,
    after: i64,
) -> Result<Vec<Message>> {
    // Somebody else's snippet is `not_found`, before a single row is read.
    let _ = snippets::get(conn, address, snippet_id)?;
    let mut stmt = conn.prepare(&format!(
        "SELECT {COLUMNS} FROM (
            SELECT {COLUMNS} FROM snippet_messages
             WHERE snippet_id = ?1 AND address = ?2 AND timeid > ?4
               AND (?4 > 0 OR deleted = 0)
             ORDER BY timeid DESC
             LIMIT ?3)
          ORDER BY timeid ASC"
    ))?;
    let rows = stmt.query_map(
        params![snippet_id, address, limit as i64, after],
        read_message,
    )?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// Every message of this player past `after`, whichever room it is in, in
/// `timeid` order and at most `limit` of them — the other half of sync, for a
/// client keeping every room. The oldest first this time: a client walks
/// forward from its cursor and takes the last `timeid` it saw as the next one.
pub fn since(conn: &Connection, address: &str, after: i64, limit: usize) -> Result<Vec<Message>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {COLUMNS} FROM snippet_messages
          WHERE address = ?1 AND timeid > ?2
          ORDER BY timeid ASC
          LIMIT ?3"
    ))?;
    let rows = stmt.query_map(params![address, after, limit as i64], read_message)?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// The newest `timeid` this player has, or 0: where a fresh client's cursor
/// starts if it only wants what comes next.
pub fn head(conn: &Connection, address: &str) -> Result<i64> {
    Ok(conn.query_row(
        "SELECT coalesce(max(timeid), 0) FROM snippet_messages WHERE address = ?1",
        params![address],
        |r| r.get(0),
    )?)
}

/// Post one message. `image` is `(bytes, mime)`; when it is present the row
/// is `kind = 'image'` and `text` is the prompt that made it.
///
/// Nine arguments, for the same reason `snippets::save` has eight: four are
/// the context every call here takes and five are the message, and a struct
/// for one call site would name nothing the list does not.
#[allow(clippy::too_many_arguments)]
pub fn post(
    conn: &Connection,
    home: &Home,
    embedder: &dyn Embedder,
    address: &str,
    snippet_id: &str,
    role: &str,
    text: &str,
    image: Option<(&[u8], &str)>,
    provider: Option<&str>,
    model: Option<&str>,
) -> Result<Message> {
    let _ = snippets::get(conn, address, snippet_id)?;
    check_role(role)?;
    if text.len() > MAX_TEXT_BYTES {
        return Err(bad_request(format!(
            "a message is at most {MAX_TEXT_BYTES} bytes; this one is {}",
            text.len()
        )));
    }
    let photo = match image {
        Some((bytes, mime)) => {
            let ext = extension_for(mime)?;
            if bytes.is_empty() {
                return Err(bad_request("the image is empty"));
            }
            if bytes.len() > MAX_PHOTO_BYTES {
                return Err(bad_request(format!(
                    "a photo is at most {MAX_PHOTO_BYTES} bytes; this one is {}",
                    bytes.len()
                )));
            }
            Some((bytes, ext))
        }
        None => {
            if text.trim().is_empty() {
                return Err(bad_request("a message needs text or an image"));
            }
            None
        }
    };
    let count: i64 = conn.query_row(
        "SELECT count(*) FROM snippet_messages WHERE snippet_id = ?1",
        params![snippet_id],
        |r| r.get(0),
    )?;
    if count >= MAX_MESSAGES_PER_SNIPPET {
        return Err(bad_request(format!(
            "this room has {count} messages and the limit is {MAX_MESSAGES_PER_SNIPPET}; \
             clear it first"
        )));
    }

    let timeid = next_timeid(conn)?;
    let now = now_stamp();
    let kind = if photo.is_some() { "image" } else { "text" };
    let token = photo.map(|_| ids::photo_token());
    conn.execute(
        "INSERT INTO snippet_messages
             (timeid, snippet_id, address, role, kind, text, photo_token,
              provider, model, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![timeid, snippet_id, address, role, kind, text, token, provider, model, now],
    )?;
    // The id is SQLite's to give; the photo's file name is built from it
    // once it is known, and the row told where its picture went.
    let id = conn.last_insert_rowid();
    let file = photo.map(|(_, ext)| format!("{id}.{ext}"));
    if let Some(file) = &file {
        conn.execute(
            "UPDATE snippet_messages SET photo = ?2 WHERE id = ?1",
            params![id, file],
        )?;
    }
    // The index the agent's `search_notes` reads. An image's prompt is text
    // worth finding too; an empty text has nothing to embed.
    if !text.trim().is_empty() {
        conn.execute(
            "INSERT INTO snippet_message_vec (message_id, dim, model, vec)
             VALUES (?1, ?2, ?3, ?4)",
            params![
                id,
                embedder.dim() as i64,
                embedder.id(),
                search::to_blob(&embedder.embed(text))
            ],
        )?;
    }
    let message = get(conn, address, id)?.ok_or_else(|| not_found("no such message"))?;

    // The folder mirror (SPEC §1): the bytes as posted, and one line in the
    // transcript. After the row, so a disk that refuses leaves nothing half
    // said in the database that the folder does not also have.
    if let (Some((bytes, _)), Some(file)) = (photo, &file) {
        write_private(
            &home.snippet_photo_dir(address, snippet_id).join(file),
            bytes,
        )?;
    }
    append_line(
        &home.snippet_dir(address, snippet_id).join("chat.jsonl"),
        &serde_json::to_string(&message)?,
    )?;
    Ok(message)
}

/// Every message and photo of one room. Returns how many rows went; the vec
/// rows and the FTS entries follow through the cascade and the triggers.
pub fn clear(conn: &Connection, home: &Home, address: &str, snippet_id: &str) -> Result<usize> {
    let _ = snippets::get(conn, address, snippet_id)?;
    let cleared = conn.execute(
        "DELETE FROM snippet_messages WHERE snippet_id = ?1 AND address = ?2",
        params![snippet_id, address],
    )?;
    let _ = std::fs::remove_dir_all(home.snippet_photo_dir(address, snippet_id));
    let _ = std::fs::remove_file(home.snippet_dir(address, snippet_id).join("chat.jsonl"));
    Ok(cleared)
}

/// Change what a message says. The row keeps its id, takes a new `timeid`
/// so every cursor past the original receives the change, and says it was
/// edited. Only text rows, only the owner's, never a tombstone.
pub fn edit(
    conn: &Connection,
    home: &Home,
    embedder: &dyn Embedder,
    address: &str,
    message_id: i64,
    text: &str,
) -> Result<Message> {
    let held = get(conn, address, message_id)?.ok_or_else(|| not_found("no such message"))?;
    if held.deleted {
        return Err(bad_request("that message was deleted"));
    }
    if held.kind != "text" {
        return Err(bad_request(
            "a photo's prompt is not edited; delete it and post again",
        ));
    }
    if text.trim().is_empty() {
        return Err(bad_request(
            "an edit needs text; delete the message instead",
        ));
    }
    if text.len() > MAX_TEXT_BYTES {
        return Err(bad_request(format!(
            "a message is at most {MAX_TEXT_BYTES} bytes; this one is {}",
            text.len()
        )));
    }
    let timeid = next_timeid(conn)?;
    conn.execute(
        "UPDATE snippet_messages SET text = ?2, edited = 1, timeid = ?3 WHERE id = ?1",
        params![message_id, text, timeid],
    )?;
    conn.execute(
        "INSERT INTO snippet_message_vec (message_id, dim, model, vec) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(message_id) DO UPDATE SET dim = ?2, model = ?3, vec = ?4",
        params![
            message_id,
            embedder.dim() as i64,
            embedder.id(),
            search::to_blob(&embedder.embed(text))
        ],
    )?;
    let message = get(conn, address, message_id)?.ok_or_else(|| not_found("no such message"))?;
    append_line(
        &home
            .snippet_dir(address, &held.snippet_id)
            .join("chat.jsonl"),
        &serde_json::to_string(&message)?,
    )?;
    Ok(message)
}

/// Take a message back. A tombstone rather than a missing row: the text is
/// scrubbed, the photo and the vector are gone, and the row takes a new
/// `timeid` so every client holding a copy is told to drop it. Deleting a
/// tombstone again is the same tombstone.
pub fn delete(conn: &Connection, home: &Home, address: &str, message_id: i64) -> Result<Message> {
    let held = get(conn, address, message_id)?.ok_or_else(|| not_found("no such message"))?;
    if held.deleted {
        return Ok(held);
    }
    let timeid = next_timeid(conn)?;
    let photo: Option<String> = conn.query_row(
        "SELECT photo FROM snippet_messages WHERE id = ?1",
        params![message_id],
        |r| r.get(0),
    )?;
    conn.execute(
        "UPDATE snippet_messages
            SET text = '', photo = NULL, photo_token = NULL, deleted = 1, timeid = ?2
          WHERE id = ?1",
        params![message_id, timeid],
    )?;
    conn.execute(
        "DELETE FROM snippet_message_vec WHERE message_id = ?1",
        params![message_id],
    )?;
    if let Some(file) = photo {
        let _ = std::fs::remove_file(home.snippet_photo_dir(address, &held.snippet_id).join(file));
    }
    let message = get(conn, address, message_id)?.ok_or_else(|| not_found("no such message"))?;
    append_line(
        &home
            .snippet_dir(address, &held.snippet_id)
            .join("chat.jsonl"),
        &serde_json::to_string(&message)?,
    )?;
    Ok(message)
}

/// The file the HTTP route serves, if `token` is the one minted for this
/// message. The row is looked up by id **and** token in one query, so a
/// right id with a wrong token is indistinguishable from no row at all.
pub fn photo(
    conn: &Connection,
    home: &Home,
    message_id: i64,
    token: &str,
) -> Result<Option<(PathBuf, &'static str)>> {
    let row: Option<(String, String, String)> = conn
        .query_row(
            "SELECT address, snippet_id, photo FROM snippet_messages
              WHERE id = ?1 AND photo_token = ?2 AND photo IS NOT NULL",
            params![message_id, token],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    let Some((address, snippet_id, file)) = row else {
        return Ok(None);
    };
    let ext = file.rsplit_once('.').map(|(_, e)| e).unwrap_or("");
    let Some(mime) = mime_for(ext) else {
        return Ok(None);
    };
    Ok(Some((
        home.snippet_photo_dir(&address, &snippet_id).join(file),
        mime,
    )))
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

struct Bm25Hit {
    id: i64,
    score: f64,
    snippet: String,
}

/// The `WHERE` tail shared by both halves: this user, and one pad if asked.
/// Bound as parameters ?2/?3 either way, with ?3 ignored when it is NULL, so
/// the two shapes are one statement.
const SCOPE: &str = "m.address = ?2 AND (?3 IS NULL OR m.snippet_id = ?3) AND m.deleted = 0";

fn bm25_search(
    conn: &Connection,
    address: &str,
    snippet_id: Option<&str>,
    q: &str,
    limit: usize,
) -> Result<Vec<Bm25Hit>> {
    // Every word first, any word second — the same two tries `search.rs`
    // makes, for the same reason: a typo in one word of four should loosen
    // the search, not empty it.
    for all_words in [true, false] {
        let Some(query) = search::match_query(q, all_words) else {
            return Ok(Vec::new());
        };
        let mut stmt = conn.prepare(&format!(
            "SELECT m.id,
                    bm25(snippet_message_fts) AS rank,
                    snippet(snippet_message_fts, 0, '<b>', '</b>', '…', 14)
               FROM snippet_message_fts
               JOIN snippet_messages m ON m.rowid = snippet_message_fts.rowid
              WHERE snippet_message_fts MATCH ?1 AND {SCOPE}
              ORDER BY rank
              LIMIT ?4"
        ))?;
        let rows = stmt.query_map(params![query, address, snippet_id, limit as i64], |r| {
            Ok(Bm25Hit {
                id: r.get(0)?,
                // bm25() is negative and lower is better; flipped so every
                // score here means "more is better", as in `search.rs`.
                score: -r.get::<_, f64>(1)?,
                snippet: r.get(2)?,
            })
        })?;
        let hits: Vec<Bm25Hit> = rows.collect::<rusqlite::Result<Vec<_>>>()?;
        if !hits.is_empty() {
            return Ok(hits);
        }
    }
    Ok(Vec::new())
}

fn semantic_search(
    conn: &Connection,
    embedder: &dyn Embedder,
    address: &str,
    snippet_id: Option<&str>,
    q: &str,
    limit: usize,
) -> Result<Vec<(i64, f64)>> {
    let query = embedder.embed(q);
    // Brute force over this user's rows: a few hundred messages per pad and
    // the scope is one SQL filter away, so an index would cost more than it
    // saves. A row from another embedder is skipped rather than compared
    // against a vector of a different shape.
    let mut stmt = conn.prepare(&format!(
        "SELECT v.message_id, v.vec FROM snippet_message_vec v
           JOIN snippet_messages m ON m.id = v.message_id
          WHERE v.model = ?1 AND {SCOPE}"
    ))?;
    let rows = stmt.query_map(params![embedder.id(), address, snippet_id], |r| {
        let blob: Vec<u8> = r.get(1)?;
        Ok((r.get::<_, i64>(0)?, blob))
    })?;
    let mut scored: Vec<(i64, f64)> = rows
        .collect::<rusqlite::Result<Vec<_>>>()?
        .into_iter()
        .map(|(id, blob)| (id, search::cosine(&query, &search::from_blob(&blob)) as f64))
        .filter(|(_, score)| *score > 0.0)
        .collect();
    scored.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    scored.truncate(limit);
    Ok(scored)
}

#[derive(Default)]
struct Fused {
    score: f64,
    bm25: Option<f64>,
    cosine: Option<f64>,
    snippet: Option<String>,
}

/// BM25 over `snippet_message_fts`, cosine over `snippet_message_vec`, fused
/// by RRF with `k = 60` exactly as `search::query` does for quests (SPEC §8.3).
/// Every hit is this user's; `snippet_id` narrows to one room.
pub fn search(
    conn: &Connection,
    embedder: &dyn Embedder,
    address: &str,
    q: &str,
    snippet_id: Option<&str>,
    mode: Mode,
    limit: usize,
) -> Result<Vec<Hit>> {
    if q.trim().is_empty() {
        return Ok(Vec::new());
    }
    if let Some(id) = snippet_id {
        // Somebody else's room is `not_found` rather than quietly empty.
        let _ = snippets::get(conn, address, id)?;
    }
    let pool = (limit * 5).clamp(20, 200);
    let bm25 = if mode == Mode::Semantic {
        Vec::new()
    } else {
        bm25_search(conn, address, snippet_id, q, pool)?
    };
    let semantic = if mode == Mode::Bm25 {
        Vec::new()
    } else {
        semantic_search(conn, embedder, address, snippet_id, q, pool)?
    };

    let mut fused: HashMap<i64, Fused> = HashMap::new();
    for (rank, hit) in bm25.iter().enumerate() {
        let entry = fused.entry(hit.id).or_default();
        entry.score += 1.0 / (search::RRF_K + rank as f64 + 1.0);
        entry.bm25 = Some(hit.score);
        entry.snippet = Some(hit.snippet.clone());
    }
    for (rank, (id, score)) in semantic.iter().enumerate() {
        let entry = fused.entry(*id).or_default();
        entry.score += 1.0 / (search::RRF_K + rank as f64 + 1.0);
        entry.cosine = Some(*score);
    }

    let mut hits = Vec::new();
    for (id, entry) in fused {
        // Scoped by address once more on the read: a hit is only ever built
        // from a row this user owns.
        let Some(message) = get(conn, address, id)? else {
            continue;
        };
        let snippet_name: String = conn.query_row(
            "SELECT name FROM snippets WHERE id = ?1 AND address = ?2",
            params![message.snippet_id, address],
            |r| r.get(0),
        )?;
        hits.push(Hit {
            snippet: entry
                .snippet
                .unwrap_or_else(|| search::excerpt(&message.text)),
            message,
            snippet_name,
            score: entry.score,
            bm25: entry.bm25,
            cosine: entry.cosine,
        });
    }
    hits.sort_by(|a, b| {
        b.score
            .total_cmp(&a.score)
            .then_with(|| a.message.id.cmp(&b.message.id))
    });
    hits.truncate(limit);
    Ok(hits)
}

// ---------------------------------------------------------------------------
// The folder mirror
// ---------------------------------------------------------------------------

/// Append one line to an owner-only file. `write_private` truncates, which is
/// right for a snippet's source and wrong for a transcript.
fn append_line(path: &std::path::Path, line: &str) -> Result<()> {
    use std::io::Write;
    if let Some(parent) = path.parent() {
        ensure_dir(parent)?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.append(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    set_private(path, 0o600)?;
    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")?;
    file.flush()?;
    Ok(())
}
