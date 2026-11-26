//! Causewaybay Hacker on the desktop: the game server and its window, in one
//! process.
//!
//! The server is the same library `cwbhacker serve` runs (backend/server),
//! started on a thread of its own, on loopback, on **a port the OS picks**
//! every launch. The page is not served by it: the window loads the bundled
//! frontend from the webview's own origin (`tauri://localhost`, or
//! `http://tauri.localhost` on Windows), and is told the server's address
//! before any of its scripts run (`window.__CWBH_SERVER__`, read by
//! frontend/src/net/endpoint.ts). So:
//!
//!   * the origin is fixed, and with it localStorage — the player's key,
//!     prefs and drafts survive a relaunch even though the port does not;
//!   * nothing else on the machine has to keep a port free for us, and a
//!     second copy of the server (`make start`) never collides;
//!   * the server lets exactly those webview origins open the socket
//!     (`Config::app_origins`); `cwbhacker serve` lets in none of them.
//!
//! Up to v0.1.13 the page was served by the server on the fixed
//! `http://127.0.0.1:5395`, so that is where an existing player's key is.
//! The first launch of this version moves it: see `migrate`.

// No console window behind the game on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::collections::BTreeMap;
use std::io::IsTerminal;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use cwbhacker_core::{auth, content, paths, Store};

/// The origins the webview gives the bundled page: macOS and Linux, then
/// Windows (WebView2 serves custom protocols over http).
const APP_ORIGINS: [&str; 2] = ["tauri://localhost", "http://tauri.localhost"];

/// Where v0.1.13 and before served the page, and so where an existing
/// player's localStorage lives.
const OLD_PORT: u16 = 5395;

/// In the home once the old origin's localStorage has been carried over, so
/// it is done once.
const MIGRATED: &str = "desktop-origin.migrated";

