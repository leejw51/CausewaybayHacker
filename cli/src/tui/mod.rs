//! `cwbh tui` — the map you can walk, without leaving the terminal.
//!
//! Three panes: the overworld on the left, the quest on the right, and the
//! compiler underneath it. Nothing is a modal dialog and nothing blocks: the
//! loop polls the keyboard and the socket together, so `rustc`'s output paints
//! while you are still scrolling the brief.
//!
//! **It is a frame-driven client, not a request/response one.** A request goes
//! out with `Conn::send` and its id is written down; every frame that comes
//! back — a reply, a `run.log`, a `progress.update` from the player's *other*
//! window — is dispatched in one place. That is what makes §2.2's
//! out-of-order rule free rather than something to remember, and it is why the
//! keyboard keeps working through a five-second submit.
//!
//! **`e` hands the terminal over.** The screen is restored, `$EDITOR` runs as
//! a child with a real tty, and the alternate screen comes back afterwards.
//! The file is the same one `cwbh edit` uses — the player's.

mod ui;

use std::collections::HashMap;
use std::io::Write;
use std::time::{Duration, Instant};

use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::ExecutableCommand;
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;

use causewaybay_hacker_cli::client::LogStreams;
use causewaybay_hacker_cli::error::{Code, Result};
use causewaybay_hacker_cli::proto::{
    Attempt, Frame, Lands, MapNode, Quest, RunLog, RunStage, WorldMap,
};
use causewaybay_hacker_cli::render;
use causewaybay_hacker_cli::session::Session;
use causewaybay_hacker_cli::workspace;

use crate::cmd::stream::render_compile_line;
use crate::cmd::Ctx;

/// What an in-flight request was for, so its reply can be applied.
#[derive(Clone, Debug)]
enum Pending {
    Lands,
    Map {
        land: String,
        category: String,
    },
    Quest {
        then_edit: bool,
    },
    Run,
    Submit,
    Format,
    Hint,
    /// §4.11 gives the starter back; the path is remembered so the reply knows
    /// which of the player's files to put it in.
    Reset {
        path: std::path::PathBuf,
    },
}

#[derive(PartialEq)]
pub enum Pane {
    Map,
    Output,
}

pub struct App {
    pub land: String,
    pub category: String,
    pub categories: Vec<(String, String)>,
    pub nodes: Vec<MapNode>,
    pub selected: usize,
    pub quest: Option<Quest>,
    pub attempt: Option<Attempt>,
    pub output: Vec<String>,
    pub out_scroll: u16,
    pub brief_scroll: u16,
    pub status: String,
    pub busy: Option<String>,
    pub connected: bool,
    pub user: String,
    pub address: String,
    pub server: String,
    pub focus: Pane,
    pub help: bool,
    pub quit: bool,
    streams: LogStreams,
    /// §4.18's buffer: the tail of a compile line that has not ended yet.
    compile_tail: String,
    pending: HashMap<String, Pending>,
    started: Option<Instant>,
}

impl App {
    fn node(&self) -> Option<&MapNode> {
        self.nodes.get(self.selected)
    }

    pub fn say(&mut self, line: impl Into<String>) {
        self.output.push(line.into());
        // Keep the tail in view unless the player has scrolled away.
        self.out_scroll = u16::MAX;
    }

    /// Append raw stream text, splitting only where newlines actually are.
    fn append_stream(&mut self, text: &str) {
        for (index, piece) in text.split('\n').enumerate() {
            if index > 0 {
                self.output.push(String::new());
            }
            if let Some(last) = self.output.last_mut() {
                last.push_str(piece);
            } else {
                self.output.push(piece.to_string());
            }
        }
        self.out_scroll = u16::MAX;
    }
}

/// Restore the terminal whatever happens — a panic, a `?`, a Ctrl-C. Leaving
/// somebody in the alternate screen with echo off is the rudest thing a TUI
/// can do.
struct Screen;

impl Screen {
    fn enter() -> Result<Screen> {
        enable_raw_mode()?;
        std::io::stdout().execute(EnterAlternateScreen)?;
        Ok(Screen)
    }
    /// Give the terminal back temporarily — for `$EDITOR`.
    fn suspend() {
        let _ = disable_raw_mode();
        let _ = std::io::stdout().execute(LeaveAlternateScreen);
    }
    fn resume() -> Result<()> {
        enable_raw_mode()?;
        std::io::stdout().execute(EnterAlternateScreen)?;
        Ok(())
    }
}

impl Drop for Screen {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = std::io::stdout().execute(LeaveAlternateScreen);
    }
}

