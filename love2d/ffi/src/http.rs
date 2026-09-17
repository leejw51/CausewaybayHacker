//! The streaming HTTP client the Rust coder talks to model providers with.
//!
//! LÖVE bundles LuaSocket and nothing else: plain TCP, no TLS. Every model
//! provider is HTTPS, so the client physically cannot reach one from Lua.
//! This module is the door, and it is deliberately a **generic HTTP client**
//! rather than an AI client: it knows about URLs, headers, bytes and
//! cancellation, and nothing whatsoever about Anthropic, OpenAI or xAI. Which
//! provider is being spoken to, what the request body means and how to read a
//! stream of events back out of it all live in `love2d/src/agent/`, the same
//! way they live in `frontend/src/ai/` on the web. One protocol, written once
//! per language, not once per provider.
//!
//! ## Why polling
//!
//! `love.update` runs sixty times a second and must never block. So a request
//! is a **handle**: `http_start` spawns a thread and returns an id, `http_poll`
//! takes whatever bytes have arrived since the last call, and `http_cancel`
//! asks the thread to stop at its next read. Nothing here ever waits.
//!
//! Chunks come back base64-encoded. A server-sent-event stream splits on
//! whatever boundary the network gave it, which can be the middle of a UTF-8
//! sequence, and a JSON string cannot carry half a character. `src/net/
//! base64.lua` decodes them, and `src/agent/sse.lua` reassembles the lines.
//!
//! ## What does not cross
//!
//! An API key is a header on the way **out** and is never stored, never
//! logged and never echoed back: `http_poll` returns the response, and the
//! request is dropped with the thread that made it. The keys themselves live
//! in the player's own store, never in the game server (SPEC §5.3's argument,
//! applied to somebody else's credential).

use std::collections::HashMap;
use std::io::Read;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use serde::Deserialize;
use serde_json::json;

/// How much body may sit unread in a handle before the call is failed.
///
/// A caller that stops polling — a screen that was left, a scene that threw —
/// must not be able to grow a buffer without bound. Eight megabytes is far
/// more than any chat completion and still small enough to be nothing.
const BUFFER_MAX: usize = 8 * 1024 * 1024;

/// Read size. Small enough that a token appears the moment it arrives rather
/// than when a block fills; large enough not to be a syscall per byte.
const READ_CHUNK: usize = 8 * 1024;

/// The ceiling on a single call, from the first connect to the last byte.
/// A model that has stopped talking is not a model that is still thinking.
const TIMEOUT_TOTAL: Duration = Duration::from_secs(600);
const TIMEOUT_CONNECT: Duration = Duration::from_secs(20);
const TIMEOUT_HEADERS: Duration = Duration::from_secs(120);

/// One call in flight, shared between the thread that fills it and the Lua
/// side that drains it.
struct Call {
    /// Bytes that have arrived and not yet been polled, oldest first.
    chunks: Mutex<Vec<Vec<u8>>>,
    /// How much is sitting in `chunks`, for the cap.
    buffered: AtomicU64,
    /// The HTTP status, or -1 before the headers have come back.
    status: AtomicI64,
    /// Set once the body is finished, failed or cancelled.
    done: AtomicBool,
    /// Set by `http_cancel`; the reader checks it between chunks.
    cancel: AtomicBool,
    /// What went wrong, if anything did.
    error: Mutex<Option<String>>,
}

impl Call {
    fn new() -> Self {
        Self {
            chunks: Mutex::new(Vec::new()),
            buffered: AtomicU64::new(0),
            status: AtomicI64::new(-1),
            done: AtomicBool::new(false),
            cancel: AtomicBool::new(false),
            error: Mutex::new(None),
        }
    }

    fn fail(&self, message: impl Into<String>) {
        let mut slot = self.error.lock().unwrap_or_else(|e| e.into_inner());
        if slot.is_none() {
            *slot = Some(message.into());
        }
        self.done.store(true, Ordering::SeqCst);
    }
}

/// Every call that has been started and not yet closed.
///
/// A handle is an integer because it crosses a JSON boundary into Lua, where
/// a pointer would be a number with a sharp edge on it. Ids are never reused.
fn registry() -> &'static Mutex<HashMap<u64, Arc<Call>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<u64, Arc<Call>>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_handle() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::SeqCst)
}

