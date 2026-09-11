//! The home, the migrations, the importer and the thing milestone 1 is for:
//! a clear that is still there after a restart.
//!
//! Every test here gets its own temp home, passed in as a parameter. Nothing
//! reads `$HOME` or sets an environment variable — cargo runs these threaded
//! in one process, and an env-based home is one race away from writing into
//! the real `~/.causewaybayhacker`.

use std::path::Path;

use cwbhacker_core::{attempts, content, mistakes, progress, quests, users, world, Store};

const PACK: &str = include_str!("fixtures/rust_basic.toml");

const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";
const BOB: &str = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";

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

#[test]
fn the_home_is_owner_only() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let store = Store::open(&home).unwrap();
    let mode = |p: &Path| {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(p).unwrap().permissions().mode() & 0o777
    };
    assert_eq!(mode(&home), 0o700);
    assert_eq!(mode(&store.home().users_dir()), 0o700);
    assert_eq!(mode(&store.home().db_path()), 0o600);
}

#[test]
fn migrations_bring_the_schema_up_to_date() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(tmp.path()).unwrap();
    let conn = store.conn();
    let version: i64 = conn
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, cwbhacker_core::db::latest_version());
    let foreign_keys: i64 = conn
        .query_row("PRAGMA foreign_keys", [], |r| r.get(0))
        .unwrap();
    assert_eq!(foreign_keys, 1, "foreign keys must be on");
    // SPEC §9.3: FTS5 is asserted, not hoped for. `Store::open` already ran
    // the assertion; this is the same claim from the other side.
    conn.execute_batch("CREATE VIRTUAL TABLE temp.probe USING fts5(x);")
        .expect("fts5 is compiled in");
}

#[test]
fn the_importer_reads_the_pack_and_the_map() {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_dir(tmp.path(), PACK);
    let store = open_and_import(&tmp.path().join("home"), &src);
    let conn = store.conn();

    let all = quests::list(&conn, "rust", "basic").unwrap();
    assert_eq!(all.len(), 3);
    assert_eq!(all[0].id, "rust.basic.01.hello");
    assert_eq!(all[0].map.x, 0.12);
    assert_eq!(all[0].map.kind, "quest");
    assert_eq!(all[0].hints.len(), 2);
    assert_eq!(
        quests::requirements(&conn, "rust.basic.02.sum").unwrap(),
        vec!["rust.basic.01.hello".to_string()]
    );

    // §1: the home keeps a copy of what it loaded.
    assert!(store.home().content_dir().join("rust.basic.toml").is_file());
}

#[test]
fn a_missing_content_directory_is_not_an_error() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(tmp.path()).unwrap();
    let conn = store.conn();
    let report = content::import_dir(&conn, store.home(), &tmp.path().join("nowhere")).unwrap();
    assert!(report.packs.is_empty());
    assert!(report.failures.is_empty());
}

#[test]
fn a_pack_with_a_node_gap_is_refused() {
    let broken = PACK
        .replace("node        = 2", "node        = 4")
        .replace("rust.basic.02.sum", "rust.basic.04.sum");
    let pack: content::Pack = toml::from_str(&broken).unwrap();
    let err = content::validate(&pack).unwrap_err();
    assert!(
        err.message.contains("contiguous"),
        "unexpected message: {}",
        err.message
    );
}

#[test]
fn a_quest_id_that_disagrees_with_its_pack_is_refused() {
    let broken = PACK.replace("rust.basic.01.hello", "go.basic.01.hello");
    let pack: content::Pack = toml::from_str(&broken).unwrap();
    let err = content::validate(&pack).unwrap_err();
    assert!(err.message.contains("disagrees"), "{}", err.message);
}

#[test]
fn a_quest_with_no_visible_case_is_refused() {
    let broken = PACK.replace(
        r#"{ name = "greets", stdin = "", expect = "hello, causewaybay\n", visible = true }"#,
        r#"{ name = "greets", stdin = "", expect = "hello, causewaybay\n", visible = false }"#,
    );
    let pack: content::Pack = toml::from_str(&broken).unwrap();
    let err = content::validate(&pack).unwrap_err();
    assert!(err.message.contains("visible"), "{}", err.message);
}

