//! AI mode (SPEC §7.3).
//!
//! The two rules that shape every test here: a drill is a **fixed ordered
//! list**, so a reconnect resumes the same session; and a drill is **never
//! empty and silent** — if there is nothing to teach, it says what that means.

use cwbhacker_core::{attempts, content, drills, mistakes, progress, users, Store};

const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";
const BOB: &str = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";

/// Quests with real concepts from `docs/concepts.md`, because `weakness` joins
/// through that vocabulary and a made-up slug would reach nothing.
fn pack() -> String {
    let quests = [
        (1, "hello", "io"),
        (2, "the-move", "ownership"),
        (3, "borrowing", "borrowing"),
        (4, "closures", "closures"),
        (5, "boxes", "smart-pointers"),
        (6, "types", "types"),
    ];
    let mut out =
        String::from("pack = \"rust.basic\"\nland = \"rust\"\ncategory = \"basic\"\nversion = 1\n");
    for (node, slug, concept) in quests {
        out.push_str(&format!(
            r#"
[[quest]]
id          = "rust.basic.{node:02}.{slug}"
node        = {node}
title       = "{slug}"
difficulty  = 1
story       = "a street"
concepts    = ["{concept}"]
requires    = []
map         = {{ x = 0.1, y = 0.1, kind = "quest" }}
brief       = '''
Do the {slug} thing.
'''
starter     = '''
fn main() {{}}
'''
solution    = '''
fn main() {{ println!("{slug}"); }}
'''
hints = []

[quest.tests]
harness      = "stdio"
timeout_ms   = 5000
match        = "trim"
cases = [
  {{ name = "says", stdin = "", expect = "{slug}\n", visible = true }},
]
"#
        ));
    }
    out
}

fn store() -> (tempfile::TempDir, Store) {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), pack()).unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    {
        let conn = store.conn();
        let report =
            content::import_dir(&conn, store.home(), &tmp.path().join("content-src")).unwrap();
        assert!(report.failures.is_empty(), "{:?}", report.failures);
        users::upsert(&conn, ALICE).unwrap();
        users::upsert(&conn, BOB).unwrap();
    }
    (tmp, store)
}

fn submit(store: &Store, quest: &str, verdict: &str, kinds: &[&str]) {
    let id = cwbhacker_core::ids::attempt_id();
    let conn = store.conn();
    let mut record = attempts::new_record(
        id.clone(),
        ALICE,
        quest,
        "rust",
        attempts::Mode::Submit,
        "fn main(){}".into(),
    );
    record.verdict = verdict.into();
    attempts::insert(&conn, &record).unwrap();
    let found: Vec<mistakes::Mistake> = kinds
        .iter()
        .map(|kind| mistakes::Mistake {
            kind: (*kind).to_string(),
            code: Some("E0382".into()),
            message: "m".into(),
            line: None,
            col: None,
        })
        .collect();
    mistakes::record(&conn, &id, ALICE, quest, &found, attempts::Mode::Submit).unwrap();
}

#[test]
fn repeat_is_the_quests_you_have_failed_most() {
    let (_tmp, store) = store();
    for _ in 0..3 {
        submit(&store, "rust.basic.02.the-move", "compile_error", &[]);
    }
    submit(&store, "rust.basic.04.closures", "wrong_answer", &[]);
    submit(&store, "rust.basic.01.hello", "accepted", &[]);

    let conn = store.conn();
    let drill = drills::create(&conn, ALICE, drills::Mode::Repeat, None, 5).unwrap();
    assert_eq!(
        drill.plan,
        vec![
            "rust.basic.02.the-move".to_string(),
            "rust.basic.04.closures".to_string()
        ],
        "most-failed first, and a quest you passed is not in it"
    );
    assert!(drill.reason.contains("3 times"), "{}", drill.reason);
}

