//! The edit stack (`core/src/edits.rs`): push, undo, redo and clear, the cap,
//! and the two properties that come from storing the source on disk under its
//! own hash rather than in a column.

use cwbhacker_core::{content, edits, users, Store};

const PACK: &str = include_str!("fixtures/rust_basic.toml");
const CPP: &str = include_str!("fixtures/cpp_basic.toml");

const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";
const BOB: &str = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";
const HELLO: &str = "rust.basic.01.hello";
const SUM: &str = "rust.basic.02.sum";

fn store() -> (tempfile::TempDir, Store) {
    let tmp = tempfile::tempdir().unwrap();
    let src = tmp.path().join("content-src");
    std::fs::create_dir_all(src.join("rust")).unwrap();
    std::fs::create_dir_all(src.join("cpp")).unwrap();
    std::fs::write(src.join("rust/basic.toml"), PACK).unwrap();
    std::fs::write(src.join("cpp/basic.toml"), CPP).unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    {
        let conn = store.conn();
        let report = content::import_dir(&conn, store.home(), &src).unwrap();
        assert!(report.failures.is_empty(), "{:?}", report.failures);
        users::upsert(&conn, ALICE).unwrap();
        users::upsert(&conn, BOB).unwrap();
    }
    (tmp, store)
}

/// How many blobs are on disk for one stack — the number that says whether
/// content addressing is doing its job.
fn blobs(store: &Store, address: &str, quest_id: &str) -> usize {
    let dir = store.home().edit_dir(address, quest_id);
    match std::fs::read_dir(&dir) {
        Ok(entries) => entries.count(),
        Err(_) => 0,
    }
}

#[test]
fn push_undo_redo_walk_the_cursor_over_the_entries() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let home = store.home();

    // An untouched quest: nothing pushed, nothing to undo, and `source` is
    // null rather than a copy of the starter.
    let fresh = edits::state(&conn, home, ALICE, HELLO).unwrap();
    assert_eq!(fresh.quest_id, HELLO);
    assert_eq!(fresh.source, None);
    assert_eq!((fresh.cursor, fresh.depth), (0, 0));
    assert!(!fresh.can_undo && !fresh.can_redo);

    for (n, text) in ["one", "two", "three"].iter().enumerate() {
        let pushed = edits::push(&conn, home, ALICE, HELLO, text).unwrap();
        assert_eq!(pushed.source.as_deref(), Some(*text));
        assert_eq!(pushed.cursor, n as i64 + 1);
        assert_eq!(pushed.depth, n as i64 + 1);
        assert!(pushed.can_undo);
        assert!(
            !pushed.can_redo,
            "the top of the stack has nothing above it"
        );
    }

    let back = edits::undo(&conn, home, ALICE, HELLO).unwrap();
    assert_eq!(back.source.as_deref(), Some("two"));
    assert_eq!((back.cursor, back.depth), (2, 3));
    assert!(back.can_undo && back.can_redo);

    let bottom = edits::undo(&conn, home, ALICE, HELLO).unwrap();
    assert_eq!(bottom.source.as_deref(), Some("one"));
    let starter = edits::undo(&conn, home, ALICE, HELLO).unwrap();
    assert_eq!(starter.source, None, "under the first entry is the starter");
    assert_eq!((starter.cursor, starter.depth), (0, 3));
    assert!(!starter.can_undo && starter.can_redo);

    // The bottom is not an error, it is a place: undoing again says so.
    let floor = edits::undo(&conn, home, ALICE, HELLO).unwrap();
    assert_eq!((floor.cursor, floor.depth), (0, 3));

    for (n, text) in ["one", "two", "three"].iter().enumerate() {
        let forward = edits::redo(&conn, home, ALICE, HELLO).unwrap();
        assert_eq!(forward.source.as_deref(), Some(*text));
        assert_eq!(forward.cursor, n as i64 + 1);
    }
    let ceiling = edits::redo(&conn, home, ALICE, HELLO).unwrap();
    assert_eq!((ceiling.cursor, ceiling.depth), (3, 3));
    assert!(!ceiling.can_redo);

    // And it survives being asked about again, which is the whole point of
    // putting it in the home rather than in a client's memory.
    let reopened = edits::state(&conn, home, ALICE, HELLO).unwrap();
    assert_eq!(reopened.source.as_deref(), Some("three"));
    assert_eq!((reopened.cursor, reopened.depth), (3, 3));
}