/// The milestone: clear a quest, put the server down, bring it back, and it is
/// still cleared — **through a real re-import**, because that is what `serve`
/// does on every start and it is the step that could cascade the progress
/// away.
#[test]
fn a_clear_survives_a_restart_and_a_reimport() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let src = content_dir(tmp.path(), PACK);

    {
        let store = open_and_import(&home, &src);
        let conn = store.conn();
        users::upsert(&conn, ALICE).unwrap();
        progress::bump_attempt(&conn, ALICE, "rust.basic.01.hello").unwrap();
        let row = progress::record_clear(&conn, ALICE, "rust.basic.01.hello", 120).unwrap();
        assert!(row.cleared);
        assert_eq!(row.stars, 3, "a clean first clear is three stars");
    }

    // The content is edited between runs, the way content actually is.
    let edited = PACK.replace("FIRST LIGHT", "FIRST LIGHT, AGAIN");
    let src = content_dir(tmp.path(), &edited);

    let store = open_and_import(&home, &src);
    let conn = store.conn();
    let row = progress::get(&conn, ALICE, "rust.basic.01.hello").unwrap();
    assert!(row.cleared, "the clear did not survive the restart");
    assert_eq!(row.stars, 3);
    let quest = quests::get(&conn, "rust.basic.01.hello").unwrap();
    assert_eq!(quest.title, "FIRST LIGHT, AGAIN", "the edit did not land");
}

#[test]
fn locked_nodes_open_as_their_requirements_clear() {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_dir(tmp.path(), PACK);
    let store = open_and_import(&tmp.path().join("home"), &src);
    let conn = store.conn();
    users::upsert(&conn, ALICE).unwrap();

    let map = world::map(&conn, ALICE, "rust", "basic").unwrap();
    assert_eq!(map.nodes[0].state, progress::State::Open);
    assert_eq!(map.nodes[1].state, progress::State::Locked);
    assert_eq!(map.edges.len(), 2);

    progress::record_clear(&conn, ALICE, "rust.basic.01.hello", 10).unwrap();
    let map = world::map(&conn, ALICE, "rust", "basic").unwrap();
    assert_eq!(map.nodes[0].state, progress::State::Cleared);
    assert_eq!(map.nodes[1].state, progress::State::Open);
    assert_eq!(map.nodes[2].state, progress::State::Locked);
}

#[test]
fn stars_follow_the_spec_and_never_regress() {
    assert_eq!(progress::stars_for(0, 0), 3);
    assert_eq!(progress::stars_for(0, 1), 2);
    assert_eq!(progress::stars_for(2, 0), 2);
    assert_eq!(progress::stars_for(3, 0), 1);
    assert_eq!(
        progress::stars_for(9, 2),
        2,
        "a hint is worth a second star"
    );

    let tmp = tempfile::tempdir().unwrap();
    let src = content_dir(tmp.path(), PACK);
    let store = open_and_import(&tmp.path().join("home"), &src);
    let conn = store.conn();
    users::upsert(&conn, ALICE).unwrap();

    let first = progress::record_clear(&conn, ALICE, "rust.basic.01.hello", 500).unwrap();
    assert_eq!(first.stars, 3);

    // A later sloppy re-clear must not take the stamp back.
    for _ in 0..4 {
        let mut record = attempts::new_record(
            cwbhacker_core::ids::attempt_id(),
            ALICE,
            "rust.basic.01.hello",
            "rust",
            "fn main() {}".into(),
        );
        record.verdict = "wrong_answer".into();
        attempts::insert(&conn, &record).unwrap();
    }
    let again = progress::record_clear(&conn, ALICE, "rust.basic.01.hello", 900).unwrap();
    assert_eq!(again.stars, 3);
    assert_eq!(
        again.best_ms,
        Some(500),
        "best_ms is the fastest, not the last"
    );
}

