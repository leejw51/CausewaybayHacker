//! The bookmark (SPEC §1.3): one row per player, written from navigation the
//! server already sees, read back at login.
//!
//! The behaviour worth pinning is what happens at the edges — walking back out
//! to a lobby, a quest that a reimport dropped, and two players who must never
//! see each other's place.

use std::path::Path;

use cwbhacker_core::{content, position, users, Store};

const PACK: &str = include_str!("fixtures/rust_basic.toml");
const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";
const BOB: &str = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";
const HELLO: &str = "rust.basic.01.hello";
const SUM: &str = "rust.basic.02.sum";

fn content_dir(root: &Path, pack: &str) -> std::path::PathBuf {
    let dir = root.join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), pack).unwrap();
    root.join("content-src")
}

fn fixture() -> (tempfile::TempDir, Store) {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_dir(tmp.path(), PACK);
    let store = Store::open(&tmp.path().join("home")).unwrap();
    {
        let conn = store.conn();
        let report = content::import_dir(&conn, store.home(), &src).unwrap();
        assert!(report.failures.is_empty(), "{:?}", report.failures);
        users::upsert(&conn, ALICE).unwrap();
        users::upsert(&conn, BOB).unwrap();
    }
    (tmp, store)
}

#[test]
fn a_player_who_has_never_been_anywhere_has_no_place() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    // Not "rust". A client that has never been told where to go should choose
    // for itself, and inventing a land here would be indistinguishable from
    // the player having chosen it.
    assert_eq!(position::get(&conn, ALICE).unwrap(), None);
}

#[test]
fn opening_a_stage_records_the_whole_place_not_just_the_id() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    // AUTO SELECT jumps straight to a quest id with no land in hand, so the
    // land and category have to come from the quest rather than the caller.
    position::mark_quest(&conn, ALICE, HELLO).unwrap();

    let at = position::get(&conn, ALICE).unwrap().expect("a place");
    assert_eq!(at.land, "rust");
    assert_eq!(at.category.as_deref(), Some("basic"));
    assert_eq!(at.quest_id.as_deref(), Some(HELLO));
}

#[test]
fn walking_back_out_to_a_lobby_forgets_the_stage() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    position::mark_quest(&conn, ALICE, HELLO).unwrap();
    position::mark_lobby(&conn, ALICE, "rust", Some("basic")).unwrap();

    let at = position::get(&conn, ALICE).unwrap().unwrap();
    assert_eq!(at.category.as_deref(), Some("basic"));
    // They walked out. Putting them back into the quest they just left would
    // ignore the walk — "I am reading the map" is a real place to be.
    assert_eq!(at.quest_id, None);
}

#[test]
fn it_is_a_bookmark_not_a_history() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    position::mark_quest(&conn, ALICE, HELLO).unwrap();
    position::mark_quest(&conn, ALICE, SUM).unwrap();

    let rows: i64 = conn
        .query_row("SELECT count(*) FROM user_position", [], |r| r.get(0))
        .unwrap();
    assert_eq!(rows, 1, "one row per player, overwritten in place");
    assert_eq!(
        position::get(&conn, ALICE).unwrap().unwrap().quest_id,
        Some(SUM.to_string())
    );
}

#[test]
fn a_bookmark_onto_a_dropped_quest_degrades_to_its_land() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    position::mark_quest(&conn, ALICE, HELLO).unwrap();

    // A reimport without that quest. The row is deliberately not a foreign key
    // onto `quests` — cascading it away would lose the land as well.
    conn.execute("DELETE FROM quests WHERE id = ?1", [HELLO])
        .unwrap();

    let at = position::get(&conn, ALICE).unwrap().expect("still a place");
    assert_eq!(at.land, "rust", "the land outlives the pack");
    assert_eq!(at.category.as_deref(), Some("basic"));
    assert_eq!(
        at.quest_id, None,
        "sending a client to a quest it cannot open is worse than one screen out"
    );
}

#[test]
fn one_players_place_is_never_another_players() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    position::mark_quest(&conn, ALICE, HELLO).unwrap();
    position::mark_lobby(&conn, BOB, "go", None).unwrap();

    assert_eq!(
        position::get(&conn, ALICE)
            .unwrap()
            .unwrap()
            .quest_id
            .as_deref(),
        Some(HELLO)
    );
    let his = position::get(&conn, BOB).unwrap().unwrap();
    assert_eq!(his.land, "go");
    assert_eq!(his.category, None, "a land with no category chosen yet");
}

#[test]
fn clearing_it_puts_them_back_to_having_no_place() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    position::mark_quest(&conn, ALICE, HELLO).unwrap();
    position::clear(&conn, ALICE).unwrap();
    assert_eq!(position::get(&conn, ALICE).unwrap(), None);
}

#[test]
fn marking_a_quest_that_does_not_exist_writes_nothing() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    position::mark_lobby(&conn, ALICE, "rust", Some("basic")).unwrap();
    // The INSERT..SELECT finds no row, so there is nothing to write — and the
    // place they actually had is not destroyed on the way past.
    position::mark_quest(&conn, ALICE, "rust.basic.99.nope").unwrap();

    let at = position::get(&conn, ALICE).unwrap().unwrap();
    assert_eq!(at.category.as_deref(), Some("basic"));
    assert_eq!(at.quest_id, None);
}
