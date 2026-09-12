//! `locale?` on `quest.get`, `world.map` and `quest.hint` (PROTOCOL §4.7,
//! §4.8, §4.10): the handlers substitute a translation when one exists and
//! say which language went out, and an unknown locale is English rather than
//! an error. Driven through the handlers directly; the socket layer adds
//! nothing here and `ws_flow.rs` already proves it carries a payload.

use std::sync::Arc;

use cwbhacker_core::{content, users, Store};
use cwbhacker_server::handlers::{self, Session};
use serde_json::json;

const PACK: &str = include_str!("../../core/tests/fixtures/rust_basic.toml");
const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";

const KO: &str = r#"
pack   = "rust.basic"
locale = "ko"

[[quest]]
id    = "rust.basic.01.hello"
title = "첫 불빛"
story = "터미널이 깜박인다."
brief = '''
`hello, causewaybay`만 출력하세요.
'''
hints = ["`println!`은 매크로입니다.", "문자열은 정확해야 합니다."]
"#;

fn state(root: &std::path::Path) -> cwbhacker_server::Shared {
    let src = root.join("content-src");
    std::fs::create_dir_all(src.join("rust")).unwrap();
    std::fs::create_dir_all(src.join("i18n/ko")).unwrap();
    std::fs::write(src.join("rust/basic.toml"), PACK).unwrap();
    std::fs::write(src.join("i18n/ko/rust.basic.toml"), KO).unwrap();
    let store = Arc::new(Store::open(&root.join("home")).expect("store"));
    {
        let conn = store.conn();
        let report = content::import_dir(&conn, store.home(), &src).expect("import");
        assert!(report.failures.is_empty(), "{:?}", report.failures);
        assert_eq!(report.translations.len(), 1);
        // Taking a hint writes progress, and progress belongs to a user.
        users::upsert(&conn, ALICE).unwrap();
    }
    let config = cwbhacker_server::Config {
        bind: "127.0.0.1:0".parse().unwrap(),
        static_dir: None,
        art_dir: None,
    };
    cwbhacker_server::build_state(store, &config)
}

fn alice() -> Session {
    Session {
        address: Some(ALICE.to_string()),
    }
}

#[test]
fn quest_get_answers_in_the_locale_it_has_and_english_otherwise() {
    let tmp = tempfile::tempdir().unwrap();
    let state = state(tmp.path());
    let session = alice();

    let ko = handlers::quest_get(
        &state,
        &session,
        &json!({ "quest_id": "rust.basic.01.hello", "locale": "ko" }),
    )
    .unwrap();
    assert_eq!(ko["quest"]["text_locale"], "ko");
    assert_eq!(ko["quest"]["title"], "첫 불빛");
    assert_eq!(ko["quest"]["story"], "터미널이 깜박인다.");
    assert!(ko["quest"]["brief"]
        .as_str()
        .unwrap()
        .contains("hello, causewaybay"));
    assert_eq!(ko["quest"]["hints_total"], 2);
    // Code is the English pack's, whatever the locale.
    assert!(ko["quest"]["starter"]
        .as_str()
        .unwrap()
        .contains("fn main()"));

    // A locale nobody wrote a pack for, a locale outside the set, and no
    // locale at all: all three are English and say so.
    for payload in [
        json!({ "quest_id": "rust.basic.01.hello", "locale": "xx" }),
        json!({ "quest_id": "rust.basic.01.hello", "locale": "ja" }),
        json!({ "quest_id": "rust.basic.01.hello" }),
    ] {
        let en = handlers::quest_get(&state, &session, &payload).unwrap();
        assert_eq!(en["quest"]["text_locale"], "en", "{payload}");
        assert_eq!(en["quest"]["title"], "FIRST LIGHT", "{payload}");
    }

    // A quest the Korean file does not cover is English under `ko` too —
    // per quest, not per file.
    let sum = handlers::quest_get(
        &state,
        &session,
        &json!({ "quest_id": "rust.basic.02.sum", "locale": "ko" }),
    )
    .unwrap();
    assert_eq!(sum["quest"]["text_locale"], "en");
    assert_eq!(sum["quest"]["title"], "COUNTING AGAIN");
}

#[test]
fn world_map_titles_follow_the_locale_node_by_node() {
    let tmp = tempfile::tempdir().unwrap();
    let state = state(tmp.path());
    let session = alice();
    let map = handlers::world_map(
        &state,
        &session,
        &json!({ "land": "rust", "category": "basic", "locale": "ko" }),
    )
    .unwrap();
    let nodes = map["nodes"].as_array().unwrap();
    assert_eq!(nodes[0]["title"], "첫 불빛");
    assert_eq!(nodes[0]["text_locale"], "ko");
    assert_eq!(nodes[1]["title"], "COUNTING AGAIN");
    assert_eq!(nodes[1]["text_locale"], "en");

    let map = handlers::world_map(
        &state,
        &session,
        &json!({ "land": "rust", "category": "basic", "locale": "xx" }),
    )
    .unwrap();
    let nodes = map["nodes"].as_array().unwrap();
    assert_eq!(nodes[0]["title"], "FIRST LIGHT");
    assert_eq!(nodes[0]["text_locale"], "en");
}

#[test]
fn a_hint_is_handed_out_in_the_locale_at_the_same_index() {
    let tmp = tempfile::tempdir().unwrap();
    let state = state(tmp.path());
    let session = alice();
    let ko = handlers::quest_hint(
        &state,
        &session,
        &json!({ "quest_id": "rust.basic.01.hello", "index": 1, "locale": "ko" }),
    )
    .unwrap();
    assert_eq!(ko["hint"], "문자열은 정확해야 합니다.");
    assert_eq!(ko["total"], 2);
    let en = handlers::quest_hint(
        &state,
        &session,
        &json!({ "quest_id": "rust.basic.01.hello", "index": 1 }),
    )
    .unwrap();
    assert_eq!(
        en["hint"],
        "The string is exact: lowercase, one comma, one space."
    );
    // Re-taking the same hint in another language costs nothing more.
    assert_eq!(en["hints_used"], ko["hints_used"]);
}