/// What `http_start` accepts. Deserialised from the same request object the
/// rest of the library uses, so the Lua side has one encoder and one decoder.
#[derive(Deserialize, Default)]
pub struct HttpRequest {
    pub url: Option<String>,
    pub method: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    /// The request body as text. JSON, in every call this client makes.
    pub body: Option<String>,
}

fn agent() -> ureq::Agent {
    ureq::Agent::new_with_config(
        ureq::Agent::config_builder()
            .timeout_global(Some(TIMEOUT_TOTAL))
            .timeout_connect(Some(TIMEOUT_CONNECT))
            .timeout_recv_response(Some(TIMEOUT_HEADERS))
            // A streaming reply is read as it comes; there is no response-body
            // deadline that is not the whole call's.
            .timeout_recv_body(None)
            .http_status_as_error(false)
            .build(),
    )
}

/// Start a call. Returns the handle.
pub fn start(req: &HttpRequest) -> Result<u64, String> {
    let url = req
        .url
        .clone()
        .ok_or_else(|| "no `url` given".to_string())?;
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err("`url` must be http:// or https://".to_string());
    }
    let method = req
        .method
        .clone()
        .unwrap_or_else(|| if req.body.is_some() { "POST" } else { "GET" }.to_string())
        .to_uppercase();
    let headers = req.headers.clone().unwrap_or_default();
    let body = req.body.clone().unwrap_or_default();

    let call = Arc::new(Call::new());
    let handle = next_handle();
    registry()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(handle, Arc::clone(&call));

    let worker = Arc::clone(&call);
    std::thread::Builder::new()
        .name(format!("cwbh-http-{handle}"))
        .spawn(move || run_call(worker, url, method, headers, body))
        .map_err(|e| {
            registry()
                .lock()
                .unwrap_or_else(|er| er.into_inner())
                .remove(&handle);
            format!("could not start a request thread: {e}")
        })?;
    Ok(handle)
}

fn run_call(
    call: Arc<Call>,
    url: String,
    method: String,
    headers: HashMap<String, String>,
    body: String,
) {
    let mut builder = ureq::http::Request::builder().method(method.as_str()).uri(&url);
    for (name, value) in &headers {
        builder = builder.header(name.as_str(), value.as_str());
    }
    let request = match builder.body(body) {
        Ok(r) => r,
        Err(e) => return call.fail(format!("the request could not be built: {e}")),
    };

    let response = match agent().run(request) {
        Ok(r) => r,
        Err(e) => return call.fail(describe_error(&e)),
    };
    call.status.store(response.status().as_u16() as i64, Ordering::SeqCst);

    let mut reader = response.into_body().into_reader();
    let mut buf = vec![0u8; READ_CHUNK];
    loop {
        if call.cancel.load(Ordering::SeqCst) {
            call.done.store(true, Ordering::SeqCst);
            return;
        }
        match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                let total = call.buffered.fetch_add(n as u64, Ordering::SeqCst) + n as u64;
                if total > BUFFER_MAX as u64 {
                    return call.fail("the reply outgrew the buffer and was dropped");
                }
                call.chunks
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .push(buf[..n].to_vec());
            }
            Err(e) => return call.fail(format!("the reply stopped early: {e}")),
        }
    }
    call.done.store(true, Ordering::SeqCst);
}

/// A network failure in a sentence a player can read. `ureq`'s own Display is
/// accurate and long; this keeps the shape and drops the noise.
fn describe_error(e: &ureq::Error) -> String {
    match e {
        ureq::Error::ConnectionFailed => "could not connect".to_string(),
        ureq::Error::Timeout(_) => "the request timed out".to_string(),
        ureq::Error::HostNotFound => "the host could not be found".to_string(),
        other => other.to_string(),
    }
}

/// Take everything that has arrived since the last poll.
///
/// The chunks are base64 so that a split UTF-8 sequence survives the JSON
/// round trip; `done` is the only signal that matters for ending a read, and
/// it is set for success, failure and cancellation alike.
pub fn poll(handle: u64) -> Result<serde_json::Value, String> {
    let call = find(handle)?;
    let taken: Vec<Vec<u8>> = {
        let mut held = call.chunks.lock().unwrap_or_else(|e| e.into_inner());
        std::mem::take(&mut *held)
    };
    let mut bytes = 0usize;
    let chunks: Vec<String> = taken
        .iter()
        .map(|c| {
            bytes += c.len();
            b64(c)
        })
        .collect();
    call.buffered.fetch_sub(bytes as u64, Ordering::SeqCst);
    let status = call.status.load(Ordering::SeqCst);
    let error = call
        .error
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    Ok(json!({
        "ok": true,
        "handle": handle,
        "status": if status < 0 { serde_json::Value::Null } else { json!(status) },
        "chunks": chunks,
        "bytes": bytes,
        "done": call.done.load(Ordering::SeqCst),
        "cancelled": call.cancel.load(Ordering::SeqCst),
        "error": error,
    }))
}

