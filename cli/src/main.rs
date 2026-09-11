//! `cwbh` — the Causewaybay Hacker terminal client.
//!
//! The fourth implementation of `PROTOCOL.md`. Everything the client *does*
//! lives in the library beside this file; what is left here is what only a
//! terminal has: argv, a tty to prompt on without echo, `$EDITOR`, an exit
//! status, and the TUI.

mod cmd;
mod secret;
mod tui;

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

use causewaybay_hacker_cli::error::{Code, Error};
use causewaybay_hacker_cli::render::{self, Paint};

use cmd::Ctx;

#[derive(Parser)]
#[command(
    name = "cwbh",
    version,
    about = "Causewaybay Hacker — take your craft back from Skynet, from a terminal",
    long_about = "\
A 16-bit coding dojo, played from a shell.

  cwbh login              a mnemonic or a private key, read without echo
  cwbh maps               the lands, and how far through them you are
  cwbh map rust basic     one overworld
  cwbh quest <id>         the brief
  cwbh play <id>          edit -> run -> submit, the loop
  cwbh tui                the same thing with a map you can walk

Your source lives in ~/.causewaybayhackercli/work/<address>/ and stays yours.
Your key never leaves this process; the server only ever sees a signature."
)]
struct Cli {
    /// The server: ws://, wss://, http(s):// or a bare host:port.
    ///
    /// Precedence: --server > $CWBH_SERVER > the last one used > 127.0.0.1:5390
    #[arg(long, global = true, value_name = "URL")]
    server: Option<String>,

    /// The client's own store. Default ~/.causewaybayhackercli (or $CWBH_HOME).
    #[arg(long, global = true, value_name = "DIR")]
    home: Option<PathBuf>,

    /// Print every frame in both directions, with timings.
    #[arg(long, global = true)]
    trace: bool,

    /// Show the compile stream verbatim — rustc's JSON diagnostics, unrendered.
    #[arg(long, global = true)]
    raw: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Log in with a mnemonic or a private key. Never echoed, never in argv.
    Login {
        /// Read the phrase from stdin instead of prompting.
        #[arg(long)]
        stdin: bool,
        /// A display name, used only when the account is created.
        #[arg(long)]
        name: Option<String>,
        /// The BIP-44 address index. 0 is the identity (SPEC §3.1).
        #[arg(long, default_value_t = 0)]
        index: u32,
    },
    /// Forget the session token for this server. Your files stay.
    Logout,
    /// Who this client is logged in as.
    Whoami,
    /// The store, the server, the session and your editor.
    Doctor {
        /// Hold a connection open this many seconds and report whether the
        /// keepalive kept it (PROTOCOL §1.1, §8.12).
        #[arg(long, value_name = "SECONDS")]
        hold: Option<u64>,
    },

    /// The lands and categories, with progress.
    Maps,
    /// One overworld: its nodes, their state and their stars.
    Map {
        /// rust | go
        land: String,
        /// basic | advanced | hacker
        category: String,
    },
    /// Read a quest's brief.
    Quest {
        quest_id: String,
        /// Show the author's solution (only available once you have cleared it).
        #[arg(long)]
        solution: bool,
    },
    /// Take a hint. Costs stars, permanently.
    Hint {
        quest_id: String,
        /// 0-based. Defaults to the next one you have not taken.
        index: Option<i64>,
    },
    /// Put the starter back in your file. Progress and stars are untouched.
    Reset {
        quest_id: String,
        #[arg(long)]
        yes: bool,
    },

    /// Open your editor on the quest's file, creating it from the starter once.
    Edit {
        quest_id: String,
        /// Print the path and exit, for `vim "$(cwbh edit --path <id>)"`.
        #[arg(long = "path")]
        path_only: bool,
    },
    /// Run against the visible cases only. Never clears, never costs stars.
    Run {
        quest_id: String,
        /// Send this file instead of the one in your work directory.
        #[arg(long)]
        file: Option<PathBuf>,
    },
    /// The real thing: every case, hidden ones included.
    Submit {
        quest_id: String,
        #[arg(long)]
        file: Option<PathBuf>,
    },
    /// rustfmt or gofmt a file, in place.
    Fmt { file: PathBuf },
    /// edit -> run -> submit, in a loop, until it is cleared.
    Play { quest_id: String },

    /// Cleared, stars, attempts, accuracy, streak.
    Stats,
    /// What you keep getting wrong. The curriculum.
    Mistakes {
        #[arg(long, default_value_t = 10)]
        limit: i64,
        /// Include the kinds you have already learned.
        #[arg(long)]
        all: bool,
    },
    /// The shelf.
    Awards,
    /// Recent attempts, newest first.
    History {
        quest_id: Option<String>,
        #[arg(long, default_value_t = 20)]
        limit: i64,
    },
    /// Search the quests.
    Search {
        query: Vec<String>,
        #[arg(long, default_value_t = 20)]
        limit: i64,
    },
    /// Ask for a drill built from your mistakes.
    Drill {
        /// repeat | weakness | spaced
        #[arg(long, default_value = "weakness")]
        mode: String,
        #[arg(long)]
        land: Option<String>,
        #[arg(long, default_value_t = 5)]
        size: i64,
    },

    /// The scratchpad: run whatever you like, save it, nothing is scored.
    #[command(subcommand)]
    Pg(Playground),

