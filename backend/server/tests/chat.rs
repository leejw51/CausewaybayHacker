//! The chatroom over the wire (PROTOCOL §4.9f) and its photos over HTTP.
//!
//! The one thing only an end-to-end test can prove is the seam: a photo goes
//! in as base64 on the socket and comes back out as bytes on a URL the reply
//! named, with the right content-type, to the holder of the token and to
//! nobody else.

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::tungstenite::Message;

use cwbhacker_core::{content, eth, Store};

const PACK: &str = include_str!("../../core/tests/fixtures/rust_basic.toml");
const ALICE_KEY: &str = "4646464646464646464646464646464646464646464646464646464646464646";
const BOB_KEY: &str = "1111111111111111111111111111111111111111111111111111111111111111";

/// A 1×1 PNG.
const PNG: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
    0x42, 0x60, 0x82,
];

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
}

impl Client {
    async fn connect(port: u16) -> Client {
        let (socket, _) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}/ws"))
            .await
            .unwrap();
        Client { socket, next_id: 0 }
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
                tokio::time::timeout(std::time::Duration::from_secs(30), self.socket.next())
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

    async fn new_pad(&mut self) -> String {
        self.ok(
            "playground.save",
            json!({ "lang": "rust", "source": "fn main() {}\n", "name": "chatty" }),
        )
        .await["snippet"]["id"]
            .as_str()
            .unwrap()
            .to_string()
    }
}

/// A plain HTTP/1.1 GET, by hand: the crate has no HTTP client among its
/// dev-dependencies and one request does not earn one. Returns the status,
/// the headers lowercased, and the body.
async fn http_get(port: u16, path: &str) -> (u16, Vec<(String, String)>, Vec<u8>) {
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .unwrap();
    stream
        .write_all(
            format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
                .as_bytes(),
        )
        .await
        .unwrap();
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).await.unwrap();
    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .expect("a header block");
    let head = String::from_utf8_lossy(&raw[..split]).to_string();
    let body = raw[split + 4..].to_vec();
    let mut lines = head.lines();
    let status: u16 = lines
        .next()
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse()
        .unwrap();
    let headers = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
        .collect();
    (status, headers, body)
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.as_str())
}

