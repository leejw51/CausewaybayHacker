//! The RUN button (PROTOCOL §4.9b).
//!
//! A run is for the player; a submit is for the record. Everything here is one
//! of the four differences, or the one thing that is deliberately the same:
//! a run's mistakes still enter the curriculum.

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

use cwbhacker_core::{content, eth, Store};

const PACK: &str = include_str!("../../core/tests/fixtures/rust_basic.toml");
const KEY: &str = "4646464646464646464646464646464646464646464646464646464646464646";

const HELLO: &str = "fn main() { println!(\"hello, causewaybay\"); }";
const BROKEN: &str = "fn main() { let x: i32 = \"not a number\"; println!(\"{x}\"); }";
/// Passes `rust.basic.02.sum`'s visible case and fails its hidden one.
const HARDCODED: &str = "fn main() { println!(\"6\"); }";
/// The real answer to `rust.basic.02.sum`, which is a difficulty-2 quest.
const SUM_SOLUTION: &str = r#"
use std::io::Read;
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let mut parts = input.split_whitespace();
    let n: usize = parts.next().unwrap().parse().unwrap();
    let total: i64 = parts.take(n).map(|t| t.parse::<i64>().unwrap()).sum();
    println!("{total}");
}
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

    async fn execute(&mut self, kind: &str, quest: &str, source: &str) -> Value {
        self.ok(
            kind,
            json!({ "quest_id": quest, "lang": "rust", "source": source }),
        )
        .await["attempt"]
            .clone()
    }

    async fn node(&mut self, index: usize) -> Value {
        self.ok("world.map", json!({ "land": "rust", "category": "basic" }))
            .await["nodes"][index]
            .clone()
    }
}

/// A run that passes every visible case still leaves the map untouched. The
/// hidden cases are the ones that decide, and a run never sees them.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_never_clears_a_node() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login().await;

    let attempt = client
        .execute("quest.run", "rust.basic.01.hello", HELLO)
        .await;
    assert_eq!(attempt["mode"].as_str(), Some("run"));
    assert_eq!(attempt["verdict"].as_str(), Some("accepted"), "{attempt}");
    assert_eq!(
        attempt["cleared"].as_bool(),
        Some(false),
        "a run never clears, however well it went"
    );
    assert_eq!(attempt["stars"].as_i64(), Some(0));

    let node = client.node(0).await;
    assert_eq!(node["state"].as_str(), Some("open"));
    assert_eq!(node["stars"].as_i64(), Some(0));
    assert_eq!(
        node["attempts"].as_i64(),
        Some(0),
        "a run must not count against the node's attempts"
    );

    let summary = client.ok("stats.summary", json!({})).await;
    assert_eq!(summary["cleared"].as_i64(), Some(0));
    assert_eq!(
        summary["attempts"].as_i64(),
        Some(0),
        "accuracy counts submits; iterating honestly is not failing"
    );
    assert!(
        !client.events.iter().any(|e| e["type"] == "progress.update"),
        "a run told the map something had changed"
    );

    // …and the same source through SUBMIT does clear it, which is what makes
    // the assertion above about the mode rather than about the source.
    let attempt = client
        .execute("quest.submit", "rust.basic.01.hello", HELLO)
        .await;
    assert_eq!(attempt["mode"].as_str(), Some("submit"));
    assert_eq!(attempt["cleared"].as_bool(), Some(true));
    assert_eq!(client.node(0).await["state"].as_str(), Some("cleared"));
    server.handle.abort();
}

/// The one thing that is deliberately the same. A borrow-checker error is the
/// same lesson whichever button produced it, and SPEC §7's drills are built
/// from this table.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_failing_run_still_enters_the_curriculum() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login().await;

    let attempt = client
        .execute("quest.run", "rust.basic.01.hello", BROKEN)
        .await;
    assert_eq!(attempt["verdict"].as_str(), Some("compile_error"));
    let kinds: Vec<&str> = attempt["mistakes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["kind"].as_str().unwrap())
        .collect();
    assert!(kinds.contains(&"type-mismatch"), "{attempt}");

    let stats = client.ok("stats.mistakes", json!({})).await;
    assert_eq!(
        stats["mistakes"][0]["kind"].as_str(),
        Some("type-mismatch"),
        "the run's mistake never reached mistake_stats: {stats}"
    );
    assert_eq!(stats["mistakes"][0]["count"].as_i64(), Some(1));

    // And the player can see their own iteration.
    let history = client.ok("stats.history", json!({})).await;
    assert_eq!(history["attempts"].as_array().unwrap().len(), 1);
    assert_eq!(history["attempts"][0]["mode"].as_str(), Some("run"));
    server.handle.abort();
}

