//! The chatroom under a snippet (PROTOCOL §4.9f).
//!
//! What is worth proving here: that a room is the owner's alone, that the
//! folder mirror and the index follow every post, that the caps bite with a
//! reason, and that clearing — or deleting the pad — leaves nothing behind in
//! any of the three places a message lives.

use cwbhacker_core::search::{HashedEmbedder, Mode, HASHED_DIM};
use cwbhacker_core::{chat, snippets, users, Store};

const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";
const BOB: &str = "0x1111111111111111111111111111111111111111";

/// A 1×1 PNG, so "an image" is real bytes and not a string pretending.
const PNG: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
    0x42, 0x60, 0x82,
];

fn room() -> (tempfile::TempDir, Store, HashedEmbedder, String) {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    let id = {
        let conn = store.conn();
        users::upsert(&conn, ALICE).unwrap();
        users::upsert(&conn, BOB).unwrap();
        snippets::save(
            &conn,
            store.home(),
            ALICE,
            None,
            Some("iter ideas"),
            "rust",
            "fn main() {}\n",
            None,
        )
        .unwrap()
        .id
    };
    (tmp, store, HashedEmbedder::new(HASHED_DIM), id)
}

fn count(store: &Store, sql: &str) -> i64 {
    store.with_conn(|conn| conn.query_row(sql, [], |r| r.get(0)).unwrap())
}

fn say(
    store: &Store,
    embedder: &HashedEmbedder,
    id: &str,
    role: &str,
    text: &str,
) -> chat::Message {
    store.with_conn(|conn| {
        chat::post(
            conn,
            store.home(),
            embedder,
            ALICE,
            id,
            role,
            text,
            None,
            Some("openai"),
            Some("gpt-4.1"),
        )
        .unwrap()
    })
}

#[test]
fn post_list_and_clear_are_the_owners_alone() {
    let (_tmp, store, embedder, id) = room();
    let first = say(
        &store,
        &embedder,
        &id,
        "user",
        "how does an iterator adapter work?",
    );
    assert!(
        first.id > 0,
        "an id is SQLite's int64, never 0: {}",
        first.id
    );
    assert!(
        first.timeid > 1_600_000_000_000,
        "a timeid is milliseconds since the epoch: {}",
        first.timeid
    );
    assert_eq!(first.kind, "text");
    assert_eq!(first.photo_url, None);
    assert_eq!(first.provider.as_deref(), Some("openai"));
    let second = say(
        &store,
        &embedder,
        &id,
        "agent",
        "map is lazy; collect drives it",
    );

    let listed = store.with_conn(|conn| chat::list(conn, ALICE, &id, 200, 0).unwrap());
    assert_eq!(
        listed.iter().map(|m| m.id).collect::<Vec<_>>(),
        vec![first.id, second.id],
        "oldest first"
    );
    // A limit keeps the newest, still in order.
    let tail = store.with_conn(|conn| chat::list(conn, ALICE, &id, 1, 0).unwrap());
    assert_eq!(tail.len(), 1);
    assert_eq!(tail[0].id, second.id);

    // Bob cannot see, post into, search or clear Alice's room, and he is told
    // it does not exist rather than that it is hers.
    store.with_conn(|conn| {
        assert_eq!(
            chat::list(conn, BOB, &id, 200, 0).unwrap_err().code,
            cwbhacker_core::Code::NotFound
        );
        assert_eq!(
            chat::post(
                conn,
                store.home(),
                &embedder,
                BOB,
                &id,
                "user",
                "hi",
                None,
                None,
                None
            )
            .unwrap_err()
            .code,
            cwbhacker_core::Code::NotFound
        );
        assert_eq!(
            chat::search(
                conn,
                &embedder,
                BOB,
                "iterator",
                Some(&id),
                Mode::Unified,
                10
            )
            .unwrap_err()
            .code,
            cwbhacker_core::Code::NotFound
        );
        assert_eq!(
            chat::clear(conn, store.home(), BOB, &id).unwrap_err().code,
            cwbhacker_core::Code::NotFound
        );
        // And a search of Bob's own rooms finds none of it.
        assert!(
            chat::search(conn, &embedder, BOB, "iterator", None, Mode::Unified, 10)
                .unwrap()
                .is_empty()
        );
    });
    // Bob's failed clear took nothing.
    assert_eq!(count(&store, "SELECT count(*) FROM snippet_messages"), 2);

    // A bad role and an empty message are refused with a reason.
    store.with_conn(|conn| {
        let e = chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &id,
            "system",
            "x",
            None,
            None,
            None,
        )
        .unwrap_err();
        assert_eq!(e.code, cwbhacker_core::Code::BadRequest);
        assert!(e.message.contains("role"), "{e}");
        let e = chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &id,
            "user",
            "  ",
            None,
            None,
            None,
        )
        .unwrap_err();
        assert_eq!(e.code, cwbhacker_core::Code::BadRequest);
    });
}

