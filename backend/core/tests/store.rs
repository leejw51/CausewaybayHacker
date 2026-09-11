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

/// PROTOCOL §4.7: every node is playable from the start. `requires` and
/// `edges` still travel — they are the suggested route and the line the map
/// draws — but they gate nothing.
///
/// This test used to assert the opposite (node 2 locked until node 1 cleared).
/// It is kept, inverted, rather than deleted: the thing worth guarding now is
/// that the route is still *advertised* while no longer being enforced, which
/// is a weaker claim than before and easy to lose by deleting the dependency
/// plumbing along with the gate.
#[test]
fn every_node_is_playable_and_the_route_is_still_advertised() {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_dir(tmp.path(), PACK);
    let store = open_and_import(&tmp.path().join("home"), &src);
    let conn = store.conn();
    users::upsert(&conn, ALICE).unwrap();

    let map = world::map(&conn, ALICE, "rust", "basic").unwrap();
    assert!(
        map.nodes.iter().all(|n| n.state == progress::State::Open),
        "a fresh player should be able to open any node: {:?}",
        map.nodes
            .iter()
            .map(|n| (&n.quest_id, n.state))
            .collect::<Vec<_>>()
    );
    // The advice survives the gate's removal.
    assert_eq!(map.edges.len(), 2);
    assert_eq!(map.nodes[0].requires, Vec::<String>::new());
    assert_eq!(
        map.nodes[1].requires,
        vec!["rust.basic.01.hello".to_string()]
    );
    assert_eq!(
        world::state_of(&conn, ALICE, "rust.basic.03.shadowing").unwrap(),
        progress::State::Open,
        "the last node is open before the first is touched"
    );

    // Clearing changes a node to cleared and nothing else to anything.
    progress::record_clear(&conn, ALICE, "rust.basic.01.hello", 10).unwrap();
    let map = world::map(&conn, ALICE, "rust", "basic").unwrap();
    assert_eq!(map.nodes[0].state, progress::State::Cleared);
    assert_eq!(map.nodes[1].state, progress::State::Open);
    assert_eq!(map.nodes[2].state, progress::State::Open);

    // `unlocked_by` is now "what the route says comes next", and still useful.
    assert_eq!(
        world::unlocked_by(&conn, ALICE, "rust.basic.01.hello").unwrap(),
        vec!["rust.basic.02.sum".to_string()]
    );
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
            attempts::Mode::Submit,
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
                attempts::Mode::Submit,
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

    assert!(mistakes::stats(&conn, ALICE, 10, true).unwrap().is_empty());
    let bobs = mistakes::stats(&conn, BOB, 10, true).unwrap();
    assert_eq!(bobs.len(), 1);
    assert_eq!(bobs[0].count, 2);

    // And the map each of them is looking at is their own. Nothing is locked
    // any more (PROTOCOL §4.7), so what separates the two maps is the stamp on
    // node 1 — which is the thing this test is actually about.
    let alice_map = world::map(&conn, ALICE, "rust", "basic").unwrap();
    let bob_map = world::map(&conn, BOB, "rust", "basic").unwrap();
    assert_eq!(alice_map.nodes[0].state, progress::State::Cleared);
    assert_eq!(bob_map.nodes[0].state, progress::State::Open);
    assert_eq!(alice_map.nodes[0].attempts, 2);
    assert_eq!(bob_map.nodes[0].attempts, 2);
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
        attempts::Mode::Submit,
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

/// SPEC §9.3: the FTS5 check is an **assertion**, not a log line.
///
/// The bundled amalgamation always has FTS5, so the way to prove the check is
/// load-bearing is to make the smoke test fail and watch startup refuse: a
/// plain table sitting where the virtual one goes shadows it, and nothing
/// after it runs.
#[test]
fn a_database_without_working_fts5_refuses_to_start() {
    let conn = rusqlite::Connection::open_in_memory().unwrap();
    conn.execute_batch("CREATE TABLE temp.fts5_smoke (x);")
        .unwrap();

    let err = cwbhacker_core::db::prepare(&conn)
        .expect_err("startup must refuse a database whose FTS5 does not work");
    assert!(
        err.message.contains("FTS5"),
        "the failure should name FTS5, not leave an operator guessing: {}",
        err.message
    );

    // And it refused *before* migrating: a half-built database is worse than
    // no database, and 0001 itself creates a `USING fts5` table.
    let version: i64 = conn
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 0, "migrations ran despite the failed assertion");
    let tables: i64 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'quests'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(tables, 0);
}

