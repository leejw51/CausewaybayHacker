//! Interview mode (PROTOCOL §4.9e).
//!
//! The rules that make it an interview rather than a quest wearing a hat: no
//! hints and no reference answer for the whole session, the approach written
//! first and never graded, and a clock that records rather than stops you.

use cwbhacker_core::{attempts, content, interviews, progress, quests, users, Store};

const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";
const BOB: &str = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";

fn pack(category: &str, timed: bool) -> String {
    let mut out = format!(
        "pack = \"rust.{category}\"\nland = \"rust\"\ncategory = \"{category}\"\nversion = 1\n"
    );
    for node in 1..=3 {
        let limit = if timed {
            format!("time_limit_s = {}\n", 600 * node)
        } else {
            String::new()
        };
        let hidden = if timed {
            r#"  { name = "hidden", stdin = "", expect = "x\n", visible = false },"#
        } else {
            ""
        };
        out.push_str(&format!(
            r#"
[[quest]]
id          = "rust.{category}.{node:02}.q{node}"
node        = {node}
title       = "QUEST {node}"
difficulty  = 3
story       = "a street"
concepts    = ["hashing", "complexity"]
requires    = []
map         = {{ x = 0.1, y = 0.1, kind = "quest" }}
{limit}brief       = '''
Solve number {node}.
'''
starter     = '''
fn main() {{}}
'''
solution    = '''
// Count with a map, then walk it once.
fn main() {{ println!("q{node}"); }}
'''
hints = [ "a hint nobody in an interview gets", "another one" ]

[quest.tests]
harness      = "stdio"
timeout_ms   = 5000
match        = "trim"
cases = [
  {{ name = "says", stdin = "", expect = "q{node}\n", visible = true }},
{hidden}
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
    std::fs::write(dir.join("hacker.toml"), pack("hacker", true)).unwrap();
    std::fs::write(dir.join("basic.toml"), pack("basic", false)).unwrap();
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

#[test]
fn a_session_starts_a_clock_on_a_quest_you_have_not_cleared() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let session = interviews::start(&conn, ALICE, "rust", Some("hacker")).unwrap();
    assert!(session.id.starts_with("int_"));
    assert!(session.deadline_at.is_some(), "a hacker quest is timed");
    assert!(session.approach.is_none());
    assert!(session.finished_at.is_none());
    // The quest's own clock started too, so a submit carries `within_limit`.
    let row = progress::get(&conn, ALICE, &session.quest_id).unwrap();
    assert_eq!(row.opened_at.as_deref(), Some(session.opened_at.as_str()));

    // A cleared quest is not offered.
    for node in 1..=3 {
        progress::record_clear(&conn, ALICE, &format!("rust.hacker.{node:02}.q{node}"), 10)
            .unwrap();
    }
    let err = interviews::start(&conn, ALICE, "rust", Some("hacker")).unwrap_err();
    assert!(err.message.contains("cleared every"), "{}", err.message);
}

/// Timed quests first: a screen with a clock on it is the thing being
/// rehearsed.
#[test]
fn a_timed_quest_is_preferred_when_the_category_is_not_named() {
    let (_tmp, store) = store();
    let conn = store.conn();
    for _ in 0..6 {
        let session = interviews::start(&conn, ALICE, "rust", None).unwrap();
        assert!(
            session.quest_id.starts_with("rust.hacker."),
            "picked an untimed quest while timed ones were free: {}",
            session.quest_id
        );
        assert!(session.deadline_at.is_some());
    }
}

/// The feature. Kept verbatim, never graded, handed back at the end.
#[test]
fn the_approach_is_written_first_and_never_graded() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let session = interviews::start(&conn, ALICE, "rust", Some("hacker")).unwrap();
    assert!(
        session.approach_at.is_none(),
        "the editor should not be unlocked before a word is written"
    );

    let words = "  Sort by end time, then take greedily. O(n log n) for the sort, O(n) after.  ";
    let after = interviews::set_approach(&conn, ALICE, &session.id, words).unwrap();
    assert_eq!(after.approach.as_deref(), Some(words.trim()));
    assert!(after.approach_at.is_some(), "the editor unlocks now");

    // Refining the words does not pretend they were written later.
    let stamped = after.approach_at.clone();
    let refined =
        interviews::set_approach(&conn, ALICE, &session.id, "Sort by end. Greedy.").unwrap();
    assert_eq!(refined.approach_at, stamped);
    assert_eq!(refined.approach.as_deref(), Some("Sort by end. Greedy."));

    // An empty approach is refused, because writing it is the exercise.
    assert!(interviews::set_approach(&conn, ALICE, &session.id, "   ").is_err());
}

#[test]
fn one_live_session_per_player() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let first = interviews::start(&conn, ALICE, "rust", Some("hacker")).unwrap();
    let second = interviews::start(&conn, ALICE, "rust", Some("hacker")).unwrap();
    assert_ne!(first.id, second.id);

    let abandoned = interviews::get(&conn, ALICE, &first.id).unwrap();
    assert!(
        abandoned.finished_at.is_some(),
        "starting another must finish the first — walking out is a thing that happened"
    );
    assert_eq!(
        interviews::live(&conn, ALICE).unwrap().map(|s| s.id),
        Some(second.id)
    );
}

/// The clock records; it does not stop you (§4.8b).
#[test]
fn running_out_of_time_does_not_end_the_session() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let session = interviews::start(&conn, ALICE, "rust", Some("hacker")).unwrap();
    let long_ago =
        cwbhacker_core::time::stamp(cwbhacker_core::time::now() - chrono::Duration::hours(5));
    conn.execute(
        "UPDATE interviews SET opened_at = ?2 WHERE id = ?1",
        rusqlite::params![session.id, long_ago],
    )
    .unwrap();
    conn.execute(
        "UPDATE progress SET opened_at = ?3 WHERE address = ?1 AND quest_id = ?2",
        rusqlite::params![ALICE, session.quest_id, long_ago],
    )
    .unwrap();

    let still_live = interviews::live(&conn, ALICE).unwrap().unwrap();
    assert!(
        still_live.finished_at.is_none(),
        "the buzzer closed the session"
    );
    // …and the fact is recorded rather than enforced.
    let quest = quests::get(&conn, &session.quest_id).unwrap();
    assert_eq!(
        progress::within_limit(Some(&long_ago), quest.time_limit_s),
        Some(false)
    );
}

#[test]
fn the_report_is_the_product() {
    let (_tmp, store) = store();
    let session = {
        let conn = store.conn();
        let session = interviews::start(&conn, ALICE, "rust", Some("hacker")).unwrap();
        interviews::set_approach(&conn, ALICE, &session.id, "Count with a map.").unwrap();
        session
    };

    // Two submits during the session: one wrong, one right.
    for verdict in ["compile_error", "accepted"] {
        let conn = store.conn();
        let id = cwbhacker_core::ids::attempt_id();
        let mut record = attempts::new_record(
            id.clone(),
            ALICE,
            &session.quest_id,
            "rust",
            attempts::Mode::Submit,
            "fn main(){}".into(),
        );
        record.verdict = verdict.into();
        record.within_limit = Some(true);
        attempts::insert(&conn, &record).unwrap();
        if verdict == "compile_error" {
            cwbhacker_core::mistakes::record(
                &conn,
                &id,
                ALICE,
                &session.quest_id,
                &[cwbhacker_core::mistakes::Mistake {
                    kind: "type-mismatch".into(),
                    code: Some("E0308".into()),
                    message: "m".into(),
                    line: None,
                    col: None,
                }],
                attempts::Mode::Submit,
            )
            .unwrap();
        }
    }

    let conn = store.conn();
    let report = interviews::finish(&conn, ALICE, &session.id).unwrap();
    assert_eq!(report.session_id, session.id);
    assert!(report.cleared);
    assert_eq!(report.within_limit, Some(true));
    // The pick is randomised among the timed quests, so the limit is checked
    // against the quest that was actually picked rather than a constant.
    let picked = quests::get(&conn, &session.quest_id).unwrap();
    assert_eq!(report.limit_ms, picked.time_limit_s.map(|s| s * 1000));
    assert!(report.limit_ms.is_some(), "a hacker quest is timed");
    assert!(report.took_ms >= 0);
    assert_eq!(report.approach.as_deref(), Some("Count with a map."));
    assert_eq!(report.attempts.len(), 2, "{:?}", report.attempts);
    assert_eq!(report.mistakes.len(), 1);
    assert_eq!(report.mistakes[0].kind, "type-mismatch");
    assert_eq!(report.mistakes[0].label, "type mismatch");
    // Derived from the reference, never written about it: the author's own
    // leading comment, plus its size and what it is about.
    assert!(
        report
            .reference_summary
            .contains("Count with a map, then walk it once."),
        "{}",
        report.reference_summary
    );
    assert!(
        report.reference_summary.contains("hashing"),
        "{}",
        report.reference_summary
    );

    // Finishing twice is not an error and does not move the ending.
    let again = interviews::finish(&conn, ALICE, &session.id).unwrap();
    assert_eq!(again.attempts.len(), report.attempts.len());
    assert!(interviews::live(&conn, ALICE).unwrap().is_none());
}

#[test]
fn an_interview_belongs_to_one_player() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let session = interviews::start(&conn, ALICE, "rust", Some("hacker")).unwrap();
    assert!(interviews::get(&conn, BOB, &session.id).is_err());
    assert!(interviews::set_approach(&conn, BOB, &session.id, "mine now").is_err());
    assert!(interviews::finish(&conn, BOB, &session.id).is_err());
    assert!(interviews::live(&conn, BOB).unwrap().is_none());
}

