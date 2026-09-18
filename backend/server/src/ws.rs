//! One websocket connection (PROTOCOL §1, §2, §3).
//!
//! The socket is split and a **writer task owns the sink**. Handlers never
//! touch it; they push frames into a channel. That is what lets `run.stage`
//! and `run.log` stream out while `quest.submit` is still unanswered — a
//! handler holding the sink could not do it — and it is why replies may
//! arrive out of order, which §2.2 makes the client's problem to handle.

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc::unbounded_channel;

use cwbhacker_core::attempts::Mode;
use cwbhacker_core::error::{bad_request, rate_limited, Code, Error};
use cwbhacker_core::snapshot;

use crate::handlers::{self, Session};
use crate::limits::{self, ConnectionLimits};
use crate::playground;
use crate::proto::{self, send, Incoming, Out, Outgoing, ServerFrame, MAX_FRAME_BYTES};
use crate::state::Shared;
use crate::submit;

const PING_EVERY: Duration = Duration::from_secs(30);
const MISSED_PONGS_ALLOWED: usize = 2;

/// PROTOCOL §1.2.
const CLOSE_GOING_AWAY: u16 = 1001;
const CLOSE_UNSUPPORTED: u16 = 1003;
const CLOSE_TOO_LARGE: u16 = 1009;
const CLOSE_TRY_AGAIN_LATER: u16 = 1013;

/// One open socket, counted against `limits::MAX_CONNECTIONS` for exactly as
/// long as `connection` runs — a guard rather than a decrement at the end,
/// so a panic or an early return cannot leave the count high.
struct Seat(Shared);

impl Seat {
    fn take(state: &Shared) -> Option<Seat> {
        let before = state.connections.fetch_add(1, Ordering::AcqRel);
        if before >= limits::MAX_CONNECTIONS {
            state.connections.fetch_sub(1, Ordering::AcqRel);
            return None;
        }
        Some(Seat(state.clone()))
    }
}

impl Drop for Seat {
    fn drop(&mut self) {
        self.0.connections.fetch_sub(1, Ordering::AcqRel);
    }
}

/// Whether a browser at `origin` may open the socket on a server addressed
/// as `host` (PROTOCOL §1.3).
///
/// A browser does not apply the same-origin rule to a websocket open, so
/// without this any page the player visits could reach `ws://127.0.0.1:5390`
/// and, since login is open registration, run code on this machine. The rule
/// is the one the frontend's own derivation implies (`endpoint.ts`: the
/// socket is `location.host`):
///
///   * no `Origin` at all: allowed. The LÖVE client and `cwbh` are not
///     browsers and send none; a browser always sends one, so this is not a
///     way round the check.
///   * `Origin`'s authority equals the `Host` the request came in on:
///     allowed. That is the page the server itself served, at whatever
///     address it was reached on — loopback, a LAN IP, a tailnet IP.
///   * `Origin`'s host is loopback, on any port: allowed. That is the vite
///     dev server on 5291 talking to the game server on 5390.
///   * anything else, including `Origin: null`: refused.
pub fn origin_allowed(origin: Option<&str>, host: Option<&str>) -> bool {
    let Some(origin) = origin else { return true };
    let Some(authority) = origin
        .strip_prefix("http://")
        .or_else(|| origin.strip_prefix("https://"))
    else {
        return false;
    };
    let authority = authority
        .split('/')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    if authority.is_empty() {
        return false;
    }
    if let Some(host) = host {
        if authority == host.to_ascii_lowercase() {
            return true;
        }
    }
    let hostname = if let Some(rest) = authority.strip_prefix('[') {
        rest.split(']').next().unwrap_or("")
    } else {
        authority.split(':').next().unwrap_or("")
    };
    matches!(hostname, "127.0.0.1" | "localhost" | "::1")
}

pub async fn upgrade(
    ws: WebSocketUpgrade,
    headers: HeaderMap,
    State(state): State<Shared>,
) -> Response {
    let origin = headers.get(header::ORIGIN).and_then(|v| v.to_str().ok());
    let host = headers.get(header::HOST).and_then(|v| v.to_str().ok());
    if !origin_allowed(origin, host) {
        tracing::warn!(
            origin = origin.unwrap_or("-"),
            host = host.unwrap_or("-"),
            "websocket refused: foreign origin"
        );
        return (StatusCode::FORBIDDEN, "foreign origin").into_response();
    }
    ws.max_message_size(MAX_FRAME_BYTES)
        .max_frame_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| connection(socket, state))
}

