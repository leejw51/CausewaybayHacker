//! The importer against content that **changed shape**.
//!
//! This is the gap that let a real bug through. `store.rs` re-imports a pack
//! whose *text* changed — a title edited — and asserts progress survives.
//! That passes whether the importer works or not, because nothing moved.
//!
//! Content does not stay still. A quest gets inserted in the middle of a map,
//! one gets cut, the boss moves to the end and SPEC §12 ties the id's number
//! to `node`, so its id changes too. Every one of those renumbers the quests
//! after it — and `quests` has `UNIQUE (land, category, node)`, so an
//! importer that upserts row by row hits a collision against rows that are
//! still holding the old numbering.
//!
//! When that happened for real, the symptom was the worst kind: three of six
//! packs silently failed to import, the server logged a WARN and carried on
//! serving **stale content**, and the database and the TOML disagreed by
//! whole quests. Nothing was red. A player got a map that did not match the
//! file anybody was editing.
//!
//! So the assertion here is not "the import returned Ok". It is **the
//! database matches the file, exactly**, after each shape change — which is
//! what `content::audit_file` was added to answer.

use std::path::Path;

use cwbhacker_core::{content, progress, quests, users, Store};

const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";

/// A pack built from `(node, slug)` pairs, so a test can say what shape it
/// wants without four hundred lines of TOML.
///
/// Every quest is the same trivial print, because what is under test is the
/// importer, not the runner. Code fields use `'''` literal strings, as SPEC
/// §12 requires — `"""` would process the `\n` in `expect` and quietly
/// rewrite the content.
fn pack_of(quests: &[(u32, &str)]) -> String {
    let mut out =
        String::from("pack = \"rust.basic\"\nland = \"rust\"\ncategory = \"basic\"\nversion = 1\n");
    for (i, (node, slug)) in quests.iter().enumerate() {
        let requires = if i == 0 {
            String::from("[]")
        } else {
            let (pn, ps) = quests[i - 1];
            format!("[\"rust.basic.{pn:02}.{ps}\"]")
        };
        out.push_str(&format!(
            r#"
[[quest]]
id          = "rust.basic.{node:02}.{slug}"
node        = {node}
title       = "{upper}"
difficulty  = 1
story       = "A street."
concepts    = ["io"]
requires    = {requires}
map         = {{ x = 0.1, y = 0.1, kind = "quest" }}
brief       = '''
Print `{slug}`.
'''
starter     = '''
fn main() {{
    // your code here
}}
'''
solution    = '''
fn main() {{
    println!("{slug}");
}}
'''
hints = ["Print it."]

[quest.tests]
harness      = "stdio"
timeout_ms   = 5000
match        = "trim"
cases = [
  {{ name = "prints", stdin = "", expect = "{slug}\n", visible = true }},
]
"#,
            upper = slug.to_uppercase(),
        ));
    }
    out
}

fn write_pack(root: &Path, text: &str) -> std::path::PathBuf {
    let dir = root.join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), text).unwrap();
    root.join("content-src")
}

/// Import, and insist it really happened.
///
/// `import_dir` does not fail the process on a bad pack — by design, so one
/// broken file does not take the server down (SPEC §12). That is exactly why
/// a test must look at `failures` rather than at the `Result`: the silent
/// path is the dangerous one.
fn import(store: &Store, src: &Path) -> content::ImportReport {
    let conn = store.conn();
    let report = content::import_dir(&conn, store.home(), src).expect("import runs");
    assert!(
        report.failures.is_empty(),
        "the importer reported failures and carried on, which is how the \
         database and the content drift apart without anything going red: {:?}",
        report.failures
    );
    report
}

/// The whole point: does the database say what the file says?
fn assert_agrees(store: &Store, src: &Path, when: &str) {
    let conn = store.conn();
    let audits = content::audit_dir(&conn, src).expect("audit runs");
    assert!(!audits.is_empty(), "nothing was audited at all ({when})");
    for audit in &audits {
        assert!(
            audit.agrees(),
            "{when}: the database and {} disagree — missing {:?}, stale {:?}, \
             unreadable {:?}. {} quests in the file, {} in the database.",
            audit.path,
            audit.missing,
            audit.stale,
            audit.unreadable,
            audit.in_file,
            audit.in_db,
        );
    }
}

/// Every quest id the database holds for rust/basic, with its node, sorted.
fn shape(store: &Store) -> Vec<(i64, String)> {
    let conn = store.conn();
    let mut rows: Vec<(i64, String)> = quests::list(&conn, "rust", "basic")
        .expect("list")
        .into_iter()
        .map(|q| (q.node, q.id))
        .collect();
    rows.sort();
    rows
}

