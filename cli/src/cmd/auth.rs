//! `login`, `logout`, `whoami`, `doctor`.

use causewaybay_hacker_cli::client::Conn;
use causewaybay_hacker_cli::error::Result;
use causewaybay_hacker_cli::server;
use causewaybay_hacker_cli::session::Session;
use causewaybay_hacker_cli::wallet::Keypair;
use causewaybay_hacker_cli::workspace;

use super::Ctx;
use crate::secret;

/// Read a mnemonic or a private key, derive, sign one challenge, and keep only
/// the token.
///
/// The phrase is read without echo (`secret::prompt`) or from a pipe. It lives
/// in a `Zeroizing<String>`, is turned into a `Keypair` that wipes itself on
/// drop, and both are gone before this function returns. What is written to
/// disk is the session token and the address — never the key.
pub async fn login(ctx: &Ctx, from_stdin: bool, name: Option<String>, index: u32) -> Result<()> {
    let paint = &ctx.paint;
    println!(
        "  {} {}",
        paint.dim("server"),
        paint.bold(&server::short(&ctx.server))
    );

    let phrase = if from_stdin {
        secret::from_stdin()?
    } else {
        eprintln!(
            "  {}",
            paint.dim("a 12-24 word mnemonic, or 0x + 64 hex. It is not echoed and never leaves this process.")
        );
        secret::prompt("  key")?
    };

    let key = Keypair::from_secret(&phrase, index)?;
    // The phrase has done its work; drop it before the network is touched, so
    // there is no window in which a panic mid-handshake could dump it.
    drop(phrase);

    let address = key.address();
    println!("  {} {}", paint.dim("address"), paint.bold(&address));
    if index != 0 {
        println!(
            "  {}",
            paint.dim(&format!("derivation m/44'/60'/0'/0/{index}"))
        );
    }

    let session = Session::login(&ctx.store, &ctx.server, &key, name.as_deref(), ctx.trace).await?;
    drop(key);

    println!();
    println!(
        "  {} {} {}",
        paint.green("logged in as"),
        paint.bold(&session.user.name),
        paint.dim(&format!(
            "level {}  {} xp",
            session.user.level, session.user.xp
        ))
    );
    println!(
        "  {}",
        paint.dim(&format!(
            "the session token is in {}; the key is not.",
            ctx.store.log_path().display()
        ))
    );
    Ok(())
}

/// SPEC §1.1: forgetting a session is a record, not an edit.
///
/// It also moves the *default* server off the one being forgotten, when that
/// is where it was pointing. `cwbh --server other login` makes `other` the
/// default; without this, logging out of it leaves every later command aimed
/// at a server the player has just left, answering `unauthorized` for a reason
/// they cannot see — which is the failure SPEC §1.1 warns about, arrived at
/// from the other direction.
pub fn logout(ctx: &Ctx) -> Result<()> {
    let state = ctx.store.load()?;
    match state.session(&ctx.server) {
        Some(session) => {
            ctx.store.clear_session(&ctx.server)?;
            println!(
                "  forgot the session for {} ({})",
                server::short(&ctx.server),
                session.address
            );
            if state.server.as_deref() == Some(ctx.server.as_str()) {
                let next = state
                    .sessions
                    .keys()
                    .find(|url| *url != &ctx.server)
                    .cloned()
                    .unwrap_or_else(|| server::DEFAULT.to_string());
                ctx.store.set_server(&next)?;
                println!(
                    "  {}",
                    ctx.paint
                        .dim(&format!("pointing at {} from now on", server::short(&next)))
                );
            }
            println!(
                "  {}",
                ctx.paint
                    .dim("your quest files are untouched — they are yours.")
            );
        }
        None => println!("  no session for {}", server::short(&ctx.server)),
    }
    Ok(())
}

pub async fn whoami(ctx: &Ctx) -> Result<()> {
    let mut session = ctx.session().await?;
    let paint = &ctx.paint;
    let user = &session.user;
    println!("  {}  {}", paint.bold(&user.name), paint.dim(&user.address));
    println!(
        "  level {}   {} xp   {}",
        user.level,
        user.xp,
        paint.dim(&format!("since {}", user.created_at))
    );
    println!("  {} {}", paint.dim("server"), server::short(&ctx.server));
    println!(
        "  {} {}",
        paint.dim("files"),
        ctx.store.work_dir(&user.address).display()
    );
    session.close().await;
    Ok(())
}