    /// The full-screen client: a map you can walk, a quest pane, live output.
    Tui {
        /// Start on this land.
        #[arg(long, default_value = "rust")]
        land: String,
        /// Start on this category.
        #[arg(long, default_value = "basic")]
        category: String,
    },
}

/// PROTOCOL §4.9c. Five messages ship; two of them are in the contract.
#[derive(Subcommand)]
enum Playground {
    /// Compile and run a file. Nothing is recorded.
    Run {
        file: PathBuf,
        /// A file to feed the program on stdin.
        #[arg(long = "stdin-file")]
        stdin_file: Option<PathBuf>,
    },
    /// Save a file as a snippet, server-side.
    Save {
        file: PathBuf,
        /// Update this snippet instead of creating one.
        #[arg(long)]
        id: Option<String>,
        #[arg(long)]
        name: Option<String>,
    },
    /// The snippets this account has.
    List,
    /// Print a snippet, or write it to a file.
    Load {
        id: String,
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// Remove a snippet.
    Delete { id: String },
}

fn main() -> ExitCode {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(e) => {
            let _ = e.print();
            return match e.kind() {
                clap::error::ErrorKind::DisplayHelp
                | clap::error::ErrorKind::DisplayVersion
                | clap::error::ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand => {
                    ExitCode::SUCCESS
                }
                _ => ExitCode::from(2),
            };
        }
    };

    // A current-thread runtime: this client's whole job is one socket and one
    // person, and a thread pool for that would be furniture.
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(e) => {
            eprintln!("cannot start: {e}");
            return ExitCode::FAILURE;
        }
    };

    match runtime.block_on(run(cli)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            report(&e);
            ExitCode::from(e.code.exit_status())
        }
    }
}

async fn run(cli: Cli) -> causewaybay_hacker_cli::Result<()> {
    let ctx = Ctx::new(cli.home, cli.server, cli.trace, cli.raw)?;
    match cli.command {
        Command::Login { stdin, name, index } => cmd::auth::login(&ctx, stdin, name, index).await,
        Command::Logout => cmd::auth::logout(&ctx),
        Command::Whoami => cmd::auth::whoami(&ctx).await,
        Command::Doctor { hold } => cmd::auth::doctor(&ctx, hold).await,

        Command::Maps => cmd::world::maps(&ctx).await,
        Command::Map { land, category } => cmd::world::map(&ctx, &land, &category).await,
        Command::Quest { quest_id, solution } => cmd::world::quest(&ctx, &quest_id, solution).await,
        Command::Hint { quest_id, index } => cmd::world::hint(&ctx, &quest_id, index).await,
        Command::Reset { quest_id, yes } => cmd::world::reset(&ctx, &quest_id, yes).await,

        Command::Edit {
            quest_id,
            path_only,
        } => cmd::code::edit(&ctx, &quest_id, path_only).await,
        Command::Run { quest_id, file } => {
            // A failed run is not a failed command: the player asked what the
            // compiler thought and got an answer. Exit 0, and let the verdict
            // on stdout be the news.
            cmd::code::run(&ctx, &quest_id, file).await.map(|_| ())
        }
        Command::Submit { quest_id, file } => {
            cmd::code::submit(&ctx, &quest_id, file).await.map(|_| ())
        }
        Command::Fmt { file } => cmd::code::fmt(&ctx, &file).await,
        Command::Play { quest_id } => cmd::code::play(&ctx, &quest_id).await,

        Command::Stats => cmd::stats::summary(&ctx).await,
        Command::Mistakes { limit, all } => cmd::stats::mistakes(&ctx, limit, all).await,
        Command::Awards => cmd::stats::awards(&ctx).await,
        Command::History { quest_id, limit } => {
            cmd::stats::history(&ctx, quest_id.as_deref(), limit).await
        }
        Command::Search { query, limit } => cmd::world::search(&ctx, &query.join(" "), limit).await,
        Command::Drill { mode, land, size } => {
            cmd::world::drill(&ctx, &mode, land.as_deref(), size).await
        }

        Command::Pg(playground) => match playground {
            Playground::Run { file, stdin_file } => {
                cmd::playground::run(&ctx, &file, stdin_file.as_deref()).await
            }
            Playground::Save { file, id, name } => {
                cmd::playground::save(&ctx, &file, id, name).await
            }
            Playground::List => cmd::playground::list(&ctx).await,
            Playground::Load { id, out } => cmd::playground::load(&ctx, &id, out).await,
            Playground::Delete { id } => cmd::playground::delete(&ctx, &id).await,
        },

        Command::Tui { land, category } => tui::run(&ctx, &land, &category).await,
    }
}

/// §3.3: the player reads a sentence this client wrote from `code`; the
/// server's `message` is for a log, and is kept beside it rather than shown
/// instead of it.
fn report(error: &Error) {
    let paint = Paint::new();
    eprintln!();
    eprintln!("  {} {}", paint.red("✗"), render::explain(error));
    if !matches!(
        error.code,
        Code::Usage | Code::InvalidMnemonic | Code::InvalidPrivateKey | Code::Io
    ) {
        eprintln!(
            "  {}",
            paint.dim(&format!("[{}] {}", error.code.as_str(), error.message))
        );
    }
}
