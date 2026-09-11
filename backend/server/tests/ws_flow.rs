//! The vertical slice over the real wire (PLAN.md, milestone 1).
//!
//! Login with a signature, walk the map, submit the reference solution, watch
//! `run.stage` stream, clear the node — then put the server down, bring it up
//! on the same home, and find it still cleared.

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

use cwbhacker_core::{content, eth, Store};

const PACK: &str = include_str!("../../core/tests/fixtures/rust_basic.toml");
/// The key `eth-account` used for this repo's EIP-191 vectors. Its private
/// half is a published test key and guards nothing.
const ALICE_KEY: &str = "4646464646464646464646464646464646464646464646464646464646464646";
const BOB_KEY: &str = "1111111111111111111111111111111111111111111111111111111111111111";

struct Client {
    socket: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    next_id: u32,
    /// Every unsolicited frame seen while waiting for a reply.
    events: Vec<Value>,
}

impl Client {
    async fn connect(port: u16) -> Client {
        let (socket, _) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}/ws"))
            .await
            .expect("the websocket accepts a connection");
        Client {
            socket,
            next_id: 0,
            events: Vec::new(),
        }
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
                tokio::time::timeout(std::time::Duration::from_secs(120), self.socket.next())
                    .await
                    .expect("the server answered within two minutes")
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
            assert!(value["id"].is_null(), "a reply to a request nobody made");
            self.events.push(value);
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

    /// §3.2 from the client's side: derive, ask for a challenge, sign the
    /// exact message the server sent back, log in.
    async fn login(&mut self, key_hex: &str) -> (String, String) {
        let key = signing_key(key_hex);
        let address = eth::address_from_pubkey(key.verifying_key());
        let challenge = self
            .ok("auth.challenge", json!({ "address": address }))
            .await;
        let message = challenge["message"].as_str().unwrap().to_string();
        let signature = sign(&key, &message);
        let login = self
            .ok(
                "auth.login",
                json!({ "address": address, "signature": signature }),
            )
            .await;
        (address, login["token"].as_str().unwrap().to_string())
    }
}

fn signing_key(hex_key: &str) -> k256::ecdsa::SigningKey {
    k256::ecdsa::SigningKey::from_slice(&hex::decode(hex_key).unwrap()).unwrap()
}

fn sign(key: &k256::ecdsa::SigningKey, message: &str) -> String {
    let digest = eth::eip191_hash(message);
    let (signature, recovery) = key.sign_prehash_recoverable(&digest).unwrap();
    let mut bytes = signature.to_bytes().to_vec();
    bytes.push(recovery.to_byte());
    format!("0x{}", hex::encode(bytes))
}

struct Server {
    port: u16,
    handle: tokio::task::JoinHandle<()>,
}

async fn start(home: &std::path::Path, content_src: &std::path::Path) -> Server {
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
    let state = cwbhacker_server::build_state(store, &config);
    let app = cwbhacker_server::router(state);
    let handle = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    Server { port, handle }
}

fn content_src(root: &std::path::Path) -> std::path::PathBuf {
    let dir = root.join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), PACK).unwrap();
    root.join("content-src")
}