fn main() {
    fix_path();

    tauri::Builder::default()
        // One server and one window per player; a second launch raises the
        // first rather than starting another.
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            for label in ["main", "migrate"] {
                if let Some(w) = app.get_webview_window(label) {
                    let _ = w.unminimize();
                    let _ = w.set_focus();
                }
            }
        }))
        .setup(|app| {
            let handle = app.handle().clone();
            // Bound here, before any window, so the page can be told the port
            // up front. Connections that arrive while the packs import wait in
            // the backlog; the page's client simply sees a slow open.
            let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
                .context("binding a loopback port for the server")?;
            let server = format!("http://{}", listener.local_addr()?);

            let migration = migrate::begin(&handle);
            if migration.is_none() {
                open_main(&handle, &server, None)?;
            }
            let dirs = Dirs::find(&handle);
            std::thread::Builder::new()
                .name("server".into())
                .spawn(move || {
                    if let Err(e) = run(dirs, listener, server, migration, &handle) {
                        tracing::error!("{e:#}");
                        show_error(&handle, &format!("{e:#}"));
                    }
                })?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("running the desktop app");
}

/// The game's window, on the bundled page, told where its server is — and,
/// on the launch that migrates, handed the old origin's localStorage to seed
/// its own with.
fn open_main(
    app: &AppHandle,
    server: &str,
    seed: Option<&BTreeMap<String, String>>,
) -> tauri::Result<WebviewWindow> {
    WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
        .title("Causewaybay Hacker")
        .inner_size(1600.0, 900.0)
        .min_inner_size(960.0, 600.0)
        .center()
        .initialization_script(init_script(server, seed))
        .build()
}

/// The script the webview runs before the page's own, on every load.
///
/// The seed only fills keys the new origin does not have yet, and only once
/// (a flag in the new origin's own storage), so a reload — or a player who
/// has already signed in again here — is never overwritten.
fn init_script(server: &str, seed: Option<&BTreeMap<String, String>>) -> String {
    let server = serde_json::to_string(server).expect("a string serialises");
    let mut script = format!("window.__CWBH_SERVER__ = {server};\n");
    if let Some(seed) = seed.filter(|s| !s.is_empty()) {
        let seed = serde_json::to_string(seed).expect("a map of strings serialises");
        script.push_str(&format!(
            "(function (seed) {{\n\
             \x20 try {{\n\
             \x20   var done = \"cwbhacker.desktop.migrated\";\n\
             \x20   if (localStorage.getItem(done)) return;\n\
             \x20   Object.keys(seed).forEach(function (k) {{\n\
             \x20     if (localStorage.getItem(k) === null) localStorage.setItem(k, seed[k]);\n\
             \x20   }});\n\
             \x20   localStorage.setItem(done, \"1\");\n\
             \x20 }} catch (e) {{ console.warn(\"[causewaybay hacker] migration:\", e); }}\n\
             }})({seed});\n"
        ));
    }
    script
}

/// The content packs: bundled beside the executable in an installed app, or
/// the checkout's own when run from it (`tauri dev`, or a bare `cargo run`).
/// The frontend is not here: it is built into the binary (`frontendDist`).
struct Dirs {
    content: PathBuf,
}

impl Dirs {
    fn find(app: &AppHandle) -> Dirs {
        if let Ok(res) = app.path().resource_dir() {
            if res.join("content").is_dir() {
                return Dirs {
                    content: res.join("content"),
                };
            }
        }
        Dirs {
            content: repo_root().join("content"),
        }
    }
}

/// Up from the executable, then from the working directory, to the directory
/// with SPEC.md and backend/ in it — the CLI's own test for "the checkout".
fn repo_root() -> PathBuf {
    let starts = [std::env::current_exe().ok(), std::env::current_dir().ok()];
    for start in starts.into_iter().flatten() {
        let mut dir = start.as_path();
        loop {
            if dir.join("SPEC.md").is_file() && dir.join("backend").is_dir() {
                return dir.to_path_buf();
            }
            match dir.parent() {
                Some(parent) => dir = parent,
                None => break,
            }
        }
    }
    PathBuf::from(".")
}

/// What `cwbhacker serve` does before it listens, then the listening, on the
/// listener `setup` bound. With a migration under way, the main window opens
/// once the old page has handed its storage over. Returns only if something
/// failed; otherwise it serves until the process exits.
fn run(
    dirs: Dirs,
    listener: std::net::TcpListener,
    server: String,
    migration: Option<migrate::Pending>,
    app: &AppHandle,
) -> Result<()> {
    let home = paths::resolve_home(None)
        .map_err(|e| anyhow::anyhow!("{e}"))
        .context("resolving the home directory")?;
    paths::ensure_dir(&home.join("logs")).map_err(|e| anyhow::anyhow!("{e}"))?;
    init_logging(&home);
    tracing::info!(content = %dirs.content.display(), "desktop starting");
    tracing::info!(path = %std::env::var("PATH").unwrap_or_default(), "toolchain PATH");

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("starting the tokio runtime")?;

    if let Some(pending) = migration {
        let seed = runtime.block_on(pending.finish());
        let carried = seed.as_ref().map_or(0, BTreeMap::len);
        open_main(app, &server, seed.as_ref())?;
        if let Some(w) = app.get_webview_window("migrate") {
            let _ = w.close();
        }
        if seed.is_some() {
            let _ = std::fs::write(home.join(MIGRATED), format!("{carried} keys\n"));
            tracing::info!(keys = carried, "old origin's localStorage carried over");
        } else {
            tracing::warn!("the old page did not answer; will try again next launch");
        }
    }

    let store = Arc::new(Store::open(&home).map_err(|e| anyhow::anyhow!("{e}"))?);
    tracing::info!(home = %home.display(), "home ready");
    {
        let conn = store.conn();
        let report = content::import_dir(&conn, store.home(), &dirs.content)
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        let quests: usize = report.packs.iter().map(|p| p.quests).sum();
        tracing::info!(
            packs = report.packs.len(),
            quests,
            failures = report.failures.len(),
            "content imported"
        );
        for (path, reason) in &report.failures {
            tracing::error!(
                path,
                reason,
                "PACK FAILED TO IMPORT — serving stale content"
            );
        }
        let purged = auth::purge_expired_sessions(&conn).map_err(|e| anyhow::anyhow!("{e}"))?;
        if purged > 0 {
            tracing::info!(purged, "expired sessions removed");
        }
    }

    let config = cwbhacker_server::Config {
        bind: listener.local_addr()?,
        static_dir: None,
        art_dir: None,
        app_origins: APP_ORIGINS.iter().map(|o| o.to_string()).collect(),
    };
    let router = cwbhacker_server::router(cwbhacker_server::build_state(store, &config));

    runtime.block_on(async move {
        listener.set_nonblocking(true)?;
        let listener = tokio::net::TcpListener::from_std(listener)?;
        tracing::info!(local = %config.bind, "serving");
        axum::serve(listener, router).await?;
        Ok(())
    })
}

/// Carrying an existing player's localStorage from the old origin
/// (`http://127.0.0.1:5395`, where v0.1.13 and before served the page) to the
/// webview's own.
///
/// One origin cannot read another's storage, so the old origin has to be
/// asked: for one launch, a page is served on 5395 again — under a random
/// path, so nothing else on the machine can feed it a seed — and the window
/// opens on it. It posts every key it has back here; the main window then
/// opens with them as its seed (`init_script`). The old origin's storage is
/// left as it was. Once it has answered, `MIGRATED` in the home says so and
/// this never runs again; if 5395 is busy, or the page never answers, the
/// game opens without a seed and the next launch tries again.
mod migrate {
    use super::*;
    use axum::extract::{DefaultBodyLimit, Path as UrlPath, State};
    use axum::response::Html;
    use axum::routing::{get, post};
    use tokio::sync::{mpsc, oneshot};

    pub struct Pending {
        listener: std::net::TcpListener,
        token: String,
    }

    /// Whether to migrate on this launch, and if so the window on the old
    /// origin, already loading. `None` means open the game straight away.
    pub fn begin(app: &AppHandle) -> Option<Pending> {
        let home = paths::resolve_home(None).ok()?;
        if home.join(MIGRATED).exists() {
            return None;
        }
        // Taken means another program has it, and no page of ours can be
        // served there: nothing to move this time.
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, OLD_PORT)).ok()?;
        let token = cwbhacker_core::ids::photo_token();
        let url: tauri::Url = format!("http://127.0.0.1:{OLD_PORT}/{token}/")
            .parse()
            .ok()?;
        WebviewWindowBuilder::new(app, "migrate", WebviewUrl::External(url))
            .title("Causewaybay Hacker")
            .inner_size(1600.0, 900.0)
            .center()
            .build()
            .ok()?;
        Some(Pending { listener, token })
    }

    impl Pending {
        /// Serve the export page until it answers, or ten seconds pass. The
        /// old port is let go of either way.
        pub async fn finish(self) -> Option<BTreeMap<String, String>> {
            let (tx, mut rx) = mpsc::channel::<BTreeMap<String, String>>(1);
            let (stop, stopped) = oneshot::channel::<()>();
            let app = axum::Router::new()
                .route("/{token}/", get(page))
                .route("/{token}/export", post(export))
                .layer(DefaultBodyLimit::max(32 << 20))
                .with_state((self.token, tx));
            self.listener.set_nonblocking(true).ok()?;
            let listener = tokio::net::TcpListener::from_std(self.listener).ok()?;
            let server = tokio::spawn(async move {
                let _ = axum::serve(listener, app)
                    .with_graceful_shutdown(async {
                        let _ = stopped.await;
                    })
                    .await;
            });
            let seed = tokio::time::timeout(Duration::from_secs(10), rx.recv())
                .await
                .ok()
                .flatten();
            let _ = stop.send(());
            let _ = tokio::time::timeout(Duration::from_secs(2), server).await;
            seed
        }
    }

    type Shared = (String, mpsc::Sender<BTreeMap<String, String>>);

    async fn page(
        State((token, _)): State<Shared>,
        UrlPath(asked): UrlPath<String>,
    ) -> Result<Html<&'static str>, axum::http::StatusCode> {
        if asked != token {
            return Err(axum::http::StatusCode::NOT_FOUND);
        }
        Ok(Html(PAGE))
    }

    async fn export(
        State((token, tx)): State<Shared>,
        UrlPath(asked): UrlPath<String>,
        axum::Json(storage): axum::Json<BTreeMap<String, String>>,
    ) -> axum::http::StatusCode {
        if asked != token {
            return axum::http::StatusCode::NOT_FOUND;
        }
        let _ = tx.try_send(storage);
        axum::http::StatusCode::NO_CONTENT
    }

    /// Reads every key of this origin's localStorage and posts it back.
    pub(super) const PAGE: &str = r#"<!doctype html>
