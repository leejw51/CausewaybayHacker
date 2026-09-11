//! Search (SPEC §8) — the module boundary, and nothing behind it yet.
//!
//! Milestone 1 is the vertical slice: rust/basic, end to end. BM25, the
//! `hashed` embedder and the RRF fusion are milestone 2. The trait is here now
//! because §8.2 fixes its shape, and because `quest_vec`'s `model` column is
//! already in the schema and wants an `id()` to compare against.

use crate::error::{Error, Result};

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
            other => {
                return Err(crate::error::bad_request(format!(
                    "unknown search mode '{other}'"
                )))
            }
        })
    }
}

/// Not built yet. Answers `not_found` rather than panicking, so a client that
/// ships the search screen early gets a clean refusal (SPEC §6.1's closed set
/// has no "unimplemented", and `not_found` is the honest member of it).
pub fn query(_q: &str, _mode: Mode, _limit: usize) -> Result<Vec<serde_json::Value>> {
    Err(Error::new(
        crate::error::Code::NotFound,
        "search is not in this build yet (SPEC §8, milestone 2)",
    ))
}
