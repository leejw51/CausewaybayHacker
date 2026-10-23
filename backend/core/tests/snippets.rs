//! The scratchpad caps (PROTOCOL §4.9c). The source limit is asserted where
//! the chat tests build their room; this file is for the input a pad keeps,
//! which used to be the one field a client could grow without bound.

use cwbhacker_core::error::Code;
use cwbhacker_core::snippets::{self, MAX_SNIPPETS_PER_USER, MAX_STDIN_BYTES};
use cwbhacker_core::{users, Store};

const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";

#[test]
fn a_pads_stdin_is_capped_like_its_source() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    let conn = store.conn();
    users::upsert(&conn, ALICE).unwrap();

    let exactly = "x".repeat(MAX_STDIN_BYTES);
    let saved = snippets::save(
        &conn,
        store.home(),
        ALICE,
        None,
        Some("input"),
        "rust",
        "fn main() {}\n",
        Some(&exactly),
    )
    .expect("the limit itself is allowed");
    assert_eq!(saved.stdin.len(), MAX_STDIN_BYTES);

    let over = "x".repeat(MAX_STDIN_BYTES + 1);
    let err = snippets::save(
        &conn,
        store.home(),
        ALICE,
        Some(&saved.id),
        None,
        "rust",
        "fn main() {}\n",
        Some(&over),
    )
    .unwrap_err();
    assert_eq!(err.code, Code::BadRequest);
    assert!(
        err.message.contains(&MAX_STDIN_BYTES.to_string()),
        "the refusal says what the limit is: {}",
        err.message
    );

    // And the refusal changed nothing.
    let kept = snippets::get(&conn, ALICE, &saved.id).unwrap();
    assert_eq!(kept.stdin.len(), MAX_STDIN_BYTES);
}

/// 64 pads filled in under a month of ordinary use, and from then on every
/// autosave of a new scratchpad was refused. The shelf is now a thousand, and
/// a full one still lets the pads already on it be saved.
#[test]
fn the_shelf_holds_a_thousand_pads_and_a_full_one_still_saves_its_own() {
    assert_eq!(MAX_SNIPPETS_PER_USER, 1000);
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    let conn = store.conn();
    users::upsert(&conn, ALICE).unwrap();

    let save = |id: Option<&str>, source: &str| {
        snippets::save(&conn, store.home(), ALICE, id, None, "rust", source, None)
    };
    let first = save(None, "fn main() {}\n").unwrap();
    for i in 1..MAX_SNIPPETS_PER_USER {
        save(None, &format!("fn main() {{ /* {i} */ }}\n")).unwrap_or_else(|e| {
            panic!(
                "pad {i} of {MAX_SNIPPETS_PER_USER} was refused: {}",
                e.message
            )
        });
    }

    let err = save(None, "fn main() { /* one too many */ }\n").unwrap_err();
    assert_eq!(err.code, Code::BadRequest);
    assert!(
        err.message
            .contains(&format!("the limit is {MAX_SNIPPETS_PER_USER}")),
        "the refusal says what the limit is: {}",
        err.message
    );

    let kept = save(Some(&first.id), "fn main() { /* edited */ }\n")
        .expect("a full shelf still saves the pads already on it");
    assert!(kept.source.contains("edited"));
}
