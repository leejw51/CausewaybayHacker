//! Behaviour over time, over the real wire.
//!
//! `tests/smoke/contract.mjs` proves the *protocol*: every frame is the right
//! shape and every rule in PROTOCOL.md §8 holds. `ws_flow.rs` proves the
//! slice runs once. What neither of them can show is what happens across
//! several submissions, several sessions and a restart — and that is where
//! the rules the player actually feels live.
//!
//! Four things are tested here and nowhere else:
//!
//! * **the star cascade** (SPEC §6.3) across *real* submissions. `store.rs`
//!   asserts `stars_for(failures, hints)` as a function and `record_clear` as
//!   a store call; neither drives the arithmetic through a compiler. A star
//!   rule that is right in `progress.rs` and wrong in the submit handler is
//!   invisible to both.
//! * **a hint costing a star**, likewise end to end. `stars_for(9, 2) == 2`
//!   is asserted in `store.rs`; that `quest.hint` over the wire changes the
//!   stamp the player gets is not asserted anywhere.
//! * **a restart**, with the server really torn down and brought back on the
//!   same home, and the session resumed with the token across it.
//!   `store.rs::a_clear_survives_a_restart_and_a_reimport` does this at the
//!   store level; the wire level adds the two things a player notices — the
//!   map still says `cleared`, and they are not asked for their mnemonic.
//! * **two users interleaved on one quest**, with the submissions genuinely
//!   concurrent rather than one after the other.
//!
//! Deliberately **not** repeated here, because it is already covered:
//! `a_clear_reaches_the_users_other_window` (protocol.rs), the locked→open
//! cascade at the store level and the two-user store isolation (store.rs),
//! the whole first-clear slice (ws_flow.rs).

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

use cwbhacker_core::{content, eth, Store};

const PACK: &str = include_str!("../../core/tests/fixtures/rust_basic.toml");

/// Published test keys. Both guard nothing; the first is the one
/// `eth-account` uses for this repo's EIP-191 vectors.
const ALICE_KEY: &str = "4646464646464646464646464646464646464646464646464646464646464646";
const BOB_KEY: &str = "1111111111111111111111111111111111111111111111111111111111111111";

const HELLO: &str = "rust.basic.01.hello";
const SUM: &str = "rust.basic.02.sum";
const SHADOWING: &str = "rust.basic.03.shadowing";

// ------------------------------------------------------------------ client

