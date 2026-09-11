//! One websocket connection (SPEC §6.4).
//!
//! The socket is split and a **writer task owns the sink**. Handlers never
//! touch it; they push frames into an unbounded channel. That is what lets
//! `run.stage` and `run.log` stream out while `quest.submit` is still
//! unanswered — a handler holding the sink could not do it.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::response::Response;
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};

use cwbhacker_core::error::{bad_request, Code, Error};

use crate::handlers::{self, Session};
use crate::proto::{ClientFrame, ServerFrame, PROTOCOL_VERSION};
use crate::state::Shared;
use crate::submit;

const PING_EVERY: Duration = Duration::from_secs(30);
const MISSED_PONGS_ALLOWED: usize = 2;

pub async fn upgrade(ws: WebSocketUpgrade, State(state): State<Shared>) -> Response {
    ws.on_upgrade(move |socket| connection(socket, state))
}

async fn connection(socket: WebSocket, state: Shared) {
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = unbounded_channel::<ServerFrame>();
    let missed = Arc::new(AtomicUsize::new(0));

    let writer_missed = missed.clone();
    let writer = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(PING_EVERY);
        ticker.tick().await; // the first tick is immediate; skip it
        loop {
            tokio::select! {
                frame = rx.recv() => {
                    let Some(frame) = frame else { break };
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
                _ = ticker.tick() => {
                    if writer_missed.fetch_add(1, Ordering::Relaxed) >= MISSED_PONGS_ALLOWED {
                        // Two pings with no answer: the peer is gone even if
                        // the socket has not noticed yet.
                        let _ = sink.send(Message::Close(None)).await;
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
    // §6.4: one in-flight `quest.submit` per connection; a second is `busy`.
    let in_flight = Arc::new(AtomicBool::new(false));

    while let Some(message) = stream.next().await {
        let message = match message {
            Ok(message) => message,
            Err(e) => {
                tracing::debug!(error = %e, "websocket read failed");
                break;
            }
        };
        match message {
            Message::Text(text) => {
                dispatch(&state, &mut session, &in_flight, &tx, text.as_str()).await;
            }
            Message::Pong(_) => {
                missed.store(0, Ordering::Relaxed);
            }
            Message::Close(_) => break,
            Message::Binary(_) => {
                // §6: text frames, one JSON object each. Binary is not part of
                // the protocol, and guessing at it would be inventing one.
                let _ = tx.send(ServerFrame::err(
                    None,
                    "frame",
                    &bad_request("this protocol is text frames only"),
                ));
            }
            Message::Ping(_) => {}
        }
    }

    let _ = tx.send(ServerFrame::event(
        "server.bye",
        serde_json::json!({ "reason": "closed" }),
    ));
    drop(tx);
    let _ = writer.await;
}

async fn dispatch(
    state: &Shared,
    session: &mut Session,
    in_flight: &Arc<AtomicBool>,
    tx: &UnboundedSender<ServerFrame>,
    text: &str,
) {
    let frame: ClientFrame = match serde_json::from_str(text) {
        Ok(frame) => frame,
        Err(e) => {
            let _ = tx.send(ServerFrame::err(
                None,
                "frame",
                &bad_request(format!("not a protocol frame: {e}")),
            ));
            return;
        }
    };
    let id = frame.id.clone();
    let kind = frame.kind.clone();

    if let Some(v) = frame.v {
        if v != PROTOCOL_VERSION {
            // The connection stays open (§6.1) — an old client should be told
            // what is wrong, not hung up on.
            let _ = tx.send(ServerFrame::err(
                id,
                &kind,
                &Error::new(
                    Code::ProtoVersion,
                    format!("this server speaks protocol v{PROTOCOL_VERSION}"),
                ),
            ));
            return;
        }
    }

    // §6.4: anonymous connections may only ping and start logging in.
    const ANONYMOUS_OK: &[&str] = &["ping", "auth.challenge", "auth.login", "auth.resume"];
    if session.address.is_none() && !ANONYMOUS_OK.contains(&kind.as_str()) {
        let _ = tx.send(ServerFrame::err(
            id,
            &kind,
            &Error::new(Code::Unauthorized, "log in first"),
        ));
        return;
    }

    if kind == "quest.submit" {
        submit_async(state, session, in_flight, tx, id, frame.payload);
        return;
    }

    let payload = &frame.payload;
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

    let _ = tx.send(match result {
        Ok(payload) => ServerFrame::ok(id, &kind, payload),
        Err(e) => ServerFrame::err(id, &kind, &e),
    });
}

fn submit_async(
    state: &Shared,
    session: &Session,
    in_flight: &Arc<AtomicBool>,
    tx: &UnboundedSender<ServerFrame>,
    id: Option<String>,
    payload: serde_json::Value,
) {
    let address = match session.address.clone() {
        Some(address) => address,
        None => {
            let _ = tx.send(ServerFrame::err(
                id,
                "quest.submit",
                &Error::new(Code::Unauthorized, "log in first"),
            ));
            return;
        }
    };
    if in_flight
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        let _ = tx.send(ServerFrame::err(
            id,
            "quest.submit",
            &Error::new(Code::Busy, "one submission at a time"),
        ));
        return;
    }

    let state = state.clone();
    let tx = tx.clone();
    let flag = in_flight.clone();
    tokio::spawn(async move {
        // The compiler blocks for seconds; it does not belong on an async
        // worker. The events still stream out, because they go through the
        // channel the writer task owns.
        let result = {
            let tx = tx.clone();
            tokio::task::spawn_blocking(move || submit::run(&state, &address, &payload, &tx)).await
        };
        flag.store(false, Ordering::SeqCst);
        let frame = match result {
            Ok(Ok(payload)) => ServerFrame::ok(id, "quest.submit", payload),
            Ok(Err(e)) => ServerFrame::err(id, "quest.submit", &e),
            Err(e) => ServerFrame::err(
                id,
                "quest.submit",
                &Error::new(Code::Internal, format!("the runner panicked: {e}")),
            ),
        };
        let _ = tx.send(frame);
    });
}
