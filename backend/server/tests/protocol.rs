//! PROTOCOL §1–§3: the transport rules, which are the half of the contract
//! that has nothing to do with the game.
//!
//! Two other clients are being written against this file — a browser and a
//! LÖVE desktop app — so "the frontend seems happy" is not evidence.

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

use cwbhacker_core::{content, eth, Store};

const PACK: &str = include_str!("../../core/tests/fixtures/rust_basic.toml");
const ALICE_KEY: &str = "4646464646464646464646464646464646464646464646464646464646464646";

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct Server {
    port: u16,
    handle: tokio::task::JoinHandle<()>,
    _tmp: tempfile::TempDir,
}

async fn start() -> Server {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), PACK).unwrap();

    let store = Arc::new(Store::open(&tmp.path().join("home")).unwrap());
    {
        let conn = store.conn();
        let report =
            content::import_dir(&conn, store.home(), &tmp.path().join("content-src")).unwrap();
        assert!(report.failures.is_empty(), "{:?}", report.failures);
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let config = cwbhacker_server::Config {
        bind: listener.local_addr().unwrap(),
        static_dir: None,
        art_dir: None,
    };
    let state = cwbhacker_server::build_state(store, &config);
    let app = cwbhacker_server::router(state);
    let handle = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    Server {
        port,
        handle,
        _tmp: tmp,
    }
}

async fn connect(port: u16) -> Socket {
    tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}/ws"))
        .await
        .unwrap()
        .0
}

async fn send(socket: &mut Socket, frame: Value) {
    socket.send(Message::text(frame.to_string())).await.unwrap();
}

async fn next(socket: &mut Socket) -> Message {
    tokio::time::timeout(std::time::Duration::from_secs(30), socket.next())
        .await
        .expect("the server answered")
        .expect("the socket stayed open")
        .expect("a readable frame")
}

async fn next_json(socket: &mut Socket) -> Value {
    loop {
        match next(socket).await {
            Message::Text(text) => return serde_json::from_str(&text).unwrap(),
            Message::Ping(_) | Message::Pong(_) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

fn signing_key() -> k256::ecdsa::SigningKey {
    k256::ecdsa::SigningKey::from_slice(&hex::decode(ALICE_KEY).unwrap()).unwrap()
}

async fn login(socket: &mut Socket) -> String {
    let key = signing_key();
    let address = eth::address_from_pubkey(key.verifying_key());
    send(
        socket,
        json!({ "v":1, "id":"a-1", "type":"auth.challenge", "payload": { "address": address } }),
    )
    .await;
    let challenge = next_json(socket).await;
    let message = challenge["payload"]["message"]
        .as_str()
        .unwrap()
        .to_string();
    let digest = eth::eip191_hash(&message);
    let (signature, recovery) = key.sign_prehash_recoverable(&digest).unwrap();
    let mut bytes = signature.to_bytes().to_vec();
    bytes.push(recovery.to_byte());
    send(
        socket,
        json!({ "v":1, "id":"a-2", "type":"auth.login",
                "payload": { "address": address, "signature": format!("0x{}", hex::encode(bytes)) } }),
    )
    .await;
    let login = next_json(socket).await;
    assert_eq!(login["type"].as_str(), Some("auth.login.ok"), "{login}");
    address
}

/// §2: exactly four top-level keys. A fifth is `bad_request` — the server does
/// not silently ignore fields, because a silently ignored field is how a
/// client ships a bug that looks like it works.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unknown_top_level_key_is_refused() {
    let server = start().await;
    let mut socket = connect(server.port).await;
    send(
        &mut socket,
        json!({ "v":1, "id":"c-1", "type":"ping", "payload":{}, "extra": true }),
    )
    .await;
    let reply = next_json(&mut socket).await;
    assert_eq!(reply["type"].as_str(), Some("ping.err"));
    assert_eq!(reply["payload"]["code"].as_str(), Some("bad_request"));
    assert_eq!(reply["id"].as_str(), Some("c-1"), "the error is correlated");

    // The connection survives it: an application error is never a close.
    send(
        &mut socket,
        json!({ "v":1, "id":"c-2", "type":"ping", "payload":{} }),
    )
    .await;
    assert_eq!(
        next_json(&mut socket).await["type"].as_str(),
        Some("ping.ok")
    );
    server.handle.abort();
}

/// §2: `payload` is always an object, never a bare value.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_payload_that_is_not_an_object_is_refused() {
    let server = start().await;
    let mut socket = connect(server.port).await;
    send(
        &mut socket,
        json!({ "v":1, "id":"c-1", "type":"ping", "payload": 7 }),
    )
    .await;
    let reply = next_json(&mut socket).await;
    assert_eq!(reply["payload"]["code"].as_str(), Some("bad_request"));
    server.handle.abort();
}

/// §1.2: a frame that is not a JSON object is a transport error, closed with
/// 1003 — not an `.err`, because there is no envelope to answer in.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_frame_that_is_not_an_object_closes_1003() {
    let server = start().await;
    let mut socket = connect(server.port).await;
    socket.send(Message::text("\"hello\"")).await.unwrap();
    match next(&mut socket).await {
        Message::Close(Some(frame)) => assert_eq!(u16::from(frame.code), 1003),
        other => panic!("expected a 1003 close, got {other:?}"),
    }
    server.handle.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_binary_frame_closes_1003() {
    let server = start().await;
    let mut socket = connect(server.port).await;
    socket
        .send(Message::Binary(vec![0, 1, 2].into()))
        .await
        .unwrap();
    match next(&mut socket).await {
        Message::Close(Some(frame)) => assert_eq!(u16::from(frame.code), 1003),
        other => panic!("expected a 1003 close, got {other:?}"),
    }
    server.handle.abort();
}

/// §2.2: reusing an `id` that is still in flight is `bad_request`. The submit
/// is the only request that takes long enough for it to matter, which is
/// exactly why it is the one a client will collide on.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn reusing_an_in_flight_id_is_refused() {
    let server = start().await;
    let mut socket = connect(server.port).await;
    login(&mut socket).await;
    send(
        &mut socket,
        json!({ "v":1, "id":"dup", "type":"quest.submit", "payload": {
            "quest_id": "rust.basic.01.hello", "lang": "rust",
            "source": "fn main() { println!(\"hello, causewaybay\"); }" } }),
    )
    .await;
    send(
        &mut socket,
        json!({ "v":1, "id":"dup", "type":"ping", "payload": {} }),
    )
    .await;

    let mut refused = false;
    let mut answered = false;
    while !(refused && answered) {
        let frame = next_json(&mut socket).await;
        match frame["type"].as_str() {
            Some("ping.err") => {
                assert_eq!(frame["payload"]["code"].as_str(), Some("bad_request"));
                refused = true;
            }
            Some("quest.submit.ok") => answered = true,
            _ => continue,
        }
    }
    server.handle.abort();
}