/// The classic editor rule: an edit made after an undo throws away everything
/// that was in front of the cursor.
#[test]
fn a_push_after_an_undo_drops_the_redo_tail() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let home = store.home();

    for text in ["one", "two", "three"] {
        edits::push(&conn, home, ALICE, HELLO, text).unwrap();
    }
    edits::undo(&conn, home, ALICE, HELLO).unwrap();
    edits::undo(&conn, home, ALICE, HELLO).unwrap();
    let branched = edits::push(&conn, home, ALICE, HELLO, "elsewhere").unwrap();
    assert_eq!((branched.cursor, branched.depth), (2, 2));
    assert!(!branched.can_redo, "'three' is gone, not waiting");
    assert_eq!(branched.source.as_deref(), Some("elsewhere"));

    // Its bytes went with it: nothing names "three"'s sha any more.
    assert_eq!(blobs(&store, ALICE, HELLO), 2);
    assert_eq!(
        edits::undo(&conn, home, ALICE, HELLO)
            .unwrap()
            .source
            .as_deref(),
        Some("one")
    );
}

/// The client pushes on an idle timer, so the same text arriving twice must
/// cost nothing. The starter counts as the current source at cursor 0 — it is
/// what the editor is showing — so opening a quest and idling does not put an
/// entry on the stack.
#[test]
fn pushing_what_is_already_current_is_a_no_op() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let home = store.home();
    let starter = {
        let quest = cwbhacker_core::quests::get(&conn, HELLO).unwrap();
        quest.starter
    };

    let idle = edits::push(&conn, home, ALICE, HELLO, &starter).unwrap();
    assert_eq!(
        (idle.cursor, idle.depth),
        (0, 0),
        "the untouched starter is not an edit"
    );
    assert_eq!(blobs(&store, ALICE, HELLO), 0);

    edits::push(&conn, home, ALICE, HELLO, "one").unwrap();
    for _ in 0..5 {
        let again = edits::push(&conn, home, ALICE, HELLO, "one").unwrap();
        assert_eq!((again.cursor, again.depth), (1, 1));
    }
    // A push of the starter now *is* an edit — the editor was showing "one".
    let reverted = edits::push(&conn, home, ALICE, HELLO, &starter).unwrap();
    assert_eq!((reverted.cursor, reverted.depth), (2, 2));
}

/// A hundred entries per quest, and past that the oldest goes. The cursor has
/// to follow the entry it was pointing at down one place, or a trim would
/// silently move the player's text.
#[test]
fn the_cap_drops_the_oldest_entry_and_keeps_the_cursor_on_its_own() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let home = store.home();

    for n in 0..edits::MAX_ENTRIES {
        let pushed = edits::push(&conn, home, ALICE, HELLO, &format!("edit {n}")).unwrap();
        assert_eq!(pushed.depth, n as i64 + 1);
    }
    let full = edits::state(&conn, home, ALICE, HELLO).unwrap();
    assert_eq!((full.cursor, full.depth), (100, 100));

    let over = edits::push(&conn, home, ALICE, HELLO, "one too many").unwrap();
    assert_eq!(
        (over.cursor, over.depth),
        (100, 100),
        "the stack stays at the cap instead of growing"
    );
    assert_eq!(over.source.as_deref(), Some("one too many"));
    assert_eq!(blobs(&store, ALICE, HELLO), 100, "'edit 0' was unlinked");

    // The arithmetic boundary: one undo off the top of a full stack, then a
    // push. Truncating the one-entry redo tail takes the stack to 99 and the
    // append puts it back on 100, so this must land exactly on the cap without
    // trimming anything — a trim here would drop 'edit 1' for nothing.
    edits::undo(&conn, home, ALICE, HELLO).unwrap();
    let refilled = edits::push(&conn, home, ALICE, HELLO, "back to the top").unwrap();
    assert_eq!((refilled.cursor, refilled.depth), (100, 100));

    // Walking all the way down lands on 'edit 1', the new oldest, and the
    // entry below it is the starter.
    for _ in 0..99 {
        edits::undo(&conn, home, ALICE, HELLO).unwrap();
    }
    let oldest = edits::state(&conn, home, ALICE, HELLO).unwrap();
    assert_eq!(oldest.source.as_deref(), Some("edit 1"));
    assert_eq!(oldest.cursor, 1);
    assert_eq!(edits::undo(&conn, home, ALICE, HELLO).unwrap().source, None);

    // Undoing near the bottom and pushing again renumbers cleanly — the seq
    // column is the primary key, so a trim that did not renumber would have
    // collided by now.
    let branched = edits::push(&conn, home, ALICE, HELLO, "from the bottom").unwrap();
    assert_eq!((branched.cursor, branched.depth), (1, 1));
}

