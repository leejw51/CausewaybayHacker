//! `users/<address>/progress.json` — what goes in it, and what "weakest" means.
//!
//! The file is a mirror, so most of what is worth asserting is that it agrees
//! with the database it was built from. The part that is a judgement rather
//! than a copy is the ranking, and that is where most of these tests are: the
//! obvious ranking (raw failure count) returns the quests a player has
//! *practised* most, which for anyone working steadily through a land is
//! simply the ones they have reached.

use std::path::Path;

use cwbhacker_core::{attempts, content, progress, snapshot, users, Store};

const PACK: &str = include_str!("fixtures/rust_basic.toml");
const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";
const BOB: &str = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";

const HELLO: &str = "rust.basic.01.hello";
const SUM: &str = "rust.basic.02.sum";
const SHADOW: &str = "rust.basic.03.shadowing";

fn content_dir(root: &Path, pack: &str) -> std::path::PathBuf {
    let dir = root.join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), pack).unwrap();
    root.join("content-src")
}

fn open_and_import(home: &Path, content_src: &Path) -> Store {
    let store = Store::open(home).expect("store opens");
    let conn = store.conn();
    let report = content::import_dir(&conn, store.home(), content_src).expect("import");
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    drop(conn);
    store
}

fn fixture() -> (tempfile::TempDir, Store) {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_dir(tmp.path(), PACK);
    let store = open_and_import(&tmp.path().join("home"), &src);
    {
        let conn = store.conn();
        users::upsert(&conn, ALICE).unwrap();
        users::upsert(&conn, BOB).unwrap();
    }
    (tmp, store)
}

/// One submit with the given verdict.
fn submit(conn: &cwbhacker_core::Connection, address: &str, quest: &str, verdict: &str) {
    let mut record = attempts::new_record(
        cwbhacker_core::ids::attempt_id(),
        address,
        quest,
        "rust",
        attempts::Mode::Submit,
        "fn main() {}".into(),
    );
    record.verdict = verdict.into();
    attempts::insert(conn, &record).unwrap();
}

/// A RUN, which is deliberately not a failure however it went (PROTOCOL §4.9b).
fn run(conn: &cwbhacker_core::Connection, address: &str, quest: &str, verdict: &str) {
    let mut record = attempts::new_record(
        cwbhacker_core::ids::attempt_id(),
        address,
        quest,
        "rust",
        attempts::Mode::Run,
        "fn main() {}".into(),
    );
    record.verdict = verdict.into();
    attempts::insert(conn, &record).unwrap();
}

#[test]
fn an_account_that_has_done_nothing_has_no_position_and_no_weakness() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    let snap = snapshot::build(&conn, ALICE).unwrap();

    // Not "at the start of rust" — that is a different claim, and inventing it
    // would put a player on a map they have never opened.
    assert!(snap.position.is_none());
    assert!(snap.weakest.is_empty());
    assert!(snap.quests.is_empty(), "untouched quests are not listed");
    assert_eq!(snap.totals.cleared, 0);
}

#[test]
fn position_is_the_quest_last_worked_on() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    submit(&conn, ALICE, HELLO, "accepted");
    progress::record_clear(&conn, ALICE, HELLO, 100).unwrap();
    submit(&conn, ALICE, SUM, "wrong_answer");

    let snap = snapshot::build(&conn, ALICE).unwrap();
    let pos = snap.position.expect("a position");
    assert_eq!(pos.quest_id.as_deref(), Some(SUM));
    assert_eq!(pos.land, "rust");
    assert_eq!(pos.category.as_deref(), Some("basic"));
    assert_eq!(pos.node, Some(2));
    assert_eq!(pos.cleared, Some(false), "they are still on it");
}

#[test]
fn a_run_is_never_counted_as_a_failure() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    // Iterating honestly with the RUN button must not read as failing.
    for _ in 0..8 {
        run(&conn, ALICE, HELLO, "wrong_answer");
    }
    let snap = snapshot::build(&conn, ALICE).unwrap();
    assert!(snap.weakest.is_empty(), "{:?}", snap.weakest);
    let hello = snap.quests.iter().find(|q| q.quest_id == HELLO).unwrap();
    assert_eq!(hello.submits, 0);
    assert_eq!(hello.failures, 0);
}

#[test]
fn a_quest_they_are_stuck_on_outranks_one_they_failed_more_but_cleared() {
    let (_tmp, store) = fixture();
    let conn = store.conn();

    // Cleared, but expensive: six failures before it went green.
    for _ in 0..6 {
        submit(&conn, ALICE, HELLO, "wrong_answer");
    }
    submit(&conn, ALICE, HELLO, "accepted");
    progress::record_clear(&conn, ALICE, HELLO, 100).unwrap();

    // Still beating them, on fewer failures.
    for _ in 0..2 {
        submit(&conn, ALICE, SUM, "wrong_answer");
    }

    let weak = snapshot::weakest(&conn, ALICE, 10).unwrap();
    assert_eq!(weak.len(), 2);
    // This is the whole point of the two groups: raw count would put HELLO
    // first, and HELLO is the one they have already beaten.
    assert_eq!(weak[0].quest_id, SUM);
    assert_eq!(weak[0].reason, "stuck");
    assert_eq!(weak[1].quest_id, HELLO);
    assert_eq!(weak[1].reason, "costly");
}

