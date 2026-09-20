//! Opening the database: pragmas, the forward-only migrations, and the FTS5
//! assertion SPEC §9.3 insists is an assertion rather than a hope.

use std::path::Path;

use rusqlite::Connection;

use crate::error::{internal, Result};
use crate::paths::set_private;

/// The migrations, in order. Forward-only: a shipped file is never edited,
/// a change is a new one. `include_str!` so the binary carries them and a
/// deployed server cannot be missing its own schema.
pub const MIGRATIONS: &[(i64, &str, &str)] = &[
    (1, "0001_init", include_str!("../migrations/0001_init.sql")),
    (
        2,
        "0002_attempt_mode",
        include_str!("../migrations/0002_attempt_mode.sql"),
    ),
    (
        3,
        "0003_snippets",
        include_str!("../migrations/0003_snippets.sql"),
    ),
    (
        4,
        "0004_awards",
        include_str!("../migrations/0004_awards.sql"),
    ),
    (
        5,
        "0005_clock",
        include_str!("../migrations/0005_clock.sql"),
    ),
    (
        6,
        "0006_drill_reason",
        include_str!("../migrations/0006_drill_reason.sql"),
    ),
    (
        7,
        "0007_interviews",
        include_str!("../migrations/0007_interviews.sql"),
    ),
    (
        8,
        "0008_more_lands",
        include_str!("../migrations/0008_more_lands.sql"),
    ),
    // Versions must stay ascending here: `migrate` stamps `user_version` after
    // each one, so an entry listed out of order is silently skipped forever.
    (
        9,
        "0009_quest_text",
        include_str!("../migrations/0009_quest_text.sql"),
    ),
    (
        10,
        "0010_edit_stack",
        include_str!("../migrations/0010_edit_stack.sql"),
    ),
    (
        11,
        "0011_position",
        include_str!("../migrations/0011_position.sql"),
    ),
    (
        12,
        "0012_snippet_stdin",
        include_str!("../migrations/0012_snippet_stdin.sql"),
    ),
    (
        13,
        "0013_snippet_chat",
        include_str!("../migrations/0013_snippet_chat.sql"),
    ),
    (
        14,
        "0014_chat_seq",
        include_str!("../migrations/0014_chat_seq.sql"),
    ),
    (
        15,
        "0015_chat_edit",
        include_str!("../migrations/0015_chat_edit.sql"),
    ),
    (16, "0016_xp", include_str!("../migrations/0016_xp.sql")),
    (
        17,
        "0017_verybasic",
        include_str!("../migrations/0017_verybasic.sql"),
    ),
    (
        18,
        "0018_practice",
        include_str!("../migrations/0018_practice.sql"),
    ),
];

pub fn latest_version() -> i64 {
    MIGRATIONS.last().map(|m| m.0).unwrap_or(0)
}

/// How many startup backups are kept. Seven starts is a week of `make
/// start`s for somebody who plays daily and a month for somebody who does
/// not, and the newest is the one that matters.
pub const BACKUPS_KEPT: usize = 7;

/// Copy the database into `dir` as `hacker-<stamp>.db`, consistently, with
/// the WAL folded in — `VACUUM INTO`, not a file copy, which would miss
/// every write still sitting in `hacker.db-wal`. Taken **before** `open`
/// runs the migrations, so what is kept is the database as the last server
/// left it. A missing or empty database is nothing to back up. The oldest
/// copies past `BACKUPS_KEPT` are removed.
///
/// Best effort, said so out loud: a disk too full to take a copy is a
/// reason to warn, not a reason to refuse to serve the player's record.
pub fn backup(path: &Path, dir: &Path) -> Result<Option<std::path::PathBuf>> {
    let size = match std::fs::metadata(path) {
        Ok(meta) => meta.len(),
        Err(_) => return Ok(None),
    };
    if size == 0 {
        return Ok(None);
    }
    let stamp = crate::time::now_stamp()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect::<String>();
    let target = dir.join(format!("hacker-{stamp}.db"));
    let conn = Connection::open(path)?;
    conn.execute("VACUUM INTO ?1", [target.to_string_lossy().as_ref()])?;
    drop(conn);
    set_private(&target, 0o600)?;
    // Prune: the names sort by stamp, so the oldest are the first.
    let mut copies: Vec<_> = std::fs::read_dir(dir)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with("hacker-") && n.ends_with(".db"))
                .unwrap_or(false)
        })
        .collect();
    copies.sort();
    while copies.len() > BACKUPS_KEPT {
        let old = copies.remove(0);
        let _ = std::fs::remove_file(old);
    }
    Ok(Some(target))
}

/// Open `hacker.db`, apply everything, hand back a ready connection.
pub fn open(path: &Path) -> Result<Connection> {
    // Said before it happens: a database that is not there is a record that
    // starts empty, and when that is not what somebody expected — a home
    // that was moved, a `--home` pointing somewhere new — this line in the
    // log is the one that explains where their clears went.
    let fresh = !std::fs::metadata(path)
        .map(|m| m.len() > 0)
        .unwrap_or(false);
    if fresh {
        tracing::warn!(db = %path.display(), "no database here — starting an empty record");
    }
    let conn = Connection::open(path)?;
    configure(&conn)?;
    // SQLite creates the db and its sidecars under the umask; §1 says every
    // file in the home is 0600, and the -wal/-shm pair is the one that gets
    // forgotten because it appears only after the first write.
    tighten(path)?;
    prepare(&conn)?;
    tighten(path)?;
    Ok(conn)
}