/// Content addressing: coming back to text that is already in the store costs
/// a row, not a file.
#[test]
fn the_same_text_twice_is_one_file() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let home = store.home();

    edits::push(&conn, home, ALICE, HELLO, "alpha").unwrap();
    edits::push(&conn, home, ALICE, HELLO, "beta").unwrap();
    let third = edits::push(&conn, home, ALICE, HELLO, "alpha").unwrap();
    assert_eq!(third.depth, 3, "three entries");
    assert_eq!(blobs(&store, ALICE, HELLO), 2, "two distinct sources");

    // And the shared blob survives one of the two rows going away.
    edits::undo(&conn, home, ALICE, HELLO).unwrap();
    edits::undo(&conn, home, ALICE, HELLO).unwrap();
    let branched = edits::push(&conn, home, ALICE, HELLO, "gamma").unwrap();
    assert_eq!(branched.depth, 2);
    assert_eq!(
        edits::undo(&conn, home, ALICE, HELLO)
            .unwrap()
            .source
            .as_deref(),
        Some("alpha"),
        "the first entry still reads, though the third named the same file"
    );
}

/// CLEAR STACK is the button the brief asks for. It drops the history and
/// nothing else — no attempt, no progress, and the editor keeps its text.
#[test]
fn clear_drops_the_history_and_the_files_with_it() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let home = store.home();

    for text in ["one", "two", "three"] {
        edits::push(&conn, home, ALICE, HELLO, text).unwrap();
    }
    edits::undo(&conn, home, ALICE, HELLO).unwrap();
    assert_eq!(blobs(&store, ALICE, HELLO), 3);

    let cleared = edits::clear(&conn, home, ALICE, HELLO).unwrap();
    assert_eq!((cleared.cursor, cleared.depth), (0, 0));
    assert!(!cleared.can_undo && !cleared.can_redo);
    assert_eq!(cleared.source, None);
    assert_eq!(blobs(&store, ALICE, HELLO), 0);

    // Clearing an empty stack is not an error, and the stack still works.
    edits::clear(&conn, home, ALICE, HELLO).unwrap();
    let after = edits::push(&conn, home, ALICE, HELLO, "starting over").unwrap();
    assert_eq!((after.cursor, after.depth), (1, 1));
}

/// One stack per (address, quest). Two quests do not share one, two players
/// do not share one, and an address spelled in EIP-55 is the same player as
/// the same address in lowercase (SPEC §3.4).
#[test]
fn a_stack_belongs_to_one_player_and_one_quest() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let home = store.home();

    edits::push(&conn, home, ALICE, HELLO, "alice on hello").unwrap();
    edits::push(&conn, home, ALICE, SUM, "alice on sum").unwrap();
    edits::push(&conn, home, BOB, HELLO, "bob on hello").unwrap();

    for (address, quest_id, text) in [
        (ALICE, HELLO, "alice on hello"),
        (ALICE, SUM, "alice on sum"),
        (BOB, HELLO, "bob on hello"),
    ] {
        let state = edits::state(&conn, home, address, quest_id).unwrap();
        assert_eq!(state.depth, 1, "{address} {quest_id}");
        assert_eq!(state.source.as_deref(), Some(text));
    }

    let shouting = ALICE.to_ascii_uppercase().replace("0X", "0x");
    let same = edits::state(&conn, home, &shouting, HELLO).unwrap();
    assert_eq!(same.source.as_deref(), Some("alice on hello"));
}

/// A quest that is cut from a pack takes its history with it: the rows are
/// `ON DELETE CASCADE` against `quests`, so a reimport that drops a node
/// cannot leave a stack pointing at something nobody can open.
#[test]
fn the_stack_goes_when_the_quest_does() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let home = store.home();

    edits::push(&conn, home, ALICE, HELLO, "one").unwrap();
    edits::push(&conn, home, ALICE, HELLO, "two").unwrap();
    edits::push(&conn, home, ALICE, SUM, "elsewhere").unwrap();

    conn.execute("DELETE FROM quests WHERE id = ?1", [HELLO])
        .unwrap();
    let rows: i64 = conn
        .query_row(
            "SELECT count(*) FROM edit_stack WHERE quest_id = ?1",
            [HELLO],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(rows, 0, "the entries cascaded");
    let cursors: i64 = conn
        .query_row(
            "SELECT count(*) FROM edit_cursor WHERE quest_id = ?1",
            [HELLO],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(cursors, 0, "and so did the cursor");

    // The quest is gone, so asking about it is `not_found` rather than an
    // empty stack — the same answer `quest.get` gives.
    let err = edits::state(&conn, home, ALICE, HELLO).unwrap_err();
    assert_eq!(err.code, cwbhacker_core::Code::NotFound, "{}", err.message);

    // The other quest is untouched.
    assert_eq!(edits::state(&conn, home, ALICE, SUM).unwrap().depth, 1);
}

/// The same 256 KiB `quest.submit` takes, refused in the model rather than at
/// the socket.
#[test]
fn a_source_over_the_cap_is_refused() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let home = store.home();

    let big = "x".repeat(edits::MAX_SOURCE_BYTES + 1);
    let err = edits::push(&conn, home, ALICE, HELLO, &big).unwrap_err();
    assert_eq!(
        err.code,
        cwbhacker_core::Code::BadRequest,
        "{}",
        err.message
    );
    assert_eq!(edits::state(&conn, home, ALICE, HELLO).unwrap().depth, 0);

    // Exactly at the cap is fine.
    let edge = "y".repeat(edits::MAX_SOURCE_BYTES);
    assert_eq!(
        edits::push(&conn, home, ALICE, HELLO, &edge).unwrap().depth,
        1
    );
}

