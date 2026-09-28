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
fn a_scratchpads_chatroom_arrived_with_0013() {
    let conn = database_at_version(12);
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

#[test]
fn every_message_got_an_id_and_a_timeid_with_0014() {
    let conn = database_at_version(13);
    // A room from before: text ids, three messages, one pair said in the
    // same second, one said earlier but inserted later, one with a photo
    // and a vector.
    conn.execute_batch(
        "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at, settings)
           VALUES ('0xaa', '0xAA', 'old hand', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '{}');
         INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
           VALUES ('pg_0000000000000001', '0xaa', 'old', 'rust', '', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
         INSERT INTO snippet_messages (id, snippet_id, address, role, kind, text, photo, photo_token, created_at) VALUES
           ('msg_000000000000000b', 'pg_0000000000000001', '0xaa', 'user', 'text', 'second', NULL, NULL, '2026-01-02T00:00:00Z'),
           ('msg_000000000000000c', 'pg_0000000000000001', '0xaa', 'agent', 'image', 'third', 'msg_000000000000000c.png', 'ab', '2026-01-02T00:00:00Z'),
           ('msg_000000000000000a', 'pg_0000000000000001', '0xaa', 'user', 'text', 'first', NULL, NULL, '2026-01-01T00:00:00Z');
         INSERT INTO snippet_message_vec (message_id, dim, model, vec)
           VALUES ('msg_000000000000000c', 1, 'hashed-v2-512', x'00000000');",
    )
    .unwrap();
    assert!(
        conn.prepare("SELECT timeid FROM snippet_messages").is_err(),
        "no timeid before 0014"
    );
    db::prepare(&conn).unwrap();
    let mut stmt = conn
        .prepare("SELECT id, timeid, text, photo FROM snippet_messages ORDER BY timeid")
        .unwrap();
    let rows: Vec<(i64, i64, String, Option<String>)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    // In the order they were said, ties broken by insertion; ids are ints
    // and the photo keeps the file it always had.
    assert_eq!(
        rows.iter().map(|r| r.2.as_str()).collect::<Vec<_>>(),
        ["first", "second", "third"]
    );
    assert!(rows[0].1 < rows[1].1 && rows[1].1 < rows[2].1, "{rows:?}");
    assert_eq!(rows[1].1 + 1, rows[2].1, "a tie is one millisecond apart");
    assert_eq!(rows[0].1, 1_767_225_600_000, "2026-01-01T00:00:00Z in ms");
    assert!(rows.iter().all(|r| r.0 > 0));
    assert_eq!(rows[2].3.as_deref(), Some("msg_000000000000000c.png"));
    // The vector followed its message to the new id, and the FTS index was
    // rebuilt over the new rowids.
    let vec_for: i64 = conn
        .query_row(
            "SELECT count(*) FROM snippet_message_vec v JOIN snippet_messages m ON m.id = v.message_id WHERE m.text = 'third'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(vec_for, 1);
    let found: i64 = conn
        .query_row(
            "SELECT count(*) FROM snippet_message_fts WHERE snippet_message_fts MATCH 'second'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(found, 1);
    // And the clock stands past every row that exists.
    let clock: i64 = conn
        .query_row("SELECT last_timeid FROM chat_clock", [], |r| r.get(0))
        .unwrap();
    assert_eq!(clock, rows[2].1);
}

#[test]
fn a_message_could_be_edited_or_deleted_from_0015() {
    // A specific check on top of the generic ones, so this file also documents
    // what that change actually was. (It used to pin itself as the newest
    // migration; 0016 took that seat — see the ledger test below.)
    let conn = database_at_version(14);
    conn.execute_batch(
        "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at, settings)
           VALUES ('0xaa', '0xAA', 'old hand', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '{}');
         INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
           VALUES ('pg_0000000000000001', '0xaa', 'old', 'rust', '', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
         INSERT INTO snippet_messages (timeid, snippet_id, address, role, kind, text, created_at)
           VALUES (1767225600000, 'pg_0000000000000001', '0xaa', 'user', 'text', 'said', '2026-01-01T00:00:00Z');",
    )
    .unwrap();
    assert!(conn
        .prepare("SELECT edited, deleted FROM snippet_messages")
        .is_err());
    db::prepare(&conn).unwrap();
    let (edited, deleted): (i64, i64) = conn
        .query_row("SELECT edited, deleted FROM snippet_messages", [], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .unwrap();
    assert_eq!((edited, deleted), (0, 0), "what exists is as it was said");
}

#[test]
fn the_xp_ledger_arrived_with_0016_and_was_backfilled() {
    // A player who cleared things before the ledger existed keeps exactly the
    // XP the old formula was reading for them, dated at the clear.
    let conn = database_at_version(15);
    conn.execute(
        "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at, settings)
           VALUES ('0xaa', '0xAA', 'old hand', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '{}')",
        [],
    )
    .unwrap();
    for (id, cat, node, diff) in [
        ("rust.basic.01.a", "basic", 1, 1),
        ("rust.hacker.02.b", "hacker", 2, 5),
        ("rust.basic.03.c", "basic", 3, 2),
    ] {
        conn.execute(
            "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                                 starter, solution, tests, checksum)
             VALUES (?1, 'p', 'rust', ?2, ?3, 't', 'b', 's', ?4, 's', 's', '{}', 'c')",
            rusqlite::params![id, cat, node, diff],
        )
        .unwrap();
    }
    conn.execute(
        "INSERT INTO progress (address, quest_id, state, stars, attempts, hints_used, first_clear_at, updated_at)
           VALUES ('0xaa', 'rust.basic.01.a', 'cleared', 3, 1, 0, '2026-02-01T00:00:00Z', '2026-02-02T00:00:00Z'),
                  ('0xaa', 'rust.hacker.02.b', 'cleared', 2, 4, 1, NULL, '2026-03-01T00:00:00Z'),
                  ('0xaa', 'rust.basic.03.c', 'open', 0, 2, 0, NULL, '2026-03-02T00:00:00Z')",
        [],
    )
    .unwrap();

    db::prepare(&conn).unwrap();

    let rows: Vec<(String, i64, i64, String)> = conn
        .prepare("SELECT quest_id, amount, stars, created_at FROM xp_ledger WHERE address = '0xaa' ORDER BY quest_id")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    assert_eq!(
        rows,
        vec![
            (
                "rust.basic.01.a".to_string(),
                75,
                3,
                "2026-02-01T00:00:00Z".to_string()
            ),
            (
                "rust.hacker.02.b".to_string(),
                750,
                2,
                "2026-03-01T00:00:00Z".to_string()
            ),
        ],
        "3×1×1 basic and 2×5×3 hacker; the open quest gets nothing"
    );
}

#[test]
fn a_verybasic_quest_with_a_quiz_arrived_with_0017() {
    // 0017 rebuilds `quests`: a row survives with its rowid, a 'verybasic'
    // quest is now insertable, and `quiz` is a column.
    let conn = database_at_version(16);
    conn.execute(
        "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                             starter, solution, tests, checksum)
         VALUES ('rust.basic.01.a', 'p', 'rust', 'basic', 1, 'A', 'b', 's', 1, 's', 's', '{}', 'c')",
        [],
    )
    .unwrap();
    let rowid_before: i64 = conn
        .query_row(
            "SELECT rowid FROM quests WHERE id = 'rust.basic.01.a'",
            [],
            |r| r.get(0),
        )
        .unwrap();

    db::prepare(&conn).unwrap();

    let (rowid_after, quiz): (i64, Option<String>) = conn
        .query_row(
            "SELECT rowid, quiz FROM quests WHERE id = 'rust.basic.01.a'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(rowid_after, rowid_before, "the FTS index is keyed by rowid");
    assert_eq!(quiz, None);
    conn.execute(
        "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                             starter, solution, tests, checksum, quiz)
         VALUES ('rust.verybasic.01.a', 'p', 'rust', 'verybasic', 1, 'Q', 'b', 's', 1, 's', 's', '{}', 'c',
                 '{\"choices\":[\"a\",\"b\",\"c\",\"d\"],\"answer\":2}')",
        [],
    )
    .expect("a verybasic quest with a quiz is insertable after 0017");
    let hits: i64 = conn
        .query_row(
            "SELECT count(*) FROM quest_fts WHERE quest_fts MATCH 'Q'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(hits, 1, "the FTS triggers were put back");
}

#[test]
fn the_ledger_learned_to_pay_for_practice_with_0018() {
    // 0018 rebuilds `xp_ledger`: the clear rows survive with their ids, a
    // second `practice` row for the same quest is insertable, and a second
    // `clear` row still is not.
    let conn = database_at_version(17);
    conn.execute(
        "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at, settings)
           VALUES ('0xaa', '0xAA', 'old hand', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '{}')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO xp_ledger (id, address, quest_id, reason, amount, stars, created_at)
           VALUES (7, '0xaa', 'rust.basic.01.a', 'clear', 75, 3, '2026-02-01T00:00:00Z')",
        [],
    )
    .unwrap();

    db::prepare(&conn).unwrap();

    let (id, amount): (i64, i64) = conn
        .query_row(
            "SELECT id, amount FROM xp_ledger WHERE quest_id = 'rust.basic.01.a'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(
        (id, amount),
        (7, 75),
        "the clear row came through with its id"
    );
    for _ in 0..2 {
        conn.execute(
            "INSERT INTO xp_ledger (address, quest_id, reason, amount, stars, created_at)
               VALUES ('0xaa', 'rust.basic.01.a', 'practice', 15, 3, '2026-03-01T00:00:00Z')",
            [],
        )
        .expect("practice rows repeat");
    }
    let dup = conn.execute(
        "INSERT INTO xp_ledger (address, quest_id, reason, amount, stars, created_at)
           VALUES ('0xaa', 'rust.basic.01.a', 'clear', 75, 3, '2026-03-02T00:00:00Z')",
        [],
    );
    assert!(dup.is_err(), "a clear is still granted once");
}

#[test]
fn migration_0019_lets_a_road_be_walked_again() {
    // 0019 adds `progress.reset_at` — the date a road was put back to
    // untouched, which is where the star count starts from.
    let conn = database_at_version(18);
    conn.execute(
        "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at, settings)
           VALUES ('0xaa', '0xAA', 'old hand', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '{}')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                             starter, solution, tests, checksum)
         VALUES ('rust.basic.01.a', 'p', 'rust', 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO progress (address, quest_id, state, stars, attempts, hints_used,
                               first_clear_at, updated_at)
           VALUES ('0xaa', 'rust.basic.01.a', 'cleared', 3, 1, 0,
                   '2026-02-01T00:00:00Z', '2026-02-01T00:00:00Z')",
        [],
    )
    .unwrap();

    db::prepare(&conn).unwrap();

    let (stars, reset_at): (i64, Option<String>) = conn
        .query_row(
            "SELECT stars, reset_at FROM progress WHERE address = '0xaa'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(stars, 3, "the upgrade kept the row it found");
    assert_eq!(reset_at, None, "a road nobody has reset has no reset date");
    conn.execute(
        "UPDATE progress SET reset_at = '2026-03-01T00:00:00Z' WHERE address = '0xaa'",
        [],
    )
    .expect("the column is writable");
}

#[test]
fn migration_0020_opens_the_fifth_land() {
    // 0020 widens three CHECK constraints — the ones
    // 0008 and 0017 last rebuilt — so `pytorch` is a land the database will
    // accept. Everything already in the three tables has to survive the
    // rebuild, which is the half of this that is worth testing.
    let conn = database_at_version(19);
    conn.execute(
        "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at, settings)
           VALUES ('0xaa', '0xAA', 'old hand', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '{}')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                             starter, solution, tests, checksum)
         VALUES ('rust.basic.01.a', 'p', 'rust', 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
           VALUES ('s1', '0xaa', 'scratch', 'python', 'print(1)',
                   '2026-02-01T00:00:00Z', '2026-02-01T00:00:00Z')",
        [],
    )
    .unwrap();

    // Before the migration, the fifth land is not a land.
    assert!(
        conn.execute(
            "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                                 starter, solution, tests, checksum)
             VALUES ('pytorch.basic.01.a', 'p', 'pytorch', 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
            [],
        )
        .is_err(),
        "0019 has no pytorch in its CHECK"
    );

    db::prepare(&conn).unwrap();

    // After it, it is — in all three tables that name a land.
    conn.execute(
        "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                             starter, solution, tests, checksum)
         VALUES ('pytorch.basic.01.a', 'p', 'pytorch', 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
        [],
    )
    .expect("quests takes the fifth land");
    conn.execute(
        "INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
           VALUES ('s2', '0xaa', 'tensors', 'pytorch', 'import torch',
                   '2026-02-02T00:00:00Z', '2026-02-02T00:00:00Z')",
        [],
    )
    .expect("snippets takes the fifth land");
    conn.execute(
        "INSERT INTO attempts (id, address, quest_id, lang, source, verdict, created_at)
           VALUES ('a1', '0xaa', 'pytorch.basic.01.a', 'pytorch', 'import torch', 'accepted',
                   '2026-02-02T00:00:00Z')",
        [],
    )
    .expect("attempts takes the fifth land");

    // A land that is still not a land is still refused, so the rebuild
    // widened the constraint rather than dropping it.
    assert!(
        conn.execute(
            "INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
               VALUES ('s3', '0xaa', 'nope', 'cobol', 'x', '2026-02-03T00:00:00Z', '2026-02-03T00:00:00Z')",
            [],
        )
        .is_err(),
        "the CHECK is widened, not removed"
    );

    // And nothing that was there before was lost on the way through.
    let quests: i64 = conn
        .query_row(
            "SELECT count(*) FROM quests WHERE id = 'rust.basic.01.a'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(quests, 1, "the rebuild carried the quests across");
    let snips: i64 = conn
        .query_row("SELECT count(*) FROM snippets WHERE id = 's1'", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(snips, 1, "the rebuild carried the snippets across");

    // The FTS index is rebuilt by the migration, so search still finds the
    // row whose table was dropped and recreated underneath it.
    let hits: i64 = conn
        .query_row(
            "SELECT count(*) FROM quest_fts WHERE quest_fts MATCH 't'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(hits >= 1, "the FTS index came back with the table");
}

#[test]
fn migration_0021_opens_the_sixth_land() {
    // 0021 widens the same three CHECK constraints 0020 rebuilt, so
    // `typescript` is a land the database will accept. Everything already in
    // the three tables has to survive the rebuild, which is the half of this
    // that is worth testing. (The "newest migration" pin moved on to 0022's
    // test below.)
    let conn = database_at_version(20);
    conn.execute(
        "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at, settings)
           VALUES ('0xaa', '0xAA', 'old hand', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '{}')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                             starter, solution, tests, checksum)
         VALUES ('rust.basic.01.a', 'p', 'rust', 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
           VALUES ('s1', '0xaa', 'scratch', 'python', 'print(1)',
                   '2026-02-01T00:00:00Z', '2026-02-01T00:00:00Z')",
        [],
    )
    .unwrap();

    // Before the migration, the sixth land is not a land.
    assert!(
        conn.execute(
            "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                                 starter, solution, tests, checksum)
             VALUES ('typescript.basic.01.a', 'p', 'typescript', 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
            [],
        )
        .is_err(),
        "0020 has no typescript in its CHECK"
    );

    db::prepare(&conn).unwrap();

    // After it, it is — in all three tables that name a land.
    conn.execute(
        "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                             starter, solution, tests, checksum)
         VALUES ('typescript.basic.01.a', 'p', 'typescript', 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
        [],
    )
    .expect("quests takes the sixth land");
    conn.execute(
        "INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
           VALUES ('s2', '0xaa', 'screens', 'typescript', 'console.log(1)',
                   '2026-02-02T00:00:00Z', '2026-02-02T00:00:00Z')",
        [],
    )
    .expect("snippets takes the sixth land");
    conn.execute(
        "INSERT INTO attempts (id, address, quest_id, lang, source, verdict, created_at)
           VALUES ('a1', '0xaa', 'typescript.basic.01.a', 'typescript', 'console.log(1)', 'accepted',
                   '2026-02-02T00:00:00Z')",
        [],
    )
    .expect("attempts takes the sixth land");

    // A land that is still not a land is still refused, so the rebuild
    // widened the constraint rather than dropping it.
    assert!(
        conn.execute(
            "INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
               VALUES ('s3', '0xaa', 'nope', 'cobol', 'x', '2026-02-03T00:00:00Z', '2026-02-03T00:00:00Z')",
            [],
        )
        .is_err(),
        "the CHECK is widened, not removed"
    );

    // And nothing that was there before was lost on the way through.
    let quests: i64 = conn
        .query_row(
            "SELECT count(*) FROM quests WHERE id = 'rust.basic.01.a'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(quests, 1, "the rebuild carried the quests across");
    let snips: i64 = conn
        .query_row("SELECT count(*) FROM snippets WHERE id = 's1'", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(snips, 1, "the rebuild carried the snippets across");

    // The FTS index is rebuilt by the migration, so search still finds the
    // row whose table was dropped and recreated underneath it.
    let hits: i64 = conn
        .query_row(
            "SELECT count(*) FROM quest_fts WHERE quest_fts MATCH 't'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(hits >= 1, "the FTS index came back with the table");
}

#[test]
fn migration_0022_opens_the_seventh_land_and_gives_every_quest_a_language() {
    // 0022 is the first land that is not a language: `remix` joins
    // `quests.land`, and `quests.lang` — the toolchain a quest is judged in
    // — arrives beside it, filled in from `land` for every row that was
    // already there and for every INSERT that does not say. (The "newest
    // migration" pin moved on to 0023's test below.)
    let conn = database_at_version(21);
    conn.execute(
        "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                             starter, solution, tests, checksum)
         VALUES ('go.basic.01.a', 'p', 'go', 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
        [],
    )
    .unwrap();
    assert!(
        conn.execute(
            "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                                 starter, solution, tests, checksum)
             VALUES ('remix.basic.01.a', 'p', 'remix', 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
            [],
        )
        .is_err(),
        "0021 has no remix in its CHECK"
    );

    db::prepare(&conn).unwrap();

    // The row that was there is in the language of its land.
    let lang: String = conn
        .query_row(
            "SELECT lang FROM quests WHERE id = 'go.basic.01.a'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(lang, "go", "0022 fills lang from land for existing rows");

    // A remix quest says its language, and the land is now a land.
    conn.execute(
        "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                             starter, solution, tests, checksum, lang)
         VALUES ('remix.basic.01.a', 'p', 'remix', 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c',
                 'rust')",
        [],
    )
    .expect("quests takes the seventh land with a language");

    // One that does not say is refused: the trigger would write `remix`
    // into `lang`, and `remix` is not a language the runner has.
    assert!(
        conn.execute(
            "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                                 starter, solution, tests, checksum)
             VALUES ('remix.basic.02.b', 'p', 'remix', 'basic', 2, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
            [],
        )
        .is_err(),
        "a remix quest with no lang is refused"
    );
    let count: i64 = conn
        .query_row(
            "SELECT count(*) FROM quests WHERE id = 'remix.basic.02.b'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 0, "the refused row left nothing behind");

    // And a raw INSERT in a language land still needs no `lang`: the
    // trigger fills it, so the fixtures the older tests write keep working.
    conn.execute(
        "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                             starter, solution, tests, checksum)
         VALUES ('python.basic.01.a', 'p', 'python', 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
        [],
    )
    .unwrap();
    let lang: String = conn
        .query_row(
            "SELECT lang FROM quests WHERE id = 'python.basic.01.a'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(lang, "python");

    // `attempts.lang` and `snippets.lang` were not widened: an attempt at a
    // remix quest is filed under the language it was judged in.
    conn.execute(
        "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at, settings)
           VALUES ('0xaa', '0xAA', 'old hand', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '{}')",
        [],
    )
    .unwrap();
    assert!(
        conn.execute(
            "INSERT INTO attempts (id, address, quest_id, lang, source, verdict, created_at)
               VALUES ('a1', '0xaa', 'remix.basic.01.a', 'remix', 'fn main(){}', 'accepted',
                       '2026-02-02T00:00:00Z')",
            [],
        )
        .is_err(),
        "remix is not a language an attempt can be in"
    );
    conn.execute(
        "INSERT INTO attempts (id, address, quest_id, lang, source, verdict, created_at)
           VALUES ('a1', '0xaa', 'remix.basic.01.a', 'rust', 'fn main(){}', 'accepted',
                   '2026-02-02T00:00:00Z')",
        [],
    )
    .expect("an attempt at a remix quest is filed under its language");

    // The FTS index is rebuilt by the migration, so search still finds the
    // row whose table was dropped and recreated underneath it.
    let hits: i64 = conn
        .query_row(
            "SELECT count(*) FROM quest_fts WHERE quest_fts MATCH 't'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(hits >= 1, "the FTS index came back with the table");
}

#[test]
fn the_newest_migration_opens_the_eighth_and_ninth_lands() {
    // The "newest migration" pin: fails loudly if a 0024 is added without a
    // test of its own here. 0023 is two more toolchains, `zig` and `lua`,
    // and to the database that is two names in four CHECK constraints —
    // `quests.land`, `quests.lang`, `attempts.lang`, `snippets.lang` — with
    // everything 0022 built (the `lang` fill-in trigger, the narrowed FTS
    // update trigger) carried across the rebuild.
    let previous = db::MIGRATIONS[db::MIGRATIONS.len() - 2].0;
    assert_eq!(previous, 22);
    let conn = database_at_version(previous);
    conn.execute(
        "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at, settings)
           VALUES ('0xaa', '0xAA', 'old hand', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '{}')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                             starter, solution, tests, checksum, lang)
         VALUES ('remix.basic.01.a', 'p', 'remix', 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c',
                 'go')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
           VALUES ('s1', '0xaa', 'old', 'rust', 'fn main() {}',
                   '2026-02-01T00:00:00Z', '2026-02-01T00:00:00Z')",
        [],
    )
    .unwrap();
    for land in ["zig", "lua"] {
        assert!(
            conn.execute(
                "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                                     starter, solution, tests, checksum)
                 VALUES (?1, 'p', ?2, 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
                rusqlite::params![format!("{land}.basic.01.a"), land],
            )
            .is_err(),
            "0022 has no {land} in its CHECK"
        );
    }

    db::prepare(&conn).unwrap();

    // After it, both are — in all three tables that name a land, and the
    // `lang` trigger fills a new land's rows from its land as it always did.
    for land in ["zig", "lua"] {
        conn.execute(
            "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                                 starter, solution, tests, checksum)
             VALUES (?1, 'p', ?2, 'basic', 1, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
            rusqlite::params![format!("{land}.basic.01.a"), land],
        )
        .unwrap_or_else(|e| panic!("quests takes {land}: {e}"));
        let lang: String = conn
            .query_row(
                "SELECT lang FROM quests WHERE id = ?1",
                [format!("{land}.basic.01.a")],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(lang, land, "the fill-in trigger survived the rebuild");
        conn.execute(
            "INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
               VALUES (?1, '0xaa', 'pad', ?2, 'x', '2026-02-02T00:00:00Z', '2026-02-02T00:00:00Z')",
            rusqlite::params![format!("s_{land}"), land],
        )
        .unwrap_or_else(|e| panic!("snippets takes {land}: {e}"));
        conn.execute(
            "INSERT INTO attempts (id, address, quest_id, lang, source, verdict, created_at)
               VALUES (?1, '0xaa', ?2, ?3, 'x', 'accepted', '2026-02-02T00:00:00Z')",
            rusqlite::params![format!("a_{land}"), format!("{land}.basic.01.a"), land],
        )
        .unwrap_or_else(|e| panic!("attempts takes {land}: {e}"));
    }

    // A remix quest may be judged in one of the new languages too: the
    // widened `lang` CHECK admits it, and one that still does not say is
    // still refused.
    conn.execute(
        "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                             starter, solution, tests, checksum, lang)
         VALUES ('remix.basic.02.b', 'p', 'remix', 'basic', 2, 't', 'b', 's', 1, 's', 's', '{}', 'c',
                 'zig')",
        [],
    )
    .expect("a remix quest may say zig");
    assert!(
        conn.execute(
            "INSERT INTO quests (id, pack, land, category, node, title, brief, story, difficulty,
                                 starter, solution, tests, checksum)
             VALUES ('remix.basic.03.c', 'p', 'remix', 'basic', 3, 't', 'b', 's', 1, 's', 's', '{}', 'c')",
            [],
        )
        .is_err(),
        "a remix quest that does not say its language is still refused"
    );

    // A land that is still not a land is still refused: widened, not removed.
    assert!(
        conn.execute(
            "INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
               VALUES ('s9', '0xaa', 'nope', 'cobol', 'x', '2026-02-03T00:00:00Z', '2026-02-03T00:00:00Z')",
            [],
        )
        .is_err(),
        "the CHECK is widened, not removed"
    );

    // Nothing that was there before was lost, and the FTS index and the
    // `OF`-narrowed update trigger came back with the table: a `lang` change
    // does not touch the index, a title change does.
    let kept: i64 = conn
        .query_row(
            "SELECT count(*) FROM quests WHERE id = 'remix.basic.01.a' AND lang = 'go'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        kept, 1,
        "the rebuild carried the quests across, lang and all"
    );
    let snips: i64 = conn
        .query_row("SELECT count(*) FROM snippets WHERE id = 's1'", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(snips, 1, "the rebuild carried the snippets across");
    conn.execute(
        "UPDATE quests SET lang = 'rust' WHERE id = 'remix.basic.01.a'",
        [],
    )
    .expect("a lang update does not go near the FTS index");
    conn.execute(
        "UPDATE quests SET title = 'lantern' WHERE id = 'lua.basic.01.a'",
        [],
    )
    .unwrap();
    let hits: i64 = conn
        .query_row(
            "SELECT count(*) FROM quest_fts WHERE quest_fts MATCH 'lantern'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(hits, 1, "the FTS update trigger came back with the table");
    let total: i64 = conn
        .query_row("SELECT count(*) FROM quest_fts", [], |r| r.get(0))
        .unwrap();
    let rows: i64 = conn
        .query_row("SELECT count(*) FROM quests", [], |r| r.get(0))
        .unwrap();
    assert_eq!(total, rows, "one FTS row per quest, no more and no fewer");
}
