//! `stats`, `mistakes`, `awards`, `history`.

use causewaybay_hacker_cli::error::Result;
use causewaybay_hacker_cli::proto::{Awards, History, Mistakes, Summary};
use causewaybay_hacker_cli::render;

use super::Ctx;

pub async fn summary(ctx: &Ctx) -> Result<()> {
    let mut session = ctx.session().await?;
    let stats: Summary = session
        .conn
        .call("stats.summary", serde_json::json!({}))
        .await?;
    let paint = &ctx.paint;

    println!();
    println!(
        "  {}  {}",
        paint.bold(&session.user.name),
        paint.dim(&session.user.address)
    );
    println!();
    println!(
        "    cleared    {} {}",
        paint.bold(&format!("{}/{}", stats.cleared, stats.total)),
        paint.dim(&format!(
            "({:.0}%)",
            if stats.total > 0 {
                stats.cleared as f64 / stats.total as f64 * 100.0
            } else {
                0.0
            }
        ))
    );
    println!(
        "    stars      {}",
        paint.yellow(&format!("{}★", stats.stars))
    );
    println!("    attempts   {}", stats.attempts);
    // §4.13: accepted attempts over all attempts. §4.9b excludes runs, which
    // is why iterating honestly does not look like failing repeatedly.
    println!(
        "    accuracy   {} {}",
        format_args!("{:.0}%", stats.accuracy * 100.0),
        paint.dim("(submits only — runs are not counted)")
    );
    println!("    streak     {} days", stats.streak_days);

    if !stats.by_land.is_empty() {
        println!();
        for land in &stats.by_land {
            println!("    {:<6} {:>3}/{:<3}", land.land, land.cleared, land.total);
        }
    }
    session.close().await;
    Ok(())
}

/// §4.14 — *"The heart of the training loop."*
pub async fn mistakes(ctx: &Ctx, limit: i64, include_learned: bool) -> Result<()> {
    let mut session = ctx.session().await?;
    let stats: Mistakes = session
        .conn
        .call(
            "stats.mistakes",
            serde_json::json!({ "limit": limit, "include_learned": include_learned }),
        )
        .await?;
    let paint = &ctx.paint;

    if stats.mistakes.is_empty() {
        println!(
            "  {}",
            paint.dim(if include_learned {
                "nothing recorded yet"
            } else {
                "nothing outstanding — try --all for the ones you have already fixed"
            })
        );
        session.close().await;
        return Ok(());
    }

    println!();
    for mistake in &stats.mistakes {
        println!(
            "  {:>4}×  {}  {}",
            paint.red(&mistake.count.to_string()),
            paint.bold(&mistake.label),
            paint.dim(&mistake.kind)
        );
        let mut notes = Vec::new();
        if mistake.cleared_since > 0 {
            notes.push(format!("{} clean attempts since", mistake.cleared_since));
        }
        if !mistake.concepts.is_empty() {
            notes.push(format!("drill: {}", mistake.concepts.join(", ")));
        }
        if let Some(example) = &mistake.example_quest_id {
            notes.push(example.clone());
        }
        if !notes.is_empty() {
            println!("        {}", paint.dim(&notes.join("  ·  ")));
        }
    }
    session.close().await;
    Ok(())
}

/// §4.14b — the shelf, as opposed to the fanfare. `kind: "stamp"` is never in
/// this list; it is a moment, not something a player has.
pub async fn awards(ctx: &Ctx) -> Result<()> {
    let mut session = ctx.session().await?;
    let list: Awards = session
        .conn
        .call("stats.awards", serde_json::json!({}))
        .await?;
    let paint = &ctx.paint;

    if list.awards.is_empty() {
        println!("  {}", paint.dim("the shelf is empty — clear something"));
        session.close().await;
        return Ok(());
    }
    println!();
    for award in &list.awards {
        println!(
            "  {}  {:<24} {}",
            paint.yellow("✦"),
            paint.bold(&award.title),
            paint.dim(&format!("{}  {}", award.kind, award.created_at))
        );
        if award
            .detail
            .as_object()
            .map(|o| !o.is_empty())
            .unwrap_or(false)
        {
            println!("      {}", paint.dim(&award.detail.to_string()));
        }
    }
    session.close().await;
    Ok(())
}

pub async fn history(ctx: &Ctx, quest_id: Option<&str>, limit: i64) -> Result<()> {
    let mut session = ctx.session().await?;
    let mut payload = serde_json::json!({ "limit": limit });
    if let Some(quest_id) = quest_id {
        payload["quest_id"] = serde_json::Value::String(quest_id.to_string());
    }
    let history: History = session.conn.call("stats.history", payload).await?;
    let paint = &ctx.paint;

    if history.attempts.is_empty() {
        println!("  {}", paint.dim("no attempts yet"));
        session.close().await;
        return Ok(());
    }
    println!();
    for attempt in &history.attempts {
        println!(
            "  {}  {:<16} {:>5}  {}",
            paint.dim(&attempt.created_at),
            render::verdict(paint, &attempt.verdict),
            format!("{}/{}", attempt.tests_passed, attempt.tests_total),
            paint.dim(&attempt.quest_id)
        );
        if !attempt.kinds.is_empty() {
            println!("      {}", paint.dim(&attempt.kinds.join(", ")));
        }
    }
    session.close().await;
    Ok(())
}
