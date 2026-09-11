//! XP, levels and badges (PLAN.md milestone 3).
//!
//! The rule every test here exists to protect: **nothing is awarded for
//! something that did not happen.** A badge that fires on the wrong thing is
//! worse than one nobody earns, because it makes every other badge mean
//! nothing.

use cwbhacker_core::{attempts, awards, mistakes, progress, users, Store};

const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";
const BOB: &str = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";

/// A store with `n` quests in one category, so a test can clear real rows.
fn store_with(quests: &[(&str, &str, &str, i64)]) -> (tempfile::TempDir, Store) {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    {
        let conn = store.conn();
        for (i, (id, land, category, difficulty)) in quests.iter().enumerate() {
            conn.execute(
                "INSERT INTO quests (id, pack, land, category, node, title, brief, difficulty,
                                     starter, solution, tests, checksum)
                 VALUES (?1, 'p', ?2, ?3, ?4, 't', 'b', ?5, 's', 's', '{}', 'c')",
                rusqlite::params![id, land, category, i as i64 + 1, difficulty],
            )
            .unwrap();
        }
        users::upsert(&conn, ALICE).unwrap();
        users::upsert(&conn, BOB).unwrap();
    }
    (tmp, store)
}

/// Takes the connection briefly and gives it straight back. `Store::conn` is a
/// plain mutex guard and is not reentrant, so a helper that locks must never
/// be called while a caller is holding one.
fn submit(store: &Store, address: &str, quest: &str, verdict: &str) -> String {
    let conn = store.conn();
    let id = cwbhacker_core::ids::attempt_id();
    let mut record = attempts::new_record(
        id.clone(),
        address,
        quest,
        "rust",
        attempts::Mode::Submit,
        "fn main(){}".into(),
    );
    record.verdict = verdict.into();
    attempts::insert(&conn, &record).unwrap();
    id
}

#[test]
fn the_xp_curve_rewards_the_hard_end_of_the_map() {
    // A three-star clear on `first-light` and one on a five-difficulty HACKER
    // quest must not be worth the same, or the far end of the map feels like
    // the near end.
    assert_eq!(awards::xp_for_clear(3, 1, "basic"), 75);
    assert_eq!(awards::xp_for_clear(3, 5, "hacker"), 1125);
    assert_eq!(awards::xp_for_clear(1, 3, "advanced"), 150);
    // Nothing for nothing.
    assert_eq!(awards::xp_for_clear(0, 5, "hacker"), 0);
}

#[test]
fn the_level_curve_climbs() {
    assert_eq!(awards::level_for_xp(0), 1);
    assert_eq!(awards::level_for_xp(99), 1);
    assert_eq!(awards::level_for_xp(100), 2);
    assert_eq!(awards::level_for_xp(299), 2);
    assert_eq!(awards::level_for_xp(300), 3);
    // Each level costs more than the last, and none of them costs nothing.
    let mut previous = 0;
    for level in 2..40 {
        let step = awards::xp_for_level(level) - awards::xp_for_level(level - 1);
        assert!(
            step > previous,
            "level {level} was not dearer than the last"
        );
        previous = step;
    }
}

#[test]
fn xp_is_derived_from_the_record_and_not_from_a_counter() {
    let (_tmp, store) = store_with(&[
        ("rust.basic.01.a", "rust", "basic", 1),
        ("rust.hacker.02.b", "rust", "hacker", 5),
    ]);
    let conn = store.conn();
    assert_eq!(awards::total_xp(&conn, ALICE).unwrap(), 0);

    progress::record_clear(&conn, ALICE, "rust.basic.01.a", 10).unwrap();
    assert_eq!(
        awards::total_xp(&conn, ALICE).unwrap(),
        75,
        "3 stars × 1 × 1"
    );

    progress::record_clear(&conn, ALICE, "rust.hacker.02.b", 10).unwrap();
    assert_eq!(awards::total_xp(&conn, ALICE).unwrap(), 75 + 1125);

    // And it is one player's own.
    assert_eq!(awards::total_xp(&conn, BOB).unwrap(), 0);
}

