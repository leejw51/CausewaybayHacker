//! Search (SPEC §8).

use cwbhacker_core::search::{self, Embedder, Filters, HashedEmbedder, Mode};
use cwbhacker_core::{content, progress, users, Store};

const ALICE: &str = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";

/// A pack big enough that ranking means something.
fn pack() -> String {
    let quests = [
        (
            1,
            "hello",
            "FIRST LIGHT",
            "io",
            "Print a greeting to stdout and nothing else.",
        ),
        (
            2,
            "borrow",
            "THE MOVE",
            "ownership",
            "A value moved out from under a borrow. Ownership, moves and clones.",
        ),
        (
            3,
            "threads",
            "MANY HANDS",
            "concurrency",
            "Spawn threads and join them. Concurrency and shared state.",
        ),
        (
            4,
            "iterators",
            "ONE AT A TIME",
            "iteration",
            "Walk a sequence with an iterator instead of an index.",
        ),
        (
            5,
            "slices",
            "A WINDOW",
            "slices",
            "Index a slice without falling off the end of it.",
        ),
    ];
    let mut out =
        String::from("pack = \"rust.basic\"\nland = \"rust\"\ncategory = \"basic\"\nversion = 1\n");
    for (node, slug, title, concept, brief) in quests {
        out.push_str(&format!(
            r#"
[[quest]]
id          = "rust.basic.{node:02}.{slug}"
node        = {node}
title       = "{title}"
difficulty  = 1
story       = "a street in causeway bay"
concepts    = ["{concept}"]
requires    = []
map         = {{ x = 0.1, y = 0.1, kind = "quest" }}
brief       = '''
{brief}
'''
starter     = '''
fn main() {{}}
'''
solution    = '''
fn main() {{ println!("{slug}"); }}
'''
hints = []

[quest.tests]
harness      = "stdio"
timeout_ms   = 5000
match        = "trim"
cases = [
  {{ name = "says", stdin = "", expect = "{slug}\n", visible = true }},
]
"#
        ));
    }
    out
}

fn indexed() -> (tempfile::TempDir, Store, HashedEmbedder) {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), pack()).unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    let embedder = {
        let conn = store.conn();
        let report =
            content::import_dir(&conn, store.home(), &tmp.path().join("content-src")).unwrap();
        assert!(report.failures.is_empty(), "{:?}", report.failures);
        users::upsert(&conn, ALICE).unwrap();
        let embedder = search::train_from_corpus(&conn).unwrap();
        assert_eq!(search::reindex(&conn, &embedder).unwrap(), 5);
        embedder
    };
    (tmp, store, embedder)
}

fn ids(hits: &[search::SearchHit]) -> Vec<&str> {
    hits.iter().map(|h| h.quest_id.as_str()).collect()
}

#[test]
fn bm25_finds_a_word_and_ranks_the_title_above_the_story() {
    let (_tmp, store, embedder) = indexed();
    let conn = store.conn();
    let hits = search::query(
        &conn,
        &embedder,
        ALICE,
        "ownership",
        Mode::Bm25,
        &Filters::default(),
        10,
    )
    .unwrap();
    assert_eq!(ids(&hits), vec!["rust.basic.02.borrow"], "{hits:?}");
    assert!(hits[0].bm25.is_some());
    assert!(
        hits[0].cosine.is_none(),
        "bm25 mode must not invent a cosine"
    );
    assert!(
        hits[0].snippet.contains("<b>"),
        "FTS5 snippet() should mark the match: {}",
        hits[0].snippet
    );

    // SPEC §8.1's column weights: a word in the title outranks the same word
    // buried in a story.
    let hits = search::query(
        &conn,
        &embedder,
        ALICE,
        "light",
        Mode::Bm25,
        &Filters::default(),
        10,
    )
    .unwrap();
    assert_eq!(
        hits.first().map(|h| h.quest_id.as_str()),
        Some("rust.basic.01.hello")
    );
}

#[test]
fn a_search_box_is_not_a_query_language() {
    let (_tmp, store, embedder) = indexed();
    let conn = store.conn();
    // FTS5 syntax typed by a player must be a search, not a syntax error.
    for q in ["Box<dyn Error>", "\"unbalanced", "NEAR(", "a OR", "*", "()"] {
        let hits = search::query(
            &conn,
            &embedder,
            ALICE,
            q,
            Mode::Unified,
            &Filters::default(),
            10,
        );
        assert!(hits.is_ok(), "{q:?} blew up: {:?}", hits.err());
    }
    // An empty box returns nothing rather than everything.
    assert!(search::query(
        &conn,
        &embedder,
        ALICE,
        "   ",
        Mode::Unified,
        &Filters::default(),
        10
    )
    .unwrap()
    .is_empty());
}

#[test]
fn every_word_first_then_any_word() {
    let (_tmp, store, embedder) = indexed();
    let conn = store.conn();
    // "threads join" is in one quest; "threads bicycle" is in none of them
    // together, and a loose match beats zero results for one stray word.
    let both = search::query(
        &conn,
        &embedder,
        ALICE,
        "threads join",
        Mode::Bm25,
        &Filters::default(),
        10,
    )
    .unwrap();
    assert_eq!(ids(&both), vec!["rust.basic.03.threads"]);
    let loose = search::query(
        &conn,
        &embedder,
        ALICE,
        "threads bicycle",
        Mode::Bm25,
        &Filters::default(),
        10,
    )
    .unwrap();
    assert_eq!(ids(&loose), vec!["rust.basic.03.threads"], "{loose:?}");
}

