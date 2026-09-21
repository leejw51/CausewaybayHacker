//! `world.reset` (PROTOCOL §4.7b): walking one road again from the start.
//!
//! The handler is where the rule lives that a player can actually feel — what
//! a reset clears and, more importantly, what it must not. A reset that took
//! the attempt log with it would delete the curriculum (SPEC §7); one that
//! took the XP would punish practice; one that left the XP *earnable again*
//! would turn the button into a farm. All three are one message, so they are
//! tested here rather than in three places.
use std::sync::Arc;

use cwbhacker_core::{attempts, awards, content, ids, progress, users, Store};
use cwbhacker_server::handlers::{self, Session};
use serde_json::json;

const PACK: &str = include_str!("../../core/tests/fixtures/rust_basic.toml");
const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";

fn state(root: &std::path::Path) -> cwbhacker_server::Shared {
    let src = root.join("content-src");
    std::fs::create_dir_all(src.join("rust")).unwrap();
    std::fs::write(src.join("rust/basic.toml"), PACK).unwrap();
    let store = Arc::new(Store::open(&root.join("home")).expect("store"));
    {
        let conn = store.conn();
        let report = content::import_dir(&conn, store.home(), &src).expect("import");
        assert!(report.failures.is_empty(), "{:?}", report.failures);
        users::upsert(&conn, ALICE).unwrap();
    }
    let config = cwbhacker_server::Config {
        bind: "127.0.0.1:0".parse().unwrap(),
        static_dir: None,
        art_dir: None,
    };
    cwbhacker_server::build_state(store, &config)
}

fn alice() -> Session {
    Session {
        address: Some(ALICE.to_string()),
    }
}

/// The first quest of the fixture pack, cleared the way a submit clears it:
/// the attempt on the record, then the progress row.
fn clear_first(state: &cwbhacker_server::Shared) -> String {
    let conn = state.store.conn();
    let id: String = conn
        .query_row(
            "SELECT id FROM quests WHERE land = 'rust' AND category = 'basic' ORDER BY node LIMIT 1",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let mut record = attempts::new_record(
        ids::attempt_id(),
        ALICE,
        &id,
        "rust",
        attempts::Mode::Submit,
        "fn main(){}".into(),
    );
    record.verdict = "accepted".into();
    attempts::insert(&conn, &record).unwrap();
    progress::record_clear(&conn, ALICE, &id, 10).unwrap();
    id
}

#[test]
fn a_reset_empties_the_road_and_says_what_it_emptied() {
    let tmp = tempfile::tempdir().unwrap();
    let state = state(tmp.path());
    let session = alice();
    let quest = clear_first(&state);

    let before = handlers::world_map(
        &state,
        &session,
        &json!({ "land": "rust", "category": "basic" }),
    )
    .unwrap();
    assert_eq!(before["cleared"], 1);

    let out = handlers::world_reset(
        &state,
        &session,
        &json!({ "land": "rust", "category": "basic" }),
    )
    .unwrap();
    assert_eq!(out["reset"], 1, "one row was this player's");
    assert_eq!(out["cleared"], 0, "the reply carries the road afterwards");
    assert_eq!(out["stars"], 0);
    assert_eq!(out["total"], before["total"]);

    // And the map agrees, which is what the player sees.
    let after = handlers::world_map(
        &state,
        &session,
        &json!({ "land": "rust", "category": "basic" }),
    )
    .unwrap();
    assert_eq!(after["cleared"], 0);
    let node = &after["nodes"].as_array().unwrap()[0];
    assert_eq!(node["quest_id"], quest.as_str());
    assert_eq!(node["state"], "open");
    assert_eq!(node["stars"], 0);
    assert_eq!(node["attempts"], 0);
}

#[test]
fn a_reset_keeps_the_attempts_the_mistakes_and_the_xp() {
    let tmp = tempfile::tempdir().unwrap();
    let state = state(tmp.path());
    let session = alice();
    let quest = clear_first(&state);
    let earned = {
        let conn = state.store.conn();
        awards::total_xp(&conn, ALICE).unwrap()
    };
    assert!(earned > 0, "the clear paid something to begin with");

    handlers::world_reset(
        &state,
        &session,
        &json!({ "land": "rust", "category": "basic" }),
    )
    .unwrap();

    let conn = state.store.conn();
    let attempts_kept: i64 = conn
        .query_row(
            &format!(
                "SELECT count(*) FROM attempts WHERE address = '{ALICE}' AND quest_id = '{quest}'"
            ),
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        attempts_kept, 1,
        "the record of what happened is not a state to reset"
    );
    assert_eq!(
        awards::total_xp(&conn, ALICE).unwrap(),
        earned,
        "XP is history; a reset does not take it back"
    );
}

#[test]
fn clearing_it_again_after_a_reset_pays_no_xp() {
    let tmp = tempfile::tempdir().unwrap();
    let state = state(tmp.path());
    let session = alice();
    let quest = clear_first(&state);
    let earned = {
        let conn = state.store.conn();
        awards::total_xp(&conn, ALICE).unwrap()
    };

    // Reset and clear, three times over: if this paid, the button would be a
    // farm rather than a way to practise.
    for round in 0..3 {
        handlers::world_reset(
            &state,
            &session,
            &json!({ "land": "rust", "category": "basic" }),
        )
        .unwrap();
        let conn = state.store.conn();
        let mut record = attempts::new_record(
            ids::attempt_id(),
            ALICE,
            &quest,
            "rust",
            attempts::Mode::Submit,
            "fn main(){}".into(),
        );
        record.verdict = "accepted".into();
        attempts::insert(&conn, &record).unwrap();
        let row = progress::record_clear(&conn, ALICE, &quest, 10).unwrap();
        assert_eq!(
            row.xp_gained, 0,
            "round {round} paid for the same clear again"
        );
        assert_eq!(
            awards::total_xp(&conn, ALICE).unwrap(),
            earned,
            "round {round}"
        );
        // It still counts as a clear, which is the point of doing it.
        assert!(row.cleared);
    }
}

#[test]
fn a_reset_leaves_every_other_road_alone() {
    let tmp = tempfile::tempdir().unwrap();
    let state = state(tmp.path());
    let session = alice();
    clear_first(&state);

    // A road the pack does not define is `not_found`, not a quiet no-op that
    // reports success — the same answer `world.map` gives.
    let missing = handlers::world_reset(
        &state,
        &session,
        &json!({ "land": "rust", "category": "hacker" }),
    );
    assert!(missing.is_err(), "an undefined road must be refused");

    // And the road that does exist is untouched by that refusal.
    let map = handlers::world_map(
        &state,
        &session,
        &json!({ "land": "rust", "category": "basic" }),
    )
    .unwrap();
    assert_eq!(map["cleared"], 1);
}

#[test]
fn resetting_a_road_nobody_has_touched_is_not_an_error() {
    let tmp = tempfile::tempdir().unwrap();
    let state = state(tmp.path());
    let session = alice();
    let out = handlers::world_reset(
        &state,
        &session,
        &json!({ "land": "rust", "category": "basic" }),
    )
    .unwrap();
    assert_eq!(out["reset"], 0, "nothing to do is not a failure");
    assert_eq!(out["cleared"], 0);
}