#[test]
fn within_a_group_more_failures_come_first_then_the_higher_rate() {
    let (_tmp, store) = fixture();
    let conn = store.conn();

    // Four failures out of four.
    for _ in 0..4 {
        submit(&conn, ALICE, SUM, "wrong_answer");
    }
    // Four failures out of eight — the same count, a kinder record.
    for _ in 0..4 {
        submit(&conn, ALICE, SHADOW, "wrong_answer");
    }
    for _ in 0..4 {
        submit(&conn, ALICE, SHADOW, "accepted");
    }

    let weak = snapshot::weakest(&conn, ALICE, 10).unwrap();
    assert_eq!(weak[0].quest_id, SUM, "tied on failures, worse rate first");
    assert_eq!(weak[0].failure_rate, 1.0);
    assert_eq!(weak[1].quest_id, SHADOW);
    assert_eq!(weak[1].failure_rate, 0.5);
}

#[test]
fn a_quest_never_failed_is_not_weakness() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    submit(&conn, ALICE, HELLO, "accepted");
    progress::record_clear(&conn, ALICE, HELLO, 100).unwrap();

    assert!(snapshot::weakest(&conn, ALICE, 10).unwrap().is_empty());
}

#[test]
fn the_ranking_is_total_so_the_file_does_not_churn() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    // Two quests tied on every count must not swap between writes.
    for quest in [SUM, SHADOW] {
        for _ in 0..3 {
            submit(&conn, ALICE, quest, "wrong_answer");
        }
    }
    let first = snapshot::weakest(&conn, ALICE, 10).unwrap();
    for _ in 0..5 {
        let again = snapshot::weakest(&conn, ALICE, 10).unwrap();
        let ids: Vec<_> = again.iter().map(|w| &w.quest_id).collect();
        let want: Vec<_> = first.iter().map(|w| &w.quest_id).collect();
        assert_eq!(ids, want);
    }
}

#[test]
fn one_players_record_never_includes_another() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    for _ in 0..3 {
        submit(&conn, BOB, SUM, "wrong_answer");
    }
    submit(&conn, ALICE, HELLO, "accepted");
    progress::record_clear(&conn, ALICE, HELLO, 100).unwrap();

    let snap = snapshot::build(&conn, ALICE).unwrap();
    assert!(snap.weakest.is_empty(), "BOB's failures are not ALICE's");
    assert!(snap.quests.iter().all(|q| q.quest_id != SUM));
    assert_eq!(snapshot::weakest(&conn, BOB, 10).unwrap().len(), 1);
}

#[test]
fn the_undo_stack_is_referenced_not_copied() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    let home = store.home();

    cwbhacker_core::edits::push(&conn, home, ALICE, HELLO, "fn main() { /* a */ }").unwrap();
    cwbhacker_core::edits::push(&conn, home, ALICE, HELLO, "fn main() { /* b */ }").unwrap();
    let after_undo = cwbhacker_core::edits::undo(&conn, home, ALICE, HELLO).unwrap();

    let snap = snapshot::build(&conn, ALICE).unwrap();
    let hello = snap.quests.iter().find(|q| q.quest_id == HELLO).unwrap();
    // The same numbers `edit.state` would give the client, from the same rows.
    assert_eq!(hello.edits.depth, 2);
    assert_eq!(hello.edits.cursor, after_undo.cursor);
    assert_eq!(hello.edits.can_undo, after_undo.can_undo);
    assert_eq!(hello.edits.can_redo, after_undo.can_redo);

    // And the sources stay where SPEC §2.3 puts them: `prune` may drop that
    // tree, and nothing in `users/` should break when it does.
    let json = serde_json::to_string(&snap).unwrap();
    assert!(
        !json.contains("/* a */") && !json.contains("/* b */"),
        "progress.json must not carry a copy of the edit sources"
    );
}

#[test]
fn writing_it_leaves_an_owner_only_file_that_matches_the_database() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    let home = store.home();
    for _ in 0..2 {
        submit(&conn, ALICE, SUM, "wrong_answer");
    }
    submit(&conn, ALICE, HELLO, "accepted");
    progress::record_clear(&conn, ALICE, HELLO, 100).unwrap();

    snapshot::write(&conn, home, ALICE).unwrap();

    let path = home.progress_path(ALICE);
    assert!(path.exists(), "progress.json is beside profile.json");
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "everything in the home is owner-only");
    }

    // Readable without sqlite, which is the whole point of the file.
    let text = std::fs::read_to_string(&path).unwrap();
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(v["address"], ALICE);
    assert_eq!(v["totals"]["cleared"], 1);
    assert_eq!(v["position"]["quest_id"], HELLO);
    assert_eq!(v["weakest"][0]["quest_id"], SUM);
    assert_eq!(v["weakest"][0]["reason"], "stuck");
}

#[test]
fn the_address_in_the_file_is_the_lowercase_one_the_directory_uses() {
    let (_tmp, store) = fixture();
    let conn = store.conn();
    let home = store.home();
    let mixed = "0x9D8A62F656A8D1615C1294FD71E9CFB3E4855A4F";
    snapshot::write(&conn, home, mixed).unwrap();

    // Two spellings of one wallet must not become two directories (SPEC §3.4).
    let text = std::fs::read_to_string(home.progress_path(mixed)).unwrap();
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(v["address"], ALICE);
}
