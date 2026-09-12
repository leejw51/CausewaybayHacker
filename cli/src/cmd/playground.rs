//! The playground — PROTOCOL §4.9c. A scratchpad: no quest, no tests, no
//! verdict.
//!
//! Nothing here is scored, and that has to be true of the *language* as well
//! as the data: §4.9c says a playground run *"is not recorded and does not
//! feed the curriculum"*, and it is also where somebody deliberately writes
//! something broken to see what the compiler says. So the five outcomes are
//! described rather than judged — the words "wrong", "failed" and "verdict"
//! do not appear in this file.
//!
//! **Two of the five messages are undocumented.** §4.9c writes up
//! `playground.run` and `playground.save`; `playground.list`,
//! `playground.load` and `playground.delete` are live on the server and are
//! not in the contract. This client is written against all five, and the three
//! missing shapes were confirmed by probing rather than assumed.

use std::path::{Path, PathBuf};

use causewaybay_hacker_cli::error::{self, Result};
use causewaybay_hacker_cli::proto::{PlaygroundReply, SnippetList, SnippetReply};
use causewaybay_hacker_cli::render::{self, Paint};
use causewaybay_hacker_cli::workspace;

use super::stream::Watcher;
use super::Ctx;

fn lang_for_path(path: &Path) -> Result<&'static str> {
    match path.extension().and_then(|e| e.to_str()) {
        Some("rs") => Ok("rust"),
        Some("go") => Ok("go"),
        Some("cpp") => Ok("cpp"),
        Some("py") => Ok("python"),
        _ => Err(error::usage(format!(
            "cannot tell what language {} is; the playground takes a .rs, .go, .cpp or .py file",
            path.display()
        ))),
    }
}

/// `playground.run` — compile it, run it, show what it printed.
pub async fn run(ctx: &Ctx, file: &Path, stdin_file: Option<&Path>) -> Result<()> {
    let lang = lang_for_path(file)?;
    let source = workspace::read(file)?;
    workspace::check_size(&source)?;
    let stdin = match stdin_file {
        Some(path) => workspace::read(path)?,
        None => String::new(),
    };

    let mut session = ctx.session().await?;
    let mut watcher = Watcher::new(Paint::new(), false).raw(ctx.raw);
    let paint = &ctx.paint;
    println!();
    println!(
        "  {} {}",
        paint.bold("PLAYGROUND"),
        paint.dim(&format!("{}  {} bytes", file.display(), source.len()))
    );
    println!();

    watcher.mark_sent();
    let reply: Result<PlaygroundReply> = session
        .conn
        .call_with(
            "playground.run",
            serde_json::json!({ "lang": lang, "source": source, "stdin": stdin }),
            &mut |frame| watcher.on_frame(frame),
        )
        .await;
    watcher.finish();
    session.close().await;
    let result = reply?.run;

    println!();
    // Described, never judged. §4.9c: "It is also where somebody deliberately
    // writes something broken to see what the compiler says, which is the last
    // thing that should be counted against them."
    let outcome = match result.outcome.as_str() {
        "ok" => paint.green("ran"),
        "compile_error" => paint.yellow("did not compile"),
        "runtime_error" => paint.yellow("stopped early"),
        "timeout" => paint.yellow("took too long"),
        "output_limit" => paint.yellow("printed too much"),
        other => paint.yellow(other),
    };
    println!(
        "  {}  {}",
        outcome,
        paint.dim(&format!(
            "compile {}ms  run {}ms{}",
            result.compile_ms,
            result.run_ms,
            result
                .exit_code
                .map(|c| format!("  exit {c}"))
                .unwrap_or_default()
        ))
    );
    if !result.stdout.is_empty() && watcher.streams.total_bytes() == 0 {
        println!("{}", render::indent(result.stdout.trim_end(), "  "));
    }
    for diagnostic in &result.diagnostics {
        println!(
            "    {} {}",
            paint.dim(diagnostic.code.as_deref().unwrap_or("—")),
            diagnostic.message
        );
    }
    println!(
        "  {}",
        paint.dim("nothing here is recorded: no attempt, no mistake, no effect on stars")
    );
    Ok(())
}

/// `playground.save` — §4.9c. Cheap and idempotent; saving identical content
/// returns the same `updated_at` rather than churning a new version.
pub async fn save(ctx: &Ctx, file: &Path, id: Option<String>, name: Option<String>) -> Result<()> {
    let lang = lang_for_path(file)?;
    let source = workspace::read(file)?;
    let mut payload = serde_json::json!({ "lang": lang, "source": source });
    if let Some(id) = id {
        payload["id"] = serde_json::Value::String(id);
    }
    if let Some(name) = name {
        payload["name"] = serde_json::Value::String(name);
    }

    let mut session = ctx.session().await?;
    let reply: SnippetReply = session.conn.call("playground.save", payload).await?;
    session.close().await;
    let snippet = reply.snippet;
    println!(
        "  {} {}  {}",
        ctx.paint.green("saved"),
        ctx.paint.bold(&snippet.name),
        ctx.paint
            .dim(&format!("{}  updated {}", snippet.id, snippet.updated_at))
    );
    Ok(())
}

/// `playground.list` — **undocumented**; see the module comment.
pub async fn list(ctx: &Ctx) -> Result<()> {
    let mut session = ctx.session().await?;
    let list: SnippetList = session
        .conn
        .call("playground.list", serde_json::json!({}))
        .await?;
    session.close().await;
    let paint = &ctx.paint;
    if list.snippets.is_empty() {
        println!("  {}", paint.dim("no snippets"));
        return Ok(());
    }
    println!();
    for snippet in &list.snippets {
        println!(
            "  {:<20} {:<6} {:>6}B  {}",
            paint.bold(&snippet.name),
            snippet.lang,
            snippet.bytes,
            paint.dim(&format!("{}  {}", snippet.id, snippet.updated_at))
        );
    }
    Ok(())
}

/// `playground.load` — **undocumented**; see the module comment.
pub async fn load(ctx: &Ctx, id: &str, out: Option<PathBuf>) -> Result<()> {
    let mut session = ctx.session().await?;
    let reply: SnippetReply = session
        .conn
        .call("playground.load", serde_json::json!({ "id": id }))
        .await?;
    session.close().await;
    let snippet = reply.snippet;
    match out {
        Some(path) => {
            workspace::write_private(&path, &snippet.source)?;
            println!(
                "  {} {} {}",
                ctx.paint.green("wrote"),
                path.display(),
                ctx.paint.dim(&snippet.name)
            );
        }
        None => print!("{}", snippet.source),
    }
    Ok(())
}

/// `playground.delete` — **undocumented**; see the module comment.
pub async fn delete(ctx: &Ctx, id: &str) -> Result<()> {
    let mut session = ctx.session().await?;
    let _: serde_json::Value = session
        .conn
        .request("playground.delete", serde_json::json!({ "id": id }))
        .await?;
    session.close().await;
    println!("  {} {id}", ctx.paint.dim("deleted"));
    Ok(())
}
