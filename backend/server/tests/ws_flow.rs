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
    // PROTOCOL §4.7: nothing is locked. Every node on a fresh map is open.
    assert!(
        map["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .all(|n| n["state"] == "open"),
        "a fresh player must be able to open any node: {}",
        map["nodes"]
    );
    assert_eq!(map["nodes"][0]["x"].as_f64(), Some(0.12));
    assert_eq!(map["land"].as_str(), Some("rust"));
    assert_eq!(map["category"].as_str(), Some("basic"));
    assert_eq!(map["nodes"][0]["requires"], json!([]));
    assert_eq!(
        map["nodes"][1]["requires"],
        json!(["rust.basic.01.hello"]),
        "the suggested route still travels, it just does not gate anything"
    );

    // This used to be the `locked` case. The last node of the map opens for a
    // player who has touched nothing: somebody with an interview on Thursday
    // needs the hard street on Tuesday.
    let ahead = alice
        .ok(
            "quest.get",
            json!({ "quest_id": "rust.basic.03.shadowing" }),
        )
        .await;
    assert_eq!(ahead["quest"]["state"].as_str(), Some("open"));
    assert_eq!(
        ahead["quest"]["node"].as_i64(),
        Some(3),
        "the third node opened without the first two"
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

    // §8: one box over two indexes. The engine, the embedder and the index
    // were all here; the dispatch answered `unavailable` regardless, so the
    // screen had three modes and a filter column and could not run a query.
    let found = alice
        .ok("search.query", json!({ "q": "shadowing", "limit": 5 }))
        .await;
    // A word that is in the fixture, so this fails when the index is empty
    // rather than passing on a well-shaped answer with nothing in it.
    let hits = found["hits"].as_array().expect("§4.12: hits is a list");
    assert!(
        !hits.is_empty(),
        "`shadowing` is a concept on rust.basic.03 and must be findable: {found}"
    );
    let ids: Vec<&str> = hits.iter().filter_map(|h| h["quest_id"].as_str()).collect();
    assert!(
        ids.contains(&"rust.basic.03.shadowing"),
        "the quest that word belongs to is not in {ids:?}"
    );
    // Every field the results panel draws, on the hit it draws them from: a
    // hit missing `title` or `state` is a blank row on screen.
    let top = &hits[0];
    for field in ["quest_id", "title", "land", "category", "state"] {
        assert!(
            top[field].is_string(),
            "a hit needs `{field}` to be drawable: {top}"
        );
    }
    assert!(top["score"].is_number(), "the bars are drawn from `score`");
    assert!(
        found["took_ms"].is_number(),
        "the screen draws how long it took"
    );
    // The mode that **ran**, which is not always the one that was asked for:
    // with an empty embedding table the fusion falls back to BM25 alone, and
    // the client captions what came back rather than what it requested.
    assert!(
        matches!(
            found["mode"].as_str(),
            Some("unified") | Some("bm25") | Some("semantic")
        ),
        "unexpected mode: {found}"
    );
    // An empty box is still not a way to ask for everything (§4.12).
    let empty = alice.ok("search.query", json!({ "q": "   " })).await;
    assert_eq!(
        empty["hits"].as_array().map(Vec::len),
        Some(0),
        "an empty query returns nothing rather than the whole corpus"
    );

    // §4.12: the filters narrow rather than decorate. The quest's own land
    // keeps it; a land it is not in drops it.
    let kept = alice
        .ok(
            "search.query",
            json!({ "q": "shadowing", "filters": { "land": "rust" } }),
        )
        .await;
    assert!(
        !kept["hits"].as_array().unwrap().is_empty(),
        "filtering to the quest's own land dropped it: {kept}"
    );
    let dropped = alice
        .ok(
            "search.query",
            json!({ "q": "shadowing", "filters": { "land": "go" } }),
        )
        .await;
    assert_eq!(
        dropped["hits"].as_array().map(Vec::len),
        Some(0),
        "a Rust quest answered a search filtered to Go: {dropped}"
    );

    // All three modes answer. `semantic` is the one that needs the embedder
    // and the vector table, so it is the one that would fail quietly if the
    // index had not been built at startup.
    for mode in ["unified", "bm25", "semantic"] {
        let reply = alice
            .ok("search.query", json!({ "q": "shadowing", "mode": mode }))
            .await;
        assert!(
            reply["hits"].is_array(),
            "mode {mode} did not answer with hits: {reply}"
        );
    }

    // A search box is not a query language (§8). FTS5 would read this as
    // syntax; somebody typing it deserves a search rather than an error.
    let punctuation = alice
        .ok("search.query", json!({ "q": "Box<dyn Error>" }))
        .await;
    assert!(
        punctuation["hits"].is_array(),
        "punctuation in the box became an error: {punctuation}"
    );

    // AI drills (§4.16). Alice has failed `02` above and cleared `01`, so
    // `repeat` has one quest to offer; the plan is walked to its end, which
    // is `not_found`, and finished. The plan's *contents* are the core's
    // business (core/tests/drills.rs); this is the wire.
    let ai = alice.ok("ai.plan", json!({ "mode": "repeat" })).await;
    let drill_id = ai["drill"]["id"].as_str().expect("a drill id").to_string();
    assert!(drill_id.starts_with("drl_"), "{drill_id}");
    assert_eq!(ai["drill"]["mode"].as_str(), Some("repeat"));
    assert_eq!(
        ai["drill"]["cursor"].as_i64(),
        Some(0),
        "§4.16: cursor is 0-based"
    );
    let total = ai["drill"]["plan"].as_array().expect("a plan").len();
    assert!(total >= 1, "a failed quest is what `repeat` is for: {ai}");
    for position in 0..total {
        let step = alice
            .ok("ai.next", json!({ "drill_id": drill_id, "locale": "ko" }))
            .await;
        assert_eq!(step["position"].as_u64(), Some(position as u64));
        assert_eq!(step["total"].as_u64(), Some(total as u64));
        assert!(step["quest"]["id"].is_string(), "{step}");
        assert!(
            step["why"].as_str().is_some_and(|w| !w.is_empty()),
            "{step}"
        );
    }
    let past = alice.call("ai.next", json!({ "drill_id": drill_id })).await;
    assert_eq!(
        past["payload"]["code"].as_str(),
        Some("not_found"),
        "§4.16: past the end is not_found, not a crash: {past}"
    );
    let done = alice.ok("ai.finish", json!({ "drill_id": drill_id })).await;
    assert!(done["summary"]["attempted"].is_number(), "{done}");
    let weak = alice.ok("ai.plan", json!({ "mode": "weakness" })).await;
    assert!(
        weak["drill"]["plan"].is_array(),
        "an empty plan is .ok, not an error: {weak}"
    );
    let bad = alice.call("ai.plan", json!({ "mode": "psychic" })).await;
    assert_eq!(bad["payload"]["code"].as_str(), Some("bad_request"));
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
    // Alice cleared node 1; Bob has not. Nothing is locked for either of
    // them, so what distinguishes the two maps is the stamp — which is what
    // this test is about.
    assert_eq!(bob_map["nodes"][0]["state"].as_str(), Some("open"));
    assert!(
        bob_map["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .all(|n| n["state"] == "open"),
        "{}",
        bob_map["nodes"]
    );
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
async fn a_run_leaves_a_draft_and_solve_costs_a_star() {
    // PROTOCOL §4.8's `draft`, and §4.11b's `quest.solve` — both new, both
    // built on data the server already had rather than a new save path.
    let tmp = tempfile::tempdir().unwrap();
    let src = content_src(tmp.path());
    let server = start(&tmp.path().join("home"), &src).await;
    let mut alice = Client::connect(server.port).await;
    alice.login(ALICE_KEY).await;

    // Nobody has attempted this quest yet: no draft to speak of.
    let first = alice
        .ok("quest.get", json!({ "quest_id": "rust.basic.02.sum" }))
        .await;
    assert!(
        first["quest"]["draft"].is_null(),
        "a quest nobody has touched has no draft: {first}"
    );

    // A RUN — not even a submit — is enough to leave one. §4.9b's own rule
    // ("a run is still recorded") is what makes this true without a new
    // write path: the draft is just the newest attempt's source, and a run
    // is an attempt.
    let scratch = "fn main() { println!(\"not the answer\"); }";
    alice
        .ok(
            "quest.run",
            json!({ "quest_id": "rust.basic.02.sum", "source": scratch, "lang": "rust" }),
        )
        .await;
    let after_run = alice
        .ok("quest.get", json!({ "quest_id": "rust.basic.02.sum" }))
        .await;
    assert_eq!(
        after_run["quest"]["draft"].as_str(),
        Some(scratch),
        "the run's own source comes back as the draft: {after_run}"
    );

    // A submit afterwards moves the draft again, to the newest source — and
    // clears the node at three stars, since nothing has cost a star yet.
    let solution = solution_of("rust.basic.02.sum");
    alice
        .ok(
            "quest.submit",
            json!({ "quest_id": "rust.basic.02.sum", "source": solution, "lang": "rust" }),
        )
        .await;
    let after_submit = alice
        .ok("quest.get", json!({ "quest_id": "rust.basic.02.sum" }))
        .await;
    assert_eq!(after_submit["quest"]["stars"].as_i64(), Some(3));

    // quest.solve on a different, uncleared quest: the real answer comes
    // back, and it costs at least as much as any hint would.
    let solve = alice
        .ok("quest.solve", json!({ "quest_id": "rust.basic.01.hello" }))
        .await;
    let real_solution = solution_of("rust.basic.01.hello");
    assert_eq!(solve["source"].as_str(), Some(real_solution.as_str()));
    assert!(
        solve["hints_used"].as_i64().unwrap() > 0,
        "solving must cost at least one hint's worth: {solve}"
    );

    // Submitting the revealed answer clears the quest, but never at three
    // stars: `stars_for` only ever checks hints_used > 0, and solve just set
    // it, so a perfect clear is exactly what this must never read as.
    let cleared = alice
        .ok(
            "quest.submit",
            json!({ "quest_id": "rust.basic.01.hello", "source": real_solution, "lang": "rust" }),
        )
        .await;
    assert_eq!(cleared["attempt"]["verdict"].as_str(), Some("accepted"));
    assert_eq!(cleared["attempt"]["cleared"].as_bool(), Some(true));
    assert!(
        cleared["attempt"]["stars"].as_i64().unwrap() <= 2,
        "using solve must never earn a perfect clear: {cleared}"
    );

    // And quest.solve itself must not have written an attempt: asking for
    // the answer is not a run, and recording one would put a submission in
    // the table that never happened (the same rule the playground and the
    // formatter are both held to). Exactly one real submit happened above.
    let history = alice
        .ok(
            "stats.history",
            json!({ "quest_id": "rust.basic.01.hello" }),
        )
        .await;
    assert_eq!(
        history["attempts"].as_array().unwrap().len(),
        1,
        "quest.solve must not appear as an attempt: {history}"
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

/// PROTOCOL §1.3: a page from somewhere else cannot open the socket; the
/// server's own page, a native client, and the dev server can.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_foreign_origin_cannot_open_the_socket() {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let src = content_src(tmp.path());
    let server = start(&home, &src).await;
    let url = format!("ws://127.0.0.1:{}/ws", server.port);

    let with_origin = |origin: &str| {
        let mut request = url.as_str().into_client_request().unwrap();
        request
            .headers_mut()
            .insert("Origin", origin.parse().unwrap());
        request
    };

    let err = tokio_tungstenite::connect_async(with_origin("http://evil.example"))
        .await
        .expect_err("a foreign origin is refused");
    match err {
        tokio_tungstenite::tungstenite::Error::Http(response) => {
            assert_eq!(response.status(), 403, "refused with 403, not {response:?}");
        }
        other => panic!("expected an HTTP 403, got {other:?}"),
    }
    tokio_tungstenite::connect_async(with_origin("null"))
        .await
        .expect_err("an opaque origin is refused");

    let own = format!("http://127.0.0.1:{}", server.port);
    tokio_tungstenite::connect_async(with_origin(&own))
        .await
        .expect("the server's own page opens the socket");
    tokio_tungstenite::connect_async(with_origin("http://localhost:5291"))
        .await
        .expect("the dev server on loopback opens the socket");
    tokio_tungstenite::connect_async(url.as_str())
        .await
        .expect("a native client with no Origin opens the socket");

    server.handle.abort();
}