/// The healthy path, for contrast: a real home gets a working FTS5 index.
#[test]
fn a_healthy_database_has_a_working_fts5_index() {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_dir(tmp.path(), PACK);
    let store = open_and_import(&tmp.path().join("home"), &src);
    let conn = store.conn();
    let hits: i64 = conn
        .query_row(
            "SELECT count(*) FROM quest_fts WHERE quest_fts MATCH 'causewaybay'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(hits >= 1, "the importer's rows never reached the FTS index");
}

// ---------------------------------------------------------------------------
// Re-importing a pack that CHANGED SHAPE.
//
// The importer was tested against unchanged content, which is why this got
// through: a quest removed from a pack was left stranded on a parked node, and
// the *next* import then collided with it and failed — for good. Half the
// packs stopped importing and the server went on serving yesterday's map with
// a WARN line nobody reads.
// ---------------------------------------------------------------------------

/// A rust/basic pack with exactly these `(node, slug)` quests, so a test can
/// say "and now the content looks like this instead".
fn pack_of(quests: &[(i64, &str)]) -> String {
    let mut out =
        String::from("pack = \"rust.basic\"\nland = \"rust\"\ncategory = \"basic\"\nversion = 1\n");
    for (node, slug) in quests {
        out.push_str(&format!(
            r#"
[[quest]]
id          = "rust.basic.{node:02}.{slug}"
node        = {node}
title       = "{slug}"
difficulty  = 1
story       = "a street"
concepts    = ["io"]
requires    = []
map         = {{ x = 0.1, y = 0.1, kind = "quest" }}
brief       = '''
Print `{slug}`.
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

fn ids_and_nodes(store: &Store) -> Vec<(String, i64)> {
    let conn = store.conn();
    let mut stmt = conn
        .prepare("SELECT id, node FROM quests WHERE land='rust' AND category='basic' ORDER BY node")
        .unwrap();
    stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap()
}

fn reimport(home: &Path, root: &Path, pack: &str) -> Store {
    let src = content_dir(root, pack);
    let store = Store::open(home).expect("store opens");
    {
        let conn = store.conn();
        let report = content::import_dir(&conn, store.home(), &src).expect("import ran");
        assert!(
            report.failures.is_empty(),
            "the pack failed to import: {:?}",
            report.failures
        );
    }
    store
}

#[test]
fn a_pack_that_changed_shape_reconciles_exactly() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");

    // Yesterday's content.
    let v1 = pack_of(&[(1, "alpha"), (2, "beta"), (3, "gamma")]);
    let store = reimport(&home, tmp.path(), &v1);
    {
        let conn = store.conn();
        users::upsert(&conn, ALICE).unwrap();
        progress::record_clear(&conn, ALICE, "rust.basic.01.alpha", 10).unwrap();
        progress::record_clear(&conn, ALICE, "rust.basic.02.beta", 10).unwrap();
    }
    drop(store);

    // Today's: `beta` is gone, `gamma` moved down into its place, and `delta`
    // is new at the end. Every kind of change at once, which is what an edit
    // actually looks like.
    let v2 = pack_of(&[(1, "alpha"), (2, "gamma"), (3, "delta")]);
    let store = reimport(&home, tmp.path(), &v2);

    assert_eq!(
        ids_and_nodes(&store),
        vec![
            ("rust.basic.01.alpha".to_string(), 1),
            ("rust.basic.02.gamma".to_string(), 2),
            ("rust.basic.03.delta".to_string(), 3),
        ],
        "the database does not match the file it was imported from"
    );

    {
        let conn = store.conn();
        // SPEC §2.2: an edit does not cost a player their progress.
        assert!(
            progress::get(&conn, ALICE, "rust.basic.01.alpha")
                .unwrap()
                .cleared,
            "a surviving quest lost its progress"
        );
        // A quest that no longer exists takes its progress with it — there is
        // nothing left for it to be progress on.
        let ghosts: i64 = conn
            .query_row(
                "SELECT count(*) FROM progress WHERE quest_id = 'rust.basic.02.beta'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(ghosts, 0, "a removed quest's progress survived it");
        let stranded: i64 = conn
            .query_row("SELECT count(*) FROM quests WHERE node < 1", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(stranded, 0, "a quest was left parked off the map");
    }
    drop(store);

    // The bug's real shape: the *second* import after a change is the one that
    // died, because the first left something stranded on a parked node.
    let store = reimport(&home, tmp.path(), &v2);
    assert_eq!(ids_and_nodes(&store).len(), 3);
    drop(store);

    // And it goes back the other way — a quest can return, renumbered.
    let store = reimport(&home, tmp.path(), &v1);
    assert_eq!(
        ids_and_nodes(&store),
        vec![
            ("rust.basic.01.alpha".to_string(), 1),
            ("rust.basic.02.beta".to_string(), 2),
            ("rust.basic.03.gamma".to_string(), 3),
        ]
    );
    let conn = store.conn();
    assert!(
        progress::get(&conn, ALICE, "rust.basic.01.alpha")
            .unwrap()
            .cleared,
        "three imports later, the clear is still there"
    );
    // `beta` came back as a new quest, not as a resurrected clear.
    assert!(
        !progress::get(&conn, ALICE, "rust.basic.02.beta")
            .unwrap()
            .cleared
    );
}

/// Two quests swapping places in one edit — the case that cannot be done one
/// statement at a time, because either order passes through a node the other
/// still holds.
#[test]
fn two_quests_can_swap_nodes_in_one_import() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let store = reimport(&home, tmp.path(), &pack_of(&[(1, "alpha"), (2, "beta")]));
    drop(store);
    let store = reimport(&home, tmp.path(), &pack_of(&[(1, "beta"), (2, "alpha")]));
    assert_eq!(
        ids_and_nodes(&store),
        vec![
            ("rust.basic.01.beta".to_string(), 1),
            ("rust.basic.02.alpha".to_string(), 2),
        ]
    );
}

/// The real edit that broke the importer, in miniature.
///
/// Lengthening a map moves the boss: SPEC §12 makes the id carry the node
/// number, so `rust.basic.12.traits` becomes `rust.basic.18.traits` while a
/// *different* quest takes node 12. An id that left the file while its node
/// stayed occupied is the exact shape that produced the constraint violation,
/// and it is not hypothetical — it happened to four quests at once.
#[test]
fn a_renumbered_boss_does_not_collide_with_its_replacement() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");

    let v1 = pack_of(&[(1, "alpha"), (2, "beta"), (3, "boss")]);
    let store = reimport(&home, tmp.path(), &v1);
    {
        let conn = store.conn();
        users::upsert(&conn, ALICE).unwrap();
        progress::record_clear(&conn, ALICE, "rust.basic.01.alpha", 10).unwrap();
        progress::record_clear(&conn, ALICE, "rust.basic.03.boss", 10).unwrap();
    }
    drop(store);

    // The map grew: `gamma` takes node 3, and the boss moves to the end and
    // is renamed by the same rule that names every quest.
    let v2 = pack_of(&[(1, "alpha"), (2, "beta"), (3, "gamma"), (4, "boss")]);
    let store = reimport(&home, tmp.path(), &v2);

    assert_eq!(
        ids_and_nodes(&store),
        vec![
            ("rust.basic.01.alpha".to_string(), 1),
            ("rust.basic.02.beta".to_string(), 2),
            ("rust.basic.03.gamma".to_string(), 3),
            ("rust.basic.04.boss".to_string(), 4),
        ]
    );
    let conn = store.conn();
    // The clear on the quest that did not move is untouched…
    assert!(
        progress::get(&conn, ALICE, "rust.basic.01.alpha")
            .unwrap()
            .cleared
    );
    // …and the old boss id is gone, progress and all. A rename is
    // indistinguishable from a delete-plus-insert, and guessing wrong is
    // worse than losing one clear while nobody has a real save.
    let ghosts: i64 = conn
        .query_row(
            "SELECT count(*) FROM progress WHERE quest_id = 'rust.basic.03.boss'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(ghosts, 0);
    assert!(
        !progress::get(&conn, ALICE, "rust.basic.04.boss")
            .unwrap()
            .cleared
    );
}

/// A client that fetches the map *while* a pack is being re-imported must see
/// either the old map or the new one, never a mix.
///
/// This is not hypothetical: the LÖVE client caught `world.map` returning
/// `rust.basic.12.traits` first, out of node order, with `world.lands`
/// disagreeing with it in the same window. The cause was a row the old
/// importer had stranded on node -12 — permanent, not transient — and the
/// reconciliation above removes that state entirely. This test guards the
/// property the fix depends on: the whole reconcile is one write transaction,
/// so a reader on another connection is on a snapshot until it commits.
#[test]
fn a_reader_never_sees_a_half_reconciled_map() {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");

    // Big enough that the reconcile is not over before the reader's first
    // look, and shaped so that *every* node number moves.
    let old_shape: Vec<(i64, String)> = (1..=40).map(|n| (n, format!("old{n:02}"))).collect();
    let new_shape: Vec<(i64, String)> = std::iter::once((1, "inserted".to_string()))
        .chain((1..=40).map(|n| (n + 1, format!("old{n:02}"))))
        .collect();
    fn as_pairs(v: &[(i64, String)]) -> Vec<(i64, &str)> {
        v.iter().map(|(n, s)| (*n, s.as_str())).collect()
    }

    let store = reimport(&home, tmp.path(), &pack_of(&as_pairs(&old_shape)));
    let before = ids_and_nodes(&store);
    drop(store);

    let expected_after: Vec<(String, i64)> = new_shape
        .iter()
        .map(|(n, slug)| (format!("rust.basic.{n:02}.{slug}"), *n))
        .collect();

    let db_path = home.join("hacker.db");
    let stop = Arc::new(AtomicBool::new(false));
    let reader_stop = stop.clone();
    let reader = std::thread::spawn(move || {
        // A second connection to the same file — a running server, in effect.
        let conn = cwbhacker_core::db::open(&db_path).expect("reader connects");
        let mut seen: Vec<Vec<(String, i64)>> = Vec::new();
        while !reader_stop.load(Ordering::Relaxed) || seen.len() < 2 {
            let mut stmt = conn
                .prepare(
                    "SELECT id, node FROM quests
                      WHERE land='rust' AND category='basic' ORDER BY node",
                )
                .unwrap();
            let rows: Vec<(String, i64)> = stmt
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .collect::<rusqlite::Result<Vec<_>>>()
                .unwrap();
            seen.push(rows);
            if seen.len() > 4000 {
                break;
            }
        }
        seen
    });

    let src = content_dir(tmp.path(), &pack_of(&as_pairs(&new_shape)));
    let store = Store::open(&home).unwrap();
    {
        let conn = store.conn();
        let report = content::import_dir(&conn, store.home(), &src).unwrap();
        assert!(report.failures.is_empty(), "{:?}", report.failures);
    }
    stop.store(true, Ordering::Relaxed);
    let observations = reader.join().unwrap();

    assert!(
        observations.len() > 1,
        "the reader never got a look in; the test proves nothing"
    );
    let mut saw_old = false;
    let mut saw_new = false;
    for (i, rows) in observations.iter().enumerate() {
        // Whatever it saw, it must be a map: ordered, 1-based, no duplicates.
        let nodes: Vec<i64> = rows.iter().map(|(_, n)| *n).collect();
        assert!(
            nodes.windows(2).all(|w| w[1] > w[0]),
            "observation {i} came back out of node order: {nodes:?}"
        );
        assert!(
            nodes.first().copied().unwrap_or(1) >= 1,
            "observation {i} had a node below 1: {nodes:?}"
        );
        if *rows == before {
            saw_old = true;
        } else if *rows == expected_after {
            saw_new = true;
        } else {
            panic!(
                "observation {i} was neither the old map nor the new one: {} rows, nodes {:?}",
                rows.len(),
                nodes
            );
        }
    }
    assert!(saw_new, "the reader never saw the import land");
    let _ = saw_old;
}

#[test]
fn taking_the_connection_twice_on_one_thread_panics_instead_of_hanging() {
    // The guard is a plain mutex and is not reentrant, so this is a deadlock.
    // A deadlock hangs, and a hang is a bad way to lose ten minutes — it has
    // cost two agents an afternoon each. It now panics with the remedy in the
    // message, which is the whole point of the change and is worth a test so
    // nobody "simplifies" the bookkeeping away.
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open_memory(&tmp.path().join("home")).unwrap();

    let outer = store.conn();
    // The hook would print the panic to stderr and make a passing run look
    // like a failing one to anyone reading the output.
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _inner = store.conn();
    }));
    std::panic::set_hook(previous);
    let payload = panicked.expect_err("the second take must not succeed");
    let said = payload
        .downcast_ref::<String>()
        .cloned()
        .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
        .unwrap_or_default();
    assert!(
        said.contains("twice on one thread"),
        "the panic must name what happened: {said:?}"
    );
    assert!(
        said.contains("with_conn"),
        "and the remedy, or the next person only learns that it broke: {said:?}"
    );

    // The bookkeeping survived the panic: the outer guard still works, and
    // dropping it leaves the store usable.
    outer.execute_batch("select 1").unwrap();
    drop(outer);
    store
        .with_conn(|conn| conn.execute_batch("select 1"))
        .unwrap();
}

#[test]
fn two_threads_taking_the_connection_is_not_reentrance() {
    // The check is per thread, and must not turn ordinary contention — two
    // connections doing database work at once, which is the normal state of
    // the server — into a panic.
    let tmp = tempfile::tempdir().unwrap();
    let store = std::sync::Arc::new(Store::open_memory(&tmp.path().join("home")).unwrap());
    let mut threads = Vec::new();
    for _ in 0..8 {
        let store = store.clone();
        threads.push(std::thread::spawn(move || {
            for _ in 0..50 {
                store
                    .with_conn(|conn| conn.execute_batch("select 1"))
                    .unwrap();
            }
        }));
    }
    for t in threads {
        t.join()
            .expect("no thread mistook contention for reentrance");
    }
}