/// A run must not tell the player whether the hidden cases pass — that is what
/// submitting is for. The hidden cases are not *hidden from the response*,
/// they are never executed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_executes_only_the_visible_cases() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login().await;

    // `rust.basic.02.sum` has one visible case (3 → 6) and one hidden (→ 150).
    // This source passes the first and fails the second.
    let run = client
        .execute("quest.run", "rust.basic.02.sum", HARDCODED)
        .await;
    assert_eq!(
        run["verdict"].as_str(),
        Some("accepted"),
        "the visible case passes, so the run passes: {run}"
    );
    assert_eq!(run["tests_total"].as_i64(), Some(1));
    assert_eq!(run["tests_passed"].as_i64(), Some(1));
    let cases = run["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 1, "a hidden case was reported: {run}");
    assert_eq!(cases[0]["name"].as_str(), Some("sample"));
    assert!(
        !run.to_string().contains("bigger"),
        "the hidden case's name leaked into a run: {run}"
    );
    assert!(
        !run.to_string().contains("150"),
        "the hidden case's data leaked into a run: {run}"
    );
    assert_eq!(run["cleared"].as_bool(), Some(false));

    // Submitting the same source runs both and fails.
    let submit = client
        .execute("quest.submit", "rust.basic.02.sum", HARDCODED)
        .await;
    assert_eq!(submit["verdict"].as_str(), Some("wrong_answer"));
    assert_eq!(submit["tests_total"].as_i64(), Some(2));
    assert_eq!(submit["tests_passed"].as_i64(), Some(1));
    assert_eq!(submit["cleared"].as_bool(), Some(false));
    server.handle.abort();
}

/// The shape of an actual session: iterate, iterate, iterate, then submit.
/// The node should remember one attempt and the curriculum should remember
/// every mistake.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn twenty_runs_and_one_submit() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login().await;

    for i in 0..20 {
        let attempt = client
            .execute("quest.run", "rust.basic.01.hello", BROKEN)
            .await;
        assert_eq!(
            attempt["verdict"].as_str(),
            Some("compile_error"),
            "run {i}"
        );
    }
    let attempt = client
        .execute("quest.submit", "rust.basic.01.hello", BROKEN)
        .await;
    assert_eq!(attempt["verdict"].as_str(), Some("compile_error"));

    let node = client.node(0).await;
    assert_eq!(
        node["attempts"].as_i64(),
        Some(1),
        "twenty runs and one submit is one attempt on the node"
    );
    let summary = client.ok("stats.summary", json!({})).await;
    assert_eq!(summary["attempts"].as_i64(), Some(1));
    assert_eq!(summary["accuracy"].as_f64(), Some(0.0));

    let stats = client.ok("stats.mistakes", json!({})).await;
    assert_eq!(
        stats["mistakes"][0]["count"].as_i64(),
        Some(21),
        "the curriculum must remember all twenty-one: {stats}"
    );
    // Every one of the twenty-one is in the player's own history.
    let history = client.ok("stats.history", json!({ "limit": 100 })).await;
    let modes: Vec<&str> = history["attempts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["mode"].as_str().unwrap())
        .collect();
    assert_eq!(modes.len(), 21);
    assert_eq!(modes.iter().filter(|m| **m == "submit").count(), 1);
    server.handle.abort();
}

/// PROTOCOL §3.2, widened: runs and submits share the one-execution slot.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_and_a_submit_share_the_busy_slot() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login().await;

    let body = json!({
        "quest_id": "rust.basic.01.hello", "lang": "rust", "source": HELLO
    });
    for (id, kind) in [("x-1", "quest.run"), ("x-2", "quest.submit")] {
        client
            .socket
            .send(Message::text(
                json!({ "v": 1, "id": id, "type": kind, "payload": body }).to_string(),
            ))
            .await
            .unwrap();
    }

    let mut seen = std::collections::HashMap::new();
    while seen.len() < 2 {
        let message =
            tokio::time::timeout(std::time::Duration::from_secs(120), client.socket.next())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
        let Message::Text(text) = message else {
            continue;
        };
        let value: Value = serde_json::from_str(&text).unwrap();
        if let Some(id) = value["id"].as_str() {
            seen.insert(id.to_string(), value.clone());
        }
    }
    assert_eq!(
        seen["x-2"]["payload"]["code"].as_str(),
        Some("busy"),
        "a submit started while a run was in flight: {:?}",
        seen["x-2"]
    );
    assert_eq!(seen["x-1"]["type"].as_str(), Some("quest.run.ok"));
    server.handle.abort();
}