/// SPEC §9.8. Two addresses, interleaved writes: neither sees the other's
/// progress, attempts or mistakes.
#[test]
fn two_users_do_not_leak_into_each_other() {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_dir(tmp.path(), PACK);
    let store = open_and_import(&tmp.path().join("home"), &src);
    let conn = store.conn();
    users::upsert(&conn, ALICE).unwrap();
    users::upsert(&conn, BOB).unwrap();

    for (address, quest, verdict) in [
        (ALICE, "rust.basic.01.hello", "accepted"),
        (BOB, "rust.basic.01.hello", "compile_error"),
        (ALICE, "rust.basic.01.hello", "wrong_answer"),
        (BOB, "rust.basic.01.hello", "compile_error"),
    ] {
        let id = cwbhacker_core::ids::attempt_id();
        let mut record =
            attempts::new_record(id.clone(), address, quest, "rust", "fn main(){}".into());
        record.verdict = verdict.into();
        attempts::insert(&conn, &record).unwrap();
        progress::bump_attempt(&conn, address, quest).unwrap();
        if verdict == "compile_error" {
            mistakes::record(
                &conn,
                &id,
                address,
                quest,
                &[mistakes::Mistake {
                    kind: "type-mismatch".into(),
                    code: Some("E0308".into()),
                    message: "mismatched types".into(),
                    line: Some(2),
                    col: Some(5),
                }],
            )
            .unwrap();
        }
    }
    progress::record_clear(&conn, ALICE, "rust.basic.01.hello", 42).unwrap();

    assert_eq!(attempts::history(&conn, ALICE, None, 50).unwrap().len(), 2);
    assert_eq!(attempts::history(&conn, BOB, None, 50).unwrap().len(), 2);
    assert!(attempts::history(&conn, ALICE, None, 50)
        .unwrap()
        .iter()
        .all(|a| a.verdict != "compile_error"));

    assert!(
        progress::get(&conn, ALICE, "rust.basic.01.hello")
            .unwrap()
            .cleared
    );
    assert!(
        !progress::get(&conn, BOB, "rust.basic.01.hello")
            .unwrap()
            .cleared
    );

    assert!(mistakes::stats(&conn, ALICE, 10).unwrap().is_empty());
    let bobs = mistakes::stats(&conn, BOB, 10).unwrap();
    assert_eq!(bobs.len(), 1);
    assert_eq!(bobs[0].count, 2);

    // And the map each of them is looking at is their own.
    let alice_map = world::map(&conn, ALICE, "rust", "basic").unwrap();
    let bob_map = world::map(&conn, BOB, "rust", "basic").unwrap();
    assert_eq!(alice_map.nodes[1].state, progress::State::Open);
    assert_eq!(bob_map.nodes[1].state, progress::State::Locked);
}

#[test]
fn an_attempt_is_written_into_the_users_own_directory() {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_dir(tmp.path(), PACK);
    let store = open_and_import(&tmp.path().join("home"), &src);
    let record = attempts::new_record(
        "att_0123456789abcdef".into(),
        ALICE,
        "rust.basic.01.hello",
        "rust",
        "fn main() {}\n".into(),
    );
    attempts::write_to_disk(
        store.home(),
        &record,
        "hello\n",
        "",
        &serde_json::json!({"verdict": "accepted"}),
    )
    .unwrap();
    let dir = store.home().attempt_dir(ALICE, "att_0123456789abcdef");
    assert!(dir.join("main.rs").is_file());
    assert!(dir.join("result.json").is_file());
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(dir.join("main.rs"))
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o600);
}

#[test]
fn stderr_is_truncated_on_a_character_boundary() {
    let noisy = "é".repeat(64 * 1024);
    let truncated = attempts::truncate_stderr(&noisy);
    assert!(truncated.contains("…truncated"));
    assert!(truncated.len() < noisy.len() + 64);
}
