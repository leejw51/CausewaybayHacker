//! What every connection shares: the store, the live challenges, where the
//! static files are, and the hub that lets one user's windows stay in step.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use cwbhacker_core::auth::Challenges;
use cwbhacker_core::search::{Embedder, HashedEmbedder};
use cwbhacker_core::Store;

use crate::limits::{self, Gate};
use crate::proto::{Out, Outgoing, ServerFrame};

/// PROTOCOL §4.19: `progress.update` also goes to the same user's other open
/// connections, which is how two windows stay in step. The hub is the only
/// thing in the server that knows a user can be in more than one place.
#[derive(Default)]
pub struct Hub {
    connections: Mutex<HashMap<String, Vec<(u64, Out)>>>,
}

impl Hub {
    pub fn join(&self, address: &str, id: u64, out: Out) {
        let mut map = self.connections.lock().unwrap();
        let entry = map.entry(address.to_ascii_lowercase()).or_default();
        entry.retain(|(existing, _)| *existing != id);
        entry.push((id, out));
    }

    pub fn leave(&self, address: &str, id: u64) {
        let mut map = self.connections.lock().unwrap();
        if let Some(entry) = map.get_mut(&address.to_ascii_lowercase()) {
            entry.retain(|(existing, _)| *existing != id);
            if entry.is_empty() {
                map.remove(&address.to_ascii_lowercase());
            }
        }
    }

    /// Everyone signed in as this address except the connection that caused
    /// the change — it gets the same frame on its own reply path.
    pub fn broadcast(&self, address: &str, except: u64, frame: &ServerFrame) {
        let map = self.connections.lock().unwrap();
        if let Some(entry) = map.get(&address.to_ascii_lowercase()) {
            for (id, out) in entry {
                if *id != except {
                    let _ = out.send(Outgoing::Frame(frame.clone()));
                }
            }
        }
    }
}

pub struct AppState {
    pub store: Arc<Store>,
    pub challenges: Challenges,
    pub art_dir: Option<PathBuf>,
    pub static_dir: Option<PathBuf>,
    pub started_at: String,
    pub hub: Hub,
    /// The live embedder (SPEC §8.2). Built from the corpus at startup, which
    /// is also when any `quest_vec` row whose `model` no longer matches is
    /// recomputed.
    pub embedder: Box<dyn Embedder>,
    /// Submissions compiling right now, across every connection. It is what
    /// `run.stage`'s `queued` depth reports.
    pub running: AtomicUsize,
    /// The global ceiling on compiles, across every connection. PROTOCOL
    /// §3.2's one-execution slot is **per connection**, so without this one
    /// client with two sockets is two compilers and twenty is twenty.
    pub executions: Arc<Gate>,
    /// And on formatters. `code.format` skips the execution slot on purpose,
    /// which is what let a tight loop of it spawn `rustfmt` without bound.
    pub formatters: Arc<Gate>,
    /// Sockets open right now, against `limits::MAX_CONNECTIONS`.
    pub connections: AtomicUsize,
    next_connection: AtomicU64,
}

impl AppState {
    pub fn new(
        store: Arc<Store>,
        art_dir: Option<PathBuf>,
        static_dir: Option<PathBuf>,
    ) -> AppState {
        // Deterministic, no download, no network, and it cannot fail — which
        // is the whole reason the default embedder is this one.
        let embedder: Box<dyn Embedder> = {
            let conn = store.conn();
            match cwbhacker_core::search::train_from_corpus(&conn) {
                Ok(embedder) => Box::new(embedder),
                Err(e) => {
                    tracing::warn!(error = %e, "could not train the embedder; search will be BM25 only");
                    Box::new(HashedEmbedder::new(cwbhacker_core::search::HASHED_DIM))
                }
            }
        };
        {
            let conn = store.conn();
            match cwbhacker_core::search::reindex(&conn, embedder.as_ref()) {
                Ok(0) => {}
                Ok(n) => tracing::info!(vectors = n, model = embedder.id(), "search index rebuilt"),
                Err(e) => tracing::warn!(error = %e, "could not build the search index"),
            }
        }
        AppState {
            embedder,
            store,
            challenges: Challenges::new(),
            art_dir,
            static_dir,
            started_at: cwbhacker_core::time::now_stamp(),
            hub: Hub::default(),
            running: AtomicUsize::new(0),
            executions: Gate::new(limits::MAX_CONCURRENT_EXECUTIONS),
            formatters: Gate::new(limits::MAX_CONCURRENT_FORMATS),
            connections: AtomicUsize::new(0),
            next_connection: AtomicU64::new(1),
        }
    }

    pub fn next_connection_id(&self) -> u64 {
        self.next_connection.fetch_add(1, Ordering::Relaxed)
    }
}

pub type Shared = Arc<AppState>;