// ---------------------------------------------------------------------------

#[test]
fn a_quest_inserted_in_the_middle_renumbers_the_rest_without_colliding() {
    // The shape change that broke it. Inserting at node 2 pushes every later
    // quest down one, and because SPEC §12 puts the node number *in the id*,
    // each of them is a new id as well as a new number. An importer that
    // upserts in file order writes node 2 for `bindings` while `sum` is still
    // sitting on node 2, and `UNIQUE (land, category, node)` refuses it.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");

    let before = pack_of(&[(1, "hello"), (2, "sum"), (3, "shadowing")]);
    let src = write_pack(tmp.path(), &before);
    let store = Store::open(&home).expect("store");
    import(&store, &src);
    assert_agrees(&store, &src, "after the first import");
    assert_eq!(
        shape(&store),
        vec![
            (1, "rust.basic.01.hello".into()),
            (2, "rust.basic.02.sum".into()),
            (3, "rust.basic.03.shadowing".into()),
        ]
    );

    // `bindings` goes in at 2; `sum` becomes 3 and `shadowing` becomes 4.
    let after = pack_of(&[(1, "hello"), (2, "bindings"), (3, "sum"), (4, "shadowing")]);
    let src = write_pack(tmp.path(), &after);
    import(&store, &src);

    assert_agrees(&store, &src, "after inserting a quest mid-map");
    assert_eq!(
        shape(&store),
        vec![
            (1, "rust.basic.01.hello".into()),
            (2, "rust.basic.02.bindings".into()),
            (3, "rust.basic.03.sum".into()),
            (4, "rust.basic.04.shadowing".into()),
        ],
        "the map the server serves is not the map in the file"
    );

    // And the old ids are gone, not lingering beside the new ones. A stale
    // row is worse than a missing one: it is a street on somebody's map that
    // no longer exists in the content anybody is editing.
    let all = shape(&store);
    for gone in ["rust.basic.02.sum", "rust.basic.03.shadowing"] {
        assert!(
            !all.iter().any(|(_, id)| id == gone),
            "{gone} is still in the database after being renumbered away"
        );
    }
}

#[test]
fn a_removed_quest_leaves_nothing_behind_and_the_survivors_keep_their_progress() {
    // SPEC §2.2: "A quest whose `checksum` changed keeps its `progress` rows.
    // Content is edited constantly; progress is not thrown away for a typo
    // fix." And `PackReport::removed` is explicit that a quest the pack no
    // longer has takes its progress with it — there is nothing left for it to
    // be progress *on*.
    //
    // Both halves matter to a player. Losing a clear because somebody fixed a
    // typo three streets away is the thing PLAN.md calls "users lose their
    // accounts", one street at a time.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");

    let before = pack_of(&[(1, "hello"), (2, "sum"), (3, "shadowing"), (4, "slices")]);
    let src = write_pack(tmp.path(), &before);
    let store = Store::open(&home).expect("store");
    import(&store, &src);

    {
        let conn = store.conn();
        users::upsert(&conn, ALICE).unwrap();
        // Cleared with a grade, so there is something specific to lose
        // rather than a bare boolean. `stars_for` counts *failed attempts*
        // from the attempts table, not `progress.attempts`, so a clean clear
        // is three — which is the grade worth protecting anyway.
        let row = progress::record_clear(&conn, ALICE, "rust.basic.01.hello", 420).unwrap();
        assert_eq!(row.stars, 3, "a clean first clear");
        progress::record_clear(&conn, ALICE, "rust.basic.04.slices", 99).unwrap();
    }

    // `sum` is cut. `shadowing` and `slices` move up one, and their ids
    // change with their numbers.
    let after = pack_of(&[(1, "hello"), (2, "shadowing"), (3, "slices")]);
    let src = write_pack(tmp.path(), &after);
    import(&store, &src);
    assert_agrees(&store, &src, "after removing a quest from the middle");

    assert_eq!(
        shape(&store),
        vec![
            (1, "rust.basic.01.hello".into()),
            (2, "rust.basic.02.shadowing".into()),
            (3, "rust.basic.03.slices".into()),
        ]
    );

    let conn = store.conn();
    // The quest that did not move keeps everything.
    let kept = progress::get(&conn, ALICE, "rust.basic.01.hello").unwrap();
    assert!(
        kept.cleared,
        "a clear was lost to an edit elsewhere in the pack"
    );
    assert_eq!(kept.stars, 3, "the grade was lost to an edit elsewhere");

    // The quest that was renumbered is, by SPEC §4.1, a different quest: the
    // slug is part of the id "so a reordered map does not renumber someone's
    // cleared list into nonsense", and `slices` moved from node 4 to node 3,
    // which changes its id. Whatever the importer does with that progress, it
    // must not leave a row pointing at a quest that no longer exists.
    let orphans: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM progress p
               LEFT JOIN quests q ON q.id = p.quest_id
              WHERE q.id IS NULL",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        orphans, 0,
        "progress rows are pointing at quests the content no longer has"
    );
}

