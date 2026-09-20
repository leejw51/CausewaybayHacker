//! VERY BASIC (PROTOCOL §5.3 `quiz`): a pack whose quests carry four choices
//! imports, the choices reach the wire beside the starter, a quest without a
//! quiz carries none, and editing the choices changes the checksum so a
//! re-import writes them — the quiz is content, not decoration.
use cwbhacker_core::{content, progress, quests, store::Store};
use std::path::Path;

const PACK: &str = r#"
pack = "rust.verybasic"
land = "rust"
category = "verybasic"
version = 1

[[quest]]
id = "rust.verybasic.01.print"
node = 1
title = "FIRST QUESTION"
difficulty = 1
story = "A napkin at the Percival Street kiosk."
concepts = ["io", "strings"]
requires = []
map = { x = 0.1, y = 0.1, kind = "quest" }
brief = "Which line prints it?"
starter = '''
fn main() {
    // FILL
}
'''
solution = '''
fn main() {
    println!("hello, causewaybay");
}
'''
hints = ["println! has a bang.", "Lowercase."]

[quest.quiz]
choices = ["print(\"hello, causewaybay\");", "println(\"hello, causewaybay\");", "println!(\"hello, causewaybay\");", "echo hello, causewaybay"]
answer = 2

[quest.tests]
harness = "stdio"
timeout_ms = 5000
match = "trim"
cases = [ { name = "greets", stdin = "", expect = "hello, causewaybay\n", visible = true } ]
"#;

fn tree(root: &Path, pack: &str) -> std::path::PathBuf {
    let src = root.join("content-src");
    std::fs::create_dir_all(src.join("rust")).unwrap();
    std::fs::write(src.join("rust/verybasic.toml"), pack).unwrap();
    src
}

#[test]
fn a_quiz_imports_and_reaches_the_wire() {
    let tmp = tempfile::tempdir().unwrap();
    let src = tree(tmp.path(), PACK);
    let store = Store::open(&tmp.path().join("home")).unwrap();
    let conn = store.conn();
    let report = content::import_dir(&conn, store.home(), &src).unwrap();
    assert!(report.failures.is_empty(), "{:?}", report.failures);

    let quest = quests::get(&conn, "rust.verybasic.01.print").unwrap();
    assert_eq!(quest.category, "verybasic");
    let quiz = quest.quiz.clone().expect("the quiz is stored");
    assert_eq!(quiz["answer"], 2);
    assert_eq!(quiz["choices"].as_array().unwrap().len(), 4);

    let wire = quest.to_wire(progress::State::Open, 0, 0, None, None);
    assert_eq!(wire["quiz"]["answer"], 2);
    assert_eq!(
        wire["quiz"]["choices"][2], "println!(\"hello, causewaybay\");",
        "the choices are code and travel verbatim"
    );
    assert!(
        wire.get("solution").is_none(),
        "the quiz does not leak the solution"
    );
}

#[test]
fn a_quest_without_a_quiz_carries_none() {
    let tmp = tempfile::tempdir().unwrap();
    let plain = PACK
        .replace("rust.verybasic", "rust.basic")
        .replace("category = \"verybasic\"", "category = \"basic\"")
        .replace(
            "[quest.quiz]\nchoices = [\"print(\\\"hello, causewaybay\\\");\", \"println(\\\"hello, causewaybay\\\");\", \"println!(\\\"hello, causewaybay\\\");\", \"echo hello, causewaybay\"]\nanswer = 2\n",
            "",
        );
    assert!(!plain.contains("quiz"), "the fixture edit removed the quiz");
    let src = tmp.path().join("content-src");
    std::fs::create_dir_all(src.join("rust")).unwrap();
    std::fs::write(src.join("rust/basic.toml"), &plain).unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    let conn = store.conn();
    let report = content::import_dir(&conn, store.home(), &src).unwrap();
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    let quest = quests::get(&conn, "rust.basic.01.print").unwrap();
    assert!(quest.quiz.is_none());
    let wire = quest.to_wire(progress::State::Open, 0, 0, None, None);
    assert!(
        wire["quiz"].is_null(),
        "no quiz on the wire for an ordinary road"
    );
}

#[test]
fn editing_the_choices_changes_the_checksum_and_reimports() {
    let tmp = tempfile::tempdir().unwrap();
    let src = tree(tmp.path(), PACK);
    let store = Store::open(&tmp.path().join("home")).unwrap();
    let conn = store.conn();
    content::import_dir(&conn, store.home(), &src).unwrap();
    let before = quests::get(&conn, "rust.verybasic.01.print").unwrap();

    let edited = PACK.replace("answer = 2", "answer = 1").replace(
        "\"println(\\\"hello, causewaybay\\\");\", \"println!(\\\"hello, causewaybay\\\");\"",
        "\"println!(\\\"hello, causewaybay\\\");\", \"println(\\\"hello, causewaybay\\\");\"",
    );
    assert!(edited.contains("answer = 1"));
    std::fs::write(src.join("rust/verybasic.toml"), &edited).unwrap();
    let report = content::import_dir(&conn, store.home(), &src).unwrap();
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    let after = quests::get(&conn, "rust.verybasic.01.print").unwrap();
    assert_ne!(
        before.checksum, after.checksum,
        "the quiz is part of the checksum"
    );
    assert_eq!(after.quiz.unwrap()["answer"], 1);
}

#[test]
fn the_importer_refuses_a_category_it_does_not_know() {
    let tmp = tempfile::tempdir().unwrap();
    let bogus = PACK
        .replace("category = \"verybasic\"", "category = \"expert\"")
        .replace("rust.verybasic", "rust.expert");
    let src = tmp.path().join("content-src");
    std::fs::create_dir_all(src.join("rust")).unwrap();
    std::fs::write(src.join("rust/expert.toml"), &bogus).unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    let conn = store.conn();
    let report = content::import_dir(&conn, store.home(), &src).unwrap();
    assert!(
        !report.failures.is_empty(),
        "an unknown category is a failure, not a fifth road"
    );
}