/// The blob is named for the land's own source extension, so a stack in the
/// home can be opened with an editor and the editor knows what it is looking
/// at. Reused from `attempts::source_filename` rather than a second table.
#[test]
fn the_files_are_named_for_the_land() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let home = store.home();

    edits::push(&conn, home, ALICE, HELLO, "fn main() {}").unwrap();
    edits::push(&conn, home, ALICE, "cpp.basic.01.hello", "int main() {}").unwrap();

    for (quest_id, ext) in [(HELLO, "rs"), ("cpp.basic.01.hello", "cpp")] {
        let dir = store.home().edit_dir(ALICE, quest_id);
        let names: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names.len(), 1, "{quest_id}");
        assert!(
            names[0].ends_with(&format!(".{ext}")),
            "{quest_id}: {}",
            names[0]
        );
        // 64 hex of sha256, plus the dot and the extension.
        assert_eq!(names[0].len(), 64 + 1 + ext.len(), "{}", names[0]);
    }
}

/// An unknown quest is `not_found` on every one of the five, not just on read.
#[test]
fn an_unknown_quest_is_not_found_everywhere() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let home = store.home();
    const GHOST: &str = "rust.basic.99.nowhere";

    for err in [
        edits::state(&conn, home, ALICE, GHOST).unwrap_err(),
        edits::push(&conn, home, ALICE, GHOST, "x").unwrap_err(),
        edits::undo(&conn, home, ALICE, GHOST).unwrap_err(),
        edits::redo(&conn, home, ALICE, GHOST).unwrap_err(),
        edits::clear(&conn, home, ALICE, GHOST).unwrap_err(),
    ] {
        assert_eq!(err.code, cwbhacker_core::Code::NotFound, "{}", err.message);
    }
}

/// `world.reset` takes the road's stacks with it (PROTOCOL §4.7b) — every
/// quest of that land and category, this player's only, and only that road.
/// The stack decides what the editor opens on, so a road left with its
/// history is a road that re-opens on the code that cleared it.
#[test]
fn a_road_reset_clears_that_road_s_stacks_and_no_others() {
    let (_tmp, store) = store();
    let conn = store.conn();
    let home = store.home();

    for text in ["one", "two"] {
        edits::push(&conn, home, ALICE, HELLO, text).unwrap();
    }
    edits::push(&conn, home, ALICE, SUM, "alice on the second node").unwrap();
    edits::push(&conn, home, BOB, HELLO, "bob's own work").unwrap();
    edits::push(&conn, home, ALICE, "cpp.basic.01.hello", "another land").unwrap();

    let cleared = edits::clear_road(&conn, home, ALICE, "rust", "basic").unwrap();
    assert_eq!(cleared, 2, "two of alice's rust/basic quests had a stack");

    for quest in [HELLO, SUM] {
        let state = edits::state(&conn, home, ALICE, quest).unwrap();
        assert_eq!((state.cursor, state.depth), (0, 0), "{quest}");
        assert_eq!(state.source, None, "{quest} opens on the starter");
        assert_eq!(blobs(&store, ALICE, quest), 0, "{quest} kept a blob");
    }

    // Another player's history on the same road, and the same player's on
    // another road, are somebody else's business.
    assert_eq!(edits::state(&conn, home, BOB, HELLO).unwrap().depth, 1);
    assert_eq!(
        edits::state(&conn, home, ALICE, "cpp.basic.01.hello")
            .unwrap()
            .depth,
        1
    );

    // A road nobody has typed on is zero, not an error.
    assert_eq!(
        edits::clear_road(&conn, home, ALICE, "rust", "basic").unwrap(),
        0
    );
}