#[test]
fn nothing_is_awarded_to_a_player_who_has_done_nothing() {
    let (_tmp, store) = store_with(&[("rust.basic.01.a", "rust", "basic", 1)]);
    let conn = store.conn();
    assert!(
        awards::evaluate(&conn, ALICE).unwrap().is_empty(),
        "a fresh player earned something"
    );
    assert!(awards::list(&conn, ALICE).unwrap().is_empty());
}

#[test]
fn an_award_is_granted_once_and_only_once() {
    let (_tmp, store) = store_with(&[("rust.basic.01.a", "rust", "basic", 1)]);
    let conn = store.conn();
    progress::record_clear(&conn, ALICE, "rust.basic.01.a", 10).unwrap();

    let first = awards::evaluate(&conn, ALICE).unwrap();
    assert!(
        first
            .iter()
            .any(|a| a.id == "first-clear" && a.kind == "badge"),
        "{first:?}"
    );
    let granted = first.len();
    assert!(granted > 0);

    // Evaluating again grants nothing: "not re-awarded" is the UNIQUE index's
    // job, not something the caller has to remember.
    for _ in 0..3 {
        assert!(
            awards::evaluate(&conn, ALICE).unwrap().is_empty(),
            "an award was handed out twice"
        );
    }
    assert_eq!(awards::list(&conn, ALICE).unwrap().len(), granted);
}

#[test]
fn a_level_up_is_announced_for_every_level_crossed() {
    let (_tmp, store) = store_with(&[
        ("rust.hacker.01.a", "rust", "hacker", 5),
        ("rust.hacker.02.b", "rust", "hacker", 5),
    ]);
    let conn = store.conn();
    // One 3-star clear on a hard quest is 1125 xp, which is levels 2, 3, 4 and
    // 5 at once. Somebody who jumps four should be told four times rather than
    // silently skipped.
    progress::record_clear(&conn, ALICE, "rust.hacker.01.a", 10).unwrap();
    let fresh = awards::evaluate(&conn, ALICE).unwrap();
    let levels: Vec<&str> = fresh
        .iter()
        .filter(|a| a.kind == "level")
        .map(|a| a.id.as_str())
        .collect();
    assert_eq!(
        levels,
        vec!["level-2", "level-3", "level-4", "level-5"],
        "{fresh:?}"
    );
    assert_eq!(
        awards::level_for_xp(awards::total_xp(&conn, ALICE).unwrap()),
        5
    );
}

/// The combo is defined exactly, because a badge with a fuzzy definition is a
/// badge that fires on the wrong thing.
#[test]
fn the_combo_is_the_current_run_of_accepted_submits() {
    let (_tmp, store) = store_with(&[("rust.basic.01.a", "rust", "basic", 1)]);
    assert_eq!(
        awards::current_combo(&store.conn(), ALICE).unwrap(),
        0,
        "no submits is no combo"
    );

    for _ in 0..3 {
        submit(&store, ALICE, "rust.basic.01.a", "accepted");
    }
    assert_eq!(awards::current_combo(&store.conn(), ALICE).unwrap(), 3);

    // A failure ends it, and the count starts again from there.
    submit(&store, ALICE, "rust.basic.01.a", "wrong_answer");
    assert_eq!(awards::current_combo(&store.conn(), ALICE).unwrap(), 0);
    submit(&store, ALICE, "rust.basic.01.a", "accepted");
    assert_eq!(awards::current_combo(&store.conn(), ALICE).unwrap(), 1);
}

/// A run is not a considered answer (PROTOCOL §4.9b), so it cannot build a
/// combo — otherwise the badge would mean "pressed RUN ten times".
#[test]
fn runs_do_not_build_a_combo() {
    let (_tmp, store) = store_with(&[("rust.basic.01.a", "rust", "basic", 1)]);
    {
        let conn = store.conn();
        for _ in 0..20 {
            let id = cwbhacker_core::ids::attempt_id();
            let mut record = attempts::new_record(
                id,
                ALICE,
                "rust.basic.01.a",
                "rust",
                attempts::Mode::Run,
                "fn main(){}".into(),
            );
            record.verdict = "accepted".into();
            attempts::insert(&conn, &record).unwrap();
        }
    }
    assert_eq!(awards::current_combo(&store.conn(), ALICE).unwrap(), 0);
    let fresh = awards::evaluate(&store.conn(), ALICE).unwrap();
    assert!(
        !fresh.iter().any(|a| a.id.starts_with("combo-")),
        "twenty runs earned a combo: {fresh:?}"
    );
}