/// Even a quest cleared long ago comes without its answer while the session is
/// live — the mask is on the session, not on the player's progress.
#[test]
fn the_masked_quest_has_no_answer_and_no_hints() {
    let (_tmp, store) = store();
    let conn = store.conn();
    progress::record_clear(&conn, ALICE, "rust.hacker.01.q1", 10).unwrap();
    let quest = quests::get(&conn, "rust.hacker.01.q1").unwrap();

    let normal = quest.to_wire(progress::State::Cleared, 3, 1, None);
    assert!(
        normal.get("solution").is_some(),
        "a cleared quest shows its answer"
    );
    assert_eq!(normal["hints_total"].as_i64(), Some(2));

    let masked = quest.to_wire_under_interview(progress::State::Cleared, 3, None);
    assert!(
        masked.get("solution").is_none(),
        "the answer survived the mask: {masked}"
    );
    assert_eq!(masked["hints_total"].as_i64(), Some(0));
    assert_eq!(masked["under_interview"].as_bool(), Some(true));
    // The problem itself is all still there.
    assert_eq!(masked["title"], normal["title"]);
    assert_eq!(masked["brief"], normal["brief"]);
    assert_eq!(masked["tests"]["visible"], normal["tests"]["visible"]);
    assert_eq!(
        masked["tests"]["hidden_count"],
        normal["tests"]["hidden_count"]
    );
}
