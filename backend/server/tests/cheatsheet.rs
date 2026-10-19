//! The CHEATSHEET road (SPEC §0): four lines, one right, and the pick is the
//! submission. Nothing is compiled — the server judges the line against the
//! quiz — and the verdict goes down the same path as any other: a wrong pick
//! is a failed attempt that costs a star, the right one clears the node.

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

use cwbhacker_core::{content, eth, Store};

const KEY: &str = "4646464646464646464646464646464646464646464646464646464646464646";

const PACK: &str = r#"
pack = "rust.cheatsheet"
land = "rust"
category = "cheatsheet"
version = 1

[[quest]]
id         = "rust.cheatsheet.01.inclusive"
node       = 1
title      = "ONE TO TEN"
difficulty = 1
story      = "The tram stops are numbered 1 to 10."
concepts   = ["control-flow", "iteration"]
requires   = []
brief      = "Loop over 1 to 10, ten included."
solution   = "for i in 1..=10 {"

[quest.quiz]
choices = ["for i in 1..10 {", "for i in 1..=10 {", "for i in range(1, 11) {", "for (i = 1; i <= 10; i++) {"]
answer  = 1
"#;

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
    std::fs::write(dir.join("cheatsheet.toml"), PACK).unwrap();
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

struct Client {
    socket: Socket,
    next_id: u32,
    events: Vec<Value>,
}

impl Client {
    async fn connect(port: u16) -> Client {
        let (socket, _) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}/ws"))
            .await
            .unwrap();
        Client {
            socket,
            next_id: 0,
            events: Vec::new(),
        }
    }

    async fn call(&mut self, kind: &str, payload: Value) -> Value {
        self.next_id += 1;
        let id = format!("c-{}", self.next_id);
        self.socket
            .send(Message::text(
                json!({ "v": 1, "id": id, "type": kind, "payload": payload }).to_string(),
            ))
            .await
            .unwrap();
        loop {
            let message =
                tokio::time::timeout(std::time::Duration::from_secs(120), self.socket.next())
                    .await
                    .expect("answered")
                    .expect("open")
                    .expect("readable");
            let Message::Text(text) = message else {
                continue;
            };
            let value: Value = serde_json::from_str(&text).unwrap();
            if value["id"].as_str() == Some(id.as_str()) {
                return value;
            }
            self.events.push(value);
        }
    }

    async fn ok(&mut self, kind: &str, payload: Value) -> Value {
        let frame = self.call(kind, payload).await;
        assert_eq!(
            frame["type"].as_str(),
            Some(format!("{kind}.ok").as_str()),
            "{frame}"
        );
        frame["payload"].clone()
    }

    async fn login(&mut self) {
        let key = k256::ecdsa::SigningKey::from_slice(&hex::decode(KEY).unwrap()).unwrap();
        let address = eth::address_from_pubkey(key.verifying_key());
        let challenge = self
            .ok("auth.challenge", json!({ "address": address }))
            .await;
        let message = challenge["message"].as_str().unwrap().to_string();
        let (signature, recovery) = key
            .sign_prehash_recoverable(&eth::eip191_hash(&message))
            .unwrap();
        let mut bytes = signature.to_bytes().to_vec();
        bytes.push(recovery.to_byte());
        self.ok(
            "auth.login",
            json!({ "address": address, "signature": format!("0x{}", hex::encode(bytes)) }),
        )
        .await;
    }

    async fn pick(&mut self, source: &str) -> Value {
        self.ok(
            "quest.submit",
            json!({ "quest_id": "rust.cheatsheet.01.inclusive", "lang": "rust", "source": source }),
        )
        .await["attempt"]
            .clone()
    }

    async fn node(&mut self) -> Value {
        self.ok(
            "world.map",
            json!({ "land": "rust", "category": "cheatsheet" }),
        )
        .await["nodes"][0]
            .clone()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_wrong_pick_is_a_failed_attempt_and_the_right_one_clears() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login().await;

    let quest = client
        .ok(
            "quest.get",
            json!({ "quest_id": "rust.cheatsheet.01.inclusive" }),
        )
        .await;
    assert_eq!(quest["quest"]["category"].as_str(), Some("cheatsheet"));
    assert_eq!(
        quest["quest"]["quiz"]["choices"].as_array().map(Vec::len),
        Some(4)
    );

    let wrong = client.pick("for i in 1..10 {").await;
    assert_eq!(wrong["verdict"].as_str(), Some("wrong_answer"), "{wrong}");
    assert_eq!(wrong["cleared"].as_bool(), Some(false));
    assert_eq!(client.node().await["state"].as_str(), Some("open"));

    let right = client.pick("  for i in 1..=10 {\n").await;
    assert_eq!(right["verdict"].as_str(), Some("accepted"), "{right}");
    assert_eq!(right["cleared"].as_bool(), Some(true));
    assert_eq!(
        right["stars"].as_i64(),
        Some(2),
        "one wrong pick before the right one is two stars, as on any road"
    );
    let node = client.node().await;
    assert_eq!(node["state"].as_str(), Some("cleared"));
    assert_eq!(node["attempts"].as_i64(), Some(2));
    server.handle.abort();
}

#[test]
fn a_cheatsheet_quest_with_tests_or_a_wrong_solution_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("home")).unwrap();
    for (name, pack) in [
        (
            "tests",
            PACK.replace("[quest.quiz]", "[quest.tests]\ncases = []\n\n[quest.quiz]"),
        ),
        (
            "solution",
            PACK.replace(
                r#"solution   = "for i in 1..=10 {""#,
                r#"solution   = "for i in 1..10 {""#,
            ),
        ),
        ("answer", PACK.replace("answer  = 1", "answer  = 4")),
    ] {
        let dir = tmp.path().join(name).join("rust");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("cheatsheet.toml"), pack).unwrap();
        let conn = store.conn();
        let report = content::import_dir(&conn, store.home(), &tmp.path().join(name)).unwrap();
        assert_eq!(report.failures.len(), 1, "{name}: {:?}", report.failures);
    }
}