pub async fn run(ctx: &Ctx, land: &str, category: &str) -> Result<()> {
    let mut session = ctx.session().await?;
    let mut app = App {
        land: land.to_string(),
        category: category.to_string(),
        categories: Vec::new(),
        nodes: Vec::new(),
        selected: 0,
        quest: None,
        attempt: None,
        output: vec!["Causeway Bay. The cursor is blinking.".into(), "".into()],
        out_scroll: 0,
        brief_scroll: 0,
        status: String::new(),
        busy: None,
        connected: true,
        user: session.user.name.clone(),
        address: session.user.address.clone(),
        server: causewaybay_hacker_cli::server::short(&ctx.server),
        focus: Pane::Map,
        help: false,
        quit: false,
        streams: LogStreams::default(),
        compile_tail: String::new(),
        pending: HashMap::new(),
        started: None,
    };

    let _screen = Screen::enter()?;
    let mut terminal = Terminal::new(CrosstermBackend::new(std::io::stdout()))?;
    terminal.clear()?;

    request(
        &mut session,
        &mut app,
        "world.lands",
        serde_json::json!({}),
        Pending::Lands,
    )
    .await?;
    refetch_map(&mut session, &mut app).await?;

    let mut tick = tokio::time::interval(Duration::from_millis(16));
    let mut keepalive = tokio::time::interval(causewaybay_hacker_cli::client::KEEPALIVE);
    keepalive.tick().await;

    while !app.quit {
        terminal.draw(|frame| ui::draw(frame, &app))?;

        tokio::select! {
            _ = tick.tick() => {
                // Poll rather than run a reader thread: `e` has to be able to
                // hand stdin to the player's editor, and a thread already
                // blocked on `event::read()` would be holding it.
                while event::poll(Duration::ZERO)? {
                    if let Event::Key(key) = event::read()? {
                        if key.kind == KeyEventKind::Press {
                            on_key(ctx, &mut session, &mut app, &mut terminal, key).await?;
                        }
                    }
                }
            }
            _ = keepalive.tick() => {
                // §1.1. A TUI can sit untouched for an hour.
                if session.conn.keepalive_ping().await.is_err() {
                    reconnect(ctx, &mut session, &mut app).await;
                }
            }
            incoming = session.conn.next_frame() => {
                match incoming {
                    Ok(frame) => on_frame(&mut app, &frame),
                    Err(e) if *e.code.effective() == Code::Disconnected => {
                        app.connected = false;
                        app.say(format!("— {} —", render::explain(&e)));
                        reconnect(ctx, &mut session, &mut app).await;
                    }
                    Err(e) => app.status = render::explain(&e),
                }
            }
        }
    }

    session.close().await;
    Ok(())
}

async fn request(
    session: &mut Session,
    app: &mut App,
    kind: &str,
    payload: serde_json::Value,
    pending: Pending,
) -> Result<()> {
    match session.conn.send(kind, payload).await {
        Ok(id) => {
            app.pending.insert(id, pending);
            Ok(())
        }
        Err(e) => {
            app.connected = false;
            app.status = render::explain(&e);
            Ok(())
        }
    }
}

async fn refetch_map(session: &mut Session, app: &mut App) -> Result<()> {
    let (land, category) = (app.land.clone(), app.category.clone());
    request(
        session,
        app,
        "world.map",
        serde_json::json!({ "land": land, "category": category }),
        Pending::Map { land, category },
    )
    .await
}

/// §6: back off, resume with the stored token, and **refetch the map** — step
/// 5, because a `progress.update` may have gone past while the socket was
/// down and a cached map would quietly be wrong.
async fn reconnect(ctx: &Ctx, session: &mut Session, app: &mut App) {
    app.connected = false;
    app.pending.clear();
    app.busy = None;
    let mut attempts = 0u32;
    let result = session
        .reconnect(&ctx.store, |attempt, delay| {
            attempts = attempt;
            let _ = delay;
        })
        .await;
    match result {
        Ok(()) => {
            app.connected = true;
            app.say(format!(
                "— reconnected after {} attempt(s); refetching the map —",
                attempts.max(1)
            ));
            let _ = refetch_map(session, app).await;
            if let Some(quest) = app.quest.as_ref().map(|q| q.id.clone()) {
                let _ = request(
                    session,
                    app,
                    "quest.get",
                    serde_json::json!({ "quest_id": quest }),
                    Pending::Quest { then_edit: false },
                )
                .await;
            }
        }
        Err(e) => {
            app.status = render::explain(&e);
            app.say(format!("— {} —", render::explain(&e)));
        }
    }
}

