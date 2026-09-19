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
const GO_PACK: &str = include_str!("../../core/tests/fixtures/go_basic.toml");
const CPP_PACK: &str = include_str!("../../core/tests/fixtures/cpp_basic.toml");
const PYTHON_PACK: &str = include_str!("../../core/tests/fixtures/python_basic.toml");
const ALICE_KEY: &str = "4646464646464646464646464646464646464646464646464646464646464646";

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct Server {
    port: u16,
    handle: tokio::task::JoinHandle<()>,
    _tmp: tempfile::TempDir,
}

async fn start() -> Server {
    start_inner(false).await
}

/// The same, with a Go pack imported: the land exists in the content and
/// cannot be judged by this build.
async fn start_with_go() -> Server {
    start_inner(true).await
}

async fn start_inner(with_go: bool) -> Server {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("content-src/rust");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("basic.toml"), PACK).unwrap();
    if with_go {
        // The two newer lands ride along with Go: the tests that want a
        // second land want the same thing of a third and a fourth.
        for (land, pack) in [("go", GO_PACK), ("cpp", CPP_PACK), ("python", PYTHON_PACK)] {
            let dir = tmp.path().join("content-src").join(land);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("basic.toml"), pack).unwrap();
        }
    }

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

/// §2: `payload` is never absent. "Use `{}`" is an instruction, not a
/// suggestion — accepting a missing one is the same failure as ignoring an
/// unknown key, one frame later.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_absent_payload_is_refused() {
    let server = start().await;
    let mut socket = connect(server.port).await;
    send(&mut socket, json!({ "v":1, "id":"c-1", "type":"ping" })).await;
    let reply = next_json(&mut socket).await;
    assert_eq!(reply["type"].as_str(), Some("ping.err"), "{reply}");
    assert_eq!(reply["payload"]["code"].as_str(), Some("bad_request"));

    // With `{}` it works, and the connection never died in between.
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
    // A well-formed request right behind it, before the close is read. The
    // read loop used to keep dispatching after queueing the close, so this
    // was answered into a writer that had already hung up. Now the loop
    // stops with the close: the socket is closed and nothing else comes.
    let _ = socket
        .send(Message::text(
            json!({ "v":1, "id":"c-after", "type":"ping", "payload": {} }).to_string(),
        ))
        .await;
    match next(&mut socket).await {
        Message::Close(Some(frame)) => assert_eq!(u16::from(frame.code), 1003),
        other => panic!("expected a 1003 close, got {other:?}"),
    }
    // The socket is closed, or the read fails, or nothing comes — any of
    // those is the end. A text frame is the one thing that must not arrive.
    let after = tokio::time::timeout(std::time::Duration::from_secs(2), socket.next()).await;
    if let Ok(Some(Ok(Message::Text(text)))) = after {
        panic!("a frame after the close was answered: {text}");
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

/// A deeply nested but **valid** object is not a transport failure. It used to
/// be closed 1003, whose documented meaning is "a frame that is not a JSON
/// object" — and this is an object, so the close said something untrue. §3.3
/// prefers an application error for an application-level problem, so it is
/// `bad_request`, correlated, with the connection left open.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_frame_nested_three_hundred_deep_is_bad_request_and_not_a_close() {
    let server = start().await;
    let mut socket = connect(server.port).await;

    let deep = format!(
        r#"{{"v":1,"id":"c-deep","type":"ping","payload":{}1{}}}"#,
        r#"{"a":"#.repeat(300),
        "}".repeat(300)
    );
    // Sanity: the probe really is a well-formed object, and the only thing
    // wrong with it is its depth. serde says so itself — its complaint is the
    // recursion limit, not a syntax error — and without this assertion the
    // test could pass for the wrong reason.
    let complaint = serde_json::from_str::<Value>(&deep)
        .expect_err("serde refuses it")
        .to_string();
    assert!(
        complaint.contains("recursion limit exceeded"),
        "the probe is malformed for some other reason: {complaint}"
    );
    assert!(deep.starts_with('{') && deep.ends_with('}'));

    socket.send(Message::text(deep)).await.unwrap();
    let reply = next_json(&mut socket).await;
    assert_eq!(reply["type"].as_str(), Some("ping.err"), "{reply}");
    assert_eq!(reply["payload"]["code"].as_str(), Some("bad_request"));
    assert_eq!(
        reply["id"].as_str(),
        Some("c-deep"),
        "the id is salvaged from a frame serde could not parse"
    );

    // And the connection survives, which is the half a close got wrong.
    send(
        &mut socket,
        json!({ "v":1, "id":"c-after", "type":"ping", "payload":{} }),
    )
    .await;
    assert_eq!(
        next_json(&mut socket).await["type"].as_str(),
        Some("ping.ok"),
        "the connection did not survive a frame that was merely too deep"
    );
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

/// The Go land runs. Same wire, same verdict shape, same persistence as Rust —
/// the point of building it was that 30 of the 60 shipped quests were
/// unplayable.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_go_submission_is_compiled_run_and_recorded() {
    let server = start_with_go().await;
    let mut socket = connect(server.port).await;
    login(&mut socket).await;

    send(
        &mut socket,
        json!({ "v":1, "id":"c-5", "type":"quest.submit", "payload": {
            "quest_id": "go.basic.01.hello", "lang": "go",
            "source": "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"hello, causewaybay\")\n}\n" } }),
    )
    .await;

    let mut stages = Vec::new();
    let reply = loop {
        let frame = next_json(&mut socket).await;
        match frame["type"].as_str() {
            Some("run.stage") => {
                stages.push(frame["payload"]["stage"].as_str().unwrap().to_string())
            }
            Some("quest.submit.ok") => break frame,
            Some("quest.submit.err") => panic!("the Go land is built and this failed: {frame}"),
            _ => continue,
        }
    };
    let attempt = &reply["payload"]["attempt"];
    assert_eq!(attempt["verdict"].as_str(), Some("accepted"), "{attempt}");
    assert_eq!(attempt["cleared"].as_bool(), Some(true));
    assert_eq!(attempt["tests_passed"], attempt["tests_total"]);
    assert!(stages.contains(&"compiling".to_string()), "{stages:?}");

    // And it is in the record, which is what the drills read.
    send(
        &mut socket,
        json!({ "v":1, "id":"c-6", "type":"stats.history", "payload": {} }),
    )
    .await;
    let history = next_json(&mut socket).await;
    assert_eq!(
        history["payload"]["attempts"][0]["quest_id"].as_str(),
        Some("go.basic.01.hello")
    );
    server.handle.abort();
}