#[test]
fn the_room_is_capped_with_a_reason() {
    let (_tmp, store, embedder, id) = room();
    for n in 0..chat::MAX_MESSAGES_PER_SNIPPET {
        say(&store, &embedder, &id, "user", &format!("line {n}"));
    }
    let refused = store.with_conn(|conn| {
        chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &id,
            "user",
            "one more",
            None,
            None,
            None,
        )
        .unwrap_err()
    });
    assert_eq!(refused.code, cwbhacker_core::Code::BadRequest);
    assert!(
        refused
            .message
            .contains(&chat::MAX_MESSAGES_PER_SNIPPET.to_string()),
        "the refusal should name the limit: {}",
        refused.message
    );
    assert_eq!(
        count(&store, "SELECT count(*) FROM snippet_messages"),
        chat::MAX_MESSAGES_PER_SNIPPET
    );
}

#[test]
fn an_image_post_writes_the_file_and_the_transcript_grows_by_a_line() {
    let (_tmp, store, embedder, id) = room();
    say(&store, &embedder, &id, "user", "draw a crab");
    let photo = store.with_conn(|conn| {
        chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &id,
            "tool",
            "a crab on a keyboard",
            Some((PNG, "image/png")),
            Some("openai"),
            Some("gpt-image-1"),
        )
        .unwrap()
    });
    assert_eq!(photo.kind, "image");
    let url = photo.photo_url.clone().expect("an image row has a url");
    assert!(
        url.starts_with(&format!("/photos/{}/", photo.id)) && url.ends_with(".png"),
        "{url}"
    );
    let token = url
        .trim_start_matches(&format!("/photos/{}/", photo.id))
        .trim_end_matches(".png")
        .to_string();
    assert_eq!(token.len(), 32);

    // On disk, as posted.
    let dir = store.home().snippet_photo_dir(ALICE, &id);
    let file = dir.join(format!("{}.png", photo.id));
    assert_eq!(std::fs::read(&file).unwrap(), PNG, "{}", file.display());

    // The transcript has one line per message.
    let jsonl = store.home().snippet_dir(ALICE, &id).join("chat.jsonl");
    let text = std::fs::read_to_string(&jsonl).unwrap();
    assert_eq!(text.lines().count(), 2);
    let last: serde_json::Value = serde_json::from_str(text.lines().last().unwrap()).unwrap();
    assert_eq!(last["id"], photo.id);
    assert_eq!(last["photo_url"].as_str(), Some(url.as_str()));

    // The route's lookup: the right token finds it, a wrong one does not.
    store.with_conn(|conn| {
        let (path, mime) = chat::photo(conn, store.home(), photo.id, &token)
            .unwrap()
            .expect("the token minted at post time fetches it");
        assert_eq!(path, file);
        assert_eq!(mime, "image/png");
        assert!(chat::photo(conn, store.home(), photo.id, &"0".repeat(32))
            .unwrap()
            .is_none());
        assert!(chat::photo(conn, store.home(), photo.id + 1, &token)
            .unwrap()
            .is_none());
    });

    // The limits: a wrong type and a photo over the cap are both refused.
    store.with_conn(|conn| {
        let e = chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &id,
            "tool",
            "",
            Some((PNG, "image/gif")),
            None,
            None,
        )
        .unwrap_err();
        assert_eq!(e.code, cwbhacker_core::Code::BadRequest);
        let huge = vec![0u8; chat::MAX_PHOTO_BYTES + 1];
        let e = chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &id,
            "tool",
            "",
            Some((&huge, "image/png")),
            None,
            None,
        )
        .unwrap_err();
        assert!(e.message.contains("at most"), "{e}");
    });
}

