//! Search (SPEC §8): BM25, semantic, and the fusion of the two.
//!
//! The semantic half is deliberately not a language model. The `hashed`
//! embedder below is compiled in, needs no download, starts instantly and is
//! bit-for-bit deterministic; it will not find *"concurrency"* from
//! *"parallel"*, and that is the accepted trade for never failing and never
//! reaching the network. A real sentence embedder sits behind the `embed-onnx`
//! feature, off by default, and only gets wired in once its real footprint and
//! offline behaviour are verified.

use std::collections::HashMap;

use rusqlite::{params, Connection};
use serde::Serialize;

use crate::error::{bad_request, Result};

pub trait Embedder: Send + Sync {
    /// Written into `quest_vec.model`; a row whose model does not match the
    /// live embedder is recomputed at startup.
    fn id(&self) -> &str;
    fn dim(&self) -> usize;
    /// L2-normalized, so a cosine is a dot product.
    fn embed(&self, text: &str) -> Vec<f32>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Bm25,
    Semantic,
    Unified,
}

impl Mode {
    pub fn parse(s: &str) -> Result<Mode> {
        Ok(match s {
            "bm25" => Mode::Bm25,
            "semantic" => Mode::Semantic,
            "unified" | "" => Mode::Unified,
            other => return Err(bad_request(format!("unknown search mode '{other}'"))),
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Bm25 => "bm25",
            Mode::Semantic => "semantic",
            Mode::Unified => "unified",
        }
    }
}

// ---------------------------------------------------------------------------
// The hashed embedder
// ---------------------------------------------------------------------------

pub const HASHED_DIM: usize = 512;

/// Character 3-grams and word unigrams hashed into `dim` buckets, with an IDF
/// learned from the quest corpus (SPEC §8.2).
///
/// The 3-grams are what make it tolerate a typo or a plural — *"iterator"* and
/// *"iterators"* share every gram but one. The unigrams are what stop
/// *"borrow"* and *"barrow"* ranking alike. Hashing rather than a vocabulary
/// means a new quest never needs a rebuild of anything but the vectors.
pub struct HashedEmbedder {
    dim: usize,
    /// Per bucket, learned at index time. A bucket every document touches
    /// carries no information, and this is what says so.
    idf: Vec<f32>,
    id: String,
}

impl HashedEmbedder {
    /// An untrained embedder, where every bucket is equally informative. Used
    /// when there is no corpus yet; `train` replaces it.
    pub fn new(dim: usize) -> HashedEmbedder {
        HashedEmbedder {
            dim,
            idf: vec![1.0; dim],
            id: format!("hashed-v2-{dim}"),
        }
    }

    /// Learn the IDF from the corpus. Deterministic: the same documents in the
    /// same order always produce the same embedder, which is what lets
    /// `quest_vec` be cached at all.
    pub fn train(dim: usize, documents: &[String]) -> HashedEmbedder {
        let mut df = vec![0f32; dim];
        for document in documents {
            let mut seen = vec![false; dim];
            for (bucket, _) in features(document, dim) {
                if !seen[bucket] {
                    seen[bucket] = true;
                    df[bucket] += 1.0;
                }
            }
        }
        let n = documents.len() as f32;
        let idf = df
            .iter()
            .map(|d| ((n + 1.0) / (d + 1.0)).ln() + 1.0)
            .collect();
        HashedEmbedder {
            dim,
            idf,
            id: format!("hashed-v2-{dim}"),
        }
    }
}

impl Embedder for HashedEmbedder {
    fn id(&self) -> &str {
        &self.id
    }

    fn dim(&self) -> usize {
        self.dim
    }

    fn embed(&self, text: &str) -> Vec<f32> {
        let mut counts: HashMap<usize, f32> = HashMap::new();
        for (bucket, weight) in features(text, self.dim) {
            *counts.entry(bucket).or_insert(0.0) += weight;
        }
        let mut vector = vec![0f32; self.dim];
        for (bucket, tf) in counts {
            // Sub-linear term frequency: the tenth mention of a word says much
            // less than the second. `ln(1 + tf)` rather than `1 + ln(tf)`,
            // because a lone 3-gram weighs 0.35 and `1 + ln(0.35)` is below
            // zero — which made a text that repeats a word *anti*-correlate
            // with a query that says it once, the opposite of what the grams
            // are for. The id says v2 so every stored vector is recomputed.
            vector[bucket] = tf.ln_1p() * self.idf[bucket];
        }
        let norm: f32 = vector.iter().map(|v| v * v).sum::<f32>().sqrt();
        if norm > 0.0 {
            for v in &mut vector {
                *v /= norm;
            }
        }
        vector
    }
}

/// Word unigrams and character 3-grams, each with the weight it contributes.
/// A unigram is worth more than a gram: the grams are there to be forgiving,
/// not to drown the words.
fn features(text: &str, dim: usize) -> Vec<(usize, f32)> {
    let lowered = text.to_lowercase();
    let mut out = Vec::new();
    for word in lowered.split(|c: char| !c.is_alphanumeric()) {
        if word.is_empty() {
            continue;
        }
        out.push((bucket(word.as_bytes(), dim), 1.0));
        let padded = format!(" {word} ");
        let chars: Vec<char> = padded.chars().collect();
        for gram in chars.windows(3) {
            let text: String = gram.iter().collect();
            out.push((bucket(text.as_bytes(), dim), 0.35));
        }
    }
    out
}

/// FNV-1a. Small, fast, no dependency, and — the part that matters — stable
/// for ever, because a stored vector is only valid while the hash is.
fn bucket(bytes: &[u8], dim: usize) -> usize {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    (hash % dim as u64) as usize
}

pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    // Both are L2-normalized, so the dot product is the cosine.
    a.iter().zip(b.iter()).map(|(x, y)| x * y).sum()
}

