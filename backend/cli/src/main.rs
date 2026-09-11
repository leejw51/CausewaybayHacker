//! `cwbhacker` — the binary. serve, import, doctor, prune.
//!
//! Everything the terminal needs lives here: argument parsing, logging, exit
//! statuses. The core crate does none of it, so the same operations are
//! callable from a test without a process.

use std::io::IsTerminal;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

use cwbhacker_core::{content, db, paths, Store};

#[derive(Parser)]
#[command(
    name = "cwbhacker",
    about = "Causewaybay Hacker — a 16-bit trainer for taking your craft back",
    version
)]
struct Cli {
    /// The home directory (SPEC §1). Also `CAUSEWAYBAY_HACKER_HOME`; the flag
    /// wins.
    #[arg(long, global = true, value_name = "PATH")]
    home: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Run the server: the websocket, the art and the built frontend.
    Serve {
        #[arg(long, default_value = "127.0.0.1:5390")]
        bind: SocketAddr,
        /// The content packs to import at startup (SPEC §12).
        #[arg(long, value_name = "DIR")]
        content: Option<PathBuf>,
        /// The built frontend to serve at `/`.
        #[arg(long = "static", value_name = "DIR")]
        static_dir: Option<PathBuf>,
        /// Start without importing. Useful when the content is mid-edit.
        #[arg(long)]
        no_import: bool,
    },
    /// Import content packs and exit.
    Import {
        #[arg(long, value_name = "DIR")]
        content: Option<PathBuf>,
    },
    /// Check the toolchains, the home and the database.
    Doctor,
    /// Remove things the server never removes on its own.
    Prune {
        /// Delete the build scratch under `build/`. Safe while the server is
        /// down; that is what it is for.
        #[arg(long)]
        builds: bool,
        /// Delete session rows that have expired.
        #[arg(long)]
        sessions: bool,
        /// Delete attempts older than N days — rows *and* directories. This
        /// is training data (SPEC §1); nothing else in the program removes it.
        #[arg(long, value_name = "DAYS")]
        attempts_older_than: Option<i64>,
    },
}

fn main() {
    if let Err(e) = real_main() {
        eprintln!("cwbhacker: {e:#}");
        std::process::exit(1);
    }
}

fn real_main() -> Result<()> {
    let cli = Cli::parse();
    let home_path = paths::resolve_home(cli.home.as_deref())
        .map_err(|e| anyhow::anyhow!("{e}"))
        .context("resolving the home directory")?;

    match cli.command {
        Command::Serve {
            bind,
            content,
            static_dir,
            no_import,
        } => serve(&home_path, bind, content, static_dir, no_import),
        Command::Import { content } => import(&home_path, content),
        Command::Doctor => doctor(&home_path),
        Command::Prune {
            builds,
            sessions,
            attempts_older_than,
        } => prune(&home_path, builds, sessions, attempts_older_than),
    }
}

fn open_store(home: &Path) -> Result<Arc<Store>> {
    Ok(Arc::new(
        Store::open(home).map_err(|e| anyhow::anyhow!("{e}"))?,
    ))
}