async fn connection(mut socket: WebSocket, state: Shared) {
    let Some(_seat) = Seat::take(&state) else {
        tracing::warn!(
            limit = limits::MAX_CONNECTIONS,
            "websocket refused: too many open connections"
        );
        let _ = socket
            .send(Message::Close(Some(CloseFrame {
                code: CLOSE_TRY_AGAIN_LATER,
                reason: "too many connections".into(),
            })))
            .await;
        return;
    };
    let connection_id = state.next_connection_id();
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = unbounded_channel::<Outgoing>();
    let missed = Arc::new(AtomicUsize::new(0));

    let writer_missed = missed.clone();
    let writer = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(PING_EVERY);
        ticker.tick().await; // the first tick is immediate; skip it
        loop {
            tokio::select! {
                outgoing = rx.recv() => {
                    let Some(outgoing) = outgoing else { break };
                    match outgoing {
                        Outgoing::Frame(frame) => {
                            let text = match serde_json::to_string(&frame) {
                                Ok(text) => text,
                                Err(e) => {
                                    tracing::error!(error = %e, "could not serialize a frame");
                                    continue;
                                }
                            };
                            if sink.send(Message::Text(text.into())).await.is_err() {
                                break;
                            }
                        }
                        Outgoing::Close { code, reason } => {
                            let _ = sink
                                .send(Message::Close(Some(CloseFrame {
                                    code,
                                    reason: reason.into(),
                                })))
                                .await;
                            break;
                        }
                    }
                }
                _ = ticker.tick() => {
                    if writer_missed.fetch_add(1, Ordering::Relaxed) >= MISSED_PONGS_ALLOWED {
                        // Two pings with no answer: the peer is gone even if
                        // the socket has not noticed yet (§1.1).
                        let bye = ServerFrame::event(
                            "server.bye",
                            serde_json::json!({ "reason": "shutdown" }),
                        );
                        if let Ok(text) = serde_json::to_string(&bye) {
                            let _ = sink.send(Message::Text(text.into())).await;
                        }
                        let _ = sink
                            .send(Message::Close(Some(CloseFrame {
                                code: CLOSE_GOING_AWAY,
                                reason: "keepalive missed".into(),
                            })))
                            .await;
                        break;
                    }
                    if sink.send(Message::Ping(Vec::new().into())).await.is_err() {
                        break;
                    }
                }
            }
        }
    });

    let mut session = Session::default();
    // §3.2: one in-flight `quest.submit` per connection. Per connection, not
    // per user — the same wallet in two windows gets two slots.
    let in_flight = Arc::new(AtomicBool::new(false));
    // §2.2: reusing an `id` that is still in flight is `bad_request`.
    let live_ids: Arc<Mutex<HashSet<String>>> = Arc::new(Mutex::new(HashSet::new()));
    // What this connection is allowed to ask for, and how fast (`limits.rs`).
    let allowance = Arc::new(ConnectionLimits::default());

    while let Some(message) = stream.next().await {
        let message = match message {
            Ok(message) => message,
            Err(e) => {
                // §1.2: a frame over the 4 MiB cap is closed with 1009. The
                // library reports it as a read error, so the code has to be
                // put back on the way out.
                let text = e.to_string();
                if text.contains("Space limit exceeded") || text.contains("too long") {
                    let _ = tx.send(Outgoing::Close {
                        code: CLOSE_TOO_LARGE,
                        reason: "frame over the 4 MiB limit",
                    });
                } else {
                    tracing::debug!(error = %e, "websocket read failed");
                }
                break;
            }
        };
        // §1.1: the server accepts *either* keepalive. A client whose
        // websocket library does not expose ping/pong sends the application
        // `ping` every 20 seconds instead, and a frame arriving is proof of
        // life whatever kind of frame it is. Counting only pongs would hang
        // up on the LÖVE client at ninety seconds.
        missed.store(0, Ordering::Relaxed);
        match message {
            Message::Text(text) => {
                dispatch(
                    &state,
                    connection_id,
                    &mut session,
                    &in_flight,
                    &live_ids,
                    &allowance,
                    &tx,
                    text.as_str(),
                )
                .await;
            }
            Message::Pong(_) => {}
            Message::Close(_) => break,
            Message::Binary(_) => {
                // §1: text frames only. A binary frame is closed with 1003
                // rather than answered, because there is no protocol to
                // answer it in.
                let _ = tx.send(Outgoing::Close {
                    code: CLOSE_UNSUPPORTED,
                    reason: "binary frames are not part of this protocol",
                });
                break;
            }
            Message::Ping(_) => {}
        }
    }

    if let Some(address) = session.address.as_deref() {
        state.hub.leave(address, connection_id);
        // The last chance to put this session's work in users/<address>/ (SPEC
        // §1.2). Login and a clear are the other two, and neither covers the
        // common shape of an evening: a run of failed submits on one quest and
        // then the window closes. A snapshot per attempt would be a few hundred
        // KB through the disk on every RUN; one per disconnect is one.
        //
        // Best-effort on purpose. The socket is already going away, and a
        // player whose disk is full should still get a clean close rather than
        // a panic in a teardown path nobody is reading.
        let conn = state.store.conn();
        if let Err(err) = snapshot::write(&conn, state.store.home(), address) {
            tracing::warn!(%address, %err, "could not write progress.json on close");
        }
    }
    send(
        &tx,
        ServerFrame::event("server.bye", serde_json::json!({ "reason": "shutdown" })),
    );
    drop(tx);
    let _ = writer.await;
}

