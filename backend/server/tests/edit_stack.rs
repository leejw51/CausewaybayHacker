//! The five `edit.*` messages over the real socket (PROTOCOL §4.11c).
//!
//! Handler-level tests cannot prove a router arm exists: `ws.rs` answers an
//! unknown `type` with `not_found`, which is the same code an unknown
//! `quest_id` gets, so a missing arm and a working one are indistinguishable
//! from outside unless something actually goes down the wire. Every message
//! here therefore goes through a websocket to a server on a real port.
//!
//! The stack's own behaviour — the cap, the redo tail, content addressing —
//! belongs to `core/tests/edits.rs`; what is proved here is that the wire
//! carries it, that it is scoped to the logged-in player, and that it outlives
//! the connection.

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

use cwbhacker_core::{content, eth, Store};

const PACK: &str = include_str!("../../core/tests/fixtures/rust_basic.toml");
/// The published test keys this repo's EIP-191 vectors use; they guard
/// nothing.
const ALICE_KEY: &str = "4646464646464646464646464646464646464646464646464646464646464646";
const BOB_KEY: &str = "1111111111111111111111111111111111111111111111111111111111111111";
const HELLO: &str = "rust.basic.01.hello";
const SUM: &str = "rust.basic.02.sum";

struct Client {
    socket: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    next_id: u32,
}

impl Client {
    async fn connect(port: u16) -> Client {
        let (socket, _) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}/ws"))
            .await
            .expect("the websocket accepts a connection");
        Client { socket, next_id: 0 }
    }

    async fn call(&mut self, kind: &str, payload: Value) -> Value {
        self.next_id += 1;
        let id = format!("c-{}", self.next_id);
        let frame = json!({ "v": 1, "id": id, "type": kind, "payload": payload });
        self.socket
            .send(Message::text(frame.to_string()))
            .await
            .expect("send");
        loop {
            let message =
                tokio::time::timeout(std::time::Duration::from_secs(30), self.socket.next())
                    .await
                    .expect("the server answered")
                    .expect("the socket stayed open")
                    .expect("a readable frame");
            let text = match message {
                Message::Text(text) => text,
                Message::Ping(_) | Message::Pong(_) => continue,
                other => panic!("unexpected frame: {other:?}"),
            };
            let value: Value = serde_json::from_str(&text).expect("a JSON frame");
            if value["id"].as_str() == Some(id.as_str()) {
                return value;
            }
        }
    }

    async fn ok(&mut self, kind: &str, payload: Value) -> Value {
        let frame = self.call(kind, payload).await;
        assert_eq!(
            frame["type"].as_str(),
            Some(format!("{kind}.ok").as_str()),
            "expected {kind}.ok, got {frame}"
        );
        frame["payload"].clone()
    }

    async fn err(&mut self, kind: &str, payload: Value) -> String {
        let frame = self.call(kind, payload).await;
        assert_eq!(
            frame["type"].as_str(),
            Some(format!("{kind}.err").as_str()),
            "expected {kind}.err, got {frame}"
        );
        frame["payload"]["code"].as_str().unwrap().to_string()
    }

    async fn login(&mut self, key_hex: &str) -> String {
        let key = k256::ecdsa::SigningKey::from_slice(&hex::decode(key_hex).unwrap()).unwrap();
        let address = eth::address_from_pubkey(key.verifying_key());
        let challenge = self
            .ok("auth.challenge", json!({ "address": address }))
            .await;
        let message = challenge["message"].as_str().unwrap().to_string();
        let digest = eth::eip191_hash(&message);
        let (signature, recovery) = key.sign_prehash_recoverable(&digest).unwrap();
        let mut bytes = signature.to_bytes().to_vec();
        bytes.push(recovery.to_byte());
        self.ok(
            "auth.login",
            json!({ "address": address, "signature": format!("0x{}", hex::encode(bytes)) }),
        )
        .await;
        address
    }
}

async fn start(home: &std::path::Path, content_src: &std::path::Path) -> u16 {
    let store = Arc::new(Store::open(home).expect("store"));
    {
        let conn = store.conn();
        let report = content::import_dir(&conn, store.home(), content_src).expect("import");
        assert!(report.failures.is_empty(), "{:?}", report.failures);
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let config = cwbhacker_server::Config {
        bind: listener.local_addr().unwrap(),
        static_dir: None,
        art_dir: None,
    };
    let app = cwbhacker_server::router(cwbhacker_server::build_state(store, &config));
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    port
}

fn content_src(root: &std::path::Path) -> std::path::PathBuf {
    let dir = root.join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), PACK).unwrap();
    root.join("content-src")
}