fn b64(bytes: &[u8]) -> String {
    // Standard alphabet with padding, written out so the test does not lean
    // on the crate the server decodes with.
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.len();
        let triple = (chunk[0] as u32) << 16
            | (*chunk.get(1).unwrap_or(&0) as u32) << 8
            | (*chunk.get(2).unwrap_or(&0) as u32);
        out.push(ALPHABET[(triple >> 18) as usize & 63] as char);
        out.push(ALPHABET[(triple >> 12) as usize & 63] as char);
        out.push(if n > 1 {
            ALPHABET[(triple >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if n > 2 {
            ALPHABET[triple as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_room_takes_text_and_a_photo_and_serves_the_photo_to_its_token() {
    let server = start().await;
    let mut alice = Client::connect(server.port).await;
    alice.login(ALICE_KEY).await;
    let id = alice.new_pad().await;

    assert!(
        alice.ok("playground.chat.list", json!({ "id": id })).await["messages"]
            .as_array()
            .unwrap()
            .is_empty()
    );

    let said = alice
        .ok(
            "playground.chat.post",
            json!({ "id": id, "role": "user", "text": "draw a crab on a keyboard",
                    "provider": "openai", "model": "gpt-4.1" }),
        )
        .await["message"]
        .clone();
    assert!(said["id"].as_str().unwrap().starts_with("msg_"));
    assert_eq!(said["kind"].as_str(), Some("text"));
    assert!(said["photo_url"].is_null());
    assert_eq!(said["provider"].as_str(), Some("openai"));

    let photo = alice
        .ok(
            "playground.chat.post",
            json!({ "id": id, "role": "tool", "text": "a crab on a keyboard",
                    "image_b64": b64(PNG), "image_type": "image/png", "provider": "openai",
                    "model": "gpt-image-1" }),
        )
        .await["message"]
        .clone();
    assert_eq!(photo["kind"].as_str(), Some("image"));
    let url = photo["photo_url"].as_str().unwrap().to_string();
    let message_id = photo["id"].as_str().unwrap();
    assert!(
        url.starts_with(&format!("/photos/{message_id}/")) && url.ends_with(".png"),
        "{url}"
    );

    // The listing carries the url, oldest first.
    let listed = alice.ok("playground.chat.list", json!({ "id": id })).await["messages"].clone();
    let listed = listed.as_array().unwrap();
    assert_eq!(listed.len(), 2);
    assert_eq!(listed[0]["id"], said["id"]);
    assert_eq!(listed[1]["photo_url"].as_str(), Some(url.as_str()));

    // And the url serves the bytes, typed, cacheable privately.
    let (status, headers, body) = http_get(server.port, &url).await;
    assert_eq!(status, 200);
    assert_eq!(header(&headers, "content-type"), Some("image/png"));
    assert_eq!(
        header(&headers, "cache-control"),
        Some("private, max-age=31536000")
    );
    assert_eq!(body, PNG);

    // A wrong token, a wrong extension and a wrong id are all the same 404.
    let bad_token = format!("/photos/{message_id}/{}.png", "0".repeat(32));
    assert_eq!(http_get(server.port, &bad_token).await.0, 404);
    let bad_ext = url.replace(".png", ".jpg");
    assert_eq!(http_get(server.port, &bad_ext).await.0, 404);
    assert_eq!(
        http_get(
            server.port,
            &url.replace(message_id, "msg_0000000000000000")
        )
        .await
        .0,
        404
    );
    assert_eq!(http_get(server.port, "/photos/x/notadot").await.0, 404);

    // The seam's refusals: a type the browser would not show, and base64
    // that is not.
    let frame = alice
        .call(
            "playground.chat.post",
            json!({ "id": id, "role": "tool", "image_b64": b64(PNG), "image_type": "image/gif" }),
        )
        .await;
    assert_eq!(
        frame["payload"]["code"].as_str(),
        Some("bad_request"),
        "{frame}"
    );
    let frame = alice
        .call(
            "playground.chat.post",
            json!({ "id": id, "role": "tool", "image_b64": "not base64!", "image_type": "image/png" }),
        )
        .await;
    assert_eq!(
        frame["payload"]["code"].as_str(),
        Some("bad_request"),
        "{frame}"
    );

    // Search reaches what was said.
    let found = alice
        .ok("playground.chat.search", json!({ "q": "crab" }))
        .await;
    assert_eq!(found["mode"].as_str(), Some("unified"));
    let hits = found["hits"].as_array().unwrap();
    assert!(!hits.is_empty(), "{found}");
    assert_eq!(hits[0]["snippet_name"].as_str(), Some("chatty"));
    assert!(hits[0]["message"]["id"].is_string());

    // Clear says how many went, and the url dies with the rows.
    let cleared = alice.ok("playground.chat.clear", json!({ "id": id })).await;
    assert_eq!(cleared["cleared"].as_i64(), Some(2));
    assert_eq!(cleared["id"].as_str(), Some(id.as_str()));
    assert!(
        alice.ok("playground.chat.list", json!({ "id": id })).await["messages"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(http_get(server.port, &url).await.0, 404);
    let eip55 = alice.ok("profile.update", json!({})).await["user"]["address"]
        .as_str()
        .unwrap()
        .to_string();
    let address = cwbhacker_core::eth::normalize_address(&eip55).unwrap();
    assert!(!server
        .store
        .home()
        .snippet_photo_dir(&address, &id)
        .exists());
    server.handle.abort();
}

/// SPEC §3.5 for the room: another player's snippet id answers `not_found`
/// on every one of the four, and the socket never says whose it is.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn one_player_cannot_reach_anothers_room() {
    let server = start().await;
    let mut alice = Client::connect(server.port).await;
    alice.login(ALICE_KEY).await;
    let mut bob = Client::connect(server.port).await;
    bob.login(BOB_KEY).await;
    let id = alice.new_pad().await;
    alice
        .ok(
            "playground.chat.post",
            json!({ "id": id, "role": "user", "text": "mine alone" }),
        )
        .await;

    assert_eq!(
        bob.err("playground.chat.list", json!({ "id": id })).await,
        "not_found"
    );
    assert_eq!(
        bob.err(
            "playground.chat.post",
            json!({ "id": id, "role": "user", "text": "hello?" })
        )
        .await,
        "not_found"
    );
    assert_eq!(
        bob.err("playground.chat.search", json!({ "q": "mine", "id": id }))
            .await,
        "not_found"
    );
    assert_eq!(
        bob.err("playground.chat.clear", json!({ "id": id })).await,
        "not_found"
    );
    assert!(bob
        .ok("playground.chat.search", json!({ "q": "mine" }))
        .await["hits"]
        .as_array()
        .unwrap()
        .is_empty());
    // Alice's room is untouched by all of it, and asking without a login is
    // `unauthorized` like everything else on the socket.
    assert_eq!(
        alice.ok("playground.chat.list", json!({ "id": id })).await["messages"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let mut nobody = Client::connect(server.port).await;
    assert_eq!(
        nobody
            .err("playground.chat.list", json!({ "id": id }))
            .await,
        "unauthorized"
    );
    server.handle.abort();
}