/// Everything a confused player would otherwise have to ask about.
///
/// `hold` keeps an authenticated connection open for that many seconds and
/// then says what happened to it. It exists because §1.1 and §8.12 are about
/// a *quiet* connection — the server pings every 30 s and drops a connection
/// that misses two — and there is no other way to find out whether a client
/// survives an idle minute except to be idle for one.
pub async fn doctor(ctx: &Ctx, hold: Option<u64>) -> Result<()> {
    let paint = &ctx.paint;
    let state = ctx.store.load()?;

    println!("  {}", paint.bold("store"));
    println!("    home      {}", ctx.store.home().display());
    println!("    log       {}", ctx.store.log_path().display());
    let lines = std::fs::read_to_string(ctx.store.log_path())
        .map(|t| t.lines().count())
        .unwrap_or(0);
    println!("    records   {lines}");
    if state.skipped.is_empty() {
        println!("    replay    {}", paint.green("clean"));
    } else {
        println!(
            "    replay    {}",
            paint.yellow(&format!("{} line(s) skipped", state.skipped.len()))
        );
        for warning in &state.skipped {
            println!("              {warning}");
        }
    }

    println!();
    println!("  {}", paint.bold("server"));
    println!("    url       {}", ctx.server);
    println!(
        "    from      {}",
        if std::env::var(server::ENV).is_ok() {
            format!("{} (or --server)", server::ENV)
        } else if state.server.is_some() {
            "the store, or --server".to_string()
        } else {
            "the default".to_string()
        }
    );
    println!(
        "    precedence  --server  >  {}  >  stored  >  {}",
        server::ENV,
        server::DEFAULT
    );

    print!("    reachable ");
    let _ = std::io::Write::flush(&mut std::io::stdout());
    match Conn::connect(&ctx.server).await {
        Ok(mut conn) => {
            let started = std::time::Instant::now();
            match conn.request("ping", serde_json::json!({})).await {
                Ok(payload) => println!(
                    "{} {}",
                    paint.green("yes"),
                    paint.dim(&format!(
                        "ping {:.0}ms, server time {}",
                        started.elapsed().as_secs_f64() * 1000.0,
                        payload.get("t").and_then(|v| v.as_str()).unwrap_or("?")
                    ))
                ),
                Err(e) => println!("{} {}", paint.yellow("odd"), paint.dim(&e.message)),
            }
            conn.close().await;
        }
        Err(e) => println!("{} {}", paint.red("no"), paint.dim(&e.message)),
    }

    println!();
    println!("  {}", paint.bold("sessions"));
    if state.sessions.is_empty() {
        println!("    {}", paint.dim("none — run `cwbh login`"));
    }
    for (url, session) in &state.sessions {
        let here = if *url == ctx.server { "*" } else { " " };
        println!(
            "  {here} {}  {}  {}",
            paint.bold(&session.address),
            session.name,
            paint.dim(url)
        );
        // The token is never printed. Its length is enough to say it is there.
        println!(
            "      {}",
            paint.dim(&format!("token: present, {} chars", session.token.len()))
        );
    }

    println!();
    println!("  {}", paint.bold("editor"));
    let (program, args) = workspace::editor_command();
    println!(
        "    {}  {}",
        paint.bold(&program),
        paint.dim(&args.join(" "))
    );
    if std::env::var("VISUAL").is_err() && std::env::var("EDITOR").is_err() {
        println!(
            "    {}",
            paint.dim("neither $VISUAL nor $EDITOR is set; falling back to vi")
        );
    }

    if let Some(seconds) = hold {
        println!();
        println!("  {}", paint.bold("keepalive"));
        println!(
            "    {}",
            paint.dim(&format!(
                "holding an authenticated connection open for {seconds}s, doing nothing"
            ))
        );
        let mut session = ctx.session().await?;
        session.conn.keepalive = std::time::Duration::from_secs(20);
        let started = std::time::Instant::now();
        // Ask for something that will never be answered, so the wait is a real
        // idle wait and not a poll: the timeout below is what ends it.
        let id = session.conn.next_id();
        let outcome = tokio::time::timeout(
            std::time::Duration::from_secs(seconds),
            session.conn.await_reply(&id, &mut |_| {}),
        )
        .await;
        let held = started.elapsed().as_secs_f64();
        match outcome {
            // The timeout is the *success* case: nothing answered, and nothing
            // hung up either.
            Err(_) => println!(
                "    {} {}",
                paint.green(&format!("alive after {held:.0}s")),
                paint.dim(&format!(
                    "{} websocket ping(s) from the server, {} application ping(s) sent",
                    session.conn.ws_pings, session.conn.app_pings
                ))
            ),
            Ok(Err(e)) => println!(
                "    {} {}",
                paint.red(&format!("dropped after {held:.0}s")),
                paint.dim(&e.message)
            ),
            Ok(Ok(_)) => println!(
                "    {}",
                paint.yellow("something answered an id never sent")
            ),
        }
        session.close().await;
    }
    Ok(())
}