#[test]
fn the_hashed_embedder_is_deterministic_and_normalized() {
    let embedder = HashedEmbedder::train(
        search::HASHED_DIM,
        &[
            "ownership and borrowing".to_string(),
            "threads and channels".to_string(),
        ],
    );
    let a = embedder.embed("ownership");
    let b = embedder.embed("ownership");
    assert_eq!(a, b, "the same text must always embed the same way");
    assert_eq!(a.len(), search::HASHED_DIM);
    let norm: f32 = a.iter().map(|v| v * v).sum::<f32>().sqrt();
    assert!((norm - 1.0).abs() < 1e-5, "not L2-normalized: {norm}");
    // Nothing in, nothing out — and no NaN.
    let empty = embedder.embed("");
    assert!(empty.iter().all(|v| *v == 0.0));
    assert_eq!(search::cosine(&a, &empty), 0.0);
    assert!(search::cosine(&a, &b) > 0.99);
}

/// The 3-grams are what make it forgive a plural or a typo — which is the
/// whole reason they are there alongside the unigrams.
#[test]
fn semantic_search_tolerates_a_near_miss_that_bm25_cannot() {
    let (_tmp, store, embedder) = indexed();
    let conn = store.conn();
    let typo = "iterater";
    let bm25 = search::query(
        &conn,
        &embedder,
        ALICE,
        typo,
        Mode::Bm25,
        &Filters::default(),
        10,
    )
    .unwrap();
    assert!(
        bm25.is_empty(),
        "bm25 should not find a misspelling: {bm25:?}"
    );
    let semantic = search::query(
        &conn,
        &embedder,
        ALICE,
        typo,
        Mode::Semantic,
        &Filters::default(),
        10,
    )
    .unwrap();
    assert_eq!(
        semantic.first().map(|h| h.quest_id.as_str()),
        Some("rust.basic.04.iterators"),
        "{semantic:?}"
    );
    assert!(semantic[0].cosine.is_some());
    assert!(semantic[0].bm25.is_none());
    assert!(
        !semantic[0].snippet.is_empty(),
        "a semantic-only hit still needs an excerpt"
    );
}

/// SPEC §8.3: the fused score carries both components, so the screen can show
/// *why* something matched.
#[test]
fn unified_fuses_both_rankings_and_keeps_the_components() {
    let (_tmp, store, embedder) = indexed();
    let conn = store.conn();
    let hits = search::query(
        &conn,
        &embedder,
        ALICE,
        "ownership",
        Mode::Unified,
        &Filters::default(),
        10,
    )
    .unwrap();
    let top = &hits[0];
    assert_eq!(top.quest_id, "rust.basic.02.borrow");
    assert!(top.bm25.is_some() && top.cosine.is_some(), "{top:?}");
    // RRF with k=60: a document first in both rankings scores 2/61.
    assert!((top.score - 2.0 / 61.0).abs() < 1e-9, "{}", top.score);
    // Ordered best-first.
    assert!(hits.windows(2).all(|w| w[0].score >= w[1].score));
}

#[test]
fn filters_narrow_without_changing_the_ranking() {
    let (_tmp, store, embedder) = indexed();
    let conn = store.conn();
    progress::record_clear(&conn, ALICE, "rust.basic.02.borrow", 10).unwrap();

    let cleared = search::query(
        &conn,
        &embedder,
        ALICE,
        "ownership threads iterator",
        Mode::Unified,
        &Filters {
            state: Some("cleared".into()),
            ..Default::default()
        },
        10,
    )
    .unwrap();
    assert_eq!(ids(&cleared), vec!["rust.basic.02.borrow"]);
    assert_eq!(cleared[0].state, "cleared");

    let go_only = search::query(
        &conn,
        &embedder,
        ALICE,
        "ownership",
        Mode::Unified,
        &Filters {
            land: Some("go".into()),
            ..Default::default()
        },
        10,
    )
    .unwrap();
    assert!(go_only.is_empty(), "{go_only:?}");
}

/// SPEC §8.2: a row whose `model` does not match the live embedder is
/// recomputed at startup.
#[test]
fn a_stale_vector_is_recomputed() {
    let (_tmp, store, embedder) = indexed();
    let conn = store.conn();
    assert_eq!(
        search::reindex(&conn, &embedder).unwrap(),
        0,
        "nothing to do"
    );

    conn.execute(
        "UPDATE quest_vec SET model = 'hashed-v0-256' WHERE quest_id = ?1",
        rusqlite::params!["rust.basic.01.hello"],
    )
    .unwrap();
    assert_eq!(search::reindex(&conn, &embedder).unwrap(), 1);
    let model: String = conn
        .query_row(
            "SELECT model FROM quest_vec WHERE quest_id = 'rust.basic.01.hello'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(model, embedder.id());
}

/// An edit to the content must not leave a vector describing the old text.
#[test]
fn editing_a_quest_drops_its_vector() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), pack()).unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    let conn = store.conn();
    content::import_dir(&conn, store.home(), &tmp.path().join("content-src")).unwrap();
    let embedder = search::train_from_corpus(&conn).unwrap();
    search::reindex(&conn, &embedder).unwrap();

    std::fs::write(
        dir.join("basic.toml"),
        pack().replace("MANY HANDS", "MANY HANDS AND A MUTEX"),
    )
    .unwrap();
    content::import_dir(&conn, store.home(), &tmp.path().join("content-src")).unwrap();
    assert_eq!(
        search::reindex(&conn, &embedder).unwrap(),
        5,
        "an import should leave every vector for that pack to be recomputed"
    );
}