#[test]
fn search_finds_a_word_and_a_near_word() {
    let (_tmp, store, embedder, id) = room();
    let hit = say(
        &store,
        &embedder,
        &id,
        "agent",
        "an iterator adapter is lazy until collected",
    );
    say(
        &store,
        &embedder,
        &id,
        "user",
        "what about lifetimes on a borrowed slice?",
    );

    // Another pad of Alice's, so "every entry of this user" means something.
    let other = store.with_conn(|conn| {
        snippets::save(
            conn,
            store.home(),
            ALICE,
            None,
            Some("threads"),
            "rust",
            "",
            None,
        )
        .unwrap()
        .id
    });
    say(
        &store,
        &embedder,
        &other,
        "user",
        "spawn a thread and join it",
    );

    // The exact word, BM25 alone.
    let hits = store.with_conn(|conn| {
        chat::search(conn, &embedder, ALICE, "lazy", None, Mode::Bm25, 10).unwrap()
    });
    assert_eq!(hits.len(), 1, "{hits:?}");
    assert_eq!(hits[0].message.id, hit.id);
    assert_eq!(hits[0].snippet_name, "iter ideas");
    assert!(hits[0].bm25.is_some());
    assert!(
        hits[0].cosine.is_none(),
        "bm25 mode must not invent a cosine"
    );
    assert!(
        hits[0].snippet.contains("<b>lazy</b>"),
        "{}",
        hits[0].snippet
    );

    // A near word, unified: the plural reaches the singular.
    let hits = store.with_conn(|conn| {
        chat::search(conn, &embedder, ALICE, "iterators", None, Mode::Unified, 10).unwrap()
    });
    assert_eq!(hits.first().map(|h| h.message.id), Some(hit.id), "{hits:?}");
    assert!(hits[0].cosine.is_some());

    // Narrowed to the other pad, the iterator line is out of scope.
    let hits = store.with_conn(|conn| {
        chat::search(
            conn,
            &embedder,
            ALICE,
            "iterator",
            Some(&other),
            Mode::Unified,
            10,
        )
        .unwrap()
    });
    assert!(
        hits.iter().all(|h| h.message.snippet_id == other),
        "{hits:?}"
    );

    // An empty box returns nothing rather than everything.
    assert!(store
        .with_conn(
            |conn| chat::search(conn, &embedder, ALICE, "  ", None, Mode::Unified, 10).unwrap()
        )
        .is_empty());
}

#[test]
fn clear_and_delete_leave_nothing_behind() {
    let (_tmp, store, embedder, id) = room();
    say(&store, &embedder, &id, "user", "keep this until cleared");
    store.with_conn(|conn| {
        chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &id,
            "tool",
            "a picture",
            Some((PNG, "image/png")),
            None,
            None,
        )
        .unwrap()
    });
    let photos = store.home().snippet_photo_dir(ALICE, &id);
    let jsonl = store.home().snippet_dir(ALICE, &id).join("chat.jsonl");
    assert!(photos.is_dir() && jsonl.is_file());
    assert_eq!(count(&store, "SELECT count(*) FROM snippet_message_vec"), 2);

    let cleared = store.with_conn(|conn| chat::clear(conn, store.home(), ALICE, &id).unwrap());
    assert_eq!(cleared, 2);
    assert_eq!(count(&store, "SELECT count(*) FROM snippet_messages"), 0);
    assert_eq!(
        count(&store, "SELECT count(*) FROM snippet_message_vec"),
        0,
        "the cascade"
    );
    assert_eq!(
        count(
            &store,
            "SELECT count(*) FROM snippet_message_fts WHERE snippet_message_fts MATCH 'cleared'"
        ),
        0,
        "the delete trigger"
    );
    assert!(!photos.exists(), "the photos outlived the rows");
    assert!(!jsonl.exists(), "the transcript outlived the rows");
    assert!(
        store
            .home()
            .snippet_dir(ALICE, &id)
            .join("main.rs")
            .is_file(),
        "the pad itself stays"
    );

    // Deleting the pad takes a room with it.
    say(&store, &embedder, &id, "user", "written after the clear");
    store.with_conn(|conn| snippets::delete(conn, store.home(), ALICE, &id).unwrap());
    assert_eq!(count(&store, "SELECT count(*) FROM snippet_messages"), 0);
    assert_eq!(count(&store, "SELECT count(*) FROM snippet_message_vec"), 0);
    assert_eq!(
        count(
            &store,
            "SELECT count(*) FROM snippet_message_fts WHERE snippet_message_fts MATCH 'written'"
        ),
        0
    );
    assert!(!store.home().snippet_dir(ALICE, &id).exists());
}

// ---------------------------------------------------------------------------
// The edges: what a post may not be, what a list window keeps, and where a
// search is allowed to look.
// ---------------------------------------------------------------------------