struct Client {
    socket: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    next_id: u32,
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
        self.socket
            .send(Message::text(
                json!({ "v": 1, "id": id, "type": kind, "payload": payload }).to_string(),
            ))
            .await
            .expect("send");
        loop {
            let message =
                tokio::time::timeout(std::time::Duration::from_secs(180), self.socket.next())
                    .await
                    .expect("the server answered within three minutes")
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

    /// Returns **the address the server echoed**, not the one that was
    /// claimed. `eth::address_from_pubkey` gives the lowercase storage form
    /// (SPEC §3.4) while the wire carries EIP-55 in both directions
    /// (PROTOCOL.md §2.4), and a test that compared its own spelling against
    /// a later reply would be asserting its own helper rather than the
    /// server. That mistake cost an hour once; hence this comment.
    async fn login(&mut self, key_hex: &str) -> (String, String) {
        let key = signing_key(key_hex);
        let claimed = eth::address_from_pubkey(key.verifying_key());
        let challenge = self
            .ok("auth.challenge", json!({ "address": claimed }))
            .await;
        let signature = sign(&key, challenge["message"].as_str().unwrap());
        let login = self
            .ok(
                "auth.login",
                json!({ "address": claimed, "signature": signature }),
            )
            .await;
        (
            login["user"]["address"].as_str().unwrap().to_string(),
            login["token"].as_str().unwrap().to_string(),
        )
    }

    /// Submit and return the `Attempt`.
    async fn submit(&mut self, quest: &str, source: &str) -> Value {
        self.ok(
            "quest.submit",
            json!({ "quest_id": quest, "lang": "rust", "source": source }),
        )
        .await["attempt"]
            .clone()
    }

    /// The map node for one quest, as this session sees it.
    async fn node(&mut self, quest: &str) -> Value {
        let map = self
            .ok("world.map", json!({ "land": "rust", "category": "basic" }))
            .await;
        map["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["quest_id"].as_str() == Some(quest))
            .unwrap_or_else(|| panic!("no node {quest} on the map"))
            .clone()
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

// ------------------------------------------------------------------ server

struct Server {
    port: u16,
    handle: tokio::task::JoinHandle<()>,
    shutdown: tokio::sync::oneshot::Sender<()>,
}

impl Server {
    /// Put it down the way a `^C` does, and wait until the port is actually
    /// free. A "restart" that left the old task serving would prove nothing.
    async fn stop(self) {
        let _ = self.shutdown.send(());
        let _ = tokio::time::timeout(std::time::Duration::from_secs(10), self.handle).await;
    }
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
    let (tx, rx) = tokio::sync::oneshot::channel::<()>();
    let handle = tokio::spawn(async move {
        let _ = axum::serve(listener, app)
            .with_graceful_shutdown(async {
                let _ = rx.await;
            })
            .await;
    });
    Server {
        port,
        handle,
        shutdown: tx,
    }
}

fn content_src(root: &std::path::Path) -> std::path::PathBuf {
    let dir = root.join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), PACK).unwrap();
    root.join("content-src")
}

fn quest_field(id: &str, field: &str) -> String {
    let pack: toml::Value = toml::from_str(PACK).unwrap();
    pack["quest"]
        .as_array()
        .unwrap()
        .iter()
        .find(|q| q["id"].as_str() == Some(id))
        .unwrap_or_else(|| panic!("the fixture has no {id}"))[field]
        .as_str()
        .unwrap()
        .to_string()
}

/// A source that compiles and runs but prints the wrong thing, so a failure
/// is a `wrong_answer` and not a `compile_error`. The distinction matters
/// here: both count as a failed attempt for the star arithmetic, and a test
/// that only ever produced compile errors would not notice if one of them
/// stopped counting.
fn wrong_but_valid(tag: &str) -> String {
    format!("fn main() {{ println!(\"not the answer: {tag}\"); }}")
}

// ------------------------------------------------------- the star cascade

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_star_cascade_matches_the_spec_across_real_submissions() {
    // SPEC §6.3: "3 — cleared with no failed attempt and no hint; 2 —
    // cleared with hints or ≤2 failed attempts; 1 — cleared."
    //
    // One account, three quests, three different routes to a clear. Every
    // submission below is really compiled and really run, which is the whole
    // point: `stars_for` is already unit-tested, and a unit test cannot
    // notice a submit handler that counts attempts wrong, forgets to bump a
    // failure, or reads `hints_used` from the wrong row.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let src = content_src(tmp.path());
    let server = start(&home, &src).await;

    let mut alice = Client::connect(server.port).await;
    alice.login(ALICE_KEY).await;

    // ---- three stars: straight in, no failures, no hints -----------------
    let attempt = alice.submit(HELLO, &quest_field(HELLO, "solution")).await;
    assert_eq!(attempt["verdict"], "accepted");
    assert_eq!(attempt["cleared"], true, "the first clear");
    assert_eq!(
        attempt["stars"], 3,
        "a clean first clear is three stars (SPEC §6.3)"
    );
    assert_eq!(alice.node(HELLO).await["stars"], 3);

    // ---- two stars: two failures, then the answer ------------------------
    // §6.3's middle rung. Two is the boundary — "≤2 failed attempts" — so
    // this is the case that catches an off-by-one in either direction.
    for i in 0..2 {
        let failed = alice
            .submit(SUM, &wrong_but_valid(&format!("sum{i}")))
            .await;
        assert_eq!(failed["verdict"], "wrong_answer", "attempt {i}");
        assert_eq!(failed["cleared"], false);
        assert_eq!(failed["stars"], 0, "a failed attempt earns no stamp");
        assert_eq!(
            alice.node(SUM).await["state"],
            "open",
            "a failed attempt must not clear the node"
        );
    }
    let cleared = alice.submit(SUM, &quest_field(SUM, "solution")).await;
    assert_eq!(cleared["verdict"], "accepted");
    assert_eq!(cleared["cleared"], true);
    assert_eq!(
        cleared["stars"], 2,
        "two failures then a clear is two stars, not three and not one"
    );

    // ---- one star: three failures, then the answer -----------------------
    for i in 0..3 {
        let failed = alice
            .submit(SHADOWING, &wrong_but_valid(&format!("shadow{i}")))
            .await;
        assert_eq!(failed["verdict"], "wrong_answer", "attempt {i}");
    }
    let cleared = alice
        .submit(SHADOWING, &quest_field(SHADOWING, "solution"))
        .await;
    assert_eq!(cleared["cleared"], true);
    assert_eq!(
        cleared["stars"], 1,
        "three failures is past §6.3's ≤2 rung; one star"
    );

    // ---- and the stamp never goes backwards ------------------------------
    // Re-solving a cleared quest reports `accepted` with `cleared: false`
    // (PROTOCOL.md §5.4) and must not restamp the node at a lower grade —
    // nor at a higher one, which would let a player farm three stars by
    // re-submitting the answer they were shown.
    let again = alice.submit(HELLO, &quest_field(HELLO, "solution")).await;
    assert_eq!(again["verdict"], "accepted");
    assert_eq!(
        again["cleared"], false,
        "`cleared` answers 'did this submission just clear it', not 'is it cleared'"
    );
    assert_eq!(alice.node(HELLO).await["stars"], 3, "still three");

    let sloppy = alice.submit(SHADOWING, &wrong_but_valid("late")).await;
    assert_eq!(sloppy["verdict"], "wrong_answer");
    assert_eq!(
        alice.node(SHADOWING).await["state"],
        "cleared",
        "a cleared node never goes back (SPEC §0: stamped CLEARED, for good)"
    );
    assert_eq!(
        alice.node(SHADOWING).await["stars"],
        1,
        "and keeps its star"
    );

    // The summary agrees with the map, which is the thing the player reads.
    let summary = alice.ok("stats.summary", json!({})).await;
    assert_eq!(summary["cleared"], 3);
    assert_eq!(
        summary["stars"], 6,
        "3 + 2 + 1; a summary that disagrees with the map is worse than no summary"
    );

    server.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_hint_costs_a_star_and_is_not_charged_twice() {
    // SPEC §6.3 / PROTOCOL.md §4.10: "Taking a hint costs stars and is
    // permanent. Re-requesting a hint already taken does not cost again."
    //
    // `store.rs` asserts `stars_for(9, 2) == 2` — the arithmetic. What is
    // asserted here is the sentence a player would say: *I took a hint, so I
    // got two stars instead of three.* Nothing else in the suite connects
    // `quest.hint` to the stamp on the map.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let src = content_src(tmp.path());
    let server = start(&home, &src).await;

    let mut alice = Client::connect(server.port).await;
    alice.login(ALICE_KEY).await;

    let before = alice.ok("quest.get", json!({ "quest_id": HELLO })).await;
    assert_eq!(before["quest"]["hints_used"], 0);
    assert!(
        before["quest"]["hints_total"].as_i64().unwrap() >= 2,
        "the fixture quest has hints to take"
    );

    let hint = alice
        .ok("quest.hint", json!({ "quest_id": HELLO, "index": 0 }))
        .await;
    assert!(!hint["hint"].as_str().unwrap().is_empty());
    assert_eq!(hint["hints_used"], 1);

    // Asking again for the *same* hint is free.
    let again = alice
        .ok("quest.hint", json!({ "quest_id": HELLO, "index": 0 }))
        .await;
    assert_eq!(
        again["hints_used"], 1,
        "re-reading hint 0 charged for it a second time"
    );
    assert_eq!(again["hint"], hint["hint"], "and it is the same hint");

    // A clean clear — no failed attempt at all — which without the hint
    // would be three stars. That is what makes this test about the hint and
    // nothing else.
    let attempt = alice.submit(HELLO, &quest_field(HELLO, "solution")).await;
    assert_eq!(attempt["verdict"], "accepted");
    assert_eq!(attempt["cleared"], true);
    assert_eq!(
        attempt["stars"], 2,
        "a hint on an otherwise-perfect clear must cost the third star"
    );
    assert_eq!(alice.node(HELLO).await["stars"], 2);

    // And it is permanent: the hint count survives into the next session.
    let after = alice.ok("quest.get", json!({ "quest_id": HELLO })).await;
    assert_eq!(after["quest"]["hints_used"], 1);

    // A hint index past the end is `not_found`, not a panic and not an empty
    // string the quest panel would render as a blank box.
    let total = before["quest"]["hints_total"].as_i64().unwrap();
    let past = alice
        .call("quest.hint", json!({ "quest_id": HELLO, "index": total }))
        .await;
    assert_eq!(past["type"], "quest.hint.err");
    assert_eq!(past["payload"]["code"], "not_found");

    server.stop().await;
}

// ------------------------------------------------------------ the restart

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cleared_quest_survives_the_server_being_put_down_and_brought_back() {
    // PLAN.md's definition of done for milestone 1, minus the browser:
    // "a human logs in with a mnemonic, clears a quest, kills the server,
    // restarts it, reloads the page and the quest is still cleared."
    //
    // `store.rs` proves the row survives. This proves the *player's* version
    // of that sentence: the map still says CLEARED, the stars are the same,
    // the history is still there — and they are not asked for their mnemonic
    // again, because the session token outlives the process (SPEC §3.3).
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let src = content_src(tmp.path());

    let token;
    let address;
    {
        let server = start(&home, &src).await;
        let mut alice = Client::connect(server.port).await;
        let (addr, tok) = alice.login(ALICE_KEY).await;
        address = addr;
        token = tok;

        // One failure and then a clear, so there is a star grade worth
        // checking rather than the default.
        alice.submit(HELLO, &wrong_but_valid("before")).await;
        let cleared = alice.submit(HELLO, &quest_field(HELLO, "solution")).await;
        assert_eq!(cleared["cleared"], true);
        assert_eq!(cleared["stars"], 2, "one failure, so two stars");
        assert_eq!(alice.node(SUM).await["state"], "open", "node 2 unlocked");

        server.stop().await;
    }

    // The whole process is gone: a new store, a new listener, a new port.
    // Only the home directory is the same, which is the only thing that is
    // supposed to carry state (SPEC §1).
    let server = start(&home, &src).await;
    let mut alice = Client::connect(server.port).await;

    // §3.3: the token buys a session back with no key material. If this
    // fails the player is asked for their mnemonic every time the server
    // restarts, which during development is every few minutes.
    let resumed = alice.ok("auth.resume", json!({ "token": token })).await;
    assert_eq!(
        resumed["user"]["address"].as_str(),
        Some(address.as_str()),
        "the resumed session is the same player"
    );
    let new_token = resumed["token"].as_str().unwrap().to_string();
    assert!(!new_token.is_empty(), "§4.4: a token comes back");

    let node = alice.node(HELLO).await;
    assert_eq!(node["state"], "cleared", "the clear did not survive");
    assert_eq!(node["stars"], 2, "the grade did not survive");
    assert_eq!(
        alice.node(SUM).await["state"],
        "open",
        "the unlock did not survive; the player is locked out of their own map"
    );

    // The attempts are training data (SPEC §7) and are never thrown away.
    let history = alice.ok("stats.history", json!({ "limit": 50 })).await;
    let rows = history["attempts"].as_array().unwrap();
    assert_eq!(
        rows.len(),
        2,
        "both the failure and the clear should still be on record, got {rows:?}"
    );
    assert!(
        rows.iter().any(|a| a["verdict"] == "wrong_answer"),
        "the failed attempt is the curriculum; losing it loses the lesson"
    );

    let mistakes = alice.ok("stats.mistakes", json!({})).await;
    assert!(
        !mistakes["mistakes"].as_array().unwrap().is_empty(),
        "the mistake from before the restart is gone"
    );

    // And the rotated token from the resume is the live one.
    let mut second = Client::connect(server.port).await;
    let again = second
        .ok("auth.resume", json!({ "token": new_token }))
        .await;
    assert_eq!(again["user"]["address"].as_str(), Some(address.as_str()));

    server.stop().await;
}

// -------------------------------------------------- the unlock cascade

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn clearing_a_node_unlocks_exactly_the_next_one_and_announces_it() {
    // SPEC §12: "`requires` empty means the node is open from the start.
    // Every other node is `locked` until all of its `requires` are
    // `cleared`." PROTOCOL.md §4.19: `progress.update` carries `unlocked`,
    // "so a client updates the overworld without refetching it".
    //
    // `store.rs` has the store-level cascade. What is added here is the
    // event: a client that trusted `unlocked` and a server that computed it
    // wrong would draw a map with the wrong nodes lit, and the only way to
    // see that is to compare the event against the map it claims to describe.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let src = content_src(tmp.path());
    let server = start(&home, &src).await;

    let mut alice = Client::connect(server.port).await;
    alice.login(ALICE_KEY).await;

    // At the start: node 1 open, the rest locked. Anything else and a new
    // player either cannot start or is handed the whole map.
    let map = alice
        .ok("world.map", json!({ "land": "rust", "category": "basic" }))
        .await;
    let nodes = map["nodes"].as_array().unwrap().clone();
    assert!(nodes.len() >= 3, "the fixture map has three nodes");
    for n in &nodes {
        let expected = if n["node"] == 1 { "open" } else { "locked" };
        assert_eq!(
            n["state"], expected,
            "node {} should start {expected}",
            n["node"]
        );
    }

    // A locked node refuses a submission rather than judging it — and names
    // the blocker, so the client can say *which* street to clear first.
    let locked = alice
        .call(
            "quest.submit",
            json!({ "quest_id": SHADOWING, "lang": "rust", "source": "fn main(){}" }),
        )
        .await;
    assert_eq!(locked["type"], "quest.submit.err");
    assert_eq!(locked["payload"]["code"], "locked");
    assert_eq!(
        locked["payload"]["detail"]["requires"],
        json!([SUM]),
        "`locked` must name what is blocking it"
    );

    // Clear node 1. The event should announce node 2 and nothing else.
    alice.events.clear();
    let attempt = alice.submit(HELLO, &quest_field(HELLO, "solution")).await;
    assert_eq!(attempt["cleared"], true);

    let update = alice
        .events
        .iter()
        .find(|e| e["type"] == "progress.update")
        .unwrap_or_else(|| panic!("no progress.update; events were {:?}", alice.events))
        .clone();
    assert_eq!(update["id"], Value::Null, "§2.2: an event carries id: null");
    assert_eq!(update["payload"]["quest_id"], HELLO);
    assert_eq!(update["payload"]["state"], "cleared");
    assert_eq!(update["payload"]["cleared_total"], 1);
    assert_eq!(
        update["payload"]["unlocked"],
        json!([SUM]),
        "clearing node 1 unlocks node 2 and only node 2; node 3 still needs node 2"
    );

    // The map agrees with the event it just sent. These are computed by
    // different code paths and a client trusts both.
    let after = alice
        .ok("world.map", json!({ "land": "rust", "category": "basic" }))
        .await;
    let by_node: Vec<(i64, String)> = after["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| {
            (
                n["node"].as_i64().unwrap(),
                n["state"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    assert_eq!(
        by_node,
        vec![
            (1, "cleared".into()),
            (2, "open".into()),
            (3, "locked".into())
        ],
        "the map does not match the unlock the server just announced"
    );

    // And the last one: clearing node 2 opens node 3 and the map is finished.
    alice.events.clear();
    alice.submit(SUM, &quest_field(SUM, "solution")).await;
    let update = alice
        .events
        .iter()
        .find(|e| e["type"] == "progress.update")
        .expect("a second progress.update")
        .clone();
    assert_eq!(update["payload"]["unlocked"], json!([SHADOWING]));
    assert_eq!(update["payload"]["cleared_total"], 2);

    alice
        .submit(SHADOWING, &quest_field(SHADOWING, "solution"))
        .await;
    let lands = alice.ok("world.lands", json!({})).await;
    let basic = lands["lands"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["land"] == "rust")
        .unwrap()["categories"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["category"] == "basic")
        .unwrap()
        .clone();
    assert_eq!(basic["cleared"], basic["total"], "the map is finished");

    server.stop().await;
}

// ------------------------------------------------- two users, one quest

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_players_on_one_quest_at_the_same_time_stay_separate() {
    // SPEC §9.8 and §3.5. `store.rs` proves the queries filter by address;
    // `contract.mjs` proves it over the wire with two sessions. What is added
    // here is genuine *concurrency* — both submissions in the compiler at
    // once, which is where a shared workdir, a cached binary keyed by quest
    // rather than by attempt, or a `last_attempt` field on the wrong struct
    // would show up.
    //
    // The failure this catches is the worst kind: alice's correct answer
    // clearing bob's node, or bob's compile error landing in alice's
    // curriculum. Both look like the program working, right up until two
    // people use it.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let src = content_src(tmp.path());
    let server = start(&home, &src).await;

    let mut alice = Client::connect(server.port).await;
    let mut bob = Client::connect(server.port).await;
    let (alice_addr, _) = alice.login(ALICE_KEY).await;
    let (bob_addr, _) = bob.login(BOB_KEY).await;
    assert_ne!(alice_addr, bob_addr, "two different wallets");

    let right = quest_field(HELLO, "solution");
    let wrong = wrong_but_valid("bob");
    // Not `join!` on two `&mut` borrows of one client — two clients, two
    // sockets, two futures, genuinely in flight together.
    let (a, b) = tokio::join!(alice.submit(HELLO, &right), bob.submit(HELLO, &wrong));

    assert_eq!(a["verdict"], "accepted", "alice's answer was correct");
    assert_eq!(b["verdict"], "wrong_answer", "bob's was not");
    assert_ne!(a["id"], b["id"], "two attempts, two ids");
    assert_eq!(a["cleared"], true);
    assert_eq!(b["cleared"], false);

    // The map: alice cleared it, bob did not.
    assert_eq!(alice.node(HELLO).await["state"], "cleared");
    assert_eq!(
        bob.node(HELLO).await["state"],
        "open",
        "bob's node went cleared on alice's work"
    );
    assert_eq!(
        bob.node(SUM).await["state"],
        "locked",
        "bob's node 2 unlocked on alice's clear"
    );

    // History does not cross, in both directions.
    let a_ids: Vec<String> = alice.ok("stats.history", json!({ "limit": 50 })).await["attempts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x["id"].as_str().unwrap().to_string())
        .collect();
    let b_ids: Vec<String> = bob.ok("stats.history", json!({ "limit": 50 })).await["attempts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x["id"].as_str().unwrap().to_string())
        .collect();
    let a_id = a["id"].as_str().unwrap().to_string();
    let b_id = b["id"].as_str().unwrap().to_string();
    assert!(a_ids.contains(&a_id), "alice cannot see her own attempt");
    assert!(b_ids.contains(&b_id), "bob cannot see his own attempt");
    assert!(!a_ids.contains(&b_id), "alice can see bob's attempt");
    assert!(!b_ids.contains(&a_id), "bob can see alice's attempt");

    // Mistakes do not cross. Bob earned one; alice earned none.
    let a_mistakes = alice.ok("stats.mistakes", json!({})).await["mistakes"]
        .as_array()
        .unwrap()
        .len();
    let b_mistakes = bob.ok("stats.mistakes", json!({})).await["mistakes"]
        .as_array()
        .unwrap()
        .len();
    assert_eq!(
        a_mistakes, 0,
        "alice cleared it first time and has a mistake anyway — whose?"
    );
    assert!(b_mistakes > 0, "bob's wrong answer produced no mistake row");

    // And on disk (SPEC §1): one directory per address, and neither holds
    // the other's work. This is the half `contract.mjs` cannot see, because
    // the filesystem is not on the wire.
    let users = home.join("users");
    // SPEC §3.4: the directory name is the lowercase form, whatever the wire
    // spells it.
    let alice_dir = users.join(alice_addr.to_lowercase()).join("attempts");
    let bob_dir = users.join(bob_addr.to_lowercase()).join("attempts");
    assert!(
        alice_dir.join(&a_id).is_dir(),
        "alice's attempt is not filed under alice"
    );
    assert!(
        bob_dir.join(&b_id).is_dir(),
        "bob's attempt is not filed under bob"
    );
    assert!(
        !alice_dir.join(&b_id).exists(),
        "bob's attempt is in alice's directory"
    );
    assert!(
        !bob_dir.join(&a_id).exists(),
        "alice's attempt is in bob's directory"
    );

    server.stop().await;
}

// ------------------------------------------- SPEC §9.6.h, the server half

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_submission_that_times_out_is_still_recorded() {
    // PROTOCOL.md §4.9: "A submission is **always recorded**, including a
    // compile error, including a timeout. That is the curriculum (SPEC §7)."
    //
    // `tests/PLAN.md` §9.6.h. The runner's half — a timeout coming back as a
    // filled-in report rather than an internal error — is in
    // `backend/runner/tests/limits.rs`. This is the half that matters to the
    // player: the attempt reaches their record, so the next thing they see is
    // "you have timed out three times on this quest" rather than silence.
    //
    // The quest's own `timeout_ms` is 5 s, so this test costs that plus a
    // compile. It is worth it: a timeout that is silently dropped is a hole
    // in the training data that nothing else would find.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let src = content_src(tmp.path());
    let server = start(&home, &src).await;

    let mut alice = Client::connect(server.port).await;
    alice.login(ALICE_KEY).await;

    let attempt = alice
        .submit(HELLO, "fn main() { loop { std::hint::spin_loop(); } }")
        .await;
    assert_eq!(attempt["verdict"], "timeout");
    assert_eq!(attempt["cleared"], false);
    assert_eq!(alice.node(HELLO).await["state"], "open", "still to do");

    let history = alice
        .ok("stats.history", json!({ "quest_id": HELLO }))
        .await;
    let rows = history["attempts"].as_array().unwrap();
    assert_eq!(rows.len(), 1, "the timeout was not recorded at all");
    assert_eq!(rows[0]["verdict"], "timeout");
    assert_eq!(
        rows[0]["id"], attempt["id"],
        "the recorded attempt is the one that just ran"
    );

    // And a compile error, the other verdict §4.9 calls out by name.
    let broken = alice
        .submit(HELLO, "fn main() { let x: i32 = \"nope\"; }")
        .await;
    assert_eq!(broken["verdict"], "compile_error");
    assert!(
        !broken["mistakes"].as_array().unwrap().is_empty(),
        "a compile error with no classified mistake teaches nothing (SPEC §7.1)"
    );
    let kinds: Vec<&str> = broken["mistakes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["kind"].as_str().unwrap())
        .collect();
    assert!(
        kinds.contains(&"type-mismatch"),
        "E0308 should classify as type-mismatch, got {kinds:?}"
    );

    let history = alice
        .ok("stats.history", json!({ "quest_id": HELLO }))
        .await;
    assert_eq!(
        history["attempts"].as_array().unwrap().len(),
        2,
        "both the timeout and the compile error are on record"
    );

    server.stop().await;
}

// ------------------------------------------------------ the address spelling

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_reply_spells_the_address_the_same_way() {
    // PROTOCOL.md §2.4: "Addresses: **EIP-55 checksummed** on the wire, in
    // both directions." §5.1: `User.address` is "EIP-55 checksummed".
    //
    // SPEC §3.4 explains why it is worth a test of its own: "Two spellings of
    // one wallet must never become two players." A client that compares the
    // address it got from `auth.login` against the one it got from
    // `auth.resume` is doing exactly what §3.4 warns about, and a mismatch
    // there is the login screen telling somebody they are not themselves.
    //
    // Three places the same address arrives, deliberately including one
    // after a restart — because that is when the server stops having the
    // string the client sent and has to read it back out of the `users`
    // table, where the primary key is the *lowercase* form.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let src = content_src(tmp.path());

    // `address_from_pubkey` gives the lowercase storage form (SPEC §3.4);
    // `to_eip55` is the display form that goes on the wire.
    let lower = eth::address_from_pubkey(signing_key(ALICE_KEY).verifying_key());
    let checksummed = eth::to_eip55(&lower);
    assert_ne!(
        checksummed, lower,
        "this key's address has mixed case, so the test can tell the two apart"
    );

    let mut token;
    {
        let server = start(&home, &src).await;
        let mut alice = Client::connect(server.port).await;
        let (from_login, tok) = alice.login(ALICE_KEY).await;
        token = tok;
        assert_eq!(from_login, checksummed, "auth.login");

        // A resume inside the same process, before anything is reloaded.
        // §4.4 rotates the token on use, so the one that comes back is the
        // one that has to be carried forward — the sent one is now dead.
        let mut second = Client::connect(server.port).await;
        let resumed = second.ok("auth.resume", json!({ "token": token })).await;
        token = resumed["token"].as_str().unwrap().to_string();
        assert_eq!(
            resumed["user"]["address"].as_str(),
            Some(checksummed.as_str()),
            "auth.resume in the same process"
        );

        // And after a profile write, which re-reads the row.
        let updated = second
            .ok("profile.update", json!({ "name": "ferris" }))
            .await;
        assert_eq!(
            updated["user"]["address"].as_str(),
            Some(checksummed.as_str()),
            "profile.update"
        );

        server.stop().await;
    }

    // The one that matters: a new process, so the user is read from the
    // database rather than remembered from the login that created it.
    let server = start(&home, &src).await;
    let mut alice = Client::connect(server.port).await;
    let resumed = alice.ok("auth.resume", json!({ "token": token })).await;
    assert_eq!(
        resumed["user"]["address"].as_str(),
        Some(checksummed.as_str()),
        "auth.resume after a restart spells the address differently from \
         auth.login. PROTOCOL.md §2.4 says EIP-55 in both directions, and \
         `users.address` is the lowercase primary key (SPEC §3.4) — the \
         checksummed form lives in `users.address_eip55`."
    );

    server.stop().await;
}
