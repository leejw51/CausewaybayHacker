//! Translation packs (SPEC §12.1): the file under `content/i18n/<locale>/`,
//! the `quest_text` rows it becomes, and the read path that swaps them in.
//!
//! Two sources of content are used on purpose. The throwaway fixture pack
//! (`rust.basic.01.hello`, `02.sum`) drives the rules — a hint count that
//! disagrees, an id nobody supplies, a misfiled file — because those need
//! text written to be wrong. The shipped sample (`content/i18n/ko/rust.basic.toml`
//! against `content/rust/basic.toml`) is imported once, as it is, so the
//! path from the real file to a Korean title on the wire is proven and not
//! just described.

use std::path::Path;

use cwbhacker_core::{content, progress, quests, world, Store};

const PACK: &str = include_str!("fixtures/rust_basic.toml");
const SHIPPED_PACK: &str = include_str!("../../../content/rust/basic.toml");
const SHIPPED_KO: &str = include_str!("../../../content/i18n/ko/rust.basic.toml");

const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";

/// A translation of the fixture's first two quests. `hints` counts match the
/// fixture: two for `hello`, one for `sum`.
const KO: &str = r#"
pack   = "rust.basic"
locale = "ko"

[[quest]]
id    = "rust.basic.01.hello"
title = "첫 불빛"
story = "터미널이 깜박인다. 예전엔 알던 문제다."
brief = '''
`hello, causewaybay`만 출력하고 다른 것은 출력하지 마세요.
'''
hints = ["`println!`은 매크로이므로 `!`가 붙습니다.", "문자열은 정확해야 합니다: 소문자, 쉼표 하나, 공백 하나."]

[[quest]]
id    = "rust.basic.02.sum"
title = "다시 세기"
story = "벽에 적힌 숫자들. 더하세요."
brief = '''
`n`을 읽고, 다음 줄의 정수 `n`개를 읽어 합을 출력하세요.
'''
hints = ["stdin 전체를 읽은 뒤 공백으로 나누세요."]
"#;

/// Lay a content tree out the way the repository does: the English pack
/// under `<root>/rust/basic.toml` and each translation under
/// `<root>/i18n/<locale>/<pack>.toml`.
fn content_tree(
    root: &Path,
    pack: &str,
    translations: &[(&str, &str, &str)],
) -> std::path::PathBuf {
    let src = root.join("content-src");
    std::fs::create_dir_all(src.join("rust")).unwrap();
    std::fs::write(src.join("rust/basic.toml"), pack).unwrap();
    for (locale, name, text) in translations {
        let dir = src.join("i18n").join(locale);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(format!("{name}.toml")), text).unwrap();
    }
    src
}

fn import(home: &Path, src: &Path) -> (Store, content::ImportReport) {
    let store = Store::open(home).expect("store opens");
    let report = {
        let conn = store.conn();
        content::import_dir(&conn, store.home(), src).expect("import ran")
    };
    (store, report)
}

#[test]
fn the_shipped_korean_sample_imports_and_reaches_the_wire() {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_tree(
        tmp.path(),
        SHIPPED_PACK,
        &[("ko", "rust.basic", SHIPPED_KO)],
    );
    let (store, report) = import(&tmp.path().join("home"), &src);
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    assert_eq!(report.translations.len(), 1);
    let t = &report.translations[0];
    assert_eq!((t.pack.as_str(), t.locale.as_str()), ("rust.basic", "ko"));
    // Not a count: this file grows as the language is translated, and a test
    // that pins "2" fails the day somebody writes the third quest, which is
    // the opposite of what it should do. The invariant is that every quest
    // the file does carry was written and none was skipped.
    assert!(t.quests > 0, "the shipped Korean file wrote nothing");
    assert!(t.skipped.is_empty(), "{:?}", t.skipped);

    let conn = store.conn();
    let text = quests::get_text(&conn, "rust.basic.01.first-light", Some("ko"))
        .unwrap()
        .expect("a Korean row for the first quest");
    assert_eq!(text.title, "첫 불빛");
    assert_eq!(text.hints.len(), 2);

    // The wire: Korean prose, English code, and the object says which it is.
    let quest = quests::get(&conn, "rust.basic.02.bindings")
        .unwrap()
        .localized(&conn, Some("ko"))
        .unwrap();
    let wire = quest.to_wire(progress::State::Open, 0, 0, None, None);
    assert_eq!(wire["text_locale"], "ko");
    assert_eq!(wire["title"], "요금표");
    assert!(
        wire["brief"].as_str().unwrap().contains("output: 12"),
        "the sample I/O is verbatim"
    );
    assert!(
        wire["starter"].as_str().unwrap().contains("fn main()"),
        "code is never translated"
    );
    assert_eq!(wire["hints_total"], 3);
    assert_eq!(
        quest.hints[1],
        "println!은 서식 문자열을 받습니다: println!(\"{}\", n)."
    );

    // The map: every node says for itself which language its title is in, and
    // it is right about it. Stated as the invariant rather than as "node 3 is
    // still English", because which nodes are translated is exactly what a
    // translator changes — the rule that has to hold is that `text_locale`
    // tracks the rows that exist, so a half-translated map is honest about
    // which half.
    let map = world::map_localized(&conn, ALICE, "rust", "basic", Some("ko")).unwrap();
    assert_eq!(map.nodes[0].title, "첫 불빛");
    for node in &map.nodes {
        let translated = quests::get_text(&conn, &node.quest_id, Some("ko"))
            .unwrap()
            .is_some();
        let want = if translated { "ko" } else { "en" };
        assert_eq!(
            node.text_locale, want,
            "{} has a Korean row: {translated}",
            node.quest_id
        );
    }
}

