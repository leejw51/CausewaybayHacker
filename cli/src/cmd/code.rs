//! The editor loop — `edit`, `run`, `submit`, `fmt`, `play`.
//!
//! The product. Everything else in this client is a way of getting here.

use std::io::{IsTerminal, Write};
use std::path::{Path, PathBuf};

use causewaybay_hacker_cli::error::{self, Code, Result};
use causewaybay_hacker_cli::proto::{Attempt, AttemptReply, FormatReply, Quest};
use causewaybay_hacker_cli::render::{self, Paint};
use causewaybay_hacker_cli::session::Session;
use causewaybay_hacker_cli::workspace;

use super::stream::Watcher;
use super::world;
use super::Ctx;

/// `cwbh edit <id>` — put the starter on disk if it is not there, then open
/// the player's editor on it.
pub async fn edit(ctx: &Ctx, quest_id: &str, path_only: bool) -> Result<()> {
    let mut session = ctx.session().await?;
    let quest = world::fetch(&mut session, quest_id).await?;
    let opened = workspace::ensure(&ctx.store, &session.user.address, &quest)?;
    // The editor may sit open for an hour. Hand the socket back rather than
    // keeping a connection alive through lunch.
    session.close().await;

    if path_only {
        // So `vim "$(cwbh edit --path rust.basic.01.hello)"` works, and so a
        // script can find the file without parsing prose.
        println!("{}", opened.path.display());
        return Ok(());
    }

    let paint = &ctx.paint;
    world::print_quest(paint, &quest, false);
    println!();
    println!(
        "  {} {}",
        if opened.created {
            paint.green("created")
        } else {
            paint.dim("yours  ")
        },
        opened.path.display()
    );
    if !opened.created {
        println!(
            "  {}",
            paint.dim("opening what you wrote last time — `cwbh reset` gives the starter back")
        );
    }
    println!();

    let result = workspace::edit(&opened.path)?;
    if result.changed {
        println!("  {} {} bytes", paint.green("saved"), result.source.len());
    } else {
        println!("  {}", paint.dim("unchanged"));
    }
    println!(
        "  {}",
        paint.dim(&format!(
            "cwbh run {}    cwbh submit {}",
            quest.id, quest.id
        ))
    );
    Ok(())
}

/// The source a `run` or `submit` will send: the player's file, or an explicit
/// override.
fn source_for(
    ctx: &Ctx,
    address: &str,
    quest: &Quest,
    file: Option<&Path>,
) -> Result<(PathBuf, String)> {
    let path = match file {
        Some(path) => path.to_path_buf(),
        None => workspace::path_for(&ctx.store, address, quest),
    };
    if !path.exists() {
        return Err(error::usage(format!(
            "{} does not exist — run `cwbh edit {}` first",
            path.display(),
            quest.id
        )));
    }
    let source = workspace::read(&path)?;
    workspace::check_size(&source)?;
    Ok((path, source))
}

/// `quest.run` (§4.9b) and `quest.submit` (§4.9) through one code path,
/// which is what §4.9b asks for: *"The same shape as `quest.submit`, and
/// deliberately so."*
async fn execute(
    ctx: &Ctx,
    session: &mut Session,
    quest: &Quest,
    source: &str,
    mode: Mode,
) -> Result<Attempt> {
    let mut watcher = Watcher::new(Paint::new(), false).raw(ctx.raw);
    println!();
    println!(
        "  {} {}",
        ctx.paint.bold(match mode {
            Mode::Run => "RUN",
            Mode::Submit => "SUBMIT",
        }),
        ctx.paint.dim(&format!(
            "{}  {} bytes  {}",
            quest.id,
            source.len(),
            match mode {
                Mode::Run => format!("{} visible case(s) only", quest.tests.visible.len()),
                Mode::Submit => format!(
                    "{} visible + {} hidden",
                    quest.tests.visible.len(),
                    quest.tests.hidden_count
                ),
            }
        ))
    );
    println!();

    watcher.mark_sent();
    // §4.9: `lang` "must match the quest's land". It comes from the quest, not
    // from the file's extension and not from a flag, so the two cannot drift.
    let payload = serde_json::json!({
        "quest_id": quest.id,
        "lang": quest.lang(),
        "source": source,
    });
    let reply: Result<AttemptReply> = session
        .conn
        .call_with(mode.message(), payload, &mut |frame| {
            watcher.on_frame(frame)
        })
        .await;
    watcher.finish();

    let reply = match reply {
        Ok(reply) => reply,
        Err(e) => {
            report_watcher(ctx, &watcher);
            return Err(e);
        }
    };

    print_attempt(
        ctx,
        quest,
        &reply.attempt,
        mode,
        watcher.streams.total_bytes() > 0,
    );
    report_watcher(ctx, &watcher);
    Ok(reply.attempt)
}