#[test]
fn polyglot_needs_both_lands_and_a_finished_map_needs_the_whole_map() {
    let (_tmp, store) = store_with(&[
        ("rust.basic.01.a", "rust", "basic", 1),
        ("rust.basic.02.b", "rust", "basic", 1),
        ("go.basic.01.c", "go", "basic", 1),
    ]);
    let conn = store.conn();
    progress::record_clear(&conn, ALICE, "rust.basic.01.a", 10).unwrap();
    let fresh = awards::evaluate(&conn, ALICE).unwrap();
    assert!(!fresh.iter().any(|a| a.id == "polyglot"));
    assert!(
        !fresh.iter().any(|a| a.id == "cleared-rust-basic"),
        "half a map is not a map"
    );

    progress::record_clear(&conn, ALICE, "rust.basic.02.b", 10).unwrap();
    let fresh = awards::evaluate(&conn, ALICE).unwrap();
    assert!(
        fresh.iter().any(|a| a.id == "cleared-rust-basic"),
        "{fresh:?}"
    );
    assert!(!fresh.iter().any(|a| a.id == "polyglot"));

    progress::record_clear(&conn, ALICE, "go.basic.01.c", 10).unwrap();
    let fresh = awards::evaluate(&conn, ALICE).unwrap();
    assert!(fresh.iter().any(|a| a.id == "polyglot"), "{fresh:?}");
}

/// The one badge that reads the mistake tables: a mistake you used to make
/// five times and have not made in five submits since.
#[test]
fn taming_a_mistake_needs_both_halves() {
    let (_tmp, store) = store_with(&[("rust.basic.01.a", "rust", "basic", 1)]);
    let mistake = mistakes::Mistake {
        kind: "borrow-after-move".into(),
        code: Some("E0382".into()),
        message: "m".into(),
        line: None,
        col: None,
    };
    let made = |store: &Store, kinds: &[mistakes::Mistake]| {
        let verdict = if kinds.is_empty() {
            "accepted"
        } else {
            "compile_error"
        };
        let id = submit(store, ALICE, "rust.basic.01.a", verdict);
        let conn = store.conn();
        mistakes::record(
            &conn,
            &id,
            ALICE,
            "rust.basic.01.a",
            kinds,
            attempts::Mode::Submit,
        )
        .unwrap();
    };

    // Made it four times: not yet a habit worth a badge for breaking.
    for _ in 0..4 {
        made(&store, std::slice::from_ref(&mistake));
    }
    for _ in 0..6 {
        made(&store, &[]);
    }
    let fresh = awards::evaluate(&store.conn(), ALICE).unwrap();
    assert!(
        !fresh.iter().any(|a| a.id.starts_with("tamed-")),
        "four times is not a habit: {fresh:?}"
    );

    // The fifth makes it one, and five clean submits after that break it.
    made(&store, std::slice::from_ref(&mistake));
    for _ in 0..5 {
        made(&store, &[]);
    }
    let fresh = awards::evaluate(&store.conn(), ALICE).unwrap();
    assert!(
        fresh.iter().any(|a| a.id == "tamed-borrow-after-move"),
        "{fresh:?}"
    );
}

#[test]
fn awards_are_one_players_own() {
    let (_tmp, store) = store_with(&[("rust.basic.01.a", "rust", "basic", 1)]);
    let conn = store.conn();
    progress::record_clear(&conn, ALICE, "rust.basic.01.a", 10).unwrap();
    awards::evaluate(&conn, ALICE).unwrap();
    assert!(!awards::list(&conn, ALICE).unwrap().is_empty());
    assert!(
        awards::list(&conn, BOB).unwrap().is_empty(),
        "one player's badges showed up on another's shelf"
    );
}