/// The six fields of `EditState`, checked as a group — a client renders all of
/// them, so a reply that got one wrong is a reply that draws the wrong buttons.
#[track_caller]
fn assert_state(state: &Value, quest_id: &str, source: Option<&str>, cursor: i64, depth: i64) {
    assert_eq!(state["quest_id"].as_str(), Some(quest_id), "{state}");
    match source {
        Some(text) => assert_eq!(state["source"].as_str(), Some(text), "{state}"),
        None => assert!(state["source"].is_null(), "{state}"),
    }
    assert_eq!(state["cursor"].as_i64(), Some(cursor), "{state}");
    assert_eq!(state["depth"].as_i64(), Some(depth), "{state}");
    assert_eq!(state["can_undo"].as_bool(), Some(cursor > 0), "{state}");
    assert_eq!(state["can_redo"].as_bool(), Some(cursor < depth), "{state}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_five_messages_over_the_wire() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let src = content_src(tmp.path());
    let port = start(&home, &src).await;

    // §3.1: none of the five is on the anonymous list.
    let mut anonymous = Client::connect(port).await;
    for kind in ["edit.state", "edit.undo", "edit.redo", "edit.clear"] {
        assert_eq!(
            anonymous.err(kind, json!({ "quest_id": HELLO })).await,
            "unauthorized",
            "{kind}"
        );
    }
    assert_eq!(
        anonymous
            .err("edit.push", json!({ "quest_id": HELLO, "source": "x" }))
            .await,
        "unauthorized"
    );

    let mut alice = Client::connect(port).await;
    alice.login(ALICE_KEY).await;

    // A quest nobody has edited: an empty stack, and `source` null rather than
    // a copy of the starter.
    let opened = alice.ok("edit.state", json!({ "quest_id": HELLO })).await;
    assert_state(&opened, HELLO, None, 0, 0);

    let one = alice
        .ok("edit.push", json!({ "quest_id": HELLO, "source": "one" }))
        .await;
    assert_state(&one, HELLO, Some("one"), 1, 1);
    let two = alice
        .ok("edit.push", json!({ "quest_id": HELLO, "source": "two" }))
        .await;
    assert_state(&two, HELLO, Some("two"), 2, 2);

    let back = alice.ok("edit.undo", json!({ "quest_id": HELLO })).await;
    assert_state(&back, HELLO, Some("one"), 1, 2);
    let forward = alice.ok("edit.redo", json!({ "quest_id": HELLO })).await;
    assert_state(&forward, HELLO, Some("two"), 2, 2);

    // A read never moves the cursor.
    assert_state(
        &alice.ok("edit.state", json!({ "quest_id": HELLO })).await,
        HELLO,
        Some("two"),
        2,
        2,
    );

    let cleared = alice.ok("edit.clear", json!({ "quest_id": HELLO })).await;
    assert_state(&cleared, HELLO, None, 0, 0);

    // The errors §4.11c names.
    assert_eq!(
        alice
            .err("edit.state", json!({ "quest_id": "rust.basic.99.ghost" }))
            .await,
        "not_found"
    );
    let big = "x".repeat(cwbhacker_core::edits::MAX_SOURCE_BYTES + 1);
    assert_eq!(
        alice
            .err("edit.push", json!({ "quest_id": HELLO, "source": big }))
            .await,
        "bad_request"
    );
    assert_eq!(
        alice.err("edit.push", json!({ "quest_id": HELLO })).await,
        "bad_request",
        "a push with no source"
    );
    assert_eq!(
        alice.err("edit.state", json!({})).await,
        "bad_request",
        "every one of the five needs a quest_id"
    );
}

/// The point of putting the stack in the home: it follows the player between
/// windows and between clients, and it belongs to one of them.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_stack_outlives_the_connection_and_belongs_to_one_player() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let src = content_src(tmp.path());
    let port = start(&home, &src).await;

    let mut alice = Client::connect(port).await;
    alice.login(ALICE_KEY).await;
    alice
        .ok(
            "edit.push",
            json!({ "quest_id": HELLO, "source": "alice one" }),
        )
        .await;
    alice
        .ok(
            "edit.push",
            json!({ "quest_id": HELLO, "source": "alice two" }),
        )
        .await;
    alice
        .ok(
            "edit.push",
            json!({ "quest_id": SUM, "source": "elsewhere" }),
        )
        .await;
    drop(alice);

    // Bob logs in on his own socket and sees his own (empty) stack.
    let mut bob = Client::connect(port).await;
    bob.login(BOB_KEY).await;
    assert_state(
        &bob.ok("edit.state", json!({ "quest_id": HELLO })).await,
        HELLO,
        None,
        0,
        0,
    );
    bob.ok(
        "edit.push",
        json!({ "quest_id": HELLO, "source": "bob one" }),
    )
    .await;

    // A second window for Alice: the same stack, where she left it, and the
    // other quest kept its own.
    let mut again = Client::connect(port).await;
    again.login(ALICE_KEY).await;
    assert_state(
        &again.ok("edit.state", json!({ "quest_id": HELLO })).await,
        HELLO,
        Some("alice two"),
        2,
        2,
    );
    assert_state(
        &again.ok("edit.state", json!({ "quest_id": SUM })).await,
        SUM,
        Some("elsewhere"),
        1,
        1,
    );
    assert_state(
        &again.ok("edit.undo", json!({ "quest_id": HELLO })).await,
        HELLO,
        Some("alice one"),
        1,
        2,
    );

    // And the sources are on disk under the home, content-addressed, not in a
    // column: two distinct texts for Alice's quest, one file each.
    let address = {
        let key = k256::ecdsa::SigningKey::from_slice(&hex::decode(ALICE_KEY).unwrap()).unwrap();
        eth::address_from_pubkey(key.verifying_key()).to_ascii_lowercase()
    };
    let dir = cwbhacker_core::Home::open(&home)
        .unwrap()
        .edit_dir(&address, HELLO);
    assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 2, "{dir:?}");
}
