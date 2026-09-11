//! `maps`, `map`, `quest`, `hint`, `reset`, `search`, `drill`.

use causewaybay_hacker_cli::error::Result;
use causewaybay_hacker_cli::proto::{Hint, Lands, Quest, QuestReply, Reset, WorldMap};
use causewaybay_hacker_cli::render::{self, Paint};
use causewaybay_hacker_cli::session::Session;
use causewaybay_hacker_cli::workspace;

use super::Ctx;

/// `world.lands` — the land and category select, as a table.
pub async fn maps(ctx: &Ctx) -> Result<()> {
    let mut session = ctx.session().await?;
    let lands: Lands = session
        .conn
        .call("world.lands", serde_json::json!({}))
        .await?;
    let paint = &ctx.paint;

    for land in &lands.lands {
        println!();
        println!("  {}", paint.bold(&land.land.to_uppercase()));
        for category in &land.categories {
            let bar = progress_bar(category.cleared, category.total, 20);
            println!(
                "    {:<9} {} {:>3}/{:<3}  {}  {}",
                category.category,
                bar,
                category.cleared,
                category.total,
                paint.yellow(&format!("{:>3}★", category.stars)),
                // §4.6: `open` is false when the category's first node is
                // still locked. §4.7 then says nothing is ever locked, so this
                // is advice about where to start, not a gate — and it is
                // printed as advice.
                if category.open {
                    String::new()
                } else {
                    paint.dim("(suggested later)")
                }
            );
        }
    }
    println!();
    println!(
        "  {}",
        paint.dim("cwbh map <land> <category>   — every node is playable, in any order")
    );
    session.close().await;
    Ok(())
}

fn progress_bar(done: i64, total: i64, width: usize) -> String {
    if total <= 0 {
        return " ".repeat(width);
    }
    let filled = ((done as f64 / total as f64) * width as f64).round() as usize;
    format!(
        "{}{}",
        "█".repeat(filled.min(width)),
        "░".repeat(width.saturating_sub(filled))
    )
}

/// `world.map` — one overworld, as a list in node order.
pub async fn map(ctx: &Ctx, land: &str, category: &str) -> Result<()> {
    let mut session = ctx.session().await?;
    let world: WorldMap = session
        .conn
        .call(
            "world.map",
            serde_json::json!({ "land": land, "category": category }),
        )
        .await?;
    let paint = &ctx.paint;

    println!();
    println!(
        "  {}",
        paint.bold(&format!(
            "{} / {}",
            world.land.to_uppercase(),
            world.category.to_uppercase()
        ))
    );
    println!();

    let cleared = world.nodes.iter().filter(|n| n.state == "cleared").count();
    for node in &world.nodes {
        let kind = match node.kind.as_str() {
            "boss" => paint.red(" BOSS"),
            "gate" => paint.yellow(" GATE"),
            _ => String::new(),
        };
        println!(
            "  {} {:>3}  {:<28} {}  {}  {}{}",
            render::state_mark(paint, &node.state),
            node.node,
            node.title,
            render::stars(node.stars),
            paint.dim(&render::difficulty(node.difficulty)),
            paint.dim(&node.quest_id),
            kind
        );
    }

    println!();
    println!(
        "  {} cleared, {} to go{}",
        cleared,
        world.nodes.len() - cleared,
        if world.edges.is_empty() {
            String::new()
        } else {
            format!("  {}", paint.dim(&format!("{} paths", world.edges.len())))
        }
    );
    // §4.7: the route is advice. Say where it suggests going, and say that it
    // is a suggestion.
    if let Some(next) = suggested_next(&world) {
        println!("  {} {}", paint.dim("the map suggests"), paint.bold(&next));
    }
    println!(
        "  {}",
        paint.dim("cwbh quest <id> to read one; any node is playable")
    );

    ctx.store.set_map_pos(
        &ctx.server,
        land,
        category,
        &world
            .nodes
            .first()
            .map(|n| n.quest_id.clone())
            .unwrap_or_default(),
    )?;
    session.close().await;
    Ok(())
}

/// The first open node whose `requires` are all cleared — the route the
/// content was written to be learned in.
fn suggested_next(world: &WorldMap) -> Option<String> {
    let cleared: std::collections::HashSet<&str> = world
        .nodes
        .iter()
        .filter(|n| n.state == "cleared")
        .map(|n| n.quest_id.as_str())
        .collect();
    world
        .nodes
        .iter()
        .find(|n| n.state != "cleared" && n.requires.iter().all(|r| cleared.contains(r.as_str())))
        .map(|n| n.quest_id.clone())
}

