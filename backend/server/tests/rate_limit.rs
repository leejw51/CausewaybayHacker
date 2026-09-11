//! PROTOCOL §3.3 `rate_limited` — the code that was in the closed set and that
//! nothing ever emitted.
//!
//! A reviewer's 120 rapid requests produced none, because the only cap in the
//! server was PROTOCOL §3.2's one-execution slot, which is **per connection**:
//! two sockets were two compilers, an anonymous socket could mint a hundred
//! 120-second nonces, and `code.format` skips the slot by design so a loop of
//! it spawned `rustfmt` without bound. The server binds `0.0.0.0` and the
//! README says "many players, one server", so that is one client degrading
//! everyone's availability.
//!
//! Two kinds of test live here and both matter:
//!
//! * the limits fire, and say `retry_after_ms` when they do;
//! * **nothing a person can do reaches them.** That is the assertion that
//!   gets skipped and the one the design actually rests on: a trainer that
//!   tells a player to press RUN more slowly has failed at its only job.

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

use cwbhacker_core::{content, eth, Store};
use cwbhacker_server::limits;

const PACK: &str = include_str!("../../core/tests/fixtures/rust_basic.toml");
const ALICE_KEY: &str = "4646464646464646464646464646464646464646464646464646464646464646";

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct Server {
    port: u16,
    state: cwbhacker_server::Shared,
    handle: tokio::task::JoinHandle<()>,
    _tmp: tempfile::TempDir,
}