/// The one that actually teaches: it finds the kind and hands over other
/// shapes of the same idea — **including quests already cleared**.
#[test]
fn weakness_joins_through_the_concept_vocabulary() {
    let (_tmp, store) = store();
    for _ in 0..6 {
        submit(
            &store,
            "rust.basic.02.the-move",
            "compile_error",
            &["borrow-after-move"],
        );
    }
    {
        // Clearing it must not take it out of the drill — a player getting
        // good is exactly when they need the other shapes.
        let conn = store.conn();
        progress::record_clear(&conn, ALICE, "rust.basic.02.the-move", 10).unwrap();
    }

    let conn = store.conn();
    let drill = drills::create(&conn, ALICE, drills::Mode::Weakness, None, 5).unwrap();
    // borrow-after-move → ownership, borrowing, closures, smart-pointers.
    assert!(
        drill.plan.contains(&"rust.basic.02.the-move".to_string()),
        "{drill:?}"
    );
    assert!(drill.plan.contains(&"rust.basic.03.borrowing".to_string()));
    assert!(drill.plan.contains(&"rust.basic.04.closures".to_string()));
    assert!(drill.plan.contains(&"rust.basic.05.boxes".to_string()));
    assert!(
        !drill.plan.contains(&"rust.basic.06.types".to_string()),
        "`types` is not in borrow-after-move's row: {drill:?}"
    );
    assert!(
        drill.reason.contains("use after move") && drill.reason.contains("6 times"),
        "the reason is the product: {}",
        drill.reason
    );
}

/// A kind that §7.2 has retired (`cleared_since >= 5`) drops out of the plan —
/// the mechanism `tamed-<kind>` also depends on.
#[test]
fn a_learned_kind_leaves_the_weakness_plan() {
    let (_tmp, store) = store();
    for _ in 0..6 {
        submit(
            &store,
            "rust.basic.02.the-move",
            "compile_error",
            &["borrow-after-move"],
        );
    }
    {
        let conn = store.conn();
        let drill = drills::create(&conn, ALICE, drills::Mode::Weakness, None, 5).unwrap();
        assert!(drill.reason.contains("use after move"), "{}", drill.reason);
    }
    // Five clean submits: §7.2 calls that learned.
    for _ in 0..5 {
        submit(&store, "rust.basic.01.hello", "accepted", &[]);
    }
    let conn = store.conn();
    let cleared_since: i64 = conn
        .query_row(
            "SELECT cleared_since FROM mistake_stats WHERE address = ?1 AND kind = ?2",
            rusqlite::params![ALICE, "borrow-after-move"],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(cleared_since, 5);
    let drill = drills::create(&conn, ALICE, drills::Mode::Weakness, None, 5).unwrap();
    assert!(
        !drill.reason.contains("use after move"),
        "a learned kind is still being drilled: {}",
        drill.reason
    );
}

#[test]
fn spaced_brings_back_what_has_faded() {
    let (_tmp, store) = store();
    let conn = store.conn();
    // Three stars comes back in 14 days, one star in 2 (SPEC §7.3).
    assert_eq!(drills::review_interval_days(3), 14);
    assert_eq!(drills::review_interval_days(1), 2);

    progress::record_clear(&conn, ALICE, "rust.basic.01.hello", 10).unwrap();
    progress::record_clear(&conn, ALICE, "rust.basic.02.the-move", 10).unwrap();
    // Cleared long ago with one star: overdue. Cleared just now: not.
    let long_ago =
        cwbhacker_core::time::stamp(cwbhacker_core::time::now() - chrono::Duration::days(30));
    conn.execute(
        "UPDATE progress SET first_clear_at = ?3, stars = 1
          WHERE address = ?1 AND quest_id = ?2",
        rusqlite::params![ALICE, "rust.basic.01.hello", long_ago],
    )
    .unwrap();

    let drill = drills::create(&conn, ALICE, drills::Mode::Spaced, None, 5).unwrap();
    assert_eq!(
        drill.plan,
        vec!["rust.basic.01.hello".to_string()],
        "{drill:?}"
    );
    assert!(drill.reason.contains("due for review"), "{}", drill.reason);
}

/// A plan is fixed at creation. A reconnect must resume the same session
/// rather than reshuffling under the player.
#[test]
fn a_plan_is_fixed_and_a_reconnect_resumes_it() {
    let (_tmp, store) = store();
    for _ in 0..2 {
        submit(&store, "rust.basic.02.the-move", "compile_error", &[]);
    }
    let conn = store.conn();
    let drill = drills::create(&conn, ALICE, drills::Mode::Repeat, None, 5).unwrap();
    let plan = drill.plan.clone();

    let step = drills::next(&conn, ALICE, &drill.id).unwrap();
    assert_eq!(step.position, 1);
    assert_eq!(step.quest_id, plan[0]);
    assert!(step.why.contains("2 times"), "{}", step.why);

    // The world changes underneath it — and the plan does not.
    submit(&store, "rust.basic.04.closures", "compile_error", &[]);
    submit(&store, "rust.basic.04.closures", "compile_error", &[]);
    submit(&store, "rust.basic.04.closures", "compile_error", &[]);
    let resumed = drills::get(&conn, ALICE, &drill.id).unwrap();
    assert_eq!(resumed.plan, plan);
    assert_eq!(resumed.cursor, 1, "the cursor survived");
    assert_eq!(resumed.reason, drill.reason);

    // Walking off the end is `not_found`, not a panic and not a loop.
    for _ in 0..plan.len() {
        let _ = drills::next(&conn, ALICE, &drill.id);
    }
    assert!(drills::next(&conn, ALICE, &drill.id).is_err());
}

/// Never empty and never silent — and not the same three lists for somebody
/// who has just arrived.
#[test]
fn a_new_player_gets_three_different_answers() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let mut plans = Vec::new();
    for mode in [
        drills::Mode::Repeat,
        drills::Mode::Weakness,
        drills::Mode::Spaced,
    ] {
        let drill = drills::create(&conn, ALICE, mode, None, 5).unwrap();
        assert!(
            !drill.reason.trim().is_empty(),
            "{mode:?} came back without saying why"
        );
        plans.push((mode, drill.plan));
    }
    // `spaced` has nothing to review and says so; the other two have
    // something to offer and they are not the same something.
    let repeat = &plans[0].1;
    let weakness = &plans[1].1;
    let spaced = &plans[2].1;
    assert!(!repeat.is_empty(), "repeat gave a new player nothing");
    assert!(!weakness.is_empty(), "weakness gave a new player nothing");
    assert_ne!(
        repeat, weakness,
        "the modes collapsed to the same list for a new player"
    );
    assert!(
        spaced.is_empty(),
        "nothing has been cleared, so there is genuinely nothing to review"
    );
}