/// Ask the call to stop. The thread notices between reads; the handle stays
/// valid until it is closed, so a poll after this still answers.
pub fn cancel(handle: u64) -> Result<serde_json::Value, String> {
    let call = find(handle)?;
    call.cancel.store(true, Ordering::SeqCst);
    Ok(json!({ "ok": true, "handle": handle, "cancelled": true }))
}

/// Forget the call. Cancels it first: a handle closed mid-flight must not
/// leave a thread reading a body nobody will ever look at.
pub fn close(handle: u64) -> Result<serde_json::Value, String> {
    let call = registry()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&handle);
    match call {
        Some(c) => {
            c.cancel.store(true, Ordering::SeqCst);
            Ok(json!({ "ok": true, "handle": handle, "closed": true }))
        }
        None => Ok(json!({ "ok": true, "handle": handle, "closed": false })),
    }
}

/// How many calls are open. For the tests, and for a leak to be visible.
pub fn open_count() -> usize {
    registry().lock().unwrap_or_else(|e| e.into_inner()).len()
}

fn find(handle: u64) -> Result<Arc<Call>, String> {
    registry()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&handle)
        .cloned()
        .ok_or_else(|| format!("no request with handle {handle}"))
}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding. Written out rather than pulled in: this is
/// the only place in the crate that needs it, and it is fifteen lines.
fn b64(bytes: &[u8]) -> String {
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for group in bytes.chunks(3) {
        let b = [group[0], *group.get(1).unwrap_or(&0), *group.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if group.len() > 1 { ALPHABET[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if group.len() > 2 { ALPHABET[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::TcpListener;

    /// A one-shot HTTP server on a loopback port. Returns its URL and the
    /// thread's join handle; the body is written in pieces with a pause
    /// between them, which is what a streamed reply looks like.
    fn serve(response: &'static [&'static str]) -> (String, std::thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().expect("accept");
            let mut request = Vec::new();
            let mut buf = [0u8; 1024];
            // Read the head, and the body if the head says there is one.
            loop {
                let n = socket.read(&mut buf).expect("read");
                if n == 0 {
                    break;
                }
                request.extend_from_slice(&buf[..n]);
                let text = String::from_utf8_lossy(&request).to_string();
                if let Some(head_end) = text.find("\r\n\r\n") {
                    let head = &text[..head_end];
                    let want: usize = head
                        .lines()
                        .find_map(|l| {
                            let (name, value) = l.split_once(':')?;
                            if name.eq_ignore_ascii_case("content-length") {
                                value.trim().parse().ok()
                            } else {
                                None
                            }
                        })
                        .unwrap_or(0);
                    if text.len() - head_end - 4 >= want {
                        break;
                    }
                }
            }
            for piece in response {
                socket.write_all(piece.as_bytes()).expect("write");
                socket.flush().ok();
                std::thread::sleep(Duration::from_millis(20));
            }
            drop(socket);
            String::from_utf8_lossy(&request).to_string()
        });
        (format!("http://127.0.0.1:{port}/v1/chat"), handle)
    }

    /// Poll until the call says it is finished, gathering the text.
    fn drain(handle: u64) -> (Option<i64>, String, Option<String>) {
        let mut text = String::new();
        let mut status = None;
        for _ in 0..600 {
            let v = poll(handle).expect("poll");
            if let Some(s) = v["status"].as_i64() {
                status = Some(s);
            }
            for chunk in v["chunks"].as_array().unwrap() {
                text.push_str(&String::from_utf8_lossy(&unb64(chunk.as_str().unwrap())));
            }
            if v["done"].as_bool().unwrap_or(false) {
                let error = v["error"].as_str().map(|s| s.to_string());
                return (status, text, error);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("the call never finished");
    }

    fn unb64(text: &str) -> Vec<u8> {
        let mut bits = Vec::new();
        for ch in text.bytes() {
            if ch == b'=' {
                break;
            }
            let v = ALPHABET.iter().position(|&a| a == ch).expect("base64") as u32;
            bits.push(v);
        }
        let mut out = Vec::new();
        for group in bits.chunks(4) {
            let mut n = 0u32;
            for (i, v) in group.iter().enumerate() {
                n |= v << (18 - 6 * i);
            }
            out.push((n >> 16) as u8);
            if group.len() > 2 {
                out.push((n >> 8) as u8);
            }
            if group.len() > 3 {
                out.push(n as u8);
            }
        }
        out
    }

    #[test]
    fn a_streamed_body_arrives_in_pieces_and_ends() {
        let (url, server) = serve(&[
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
            "data: {\"one\":1}\n\n",
            "data: {\"two\":2}\n\n",
            "data: [DONE]\n\n",
        ]);
        let handle = start(&HttpRequest {
            url: Some(url),
            method: Some("POST".into()),
            headers: Some(HashMap::from([(
                "content-type".to_string(),
                "application/json".to_string(),
            )])),
            body: Some(r#"{"model":"test"}"#.to_string()),
        })
        .expect("start");
        let (status, text, error) = drain(handle);
        assert_eq!(status, Some(200));
        assert_eq!(error, None);
        assert!(text.contains("\"one\":1"), "got {text}");
        assert!(text.contains("[DONE]"), "got {text}");
        let request = server.join().expect("server");
        assert!(request.starts_with("POST /v1/chat"), "got {request}");
        assert!(request.contains("content-type: application/json"), "got {request}");
        assert!(request.contains(r#"{"model":"test"}"#), "got {request}");
        close(handle).expect("close");
    }

    #[test]
    fn a_split_utf8_sequence_survives_the_round_trip() {
        // "안녕" cut between the two bytes of its first character.
        let (url, _server) = serve(&[
            "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n",
            "\u{c548}",
            "\u{b155}",
        ]);
        let handle = start(&HttpRequest {
            url: Some(url),
            ..Default::default()
        })
        .expect("start");
        let (_, text, error) = drain(handle);
        assert_eq!(error, None);
        assert_eq!(text, "안녕");
        close(handle).expect("close");
    }

    #[test]
    fn a_status_that_is_not_ok_is_a_reply_not_an_error() {
        let (url, _server) = serve(&[
            "HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n",
            "{\"error\":\"bad key\"}",
        ]);
        let handle = start(&HttpRequest {
            url: Some(url),
            ..Default::default()
        })
        .expect("start");
        let (status, text, error) = drain(handle);
        assert_eq!(status, Some(401));
        assert_eq!(error, None, "a 401 is the provider talking, not a failure");
        assert!(text.contains("bad key"));
        close(handle).expect("close");
    }

    #[test]
    fn a_refused_connection_is_reported_and_finishes() {
        // Bind and drop, so the port is certainly nobody's.
        let dead = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = dead.local_addr().unwrap().port();
        drop(dead);
        let handle = start(&HttpRequest {
            url: Some(format!("http://127.0.0.1:{port}/")),
            ..Default::default()
        })
        .expect("start");
        let (status, _, error) = drain(handle);
        assert_eq!(status, None);
        assert!(error.is_some(), "a refused connection must say so");
        close(handle).expect("close");
    }

    #[test]
    fn a_handle_is_closed_once_and_then_unknown() {
        let (url, _server) = serve(&["HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n", "hi"]);
        let handle = start(&HttpRequest {
            url: Some(url),
            ..Default::default()
        })
        .expect("start");
        drain(handle);
        let before = open_count();
        close(handle).expect("close");
        assert_eq!(open_count(), before - 1);
        assert!(poll(handle).is_err(), "a closed handle is not pollable");
    }

    #[test]
    fn a_url_that_is_not_http_is_refused_before_a_thread_exists() {
        let before = open_count();
        let err = start(&HttpRequest {
            url: Some("file:///etc/passwd".into()),
            ..Default::default()
        })
        .unwrap_err();
        assert!(err.contains("http://"), "got {err}");
        assert_eq!(open_count(), before);
    }

    #[test]
    fn base64_matches_the_examples_in_rfc_4648() {
        assert_eq!(b64(b""), "");
        assert_eq!(b64(b"f"), "Zg==");
        assert_eq!(b64(b"fo"), "Zm8=");
        assert_eq!(b64(b"foo"), "Zm9v");
        assert_eq!(b64(b"foob"), "Zm9vYg==");
        assert_eq!(b64(b"fooba"), "Zm9vYmE=");
        assert_eq!(b64(b"foobar"), "Zm9vYmFy");
    }
}