<html><head><meta charset="utf-8"><title>Causewaybay Hacker</title>
<style>html,body{margin:0;height:100%;background:#0b0d17;color:#e8d48b;
font:16px/1.4 ui-monospace,Menlo,monospace;display:grid;place-items:center}
#msg{letter-spacing:.15em}</style></head>
<body><div id="msg">MOVING YOUR SAVED KEY…</div>
<script>
var out = {};
try {
  for (var i = 0; i < localStorage.length; i++) {
    var k = localStorage.key(i);
    out[k] = localStorage.getItem(k);
  }
} catch (e) {}
fetch("export", { method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify(out) });
</script></body></html>
"#;
}

/// Said on whichever window is up: the game's, or the migration's.
fn show_error(app: &AppHandle, message: &str) {
    let text = serde_json::to_string(message).unwrap_or_else(|_| "\"\"".into());
    let script = format!(
        "document.body.innerHTML='';\
         var d=document.createElement('pre');\
         d.style.cssText='margin:2em;color:#ff7a7a;background:#0b0d17;white-space:pre-wrap;font:16px ui-monospace,Menlo,monospace';\
         d.textContent='THE SERVER DID NOT START\\n\\n'+{text};\
         document.body.appendChild(d);"
    );
    for label in ["main", "migrate"] {
        if let Some(w) = app.get_webview_window(label) {
            let _ = w.eval(&script);
        }
    }
}