/// The C++ land runs: same wire, same verdict shape, same persistence.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cpp_submission_is_compiled_run_and_recorded() {
    let server = start_with_go().await;
    let mut socket = connect(server.port).await;
    login(&mut socket).await;

    send(
        &mut socket,
        json!({ "v":1, "id":"c-5", "type":"quest.submit", "payload": {
            "quest_id": "cpp.basic.01.hello", "lang": "cpp",
            "source": "#include <iostream>\nint main() { std::cout << \"hello, causewaybay\\n\"; }\n" } }),
    )
    .await;

    let mut stages = Vec::new();
    let reply = loop {
        let frame = next_json(&mut socket).await;
        match frame["type"].as_str() {
            Some("run.stage") => {
                stages.push(frame["payload"]["stage"].as_str().unwrap().to_string())
            }
            Some("quest.submit.ok") => break frame,
            Some("quest.submit.err") => panic!("the C++ land is built and this failed: {frame}"),
            _ => continue,
        }
    };
    let attempt = &reply["payload"]["attempt"];
    assert_eq!(attempt["verdict"].as_str(), Some("accepted"), "{attempt}");
    assert_eq!(attempt["cleared"].as_bool(), Some(true));
    assert_eq!(attempt["tests_passed"], attempt["tests_total"]);
    assert!(stages.contains(&"compiling".to_string()), "{stages:?}");

    send(
        &mut socket,
        json!({ "v":1, "id":"c-6", "type":"stats.history", "payload": {} }),
    )
    .await;
    let history = next_json(&mut socket).await;
    assert_eq!(
        history["payload"]["attempts"][0]["quest_id"].as_str(),
        Some("cpp.basic.01.hello")
    );
    server.handle.abort();
}