// ---------------------------------------------------------------------------
// The index
// ---------------------------------------------------------------------------

/// `dim * f32`, little-endian — the `vec` column of `quest_vec` and
/// `snippet_message_vec` alike (SPEC §2.1).
pub fn to_blob(vector: &[f32]) -> Vec<u8> {
    vector.iter().flat_map(|v| v.to_le_bytes()).collect()
}

pub fn from_blob(blob: &[u8]) -> Vec<f32> {
    blob.chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

/// What a quest is indexed on. The same four columns FTS5 sees (SPEC §8.1),
/// so the two halves of a unified search are looking at the same text.
fn document(conn: &Connection, quest_id: &str) -> Result<String> {
    Ok(conn.query_row(
        "SELECT title || ' ' || brief || ' ' || story || ' ' || concepts
           FROM quests WHERE id = ?1",
        params![quest_id],
        |r| r.get(0),
    )?)
}

fn corpus(conn: &Connection) -> Result<Vec<(String, String)>> {
    let mut stmt = conn.prepare(
        "SELECT id, title || ' ' || brief || ' ' || story || ' ' || concepts
           FROM quests ORDER BY id",
    )?;
    let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// Build the embedder from whatever is in the database right now.
pub fn train_from_corpus(conn: &Connection) -> Result<HashedEmbedder> {
    let documents: Vec<String> = corpus(conn)?.into_iter().map(|(_, text)| text).collect();
    if documents.is_empty() {
        return Ok(HashedEmbedder::new(HASHED_DIM));
    }
    Ok(HashedEmbedder::train(HASHED_DIM, &documents))
}

/// Recompute every vector that is missing or stale (SPEC §8.2: "a `quest_vec`
/// row whose `model` does not match the live embedder's `id()` is recomputed
/// at startup"). Returns how many it wrote.
pub fn reindex(conn: &Connection, embedder: &dyn Embedder) -> Result<usize> {
    let mut stale: Vec<String> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT q.id FROM quests q
               LEFT JOIN quest_vec v ON v.quest_id = q.id
              WHERE v.quest_id IS NULL OR v.model <> ?1 OR v.dim <> ?2",
        )?;
        let rows = stmt.query_map(params![embedder.id(), embedder.dim() as i64], |r| r.get(0))?;
        for row in rows {
            stale.push(row?);
        }
    }
    for quest_id in &stale {
        let vector = embedder.embed(&document(conn, quest_id)?);
        conn.execute(
            "INSERT INTO quest_vec (quest_id, dim, model, vec) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(quest_id) DO UPDATE SET dim = ?2, model = ?3, vec = ?4",
            params![
                quest_id,
                embedder.dim() as i64,
                embedder.id(),
                to_blob(&vector)
            ],
        )?;
    }
    Ok(stale.len())
}