fn refusal(
    store: &Store,
    embedder: &HashedEmbedder,
    id: &str,
    role: &str,
    text: &str,
    image: Option<(&[u8], &str)>,
) -> cwbhacker_core::Error {
    store.with_conn(|conn| {
        chat::post(
            conn,
            store.home(),
            embedder,
            ALICE,
            id,
            role,
            text,
            image,
            None,
            None,
        )
        .unwrap_err()
    })
}

#[test]
fn a_post_is_refused_for_a_bad_role_a_bad_image_or_too_much_text() {
    let (_tmp, store, embedder, id) = room();
    let bad = cwbhacker_core::Code::BadRequest;
    assert_eq!(
        refusal(&store, &embedder, &id, "system", "hi", None).code,
        bad
    );
    assert_eq!(refusal(&store, &embedder, &id, "", "hi", None).code, bad);
    // An image has to be a picture the room knows how to name.
    assert_eq!(
        refusal(
            &store,
            &embedder,
            &id,
            "agent",
            "a crab",
            Some((PNG, "image/gif"))
        )
        .code,
        bad
    );
    assert_eq!(
        refusal(
            &store,
            &embedder,
            &id,
            "agent",
            "a crab",
            Some((&[], "image/png"))
        )
        .code,
        bad
    );
    let huge = vec![0u8; chat::MAX_PHOTO_BYTES + 1];
    let e = refusal(
        &store,
        &embedder,
        &id,
        "agent",
        "a crab",
        Some((&huge, "image/png")),
    );
    assert_eq!(e.code, bad);
    assert!(
        e.message.contains(&chat::MAX_PHOTO_BYTES.to_string()),
        "{}",
        e.message
    );
    let wall = "x".repeat(chat::MAX_TEXT_BYTES + 1);
    let e = refusal(&store, &embedder, &id, "user", &wall, None);
    assert_eq!(e.code, bad);
    assert!(
        e.message.contains(&chat::MAX_TEXT_BYTES.to_string()),
        "{}",
        e.message
    );
    // And nothing of any of that was kept.
    assert_eq!(count(&store, "SELECT count(*) FROM snippet_messages"), 0);
    assert_eq!(count(&store, "SELECT count(*) FROM snippet_message_vec"), 0);
    assert!(
        !store.home().snippet_photo_dir(ALICE, &id).exists()
            || std::fs::read_dir(store.home().snippet_photo_dir(ALICE, &id))
                .unwrap()
                .next()
                .is_none()
    );
}

#[test]
fn every_role_is_kept_with_its_provider_and_model() {
    let (_tmp, store, embedder, id) = room();
    for role in ["user", "agent", "tool"] {
        let m = say(&store, &embedder, &id, role, &format!("from {role}"));
        assert_eq!(m.role, role);
        assert_eq!(m.kind, "text");
        assert_eq!(m.snippet_id, id);
        assert_eq!(m.provider.as_deref(), Some("openai"));
        assert_eq!(m.model.as_deref(), Some("gpt-4.1"));
        assert!(m.photo_url.is_none());
        assert!(m.id > 0);
    }
    // Absent is absent, not an empty string.
    let bare = store.with_conn(|conn| {
        chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &id,
            "user",
            "plain",
            None,
            None,
            None,
        )
        .unwrap()
    });
    assert!(bare.provider.is_none());
    assert!(bare.model.is_none());
}

#[test]
fn the_list_window_keeps_the_newest_in_the_order_they_were_said() {
    let (_tmp, store, embedder, id) = room();
    for n in 0..12 {
        say(&store, &embedder, &id, "user", &format!("line {n}"));
    }
    let all = store.with_conn(|conn| chat::list(conn, ALICE, &id, 500, 0).unwrap());
    assert_eq!(all.len(), 12);
    assert_eq!(all.first().unwrap().text, "line 0");
    assert_eq!(all.last().unwrap().text, "line 11");
    let tail = store.with_conn(|conn| chat::list(conn, ALICE, &id, 5, 0).unwrap());
    assert_eq!(
        tail.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(),
        ["line 7", "line 8", "line 9", "line 10", "line 11"]
    );
}

