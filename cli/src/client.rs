//! The websocket connection — PROTOCOL §1, §2 and §6.
//!
//! One struct, `Conn`, with one rule: **replies are matched by `id`, never by
//! arrival order.** §2.2 is explicit that the server may answer out of order,
//! and it names the exact case — a `ping` sent after a `quest.submit` comes
//! back first. This client sends exactly that `ping` as its keepalive, so the
//! case is not hypothetical: it happens on every submit that takes more than
//! twenty seconds.
//!
//! A reply that arrives for an id this call is not waiting on is **stashed**,
//! not dropped. A loop that reads until it sees its own id and discards the
//! rest passes every test written with one request in flight and loses a reply
//! the first time there are two.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

use crate::error::{self, Code, Error, Result};
use crate::proto::{Frame, WireError, VERSION};

/// §1.1: *"Clients whose websocket library does not expose ping/pong … must
/// instead send the application-level `ping` message every 20 seconds."*
/// `tokio-tungstenite` does answer websocket pings, so this is belt and
/// braces — and it is also the round-trip timer and the out-of-order proof.
pub const KEEPALIVE: Duration = Duration::from_secs(20);

/// §6.2: 0.5 s, 1 s, 2 s, 4 s, 8 s, then every 8 s, each with ±20% jitter.
pub fn backoff_delay(attempt: u32) -> Duration {
    let base_ms = match attempt {
        0 => 500u64,
        1 => 1_000,
        2 => 2_000,
        3 => 4_000,
        _ => 8_000,
    };
    let jitter: f64 = {
        use rand::Rng;
        rand::thread_rng().gen_range(0.8..1.2)
    };
    Duration::from_millis((base_ms as f64 * jitter) as u64)
}

/// What a caller wants to know about while it waits for its reply.
///
/// §4.17–§4.21 events arrive unsolicited at any time, *including after the
/// request they relate to has already been answered*, so every wait hands them
/// somewhere rather than dropping them on the floor.
pub type EventSink<'a> = &'a mut dyn FnMut(&Frame);

/// A do-nothing sink, for the many requests that expect no events.
pub fn ignore_events(_: &Frame) {}

pub struct Conn {
    socket: WebSocketStream<MaybeTlsStream<TcpStream>>,
    url: String,
    counter: u64,
    /// Replies that arrived for an id nobody was waiting on yet.
    stash: HashMap<String, Frame>,
    /// Keepalive pings, whose replies are counted and discarded.
    outstanding_pings: HashSet<String>,
    /// Types the server sent that this client does not know (§2.3). Kept so
    /// `--trace` can say so out loud rather than silently ignoring them.
    pub unknown_types: Vec<String>,
    /// How many replies arrived out of order — a reply for an id other than
    /// the one currently being waited on. §8.2's evidence.
    pub out_of_order: u32,
    /// Websocket ping frames seen. §1.1 says the server sends one every 30 s;
    /// `tokio-tungstenite` answers them itself, and counting them is how a
    /// `cwbh doctor --hold` can say so rather than assume it.
    pub ws_pings: u32,
    /// Application `ping` messages this client sent as its keepalive.
    pub app_pings: u32,
    pub trace: bool,
    /// How often the application-level `ping` goes out while waiting. §1.1's
    /// 20 seconds by default; a test turns it down so the keepalive can be
    /// observed without sitting through it.
    pub keepalive: Duration,
    started: Instant,
}

impl Conn {
    pub async fn connect(url: &str) -> Result<Conn> {
        let (socket, _) = connect_async(url)
            .await
            .map_err(|e| error::disconnected(format!("cannot reach {url}: {e}")))?;
        Ok(Conn {
            socket,
            url: url.to_string(),
            counter: 0,
            stash: HashMap::new(),
            outstanding_pings: HashSet::new(),
            unknown_types: Vec::new(),
            out_of_order: 0,
            ws_pings: 0,
            app_pings: 0,
            trace: false,
            keepalive: KEEPALIVE,
            started: Instant::now(),
        })
    }

