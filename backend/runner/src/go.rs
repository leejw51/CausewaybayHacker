//! The Go runner (SPEC §5.1) — milestone 2.
//!
//! The module boundary is here so the dispatch in `lib.rs` has both arms and
//! the server never has to ask whether Go exists. When it is built it will
//! want `GOCACHE`, `GOMODCACHE`, `GOPATH` under `build/go/` and `GOPROXY=off`.

use crate::{Report, Submission};

pub fn run(_sub: &Submission) -> Report {
    Report::internal("the go runner is not in this build yet (SPEC §5.1, milestone 2)")
}
