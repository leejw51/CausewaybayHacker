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
];

pub fn latest_version() -> i64 {
    MIGRATIONS.last().map(|m| m.0).unwrap_or(0)
}

/// Open `hacker.db`, apply everything, hand back a ready connection.
pub fn open(path: &Path) -> Result<Connection> {
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
pub fn migrate(conn: &Connection) -> Result<()> {
    let current: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    for (version, name, sql) in MIGRATIONS {
        if *version <= current {
            continue;
        }
        tracing::info!(version, name, "applying migration");
        conn.execute_batch("BEGIN IMMEDIATE")?;
        let applied = conn
            .execute_batch(sql)
            .and_then(|_| conn.execute_batch(&format!("PRAGMA user_version = {version}")));
        match applied {
            Ok(()) => conn.execute_batch("COMMIT")?,
            Err(e) => {
                let _ = conn.execute_batch("ROLLBACK");
                return Err(internal(format!("migration {name} failed: {e}")));
            }
        }
    }
    Ok(())
}
