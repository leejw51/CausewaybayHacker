//! The playground (PROTOCOL §4.9c).
//!
//! Two things are worth proving here and nowhere else: that a run leaves the
//! curriculum completely untouched, and that the limits still bite in the one
//! place a player can run genuinely arbitrary code.

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

use cwbhacker_core::{content, eth, Store};

const PACK: &str = include_str!("../../core/tests/fixtures/rust_basic.toml");
const ALICE_KEY: &str = "4646464646464646464646464646464646464646464646464646464646464646";
const BOB_KEY: &str = "1111111111111111111111111111111111111111111111111111111111111111";

const HELLO: &str = "fn main() { println!(\"hello, playground\"); }";
const BROKEN: &str = "fn main() { let s = String::from(\"x\"); let t = s; println!(\"{s}{t}\"); }";

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct Server {
    port: u16,
    handle: tokio::task::JoinHandle<()>,
    store: Arc<Store>,
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
    let state = cwbhacker_server::build_state(store.clone(), &config);
    let app = cwbhacker_server::router(state);
    let handle = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    Server {
        port,
        handle,
        store,
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
                tokio::time::timeout(std::time::Duration::from_secs(180), self.socket.next())
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

    async fn err(&mut self, kind: &str, payload: Value) -> String {
        let frame = self.call(kind, payload).await;
        assert_eq!(
            frame["type"].as_str(),
            Some(format!("{kind}.err").as_str()),
            "{frame}"
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
        address
    }

    async fn play(&mut self, source: &str, stdin: &str) -> Value {
        self.ok(
            "playground.run",
            json!({ "lang": "rust", "source": source, "stdin": stdin }),
        )
        .await["run"]
            .clone()
    }
}

fn table_counts(server: &Server) -> (i64, i64, i64, i64) {
    let conn = server.store.conn();
    let one = |sql: &str| conn.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
    (
        one("SELECT count(*) FROM attempts"),
        one("SELECT count(*) FROM mistakes"),
        one("SELECT count(*) FROM mistake_stats"),
        one("SELECT count(*) FROM progress"),
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_playground_run_prints_and_records_nothing() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login(ALICE_KEY).await;
    let before = table_counts(&server);

    let run = client.play(HELLO, "").await;
    assert_eq!(run["outcome"].as_str(), Some("ok"), "{run}");
    assert_eq!(run["stdout"].as_str(), Some("hello, playground\n"));
    assert!(run["attempt_id"].as_str().unwrap().starts_with("att_"));
    assert_eq!(run["lang"].as_str(), Some("rust"));

    // And it streamed, under the id it reported.
    let stages: Vec<&str> = client
        .events
        .iter()
        .filter(|e| e["type"] == "run.stage")
        .map(|e| e["payload"]["stage"].as_str().unwrap())
        .collect();
    assert!(stages.contains(&"compiling"), "{stages:?}");
    assert!(client
        .events
        .iter()
        .filter(|e| e["type"] == "run.stage" || e["type"] == "run.log")
        .all(|e| e["payload"]["attempt_id"] == run["attempt_id"]));

    assert_eq!(
        table_counts(&server),
        before,
        "a playground run touched attempts / mistakes / mistake_stats / progress"
    );
}

/// A broken scratchpad is shown its diagnostics and the curriculum never hears
/// about it. This is the opposite of `quest.run` on purpose (PROTOCOL §4.9c).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_broken_playground_run_is_diagnosed_but_never_recorded() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login(ALICE_KEY).await;
    let before = table_counts(&server);

    let run = client.play(BROKEN, "").await;
    assert_eq!(run["outcome"].as_str(), Some("compile_error"), "{run}");
    let kinds: Vec<&str> = run["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["kind"].as_str().unwrap())
        .collect();
    assert!(
        kinds.contains(&"borrow-after-move"),
        "the player should still be told what is wrong: {run}"
    );
    assert!(run["stderr"].as_str().unwrap().contains("borrow of moved"));

    assert_eq!(
        table_counts(&server),
        before,
        "a playground mistake reached the curriculum"
    );
    // Nor through the wire's own view of it.
    assert!(client.ok("stats.mistakes", json!({})).await["mistakes"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(client.ok("stats.history", json!({})).await["attempts"]
        .as_array()
        .unwrap()
        .is_empty());
    let summary = client.ok("stats.summary", json!({})).await;
    assert_eq!(summary["attempts"].as_i64(), Some(0));
    assert_eq!(summary["cleared"].as_i64(), Some(0));
    server.handle.abort();
}

/// SPEC §5.3 applies unchanged. This is the one place a player runs genuinely
/// arbitrary code, so it is the last place any of it may be relaxed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_limits_still_bite_in_the_playground() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login(ALICE_KEY).await;

    let spun = client
        .play("fn main() { loop { std::hint::spin_loop(); } }", "")
        .await;
    assert_eq!(spun["outcome"].as_str(), Some("timeout"), "{spun}");

    let flood = client
        .play(
            "fn main() { loop { println!(\"{}\", \"x\".repeat(4096)); } }",
            "",
        )
        .await;
    assert_eq!(flood["outcome"].as_str(), Some("output_limit"), "{flood}");
    assert!(
        flood["stdout"].as_str().unwrap().len() < 1_000_000,
        "the cap was applied after the fact"
    );

    // §5.3's environment: HOME points at the build directory and the rest is
    // stripped, so a program that goes looking finds the scratch and not the
    // player's home.
    let env = client
        .play(
            "fn main() { println!(\"{}\", std::env::var(\"HOME\").unwrap_or_default()); \
             println!(\"{:?}\", std::env::var(\"CARGO_HOME\")); }",
            "",
        )
        .await;
    let printed = env["stdout"].as_str().unwrap();
    assert!(
        printed.contains("/build/rust/att_"),
        "HOME was not pointed at the attempt's build directory: {printed}"
    );
    assert!(
        printed.contains("Err("),
        "the environment was not stripped: {printed}"
    );

    // And stdin reaches it.
    let echo = client
        .play(
            "fn main() { let mut s = String::new(); \
             std::io::stdin().read_line(&mut s).unwrap(); print!(\"got {s}\"); }",
            "ping\n",
        )
        .await;
    assert_eq!(echo["stdout"].as_str(), Some("got ping\n"));
    server.handle.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn snippets_save_load_list_and_delete() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login(ALICE_KEY).await;

    assert!(client.ok("playground.list", json!({})).await["snippets"]
        .as_array()
        .unwrap()
        .is_empty());

    let created = client
        .ok(
            "playground.save",
            json!({ "lang": "rust", "source": HELLO }),
        )
        .await["snippet"]
        .clone();
    let id = created["id"].as_str().unwrap().to_string();
    assert!(id.starts_with("pg_"));
    assert!(
        !created["name"].as_str().unwrap().is_empty(),
        "a nameless save is named from the date"
    );

    // §1: the player's own work is in the home, not only in the database.
    let dir = server.store.home().snippet_dir(
        &cwbhacker_core::eth::normalize_address(
            &client.ok("profile.update", json!({})).await["user"]["address"]
                .as_str()
                .unwrap()
                .to_string(),
        )
        .unwrap(),
        &id,
    );
    assert!(dir.join("main.rs").is_file(), "{}", dir.display());
    assert_eq!(std::fs::read_to_string(dir.join("main.rs")).unwrap(), HELLO);

    let listed = client.ok("playground.list", json!({})).await;
    assert_eq!(listed["snippets"].as_array().unwrap().len(), 1);
    assert_eq!(
        listed["snippets"][0]["bytes"].as_i64(),
        Some(HELLO.len() as i64)
    );
    assert!(
        listed["snippets"][0].get("source").is_none(),
        "a listing carries sizes, not a megabyte of code"
    );

    let loaded = client.ok("playground.load", json!({ "id": id })).await;
    assert_eq!(loaded["snippet"]["source"].as_str(), Some(HELLO));

    let renamed = client
        .ok(
            "playground.save",
            json!({ "id": id, "name": "borrow ideas", "lang": "rust", "source": BROKEN }),
        )
        .await;
    assert_eq!(renamed["snippet"]["name"].as_str(), Some("borrow ideas"));
    assert_eq!(renamed["snippet"]["source"].as_str(), Some(BROKEN));
    assert_eq!(
        std::fs::read_to_string(dir.join("main.rs")).unwrap(),
        BROKEN
    );

    client.ok("playground.delete", json!({ "id": id })).await;
    assert!(client.ok("playground.list", json!({})).await["snippets"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(!dir.exists(), "the file outlived the row");
    assert_eq!(
        client.err("playground.load", json!({ "id": id })).await,
        "not_found"
    );
    server.handle.abort();
}

/// `playground.save` is an autosave timer's message: saving byte-identical
/// content must not churn a new `updated_at`, or a list sorted by it jumps
/// about while nobody is typing.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_autosave_of_identical_content_does_not_churn() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login(ALICE_KEY).await;

    let first = client
        .ok(
            "playground.save",
            json!({ "lang": "rust", "source": HELLO, "name": "scratch" }),
        )
        .await["snippet"]
        .clone();
    let id = first["id"].as_str().unwrap().to_string();
    let stamp = first["updated_at"].as_str().unwrap().to_string();

    for _ in 0..5 {
        let again = client
            .ok(
                "playground.save",
                json!({ "id": id, "lang": "rust", "source": HELLO, "name": "scratch" }),
            )
            .await["snippet"]
            .clone();
        assert_eq!(
            again["updated_at"].as_str(),
            Some(stamp.as_str()),
            "an unchanged autosave wrote a new timestamp"
        );
    }

    // SPEC §2.2's timestamps have second granularity, so proving that a real
    // change *does* move `updated_at` means waiting out a second. Worth it:
    // without this half, "the timestamp never changes" would also pass.
    tokio::time::sleep(std::time::Duration::from_millis(1_100)).await;
    let changed = client
        .ok(
            "playground.save",
            json!({ "id": id, "lang": "rust", "source": BROKEN, "name": "scratch" }),
        )
        .await["snippet"]
        .clone();
    assert_ne!(
        changed["updated_at"].as_str(),
        Some(stamp.as_str()),
        "a real edit must move the timestamp, or the idempotence above is just a dead write path"
    );
    // Still one snippet: an update is not a create.
    assert_eq!(
        client.ok("playground.list", json!({})).await["snippets"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    server.handle.abort();
}

/// SPEC §3.5 again, for the scratchpad: a snippet id is sixteen random hex,
/// but guessing one must not be enough to read somebody's notes.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn one_player_cannot_reach_anothers_snippets() {
    let server = start().await;
    let mut alice = Client::connect(server.port).await;
    alice.login(ALICE_KEY).await;
    let mut bob = Client::connect(server.port).await;
    bob.login(BOB_KEY).await;

    let id = alice
        .ok(
            "playground.save",
            json!({ "lang": "rust", "source": HELLO, "name": "alice's" }),
        )
        .await["snippet"]["id"]
        .as_str()
        .unwrap()
        .to_string();

    assert!(bob.ok("playground.list", json!({})).await["snippets"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(
        bob.err("playground.load", json!({ "id": id })).await,
        "not_found"
    );
    assert_eq!(
        bob.err("playground.delete", json!({ "id": id })).await,
        "not_found"
    );
    // Bob's failed delete did not take it.
    assert_eq!(
        alice.ok("playground.load", json!({ "id": id })).await["snippet"]["name"].as_str(),
        Some("alice's")
    );
    server.handle.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_snippet_caps_are_enforced_with_a_reason() {
    let server = start().await;
    let mut client = Client::connect(server.port).await;
    client.login(ALICE_KEY).await;

    let huge = "x".repeat(cwbhacker_core::snippets::MAX_SNIPPET_BYTES + 1);
    let frame = client
        .call("playground.save", json!({ "lang": "rust", "source": huge }))
        .await;
    assert_eq!(frame["payload"]["code"].as_str(), Some("bad_request"));
    assert!(
        frame["payload"]["message"]
            .as_str()
            .unwrap()
            .contains("at most"),
        "the refusal should name the limit: {frame}"
    );
    server.handle.abort();
}
