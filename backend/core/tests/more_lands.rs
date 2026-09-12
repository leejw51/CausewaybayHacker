//! 0008_more_lands: the two new lands get through the importer, and the
//! table rebuild the migration does keeps every row, every index and the
//! search triggers of a database that was already in use.

use cwbhacker_core::{content, db, quests, Store};
use rusqlite::Connection;

const CPP_PACK: &str = include_str!("fixtures/cpp_basic.toml");
const PYTHON_PACK: &str = include_str!("fixtures/python_basic.toml");

#[test]
fn a_cpp_pack_and_a_python_pack_import() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    let conn = store.conn();
    for (land, pack) in [("cpp", CPP_PACK), ("python", PYTHON_PACK)] {
        let dir = tmp.path().join("content-src").join(land);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("basic.toml"), pack).unwrap();
    }
    let report = content::import_dir(&conn, store.home(), &tmp.path().join("content-src")).unwrap();
    assert!(report.failures.is_empty(), "{:?}", report.failures);

    let cpp = quests::list(&conn, "cpp", "basic").unwrap();
    assert_eq!(cpp.len(), 2, "{cpp:?}");
    let python = quests::list(&conn, "python", "basic").unwrap();
    assert_eq!(python.len(), 2, "{python:?}");

    // The build directories the runner will be handed exist already.
    assert!(store.home().build_lang_dir("cpp").is_dir());
    assert!(store.home().build_lang_dir("python").is_dir());
}

#[test]
fn a_land_the_game_does_not_have_is_still_refused() {
    let pack: content::Pack =
        toml::from_str(&CPP_PACK.replace("cpp", "cobol")).expect("the fixture still parses");
    let err = content::validate(&pack).unwrap_err();
    assert!(err.to_string().contains("cobol"), "{err}");
}

/// A database built by 0001..0007 and used — a user, a rust quest with
/// progress, an attempt with a mistake, a snippet — goes through 0008 with
/// everything still there, and then takes a cpp row.
#[test]
fn the_rebuild_keeps_the_rows_the_indexes_and_the_search() {
    let conn = Connection::open_in_memory().unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    for (version, _name, sql) in db::MIGRATIONS.iter().take_while(|m| m.0 < 8) {
        conn.execute_batch(sql).unwrap();
        conn.execute_batch(&format!("PRAGMA user_version = {version}"))
            .unwrap();
    }
    let address = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";
    conn.execute_batch(&format!(
        "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at)
           VALUES ('{address}', '{address}', 'alice', 't', 't');
         INSERT INTO quests (id,pack,land,category,node,title,brief,story,difficulty,starter,solution,tests,checksum)
           VALUES ('rust.basic.01.hello','p','rust','basic',1,'HELLO','print hello','a story',1,'s','s','{{}}','c');
         INSERT INTO progress (address, quest_id, state, updated_at)
           VALUES ('{address}', 'rust.basic.01.hello', 'cleared', 't');
         INSERT INTO attempts (id, address, quest_id, lang, source, verdict, created_at, mode)
           VALUES ('att_1', '{address}', 'rust.basic.01.hello', 'rust', 'fn main(){{}}', 'compile_error', 't', 'run');
         INSERT INTO mistakes (attempt_id, address, quest_id, kind, code, message, created_at)
           VALUES ('att_1', '{address}', 'rust.basic.01.hello', 'unknown-name', 'E0425', 'm', 't');
         INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
           VALUES ('pg_1', '{address}', 'scratch', 'go', 'package main', 't', 't');"
    ))
    .unwrap();
    // The old CHECK really is in the way.
    let refused = conn.execute(
        "INSERT INTO quests (id,pack,land,category,node,title,brief,difficulty,starter,solution,tests,checksum)
           VALUES ('cpp.basic.01.hello','p','cpp','basic',1,'t','b',1,'s','s','{}','c')",
        [],
    );
    assert!(
        refused.is_err(),
        "the CHECK of 0001 should still refuse cpp"
    );

    db::migrate(&conn).unwrap();

    let version: i64 = conn
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert!(version >= 8);
    let fk: i64 = conn
        .query_row("PRAGMA foreign_keys", [], |r| r.get(0))
        .unwrap();
    assert_eq!(fk, 1, "foreign keys must be back on after the migration");

    let count = |sql: &str| -> i64 { conn.query_row(sql, [], |r| r.get(0)).unwrap() };
    assert_eq!(count("SELECT count(*) FROM quests"), 1);
    assert_eq!(count("SELECT count(*) FROM progress"), 1);
    assert_eq!(count("SELECT count(*) FROM attempts WHERE mode = 'run'"), 1);
    assert_eq!(count("SELECT count(*) FROM mistakes"), 1);
    assert_eq!(count("SELECT count(*) FROM snippets WHERE lang = 'go'"), 1);

    // The indexes were put back by name.
    for index in [
        "attempts_by_user",
        "attempts_by_quest",
        "attempts_by_mode",
        "attempts_quest_mode",
        "snippets_by_user",
    ] {
        assert_eq!(
            count(&format!(
                "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = '{index}'"
            )),
            1,
            "index {index} is gone"
        );
    }
    // And the search still finds the old row and notices a new one.
    assert_eq!(
        count("SELECT count(*) FROM quest_fts WHERE quest_fts MATCH 'hello'"),
        1
    );
    conn.execute(
        "INSERT INTO quests (id,pack,land,category,node,title,brief,difficulty,starter,solution,tests,checksum)
           VALUES ('cpp.basic.01.gun','p','cpp','basic',1,'THE NOON DAY GUN','fire',1,'s','s','{}','c')",
        [],
    )
    .unwrap();
    assert_eq!(
        count("SELECT count(*) FROM quest_fts WHERE quest_fts MATCH 'gun'"),
        1,
        "the FTS insert trigger was not recreated"
    );
    conn.execute(
        "INSERT INTO attempts (id, address, quest_id, lang, source, verdict, created_at)
           VALUES ('att_2', ?1, 'cpp.basic.01.gun', 'cpp', 'int main(){}', 'accepted', 't')",
        [address],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
           VALUES ('pg_2', ?1, 'scratch', 'python', 'print(1)', 't', 't')",
        [address],
    )
    .unwrap();
    // Cascades survive the rebuild: deleting the quest takes its attempt.
    conn.execute("DELETE FROM quests WHERE id = 'cpp.basic.01.gun'", [])
        .unwrap();
    assert_eq!(count("SELECT count(*) FROM attempts WHERE id = 'att_2'"), 0);
    assert_eq!(
        count("SELECT count(*) FROM quest_fts WHERE quest_fts MATCH 'gun'"),
        0,
        "the FTS delete trigger was not recreated"
    );
    // A land the game does not have is still refused by the new CHECK.
    let refused = conn.execute(
        "INSERT INTO snippets (id, address, name, lang, source, created_at, updated_at)
           VALUES ('pg_3', ?1, 'scratch', 'cobol', '', 't', 't')",
        [address],
    );
    assert!(refused.is_err());
}