#[allow(clippy::too_many_arguments)]
async fn dispatch(
    state: &Shared,
    connection_id: u64,
    session: &mut Session,
    in_flight: &Arc<AtomicBool>,
    live_ids: &Arc<Mutex<HashSet<String>>>,
    allowance: &Arc<ConnectionLimits>,
    tx: &Out,
    text: &str,
) {
    let frame = match proto::parse(text) {
        Incoming::Frame(frame) => frame,
        Incoming::NotAnObject => {
            let _ = tx.send(Outgoing::Close {
                code: CLOSE_UNSUPPORTED,
                reason: "every frame is one JSON object",
            });
            return;
        }
        Incoming::Malformed { id, kind, error } => {
            // Charged too. A frame the server could not understand is still a
            // frame it had to read and answer, and this arm is now reachable
            // in a loop: a 300-deep object is `bad_request` with the
            // connection open (§3.3) where it used to be a close, so without
            // a token it would be an unmetered reply at network speed.
            if charge(allowance, tx, &id, &kind) {
                send(tx, ServerFrame::err(id, &kind, &error));
            }
            return;
        }
    };
    let id = frame.id.clone();
    let kind = frame.kind.clone();

    // §3.3 `rate_limited`, before everything: before the version check, whose
    // answer is a reply like any other; before `live_ids`, so a refusal has
    // nothing to release; and before the ANONYMOUS gate, because an anonymous
    // socket asking for a hundred nonces is the case that needed a limit most.
    if !charge(allowance, tx, &id, &kind) {
        return;
    }

    if frame.v != proto::PROTOCOL_VERSION {
        // §2.1: answered, and the connection stays open, so a client can
        // discover it is too old and say so to the player.
        send(
            tx,
            ServerFrame::err(
                id,
                &kind,
                &Error::new(
                    Code::ProtoVersion,
                    format!("this server speaks protocol v{}", proto::PROTOCOL_VERSION),
                )
                .with_detail(serde_json::json!({ "supported": [proto::PROTOCOL_VERSION] })),
            ),
        );
        return;
    }

    if kind == "auth.challenge" {
        if let Err(retry_after_ms) = allowance.challenge() {
            // Each challenge mints a nonce that lives 120 seconds (SPEC §3.2).
            send(
                tx,
                ServerFrame::err(
                    id,
                    &kind,
                    &rate_limited("too many login challenges", retry_after_ms),
                ),
            );
            return;
        }
    }

    if let Some(id) = id.as_deref() {
        if !live_ids.lock().unwrap().insert(id.to_string()) {
            send(
                tx,
                ServerFrame::err(
                    Some(id.to_string()),
                    &kind,
                    &bad_request("that id is already in flight"),
                ),
            );
            return;
        }
    }

    // §3.1: exactly four messages are accepted before authenticating.
    const ANONYMOUS_OK: &[&str] = &["ping", "auth.challenge", "auth.login", "auth.resume"];
    if session.address.is_none() && !ANONYMOUS_OK.contains(&kind.as_str()) {
        release(live_ids, &id);
        send(
            tx,
            ServerFrame::err(id, &kind, &Error::new(Code::Unauthorized, "log in first")),
        );
        return;
    }

    // RUN and SUBMIT are the same path with a flag (PROTOCOL §4.9b), and they
    // share the one-execution-per-connection rule: a second of *either* while
    // one is in flight is `busy`.
    // The formatter runs a subprocess, so it does not belong on an async
    // worker — but it does not take the execution slot either: pressing FORMAT
    // while a submit compiles is a normal thing to do.
    if kind == "code.format" {
        // It skips the execution slot, so it needs a ceiling of its own or a
        // loop of it spawns `rustfmt` without bound.
        let Some(pass) = state.formatters.enter() else {
            release(live_ids, &id);
            send(
                tx,
                ServerFrame::err(
                    id,
                    "code.format",
                    &rate_limited("too many formatters running", limits::FORMAT_RETRY_MS),
                ),
            );
            return;
        };
        let tx = tx.clone();
        let live_ids = live_ids.clone();
        let payload = frame.payload.clone();
        tokio::spawn(async move {
            let result = tokio::task::spawn_blocking(move || handlers::code_format(&payload)).await;
            drop(pass);
            release(&live_ids, &id);
            send(
                &tx,
                match result {
                    Ok(Ok(payload)) => ServerFrame::ok(id, "code.format", payload),
                    Ok(Err(e)) => ServerFrame::err(id, "code.format", &e),
                    Err(e) => ServerFrame::err(
                        id,
                        "code.format",
                        &Error::new(Code::Internal, format!("the formatter panicked: {e}")),
                    ),
                },
            );
        });
        return;
    }

    if let Some(execution) = Execution::for_kind(&kind) {
        execute_async(
            state,
            connection_id,
            session,
            in_flight,
            live_ids,
            tx,
            id,
            execution,
            frame.payload,
        );
        return;
    }

    let payload = &frame.payload;
    let was_anonymous = session.address.is_none();
    let result = match kind.as_str() {
        "ping" => Ok(handlers::ping()),
        "auth.challenge" => handlers::auth_challenge(state, payload),
        "auth.login" => handlers::auth_login(state, session, payload),
        "auth.resume" => handlers::auth_resume(state, session, payload),
        "profile.update" => handlers::profile_update(state, session, payload),
        "world.lands" => handlers::world_lands(state, session),
        "world.map" => handlers::world_map(state, session, payload),
        "quest.get" => handlers::quest_get(state, session, payload),
        "quest.hint" => handlers::quest_hint(state, session, payload),
        "quest.solve" => handlers::quest_solve(state, session, payload),
        "quest.reset" => handlers::quest_reset(state, session, payload),
        // The edit stack (PROTOCOL §4.11c). None of the five compiles anything,
        // so they stay on this synchronous path beside `quest.hint`: each is a
        // handful of rows and at most one 256 KiB file, and putting them on the
        // execution slot would mean an UNDO answered `busy` while a submit runs.
        "edit.state" => handlers::edit_state(state, session, payload),
        "edit.push" => handlers::edit_push(state, session, payload),
        "edit.undo" => handlers::edit_undo(state, session, payload),
        "edit.redo" => handlers::edit_redo(state, session, payload),
        "edit.clear" => handlers::edit_clear(state, session, payload),
        "stats.summary" => handlers::stats_summary(state, session),
        "stats.mistakes" => handlers::stats_mistakes(state, session, payload),
        "stats.weakest" => handlers::stats_weakest(state, session, payload),
        "stats.history" => handlers::stats_history(state, session, payload),
        "stats.awards" => handlers::stats_awards(state, session),
        "interview.start" => handlers::interview_start(state, session, payload),
        "interview.approach" => handlers::interview_approach(state, session, payload),
        "interview.finish" => handlers::interview_finish(state, session, payload),
        "playground.list" => playground::list(state, session),
        "playground.load" => playground::load(state, session, payload),
        "playground.save" => playground::save(state, session, payload),
        "playground.delete" => playground::delete(state, session, payload),
        // The chatroom under a pad (§4.9f). A post carries at most a 3 MiB
        // photo, decoded and written in one short block; nothing here
        // compiles, so it stays beside the other snippet messages.
        "playground.chat.list" => playground::chat_list(state, session, payload),
        "playground.chat.sync" => playground::chat_sync(state, session, payload),
        "playground.chat.edit" => playground::chat_edit(state, session, payload),
        "playground.chat.delete" => playground::chat_delete(state, session, payload),
        "playground.chat.post" => playground::chat_post(state, session, payload),
        "playground.chat.clear" => playground::chat_clear(state, session, payload),
        "playground.chat.search" => playground::chat_search(state, session, payload),
        "search.query" => handlers::search_query(state, session, payload),
        "ai.plan" => handlers::ai_plan(state, session, payload),
        "ai.next" => handlers::ai_next(state, session, payload),
        "ai.finish" => handlers::ai_finish(state, session, payload),
        other => Err(Error::new(
            Code::NotFound,
            format!("no message type '{other}'"),
        )),
    };

    if was_anonymous {
        if let Some(address) = session.address.clone() {
            // Now that this connection has a user, it can hear about that
            // user's other windows (§4.19).
            state.hub.join(&address, connection_id, tx.clone());
        }
    }

    // §4.22, §4.23: a pad saved or its room changed on this connection is
    // told to the same user's other connections — the tablet and the laptop
    // with the same pad open — and not to this one, which has the reply.
    if let (Ok(payload), Some(address)) = (&result, session.address.as_deref()) {
        if let Some(event) = playground::fanout(&kind, payload) {
            state.hub.broadcast(address, connection_id, &event);
        }
    }

    release(live_ids, &id);
    send(
        tx,
        match result {
            Ok(payload) => ServerFrame::ok(id, &kind, payload),
            Err(e) => ServerFrame::err(id, &kind, &e),
        },
    );
}