#[test]
fn search_is_scoped_to_a_room_when_asked_and_to_the_owner_always() {
    let (_tmp, store, embedder, id) = room();
    let other = store.with_conn(|conn| {
        snippets::save(
            conn,
            store.home(),
            ALICE,
            None,
            Some("other pad"),
            "go",
            "package main\n",
            None,
        )
        .unwrap()
        .id
    });
    say(&store, &embedder, &id, "user", "the borrow checker again");
    store.with_conn(|conn| {
        chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &other,
            "user",
            "borrow me a goroutine",
            None,
            None,
            None,
        )
        .unwrap();
        // Bob's own pad and room, which Alice must never see in a search.
        let bobs = snippets::save(
            conn,
            store.home(),
            BOB,
            None,
            Some("bob pad"),
            "rust",
            "fn main() {}\n",
            None,
        )
        .unwrap()
        .id;
        chat::post(
            conn,
            store.home(),
            &embedder,
            BOB,
            &bobs,
            "user",
            "borrow borrow borrow",
            None,
            None,
            None,
        )
        .unwrap();
    });
    let everywhere = store.with_conn(|conn| {
        chat::search(conn, &embedder, ALICE, "borrow", None, Mode::Unified, 20).unwrap()
    });
    let names: Vec<&str> = everywhere.iter().map(|h| h.snippet_name.as_str()).collect();
    assert_eq!(everywhere.len(), 2, "{names:?}");
    assert!(names.contains(&"iter ideas") && names.contains(&"other pad"));
    let here = store.with_conn(|conn| {
        chat::search(
            conn,
            &embedder,
            ALICE,
            "borrow",
            Some(&id),
            Mode::Unified,
            20,
        )
        .unwrap()
    });
    assert_eq!(here.len(), 1);
    assert_eq!(here[0].message.text, "the borrow checker again");
    assert_eq!(here[0].snippet_name, "iter ideas");
    // Bob, from his side, sees only his own.
    let bobs = store.with_conn(|conn| {
        chat::search(conn, &embedder, BOB, "borrow", None, Mode::Unified, 20).unwrap()
    });
    assert_eq!(bobs.len(), 1);
    assert_eq!(bobs[0].snippet_name, "bob pad");
}

#[test]
fn search_modes_say_where_a_hit_came_from() {
    let (_tmp, store, embedder, id) = room();
    say(
        &store,
        &embedder,
        &id,
        "agent",
        "closures capture their environment",
    );
    say(&store, &embedder, &id, "user", "something else entirely");
    let bm25 = store.with_conn(|conn| {
        chat::search(
            conn,
            &embedder,
            ALICE,
            "closures",
            Some(&id),
            Mode::Bm25,
            20,
        )
        .unwrap()
    });
    assert_eq!(bm25.len(), 1);
    assert!(bm25[0].bm25.is_some() && bm25[0].cosine.is_none());
    assert!(
        bm25[0].snippet.contains("<b>closures</b>"),
        "{}",
        bm25[0].snippet
    );
    let semantic = store.with_conn(|conn| {
        chat::search(
            conn,
            &embedder,
            ALICE,
            "closures",
            Some(&id),
            Mode::Semantic,
            20,
        )
        .unwrap()
    });
    assert!(!semantic.is_empty());
    assert!(semantic[0].bm25.is_none() && semantic[0].cosine.is_some());
    assert_eq!(
        semantic[0].message.text,
        "closures capture their environment"
    );
    let unified = store.with_conn(|conn| {
        chat::search(
            conn,
            &embedder,
            ALICE,
            "closures",
            Some(&id),
            Mode::Unified,
            20,
        )
        .unwrap()
    });
    assert_eq!(
        unified[0].message.text,
        "closures capture their environment"
    );
    assert!(unified[0].bm25.is_some() && unified[0].cosine.is_some());
    assert!(unified[0].score > 0.0);
    // An empty question is an empty answer, and a limit is a limit.
    assert!(store
        .with_conn(
            |conn| chat::search(conn, &embedder, ALICE, "   ", None, Mode::Unified, 20).unwrap()
        )
        .is_empty());
    for n in 0..5 {
        say(&store, &embedder, &id, "user", &format!("closures {n}"));
    }
    assert_eq!(
        store
            .with_conn(|conn| chat::search(
                conn,
                &embedder,
                ALICE,
                "closures",
                None,
                Mode::Unified,
                3
            )
            .unwrap())
            .len(),
        3
    );
}