#[test]
fn a_finished_drill_reports_what_actually_happened() {
    let (_tmp, store) = store();
    for _ in 0..2 {
        submit(
            &store,
            "rust.basic.02.the-move",
            "compile_error",
            &["borrow-after-move"],
        );
    }
    let drill = {
        let conn = store.conn();
        drills::create(&conn, ALICE, drills::Mode::Repeat, None, 5).unwrap()
    };
    // During the drill: one attempt, and it passes.
    submit(&store, "rust.basic.02.the-move", "accepted", &[]);

    let conn = store.conn();
    let summary = drills::finish(&conn, ALICE, &drill.id).unwrap();
    assert_eq!(summary.attempted, 1);
    assert_eq!(summary.cleared, 1);
    assert_eq!(
        summary.kinds_improved,
        vec!["borrow-after-move".to_string()],
        "a kind made before and not since is an improvement, and it is measured"
    );
    assert!(drills::get(&conn, ALICE, &drill.id)
        .unwrap()
        .finished_at
        .is_some());
}

#[test]
fn a_drill_belongs_to_one_player() {
    let (_tmp, store) = store();
    submit(&store, "rust.basic.02.the-move", "compile_error", &[]);
    let conn = store.conn();
    let drill = drills::create(&conn, ALICE, drills::Mode::Repeat, None, 5).unwrap();
    assert!(drills::get(&conn, BOB, &drill.id).is_err());
    assert!(drills::next(&conn, BOB, &drill.id).is_err());
    assert!(drills::finish(&conn, BOB, &drill.id).is_err());
}
