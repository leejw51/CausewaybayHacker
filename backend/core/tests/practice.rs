//! `practice::next` — which street the AUTO SELECT button sends a player to.

use std::path::Path;

use cwbhacker_core::{attempts, content, practice, progress, users, Store};
use rand::{rngs::StdRng, SeedableRng};

const PACK: &str = include_str!("fixtures/rust_basic.toml");
const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";

const HELLO: &str = "rust.basic.01.hello";
const SUM: &str = "rust.basic.02.sum";
const SHADOW: &str = "rust.basic.03.shadowing";

fn fixture() -> (tempfile::TempDir, Store) {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), PACK).unwrap();
    let store = Store::open(&tmp.path().join("home")).expect("store opens");
    {
        let conn = store.conn();
        let src: &Path = &tmp.path().join("content-src");
        let report = content::import_dir(&conn, store.home(), src).expect("import");
        assert!(report.failures.is_empty(), "{:?}", report.failures);
        users::upsert(&conn, ALICE).unwrap();
    }
    (tmp, store)
}

fn submit(conn: &cwbhacker_core::Connection, quest: &str, verdict: &str) {
    let mut record = attempts::new_record(
        cwbhacker_core::ids::attempt_id(),
        ALICE,
        quest,
        "rust",
        attempts::Mode::Submit,
        "fn main() {}".into(),
    );
    record.verdict = verdict.into();
    attempts::insert(conn, &record).unwrap();
    if verdict == "accepted" {
        progress::record_clear(conn, ALICE, quest, 100).unwrap();
    }
}

fn pick(conn: &cwbhacker_core::Connection, seed: u64) -> practice::Next {
    practice::next_with(conn, ALICE, "rust", &mut StdRng::seed_from_u64(seed))
        .unwrap()
        .expect("a land with quests always has a next")
}

#[test]
fn the_first_uncleared_quest_in_road_order_comes_first() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    assert_eq!(pick(&conn, 0).quest_id, HELLO);
    assert_eq!(pick(&conn, 0).reason, "first");

    // Clearing out of order still sends them back to the gap.
    submit(&conn, SUM, "accepted");
    assert_eq!(pick(&conn, 0).quest_id, HELLO);
    submit(&conn, HELLO, "wrong_answer");
    submit(&conn, HELLO, "accepted");
    assert_eq!(pick(&conn, 0).quest_id, SHADOW);
}

#[test]
fn once_everything_is_cleared_the_failed_ones_come_back_until_paid() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    submit(&conn, HELLO, "accepted");
    submit(&conn, SUM, "wrong_answer");
    submit(&conn, SUM, "wrong_answer");
    submit(&conn, SUM, "accepted");
    submit(&conn, SHADOW, "accepted");

    // SUM owes two; SHADOW, the last one played, sits out anyway.
    for seed in 0..20 {
        let next = pick(&conn, seed);
        assert_eq!((next.quest_id.as_str(), next.reason), (SUM, "review"));
        assert_eq!(next.owed, 2);
    }
    submit(&conn, SUM, "accepted");
    submit(&conn, HELLO, "accepted"); // SUM is no longer the last one played
    assert_eq!(pick(&conn, 0).owed, 1);
    submit(&conn, SUM, "accepted");
    submit(&conn, HELLO, "accepted");

    // Paid off: now round the land, never straight back to the last one.
    for seed in 0..20 {
        let next = pick(&conn, seed);
        assert_eq!(next.reason, "rotate");
        assert_ne!(next.quest_id, HELLO, "the quest just played sits out");
    }
}

#[test]
fn rotation_goes_round_the_whole_land() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    for q in [HELLO, SUM, SHADOW] {
        submit(&conn, q, "accepted");
    }
    let mut seen = std::collections::HashSet::new();
    for seed in 0..9 {
        let next = pick(&conn, seed);
        submit(&conn, &next.quest_id, "accepted");
        seen.insert(next.quest_id);
    }
    assert_eq!(seen.len(), 3, "{seen:?}");
}

#[test]
fn an_unknown_land_has_no_next() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    assert!(practice::next(&conn, ALICE, "cobol").unwrap().is_none());
}