/// A C++ compile error reaches the player as the compiler's own prose and
/// reaches the table as §7.1's C++ column.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cpp_compile_error_is_classified_over_the_wire() {
    let server = start_with_go().await;
    let mut socket = connect(server.port).await;
    login(&mut socket).await;

    send(
        &mut socket,
        json!({ "v":1, "id":"c-5", "type":"quest.submit", "payload": {
            "quest_id": "cpp.basic.01.hello", "lang": "cpp",
            "source": "#include <iostream>\nint main() { std::cout << tolal; }\n" } }),
    )
    .await;
    let reply = loop {
        let frame = next_json(&mut socket).await;
        if frame["type"].as_str() == Some("quest.submit.ok") {
            break frame;
        }
    };
    let attempt = &reply["payload"]["attempt"];
    assert_eq!(
        attempt["verdict"].as_str(),
        Some("compile_error"),
        "{attempt}"
    );
    let kinds: Vec<&str> = attempt["mistakes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["kind"].as_str().unwrap())
        .collect();
    assert!(kinds.contains(&"unknown-name"), "{attempt}");
    assert_eq!(
        attempt["mistakes"][0]["code"].as_str(),
        Some("cpp:undeclared-identifier")
    );
    assert!(
        attempt["stderr"].as_str().unwrap().contains("tolal"),
        "the player should see what c++ said: {attempt}"
    );
    server.handle.abort();
}

/// The Python land runs: same wire, same verdict shape, same persistence.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_python_submission_is_run_and_recorded() {
    let server = start_with_go().await;
    let mut socket = connect(server.port).await;
    login(&mut socket).await;

    send(
        &mut socket,
        json!({ "v":1, "id":"c-5", "type":"quest.submit", "payload": {
            "quest_id": "python.basic.01.hello", "lang": "python",
            "source": "print(\"hello, causewaybay\")\n" } }),
    )
    .await;

    let mut stages = Vec::new();
    let reply = loop {
        let frame = next_json(&mut socket).await;
        match frame["type"].as_str() {
            Some("run.stage") => {
                stages.push(frame["payload"]["stage"].as_str().unwrap().to_string())
            }
            Some("quest.submit.ok") => break frame,
            Some("quest.submit.err") => panic!("the Python land is built and this failed: {frame}"),
            _ => continue,
        }
    };
    let attempt = &reply["payload"]["attempt"];
    assert_eq!(attempt["verdict"].as_str(), Some("accepted"), "{attempt}");
    assert_eq!(attempt["cleared"].as_bool(), Some(true));
    assert!(stages.contains(&"running".to_string()), "{stages:?}");

    send(
        &mut socket,
        json!({ "v":1, "id":"c-6", "type":"stats.history", "payload": {} }),
    )
    .await;
    let history = next_json(&mut socket).await;
    assert_eq!(
        history["payload"]["attempts"][0]["quest_id"].as_str(),
        Some("python.basic.01.hello")
    );
    server.handle.abort();
}

/// A Python runtime error is the traceback's last line, classified.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_python_runtime_error_is_classified_over_the_wire() {
    let server = start_with_go().await;
    let mut socket = connect(server.port).await;
    login(&mut socket).await;

    send(
        &mut socket,
        json!({ "v":1, "id":"c-5", "type":"quest.submit", "payload": {
            "quest_id": "python.basic.01.hello", "lang": "python",
            "source": "stall = None\nprint(stall.price)\n" } }),
    )
    .await;
    let reply = loop {
        let frame = next_json(&mut socket).await;
        if frame["type"].as_str() == Some("quest.submit.ok") {
            break frame;
        }
    };
    let attempt = &reply["payload"]["attempt"];
    assert_eq!(
        attempt["verdict"].as_str(),
        Some("runtime_error"),
        "{attempt}"
    );
    assert_eq!(
        attempt["mistakes"][0]["kind"].as_str(),
        Some("nil-deref"),
        "{attempt}"
    );
    assert_eq!(
        attempt["mistakes"][0]["code"].as_str(),
        Some("py:none-attribute")
    );
    assert!(
        attempt["stderr"].as_str().unwrap().contains("NoneType"),
        "the player should see the traceback: {attempt}"
    );
    server.handle.abort();
}