#[test]
fn a_photo_lookup_needs_the_right_token() {
    let (_tmp, store, embedder, id) = room();
    let m = store.with_conn(|conn| {
        chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &id,
            "agent",
            "a crab",
            Some((PNG, "image/png")),
            None,
            None,
        )
        .unwrap()
    });
    let url = m.photo_url.clone().unwrap();
    // "/photos/<id>/<token>.png"
    let tail = url.strip_prefix(&format!("/photos/{}/", m.id)).unwrap();
    let token = tail.strip_suffix(".png").unwrap();
    assert_eq!(token.len(), 32);
    let found = store.with_conn(|conn| chat::photo(conn, store.home(), m.id, token).unwrap());
    let (path, mime) = found.expect("the right token finds the file");
    assert_eq!(mime, "image/png");
    assert_eq!(std::fs::read(path).unwrap(), PNG);
    let wrong = "0".repeat(32);
    assert!(store
        .with_conn(|conn| chat::photo(conn, store.home(), m.id, &wrong).unwrap())
        .is_none());
    assert!(store
        .with_conn(|conn| chat::photo(conn, store.home(), m.id + 1, token).unwrap())
        .is_none());
}

// ---------------------------------------------------------------------------
// Sync: the two int64s, and the cursor over them (PROTOCOL §4.9f).
// ---------------------------------------------------------------------------

#[test]
fn ids_and_timeids_are_two_different_numbers_both_only_going_up() {
    let (_tmp, store, embedder, id) = room();
    let other = store.with_conn(|conn| {
        snippets::save(
            conn,
            store.home(),
            ALICE,
            None,
            Some("other pad"),
            "go",
            "package main\n",
            None,
        )
        .unwrap()
        .id
    });
    let a = say(&store, &embedder, &id, "user", "one");
    let b = say(&store, &embedder, &other, "user", "two");
    let c = say(&store, &embedder, &id, "agent", "three");
    // The identity is SQLite's, small and sequential; the cursor is the
    // clock's, milliseconds since the epoch. They are not the same number.
    assert!(a.id < b.id && b.id < c.id, "{} {} {}", a.id, b.id, c.id);
    assert!(a.timeid < b.timeid && b.timeid < c.timeid);
    assert!(a.timeid > 1_600_000_000_000 && a.timeid < chat::MAX_SAFE_TIMEID);
    assert_ne!(a.id, a.timeid);
    // Across rooms: one cursor orders everything a player has.
    let all = store.with_conn(|conn| chat::since(conn, ALICE, 0, 100).unwrap());
    assert_eq!(
        all.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(),
        ["one", "two", "three"]
    );
    assert_eq!(
        store.with_conn(|conn| chat::head(conn, ALICE).unwrap()),
        c.timeid
    );
    assert_eq!(store.with_conn(|conn| chat::head(conn, BOB).unwrap()), 0);
}

#[test]
fn two_posts_in_one_millisecond_still_get_two_timeids() {
    let (_tmp, store, embedder, id) = room();
    // Faster than the clock ticks: every timeid is strictly greater than
    // the last, by exactly one when the clock has not moved.
    let mut last = 0;
    for n in 0..50 {
        let m = say(&store, &embedder, &id, "user", &format!("burst {n}"));
        assert!(m.timeid > last, "{} after {last}", m.timeid);
        last = m.timeid;
    }
    let listed = store.with_conn(|conn| chat::list(conn, ALICE, &id, 500, 0).unwrap());
    let mut sorted = listed.iter().map(|m| m.timeid).collect::<Vec<_>>();
    sorted.dedup();
    assert_eq!(sorted.len(), 50, "no two share a timeid");
}

#[test]
fn the_cursor_is_exclusive_and_pages_with_more() {
    let (_tmp, store, embedder, id) = room();
    let posted: Vec<chat::Message> = (0..7)
        .map(|n| say(&store, &embedder, &id, "user", &format!("m{n}")))
        .collect();
    // After the third: exactly the four that followed, oldest first.
    let after =
        store.with_conn(|conn| chat::list(conn, ALICE, &id, 500, posted[2].timeid).unwrap());
    assert_eq!(
        after.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(),
        ["m3", "m4", "m5", "m6"]
    );
    // After the head: nothing. After 0: everything.
    assert!(store
        .with_conn(|conn| chat::list(conn, ALICE, &id, 500, posted[6].timeid).unwrap())
        .is_empty());
    assert_eq!(
        store
            .with_conn(|conn| chat::list(conn, ALICE, &id, 500, 0).unwrap())
            .len(),
        7
    );
    // `since` walks forward a page at a time and reaches the head.
    let mut cursor = 0;
    let mut seen = Vec::new();
    loop {
        let page = store.with_conn(|conn| chat::since(conn, ALICE, cursor, 3).unwrap());
        if page.is_empty() {
            break;
        }
        cursor = page.last().unwrap().timeid;
        seen.extend(page.into_iter().map(|m| m.text));
    }
    assert_eq!(seen, ["m0", "m1", "m2", "m3", "m4", "m5", "m6"]);
    assert_eq!(cursor, posted[6].timeid);
}