fn solution_of(id: &str) -> String {
    let pack: toml::Value = toml::from_str(PACK).unwrap();
    pack["quest"]
        .as_array()
        .unwrap()
        .iter()
        .find(|q| q["id"].as_str() == Some(id))
        .expect("the fixture has that quest")["solution"]
        .as_str()
        .unwrap()
        .to_string()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_whole_slice_end_to_end() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let src = content_src(tmp.path());
    let server = start(&home, &src).await;

    let mut alice = Client::connect(server.port).await;

    // §6.4: ping is allowed before logging in; everything else is not.
    let pong = alice.ok("ping", json!({})).await;
    assert!(
        pong["t"].as_str().unwrap().ends_with('Z'),
        "t is RFC3339 UTC"
    );
    assert_eq!(alice.err("world.lands", json!({})).await, "unauthorized");

    // §6.1: an unknown protocol version is answered, and the socket stays up.
    alice.next_id += 1;
    let id = format!("c-{}", alice.next_id);
    alice
        .socket
        .send(Message::text(
            json!({ "v": 99, "id": id, "type": "ping", "payload": {} }).to_string(),
        ))
        .await
        .unwrap();
    let reply = match alice.socket.next().await.unwrap().unwrap() {
        Message::Text(text) => serde_json::from_str::<Value>(&text).unwrap(),
        other => panic!("{other:?}"),
    };
    assert_eq!(reply["payload"]["code"].as_str(), Some("proto_version"));
    assert_eq!(
        reply["payload"]["detail"]["supported"],
        json!([1]),
        "PROTOCOL §2.1 names the versions this server speaks"
    );
    // …and the connection stays open.
    assert!(alice.ok("ping", json!({})).await["t"].is_string());

    let (address, token) = alice.login(ALICE_KEY).await;

    let lands = alice.ok("world.lands", json!({})).await;
    assert_eq!(lands["lands"][0]["land"].as_str(), Some("rust"));
    assert_eq!(
        lands["lands"][0]["categories"][0]["total"].as_i64(),
        Some(3)
    );

    let map = alice
        .ok("world.map", json!({ "land": "rust", "category": "basic" }))
        .await;
    assert_eq!(map["nodes"][0]["state"].as_str(), Some("open"));
    assert_eq!(map["nodes"][1]["state"].as_str(), Some("locked"));
    assert_eq!(map["nodes"][0]["x"].as_f64(), Some(0.12));
    assert_eq!(map["land"].as_str(), Some("rust"));
    assert_eq!(map["category"].as_str(), Some("basic"));
    assert_eq!(map["nodes"][0]["requires"], json!([]));
    assert_eq!(
        map["nodes"][1]["requires"],
        json!(["rust.basic.01.hello"]),
        "a node names what blocks it"
    );

    // §6.2: a locked node is `locked`, not a 404 and not a free pass.
    assert_eq!(
        alice
            .err("quest.get", json!({ "quest_id": "rust.basic.02.sum" }))
            .await,
        "locked"
    );

    let quest = alice
        .ok("quest.get", json!({ "quest_id": "rust.basic.01.hello" }))
        .await;
    assert_eq!(quest["quest"]["title"].as_str(), Some("FIRST LIGHT"));
    assert!(
        quest["quest"].get("solution").is_none(),
        "PROTOCOL §4.8: solution is omitted entirely, not sent as null"
    );
    assert_eq!(quest["quest"]["state"].as_str(), Some("open"));
    assert_eq!(quest["quest"]["hints_total"].as_i64(), Some(2));
    assert_eq!(quest["quest"]["hints_used"].as_i64(), Some(0));
    assert_eq!(
        quest["quest"]["tests"]["visible"][0]["expect"].as_str(),
        Some("hello, causewaybay\n")
    );
    assert_eq!(quest["quest"]["tests"]["hidden_count"].as_i64(), Some(0));

    // A wrong answer first, so the clear is worth two stars and the mistake
    // shows up in the stats.
    let wrong = alice
        .ok(
            "quest.submit",
            json!({
                "quest_id": "rust.basic.01.hello",
                "source": "fn main() { let x: i32 = \"no\"; }",
                "lang": "rust"
            }),
        )
        .await;
    assert_eq!(wrong["attempt"]["verdict"].as_str(), Some("compile_error"));
    assert_eq!(wrong["attempt"]["cleared"].as_bool(), Some(false));
    let kinds: Vec<&str> = wrong["attempt"]["mistakes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["kind"].as_str().unwrap())
        .collect();
    assert!(kinds.contains(&"type-mismatch"), "{kinds:?}");
    assert!(
        wrong["attempt"]["stderr"]
            .as_str()
            .unwrap()
            .contains("mismatched types"),
        "the player should see the compiler's own words, not JSON"
    );

    // §5.4: the stages streamed while the request was still unanswered.
    let stages: Vec<&str> = alice
        .events
        .iter()
        .filter(|e| e["type"] == "run.stage")
        .map(|e| e["payload"]["stage"].as_str().unwrap())
        .collect();
    assert!(
        stages.contains(&"queued") && stages.contains(&"compiling"),
        "{stages:?}"
    );
    assert!(
        alice.events.iter().any(|e| e["type"] == "run.log"),
        "no run.log arrived while rustc was working"
    );

    let hint = alice
        .ok(
            "quest.hint",
            json!({ "quest_id": "rust.basic.01.hello", "index": 0 }),
        )
        .await;
    assert!(hint["hint"].as_str().unwrap().contains("println!"));
    assert_eq!(hint["index"].as_i64(), Some(0));
    assert_eq!(hint["total"].as_i64(), Some(2));
    assert_eq!(hint["hints_used"].as_i64(), Some(1));
    assert_eq!(
        alice
            .err(
                "quest.hint",
                json!({ "quest_id": "rust.basic.01.hello", "index": 9 })
            )
            .await,
        "not_found"
    );

    let cleared = alice
        .ok(
            "quest.submit",
            json!({
                "quest_id": "rust.basic.01.hello",
                "source": solution_of("rust.basic.01.hello"),
                "lang": "rust"
            }),
        )
        .await;
    assert_eq!(
        cleared["attempt"]["verdict"].as_str(),
        Some("accepted"),
        "{}",
        cleared["attempt"]["stderr"]
    );
    assert_eq!(cleared["attempt"]["cleared"].as_bool(), Some(true));
    assert_eq!(
        cleared["attempt"]["stars"].as_i64(),
        Some(2),
        "a hint and a failure is two stars"
    );
    let update = alice
        .events
        .iter()
        .rev()
        .find(|e| e["type"] == "progress.update")
        .expect("the map was never told");
    assert_eq!(
        update["payload"]["unlocked"],
        json!(["rust.basic.02.sum"]),
        "progress.update names what it opened"
    );
    assert!(
        alice.events.iter().any(|e| e["type"] == "award"),
        "a clear is worth a stamp"
    );
    // §4.18: run.log carries a per-stream sequence starting at 0.
    let compile_seqs: Vec<i64> = alice
        .events
        .iter()
        .filter(|e| e["type"] == "run.log" && e["payload"]["stream"] == "compile")
        .map(|e| e["payload"]["seq"].as_i64().unwrap())
        .collect();
    assert_eq!(
        compile_seqs.first(),
        Some(&0),
        "seq counts from 0 per stream"
    );
    assert!(
        compile_seqs.windows(2).all(|w| w[1] == w[0] + 1),
        "a gap in seq means a client cannot trust it: {compile_seqs:?}"
    );

    // The node ahead is open now, and the answer is visible on the one cleared.
    let map = alice
        .ok("world.map", json!({ "land": "rust", "category": "basic" }))
        .await;
    assert_eq!(map["nodes"][0]["state"].as_str(), Some("cleared"));
    assert_eq!(map["nodes"][0]["stars"].as_i64(), Some(2));
    assert_eq!(map["nodes"][1]["state"].as_str(), Some("open"));
    let quest = alice
        .ok("quest.get", json!({ "quest_id": "rust.basic.01.hello" }))
        .await;
    assert!(quest["quest"]["solution"]
        .as_str()
        .unwrap()
        .contains("println!"));

    let summary = alice.ok("stats.summary", json!({})).await;
    assert_eq!(summary["cleared"].as_i64(), Some(1));
    assert_eq!(summary["total"].as_i64(), Some(3));
    assert_eq!(summary["attempts"].as_i64(), Some(2));
    assert_eq!(summary["stars"].as_i64(), Some(2));
    assert_eq!(summary["streak_days"].as_i64(), Some(1));
    assert_eq!(summary["accuracy"].as_f64(), Some(0.5));
    let stats = alice.ok("stats.mistakes", json!({})).await;
    assert_eq!(stats["mistakes"][0]["kind"].as_str(), Some("type-mismatch"));
    assert_eq!(
        stats["mistakes"][0]["label"].as_str(),
        Some("type mismatch")
    );
    let history = alice.ok("stats.history", json!({ "limit": 10 })).await;
    assert_eq!(history["attempts"].as_array().unwrap().len(), 2);

    let reset = alice
        .ok("quest.reset", json!({ "quest_id": "rust.basic.01.hello" }))
        .await;
    assert!(reset["starter"]
        .as_str()
        .unwrap()
        .contains("your code here"));

    let profile = alice
        .ok(
            "profile.update",
            json!({ "name": "kowloon", "settings": { "orientation": "portrait" } }),
        )
        .await;
    assert_eq!(profile["user"]["name"].as_str(), Some("kowloon"));
    assert_eq!(
        profile["user"]["address"].as_str(),
        Some(eth::to_eip55(&address).as_str()),
        "PROTOCOL §2.4: addresses are EIP-55 on the wire"
    );
    assert!(profile["user"]["level"].is_number());
    assert!(profile["user"]["xp"].is_number());

    // Milestone 2 refuses cleanly rather than panicking the connection.
    assert_eq!(
        alice.err("search.query", json!({ "q": "ownership" })).await,
        "not_found"
    );
    assert_eq!(
        alice.err("ai.plan", json!({ "mode": "weakness" })).await,
        "not_found"
    );
    assert!(alice.ok("ping", json!({})).await["t"].is_string());

    // §6.4: one in-flight submit per connection. Both frames go out before
    // either is answered, so the second one meets the flag the first set.
    alice.next_id += 1;
    let first_id = format!("c-{}", alice.next_id);
    alice.next_id += 1;
    let second_id = format!("c-{}", alice.next_id);
    for id in [&first_id, &second_id] {
        alice
            .socket
            .send(Message::text(
                json!({
                    "v": 1, "id": id, "type": "quest.submit",
                    "payload": {
                        "quest_id": "rust.basic.01.hello",
                        "source": solution_of("rust.basic.01.hello"),
                        "lang": "rust"
                    }
                })
                .to_string(),
            ))
            .await
            .unwrap();
    }
    let mut seen = std::collections::HashMap::new();
    while seen.len() < 2 {
        let message =
            tokio::time::timeout(std::time::Duration::from_secs(120), alice.socket.next())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
        let Message::Text(text) = message else {
            continue;
        };
        let value: Value = serde_json::from_str(&text).unwrap();
        match value["id"].as_str() {
            Some(id) if id == first_id || id == second_id => {
                seen.insert(id.to_string(), value.clone());
            }
            _ => alice.events.push(value),
        }
    }
    assert_eq!(
        seen[&second_id]["payload"]["code"].as_str(),
        Some("busy"),
        "a second submission on one connection must be refused: {:?}",
        seen[&second_id]
    );
    assert_eq!(
        seen[&first_id]["type"].as_str(),
        Some("quest.submit.ok"),
        "the first submission should still have been judged"
    );

    // ---- SPEC §3.5: a second user, on their own connection ----
    let mut bob = Client::connect(server.port).await;
    let (bob_address, _) = bob.login(BOB_KEY).await;
    assert_ne!(bob_address, address);
    let bob_map = bob
        .ok("world.map", json!({ "land": "rust", "category": "basic" }))
        .await;
    assert_eq!(bob_map["nodes"][0]["state"].as_str(), Some("open"));
    assert_eq!(bob_map["nodes"][1]["state"].as_str(), Some("locked"));
    assert_eq!(
        bob.ok("stats.summary", json!({})).await["cleared"].as_i64(),
        Some(0)
    );
    assert!(bob.ok("stats.history", json!({})).await["attempts"]
        .as_array()
        .unwrap()
        .is_empty());

    // A payload that carries somebody else's address is ignored, not trusted.
    let forged = bob.ok("stats.history", json!({ "address": address })).await;
    assert!(
        forged["attempts"].as_array().unwrap().is_empty(),
        "an address in a payload must never select the data"
    );

    // ---- the restart ----
    server.handle.abort();
    drop(alice);
    drop(bob);
    let server = start(&home, &src).await;
    let mut alice = Client::connect(server.port).await;
    let resumed = alice.ok("auth.resume", json!({ "token": token })).await;
    let rotated = resumed["token"].as_str().unwrap().to_string();
    assert_ne!(rotated, token, "PROTOCOL §4.4: the token rotates on resume");
    assert_eq!(
        resumed["user"]["address"].as_str(),
        Some(eth::to_eip55(&address).as_str())
    );
    assert_eq!(resumed["user"]["name"].as_str(), Some("kowloon"));
    let map = alice
        .ok("world.map", json!({ "land": "rust", "category": "basic" }))
        .await;
    assert_eq!(
        map["nodes"][0]["state"].as_str(),
        Some("cleared"),
        "the clear did not survive the restart"
    );
    assert_eq!(map["nodes"][0]["stars"].as_i64(), Some(2));
    let stats = alice.ok("stats.mistakes", json!({})).await;
    assert_eq!(stats["mistakes"][0]["kind"].as_str(), Some("type-mismatch"));

    // The old token is dead the moment the new one is handed over.
    let mut stale = Client::connect(server.port).await;
    assert_eq!(
        stale.err("auth.resume", json!({ "token": token })).await,
        "unauthorized"
    );
    let mut fresh = Client::connect(server.port).await;
    assert!(
        fresh.ok("auth.resume", json!({ "token": rotated })).await["user"]["name"]
            .as_str()
            .is_some()
    );
    server.handle.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stale_nonce_and_a_forged_signature_are_both_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let src = content_src(tmp.path());
    let server = start(&tmp.path().join("home"), &src).await;
    let mut client = Client::connect(server.port).await;

    let alice = signing_key(ALICE_KEY);
    let address = eth::address_from_pubkey(alice.verifying_key());
    let challenge = client
        .ok("auth.challenge", json!({ "address": address }))
        .await;
    let message = challenge["message"].as_str().unwrap().to_string();

    // Bob's signature over Alice's challenge.
    let bob = signing_key(BOB_KEY);
    let forged = sign(&bob, &message);
    assert_eq!(
        client
            .call(
                "auth.login",
                json!({ "address": address, "signature": forged })
            )
            .await["payload"]["code"]
            .as_str(),
        Some("auth_bad_signature")
    );

    // The challenge is still live: a rejected signature does not cost the
    // player a round trip, and a mistyped mnemonic is the common case.
    let honest = sign(&alice, &message);
    let reply = client
        .call(
            "auth.login",
            json!({ "address": address, "signature": honest.clone(), "nonce": challenge["nonce"] }),
        )
        .await;
    assert_eq!(
        reply["type"].as_str(),
        Some("auth.login.ok"),
        "a good signature after a bad one must still work: {reply}"
    );

    // Success spends it. A replay of the same signature is `auth_nonce_used`
    // — "used", not "expired", because those are different instructions.
    let mut replay = Client::connect(server.port).await;
    assert_eq!(
        replay
            .call(
                "auth.login",
                json!({ "address": address, "signature": honest, "nonce": challenge["nonce"] })
            )
            .await["payload"]["code"]
            .as_str(),
        Some("auth_nonce_used")
    );
    server.handle.abort();
}