    /// §6.2 and §8.9. `attempts` of `None` retries forever, which is what the
    /// TUI wants while a `make restart` is in flight; a one-shot command
    /// passes a small number so a shell script fails rather than hangs.
    pub async fn connect_with_backoff(
        url: &str,
        attempts: Option<u32>,
        mut on_retry: impl FnMut(u32, Duration),
    ) -> Result<Conn> {
        let mut attempt = 0u32;
        loop {
            match Conn::connect(url).await {
                Ok(conn) => return Ok(conn),
                Err(e) => {
                    if let Some(max) = attempts {
                        if attempt + 1 >= max {
                            return Err(e);
                        }
                    }
                    let delay = backoff_delay(attempt);
                    on_retry(attempt + 1, delay);
                    tokio::time::sleep(delay).await;
                    attempt += 1;
                }
            }
        }
    }

    pub fn url(&self) -> &str {
        &self.url
    }

    /// §2.2: *"a string unique for the life of the connection. The convention
    /// is `"c-" + a counter`."*
    pub fn next_id(&mut self) -> String {
        self.counter += 1;
        format!("c-{}", self.counter)
    }

    async fn write(&mut self, frame: &Frame) -> Result<()> {
        let text = serde_json::to_string(frame)?;
        if self.trace {
            eprintln!(
                "  {:>7.3}s →  {}",
                self.started.elapsed().as_secs_f64(),
                text
            );
        }
        self.socket
            .send(Message::Text(text))
            .await
            .map_err(|e| error::disconnected(format!("send failed: {e}")))
    }

    /// Send a request and return its correlation id.
    pub async fn send(&mut self, kind: &str, payload: serde_json::Value) -> Result<String> {
        let id = self.next_id();
        let frame = Frame::request(id.clone(), kind, payload);
        self.write(&frame).await?;
        Ok(id)
    }

    /// Send a request and wait for its reply, handing every event that arrives
    /// meanwhile to `sink`.
    pub async fn request_with(
        &mut self,
        kind: &str,
        payload: serde_json::Value,
        sink: EventSink<'_>,
    ) -> Result<serde_json::Value> {
        let id = self.send(kind, payload).await?;
        self.await_reply(&id, sink).await
    }

    /// The common case: a request with no events worth showing.
    pub async fn request(
        &mut self,
        kind: &str,
        payload: serde_json::Value,
    ) -> Result<serde_json::Value> {
        self.request_with(kind, payload, &mut ignore_events).await
    }

    /// Typed sugar over `request`.
    pub async fn call<T: serde::de::DeserializeOwned>(
        &mut self,
        kind: &str,
        payload: serde_json::Value,
    ) -> Result<T> {
        let value = self.request(kind, payload).await?;
        Ok(serde_json::from_value(value)?)
    }

    pub async fn call_with<T: serde::de::DeserializeOwned>(
        &mut self,
        kind: &str,
        payload: serde_json::Value,
        sink: EventSink<'_>,
    ) -> Result<T> {
        let value = self.request_with(kind, payload, sink).await?;
        Ok(serde_json::from_value(value)?)
    }

    /// Wait for the reply to `id`, pumping the socket meanwhile.
    ///
    /// Everything that is not that reply is dealt with in place: events go to
    /// `sink`, keepalive answers are counted, and any other reply is stashed
    /// for whoever is waiting on it.
    pub async fn await_reply(
        &mut self,
        id: &str,
        sink: EventSink<'_>,
    ) -> Result<serde_json::Value> {
        if let Some(frame) = self.stash.remove(id) {
            return Self::unwrap_reply(frame);
        }
        let mut keepalive = tokio::time::interval(self.keepalive);
        keepalive.tick().await; // the first tick is immediate
        loop {
            tokio::select! {
                _ = keepalive.tick() => {
                    // §1.1's application keepalive. Fire and forget: its reply
                    // is counted, not waited for, so it cannot deadlock behind
                    // the submit it is keeping the connection alive for.
                    self.keepalive_ping().await?;
                }
                message = self.socket.next() => {
                    let message = match message {
                        Some(Ok(m)) => m,
                        Some(Err(e)) => return Err(error::disconnected(format!("socket error: {e}"))),
                        None => return Err(error::disconnected("the server closed the connection")),
                    };
                    if let Some(frame) = self.decode(message)? {
                        if frame.is_event() {
                            sink(&frame);
                            continue;
                        }
                        let frame_id = frame.id.clone().unwrap_or_default();
                        if frame_id == id {
                            return Self::unwrap_reply(frame);
                        }
                        if self.outstanding_pings.remove(&frame_id) {
                            // The keepalive answered while a submit was still
                            // running: §2.2's own example of an out-of-order
                            // reply, observed rather than assumed.
                            self.out_of_order += 1;
                            continue;
                        }
                        self.out_of_order += 1;
                        self.stash.insert(frame_id, frame);
                    }
                }
            }
        }
    }