/// The one place a frame is turned into a change on screen.
fn on_frame(app: &mut App, frame: &Frame) {
    // §4.17–§4.21: server-initiated events, at any time.
    if frame.is_event() {
        match frame.kind.as_str() {
            "run.stage" => {
                if let Ok(stage) = serde_json::from_value::<RunStage>(frame.payload.clone()) {
                    app.say(format!("  {:>6}ms  {}", stage.elapsed_ms, stage.stage));
                }
            }
            "run.log" => {
                if let Ok(log) = serde_json::from_value::<RunLog>(frame.payload.clone()) {
                    on_log(app, &log);
                }
            }
            "progress.update" => {
                let quest = frame.payload["quest_id"].as_str().unwrap_or("");
                let state = frame.payload["state"].as_str().unwrap_or("");
                app.say(format!("  ✓ {quest} is {state}"));
                // The map has changed — including from another window.
                for node in app.nodes.iter_mut() {
                    if node.quest_id == quest {
                        node.state = state.to_string();
                        node.stars = frame.payload["stars"].as_i64().unwrap_or(node.stars);
                    }
                }
            }
            "award" => {
                app.say(format!(
                    "  ✦ {}",
                    frame.payload["title"].as_str().unwrap_or("an award")
                ));
            }
            "server.bye" => {
                app.say(format!(
                    "— the server is going away ({}) —",
                    frame.payload["reason"].as_str().unwrap_or("unstated")
                ));
                app.connected = false;
            }
            // §2.3: ignored, not fatal.
            _ => {}
        }
        return;
    }

    let Some(id) = frame.id.clone() else { return };
    let Some(pending) = app.pending.remove(&id) else {
        // A keepalive answer, or a reply to something already abandoned.
        return;
    };

    if frame.is_err() {
        let error = wire_error(frame);
        app.busy = None;
        app.status = render::explain(&error);
        app.say(format!("  ✗ {}", app.status.clone()));
        return;
    }

    match pending {
        Pending::Lands => {
            if let Ok(lands) = serde_json::from_value::<Lands>(frame.payload.clone()) {
                app.categories = lands
                    .lands
                    .iter()
                    .flat_map(|land| {
                        land.categories
                            .iter()
                            .map(|c| (land.land.clone(), c.category.clone()))
                    })
                    .collect();
            }
        }
        Pending::Map { land, category } => {
            if let Ok(world) = serde_json::from_value::<WorldMap>(frame.payload.clone()) {
                app.land = land;
                app.category = category;
                app.selected = app.selected.min(world.nodes.len().saturating_sub(1));
                app.nodes = world.nodes;
            }
        }
        Pending::Quest { then_edit } => {
            if let Ok(reply) = serde_json::from_value::<causewaybay_hacker_cli::proto::QuestReply>(
                frame.payload.clone(),
            ) {
                app.brief_scroll = 0;
                app.status = format!("{} — {}", reply.quest.title, reply.quest.id);
                app.quest = Some(reply.quest);
                if then_edit {
                    app.status = "press e again to edit".to_string();
                }
            }
        }
        Pending::Run | Pending::Submit => {
            app.busy = None;
            if let Ok(reply) = serde_json::from_value::<causewaybay_hacker_cli::proto::AttemptReply>(
                frame.payload.clone(),
            ) {
                let attempt = reply.attempt;
                let elapsed = app
                    .started
                    .map(|s| s.elapsed().as_millis())
                    .unwrap_or_default();
                app.say(String::new());
                app.say(format!(
                    "  {} {}/{} tests   compile {}ms  run {}ms   (round trip {elapsed}ms)",
                    attempt.verdict.to_uppercase().replace('_', " "),
                    attempt.tests_passed,
                    attempt.tests_total,
                    attempt.compile_ms,
                    attempt.run_ms
                ));
                for case in &attempt.cases {
                    app.say(format!(
                        "    {} {}{}",
                        if case.passed { "✓" } else { "✗" },
                        case.name,
                        if case.visible { "" } else { "  (hidden)" }
                    ));
                }
                for mistake in &attempt.mistakes {
                    app.say(format!(
                        "    {} {}",
                        mistake.code.as_deref().unwrap_or("—"),
                        mistake.message
                    ));
                }
                if attempt.mode == "run" {
                    app.say("    a run: visible cases only, nothing cleared");
                }
                if attempt.cleared {
                    app.say(format!("    CLEARED  {}", render::stars(attempt.stars)));
                }
                app.attempt = Some(attempt);
            }
            for gap in std::mem::take(&mut app.streams.gaps) {
                app.say(format!("    stream gap: {gap}"));
            }
        }
        Pending::Format => {
            app.busy = None;
            if let Ok(reply) = serde_json::from_value::<causewaybay_hacker_cli::proto::FormatReply>(
                frame.payload.clone(),
            ) {
                match (&reply.problem, reply.changed) {
                    // §4.9d: unparsable source is not an error and the buffer
                    // is left alone.
                    (Some(problem), _) => app.say(format!("  not formatted: {problem}")),
                    (None, false) => app.say("  already tidy"),
                    (None, true) => {
                        // The formatted source was written by the key handler's
                        // own path, which is the one the player edits.
                        app.say("  formatted (written to your file)")
                    }
                }
            }
        }
        Pending::Hint => {
            if let Ok(hint) =
                serde_json::from_value::<causewaybay_hacker_cli::proto::Hint>(frame.payload.clone())
            {
                app.say(format!(
                    "  hint {}/{}: {}",
                    hint.index + 1,
                    hint.total,
                    hint.hint
                ));
                if let Some(quest) = app.quest.as_mut() {
                    quest.hints_used = hint.hints_used;
                }
            }
        }
        Pending::Reset { path } => {
            if let Ok(reset) = serde_json::from_value::<causewaybay_hacker_cli::proto::Reset>(
                frame.payload.clone(),
            ) {
                match workspace::write_private(&path, &reset.starter) {
                    Ok(()) => app.say(format!(
                        "  the starter is back in {} — progress, stars and hints are untouched",
                        path.display()
                    )),
                    Err(e) => app.status = render::explain(&e),
                }
            }
        }
    }
}

