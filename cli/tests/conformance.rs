//! PROTOCOL §8, checked against a mock server.
//!
//! §8 says *"`tests/smoke/` checks them against a running server; each
//! client's own suite should check its half."* This is this client's half —
//! the behaviours that are properties of the **client** and that a real server
//! will never exhibit on demand: a reply arriving out of order, an event type
//! that does not exist, a `server.bye`, a close with no goodbye at all, and a
//! keepalive firing while a request is still unanswered.
//!
//! The mock is a real websocket server on a loopback port, so the client under
//! test is the whole client: real frames, real tungstenite, real sockets.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;

use causewaybay_hacker_cli::client::Conn;
use causewaybay_hacker_cli::error::Code;
use causewaybay_hacker_cli::session::Session;
use causewaybay_hacker_cli::store::Store;

/// Every frame the client sent, in order, for a test to assert over.
type Sent = Arc<Mutex<Vec<serde_json::Value>>>;

/// Spin up a one-connection websocket server that runs `handler`.
///
/// `handler` gets the accepted stream and the shared record of what the client
/// sent. Returns the URL to point a `Conn` at.
async fn mock<F, Fut>(handler: F) -> (String, Sent)
where
    F: FnOnce(tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>, Sent) -> Fut
        + Send
        + 'static,
    Fut: std::future::Future<Output = ()> + Send,
{
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    let sent: Sent = Arc::new(Mutex::new(Vec::new()));
    let recorded = Arc::clone(&sent);
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let ws = tokio_tungstenite::accept_async(stream).await.unwrap();
        handler(ws, recorded).await;
    });
    (format!("ws://{addr}/ws"), sent)
}