#[test]
fn a_cleared_room_cannot_land_a_post_under_what_a_client_saw() {
    let (_tmp, store, embedder, id) = room();
    let before = say(&store, &embedder, &id, "user", "before the clear");
    store.with_conn(|conn| chat::clear(conn, store.home(), ALICE, &id).unwrap());
    assert_eq!(store.with_conn(|conn| chat::head(conn, ALICE).unwrap()), 0);
    // The clock is its own row: the next post is newer than everything any
    // client was ever handed, even though no row remembers it.
    let after = say(&store, &embedder, &id, "user", "after the clear");
    assert!(after.timeid > before.timeid);
    // And a client sitting at the old cursor sees only the new one.
    let fresh = store.with_conn(|conn| chat::since(conn, ALICE, before.timeid, 100).unwrap());
    assert_eq!(fresh.len(), 1);
    assert_eq!(fresh[0].text, "after the clear");
}

#[test]
fn the_photo_url_is_named_by_the_id() {
    let (_tmp, store, embedder, id) = room();
    let m = store.with_conn(|conn| {
        chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &id,
            "agent",
            "a crab",
            Some((PNG, "image/png")),
            None,
            None,
        )
        .unwrap()
    });
    let url = m.photo_url.clone().unwrap();
    assert!(url.starts_with(&format!("/photos/{}/", m.id)), "{url}");
    assert!(
        store
            .home()
            .snippet_photo_dir(ALICE, &id)
            .join(format!("{}.png", m.id))
            .exists(),
        "the file is named by the id"
    );
}

// ---------------------------------------------------------------------------
// Edit and delete: the row stays, the timeid moves, sync says what happened.
// ---------------------------------------------------------------------------

#[test]
fn an_edit_keeps_the_id_moves_the_timeid_and_is_found_by_its_new_words() {
    let (_tmp, store, embedder, id) = room();
    let m = say(&store, &embedder, &id, "user", "the borrow checkr");
    let later = say(&store, &embedder, &id, "agent", "sure");
    let edited = store.with_conn(|conn| {
        chat::edit(
            conn,
            store.home(),
            &embedder,
            ALICE,
            m.id,
            "the borrow checker",
        )
        .unwrap()
    });
    assert_eq!(edited.id, m.id);
    assert!(edited.edited);
    assert!(!edited.deleted);
    assert_eq!(edited.text, "the borrow checker");
    assert!(
        edited.timeid > later.timeid,
        "an edit lands after everything said since"
    );
    assert_eq!(
        edited.created_at, m.created_at,
        "when it was said does not change"
    );
    // A cursor past the original receives the edit; a read from the start
    // shows it in its old place with its new words.
    let past = store.with_conn(|conn| chat::since(conn, ALICE, later.timeid, 10).unwrap());
    assert_eq!(past.iter().map(|x| x.id).collect::<Vec<_>>(), vec![m.id]);
    let listed = store.with_conn(|conn| chat::list(conn, ALICE, &id, 100, 0).unwrap());
    assert_eq!(
        listed.iter().map(|x| x.text.as_str()).collect::<Vec<_>>(),
        ["sure", "the borrow checker"],
        "listed in timeid order, so the edit comes last"
    );
    // Search follows the new words, not the old.
    let hits = store.with_conn(|conn| {
        chat::search(conn, &embedder, ALICE, "checker", None, Mode::Bm25, 10).unwrap()
    });
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].message.id, m.id);
    let old = store.with_conn(|conn| {
        chat::search(conn, &embedder, ALICE, "checkr", None, Mode::Bm25, 10).unwrap()
    });
    assert!(old.is_empty());
    // The mirror on disk has both versions, in order.
    let lines =
        std::fs::read_to_string(store.home().snippet_dir(ALICE, &id).join("chat.jsonl")).unwrap();
    assert_eq!(lines.lines().count(), 3);
    assert!(lines.lines().last().unwrap().contains("the borrow checker"));
}