/// Walk up from the working directory for the repository marker, so that
/// `cd backend && cargo run` finds `content/` and `frontend/dist` without
/// anybody passing a relative path that depends on where they stood.
fn repo_root() -> PathBuf {
    let start = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let mut dir = start.as_path();
    loop {
        if dir.join("SPEC.md").is_file() && dir.join("backend").is_dir() {
            return dir.to_path_buf();
        }
        match dir.parent() {
            Some(parent) => dir = parent,
            None => return start.clone(),
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

    // §1: `logs/server.jsonl`, one JSON object per line. Best effort — a
    // server that cannot open its log file should still serve.
    let log_path = home.join("logs/server.jsonl");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .ok();
    if let Some(file) = &file {
        let _ = paths::set_private(&log_path, 0o600);
        let file = file.try_clone().ok();
        if let Some(file) = file {
            let jsonl = tracing_subscriber::fmt::layer()
                .json()
                .with_writer(move || file.try_clone().expect("log handle"));
            tracing_subscriber::registry()
                .with(filter)
                .with(console)
                .with(jsonl)
                .init();
            return;
        }
    }
    tracing_subscriber::registry()
        .with(filter)
        .with(console)
        .init();
}

fn serve(
    home: &Path,
    bind: SocketAddr,
    content_dir: Option<PathBuf>,
    static_dir: Option<PathBuf>,
    no_import: bool,
) -> Result<()> {
    // The home has to exist before logging can write into it.
    paths::ensure_dir(&home.join("logs")).map_err(|e| anyhow::anyhow!("{e}"))?;
    init_logging(home);

    let store = open_store(home)?;
    tracing::info!(home = %home.display(), db = %store.home().db_path().display(), "home ready");

    let root = repo_root();
    let content_dir = content_dir.unwrap_or_else(|| root.join("content"));
    if no_import {
        tracing::info!("skipping the content import (--no-import)");
    } else {
        let report = {
            let conn = store.conn();
            content::import_dir(&conn, store.home(), &content_dir)
                .map_err(|e| anyhow::anyhow!("{e}"))?
        };
        let quests: usize = report.packs.iter().map(|p| p.quests).sum();
        tracing::info!(
            path = %content_dir.display(),
            packs = report.packs.len(),
            quests,
            failures = report.failures.len(),
            "content imported"
        );
        for (path, reason) in &report.failures {
            tracing::warn!(path, reason, "pack skipped");
        }
    }
    {
        let conn = store.conn();
        let purged = cwbhacker_core::auth::purge_expired_sessions(&conn)
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        if purged > 0 {
            tracing::info!(purged, "expired sessions removed");
        }
    }

    let static_dir = static_dir.or_else(|| {
        let dist = root.join("frontend/dist");
        dist.is_dir().then_some(dist)
    });
    let config = cwbhacker_server::Config {
        bind,
        art_dir: cwbhacker_server::pick_art_dir(&root),
        static_dir,
    };
    tracing::info!(
        bind = %config.bind,
        static_dir = ?config.static_dir,
        art = ?config.art_dir,
        "serving"
    );
    eprintln!("cwbhacker: ws://{}/ws", config.bind);

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("starting the tokio runtime")?;
    runtime
        .block_on(cwbhacker_server::serve(store, config))
        .map_err(|e| anyhow::anyhow!("{e}"))
}

fn import(home: &Path, content_dir: Option<PathBuf>) -> Result<()> {
    init_logging(home);
    let store = open_store(home)?;
    let dir = content_dir.unwrap_or_else(|| repo_root().join("content"));
    let report = {
        let conn = store.conn();
        content::import_dir(&conn, store.home(), &dir).map_err(|e| anyhow::anyhow!("{e}"))?
    };
    println!("content: {}", dir.display());
    for pack in &report.packs {
        println!(
            "  {:<18} {:>3} quests  ({} new)  {}",
            pack.pack, pack.quests, pack.inserted, pack.path
        );
    }
    for (path, reason) in &report.failures {
        println!("  FAILED {path}: {reason}");
    }
    if report.packs.is_empty() && report.failures.is_empty() {
        println!("  (nothing to import)");
    }
    if !report.failures.is_empty() {
        std::process::exit(1);
    }
    Ok(())
}

fn doctor(home: &Path) -> Result<()> {
    let mut bad = 0;
    println!("home        {}", home.display());
    println!("content     {}", repo_root().join("content").display());

    for (label, program, args) in [
        ("rustc", "rustc", ["--version"]),
        ("cargo", "cargo", ["--version"]),
        ("go", "go", ["version"]),
        ("node", "node", ["--version"]),
    ] {
        match std::process::Command::new(program).args(args).output() {
            Ok(out) if out.status.success() => {
                let text = String::from_utf8_lossy(&out.stdout);
                println!("{label:<11} {}", text.trim());
            }
            _ => {
                // Both lands compile and run now, so a missing `go` is half
                // the map gone; node is the frontend's build and not the
                // server's problem.
                let fatal = matches!(label, "rustc" | "cargo" | "go");
                println!(
                    "{label:<11} MISSING{}",
                    if fatal { "  (required)" } else { "" }
                );
                if fatal {
                    bad += 1;
                }
            }
        }
    }

    match Store::open(home) {
        Ok(store) => {
            let conn = store.conn();
            let version: i64 = conn
                .query_row("PRAGMA user_version", [], |r| r.get(0))
                .unwrap_or(-1);
            let quests: i64 = conn
                .query_row("SELECT count(*) FROM quests", [], |r| r.get(0))
                .unwrap_or(-1);
            let users: i64 = conn
                .query_row("SELECT count(*) FROM users", [], |r| r.get(0))
                .unwrap_or(-1);
            println!(
                "database    user_version {version} (latest {})",
                db::latest_version()
            );
            println!("fts5        present");
            println!("content     {quests} quests, {users} users");
        }
        Err(e) => {
            println!("database    BROKEN: {e}");
            bad += 1;
        }
    }

    if bad > 0 {
        std::process::exit(1);
    }
    Ok(())
}

fn prune(
    home: &Path,
    builds: bool,
    sessions: bool,
    attempts_older_than: Option<i64>,
) -> Result<()> {
    let store = open_store(home)?;
    if !builds && !sessions && attempts_older_than.is_none() {
        println!("prune: nothing asked for. Try --builds, --sessions or --attempts-older-than N.");
        return Ok(());
    }
    if builds {
        let dir = store.home().build_dir();
        // The scratch is safe to delete when the server is down (§1); the
        // skeleton is put back so the next run does not have to.
        std::fs::remove_dir_all(&dir).ok();
        cwbhacker_core::paths::ensure_dir(&dir).map_err(|e| anyhow::anyhow!("{e}"))?;
        println!("build scratch cleared: {}", dir.display());
    }
    if sessions {
        let conn = store.conn();
        let purged = cwbhacker_core::auth::purge_expired_sessions(&conn)
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        println!("expired sessions removed: {purged}");
    }
    if let Some(days) = attempts_older_than {
        let cutoff = cwbhacker_core::time::stamp(cwbhacker_core::time::now() - chrono_days(days));
        let conn = store.conn();
        let mut stmt = conn.prepare("SELECT id, address FROM attempts WHERE created_at < ?1")?;
        let doomed: Vec<(String, String)> = stmt
            .query_map([&cutoff], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(stmt);
        for (id, address) in &doomed {
            std::fs::remove_dir_all(store.home().attempt_dir(address, id)).ok();
        }
        let removed = conn.execute("DELETE FROM attempts WHERE created_at < ?1", [&cutoff])?;
        println!("attempts removed: {removed} (older than {cutoff})");
    }
    Ok(())
}

fn chrono_days(days: i64) -> std::time::Duration {
    std::time::Duration::from_secs((days.max(0) * 86_400) as u64)
}
