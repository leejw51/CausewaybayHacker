//! The HTTP and websocket server (SPEC §6).
//!
//! One port: the websocket at `/ws`, the art at `/art/…` and the built
//! frontend at `/`. One port means no CORS and nothing to configure.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::routing::get;
use axum::Router;
use tower_http::services::{ServeDir, ServeFile};

use cwbhacker_core::error::{internal, Result};
use cwbhacker_core::Store;

pub mod handlers;
pub mod playground;
pub mod proto;
pub mod state;
pub mod submit;
pub mod ws;

pub use state::{AppState, Shared};

#[derive(Debug, Clone)]
pub struct Config {
    pub bind: SocketAddr,
    /// `frontend/dist`, served at `/`. Absent until the frontend is built,
    /// which must not stop the server from starting.
    pub static_dir: Option<PathBuf>,
    /// `frontend/dist/art` once built, `frontend/public/art` before that.
    pub art_dir: Option<PathBuf>,
}

pub fn build_state(store: Arc<Store>, config: &Config) -> Shared {
    Arc::new(AppState::new(
        store,
        config.art_dir.clone(),
        config.static_dir.clone(),
    ))
}

pub fn router(state: Shared) -> Router {
    let mut router = Router::new()
        .route("/ws", get(ws::upgrade))
        .route("/healthz", get(healthz));

    // /ws and /art before the static fallback, so a frontend build that
    // happens to contain a `ws` file cannot shadow the protocol.
    if let Some(art) = state.art_dir.clone() {
        router = router.nest_service("/art", ServeDir::new(art));
    }

    let router = match state.static_dir.clone() {
        Some(dir) if dir.is_dir() => {
            let index = dir.join("index.html");
            router.fallback_service(ServeDir::new(dir).fallback(ServeFile::new(index)))
        }
        // No build yet: say so in one line rather than 404ing at a developer
        // who is wondering which of the four things is broken.
        _ => router.fallback(no_frontend),
    };

    router.with_state(state)
}

async fn healthz(
    axum::extract::State(state): axum::extract::State<Shared>,
) -> axum::Json<serde_json::Value> {
    axum::Json(serde_json::json!({
        "ok": true,
        "started_at": state.started_at,
        "protocol": proto::PROTOCOL_VERSION,
    }))
}

async fn no_frontend() -> axum::response::Response {
    use axum::response::IntoResponse;
    (
        axum::http::StatusCode::NOT_FOUND,
        [("content-type", "text/plain; charset=utf-8")],
        "Causewaybay Hacker: the server is up and the websocket is at /ws.\n\
         There is no frontend/dist yet — run `make web` for the dev server, or\n\
         `make build` to bundle one in here.\n",
    )
        .into_response()
}

pub async fn serve(store: Arc<Store>, config: Config) -> Result<()> {
    let state = build_state(store, &config);
    let app = router(state);
    let listener = tokio::net::TcpListener::bind(config.bind)
        .await
        .map_err(|e| internal(format!("cannot bind {}: {e}", config.bind)))?;
    let local = listener
        .local_addr()
        .map_err(|e| internal(format!("no local address: {e}")))?;
    tracing::info!(%local, "websocket at ws://{local}/ws");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown())
        .await
        .map_err(|e| internal(format!("server stopped: {e}")))
}

async fn shutdown() {
    let _ = tokio::signal::ctrl_c().await;
    tracing::info!("shutting down");
}

/// Where the art lives: the built copy if there is one, the source copy if
/// there is not. SPEC §6 says `/art/…` is served and does not say from which
/// of the two, and a frontend developer needs it before the first build.
pub fn pick_art_dir(repo_root: &Path) -> Option<PathBuf> {
    let dist = repo_root.join("frontend/dist/art");
    if dist.is_dir() {
        return Some(dist);
    }
    let public = repo_root.join("frontend/public/art");
    if public.is_dir() {
        return Some(public);
    }
    None
}