fn init_logging(home: &Path) {
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;
    use tracing_subscriber::EnvFilter;

    let filter = EnvFilter::try_from_env("CWBHACKER_LOG")
        .unwrap_or_else(|_| EnvFilter::new("info,cwbhacker=debug"));
    let console = tracing_subscriber::fmt::layer()
        .with_target(false)
        .with_ansi(std::io::stderr().is_terminal())
        .with_writer(std::io::stderr);

    // Launched from Finder, stderr goes nowhere; this file is the log.
    let log_path = home.join("logs/desktop.jsonl");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .ok();
    let registry = tracing_subscriber::registry().with(filter).with(console);
    match file {
        Some(file) => {
            let _ = paths::set_private(&log_path, 0o600);
            let jsonl = tracing_subscriber::fmt::layer()
                .json()
                .with_writer(move || file.try_clone().expect("log handle"));
            registry.with(jsonl).init();
        }
        None => registry.init(),
    }
}

/// **The compilers have to be on PATH, and a Finder launch has none of them.**
///
/// The runner spawns `cargo`, `go`, `c++`, `python3`, `tsc` and the
/// formatters by name — `tsc` being the global one (`npm install -g
/// typescript`), not a checkout's node_modules, because an installed app has
/// no checkout beside it. An app opened from Finder or the Dock inherits
/// launchd's PATH — `/usr/bin:/bin:/usr/sbin:/sbin` — so without this every
/// land but C++ is a compile error the player cannot fix from inside the game.
/// The login shell's PATH is the one the player set up, so that is the one
/// used; whatever was already set is kept behind it.
///
/// Then the Makefile's rule for the python land: the game's own interpreter
/// (a `cwbhacker` conda env, or a venv in the home) leads, when there is one,
/// because the ambient python3 on a Mac has no torch.
///
/// Called before any thread exists, which is what makes `set_var` sound.
fn fix_path() {
    let user_home = std::env::var("HOME").unwrap_or_default();
    let mut entries: Vec<String> = Vec::new();
    let mut push = |p: &str| {
        if !p.is_empty() && !entries.iter().any(|e| e == p) {
            entries.push(p.to_string());
        }
    };

    if let Some(py) = game_python_bin(&user_home) {
        push(&py);
    }
    if let Some(login) = login_shell_path() {
        login.split(':').for_each(&mut push);
    }
    std::env::var("PATH")
        .unwrap_or_default()
        .split(':')
        .for_each(&mut push);
    // Where toolchains land when the login shell does not say (rustup,
    // Homebrew on both architectures, Go's installer).
    for p in [
        format!("{user_home}/.cargo/bin"),
        "/opt/homebrew/bin".into(),
        "/usr/local/bin".into(),
        "/usr/local/go/bin".into(),
    ] {
        if Path::new(&p).is_dir() {
            push(&p);
        }
    }
    std::env::set_var("PATH", entries.join(":"));
}