#[test]
fn an_edit_is_refused_where_it_makes_no_sense() {
    let (_tmp, store, embedder, id) = room();
    let bad = cwbhacker_core::Code::BadRequest;
    let m = say(&store, &embedder, &id, "user", "hello");
    let photo = store.with_conn(|conn| {
        chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &id,
            "agent",
            "a crab",
            Some((PNG, "image/png")),
            None,
            None,
        )
        .unwrap()
    });
    store.with_conn(|conn| {
        assert_eq!(
            chat::edit(conn, store.home(), &embedder, ALICE, m.id, "   ")
                .unwrap_err()
                .code,
            bad
        );
        assert_eq!(
            chat::edit(conn, store.home(), &embedder, ALICE, photo.id, "x")
                .unwrap_err()
                .code,
            bad
        );
        let wall = "x".repeat(chat::MAX_TEXT_BYTES + 1);
        assert_eq!(
            chat::edit(conn, store.home(), &embedder, ALICE, m.id, &wall)
                .unwrap_err()
                .code,
            bad
        );
        // Somebody else's message is not found, and an id nobody has either.
        assert_eq!(
            chat::edit(conn, store.home(), &embedder, BOB, m.id, "mine now")
                .unwrap_err()
                .code,
            cwbhacker_core::Code::NotFound
        );
        assert_eq!(
            chat::edit(conn, store.home(), &embedder, ALICE, m.id + 100, "x")
                .unwrap_err()
                .code,
            cwbhacker_core::Code::NotFound
        );
        // A tombstone is not edited.
        chat::delete(conn, store.home(), ALICE, m.id).unwrap();
        assert_eq!(
            chat::edit(conn, store.home(), &embedder, ALICE, m.id, "back")
                .unwrap_err()
                .code,
            bad
        );
    });
}

#[test]
fn a_delete_leaves_a_tombstone_that_a_cursor_hears_and_a_room_does_not_show() {
    let (_tmp, store, embedder, id) = room();
    let kept = say(&store, &embedder, &id, "user", "keep this");
    let photo = store.with_conn(|conn| {
        chat::post(
            conn,
            store.home(),
            &embedder,
            ALICE,
            &id,
            "agent",
            "a crab",
            Some((PNG, "image/png")),
            None,
            None,
        )
        .unwrap()
    });
    let file = store
        .home()
        .snippet_photo_dir(ALICE, &id)
        .join(format!("{}.png", photo.id));
    assert!(file.exists());
    let head = store.with_conn(|conn| chat::head(conn, ALICE).unwrap());

    let gone = store.with_conn(|conn| chat::delete(conn, store.home(), ALICE, photo.id).unwrap());
    assert_eq!(gone.id, photo.id);
    assert!(gone.deleted);
    assert_eq!(gone.text, "");
    assert!(gone.photo_url.is_none());
    assert!(
        gone.timeid > head,
        "a tombstone lands after everything said before it"
    );
    assert!(!file.exists(), "the picture is gone from the disk");
    assert_eq!(
        count(&store, "SELECT count(*) FROM snippet_message_vec"),
        1,
        "only the kept message has a vector"
    );
    // The room read from the start does not show it; a cursor past the
    // original receives exactly the tombstone; everything after 0 has it.
    let listed = store.with_conn(|conn| chat::list(conn, ALICE, &id, 100, 0).unwrap());
    assert_eq!(
        listed.iter().map(|m| m.id).collect::<Vec<_>>(),
        vec![kept.id]
    );
    let past = store.with_conn(|conn| chat::list(conn, ALICE, &id, 100, head).unwrap());
    assert_eq!(past.len(), 1);
    assert!(past[0].deleted && past[0].id == photo.id);
    let all = store.with_conn(|conn| chat::since(conn, ALICE, 0, 100).unwrap());
    assert_eq!(all.len(), 2);
    assert!(all[1].deleted);
    // Search no longer finds it, by word or by meaning.
    let hits = store.with_conn(|conn| {
        chat::search(conn, &embedder, ALICE, "crab", None, Mode::Unified, 10).unwrap()
    });
    assert!(hits.is_empty());
    // Deleting it again is the same tombstone, and the clock does not move.
    let again = store.with_conn(|conn| chat::delete(conn, store.home(), ALICE, photo.id).unwrap());
    assert_eq!(again.timeid, gone.timeid);
    // The photo route has nothing to serve.
    assert!(store
        .with_conn(|conn| chat::photo(
            conn,
            store.home(),
            photo.id,
            "0000000000000000000000000000000000"
        )
        .unwrap())
        .is_none());
    // Bob cannot delete Alice's.
    assert_eq!(
        store.with_conn(|conn| chat::delete(conn, store.home(), BOB, kept.id)
            .unwrap_err()
            .code),
        cwbhacker_core::Code::NotFound
    );
}
