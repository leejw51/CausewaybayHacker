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
use axum::response::Response;
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc::unbounded_channel;

use cwbhacker_core::error::{bad_request, Code, Error};

use crate::handlers::{self, Session};
use crate::proto::{self, send, Incoming, Out, Outgoing, ServerFrame, MAX_FRAME_BYTES};
use crate::state::Shared;
use crate::submit;

const PING_EVERY: Duration = Duration::from_secs(30);
const MISSED_PONGS_ALLOWED: usize = 2;

/// PROTOCOL §1.2.
const CLOSE_GOING_AWAY: u16 = 1001;
const CLOSE_UNSUPPORTED: u16 = 1003;
const CLOSE_TOO_LARGE: u16 = 1009;

pub async fn upgrade(ws: WebSocketUpgrade, State(state): State<Shared>) -> Response {
    ws.max_message_size(MAX_FRAME_BYTES)
        .max_frame_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| connection(socket, state))
}

async fn connection(socket: WebSocket, state: Shared) {
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
            send(tx, ServerFrame::err(id, &kind, &error));
            return;
        }
    };
    let id = frame.id.clone();
    let kind = frame.kind.clone();

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

    if kind == "quest.submit" {
        submit_async(
            state,
            connection_id,
            session,
            in_flight,
            live_ids,
            tx,
            id,
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
        "quest.reset" => handlers::quest_reset(state, session, payload),
        "stats.summary" => handlers::stats_summary(state, session),
        "stats.mistakes" => handlers::stats_mistakes(state, session, payload),
        "stats.history" => handlers::stats_history(state, session, payload),
        "search.query" => Err(handlers::unimplemented("search (SPEC §8)")),
        "ai.plan" | "ai.next" | "ai.finish" => {
            Err(handlers::unimplemented("AI drills (SPEC §7.3)"))
        }
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

    release(live_ids, &id);
    send(
        tx,
        match result {
            Ok(payload) => ServerFrame::ok(id, &kind, payload),
            Err(e) => ServerFrame::err(id, &kind, &e),
        },
    );
}

fn release(live_ids: &Arc<Mutex<HashSet<String>>>, id: &Option<String>) {
    if let Some(id) = id {
        live_ids.lock().unwrap().remove(id);
    }
}

#[allow(clippy::too_many_arguments)]
fn submit_async(
    state: &Shared,
    connection_id: u64,
    session: &Session,
    in_flight: &Arc<AtomicBool>,
    live_ids: &Arc<Mutex<HashSet<String>>>,
    tx: &Out,
    id: Option<String>,
    payload: serde_json::Value,
) {
    let address = match session.address.clone() {
        Some(address) => address,
        None => {
            release(live_ids, &id);
            send(
                tx,
                ServerFrame::err(
                    id,
                    "quest.submit",
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
                "quest.submit",
                &Error::new(Code::Busy, "one submission at a time"),
            ),
        );
        return;
    }

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
            tokio::task::spawn_blocking(move || {
                submit::run(&state, &address, connection_id, &payload, &tx)
            })
            .await
        };
        flag.store(false, Ordering::SeqCst);
        release(&live_ids, &id);
        let frame = match result {
            Ok(Ok(payload)) => ServerFrame::ok(id, "quest.submit", payload),
            Ok(Err(e)) => ServerFrame::err(id, "quest.submit", &e),
            Err(e) => ServerFrame::err(
                id,
                "quest.submit",
                &Error::new(Code::Internal, format!("the runner panicked: {e}")),
            ),
        };
        send(&tx, frame);
    });
}