/// A Go compile error is classified by SPEC §7.1's Go column, which has no
/// error codes in it — the identity is made from the message's shape.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_go_compile_error_is_classified_over_the_wire() {
    let server = start_with_go().await;
    let mut socket = connect(server.port).await;
    login(&mut socket).await;

    send(
        &mut socket,
        json!({ "v":1, "id":"c-5", "type":"quest.submit", "payload": {
            "quest_id": "go.basic.01.hello", "lang": "go",
            "source": "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(tolal)\n}\n" } }),
    )
    .await;
    let reply = loop {
        let frame = next_json(&mut socket).await;
        if frame["type"].as_str() == Some("quest.submit.ok") {
            break frame;
        }
    };
    let attempt = &reply["payload"]["attempt"];
    assert_eq!(attempt["verdict"].as_str(), Some("compile_error"));
    let kinds: Vec<&str> = attempt["mistakes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["kind"].as_str().unwrap())
        .collect();
    assert!(kinds.contains(&"unknown-name"), "{attempt}");
    assert_eq!(
        attempt["mistakes"][0]["code"].as_str(),
        Some("go:undefined"),
        "the identity Go never gave us has to be made and kept"
    );
    assert!(
        attempt["stderr"].as_str().unwrap().contains("undefined"),
        "the player should see what go build said"
    );
    server.handle.abort();
}

/// A submission this build cannot judge is refused **before anything is
/// written**. An attempt row carries a verdict, a verdict carries mistakes,
/// and `mistake_stats` is what the drills teach from (SPEC §7) — a fabricated
/// entry there would teach the player to fix something they never did, and
/// afterwards there is no way to tell it from a real mistake.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_unjudgeable_submission_records_nothing() {
    let server = start_with_go().await;
    let mut socket = connect(server.port).await;
    login(&mut socket).await;

    // `go.basic.02.testing` declares the `cargo` harness on a Go quest, which
    // nothing will ever run. The language is fine; the harness is the gap.
    // The rule under test is what the server writes when it cannot judge —
    // which must be nothing — rather than which harness happens to be
    // unbuilt today.
    send(
        &mut socket,
        json!({ "v":1, "id":"c-5", "type":"quest.submit", "payload": {
            "quest_id": "go.basic.02.testing", "lang": "go",
            "source": "package main\n\nfunc main() {}\n" } }),
    )
    .await;
    let reply = next_json(&mut socket).await;
    assert_eq!(reply["type"].as_str(), Some("quest.submit.err"), "{reply}");
    assert_eq!(
        reply["payload"]["code"].as_str(),
        Some("unavailable"),
        "not `internal` — the server did not break — and not `not_found`: {reply}"
    );
    assert_eq!(reply["payload"]["detail"]["milestone"].as_i64(), Some(2));

    // Nothing was recorded: no attempt, no mistake, and the node's attempt
    // counter did not move.
    send(
        &mut socket,
        json!({ "v":1, "id":"c-6", "type":"stats.history", "payload": {} }),
    )
    .await;
    let history = next_json(&mut socket).await;
    assert!(
        history["payload"]["attempts"]
            .as_array()
            .unwrap()
            .is_empty(),
        "an unjudgeable submission left an attempt behind: {history}"
    );

    send(
        &mut socket,
        json!({ "v":1, "id":"c-7", "type":"stats.mistakes", "payload": {} }),
    )
    .await;
    let mistakes = next_json(&mut socket).await;
    assert!(mistakes["payload"]["mistakes"]
        .as_array()
        .unwrap()
        .is_empty());

    send(
        &mut socket,
        json!({ "v":1, "id":"c-8", "type":"world.map",
                "payload": { "land": "go", "category": "basic" } }),
    )
    .await;
    let map = next_json(&mut socket).await;
    assert_eq!(map["payload"]["nodes"][1]["attempts"].as_i64(), Some(0));

    // And the connection is fine — an application error is never a close.
    send(
        &mut socket,
        json!({ "v":1, "id":"c-9", "type":"ping", "payload": {} }),
    )
    .await;
    assert_eq!(
        next_json(&mut socket).await["type"].as_str(),
        Some("ping.ok")
    );
    server.handle.abort();
}