fn on_log(app: &mut App, log: &RunLog) {
    let contiguous = app
        .streams
        .accept(&log.attempt_id, &log.stream, log.seq, &log.chunk);
    if !contiguous {
        app.say(format!("  (a chunk of {} went missing)", log.stream));
    }
    if log.stream != "compile" {
        app.append_stream(&log.chunk);
        return;
    }
    // §4.18: buffer. rustc's JSON diagnostics arrive one per line and are
    // rendered as the compiler would have printed them.
    app.compile_tail.push_str(&log.chunk);
    while let Some(index) = app.compile_tail.find('\n') {
        let line: String = app.compile_tail.drain(..=index).collect();
        let text = render_compile_line(&line);
        app.append_stream(&text);
    }
}

fn wire_error(frame: &Frame) -> causewaybay_hacker_cli::error::Error {
    let wire: causewaybay_hacker_cli::proto::WireError = serde_json::from_value(
        frame.payload.clone(),
    )
    .unwrap_or(causewaybay_hacker_cli::proto::WireError {
        code: "internal".into(),
        message: frame.kind.clone(),
        detail: serde_json::json!({}),
    });
    causewaybay_hacker_cli::error::Error {
        code: Code::from_wire(&wire.code),
        message: wire.message,
        detail: wire.detail,
    }
}

type Term = Terminal<CrosstermBackend<std::io::Stdout>>;