/// §1: 4 MiB inbound, and a frame above it closes with 1009.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_oversized_frame_closes_1009() {
    let server = start().await;
    let mut socket = connect(server.port).await;
    let huge = json!({ "v":1, "id":"c-1", "type":"ping",
                       "payload": { "pad": "x".repeat(5 * 1024 * 1024) } });
    // The send itself may fail once the peer has closed under us; either way
    // what matters is the close code that comes back.
    let _ = socket.send(Message::text(huge.to_string())).await;
    loop {
        match next(&mut socket).await {
            Message::Close(Some(frame)) => {
                assert_eq!(u16::from(frame.code), 1009, "{frame:?}");
                break;
            }
            Message::Close(None) => panic!("closed with no code"),
            _ => continue,
        }
    }
    server.handle.abort();
}

/// §3.1: a connection never changes user. Logging in twice on one socket would
/// leave it in the hub under the address it used to have.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_second_login_on_one_connection_is_refused() {
    let server = start().await;
    let mut socket = connect(server.port).await;
    login(&mut socket).await;
    let key = signing_key();
    let address = eth::address_from_pubkey(key.verifying_key());
    send(
        &mut socket,
        json!({ "v":1, "id":"c-9", "type":"auth.login",
                "payload": { "address": address, "signature": "0x00" } }),
    )
    .await;
    let reply = next_json(&mut socket).await;
    assert_eq!(
        reply["payload"]["code"].as_str(),
        Some("bad_request"),
        "{reply}"
    );
    server.handle.abort();
}

/// §4.19: `progress.update` also reaches the same user's other open
/// connections, which is how two windows stay in step.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_clear_reaches_the_users_other_window() {
    let server = start().await;
    let mut playing = connect(server.port).await;
    let mut watching = connect(server.port).await;
    login(&mut playing).await;
    login(&mut watching).await;

    send(
        &mut playing,
        json!({ "v":1, "id":"c-9", "type":"quest.submit", "payload": {
            "quest_id": "rust.basic.01.hello", "lang": "rust",
            "source": "fn main() { println!(\"hello, causewaybay\"); }" } }),
    )
    .await;

    // The other window hears about it without having asked for anything.
    let update = loop {
        let frame = next_json(&mut watching).await;
        if frame["type"] == "progress.update" {
            break frame;
        }
    };
    assert!(update["id"].is_null(), "an event is never correlated");
    assert_eq!(
        update["payload"]["quest_id"].as_str(),
        Some("rust.basic.01.hello")
    );
    assert_eq!(update["payload"]["unlocked"], json!(["rust.basic.02.sum"]));
    server.handle.abort();
}