/// Read one client frame, record it, and hand it back.
async fn take(
    ws: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
    sent: &Sent,
) -> serde_json::Value {
    loop {
        match ws.next().await {
            Some(Ok(Message::Text(text))) => {
                let value: serde_json::Value = serde_json::from_str(&text).unwrap();
                sent.lock().unwrap().push(value.clone());
                return value;
            }
            Some(Ok(_)) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

async fn say(
    ws: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
    frame: serde_json::Value,
) {
    ws.send(Message::Text(frame.to_string())).await.unwrap();
}

fn reply(id: &str, kind: &str, payload: serde_json::Value) -> serde_json::Value {
    serde_json::json!({ "v": 1, "id": id, "type": kind, "payload": payload })
}

fn event(kind: &str, payload: serde_json::Value) -> serde_json::Value {
    serde_json::json!({ "v": 1, "id": null, "type": kind, "payload": payload })
}

// ---------------------------------------------------------------------- §8.1

/// *"Every frame it sends has exactly `v`, `id`, `type`, `payload`, with
/// `payload` an object."*
#[tokio::test]
async fn every_frame_the_client_sends_has_exactly_four_keys() {
    let (url, sent) = mock(|mut ws, sent| async move {
        for _ in 0..3 {
            let frame = take(&mut ws, &sent).await;
            let id = frame["id"].as_str().unwrap().to_string();
            let kind = format!("{}.ok", frame["type"].as_str().unwrap());
            say(&mut ws, reply(&id, &kind, serde_json::json!({}))).await;
        }
    })
    .await;

    let mut conn = Conn::connect(&url).await.unwrap();
    conn.request("ping", serde_json::json!({})).await.unwrap();
    conn.request("world.lands", serde_json::json!({}))
        .await
        .unwrap();
    // A caller that hands over a non-object still produces a legal frame.
    conn.request("stats.summary", serde_json::Value::Null)
        .await
        .unwrap();

    let frames = sent.lock().unwrap().clone();
    assert_eq!(frames.len(), 3);
    for frame in &frames {
        let object = frame.as_object().unwrap();
        assert_eq!(object.len(), 4, "extra or missing key in {frame}");
        assert_eq!(object["v"], 1);
        assert!(object["id"].is_string());
        assert!(object["type"].is_string());
        assert!(object["payload"].is_object(), "payload must be an object");
    }
    // §2.2's convention, and unique for the life of the connection.
    let ids: Vec<&str> = frames.iter().map(|f| f["id"].as_str().unwrap()).collect();
    assert_eq!(ids, vec!["c-1", "c-2", "c-3"]);
}

// ---------------------------------------------------------------------- §8.2

/// *"It matches replies by `id` and tolerates out-of-order replies."*
///
/// Two requests in flight; the server answers the **second** first. A client
/// that reads until it sees its own id and throws away the rest passes nothing
/// here: the first answer it gets is not the one it is waiting for, and the
/// one it is waiting for arrives second.
#[tokio::test]
async fn replies_are_matched_by_id_and_may_arrive_in_any_order() {
    let (url, _sent) = mock(|mut ws, sent| async move {
        let first = take(&mut ws, &sent).await;
        let second = take(&mut ws, &sent).await;
        // Backwards, deliberately.
        say(
            &mut ws,
            reply(
                second["id"].as_str().unwrap(),
                "ping.ok",
                serde_json::json!({ "t": "second" }),
            ),
        )
        .await;
        say(
            &mut ws,
            reply(
                first["id"].as_str().unwrap(),
                "quest.get.ok",
                serde_json::json!({ "t": "first" }),
            ),
        )
        .await;
    })
    .await;

    let mut conn = Conn::connect(&url).await.unwrap();
    let slow = conn
        .send("quest.get", serde_json::json!({ "quest_id": "x" }))
        .await
        .unwrap();
    let quick = conn.send("ping", serde_json::json!({})).await.unwrap();

    // Ask for the slow one first. Its answer comes second on the wire.
    let slow_payload = conn.await_reply(&slow, &mut |_| {}).await.unwrap();
    assert_eq!(slow_payload["t"], "first");

    // The quick answer was stashed while we waited, not dropped.
    let quick_payload = conn.await_reply(&quick, &mut |_| {}).await.unwrap();
    assert_eq!(quick_payload["t"], "second");
    assert_eq!(conn.out_of_order, 1);
}

// ---------------------------------------------------------------------- §8.3

/// *"It ignores unknown `type` values without erroring or closing."*
#[tokio::test]
async fn an_unknown_type_is_ignored_rather_than_fatal() {
    let (url, _sent) = mock(|mut ws, sent| async move {
        let frame = take(&mut ws, &sent).await;
        // Three things a future server might send that this build has never
        // heard of: an event, a versioned frame, and an event with a payload
        // shaped nothing like anything in §5.
        say(
            &mut ws,
            event("weather.update", serde_json::json!({ "rain": true })),
        )
        .await;
        say(&mut ws, event("run.telemetry", serde_json::json!({}))).await;
        say(
            &mut ws,
            event(
                "award",
                serde_json::json!({ "kind": "haircut", "id": "x", "title": "T" }),
            ),
        )
        .await;
        say(
            &mut ws,
            reply(
                frame["id"].as_str().unwrap(),
                "ping.ok",
                serde_json::json!({ "t": "2026-09-11T04:12:33Z" }),
            ),
        )
        .await;
    })
    .await;

    let mut conn = Conn::connect(&url).await.unwrap();
    let mut seen: Vec<String> = Vec::new();
    let payload = conn
        .request_with("ping", serde_json::json!({}), &mut |frame| {
            seen.push(frame.kind.clone())
        })
        .await
        .unwrap();

    assert_eq!(payload["t"], "2026-09-11T04:12:33Z");
    assert_eq!(seen, vec!["weather.update", "run.telemetry", "award"]);
}

// ---------------------------------------------------------------------- §8.4

/// *"It handles every `code` in §3.3, and treats an unknown one as
/// `internal`."*
#[tokio::test]
async fn wire_errors_arrive_with_their_code_intact() {
    let (url, _sent) = mock(|mut ws, sent| async move {
        for (code, detail) in [
            ("busy", serde_json::json!({})),
            ("unavailable", serde_json::json!({ "milestone": 2 })),
            (
                "rate_limited",
                serde_json::json!({ "retry_after_ms": 1500 }),
            ),
            ("sunspots", serde_json::json!({})),
        ] {
            let frame = take(&mut ws, &sent).await;
            say(
                &mut ws,
                reply(
                    frame["id"].as_str().unwrap(),
                    "quest.submit.err",
                    serde_json::json!({ "code": code, "message": "log line", "detail": detail }),
                ),
            )
            .await;
        }
    })
    .await;

    let mut conn = Conn::connect(&url).await.unwrap();
    for want in [Code::Busy, Code::Unavailable, Code::RateLimited] {
        let error = conn
            .request("quest.submit", serde_json::json!({}))
            .await
            .unwrap_err();
        assert_eq!(error.code, want);
        assert!(!causewaybay_hacker_cli::render::explain(&error).is_empty());
    }
    let unknown = conn
        .request("quest.submit", serde_json::json!({}))
        .await
        .unwrap_err();
    assert_eq!(unknown.code, Code::Unknown("sunspots".into()));
    assert_eq!(unknown.code.effective(), &Code::Internal);
    // The sentence a player reads is exactly `internal`'s.
    assert_eq!(
        causewaybay_hacker_cli::render::explain(&unknown),
        causewaybay_hacker_cli::render::explain(&causewaybay_hacker_cli::error::Error::new(
            Code::Internal,
            "log line"
        ))
    );
}

// ---------------------------------------------------------------------- §8.5

/// *"It never sends a mnemonic or private key, in any field, ever."*
///
/// The whole login handshake, with every byte the client sent swept for the
/// phrase, the key, the seed and the words.
#[tokio::test]
async fn a_login_never_carries_key_material() {
    const PHRASE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const PRIVATE_KEY: &str = "1ab42cc412b618bdea3a599e3c9bae199ebf030895b039e9db1e30dafb12b727";
    const ADDRESS: &str = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94";
    let message = format!(
        "Causewaybay Hacker login\naddress: {ADDRESS}\nnonce: {}\nexpires: 2026-09-11T04:14:33Z",
        "3f1a".repeat(16)
    );
    let expected = message.clone();

    let (url, sent) = mock(move |mut ws, sent| async move {
        let challenge = take(&mut ws, &sent).await;
        say(
            &mut ws,
            reply(
                challenge["id"].as_str().unwrap(),
                "auth.challenge.ok",
                serde_json::json!({
                    "nonce": "3f1a".repeat(16),
                    "message": expected,
                    "expires_at": "2026-09-11T04:14:33Z"
                }),
            ),
        )
        .await;
        let login = take(&mut ws, &sent).await;
        say(
            &mut ws,
            reply(
                login["id"].as_str().unwrap(),
                "auth.login.ok",
                serde_json::json!({
                    "token": "a-token",
                    "user": { "address": ADDRESS, "name": "ferris",
                              "created_at": "", "last_seen_at": "",
                              "settings": {}, "level": 1, "xp": 0 }
                }),
            ),
        )
        .await;
    })
    .await;

    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(Some(&dir.path().join("home"))).unwrap();
    let key = causewaybay_hacker_cli::wallet::Keypair::from_mnemonic(PHRASE, 0, "").unwrap();
    let session = Session::login(&store, &url, &key, Some("ferris"), false)
        .await
        .unwrap();
    assert_eq!(session.user.address, ADDRESS);

    let frames = sent.lock().unwrap().clone();
    let wire = frames
        .iter()
        .map(|f| f.to_string())
        .collect::<Vec<_>>()
        .join("\n");
    for forbidden in [
        PHRASE,
        PRIVATE_KEY,
        "abandon abandon",
        // The BIP-39 seed and the chain code, in case a future refactor ever
        // decides one of them is "not really the key".
        &hex::encode(&causewaybay_hacker_cli::bip39::to_seed(PHRASE, "")[..]),
    ] {
        assert!(
            !wire.contains(forbidden),
            "key material reached the wire: {forbidden}"
        );
    }

    // §8.6: the signature is over the message the server sent, byte for byte.
    let signature = frames.iter().find(|f| f["type"] == "auth.login").unwrap()["payload"]
        ["signature"]
        .as_str()
        .unwrap()
        .to_string();
    let bytes = hex::decode(signature.trim_start_matches("0x")).unwrap();
    assert_eq!(bytes.len(), 65, "r || s || v");
    assert!(bytes[64] == 27 || bytes[64] == 28);
    assert_eq!(
        causewaybay_hacker_cli::wallet::recover_message(message.as_bytes(), &bytes).unwrap(),
        ADDRESS,
        "the signature must recover to the claimed address"
    );

    // And the store, which is the other place key material could leak to.
    let log = std::fs::read_to_string(store.log_path()).unwrap();
    assert!(!log.contains(PHRASE));
    assert!(!log.contains(PRIVATE_KEY));
    assert!(log.contains("a-token"));
}

// ---------------------------------------------------------------------- §8.7

/// *"It stores the token returned by `auth.resume`, not the one it sent."*
#[tokio::test]
async fn a_rotated_token_is_the_one_that_gets_stored() {
    let (url, sent) = mock(|mut ws, sent| async move {
        let frame = take(&mut ws, &sent).await;
        say(
            &mut ws,
            reply(
                frame["id"].as_str().unwrap(),
                "auth.resume.ok",
                serde_json::json!({
                    "token": "rotated-token",
                    "user": { "address": "0x9858EfFD232B4033E47d90003D41EC34EcaEda94",
                              "name": "ferris", "created_at": "", "last_seen_at": "",
                              "settings": {}, "level": 1, "xp": 0 }
                }),
            ),
        )
        .await;
    })
    .await;

    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(Some(&dir.path().join("home"))).unwrap();
    store
        .save_session(&causewaybay_hacker_cli::store::Session {
            server: url.clone(),
            token: "old-token".into(),
            address: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94".into(),
            name: "ferris".into(),
        })
        .unwrap();

    Session::resume(&store, &url, false).await.unwrap();

    assert_eq!(
        sent.lock().unwrap()[0]["payload"]["token"],
        "old-token",
        "the stored token is what goes out"
    );
    assert_eq!(
        store.load().unwrap().session(&url).unwrap().token,
        "rotated-token",
        "the returned token is what stays"
    );
}

/// §6.4: an `unauthorized` resume drops to the login screen and forgets the
/// token — as a record, not an edit (SPEC §1.1).
#[tokio::test]
async fn an_expired_token_is_forgotten() {
    let (url, _sent) = mock(|mut ws, sent| async move {
        let frame = take(&mut ws, &sent).await;
        say(
            &mut ws,
            reply(
                frame["id"].as_str().unwrap(),
                "auth.resume.err",
                serde_json::json!({ "code": "unauthorized", "message": "gone", "detail": {} }),
            ),
        )
        .await;
    })
    .await;

    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(Some(&dir.path().join("home"))).unwrap();
    store
        .save_session(&causewaybay_hacker_cli::store::Session {
            server: url.clone(),
            token: "stale".into(),
            address: "0x00".into(),
            name: String::new(),
        })
        .unwrap();

    let error = match Session::resume(&store, &url, false).await {
        Ok(_) => panic!("a stale token must not resume"),
        Err(e) => e,
    };
    assert_eq!(error.code, Code::Unauthorized);
    assert!(store.load().unwrap().session(&url).is_none());
    assert_eq!(
        std::fs::read_to_string(store.log_path())
            .unwrap()
            .lines()
            .count(),
        2,
        "the clear is appended, not edited in"
    );
}

// ---------------------------------------------------------------------- §8.8

/// *"It buffers `run.log` chunks rather than assuming line boundaries, and
/// notices a `seq` gap."*
#[tokio::test]
async fn run_log_chunks_are_buffered_and_a_gap_is_noticed() {
    let (url, _sent) = mock(|mut ws, sent| async move {
        let frame = take(&mut ws, &sent).await;
        let id = frame["id"].as_str().unwrap().to_string();
        // A line split across three chunks, then a hole at seq 3.
        for (seq, chunk) in [
            (0, "error[E03"),
            (1, "82]: borrow of "),
            (2, "moved value\n"),
        ] {
            say(
                &mut ws,
                event(
                    "run.log",
                    serde_json::json!({ "attempt_id": "att_1", "stream": "compile",
                                        "chunk": chunk, "seq": seq }),
                ),
            )
            .await;
        }
        say(
            &mut ws,
            event(
                "run.log",
                serde_json::json!({ "attempt_id": "att_1", "stream": "compile",
                                    "chunk": "  --> main.rs:4:20\n", "seq": 4 }),
            ),
        )
        .await;
        say(
            &mut ws,
            reply(&id, "quest.submit.ok", serde_json::json!({ "done": true })),
        )
        .await;
    })
    .await;

    let mut conn = Conn::connect(&url).await.unwrap();
    let mut streams = causewaybay_hacker_cli::client::LogStreams::default();
    let mut text = String::new();
    conn.request_with("quest.submit", serde_json::json!({}), &mut |frame| {
        if frame.kind == "run.log" {
            let log: causewaybay_hacker_cli::proto::RunLog =
                serde_json::from_value(frame.payload.clone()).unwrap();
            streams.accept(&log.attempt_id, &log.stream, log.seq, &log.chunk);
            text.push_str(&log.chunk);
        }
    })
    .await
    .unwrap();

    assert_eq!(
        text,
        "error[E0382]: borrow of moved value\n  --> main.rs:4:20\n"
    );
    assert_eq!(streams.gaps.len(), 1, "the hole at seq 3 was noticed");
    assert!(streams.gaps[0].contains("expected seq 3"));
}

// ---------------------------------------------------------------------- §8.9

/// *"It reconnects with backoff and resumes with the token, refetching the
/// map."*
///
/// The server here is not listening when the client first tries. The client
/// backs off, the port opens, and the resume that follows uses the stored
/// token — the whole of §6 steps 2 and 3.
#[tokio::test]
async fn a_client_backs_off_and_then_resumes() {
    // Claim a port, then let go of it, so the client's first attempt is
    // refused by something that is genuinely not there yet.
    let scout = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = scout.local_addr().unwrap();
    drop(scout);
    let url = format!("ws://{addr}/ws");

    let later = url.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(700)).await;
        let listener = TcpListener::bind(addr).await.unwrap();
        let (stream, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
        let sent: Sent = Arc::new(Mutex::new(Vec::new()));
        let frame = take(&mut ws, &sent).await;
        assert_eq!(frame["type"], "auth.resume");
        assert_eq!(frame["payload"]["token"], "stored");
        say(
            &mut ws,
            reply(
                frame["id"].as_str().unwrap(),
                "auth.resume.ok",
                serde_json::json!({
                    "token": "fresh",
                    "user": { "address": "0x00", "name": "n", "created_at": "",
                              "last_seen_at": "", "settings": {}, "level": 1, "xp": 0 }
                }),
            ),
        )
        .await;
        let _ = later;
        // Hold the connection open long enough for the client to read.
        tokio::time::sleep(Duration::from_millis(200)).await;
    });

    let mut retries = 0u32;
    let conn = Conn::connect_with_backoff(&url, Some(10), |_, _| retries += 1)
        .await
        .unwrap();
    assert!(retries >= 1, "it should have had to wait for the port");

    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(Some(&dir.path().join("home"))).unwrap();
    let session = Session::resume_on(conn, &store, &url, "stored")
        .await
        .unwrap();
    assert_eq!(session.user.name, "n");
    assert_eq!(store.load().unwrap().session(&url).unwrap().token, "fresh");
}

// --------------------------------------------------------------------- §8.11

/// *"It survives a `server.bye` followed by a close, and a close without
/// one."*
#[tokio::test]
async fn a_goodbye_then_a_close_is_survived() {
    let (url, _sent) = mock(|mut ws, sent| async move {
        let _ = take(&mut ws, &sent).await;
        say(
            &mut ws,
            event("server.bye", serde_json::json!({ "reason": "shutdown" })),
        )
        .await;
        ws.close(None).await.unwrap();
    })
    .await;

    let mut conn = Conn::connect(&url).await.unwrap();
    let mut byes: Vec<String> = Vec::new();
    let error = conn
        .request_with("world.lands", serde_json::json!({}), &mut |frame| {
            if frame.kind == "server.bye" {
                byes.push(
                    frame.payload["reason"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string(),
                );
            }
        })
        .await
        .unwrap_err();

    assert_eq!(byes, vec!["shutdown"], "the goodbye reached the caller");
    assert_eq!(error.code, Code::Disconnected);
    // §1.2 / §3.3: a close is never an application error, and it must not be
    // reported as one.
    assert_ne!(error.code, Code::Internal);
}

/// The other half: the socket simply goes away. No goodbye, no close frame.
#[tokio::test]
async fn a_close_with_no_goodbye_is_survived() {
    let (url, _sent) = mock(|mut ws, sent| async move {
        let _ = take(&mut ws, &sent).await;
        drop(ws);
    })
    .await;

    let mut conn = Conn::connect(&url).await.unwrap();
    let error = conn
        .request("world.lands", serde_json::json!({}))
        .await
        .unwrap_err();
    assert_eq!(error.code, Code::Disconnected);
    assert!(!causewaybay_hacker_cli::render::explain(&error).is_empty());
}

// --------------------------------------------------------------------- §8.12

/// *"It sends `ping` every 20 s if it does not answer websocket pings."*
///
/// The interval is turned down so the behaviour can be watched rather than
/// waited out. What is asserted is the shape of it: pings go out *while a
/// request is still unanswered*, they carry their own unique ids, and their
/// replies do not disturb the reply the caller is waiting for — which is also
/// §2.2's own example of an out-of-order reply, observed rather than assumed.
#[tokio::test]
async fn the_keepalive_fires_while_a_submit_is_still_running() {
    let (url, sent) = mock(|mut ws, sent| async move {
        let submit = take(&mut ws, &sent).await;
        let submit_id = submit["id"].as_str().unwrap().to_string();
        assert_eq!(submit["type"], "quest.submit");

        // Answer three pings before the submit, the way a real server would.
        for _ in 0..3 {
            let ping = take(&mut ws, &sent).await;
            assert_eq!(ping["type"], "ping");
            say(
                &mut ws,
                reply(
                    ping["id"].as_str().unwrap(),
                    "ping.ok",
                    serde_json::json!({ "t": "2026-09-11T04:12:33Z" }),
                ),
            )
            .await;
        }
        say(
            &mut ws,
            reply(
                &submit_id,
                "quest.submit.ok",
                serde_json::json!({ "done": true }),
            ),
        )
        .await;
    })
    .await;

    let mut conn = Conn::connect(&url).await.unwrap();
    conn.keepalive = Duration::from_millis(60);
    let payload = conn
        .request("quest.submit", serde_json::json!({ "quest_id": "x" }))
        .await
        .unwrap();
    assert_eq!(payload["done"], true);

    let frames = sent.lock().unwrap().clone();
    let pings: Vec<&serde_json::Value> = frames.iter().filter(|f| f["type"] == "ping").collect();
    assert!(pings.len() >= 3, "the keepalive did not fire");

    // §2.2: "Reusing an `id` that is still in flight is `bad_request`."
    let ids: std::collections::HashSet<&str> =
        frames.iter().map(|f| f["id"].as_str().unwrap()).collect();
    assert_eq!(ids.len(), frames.len(), "an id was reused");

    // Three ping answers arrived while the submit was outstanding.
    assert!(conn.out_of_order >= 3);
}

/// §2.1: a frame whose `v` the client does not know is ignored rather than
/// treated as the reply — and the connection stays open long enough for the
/// real one.
#[tokio::test]
async fn a_frame_from_a_future_protocol_version_is_ignored() {
    let (url, _sent) = mock(|mut ws, sent| async move {
        let frame = take(&mut ws, &sent).await;
        let id = frame["id"].as_str().unwrap().to_string();
        say(
            &mut ws,
            serde_json::json!({ "v": 2, "id": id, "type": "ping.ok", "payload": { "t": "v2" } }),
        )
        .await;
        say(
            &mut ws,
            reply(&id, "ping.ok", serde_json::json!({ "t": "v1" })),
        )
        .await;
    })
    .await;

    let mut conn = Conn::connect(&url).await.unwrap();
    let payload = conn.request("ping", serde_json::json!({})).await.unwrap();
    assert_eq!(payload["t"], "v1");
}
