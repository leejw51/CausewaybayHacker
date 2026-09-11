//! What every connection shares: the store, the live challenges, and where
//! the static files are.

use std::path::PathBuf;
use std::sync::Arc;

use cwbhacker_core::auth::Challenges;
use cwbhacker_core::Store;

pub struct AppState {
    pub store: Arc<Store>,
    pub challenges: Challenges,
    pub art_dir: Option<PathBuf>,
    pub static_dir: Option<PathBuf>,
    pub started_at: String,
}

pub type Shared = Arc<AppState>;