    /// Read whatever arrives next without sending anything — the TUI's pump.
    pub async fn next_frame(&mut self) -> Result<Frame> {
        loop {
            match self.socket.next().await {
                Some(Ok(message)) => {
                    if let Some(frame) = self.decode(message)? {
                        return Ok(frame);
                    }
                }
                Some(Err(e)) => return Err(error::disconnected(format!("socket error: {e}"))),
                None => return Err(error::disconnected("the server closed the connection")),
            }
        }
    }

    pub async fn keepalive_ping(&mut self) -> Result<()> {
        let id = self.next_id();
        let frame = Frame::request(id.clone(), "ping", serde_json::json!({}));
        self.outstanding_pings.insert(id);
        self.app_pings += 1;
        self.write(&frame).await
    }

    /// True when this id was one of ours and is now accounted for.
    pub fn take_keepalive(&mut self, id: &str) -> bool {
        self.outstanding_pings.remove(id)
    }

    pub async fn close(&mut self) {
        let _ = self.socket.close(None).await;
    }

    /// Turn one websocket message into a frame, or `None` for the ones that
    /// carry no application meaning.
    fn decode(&mut self, message: Message) -> Result<Option<Frame>> {
        match message {
            Message::Text(text) => {
                if self.trace {
                    eprintln!(
                        "  {:>7.3}s ←  {}",
                        self.started.elapsed().as_secs_f64(),
                        truncate(&text, 400)
                    );
                }
                let frame: Frame = match serde_json::from_str(&text) {
                    Ok(f) => f,
                    Err(e) => {
                        // A frame this client cannot parse is not a reason to
                        // close (§2.3's spirit): note it and carry on.
                        self.unknown_types.push(format!("unparsable frame: {e}"));
                        return Ok(None);
                    }
                };
                if frame.v != VERSION {
                    self.unknown_types
                        .push(format!("frame with v={} ignored", frame.v));
                    return Ok(None);
                }
                Ok(Some(frame))
            }
            // §1.1: the server pings every 30 s. `tokio-tungstenite` queues
            // the pong itself; nothing to do but keep reading.
            Message::Ping(_) => {
                self.ws_pings += 1;
                Ok(None)
            }
            Message::Pong(_) => Ok(None),
            Message::Close(frame) => {
                let detail = frame
                    .map(|f| format!("{} {}", u16::from(f.code), f.reason))
                    .unwrap_or_else(|| "no close frame".to_string());
                Err(error::disconnected(format!("server closed: {detail}")))
            }
            // §1: binary frames are not used. Nothing sends one, and if
            // something did it would not be an application message.
            Message::Binary(_) | Message::Frame(_) => Ok(None),
        }
    }

    /// `.ok` -> the payload; `.err` -> §3.3's error, with its code intact.
    fn unwrap_reply(frame: Frame) -> Result<serde_json::Value> {
        if frame.is_err() {
            let wire: WireError =
                serde_json::from_value(frame.payload.clone()).unwrap_or_else(|_| WireError {
                    code: "internal".into(),
                    message: format!("malformed error payload on {}", frame.kind),
                    detail: serde_json::json!({}),
                });
            return Err(Error {
                code: Code::from_wire(&wire.code),
                message: wire.message,
                detail: wire.detail,
            });
        }
        Ok(frame.payload)
    }
}

fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let head: String = text.chars().take(max).collect();
    format!("{head}… ({} bytes)", text.len())
}

/// A `run.log` reassembler — §4.18 and §8.8.
///
/// *"`seq` counts from 0 per stream per attempt, so a client can detect a gap.
/// Chunks are UTF-8 and may split anywhere, including mid-line; a client must
/// buffer rather than assume lines."*
///
/// So this holds a tail per stream and only ever emits what it has actually
/// seen. It does not wait for a newline to print — a terminal's whole
/// advantage here is that half a line of `rustc` output is visible the moment
/// it exists — but it does keep the boundary so a line spanning two chunks is
/// counted once and a gap in `seq` is reported rather than papered over.
#[derive(Default)]
pub struct LogStreams {
    next_seq: HashMap<String, i64>,
    pub gaps: Vec<String>,
    pub bytes: HashMap<String, usize>,
}

impl LogStreams {
    /// Record a chunk. Returns `true` when it was the next one expected.
    pub fn accept(&mut self, attempt_id: &str, stream: &str, seq: i64, chunk: &str) -> bool {
        let key = format!("{attempt_id}/{stream}");
        *self.bytes.entry(key.clone()).or_insert(0) += chunk.len();
        let expected = self.next_seq.entry(key.clone()).or_insert(0);
        let contiguous = seq == *expected;
        if !contiguous {
            self.gaps.push(format!(
                "{stream}: expected seq {} but got {seq}",
                *expected
            ));
        }
        // Carry on from what actually arrived; a gap is reported once, not
        // every chunk after it.
        *expected = seq + 1;
        contiguous
    }

    pub fn total_bytes(&self) -> usize {
        self.bytes.values().sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_follows_the_documented_ladder_with_jitter() {
        for (attempt, base) in [
            (0u32, 500u64),
            (1, 1000),
            (2, 2000),
            (3, 4000),
            (4, 8000),
            (9, 8000),
        ] {
            let ms = backoff_delay(attempt).as_millis() as u64;
            assert!(
                ms >= (base as f64 * 0.8) as u64 && ms <= (base as f64 * 1.2) as u64,
                "attempt {attempt} gave {ms}ms, outside ±20% of {base}"
            );
        }
    }

    #[test]
    fn a_gap_in_seq_is_noticed() {
        let mut streams = LogStreams::default();
        assert!(streams.accept("att_1", "compile", 0, "error"));
        assert!(streams.accept("att_1", "compile", 1, "[E0382]"));
        // seq 2 never arrives.
        assert!(!streams.accept("att_1", "compile", 3, ": borrow"));
        assert_eq!(streams.gaps.len(), 1);
        assert!(streams.gaps[0].contains("expected seq 2"));
        // And it recovers rather than reporting a gap on every later chunk.
        assert!(streams.accept("att_1", "compile", 4, " of moved value"));
        assert_eq!(streams.gaps.len(), 1);
    }

    #[test]
    fn seq_is_counted_per_stream() {
        let mut streams = LogStreams::default();
        assert!(streams.accept("att_1", "compile", 0, "a"));
        assert!(streams.accept("att_1", "stdout", 0, "b"));
        assert!(streams.accept("att_1", "stderr", 0, "c"));
        assert!(streams.gaps.is_empty(), "three streams each start at 0");
        assert_eq!(streams.total_bytes(), 3);
    }

    /// §8.8's other half: a chunk that splits mid-line is buffered, not
    /// assumed to be a line.
    #[test]
    fn chunks_that_split_mid_line_reassemble() {
        let mut streams = LogStreams::default();
        let mut seen = String::new();
        for (seq, chunk) in ["error[E00", "12]: expected `;`", ", found `}`\n"]
            .iter()
            .enumerate()
        {
            streams.accept("att_1", "compile", seq as i64, chunk);
            seen.push_str(chunk);
        }
        assert_eq!(seen, "error[E0012]: expected `;`, found `}`\n");
        assert!(streams.gaps.is_empty());
    }
}