/// Spend one of this connection's request tokens. `false` means the token was
/// not there and a correlated `rate_limited` has already gone out, so the
/// caller must answer nothing further.
///
/// **Every path that replies to a frame goes through this**, including the two
/// that reply before the frame is understood — a malformed envelope and an
/// unsupported `v`. They are answered rather than closed (§2.1, §3.3), so a
/// loop of them is a loop of replies, and a limit those two paths sit above is
/// not a limit.
fn charge(allowance: &ConnectionLimits, tx: &Out, id: &Option<String>, kind: &str) -> bool {
    match allowance.request() {
        Ok(()) => true,
        Err(retry_after_ms) => {
            send(
                tx,
                ServerFrame::err(
                    id.clone(),
                    kind,
                    &rate_limited("too many requests on this connection", retry_after_ms),
                ),
            );
            false
        }
    }
}

fn release(live_ids: &Arc<Mutex<HashSet<String>>>, id: &Option<String>) {
    if let Some(id) = id {
        live_ids.lock().unwrap().remove(id);
    }
}

/// The three things that compile and run. They share one slot per connection
/// (PROTOCOL §3.2): a second of *any* of them while one is in flight is
/// `busy`, because they share one compiler and one machine.
#[derive(Debug, Clone, Copy)]
enum Execution {
    Quest(Mode),
    Playground,
}

