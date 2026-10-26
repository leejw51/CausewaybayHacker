//! Causewaybay Hacker on the desktop: the game server and its window, in one
//! process.
//!
//! The server is the same library `cwbhacker serve` runs (backend/server),
//! started on a thread of its own on loopback. The window opens on a splash
//! page at once, and is pointed at the server the moment it listens. The page
//! derives its websocket from `location` (frontend/src/net/endpoint.ts), so the
//! web bundle runs here unchanged: same frontend, same home, same progress as
//! the browser game.
//!
//! The port is fixed, not ephemeral. The page keeps the player's key, prefs and
//! drafts in localStorage, which is per origin; a new port every launch would
//! be a new origin, and the player would come back to an empty wallet.

// No console window behind the game on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::IsTerminal;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use tauri::{Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use cwbhacker_core::{auth, content, paths, Store};

/// One above the browser game's 5390, so `make start` and the app can run side
/// by side. `CWBH_DESKTOP_PORT` moves it.
const PORT: u16 = 5395;

fn main() {
    fix_path();

    tauri::Builder::default()
        // A second launch would find the port taken and fall back to another
        // origin — another localStorage, so no key. Raise the first instead.
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.unminimize();
                let _ = w.set_focus();
            }
        }))
        .setup(|app| {
            let window =
                WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                    .title("Causewaybay Hacker")
                    .inner_size(1600.0, 900.0)
                    .min_inner_size(960.0, 600.0)
                    .center()
                    .build()?;
            let dirs = Dirs::find(app.handle());
            std::thread::Builder::new()
                .name("server".into())
                .spawn(move || {
                    if let Err(e) = run_server(dirs, &window) {
                        tracing::error!("{e:#}");
                        show_error(&window, &format!("{e:#}"));
                    }
                })?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("running the desktop app");
}

/// The built frontend and the content packs: bundled beside the executable in
/// an installed app, or the checkout's own when run from it (`tauri dev`, or a
/// bare `cargo run`).
struct Dirs {
    web: PathBuf,
    content: PathBuf,
}

impl Dirs {
    fn find(app: &tauri::AppHandle) -> Dirs {
        if let Ok(res) = app.path().resource_dir() {
            if res.join("web/index.html").is_file() && res.join("content").is_dir() {
                return Dirs {
                    web: res.join("web"),
                    content: res.join("content"),
                };
            }
        }
        let root = repo_root();
        Dirs {
            web: root.join("frontend/dist"),
            content: root.join("content"),
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

/// What `cwbhacker serve` does before it listens, then the listening. Returns
/// only if something failed; otherwise it serves until the process exits.
fn run_server(dirs: Dirs, window: &WebviewWindow) -> Result<()> {
    let home = paths::resolve_home(None)
        .map_err(|e| anyhow::anyhow!("{e}"))
        .context("resolving the home directory")?;
    paths::ensure_dir(&home.join("logs")).map_err(|e| anyhow::anyhow!("{e}"))?;
    init_logging(&home);
    tracing::info!(web = %dirs.web.display(), content = %dirs.content.display(), "desktop starting");
    tracing::info!(path = %std::env::var("PATH").unwrap_or_default(), "toolchain PATH");

    if !dirs.web.join("index.html").is_file() {
        anyhow::bail!(
            "no frontend at {}\nbuild it first: make tauri (or cd frontend && npm run build)",
            dirs.web.display()
        );
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

    let port = std::env::var("CWBH_DESKTOP_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(PORT);
    let config = cwbhacker_server::Config {
        bind: SocketAddr::from((Ipv4Addr::LOCALHOST, port)),
        art_dir: Some(dirs.web.join("art")).filter(|d| d.is_dir()),
        static_dir: Some(dirs.web),
    };
    let app = cwbhacker_server::router(cwbhacker_server::build_state(store, &config));

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("starting the tokio runtime")?;
    runtime.block_on(async move {
        let listener = match tokio::net::TcpListener::bind(config.bind).await {
            Ok(l) => l,
            Err(e) => {
                // Something that is not us holds the port. Play on, but on
                // another origin: the key saved under this one is not here.
                tracing::warn!(bind = %config.bind, "port taken ({e}); using any free one");
                tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?
            }
        };
        let local = listener.local_addr()?;
        tracing::info!(%local, "serving");
        let url: tauri::Url = format!("http://{local}/").parse()?;
        window.navigate(url)?;
        axum::serve(listener, app).await?;
        Ok(())
    })
}

fn show_error(window: &WebviewWindow, message: &str) {
    let text = format!("{message:?}"); // a JS string literal, quotes and all
    let _ = window.eval(format!(
        "document.getElementById('msg').textContent='THE SERVER DID NOT START';\
         document.getElementById('err').textContent={text};"
    ));
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