#[test]
fn english_and_unknown_locales_get_the_english_text() {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_tree(tmp.path(), PACK, &[("ko", "rust.basic", KO)]);
    let (store, report) = import(&tmp.path().join("home"), &src);
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    let conn = store.conn();
    for locale in [None, Some("en"), Some("xx"), Some(""), Some("ja")] {
        let quest = quests::get(&conn, "rust.basic.01.hello")
            .unwrap()
            .localized(&conn, locale)
            .unwrap();
        assert_eq!(quest.title, "FIRST LIGHT", "locale {locale:?}");
        assert_eq!(quest.text_locale, "en", "locale {locale:?}");
        let wire = quest.to_wire(progress::State::Open, 0, 0, None, None);
        assert_eq!(wire["text_locale"], "en");
        let map = world::map_localized(&conn, ALICE, "rust", "basic", locale).unwrap();
        assert!(map.nodes.iter().all(|n| n.text_locale == "en"));
    }
    // And the plain `map` is the English one, unchanged for every caller
    // that never heard of locales.
    let map = world::map(&conn, ALICE, "rust", "basic").unwrap();
    assert_eq!(map.nodes[0].title, "FIRST LIGHT");
    // While Korean is Korean.
    let quest = quests::get(&conn, "rust.basic.01.hello")
        .unwrap()
        .localized(&conn, Some("ko"))
        .unwrap();
    assert_eq!(quest.title, "첫 불빛");
    assert_eq!(quest.hints.len(), 2);
    assert_eq!(quest.text_locale, "ko");
}

#[test]
fn a_translation_whose_hint_count_disagrees_is_refused_whole() {
    let tmp = tempfile::tempdir().unwrap();
    // `sum` has one hint in English; two here.
    let bad = KO.replace(
        r#"hints = ["stdin 전체를 읽은 뒤 공백으로 나누세요."]"#,
        r#"hints = ["하나", "둘"]"#,
    );
    assert_ne!(bad, KO);
    let src = content_tree(tmp.path(), PACK, &[("ko", "rust.basic", bad.as_str())]);
    let (store, report) = import(&tmp.path().join("home"), &src);
    assert_eq!(report.failures.len(), 1, "{:?}", report.failures);
    let (path, reason) = &report.failures[0];
    assert!(path.ends_with("i18n/ko/rust.basic.toml"), "{path}");
    assert!(
        reason.contains("rust.basic.02.sum") && reason.contains("hints"),
        "{reason}"
    );
    assert!(report.translations.is_empty());
    // Refused whole: the good row for `hello` was rolled back with it.
    let conn = store.conn();
    let rows: i64 = conn
        .query_row("SELECT count(*) FROM quest_text", [], |r| r.get(0))
        .unwrap();
    assert_eq!(rows, 0);
    // And the English pack itself is untouched by a bad translation.
    assert_eq!(report.packs.len(), 1);
    assert_eq!(
        quests::get(&conn, "rust.basic.01.hello").unwrap().title,
        "FIRST LIGHT"
    );
}

#[test]
fn a_translation_for_a_quest_nobody_supplies_is_skipped_not_fatal() {
    let tmp = tempfile::tempdir().unwrap();
    let extra = format!(
        r#"{KO}
[[quest]]
id    = "rust.basic.99.ghost"
title = "유령"
brief = '''
없는 퀘스트.
'''
hints = []
"#
    );
    let src = content_tree(tmp.path(), PACK, &[("ko", "rust.basic", extra.as_str())]);
    let (store, report) = import(&tmp.path().join("home"), &src);
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    let t = &report.translations[0];
    assert_eq!(t.quests, 2);
    assert_eq!(t.skipped, vec!["rust.basic.99.ghost".to_string()]);
    let conn = store.conn();
    assert!(quests::get_text(&conn, "rust.basic.01.hello", Some("ko"))
        .unwrap()
        .is_some());
    assert!(quests::get_text(&conn, "rust.basic.99.ghost", Some("ko"))
        .unwrap()
        .is_none());
}