impl Execution {
    fn for_kind(kind: &str) -> Option<Execution> {
        match kind {
            "quest.submit" => Some(Execution::Quest(Mode::Submit)),
            "quest.run" => Some(Execution::Quest(Mode::Run)),
            "playground.run" => Some(Execution::Playground),
            _ => None,
        }
    }

    fn reply_kind(self) -> &'static str {
        match self {
            Execution::Quest(Mode::Submit) => "quest.submit",
            Execution::Quest(Mode::Run) => "quest.run",
            Execution::Playground => "playground.run",
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn execute_async(
    state: &Shared,
    connection_id: u64,
    session: &Session,
    in_flight: &Arc<AtomicBool>,
    live_ids: &Arc<Mutex<HashSet<String>>>,
    tx: &Out,
    id: Option<String>,
    execution: Execution,
    payload: serde_json::Value,
) {
    let reply_kind = execution.reply_kind();
    let address = match session.address.clone() {
        Some(address) => address,
        None => {
            release(live_ids, &id);
            send(
                tx,
                ServerFrame::err(
                    id,
                    reply_kind,
                    &Error::new(Code::Unauthorized, "log in first"),
                ),
            );
            return;
        }
    };
    if in_flight
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        release(live_ids, &id);
        send(
            tx,
            ServerFrame::err(
                id,
                reply_kind,
                &Error::new(Code::Busy, "one execution at a time on a connection"),
            ),
        );
        return;
    }

    // The per-connection slot is taken; now the global one. This order
    // matters: `busy` is the more specific answer and the one a client has a
    // button to disable, so a connection that is already compiling hears
    // `busy` rather than being told the whole server is loaded.
    let Some(pass) = state.executions.enter() else {
        // Give the slot straight back, or this connection can never run
        // anything again.
        in_flight.store(false, Ordering::SeqCst);
        release(live_ids, &id);
        send(
            tx,
            ServerFrame::err(
                id,
                reply_kind,
                &rate_limited(
                    "the server is compiling as much as it can at once",
                    limits::EXECUTION_RETRY_MS,
                ),
            ),
        );
        return;
    };

    let state = state.clone();
    let tx = tx.clone();
    let flag = in_flight.clone();
    let live_ids = live_ids.clone();
    tokio::spawn(async move {
        // The compiler blocks for seconds; it does not belong on an async
        // worker. The events still stream, because they go through the
        // channel the writer task owns.
        let result = {
            let tx = tx.clone();
            tokio::task::spawn_blocking(move || match execution {
                Execution::Quest(mode) => {
                    submit::run(&state, &address, connection_id, mode, &payload, &tx)
                }
                Execution::Playground => playground::run(&state, &address, &payload, &tx),
            })
            .await
        };
        drop(pass);
        flag.store(false, Ordering::SeqCst);
        release(&live_ids, &id);
        let frame = match result {
            Ok(Ok(payload)) => ServerFrame::ok(id, reply_kind, payload),
            Ok(Err(e)) => ServerFrame::err(id, reply_kind, &e),
            Err(e) => ServerFrame::err(
                id,
                reply_kind,
                &Error::new(Code::Internal, format!("the runner panicked: {e}")),
            ),
        };
        send(&tx, frame);
    });
}

#[cfg(test)]
mod origin_tests {
    use super::origin_allowed;

