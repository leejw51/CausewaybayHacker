//! A copy of the record is taken at every start, before the migrations.
//!
//! The database is the player's weeks of clears, and it lives in a home
//! directory that a `--home` typo, a moved dotfile or a migration that went
//! wrong can lose in one go. `Store::open` takes a consistent copy first —
//! `VACUUM INTO`, so what sits in the WAL is in the copy too — and keeps the
//! newest `BACKUPS_KEPT`. This is the test that the copy holds the rows, and
//! that the pile does not grow without bound.

use cwbhacker_core::{db, Store};

fn cleared_rows(path: &std::path::Path) -> i64 {
    let conn = rusqlite::Connection::open(path).unwrap();
    conn.query_row(
        "SELECT count(*) FROM progress WHERE state = 'cleared'",
        [],
        |r| r.get(0),
    )
    .unwrap()
}

fn backups(home: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut out: Vec<_> = std::fs::read_dir(home.join("backups"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    out.sort();
    out
}

#[test]
fn the_second_start_backs_up_what_the_first_wrote() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");

    // A fresh home has nothing to copy, and says so by copying nothing.
    let store = Store::open(&home).unwrap();
    assert!(
        backups(&home).is_empty(),
        "an empty database is not backed up"
    );
    {
        let conn = store.conn();
        // No content is imported here, so the quest the row names does not
        // exist; the copy is what is under test, not the reference.
        conn.pragma_update(None, "foreign_keys", "OFF").unwrap();
        conn.execute(
            "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at)
             VALUES ('0xabc', '0xABC', 'tester', 'now', 'now')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO progress (address, quest_id, state, stars, attempts, updated_at)
             VALUES ('0xabc', 'rust.basic.01.first-light', 'cleared', 2, 1, 'now')",
            [],
        )
        .unwrap();
    }
    drop(store);

    // The next start copies the database as the last one left it.
    let _again = Store::open(&home).unwrap();
    let copies = backups(&home);
    assert_eq!(copies.len(), 1, "one start, one copy");
    assert_eq!(cleared_rows(&copies[0]), 1, "the copy holds the clear");
}

#[test]
fn only_the_newest_copies_are_kept() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let store = Store::open(&home).unwrap();
    store
        .conn()
        .execute(
            "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at)
             VALUES ('0xabc', '0xABC', 'tester', 'now', 'now')",
            [],
        )
        .unwrap();
    drop(store);
    for i in 0..(db::BACKUPS_KEPT + 3) {
        // Distinct names: the stamp is to the second, and a test takes less.
        let copy = home
            .join("backups")
            .join(format!("hacker-2000010100000{i}Z.db"));
        std::fs::write(&copy, b"old").unwrap();
    }
    let _again = Store::open(&home).unwrap();
    assert_eq!(
        backups(&home).len(),
        db::BACKUPS_KEPT,
        "the pile is pruned to the newest"
    );
}