#[test]
fn the_file_rules_are_checked_before_any_row_is_written() {
    // Each of these is a whole-file refusal with a reason that names the
    // rule, and none of them touches the English pack.
    let cases: Vec<(&str, String, &str)> = vec![
        (
            "locale",
            KO.replace("locale = \"ko\"", "locale = \"xx\""),
            "locale 'xx'",
        ),
        (
            "id shape",
            KO.replace("rust.basic.01.hello", "rust.basic.1.hello"),
            "not <land>.<category>.<node:02d>.<slug>",
        ),
        (
            "id outside the pack",
            KO.replace("rust.basic.01.hello", "go.basic.01.hello"),
            "does not belong to pack rust.basic",
        ),
        (
            "basic string on brief",
            KO.replace("brief = '''\n`hello", "brief = \"\"\"\n`hello")
                .replace("마세요.\n'''", "마세요.\n\"\"\""),
            "TOML basic string",
        ),
    ];
    for (what, text, expect) in cases {
        let tmp = tempfile::tempdir().unwrap();
        // The locale case must be filed under its own name or the directory
        // check fires first; put it where the file says it belongs.
        let dir = if what == "locale" { "xx" } else { "ko" };
        let src = content_tree(tmp.path(), PACK, &[(dir, "rust.basic", text.as_str())]);
        let (store, report) = import(&tmp.path().join("home"), &src);
        assert_eq!(report.failures.len(), 1, "{what}: {:?}", report.failures);
        assert!(
            report.failures[0].1.contains(expect),
            "{what}: expected {expect:?} in {:?}",
            report.failures[0].1
        );
        assert_eq!(
            report.packs.len(),
            1,
            "{what}: the English pack still imported"
        );
        let conn = store.conn();
        let rows: i64 = conn
            .query_row("SELECT count(*) FROM quest_text", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rows, 0, "{what}");
    }
}

#[test]
fn a_translation_is_never_mistaken_for_a_pack_nor_a_pack_for_a_translation() {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_tree(tmp.path(), PACK, &[]);
    // A translation dropped next to the English packs. It is recognised by
    // its `locale` key, not its path, so it is refused as a *misfiled
    // translation* — the message says where it belongs — and never parsed
    // as a pack missing `land`.
    std::fs::write(src.join("rust/stray.toml"), KO).unwrap();
    // And a pack under i18n/ is still a pack: it imports as one.
    std::fs::create_dir_all(src.join("i18n/ko")).unwrap();
    std::fs::write(
        src.join("i18n/ko/rust.basic.toml"),
        PACK.replace(
            "pack = \"rust.basic\"",
            "pack = \"rust.basic\"\n# a pack, misfiled",
        ),
    )
    .unwrap();
    let (store, report) = import(&tmp.path().join("home"), &src);
    assert_eq!(report.failures.len(), 1, "{:?}", report.failures);
    let (path, reason) = &report.failures[0];
    assert!(path.ends_with("rust/stray.toml"), "{path}");
    assert!(reason.contains("sits under i18n/rust/"), "{reason}");
    assert!(report.translations.is_empty());
    assert_eq!(
        report.packs.len(),
        2,
        "the stray pack imported as a pack, twice over"
    );

    // `doctor`'s audit walks the same tree and must not report a translation
    // as an unreadable pack.
    let src2 = content_tree(&tmp.path().join("two"), PACK, &[("ko", "rust.basic", KO)]);
    let conn = store.conn();
    let audits = content::audit_dir(&conn, &src2).unwrap();
    assert_eq!(audits.len(), 1, "{audits:?}");
    assert!(audits[0].path.ends_with("rust/basic.toml"));
}

#[test]
fn a_reimport_replaces_the_locale_and_a_dropped_quest_goes_back_to_english() {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_tree(tmp.path(), PACK, &[("ko", "rust.basic", KO)]);
    let home = tmp.path().join("home");
    let (store, report) = import(&home, &src);
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    drop(store);
    // The file now covers only `hello`, with a new title.
    let shorter = KO
        .split("[[quest]]\nid    = \"rust.basic.02.sum\"")
        .next()
        .unwrap();
    let shorter = shorter.replace("첫 불빛", "첫 빛");
    std::fs::write(src.join("i18n/ko/rust.basic.toml"), shorter).unwrap();
    let (store, report) = import(&home, &src);
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    let conn = store.conn();
    let hello = quests::get_text(&conn, "rust.basic.01.hello", Some("ko"))
        .unwrap()
        .unwrap();
    assert_eq!(hello.title, "첫 빛");
    assert!(quests::get_text(&conn, "rust.basic.02.sum", Some("ko"))
        .unwrap()
        .is_none());
    let map = world::map_localized(&conn, ALICE, "rust", "basic", Some("ko")).unwrap();
    assert_eq!(map.nodes[1].text_locale, "en");
    assert_eq!(map.nodes[1].title, "COUNTING AGAIN");
}