    #[test]
    fn no_origin_is_a_native_client() {
        assert!(origin_allowed(None, Some("127.0.0.1:5390")));
        assert!(origin_allowed(None, None));
    }

    #[test]
    fn the_page_the_server_served_is_allowed_at_any_address() {
        assert!(origin_allowed(
            Some("http://127.0.0.1:5390"),
            Some("127.0.0.1:5390")
        ));
        assert!(origin_allowed(
            Some("http://100.93.166.76:5390"),
            Some("100.93.166.76:5390")
        ));
        assert!(origin_allowed(
            Some("http://172.30.1.59:5390"),
            Some("172.30.1.59:5390")
        ));
        assert!(origin_allowed(
            Some("https://Dojo.Example:443"),
            Some("dojo.example:443")
        ));
        assert!(origin_allowed(
            Some("http://[fd7a::1]:5390"),
            Some("[fd7a::1]:5390")
        ));
    }

    #[test]
    fn the_dev_server_on_loopback_is_allowed_on_any_port() {
        assert!(origin_allowed(
            Some("http://127.0.0.1:5291"),
            Some("127.0.0.1:5390")
        ));
        assert!(origin_allowed(
            Some("http://localhost:5291"),
            Some("127.0.0.1:5390")
        ));
        assert!(origin_allowed(
            Some("http://[::1]:5291"),
            Some("127.0.0.1:5390")
        ));
    }

    #[test]
    fn a_foreign_page_is_refused() {
        assert!(!origin_allowed(
            Some("http://evil.example"),
            Some("127.0.0.1:5390")
        ));
        assert!(!origin_allowed(
            Some("https://evil.example"),
            Some("100.93.166.76:5390")
        ));
        assert!(!origin_allowed(
            Some("http://127.0.0.1.evil.example:5390"),
            Some("127.0.0.1:5390")
        ));
        assert!(!origin_allowed(
            Some("http://100.93.166.76:5390"),
            Some("172.30.1.59:5390")
        ));
        assert!(!origin_allowed(Some("null"), Some("127.0.0.1:5390")));
        assert!(!origin_allowed(Some(""), Some("127.0.0.1:5390")));
        assert!(!origin_allowed(Some("file://"), Some("127.0.0.1:5390")));
        assert!(!origin_allowed(Some("http://"), Some("127.0.0.1:5390")));
    }
}