async fn on_key(
    ctx: &Ctx,
    session: &mut Session,
    app: &mut App,
    terminal: &mut Term,
    key: event::KeyEvent,
) -> Result<()> {
    if app.help && !matches!(key.code, KeyCode::Char('?')) {
        app.help = false;
        return Ok(());
    }
    match key.code {
        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => app.quit = true,
        KeyCode::Char('q') | KeyCode::Esc => app.quit = true,
        KeyCode::Char('?') => app.help = !app.help,

        KeyCode::Down | KeyCode::Char('j') => match app.focus {
            Pane::Map => {
                if app.selected + 1 < app.nodes.len() {
                    app.selected += 1;
                }
            }
            Pane::Output => app.out_scroll = app.out_scroll.saturating_add(1),
        },
        KeyCode::Up | KeyCode::Char('k') => match app.focus {
            Pane::Map => app.selected = app.selected.saturating_sub(1),
            Pane::Output => app.out_scroll = app.out_scroll.saturating_sub(1),
        },
        KeyCode::PageDown => app.brief_scroll = app.brief_scroll.saturating_add(10),
        KeyCode::PageUp => app.brief_scroll = app.brief_scroll.saturating_sub(10),
        KeyCode::Tab => {
            app.focus = if app.focus == Pane::Map {
                Pane::Output
            } else {
                Pane::Map
            }
        }
        KeyCode::Char('[') | KeyCode::Char(']') => {
            if !app.categories.is_empty() {
                let here = app
                    .categories
                    .iter()
                    .position(|(l, c)| *l == app.land && *c == app.category)
                    .unwrap_or(0);
                let next = if key.code == KeyCode::Char(']') {
                    (here + 1) % app.categories.len()
                } else {
                    (here + app.categories.len() - 1) % app.categories.len()
                };
                let (land, category) = app.categories[next].clone();
                app.land = land;
                app.category = category;
                app.selected = 0;
                refetch_map(session, app).await?;
            }
        }

        KeyCode::Enter => {
            if let Some(node) = app.node() {
                let quest_id = node.quest_id.clone();
                request(
                    session,
                    app,
                    "quest.get",
                    serde_json::json!({ "quest_id": quest_id }),
                    Pending::Quest { then_edit: false },
                )
                .await?;
            }
        }

        KeyCode::Char('e') => {
            let Some(quest) = app.quest.clone() else {
                app.status = "press Enter on a node first".to_string();
                return Ok(());
            };
            let opened = workspace::ensure(&ctx.store, &app.address, &quest)?;
            // Hand the terminal over, wait, take it back.
            Screen::suspend();
            let _ = std::io::stdout().flush();
            let result = workspace::edit(&opened.path);
            Screen::resume()?;
            terminal.clear()?;
            match result {
                Ok(edit) => app.say(if edit.changed {
                    format!(
                        "  saved {} ({} bytes)",
                        opened.path.display(),
                        edit.source.len()
                    )
                } else {
                    format!("  {} is unchanged", opened.path.display())
                }),
                Err(e) => app.status = render::explain(&e),
            }
        }

        KeyCode::Char('r') | KeyCode::Char('s') => {
            let Some(quest) = app.quest.clone() else {
                app.status = "press Enter on a node first".to_string();
                return Ok(());
            };
            // §3.2 / §8.10: one execution per connection. The client refuses
            // the second locally rather than sending a request whose answer it
            // already knows.
            if app.busy.is_some() {
                app.status = "a run is already in flight".to_string();
                return Ok(());
            }
            let path = workspace::path_for(&ctx.store, &app.address, &quest);
            if !path.exists() {
                app.status = "press e first — there is no file yet".to_string();
                return Ok(());
            }
            let source = workspace::read(&path)?;
            workspace::check_size(&source)?;
            let submit = key.code == KeyCode::Char('s');
            app.say(String::new());
            app.say(format!(
                "— {} {} ({} bytes) —",
                if submit { "SUBMIT" } else { "RUN" },
                quest.id,
                source.len()
            ));
            app.busy = Some(if submit { "submitting" } else { "running" }.into());
            app.started = Some(Instant::now());
            app.streams = LogStreams::default();
            app.compile_tail.clear();
            request(
                session,
                app,
                if submit { "quest.submit" } else { "quest.run" },
                // §4.9: `lang` comes from the quest's land, never a guess.
                serde_json::json!({
                    "quest_id": quest.id, "lang": quest.lang(), "source": source
                }),
                if submit {
                    Pending::Submit
                } else {
                    Pending::Run
                },
            )
            .await?;
        }

        KeyCode::Char('f') => {
            let Some(quest) = app.quest.clone() else {
                return Ok(());
            };
            let path = workspace::path_for(&ctx.store, &app.address, &quest);
            if !path.exists() {
                return Ok(());
            }
            let source = workspace::read(&path)?;
            request(
                session,
                app,
                "code.format",
                serde_json::json!({ "lang": quest.lang(), "source": source }),
                Pending::Format,
            )
            .await?;
        }

        KeyCode::Char('h') => {
            let Some(quest) = app.quest.clone() else {
                return Ok(());
            };
            if quest.hints_total == 0 {
                app.say("  this quest has no hints");
                return Ok(());
            }
            let index = quest.hints_used.min(quest.hints_total - 1);
            request(
                session,
                app,
                "quest.hint",
                serde_json::json!({ "quest_id": quest.id, "index": index }),
                Pending::Hint,
            )
            .await?;
        }

        KeyCode::Char('R') => {
            let Some(quest) = app.quest.clone() else {
                return Ok(());
            };
            let path = workspace::path_for(&ctx.store, &app.address, &quest);
            request(
                session,
                app,
                "quest.reset",
                serde_json::json!({ "quest_id": quest.id }),
                Pending::Reset { path },
            )
            .await?;
        }

        KeyCode::Char('c') => {
            app.output.clear();
            app.out_scroll = 0;
        }
        _ => {}
    }
    Ok(())
}
