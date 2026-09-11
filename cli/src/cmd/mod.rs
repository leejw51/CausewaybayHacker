//! The commands. One module per group; this file holds what they share.

pub mod auth;
pub mod code;
pub mod playground;
pub mod stats;
pub mod stream;
pub mod world;

use std::path::PathBuf;

use causewaybay_hacker_cli::error::Result;
use causewaybay_hacker_cli::render::Paint;
use causewaybay_hacker_cli::server;
use causewaybay_hacker_cli::session::Session;
use causewaybay_hacker_cli::store::Store;

/// What every command needs before it does anything: where the store is, which
/// server it is talking to, and whether to paint.
pub struct Ctx {
    pub store: Store,
    pub server: String,
    pub trace: bool,
    /// Show the `compile` stream exactly as it comes off the wire, rustc's
    /// JSON diagnostics and all.
    pub raw: bool,
    pub paint: Paint,
}

impl Ctx {
    pub fn new(
        home: Option<PathBuf>,
        server_flag: Option<String>,
        trace: bool,
        raw: bool,
    ) -> Result<Ctx> {
        let store = Store::open(home.as_deref())?;
        let state = store.load()?;
        for warning in &state.skipped {
            // §1.1: a skipped line is a warning, never a silent loss.
            eprintln!("  warning: store {warning}");
        }
        let server = server::resolve(server_flag.as_deref(), state.server.as_deref())?;
        Ok(Ctx {
            store,
            server,
            trace,
            raw,
            paint: Paint::new(),
        })
    }

    /// Open an authenticated connection with the stored token.
    pub async fn session(&self) -> Result<Session> {
        Session::resume(&self.store, &self.server, self.trace).await
    }
}