/// A run that compiles cleanly does **not** retire a mistake kind from the
/// weakness drill. Reasoning in docs/decisions.md: evidence that you still
/// make a mistake counts whoever produced it, but evidence that you have
/// stopped should cost something, and pressing RUN five times is not that.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_clean_run_does_not_advance_cleared_since() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login().await;

    client
        .execute("quest.submit", "rust.basic.01.hello", BROKEN)
        .await;
    let before = client.ok("stats.mistakes", json!({})).await;
    assert_eq!(before["mistakes"][0]["cleared_since"].as_i64(), Some(0));

    for _ in 0..6 {
        client
            .execute("quest.run", "rust.basic.01.hello", HELLO)
            .await;
    }
    let after = client.ok("stats.mistakes", json!({})).await;
    assert_eq!(
        after["mistakes"][0]["cleared_since"].as_i64(),
        Some(0),
        "six clean runs retired a kind the player has not proved anything about"
    );

    // A clean submit does advance it.
    client
        .execute("quest.submit", "rust.basic.01.hello", HELLO)
        .await;
    let after = client.ok("stats.mistakes", json!({})).await;
    assert_eq!(after["mistakes"][0]["cleared_since"].as_i64(), Some(1));
    server.handle.abort();
}

/// The reward loop (PROTOCOL §4.20). A clear fires the stamp *and* whatever it
/// earned, and the shelf remembers it afterwards.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_clear_earns_something_and_the_shelf_remembers() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login().await;

    assert!(
        client.ok("stats.awards", json!({})).await["awards"]
            .as_array()
            .unwrap()
            .is_empty(),
        "a fresh player's shelf is empty"
    );

    client
        .execute("quest.submit", "rust.basic.01.hello", HELLO)
        .await;

    let awarded: Vec<(String, String)> = client
        .events
        .iter()
        .filter(|e| e["type"] == "award")
        .map(|e| {
            (
                e["payload"]["kind"].as_str().unwrap().to_string(),
                e["payload"]["id"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    assert!(
        awarded.contains(&("stamp".into(), "cleared".into())),
        "the node did not turn gold: {awarded:?}"
    );
    assert!(
        awarded.contains(&("badge".into(), "first-clear".into())),
        "a first clear earned no badge: {awarded:?}"
    );
    // A three-star clear on a difficulty-1 basic quest is 75 xp, and level 2
    // begins at 100 — so the first clear is a badge and not yet a level. That
    // is the curve doing its job rather than an oversight, and asserting it
    // here keeps the two in step.
    assert!(
        !awarded.iter().any(|(kind, _)| kind == "level"),
        "the first clear should not be a level-up at 75 xp: {awarded:?}"
    );

    // The shelf, for a client that missed the fanfare.
    let shelf = client.ok("stats.awards", json!({})).await;
    let ids: Vec<&str> = shelf["awards"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["id"].as_str().unwrap())
        .collect();
    assert!(ids.contains(&"first-clear"), "{shelf}");
    // The per-clear stamp is not on the shelf: it fires every time a node
    // turns gold, and is not something a player "has".
    assert!(!ids.contains(&"cleared"), "{shelf}");

    // Clearing it again earns nothing new.
    let before = shelf["awards"].as_array().unwrap().len();
    client.events.clear();
    client
        .execute("quest.submit", "rust.basic.01.hello", HELLO)
        .await;
    assert_eq!(
        client.ok("stats.awards", json!({})).await["awards"]
            .as_array()
            .unwrap()
            .len(),
        before,
        "a re-clear handed out a badge twice"
    );

    // And the user's level and xp travel with them.
    let user = client.ok("profile.update", json!({})).await["user"].clone();
    assert_eq!(user["xp"].as_i64(), Some(75), "{user}");
    assert_eq!(user["level"].as_i64(), Some(1));
    assert_eq!(user["xp_into_level"].as_i64(), Some(75));
    assert_eq!(user["xp_for_next"].as_i64(), Some(100));

    // The second clear — a difficulty-2 quest, so 150 xp — crosses it, and
    // the level-up is announced.
    client.events.clear();
    client
        .execute("quest.submit", "rust.basic.02.sum", SUM_SOLUTION)
        .await;
    let levels: Vec<&str> = client
        .events
        .iter()
        .filter(|e| e["type"] == "award" && e["payload"]["kind"] == "level")
        .map(|e| e["payload"]["id"].as_str().unwrap())
        .collect();
    assert_eq!(levels, vec!["level-2"], "{:?}", client.events);
    let user = client.ok("profile.update", json!({})).await["user"].clone();
    assert_eq!(user["xp"].as_i64(), Some(225));
    assert_eq!(user["level"].as_i64(), Some(2));
    server.handle.abort();
}

/// A RUN earns nothing. It is not a considered answer, and a badge for one
/// would make every other badge mean less.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_earns_nothing() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login().await;

    for _ in 0..3 {
        client
            .execute("quest.run", "rust.basic.01.hello", HELLO)
            .await;
    }
    assert!(
        !client.events.iter().any(|e| e["type"] == "award"),
        "a run fired an award"
    );
    assert!(client.ok("stats.awards", json!({})).await["awards"]
        .as_array()
        .unwrap()
        .is_empty());
    server.handle.abort();
}