fn report_watcher(ctx: &Ctx, watcher: &Watcher) {
    let paint = &ctx.paint;
    for gap in &watcher.streams.gaps {
        // §8.8: a gap in `seq` is noticed and said, not swallowed.
        println!("  {} {}", paint.yellow("stream gap:"), gap);
    }
    for update in &watcher.progress {
        println!(
            "  {} {} {}",
            paint.green("progress"),
            update.quest_id,
            paint.dim(&format!(
                "{} · {} cleared in all{}",
                update.state,
                update.cleared_total,
                if update.unlocked.is_empty() {
                    String::new()
                } else {
                    format!(" · opens {}", update.unlocked.join(", "))
                }
            ))
        );
    }
    for award in &watcher.awards {
        println!(
            "  {}  {}  {}",
            paint.yellow("✦"),
            paint.bold(&award.title),
            paint.dim(&format!("{} · {}", award.kind, award.id))
        );
    }
    if !watcher.ignored_types.is_empty() && ctx.trace {
        println!(
            "  {}",
            paint.dim(&format!(
                "ignored {} unknown event type(s): {}",
                watcher.ignored_types.len(),
                watcher.ignored_types.join(", ")
            ))
        );
    }
    if ctx.trace {
        println!("  {}", paint.dim(&watcher.timing_note()));
    }
    if let Some(reason) = &watcher.bye {
        println!("  {} {}", paint.yellow("the server said goodbye:"), reason);
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum Mode {
    Run,
    Submit,
}

impl Mode {
    fn message(self) -> &'static str {
        match self {
            Mode::Run => "quest.run",
            Mode::Submit => "quest.submit",
        }
    }
}

/// `streamed` says whether the compiler's words already went past. §4.18's
/// stream and `Attempt.stderr` carry the same text, so printing both makes the
/// player read two copies of the same error and wonder which one is newer.
pub fn print_attempt(ctx: &Ctx, quest: &Quest, attempt: &Attempt, mode: Mode, streamed: bool) {
    let paint = &ctx.paint;
    println!();
    println!("  {}", render::attempt_line(paint, attempt));

    for case in &attempt.cases {
        let mark = if case.passed {
            paint.green("✓")
        } else {
            paint.red("✗")
        };
        let hidden = if case.visible {
            String::new()
        } else {
            paint.dim("  (hidden)")
        };
        println!("    {mark} {}{hidden}", case.name);
        // §4.8/§5.4: a hidden case reports pass/fail and its name, never its
        // data — and the server does not send the data, so there is nothing
        // here to leak even by accident.
        if !case.passed && case.visible {
            if let (Some(expect), Some(got)) = (&case.expect, &case.got) {
                println!(
                    "{}",
                    render::indent(&render::visible_whitespace(expect), "        want ")
                );
                println!(
                    "{}",
                    render::indent(&render::visible_whitespace(got), "        got  ")
                );
            }
        }
    }

    if !attempt.mistakes.is_empty() {
        println!();
        println!("  {}", paint.bold("WHAT WENT WRONG"));
        for mistake in &attempt.mistakes {
            let place = match (mistake.line, mistake.col) {
                (Some(line), Some(col)) => format!(" at {line}:{col}"),
                (Some(line), None) => format!(" at line {line}"),
                _ => String::new(),
            };
            println!(
                "    {} {}{}",
                paint.red(mistake.code.as_deref().unwrap_or("—")),
                mistake.message,
                paint.dim(&place)
            );
            println!("      {}", paint.dim(&mistake.kind));
        }
    }

    // The compiler's own words, kept whole. A trainer that summarises rustc is
    // a trainer that teaches you to read a summary.
    if !attempt.stderr.trim().is_empty() && attempt.verdict != "accepted" && !streamed {
        println!();
        println!("{}", render::indent(attempt.stderr.trim_end(), "  "));
    }

    println!();
    match mode {
        Mode::Run => {
            // §4.9b, said plainly, because the difference matters and a player
            // should never have to infer it.
            println!(
                "  {}",
                paint.dim(
                    "a run: visible cases only, no stars, no clear, not counted in accuracy \
                     — but its mistakes do go into the curriculum"
                )
            );
        }
        Mode::Submit => {
            if attempt.cleared {
                println!(
                    "  {}  {}",
                    paint.green("CLEARED"),
                    render::stars(attempt.stars)
                );
            } else if attempt.verdict == "accepted" {
                println!(
                    "  {} {}",
                    paint.green("accepted"),
                    paint.dim("— already cleared, so nothing changed")
                );
            }
            match attempt.within_limit {
                Some(true) => println!("  {}", paint.green("inside the time limit")),
                Some(false) => println!(
                    "  {}",
                    paint.yellow("after the deadline — judged all the same, just not within_limit")
                ),
                None => {}
            }
        }
    }
    let _ = quest;
}

pub async fn run(ctx: &Ctx, quest_id: &str, file: Option<PathBuf>) -> Result<bool> {
    let mut session = ctx.session().await?;
    let quest = world::fetch(&mut session, quest_id).await?;
    let (_, source) = source_for(ctx, &session.user.address, &quest, file.as_deref())?;
    let attempt = execute(ctx, &mut session, &quest, &source, Mode::Run).await?;
    session.close().await;
    Ok(attempt.verdict == "accepted")
}

pub async fn submit(ctx: &Ctx, quest_id: &str, file: Option<PathBuf>) -> Result<bool> {
    let mut session = ctx.session().await?;
    let quest = world::fetch(&mut session, quest_id).await?;
    let (_, source) = source_for(ctx, &session.user.address, &quest, file.as_deref())?;
    let attempt = execute(ctx, &mut session, &quest, &source, Mode::Submit).await?;
    session.close().await;
    Ok(attempt.verdict == "accepted")
}

/// `code.format` (§4.9d) over a file, in place.
///
/// The whole subtlety of this message is the failure case: source that does
/// not parse is **not** an error, the reply is `.ok`, and the source comes
/// back byte for byte. So this writes nothing when `problem` is set —
/// *"a formatter that mangles code it could not parse is worse than no
/// formatter, because the player then has two problems."*
pub async fn fmt(ctx: &Ctx, file: &Path) -> Result<()> {
    let lang = lang_for_path(file)?;
    let source = workspace::read(file)?;
    workspace::check_size(&source)?;

    let mut session = ctx.session().await?;
    let reply: FormatReply = session
        .conn
        .call(
            "code.format",
            serde_json::json!({ "lang": lang, "source": source }),
        )
        .await?;
    session.close().await;

    let paint = &ctx.paint;
    if let Some(problem) = &reply.problem {
        // Quietly, and the buffer is left exactly as it was.
        println!("  {} {}", paint.yellow("not formatted:"), problem);
        println!(
            "  {}",
            paint.dim(&format!("{} is unchanged", file.display()))
        );
        return Ok(());
    }
    if !reply.changed {
        println!("  {}", paint.dim("already tidy"));
        return Ok(());
    }
    workspace::write_private(file, &reply.source)?;
    println!(
        "  {} {} {}",
        paint.green("formatted"),
        file.display(),
        paint.dim(&format!(
            "({} → {} bytes, {})",
            source.len(),
            reply.source.len(),
            formatter_label(lang)
        ))
    );
    Ok(())
}

/// The tool the server ran, named the way the player knows it. Python has no
/// formatter (SPEC §5.1), so the server answers `unsupported` before this is
/// ever printed for a `.py` file.
fn formatter_label(lang: &str) -> &'static str {
    match lang {
        "rust" => "rustfmt",
        "go" => "gofmt",
        "cpp" => "clang-format",
        // Both Python lands format with black; the fifth is not a language.
        "python" | "pytorch" => "black",
        "typescript" => "prettier",
        _ => "formatter",
    }
}