/// Fetch one quest. Used by `quest`, `edit`, `run`, `submit` and `play`.
///
/// **This is not a free read.** §4.8b: the first `quest.get` for a timed quest
/// stamps `opened_at` and the clock starts. Every command that calls this
/// prints the deadline for exactly that reason — a side effect the player
/// cannot see is a side effect that will surprise them later.
pub async fn fetch(session: &mut Session, quest_id: &str) -> Result<Quest> {
    let reply: QuestReply = session
        .conn
        .call("quest.get", serde_json::json!({ "quest_id": quest_id }))
        .await?;
    Ok(reply.quest)
}

/// `quest.get` — the brief, to stdout.
pub async fn quest(ctx: &Ctx, quest_id: &str, want_solution: bool) -> Result<()> {
    let mut session = ctx.session().await?;
    let quest = fetch(&mut session, quest_id).await?;
    print_quest(&ctx.paint, &quest, want_solution);
    println!();
    println!(
        "  {}",
        ctx.paint
            .dim(&format!("cwbh play {}   to edit, run and submit", quest.id))
    );
    session.close().await;
    Ok(())
}

pub fn print_quest(paint: &Paint, quest: &Quest, want_solution: bool) {
    println!();
    print!("  {}", render::quest_header(paint, quest));

    if let Some(deadline) = clock_line(paint, quest) {
        println!("  {deadline}");
    }
    if !quest.concepts.is_empty() {
        println!("  {} {}", paint.dim("concepts"), quest.concepts.join(", "));
    }

    if !quest.story.trim().is_empty() {
        println!();
        println!("{}", render::indent(quest.story.trim(), "  "));
    }
    println!();
    println!("{}", render::indent(quest.brief.trim(), "  "));

    // §4.8: `tests.visible`, never `tests.cases` — the latter is the content
    // pack's name and would render an empty list that looks like a quest with
    // no tests rather than like a bug.
    println!();
    println!(
        "  {} {}",
        paint.bold("TESTS"),
        paint.dim(&format!(
            "{} visible, {} hidden, match \"{}\", {}ms each",
            quest.tests.visible.len(),
            quest.tests.hidden_count,
            quest.tests.r#match,
            quest.tests.timeout_ms
        ))
    );
    for case in &quest.tests.visible {
        println!("    {}", paint.cyan(&case.name));
        if !case.stdin.is_empty() {
            println!(
                "{}",
                render::indent(&render::visible_whitespace(&case.stdin), "      in  ")
            );
        }
        println!(
            "{}",
            render::indent(&render::visible_whitespace(&case.expect), "      out ")
        );
    }

    println!();
    println!("  {}", paint.bold("STARTER"));
    println!("{}", render::indent(&quest.starter, "    "));

    match (&quest.solution, want_solution) {
        (Some(solution), true) => {
            println!();
            println!("  {}", paint.bold("SOLUTION"));
            println!("{}", render::indent(solution, "    "));
        }
        (Some(_), false) => {
            println!();
            println!(
                "  {}",
                paint.dim("you cleared this one — `--solution` shows how the author did it")
            );
        }
        // §4.8: omitted entirely until cleared. Nothing to say.
        (None, _) => {}
    }
}

/// §4.8b: the clock is the server's. This renders the pair it sent and nothing
/// derived from a local timer, because a client-side countdown cannot support
/// a claim like "cleared inside the limit".
fn clock_line(paint: &Paint, quest: &Quest) -> Option<String> {
    let limit = quest.time_limit_s?;
    let Some(deadline) = quest.deadline_at.as_deref() else {
        // A limit with no deadline is a fact about the quest, not half a
        // clock: the node was cleared before the clock existed, or is cleared
        // now and untimed on re-entry.
        return Some(paint.dim(&format!("time limit {}s — not running", limit)));
    };
    let remaining = chrono::DateTime::parse_from_rfc3339(deadline)
        .ok()
        .map(|d| d.with_timezone(&chrono::Utc) - chrono::Utc::now());
    Some(match remaining {
        Some(left) if left.num_seconds() > 0 => format!(
            "{} {}",
            paint.yellow(&format!(
                "⏱ {:02}:{:02} left",
                left.num_seconds() / 60,
                left.num_seconds() % 60
            )),
            paint.dim(&format!("of {limit}s, deadline {deadline}"))
        ),
        // §4.8b: "Time runs out and the quest stays open… a submit after the
        // deadline is judged exactly as one before it."
        _ => format!(
            "{} {}",
            paint.dim("⏱ the clock ran out"),
            paint.dim("— the quest is still open and still judged; it just is not within_limit")
        ),
    })
}