async fn start() -> Server {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), PACK).unwrap();

    let store = Arc::new(Store::open(&tmp.path().join("home")).unwrap());
    store.with_conn(|conn| {
        let report =
            content::import_dir(conn, store.home(), &tmp.path().join("content-src")).unwrap();
        assert!(report.failures.is_empty(), "{:?}", report.failures);
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let config = cwbhacker_server::Config {
        bind: listener.local_addr().unwrap(),
        static_dir: None,
        art_dir: None,
    };
    let state = cwbhacker_server::build_state(store, &config);
    let app = cwbhacker_server::router(state.clone());
    let handle = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    Server {
        port,
        state,
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

async fn next_json(socket: &mut Socket) -> Value {
    loop {
        let message = tokio::time::timeout(std::time::Duration::from_secs(60), socket.next())
            .await
            .expect("the server answered")
            .expect("the socket stayed open")
            .expect("a readable frame");
        match message {
            Message::Text(text) => return serde_json::from_str(&text).unwrap(),
            Message::Ping(_) | Message::Pong(_) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

/// One request, counted. The count is what the reader loop below drains.
async fn ask(socket: &mut Socket, kind: &str, payload: Value, n: &mut usize) {
    *n += 1;
    send(
        socket,
        json!({ "v":1, "id": format!("p-{n}"), "type": kind, "payload": payload }),
    )
    .await;
}

async fn login(socket: &mut Socket) -> String {
    let key = k256::ecdsa::SigningKey::from_slice(&hex::decode(ALICE_KEY).unwrap()).unwrap();
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
    let reply = next_json(socket).await;
    assert_eq!(reply["type"].as_str(), Some("auth.login.ok"), "{reply}");
    address
}

/// The shape §3.3 promises, asserted once here so the other tests can just
/// name the code: `{code, message, detail}` and nothing else, with a
/// `retry_after_ms` a client can actually wait for.
fn assert_well_formed_rate_limit(reply: &Value) {
    assert_eq!(
        reply["payload"]["code"].as_str(),
        Some("rate_limited"),
        "{reply}"
    );
    let detail = &reply["payload"]["detail"];
    let retry = detail["retry_after_ms"].as_u64().unwrap_or_else(|| {
        panic!("§3.3: `rate_limited` carries detail.retry_after_ms — got {detail}")
    });
    assert!(
        retry > 0 && retry < 120_000,
        "a client has to be able to wait it out; got {retry} ms"
    );
    assert!(
        reply["payload"]["message"].is_string(),
        "the one-line English message is not optional"
    );
    let keys: Vec<&String> = reply["payload"].as_object().unwrap().keys().collect();
    assert_eq!(
        keys.len(),
        3,
        "an .err payload has exactly three keys: {keys:?}"
    );
}

// ------------------------------------------------------------------ it fires

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_tight_loop_on_one_connection_is_rate_limited() {
    let server = start().await;
    let mut socket = connect(server.port).await;

    // Well past the burst, and sent without waiting for answers, which is
    // exactly what an unattended script does.
    let attempts = (limits::REQUEST_BURST as usize) * 3;
    for i in 0..attempts {
        send(
            &mut socket,
            json!({ "v":1, "id": format!("c-{i}"), "type":"ping", "payload":{} }),
        )
        .await;
    }

    let mut limited = None;
    for _ in 0..attempts {
        let reply = next_json(&mut socket).await;
        if reply["payload"]["code"].as_str() == Some("rate_limited") {
            limited = Some(reply);
            break;
        }
    }
    let reply = limited.expect("720 requests in a row produced no `rate_limited`");
    assert_eq!(reply["type"].as_str(), Some("ping.err"));
    assert_well_formed_rate_limit(&reply);

    // And it is a refusal, not a close: §1.2 says an application error never
    // closes the connection.
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    send(
        &mut socket,
        json!({ "v":1, "id":"c-after", "type":"ping", "payload":{} }),
    )
    .await;
    let mut saw_ok = false;
    for _ in 0..attempts {
        let reply = next_json(&mut socket).await;
        if reply["id"].as_str() == Some("c-after") {
            saw_ok = reply["type"].as_str() == Some("ping.ok");
            break;
        }
    }
    assert!(saw_ok, "the connection did not recover after backing off");
    server.handle.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_loop_of_frames_the_server_cannot_parse_is_rate_limited_too() {
    // The paths that answer *before* the frame is understood are answers all
    // the same, and both of them keep the connection open: an unsupported `v`
    // by §2.1, and a frame too deeply nested by §3.3. A limit that sat below
    // them was not a limit — and the deep-frame path is new, so this is the
    // regression test for having opened it.
    let server = start().await;

    for probe in [
        // §2.1: answered `proto_version`, connection stays open.
        format!(r#"{{"v":99,"id":"{{i}}","type":"ping","payload":{{}}}}"#),
        // §3.3: answered `bad_request`, connection stays open.
        format!(
            r#"{{"v":1,"id":"{{i}}","type":"ping","payload":{}1{}}}"#,
            r#"{"a":"#.repeat(300),
            "}".repeat(300)
        ),
    ] {
        let mut socket = connect(server.port).await;
        let attempts = (limits::REQUEST_BURST as usize) * 2;
        for i in 0..attempts {
            socket
                .send(Message::text(probe.replace("{i}", &i.to_string())))
                .await
                .unwrap();
        }
        let mut limited = None;
        for _ in 0..attempts {
            let reply = next_json(&mut socket).await;
            if reply["payload"]["code"].as_str() == Some("rate_limited") {
                limited = Some(reply);
                break;
            }
        }
        assert_well_formed_rate_limit(
            &limited.expect("a loop of unparseable frames was answered without limit"),
        );
    }
    server.handle.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_anonymous_socket_cannot_mint_a_hundred_nonces() {
    // Each `auth.challenge` puts a nonce in memory for 120 seconds (SPEC
    // §3.2). A hundred of them from a socket that has not authenticated, and
    // never will, is the cheapest way to make the server hold something.
    let server = start().await;
    let mut socket = connect(server.port).await;
    let address = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";

    let mut ok = 0usize;
    let mut limited = None;
    for i in 0..100 {
        send(
            &mut socket,
            json!({ "v":1, "id": format!("n-{i}"), "type":"auth.challenge",
                    "payload": { "address": address } }),
        )
        .await;
        let reply = next_json(&mut socket).await;
        match reply["payload"]["code"].as_str() {
            Some("rate_limited") => {
                limited = Some(reply);
                break;
            }
            _ => ok += 1,
        }
    }
    let reply = limited.expect("a hundred challenges from one anonymous socket, all granted");
    assert_eq!(reply["type"].as_str(), Some("auth.challenge.err"));
    assert_well_formed_rate_limit(&reply);
    assert!(
        ok >= 10,
        "only {ok} challenges got through — a person retyping a mnemonic \
         would be refused a login"
    );
    server.handle.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_ninth_concurrent_compile_is_rate_limited_and_not_busy() {
    // PROTOCOL §3.2's slot is per connection, so this is the one a second
    // window does not answer. The gate is occupied directly rather than by
    // starting eight real compiles: the assertion is about the ceiling, and a
    // test that has to win a race against `rustc` is a test that fails on a
    // slow machine for no reason.
    let server = start().await;
    let held: Vec<_> = (0..limits::MAX_CONCURRENT_EXECUTIONS)
        .map(|_| server.state.executions.enter().expect("the gate was open"))
        .collect();
    assert!(
        server.state.executions.enter().is_none(),
        "the ceiling is {} and it was not reached",
        limits::MAX_CONCURRENT_EXECUTIONS
    );

    let mut socket = connect(server.port).await;
    login(&mut socket).await;
    send(
        &mut socket,
        json!({ "v":1, "id":"r-1", "type":"quest.run",
                "payload": { "quest_id": "rust.basic.01.hello",
                             "source": "fn main() { println!(\"hello\"); }" } }),
    )
    .await;
    let reply = next_json(&mut socket).await;
    assert_eq!(reply["type"].as_str(), Some("quest.run.err"), "{reply}");
    assert_well_formed_rate_limit(&reply);

    // The refusal must not have eaten this connection's own slot, or the
    // client is dead for the rest of the session.
    drop(held);
    send(
        &mut socket,
        json!({ "v":1, "id":"r-2", "type":"quest.run",
                "payload": { "quest_id": "rust.basic.01.hello",
                             "source": "fn main() { println!(\"hello\"); }" } }),
    )
    .await;
    loop {
        let reply = next_json(&mut socket).await;
        if reply["id"].as_str() == Some("r-2") {
            assert_eq!(
                reply["type"].as_str(),
                Some("quest.run.ok"),
                "the connection's own execution slot was never given back: {reply}"
            );
            break;
        }
    }
    server.handle.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_flood_of_formatters_is_capped() {
    // `code.format` skips the execution slot on purpose — pressing FORMAT
    // while a submit compiles is a normal thing to do — which is precisely
    // why a tight loop of it used to spawn `rustfmt` without bound.
    let server = start().await;
    let held: Vec<_> = (0..limits::MAX_CONCURRENT_FORMATS)
        .map(|_| server.state.formatters.enter().expect("the gate was open"))
        .collect();

    let mut socket = connect(server.port).await;
    login(&mut socket).await;
    send(
        &mut socket,
        json!({ "v":1, "id":"f-1", "type":"code.format",
                "payload": { "lang": "rust", "source": "fn main(){}" } }),
    )
    .await;
    let reply = next_json(&mut socket).await;
    assert_eq!(reply["type"].as_str(), Some("code.format.err"), "{reply}");
    assert_well_formed_rate_limit(&reply);

    drop(held);
    send(
        &mut socket,
        json!({ "v":1, "id":"f-2", "type":"code.format",
                "payload": { "lang": "rust", "source": "fn main(){}" } }),
    )
    .await;
    let reply = next_json(&mut socket).await;
    assert_eq!(
        reply["type"].as_str(),
        Some("code.format.ok"),
        "the formatter gate did not hand its passes back: {reply}"
    );
    server.handle.abort();
}

// ------------------------------------------------- and it does not fire at us

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn nothing_a_person_can_do_is_throttled() {
    // The assertion the numbers exist for. A client's whole startup fan-out,
    // then the map and a quest opened over and over the way somebody browsing
    // does, then RUN pressed as fast as a hand can press it — all inside one
    // connection, with no pause anywhere.
    //
    // If this ever fails, lower the limit is the *wrong* fix: raise it.
    let server = start().await;
    let mut socket = connect(server.port).await;
    login(&mut socket).await;

    let mut sent = 0usize;

    // Startup: everything a client asks for before it paints anything.
    for kind in [
        "world.lands",
        "stats.summary",
        "stats.awards",
        "playground.list",
    ] {
        ask(&mut socket, kind, json!({}), &mut sent).await;
    }
    // Thirty screen changes, four requests each: browsing the map for a
    // minute or two without ever stopping to read.
    for _ in 0..30 {
        ask(
            &mut socket,
            "world.map",
            json!({ "land": "rust", "category": "basic" }),
            &mut sent,
        )
        .await;
        ask(
            &mut socket,
            "quest.get",
            json!({ "quest_id": "rust.basic.01.hello" }),
            &mut sent,
        )
        .await;
        ask(&mut socket, "stats.summary", json!({}), &mut sent).await;
        ask(&mut socket, "stats.mistakes", json!({}), &mut sent).await;
    }
    // And a keepalive every 20 seconds is not special-cased, so it counts too.
    for _ in 0..20 {
        ask(&mut socket, "ping", json!({}), &mut sent).await;
    }

    for _ in 0..sent {
        let reply = next_json(&mut socket).await;
        assert_ne!(
            reply["payload"]["code"].as_str(),
            Some("rate_limited"),
            "a client's ordinary startup and browsing was throttled. The fix \
             is a bigger burst, not a slower client: {reply}"
        );
    }

    // Now RUN, pressed impatiently. Serialised, because §3.2 answers a second
    // one `busy` — which is the right refusal and not this one.
    for i in 0..6 {
        send(
            &mut socket,
            json!({ "v":1, "id": format!("run-{i}"), "type":"quest.run",
                    "payload": { "quest_id": "rust.basic.01.hello",
                                 "source": "fn main() { println!(\"hello\"); }" } }),
        )
        .await;
        loop {
            let reply = next_json(&mut socket).await;
            if reply["id"].as_str() == Some(&format!("run-{i}")) {
                assert_ne!(
                    reply["payload"]["code"].as_str(),
                    Some("rate_limited"),
                    "pressing RUN six times was throttled: {reply}"
                );
                break;
            }
        }
    }
    server.handle.abort();
}