fn lang_for_path(path: &Path) -> Result<&'static str> {
    match path.extension().and_then(|e| e.to_str()) {
        Some("rs") => Ok("rust"),
        Some("go") => Ok("go"),
        Some("cpp") => Ok("cpp"),
        Some("py") => Ok("python"),
        Some("ts") => Ok("typescript"),
        _ => Err(error::usage(format!(
            "cannot tell what language {} is; cwbh fmt takes a .rs, .go, .cpp, .py or .ts file",
            path.display()
        ))),
    }
}

/// `cwbh play <id>` — the loop.
///
/// edit → run → decide. Everything a player does between opening a quest and
/// clearing it, without leaving the terminal, and with the file staying theirs
/// the whole way through.
pub async fn play(ctx: &Ctx, quest_id: &str) -> Result<()> {
    let paint = &ctx.paint;
    let mut session = ctx.session().await?;
    let mut quest = world::fetch(&mut session, quest_id).await?;
    let opened = workspace::ensure(&ctx.store, &session.user.address, &quest)?;
    let path = opened.path.clone();
    world::print_quest(paint, &quest, false);
    println!();
    println!(
        "  {} {}",
        if opened.created {
            paint.green("created")
        } else {
            paint.dim("yours  ")
        },
        path.display()
    );

    let interactive = std::io::stdin().is_terminal();
    if !interactive {
        return Err(error::usage(
            "`cwbh play` needs a terminal; use `cwbh edit`, `cwbh run` and `cwbh submit`",
        ));
    }

    let mut action = Action::Edit;
    loop {
        match action {
            Action::Edit => {
                session.close().await;
                let result = workspace::edit(&path)?;
                if !result.changed {
                    println!(
                        "  {}",
                        paint.dim(
                            "the file did not change — if your editor returns immediately, \
                             it needs a wait flag ($EDITOR=\"code -w\")"
                        )
                    );
                }
                session = ctx.session().await?;
                action = Action::Run;
            }
            Action::Run | Action::Submit => {
                let mode = if action == Action::Run {
                    Mode::Run
                } else {
                    Mode::Submit
                };
                let source = workspace::read(&path)?;
                workspace::check_size(&source)?;
                match execute(ctx, &mut session, &quest, &source, mode).await {
                    Ok(attempt) => {
                        if attempt.cleared {
                            println!();
                            println!(
                                "  {}",
                                paint.dim(&format!("your source stays at {}", path.display()))
                            );
                            break;
                        }
                    }
                    Err(e) if *e.code.effective() == Code::Busy => {
                        // §3.2: one execution per connection. Nothing to do
                        // but say so; the loop is single-threaded, so this
                        // means an earlier run is still finishing server-side.
                        println!("  {}", paint.yellow(&render::explain(&e)));
                    }
                    Err(e) => return Err(e),
                }
                action = Action::Ask;
            }
            Action::Format => {
                let source = workspace::read(&path)?;
                let reply: FormatReply = session
                    .conn
                    .call(
                        "code.format",
                        serde_json::json!({ "lang": quest.lang(), "source": source }),
                    )
                    .await?;
                if let Some(problem) = &reply.problem {
                    println!("  {} {}", paint.yellow("not formatted:"), problem);
                } else if reply.changed {
                    workspace::write_private(&path, &reply.source)?;
                    println!("  {}", paint.green("formatted"));
                } else {
                    println!("  {}", paint.dim("already tidy"));
                }
                action = Action::Ask;
            }
            Action::Hint => {
                let next = quest.hints_used.min(quest.hints_total.saturating_sub(1));
                if quest.hints_total == 0 {
                    println!("  {}", paint.dim("this quest has no hints"));
                } else {
                    let hint: causewaybay_hacker_cli::proto::Hint = session
                        .conn
                        .call(
                            "quest.hint",
                            serde_json::json!({ "quest_id": quest.id, "index": next }),
                        )
                        .await?;
                    println!();
                    println!("{}", render::indent(hint.hint.trim(), "  "));
                    quest.hints_used = hint.hints_used;
                }
                action = Action::Ask;
            }
            Action::Ask => {
                print!(
                    "\n  {} ",
                    paint.bold("[e]dit  [r]un  [s]ubmit  [f]ormat  [h]int  [q]uit:")
                );
                let _ = std::io::stdout().flush();
                let mut answer = String::new();
                if std::io::stdin().read_line(&mut answer)? == 0 {
                    break;
                }
                action = match answer.trim().to_lowercase().chars().next() {
                    Some('e') | None => Action::Edit,
                    Some('r') => Action::Run,
                    Some('s') => Action::Submit,
                    Some('f') => Action::Format,
                    Some('h') => Action::Hint,
                    Some('q') => break,
                    _ => Action::Ask,
                };
            }
        }
    }

    session.close().await;
    Ok(())
}

#[derive(Clone, Copy, PartialEq)]
enum Action {
    Edit,
    Run,
    Submit,
    Format,
    Hint,
    Ask,
}