/// `quest.hint` — taking one costs stars and is permanent.
pub async fn hint(ctx: &Ctx, quest_id: &str, index: Option<i64>) -> Result<()> {
    let mut session = ctx.session().await?;
    let quest = fetch(&mut session, quest_id).await?;
    let paint = &ctx.paint;

    if quest.hints_total == 0 {
        println!("  {}", paint.dim("this quest has no hints"));
        session.close().await;
        return Ok(());
    }
    // Default to the next one not yet taken, so `cwbh hint <id>` twice gives
    // two hints rather than the same one.
    let index = index.unwrap_or(quest.hints_used.min(quest.hints_total - 1));
    if index >= quest.hints_used {
        println!(
            "  {}",
            paint.yellow(&format!(
                "hint {} of {} — this costs stars, permanently (SPEC §6.3)",
                index + 1,
                quest.hints_total
            ))
        );
    }
    let hint: Hint = session
        .conn
        .call(
            "quest.hint",
            serde_json::json!({ "quest_id": quest_id, "index": index }),
        )
        .await?;
    println!();
    println!("{}", render::indent(hint.hint.trim(), "  "));
    println!();
    println!(
        "  {}",
        paint.dim(&format!("{} of {} taken", hint.hints_used, hint.total))
    );
    session.close().await;
    Ok(())
}

/// `quest.reset` — the starter back, explicitly.
///
/// §4.11: *"**Does not** touch progress, attempts, stars or hints — it is an
/// editor convenience, not an undo."* Which is exactly why it overwrites the
/// player's file and `cwbh edit` never does.
pub async fn reset(ctx: &Ctx, quest_id: &str, yes: bool) -> Result<()> {
    let mut session = ctx.session().await?;
    let quest = fetch(&mut session, quest_id).await?;
    let path = workspace::path_for(&ctx.store, &session.user.address, &quest);
    let paint = &ctx.paint;

    if path.exists() && !yes {
        use std::io::{IsTerminal, Write};
        if !std::io::stdin().is_terminal() {
            return Err(causewaybay_hacker_cli::error::usage(format!(
                "{} exists; re-run with --yes to overwrite it",
                path.display()
            )));
        }
        eprint!("  overwrite {} with the starter? [y/N]: ", path.display());
        let _ = std::io::stderr().flush();
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer)?;
        if !matches!(answer.trim().to_lowercase().as_str(), "y" | "yes") {
            println!("  left alone");
            session.close().await;
            return Ok(());
        }
    }

    let starter: Reset = session
        .conn
        .call("quest.reset", serde_json::json!({ "quest_id": quest_id }))
        .await?;
    workspace::reset(&ctx.store, &path, &starter.starter)?;
    println!("  {} {}", paint.green("reset"), path.display());
    println!(
        "  {}",
        paint.dim("progress, stars, attempts and hints are untouched (PROTOCOL §4.11)")
    );
    session.close().await;
    Ok(())
}

/// `search.query` — real, specified, and not built yet on this server.
///
/// §3.3 is emphatic that this must not be reported as `internal`. The command
/// exists so the answer is the true one rather than a missing subcommand.
pub async fn search(ctx: &Ctx, query: &str, limit: i64) -> Result<()> {
    let mut session = ctx.session().await?;
    let result: Result<serde_json::Value> = session
        .conn
        .request(
            "search.query",
            serde_json::json!({ "q": query, "mode": "unified", "limit": limit }),
        )
        .await;
    session.close().await;

    let hits = match result {
        Ok(payload) => payload,
        Err(e) => return Err(e),
    };
    let paint = &ctx.paint;
    let empty = vec![];
    let list = hits
        .get("hits")
        .and_then(|v| v.as_array())
        .unwrap_or(&empty);
    if list.is_empty() {
        println!("  nothing matched \"{query}\"");
        return Ok(());
    }
    println!();
    for hit in list {
        println!(
            "  {}  {}",
            paint.bold(hit["title"].as_str().unwrap_or("")),
            paint.dim(hit["quest_id"].as_str().unwrap_or(""))
        );
        if let Some(snippet) = hit.get("snippet").and_then(|v| v.as_str()) {
            println!("    {}", snippet.replace("<b>", "").replace("</b>", ""));
        }
    }
    Ok(())
}

/// `ai.plan` — the drill. Also not built on this server yet.
pub async fn drill(ctx: &Ctx, mode: &str, land: Option<&str>, size: i64) -> Result<()> {
    let mut session = ctx.session().await?;
    let mut payload = serde_json::json!({ "mode": mode, "size": size });
    if let Some(land) = land {
        payload["land"] = serde_json::Value::String(land.to_string());
    }
    let result: Result<serde_json::Value> = session.conn.request("ai.plan", payload).await;
    session.close().await;
    let plan = result?;
    println!("{}", serde_json::to_string_pretty(&plan)?);
    Ok(())
}