/// An in-memory database with the same schema, for tests that do not need a
/// home on disk.
pub fn open_memory() -> Result<Connection> {
    let conn = Connection::open_in_memory()?;
    configure(&conn)?;
    prepare(&conn)?;
    Ok(conn)
}

/// Everything between "there is a connection" and "the schema is usable".
///
/// The FTS5 assertion comes **before** the migrations on purpose: 0001 creates
/// a `USING fts5` virtual table, so a build without FTS5 would otherwise fail
/// halfway through a migration and leave a half-built database behind. And it
/// is an error, not a warning — a server that starts without FTS5 is a server
/// whose search is broken in a way nobody notices until someone types in the
/// box (SPEC §9.3).
pub fn prepare(conn: &Connection) -> Result<()> {
    assert_fts5(conn)?;
    migrate(conn)
}

fn configure(conn: &Connection) -> Result<()> {
    // journal_mode returns a row ("wal"), so it is a query and not an execute.
    let mode: String = conn.query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))?;
    if !mode.eq_ignore_ascii_case("wal") && !mode.eq_ignore_ascii_case("memory") {
        tracing::warn!(mode = %mode, "sqlite refused WAL mode");
    }
    // foreign_keys is a no-op inside a transaction, so it goes on before any
    // BEGIN — including the migration transaction below.
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.busy_timeout(std::time::Duration::from_secs(5))?;
    Ok(())
}

fn tighten(path: &Path) -> Result<()> {
    for suffix in ["", "-wal", "-shm"] {
        let mut p = path.as_os_str().to_os_string();
        p.push(suffix);
        set_private(Path::new(&p), 0o600)?;
    }
    Ok(())
}

/// SPEC §9.3. The bundled amalgamation compiles FTS5 in, but "compiles it in"
/// is a claim about a build flag; this is the thing that proves it on the
/// machine actually running.
pub fn assert_fts5(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE VIRTUAL TABLE IF NOT EXISTS temp.fts5_smoke USING fts5(x);
         INSERT INTO temp.fts5_smoke(x) VALUES ('causewaybay hacker');",
    )
    .map_err(|e| internal(format!("SQLite has no FTS5: {e}")))?;
    let hits: i64 = conn
        .query_row(
            "SELECT count(*) FROM temp.fts5_smoke WHERE fts5_smoke MATCH 'hacker'",
            [],
            |r| r.get(0),
        )
        .map_err(|e| internal(format!("FTS5 present but not working: {e}")))?;
    if hits != 1 {
        return Err(internal("FTS5 matched nothing on a document it contains"));
    }
    conn.execute_batch("DROP TABLE temp.fts5_smoke;")?;
    Ok(())
}

/// Apply every migration above `PRAGMA user_version`, each in its own
/// transaction, in order.
///
/// Foreign keys are off while a migration runs and checked before it
/// commits, which is the procedure the SQLite manual gives for altering a
/// table (0008 rebuilds three). With them on, `DROP TABLE quests` is an
/// implicit `DELETE FROM quests` that cascades through progress, attempts and
/// mistakes before the copy is renamed into place. The pragma is a no-op
/// inside a transaction, so it is set before `BEGIN` and restored after
/// `COMMIT`; `foreign_key_check` inside the transaction is what makes sure
/// nothing dangling gets committed in between.
pub fn migrate(conn: &Connection) -> Result<()> {
    let current: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    for (version, name, sql) in MIGRATIONS {
        if *version <= current {
            continue;
        }
        tracing::info!(version, name, "applying migration");
        conn.pragma_update(None, "foreign_keys", "OFF")?;
        conn.execute_batch("BEGIN IMMEDIATE")?;
        let applied = conn
            .execute_batch(sql)
            .and_then(|_| conn.execute_batch(&format!("PRAGMA user_version = {version}")))
            .and_then(|_| foreign_keys_hold(conn));
        let committed = match applied {
            Ok(()) => conn.execute_batch("COMMIT"),
            Err(e) => {
                let _ = conn.execute_batch("ROLLBACK");
                Err(e)
            }
        };
        // Restored whatever happened above; a failed migration must not leave
        // the connection with its foreign keys off.
        conn.pragma_update(None, "foreign_keys", "ON")?;
        if let Err(e) = committed {
            return Err(internal(format!("migration {name} failed: {e}")));
        }
    }
    Ok(())
}

/// `PRAGMA foreign_key_check` returns one row per violation; the migration is
/// only allowed to commit when it returns none.
fn foreign_keys_hold(conn: &Connection) -> rusqlite::Result<()> {
    let mut stmt = conn.prepare("PRAGMA foreign_key_check")?;
    let mut rows = stmt.query([])?;
    if let Some(row) = rows.next()? {
        let table: String = row.get(0)?;
        let parent: String = row.get(2)?;
        return Err(rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CONSTRAINT),
            Some(format!(
                "{table} has a row that no longer points at {parent}"
            )),
        ));
    }
    Ok(())
}