/// `$SHELL -l -i -c 'echo $PATH'`, bracketed by markers because an
/// interactive rc file may print a banner. Given three seconds; a shell that
/// hangs on a prompt is not worth waiting on.
fn login_shell_path() -> Option<String> {
    if cfg!(windows) {
        return None;
    }
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let mut child = Command::new(shell)
        .args(["-l", "-i", "-c", "printf '__CWBH__%s__CWBH__' \"$PATH\""])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                return None;
            }
        }
    }
    let out = child.wait_with_output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let start = text.find("__CWBH__")? + "__CWBH__".len();
    let len = text[start..].find("__CWBH__")?;
    Some(text[start..start + len].to_string())
}

/// The Makefile's GAME_PY_BIN: an override, then a `cwbhacker` conda env, then
/// a venv in the game's home.
fn game_python_bin(user_home: &str) -> Option<String> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(p) = std::env::var("GAME_PY_BIN") {
        candidates.push(p.into());
    }
    if let Ok(conda) = std::env::var("CONDA_EXE") {
        if let Some(root) = Path::new(&conda).parent().and_then(Path::parent) {
            candidates.push(root.join("envs/cwbhacker/bin"));
        }
    }
    for root in [
        "/opt/anaconda3".to_string(),
        "/opt/miniconda3".into(),
        format!("{user_home}/anaconda3"),
        format!("{user_home}/miniconda3"),
        format!("{user_home}/miniforge3"),
    ] {
        candidates.push(Path::new(&root).join("envs/cwbhacker/bin"));
    }
    if let Ok(home) = paths::resolve_home(None) {
        candidates.push(home.join("venv/bin"));
    }
    candidates
        .into_iter()
        .find(|d| d.join("python3").is_file())
        .map(|d| d.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Values a JS string literal could trip on if they were pasted in raw.
    fn awkward() -> BTreeMap<String, String> {
        BTreeMap::from([
            ("cwbhacker.key".to_string(), "a\"b\\c\nd\u{2028}e</script>".to_string()),
            ("kept".to_string(), "old".to_string()),
        ])
    }

    #[test]
    fn the_page_is_always_told_its_server() {
        let bare = init_script("http://127.0.0.1:61234", None);
        assert_eq!(bare, "window.__CWBH_SERVER__ = \"http://127.0.0.1:61234\";\n");
        // An empty seed is no seed: nothing to run, nothing to get wrong.
        assert_eq!(init_script("http://127.0.0.1:61234", Some(&BTreeMap::new())), bare);
    }

    #[test]
    fn the_seed_goes_in_as_json_not_as_source() {
        let script = init_script("http://127.0.0.1:61234", Some(&awkward()));
        assert!(script.starts_with("window.__CWBH_SERVER__ = \"http://127.0.0.1:61234\";\n"));
        assert!(script.contains(r#""a\"b\\c\nd"#), "{script}");
        // `cargo test -- --nocapture` shows it, to run under node.
        println!("<<<SCRIPT\n{script}SCRIPT>>>");
    }
}