#[test]
fn a_boss_moving_to_the_end_of_a_longer_map_is_not_a_collision() {
    // The specific change that shipped: four maps grew, and each one's boss
    // moved to the new end. `rust.basic.12.traits` became
    // `rust.basic.18.traits`, and the six quests inserted before it took
    // nodes 12..17 — which are the numbers the boss is vacating, in the order
    // an importer would most naturally write them.
    //
    // Deliberately built to make the collision maximally likely: the new
    // quests take exactly the numbers the old boss and its neighbours are
    // still holding.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let store = Store::open(&home).expect("store");

    let mut before: Vec<(u32, &str)> = (1..=11).map(|n| (n, slug_for(n))).collect();
    before.push((12, "traits"));
    let src = write_pack(tmp.path(), &pack_of(&before));
    import(&store, &src);
    assert_eq!(shape(&store).len(), 12);

    let mut after: Vec<(u32, &str)> = (1..=17).map(|n| (n, slug_for(n))).collect();
    after.push((18, "traits"));
    let src = write_pack(tmp.path(), &pack_of(&after));
    import(&store, &src);

    assert_agrees(
        &store,
        &src,
        "after the boss moved to the end of a longer map",
    );
    let rows = shape(&store);
    assert_eq!(rows.len(), 18, "the grown map is not all there");
    assert_eq!(rows[17].1, "rust.basic.18.traits", "the boss did not move");
    assert!(
        !rows.iter().any(|(_, id)| id == "rust.basic.12.traits"),
        "the boss's old id is still in the database beside its new one"
    );
    // Contiguous 1..18, which SPEC §12 requires because the map draws a path
    // through them.
    let nodes: Vec<i64> = rows.iter().map(|(n, _)| *n).collect();
    assert_eq!(nodes, (1..=18).collect::<Vec<i64>>());
}

/// A stable slug per node, so a growing map is reproducible.
fn slug_for(n: u32) -> &'static str {
    const SLUGS: [&str; 17] = [
        "hello",
        "bindings",
        "sum",
        "shadowing",
        "slices",
        "strings",
        "vectors",
        "maps",
        "structs",
        "enums",
        "options",
        "results",
        "iterators",
        "closures",
        "generics",
        "errors",
        "modules",
    ];
    SLUGS[(n as usize - 1) % SLUGS.len()]
}

#[test]
fn an_import_that_cannot_be_applied_is_reported_and_not_swallowed() {
    // The failure mode that actually happened is not "the import errored" —
    // it is "the import half-failed, logged a WARN, and the server carried on
    // serving whatever was already in the database".
    //
    // SPEC §12 says a pack that breaks the rules is refused. What must never
    // happen is a refusal the caller cannot see, so this asserts on
    // `ImportReport::failures` rather than on the `Result`, and then asserts
    // the audit *notices* the disagreement it caused. An audit that said
    // "agrees" here would mean the operator has no way to find out.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let store = Store::open(&home).expect("store");

    let good = pack_of(&[(1, "hello"), (2, "sum")]);
    let src = write_pack(tmp.path(), &good);
    import(&store, &src);

    // A node gap: SPEC §12 refuses it, because the map draws a path through
    // the nodes and a gap is a road to nowhere.
    let broken = pack_of(&[(1, "hello"), (3, "sum")]);
    let src = write_pack(tmp.path(), &broken);
    let report = {
        let conn = store.conn();
        content::import_dir(&conn, store.home(), &src).expect("import runs")
    };
    assert!(
        !report.failures.is_empty(),
        "a pack with a node gap imported cleanly; SPEC §12 says it is refused"
    );
    let (path, reason) = &report.failures[0];
    assert!(
        path.contains("basic.toml"),
        "the failure names the file: {path}"
    );
    assert!(
        !reason.is_empty(),
        "the failure has no reason, so nobody can act on it"
    );

    // And the operator can find out that the database no longer matches the
    // file. This is the check that turns a silent WARN into something a test
    // — or `cwbhacker doctor` — can fail on.
    let conn = store.conn();
    let audits = content::audit_dir(&conn, &src).expect("audit runs");
    let audit = audits.first().expect("one pack was audited");
    assert!(
        !audit.agrees(),
        "the file has a quest at node 3 that the database does not have, and \
         the audit says they agree — which is how stale content gets served \
         with nothing going red"
    );
}
