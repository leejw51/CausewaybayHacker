//! REMIX LAND (SPEC §0, §12): the one land that is not a language. A quest
//! there says which of Go, Rust and Python judges it, and everything that
//! used to read the land as the language reads `lang` instead.

use cwbhacker_core::{content, progress, quests, Store};

const REMIX_PACK: &str = include_str!("fixtures/remix_basic.toml");
const RUST_PACK: &str = include_str!("fixtures/rust_basic.toml");

fn import(pack: &str, land: &str) -> (tempfile::TempDir, Store, content::ImportReport) {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    let dir = tmp.path().join("content-src").join(land);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), pack).unwrap();
    let report = {
        let conn = store.conn();
        content::import_dir(&conn, store.home(), &tmp.path().join("content-src")).unwrap()
    };
    (tmp, store, report)
}

#[test]
fn a_remix_trio_imports_with_a_language_per_quest_and_the_wire_says_which() {
    let (_tmp, store, report) = import(REMIX_PACK, "remix");
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    let conn = store.conn();
    let trio = quests::list(&conn, "remix", "basic").unwrap();
    assert_eq!(trio.len(), 3, "{trio:?}");
    let langs: Vec<&str> = trio.iter().map(|q| q.lang.as_str()).collect();
    assert_eq!(
        langs,
        ["go", "rust", "python"],
        "the trio's order is the land's promise"
    );
    for q in &trio {
        assert_eq!(q.land, "remix");
        // PROTOCOL §5.3: both fields go out, and they differ here — which is
        // the whole reason `lang` exists on the wire.
        let wire = q.to_wire(progress::State::Open, 0, 0, None, None);
        assert_eq!(wire["land"], "remix");
        assert_eq!(wire["lang"], q.lang.as_str());
    }
}

#[test]
fn a_language_land_gets_its_lang_from_its_land_and_the_wire_carries_it_too() {
    let (_tmp, store, report) = import(RUST_PACK, "rust");
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    let conn = store.conn();
    for q in quests::list(&conn, "rust", "basic").unwrap() {
        assert_eq!(q.lang, "rust", "{}: the land is the language", q.id);
        let wire = q.to_wire(progress::State::Open, 0, 0, None, None);
        assert_eq!(wire["lang"], "rust");
    }
}

#[test]
fn a_remix_quest_must_say_its_language_and_it_must_be_one_of_the_three() {
    // No `lang` at all: the runner would have nothing to dispatch on.
    let text = REMIX_PACK.replacen("lang        = \"go\"\n", "", 1);
    let pack: content::Pack = toml::from_str(&text).unwrap();
    let err = content::validate(&pack).unwrap_err().to_string();
    assert!(err.contains("no lang"), "{err}");

    // A language the land does not speak.
    let text = REMIX_PACK.replacen("lang        = \"go\"", "lang        = \"cpp\"", 1);
    let pack: content::Pack = toml::from_str(&text).unwrap();
    let err = content::validate(&pack).unwrap_err().to_string();
    assert!(
        err.contains("cpp") && err.contains("go, rust or python"),
        "{err}"
    );
}

#[test]
fn a_language_land_refuses_a_lang_of_its_own() {
    // `lang` in a language land is either redundant (equal to the land) or a
    // trap (a Go program sent to rustc). The first is allowed, the second is
    // refused at import.
    let text = RUST_PACK.replacen(
        "node        = 1\n",
        "node        = 1\nlang        = \"rust\"\n",
        1,
    );
    let pack: content::Pack = toml::from_str(&text).unwrap();
    content::validate(&pack).expect("a lang equal to the land is harmless");

    let text = RUST_PACK.replacen(
        "node        = 1\n",
        "node        = 1\nlang        = \"go\"\n",
        1,
    );
    let pack: content::Pack = toml::from_str(&text).unwrap();
    let err = content::validate(&pack).unwrap_err().to_string();
    assert!(err.contains("only remix quests"), "{err}");
}

#[test]
fn the_checksum_of_a_language_land_quest_did_not_move_when_lang_arrived() {
    // `lang` is folded into the checksum only when a pack says it, so every
    // quest in the six language lands keeps the checksum it had before the
    // field existed and nobody's progress is reported "updated" for nothing.
    let pack: content::Pack = toml::from_str(RUST_PACK).unwrap();
    let before = content::checksum(&pack.quests[0]).unwrap();
    let mut with = pack.quests[0].clone();
    with.lang = Some("rust".into());
    let after = content::checksum(&with).unwrap();
    assert_ne!(before, after, "a stated lang is part of the identity");
    let mut without = with.clone();
    without.lang = None;
    assert_eq!(content::checksum(&without).unwrap(), before);
}
