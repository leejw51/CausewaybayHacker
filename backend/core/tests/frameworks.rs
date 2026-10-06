//! The fifth road (SPEC §0, §12): a `frameworks` pack imports for Rust Land
//! with its `tests.crates` kept for the runner, and the importer refuses the
//! shapes that would send a `use serde` to `rustc` alone or put a cargo
//! shelf under a land that has none.
use cwbhacker_core::{content, quests, store::Store};
use std::path::Path;

const PACK: &str = r#"
pack = "rust.frameworks"
land = "rust"
category = "frameworks"
version = 1

[[quest]]
id = "rust.frameworks.01.serde"
node = 1
title = "THE SHAPE OF THE WIRE"
difficulty = 2
story = "The terminals on Yee Wo Street post JSON."
concepts = ["serialization", "structs"]
requires = []
map = { x = 0.1, y = 0.1, kind = "quest" }
brief = "Parse it."
starter = '''
fn main() {}
'''
solution = '''
use serde::Deserialize;
#[derive(Deserialize)]
struct O { cents: i64 }
fn main() {
    let o: O = serde_json::from_str("{\"cents\":1}").unwrap();
    println!("{}", o.cents);
}
'''
hints = ["use serde::Deserialize;", "serde_json::from_str"]

[quest.tests]
harness = "stdio"
crates = ["serde", "serde_json"]
timeout_ms = 5000
match = "trim"
cases = [ { name = "one", stdin = "", expect = "1\n", visible = true } ]
"#;

fn import(root: &Path, land: &str, category: &str, pack: &str) -> content::ImportReport {
    let src = root.join("content-src");
    std::fs::create_dir_all(src.join(land)).unwrap();
    std::fs::write(src.join(format!("{land}/{category}.toml")), pack).unwrap();
    let store = Store::open(&root.join("home")).unwrap();
    let conn = store.conn();
    content::import_dir(&conn, store.home(), &src).unwrap()
}

#[test]
fn a_frameworks_pack_imports_with_its_crates() {
    let tmp = tempfile::tempdir().unwrap();
    let report = import(tmp.path(), "rust", "frameworks", PACK);
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    let store = Store::open(&tmp.path().join("home")).unwrap();
    let conn = store.conn();
    let quest = quests::get(&conn, "rust.frameworks.01.serde").unwrap();
    assert_eq!(quest.category, "frameworks");
    assert_eq!(quest.lang, "rust");
    assert_eq!(
        quest.tests["crates"],
        serde_json::json!(["serde", "serde_json"]),
        "the runner reads the crates off the stored spec"
    );
}

#[test]
fn a_frameworks_quest_without_crates_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let bare = PACK.replace("crates = [\"serde\", \"serde_json\"]\n", "");
    let report = import(tmp.path(), "rust", "frameworks", &bare);
    assert_eq!(report.failures.len(), 1, "{:?}", report.failures);
    assert!(
        report.failures[0].1.contains("tests.crates"),
        "{}",
        report.failures[0].1
    );
}

#[test]
fn the_frameworks_road_is_rusts_alone() {
    let tmp = tempfile::tempdir().unwrap();
    let go = PACK
        .replace("land = \"rust\"", "land = \"go\"")
        .replace("rust.frameworks", "go.frameworks");
    let report = import(tmp.path(), "go", "frameworks", &go);
    assert_eq!(report.failures.len(), 1, "{:?}", report.failures);
    assert!(
        report.failures[0].1.contains("crate shelf"),
        "{}",
        report.failures[0].1
    );
}

#[test]
fn crates_are_a_rust_key_on_any_road() {
    // An ADVANCED Rust quest may name crates (the runner builds it against
    // the shelf); a Go quest may not, whatever road it is on.
    let tmp = tempfile::tempdir().unwrap();
    let advanced = PACK
        .replace("category = \"frameworks\"", "category = \"advanced\"")
        .replace("rust.frameworks", "rust.advanced");
    let report = import(tmp.path(), "rust", "advanced", &advanced);
    assert!(report.failures.is_empty(), "{:?}", report.failures);

    let tmp = tempfile::tempdir().unwrap();
    let go = PACK
        .replace("land = \"rust\"", "land = \"go\"")
        .replace("category = \"frameworks\"", "category = \"advanced\"")
        .replace("rust.frameworks", "go.advanced");
    let report = import(tmp.path(), "go", "advanced", &go);
    assert_eq!(report.failures.len(), 1, "{:?}", report.failures);
    assert!(
        report.failures[0].1.contains("not a rust quest"),
        "{}",
        report.failures[0].1
    );
}