// ---------------------------------------------------------------------------
// Querying
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default)]
pub struct Filters {
    pub land: Option<String>,
    pub category: Option<String>,
    /// `cleared` or `open`.
    pub state: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SearchHit {
    pub quest_id: String,
    pub title: String,
    pub land: String,
    pub category: String,
    pub snippet: String,
    pub score: f64,
    pub bm25: Option<f64>,
    pub cosine: Option<f64>,
    pub state: String,
}

/// FTS5's query language is a language, and a search box is not. Everything
/// but letters and digits is dropped and each word is quoted, so a player
/// typing `Box<dyn Error>` gets a search rather than a syntax error.
pub(crate) fn match_query(q: &str, all_words: bool) -> Option<String> {
    let words: Vec<String> = q
        .to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(|w| format!("\"{w}\""))
        .collect();
    if words.is_empty() {
        return None;
    }
    Some(if all_words {
        words.join(" AND ")
    } else {
        words.join(" OR ")
    })
}

struct Bm25Hit {
    quest_id: String,
    score: f64,
    snippet: String,
}

fn bm25_search(conn: &Connection, q: &str, limit: usize) -> Result<Vec<Bm25Hit>> {
    // Every word first, because a search that means all of them is more
    // precise; any word if that found nothing, because zero results for a
    // typo in one word of four is a worse answer than a loose one.
    for all_words in [true, false] {
        let Some(query) = match_query(q, all_words) else {
            return Ok(Vec::new());
        };
        let mut stmt = conn.prepare(
            "SELECT q.id,
                    bm25(quest_fts, 4.0, 1.0, 2.0, 0.5) AS rank,
                    snippet(quest_fts, 1, '<b>', '</b>', '…', 14)
               FROM quest_fts JOIN quests q ON q.rowid = quest_fts.rowid
              WHERE quest_fts MATCH ?1
              ORDER BY rank
              LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![query, limit as i64], |r| {
            Ok(Bm25Hit {
                quest_id: r.get(0)?,
                // bm25() is negative and lower is better; flip it so every
                // score in this module means "more is better".
                score: -r.get::<_, f64>(1)?,
                snippet: r.get(2)?,
            })
        })?;
        let hits: Vec<Bm25Hit> = rows.collect::<rusqlite::Result<Vec<_>>>()?;
        if !hits.is_empty() {
            return Ok(hits);
        }
    }
    Ok(Vec::new())
}

fn semantic_search(
    conn: &Connection,
    embedder: &dyn Embedder,
    q: &str,
    limit: usize,
) -> Result<Vec<(String, f64)>> {
    let query = embedder.embed(q);
    // Brute force over every row. A few hundred quests makes an index
    // pointless (SPEC §8.2); this is a dot product per quest.
    let mut stmt = conn.prepare("SELECT quest_id, vec FROM quest_vec")?;
    let rows = stmt.query_map([], |r| {
        let blob: Vec<u8> = r.get(1)?;
        Ok((r.get::<_, String>(0)?, blob))
    })?;
    let mut scored: Vec<(String, f64)> = rows
        .collect::<rusqlite::Result<Vec<_>>>()?
        .into_iter()
        .map(|(id, blob)| (id, cosine(&query, &from_blob(&blob)) as f64))
        .filter(|(_, score)| *score > 0.0)
        .collect();
    scored.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    scored.truncate(limit);
    Ok(scored)
}

/// Reciprocal-rank fusion, `k = 60` (SPEC §8.3).
///
/// RRF rather than a weighted sum because BM25 scores and cosine similarities
/// are not on the same scale, and adding them ranks by neither.
pub(crate) const RRF_K: f64 = 60.0;

/// One quest's standing in the fusion: the RRF total, and the component scores
/// kept beside it so the screen can show *why* something matched.
#[derive(Default)]
struct Fused {
    score: f64,
    bm25: Option<f64>,
    cosine: Option<f64>,
    snippet: Option<String>,
}

pub fn query(
    conn: &Connection,
    embedder: &dyn Embedder,
    address: &str,
    q: &str,
    mode: Mode,
    filters: &Filters,
    limit: usize,
) -> Result<Vec<SearchHit>> {
    if q.trim().is_empty() {
        // An empty box returns nothing rather than everything.
        return Ok(Vec::new());
    }
    let pool = (limit * 5).clamp(20, 200);
    let bm25 = if mode == Mode::Semantic {
        Vec::new()
    } else {
        bm25_search(conn, q, pool)?
    };
    let semantic = if mode == Mode::Bm25 {
        Vec::new()
    } else {
        semantic_search(conn, embedder, q, pool)?
    };

    let mut fused: HashMap<String, Fused> = HashMap::new();
    for (rank, hit) in bm25.iter().enumerate() {
        let entry = fused.entry(hit.quest_id.clone()).or_default();
        entry.score += 1.0 / (RRF_K + rank as f64 + 1.0);
        entry.bm25 = Some(hit.score);
        entry.snippet = Some(hit.snippet.clone());
    }
    for (rank, (quest_id, score)) in semantic.iter().enumerate() {
        let entry = fused.entry(quest_id.clone()).or_default();
        entry.score += 1.0 / (RRF_K + rank as f64 + 1.0);
        entry.cosine = Some(*score);
    }

    let cleared = crate::progress::cleared_set(conn, address)?;
    let mut hits = Vec::new();
    for (quest_id, entry) in fused {
        let quest = match crate::quests::get(conn, &quest_id) {
            Ok(quest) => quest,
            Err(_) => continue,
        };
        if filters.land.as_ref().is_some_and(|l| *l != quest.land) {
            continue;
        }
        if filters
            .category
            .as_ref()
            .is_some_and(|c| *c != quest.category)
        {
            continue;
        }
        let state = if cleared.contains(&quest_id) {
            "cleared"
        } else {
            "open"
        };
        if filters.state.as_ref().is_some_and(|s| s != state) {
            continue;
        }
        hits.push(SearchHit {
            snippet: entry.snippet.unwrap_or_else(|| excerpt(&quest.brief)),
            quest_id,
            title: quest.title,
            land: quest.land,
            category: quest.category,
            score: entry.score,
            bm25: entry.bm25,
            cosine: entry.cosine,
            state: state.to_string(),
        });
    }
    hits.sort_by(|a, b| {
        b.score
            .total_cmp(&a.score)
            .then_with(|| a.quest_id.cmp(&b.quest_id))
    });
    hits.truncate(limit);
    Ok(hits)
}

/// A snippet for a hit that FTS5 never saw — a semantic-only match has no
/// matching term to highlight.
pub(crate) fn excerpt(brief: &str) -> String {
    let flat = brief.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() > 160 {
        flat.chars().take(157).collect::<String>() + "…"
    } else {
        flat
    }
}
