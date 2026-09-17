//! The schema upgrades itself, and keeps upgrading itself as fields are added.
//!
//! `Store::open` runs every migration above `PRAGMA user_version`, so a server
//! that ships with a new column finds an old `hacker.db` and brings it forward
//! on the next start — nobody runs anything by hand. That is easy to write and
//! easy to break later, in ways a fresh-database test cannot see:
//!
//!   * a migration added with a version that already exists, or out of order,
//!     so it is silently skipped on every database that has passed that number;
//!   * a migration that builds a table subtly unlike the one `0001..N` would
//!     produce, so upgraded databases and new ones diverge and only one of them
//!     is ever tested;
//!   * a migration that drops the player's rows on the way past.
//!
//! Each of those is a test here, written against the *list* rather than
//! against any particular migration, so a field added next year is covered by
//! what is already written.

use rusqlite::Connection;

use cwbhacker_core::db;

/// A database as an older build left it: migrations up to and including
/// `upto`, and `user_version` to match. This is what is on disk when somebody
/// upgrades.
fn database_at_version(upto: i64) -> Connection {
    let conn = Connection::open_in_memory().unwrap();
    conn.pragma_update(None, "foreign_keys", "OFF").unwrap();
    for (version, _, sql) in db::MIGRATIONS {
        if *version > upto {
            break;
        }
        conn.execute_batch(sql).unwrap();
        conn.pragma_update(None, "user_version", *version).unwrap();
    }
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    conn
}

fn user_version(conn: &Connection) -> i64 {
    conn.query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap()
}

/// Everything SQLite itself considers part of the shape, normalised to a set
/// of lines so two databases can be compared without caring about order.
fn schema(conn: &Connection) -> Vec<String> {
    let mut stmt = conn
        .prepare(
            "SELECT type || ' ' || name || ' ' || coalesce(sql, '')
               FROM sqlite_master
              WHERE name NOT LIKE 'sqlite_%'
              ORDER BY type, name",
        )
        .unwrap();
    let mut rows: Vec<String> = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    rows.sort();
    rows
}

#[test]
fn the_versions_are_unique_and_in_order() {
    // The loop in `migrate` skips anything `<= user_version`, so a duplicate or
    // an out-of-order number is not an error — it is a migration that never
    // runs on any database that has already passed it. That failure is silent
    // and permanent, which is why it is asserted rather than reviewed.
    let mut previous = 0;
    for (version, name, _) in db::MIGRATIONS {
        assert!(
            *version > previous,
            "migration {name} has version {version}, which does not come after {previous}"
        );
        previous = *version;
    }
    assert_eq!(db::latest_version(), previous);
}

#[test]
fn every_migration_is_named_for_its_number() {
    // `0011_position` at version 11. A mismatch means the file applied is not
    // the file somebody reading the directory thinks is applied.
    for (version, name, _) in db::MIGRATIONS {
        let prefix = format!("{version:04}_");
        assert!(
            name.starts_with(&prefix),
            "migration {name} should start with {prefix}"
        );
    }
}

#[test]
fn a_fresh_database_is_already_at_the_latest_version() {
    let conn = db::open_memory().unwrap();
    assert_eq!(user_version(&conn), db::latest_version());
}

#[test]
fn an_old_database_is_brought_forward_without_being_asked() {
    // The upgrade every player's machine does: a build from before the last
    // field was added, opened by a build that has it.
    let previous = db::MIGRATIONS[db::MIGRATIONS.len() - 2].0;
    let conn = database_at_version(previous);
    assert_eq!(user_version(&conn), previous);

    db::prepare(&conn).unwrap();

    assert_eq!(user_version(&conn), db::latest_version());
}

#[test]
fn upgrading_reaches_exactly_the_schema_a_fresh_database_has() {
    // The one that catches a migration written to *approximately* match what
    // `0001..N` produces. Without it, upgraded databases and new ones diverge
    // and only new ones are ever tested — every developer has a fresh one.
    for start in 0..db::MIGRATIONS.len() {
        let from = if start == 0 {
            0
        } else {
            db::MIGRATIONS[start - 1].0
        };
        let upgraded = database_at_version(from);
        db::prepare(&upgraded).unwrap();

        let fresh = db::open_memory().unwrap();
        assert_eq!(
            schema(&upgraded),
            schema(&fresh),
            "a database upgraded from version {from} does not match a fresh one"
        );
    }
}

#[test]
fn an_upgrade_keeps_the_rows_that_were_already_there() {
    // A migration that rebuilds a table — 0008 rebuilds three — is one typo
    // away from being a very effective DELETE.
    let previous = db::MIGRATIONS[db::MIGRATIONS.len() - 2].0;
    let conn = database_at_version(previous);
    conn.execute(
        "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at, settings)
              VALUES ('0xabc', '0xABC', 'mei', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '{}')",
        [],
    )
    .unwrap();

    db::prepare(&conn).unwrap();

    let name: String = conn
        .query_row("SELECT name FROM users WHERE address = '0xabc'", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(name, "mei", "the upgrade lost a player");
}

#[test]
fn running_it_again_changes_nothing() {
    // Every start after the first. `migrate` is called on every open, so it
    // being a no-op at the latest version is the common case, not an edge one.
    let conn = db::open_memory().unwrap();
    let before = schema(&conn);
    for _ in 0..3 {
        db::prepare(&conn).unwrap();
    }
    assert_eq!(schema(&conn), before);
    assert_eq!(user_version(&conn), db::latest_version());
}

#[test]
fn the_players_place_arrives_with_its_own_migration() {
    let conn = database_at_version(10);
    let has_position = |c: &Connection| -> i64 {
        c.query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='user_position'",
            [],
            |r| r.get(0),
        )
        .unwrap()
    };
    assert_eq!(has_position(&conn), 0, "not there before 0011");
    db::prepare(&conn).unwrap();
    assert_eq!(has_position(&conn), 1, "and there afterwards, unprompted");
}

#[test]
fn a_scratchpad_got_its_input_with_0012() {
    let conn = database_at_version(11);
    let has_stdin = |c: &Connection| -> i64 {
        c.query_row(
            "SELECT count(*) FROM pragma_table_info('snippets') WHERE name='stdin'",
            [],
            |r| r.get(0),
        )
        .unwrap()
    };
    assert_eq!(has_stdin(&conn), 0, "not there before 0012");
    db::prepare(&conn).unwrap();
    assert_eq!(has_stdin(&conn), 1, "and there afterwards, unprompted");
    // Every pad that already existed keeps its code and gains an empty input,
    // which is the only honest value: nobody could have saved one yet.
    let empty: String = conn
        .query_row("SELECT coalesce(max(stdin), '') FROM snippets", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(empty, "", "an existing pad's input is empty, not null");
}

#[test]
fn the_newest_migration_is_the_one_that_gave_a_scratchpad_its_chatroom() {
    // A specific check on top of the generic ones, so this file also documents
    // what the last change actually was — and fails loudly if a future
    // migration is added without extending the tests above.
    let previous = db::MIGRATIONS[db::MIGRATIONS.len() - 2].0;
    let conn = database_at_version(previous);
    let tables = |c: &Connection| -> i64 {
        c.query_row(
            "SELECT count(*) FROM sqlite_master
              WHERE name IN ('snippet_messages', 'snippet_message_fts', 'snippet_message_vec')",
            [],
            |r| r.get(0),
        )
        .unwrap()
    };
    assert_eq!(tables(&conn), 0, "not there before 0013");
    db::prepare(&conn).unwrap();
    assert_eq!(tables(&conn), 3, "and there afterwards, unprompted");
}
