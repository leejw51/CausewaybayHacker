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
    assert!(first.id.starts_with("msg_"));
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

    let listed = store.with_conn(|conn| chat::list(conn, ALICE, &id, 200).unwrap());
    assert_eq!(
        listed.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
        vec![first.id.as_str(), second.id.as_str()],
        "oldest first"
    );
    // A limit keeps the newest, still in order.
    let tail = store.with_conn(|conn| chat::list(conn, ALICE, &id, 1).unwrap());
    assert_eq!(tail.len(), 1);
    assert_eq!(tail[0].id, second.id);

    // Bob cannot see, post into, search or clear Alice's room, and he is told
    // it does not exist rather than that it is hers.
    store.with_conn(|conn| {
        assert_eq!(
            chat::list(conn, BOB, &id, 200).unwrap_err().code,
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
        let (path, mime) = chat::photo(conn, store.home(), &photo.id, &token)
            .unwrap()
            .expect("the token minted at post time fetches it");
        assert_eq!(path, file);
        assert_eq!(mime, "image/png");
        assert!(chat::photo(conn, store.home(), &photo.id, &"0".repeat(32))
            .unwrap()
            .is_none());
        assert!(
            chat::photo(conn, store.home(), "msg_0000000000000000", &token)
                .unwrap()
                .is_none()
        );
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
    assert_eq!(
        hits.first().map(|h| h.message.id.as_str()),
        Some(hit.id.as_str()),
        "{hits:?}"
    );
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
        assert!(m.id.starts_with("msg_"));
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
    let all = store.with_conn(|conn| chat::list(conn, ALICE, &id, 500).unwrap());
    assert_eq!(all.len(), 12);
    assert_eq!(all.first().unwrap().text, "line 0");
    assert_eq!(all.last().unwrap().text, "line 11");
    let tail = store.with_conn(|conn| chat::list(conn, ALICE, &id, 5).unwrap());
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
    let found = store.with_conn(|conn| chat::photo(conn, store.home(), &m.id, token).unwrap());
    let (path, mime) = found.expect("the right token finds the file");
    assert_eq!(mime, "image/png");
    assert_eq!(std::fs::read(path).unwrap(), PNG);
    let wrong = "0".repeat(32);
    assert!(store
        .with_conn(|conn| chat::photo(conn, store.home(), &m.id, &wrong).unwrap())
        .is_none());
    assert!(store
        .with_conn(|conn| chat::photo(conn, store.home(), "msg_nope", token).unwrap())
        .is_none());
}
