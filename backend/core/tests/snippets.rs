//! The scratchpad caps (PROTOCOL §4.9c). The source limit is asserted where
//! the chat tests build their room; this file is for the input a pad keeps,
//! which used to be the one field a client could grow without bound.

use cwbhacker_core::error::Code;
use cwbhacker_core::snippets::{self, MAX_STDIN_BYTES};
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
