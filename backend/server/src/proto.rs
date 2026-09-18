//! The envelope (PROTOCOL §2).
//!
//! `{ "v": 1, "id": "c-42", "type": "quest.submit", "payload": {} }` in both
//! directions, and **exactly** those four keys. A frame carrying a fifth is
//! answered `bad_request` rather than quietly accepted, because a silently
//! ignored field is how a client ships a bug that looks like it works.

use serde::{Deserialize, Serialize};
use tokio::sync::mpsc::UnboundedSender;

use cwbhacker_core::error::{bad_request, Error, Result};

pub const PROTOCOL_VERSION: i64 = 1;

/// PROTOCOL §1: 4 MiB inbound, above which the connection is closed with 1009.
pub const MAX_FRAME_BYTES: usize = 4 * 1024 * 1024;

/// How deep a frame may nest.
///
/// `serde_json` refuses at 128 and reports it as an ordinary parse error, so a
/// deeply nested but perfectly valid object used to come out of `parse` as
/// `NotAnObject` and close the connection with 1003 — whose documented meaning
/// (§1.2) is "a binary frame, or a frame that is not a JSON object". It *is* an
/// object, so that close said something untrue.
///
/// The depth is therefore checked here, before serde sees the text, and
/// answered `bad_request` with the connection left open. §3.3 prefers that for
/// anything that is an application-level problem, and a frame nested three
/// hundred deep is a client bug, not a broken transport. 64 sits well under
/// serde's own limit so the two can never disagree; the deepest thing this
/// protocol actually carries is a test spec, four levels down.
pub const MAX_DEPTH: usize = 64;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClientFrame {
    pub v: i64,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(rename = "type")]
    pub kind: String,
    /// Required, and required to be an object. PROTOCOL §2: "never absent.
    /// Use `{}`". Accepting an absent one is the same failure as silently
    /// ignoring an unknown key — a client ships a bug that looks like it
    /// works and breaks against the next server.
    pub payload: serde_json::Value,
}

#[derive(Debug, Clone, Serialize)]
pub struct ServerFrame {
    pub v: i64,
    pub id: Option<String>,
    #[serde(rename = "type")]
    pub kind: String,
    pub payload: serde_json::Value,
}

impl ServerFrame {
    pub fn ok(id: Option<String>, kind: &str, payload: serde_json::Value) -> ServerFrame {
        ServerFrame {
            v: PROTOCOL_VERSION,
            id,
            kind: format!("{kind}.ok"),
            payload,
        }
    }

    pub fn err(id: Option<String>, kind: &str, error: &Error) -> ServerFrame {
        ServerFrame {
            v: PROTOCOL_VERSION,
            id,
            kind: format!("{kind}.err"),
            payload: serde_json::json!({
                "code": error.code.as_str(),
                "message": error.message,
                "detail": error.detail,
            }),
        }
    }

    /// An unsolicited event (§4.17–§4.21). Always `id: null`; a client must
    /// never try to correlate one.
    pub fn event(kind: &str, payload: serde_json::Value) -> ServerFrame {
        ServerFrame {
            v: PROTOCOL_VERSION,
            id: None,
            kind: kind.to_string(),
            payload,
        }
    }
}

/// What the writer task accepts. A close carries a code from §1.2 — an
/// application error is never a close, so this is only used for the transport
/// failures that table names.
#[derive(Debug, Clone)]
pub enum Outgoing {
    Frame(ServerFrame),
    Close { code: u16, reason: &'static str },
}

pub type Out = UnboundedSender<Outgoing>;

pub fn send(out: &Out, frame: ServerFrame) {
    let _ = out.send(Outgoing::Frame(frame));
}

/// Parse a text frame. The two failure modes are different on purpose: a frame
/// that is not a JSON object is a transport error (close 1003), while a frame
/// that is an object with the wrong keys is an application error the
/// connection survives.
pub enum Incoming {
    Frame(Box<ClientFrame>),
    /// Not a JSON object at all — §1.2 close code 1003.
    NotAnObject,
    /// An object, but not a valid envelope. Carries whatever `id` and `type`
    /// could be salvaged so the error can be correlated.
    Malformed {
        id: Option<String>,
        kind: String,
        error: Error,
    },
}

pub fn parse(text: &str) -> Incoming {
    // Depth first, because serde cannot be asked afterwards: once it has hit
    // its recursion limit the error is indistinguishable from a syntax error,
    // and the two deserve opposite answers.
    let skim = skim(text);
    if !skim.is_object {
        return Incoming::NotAnObject;
    }
    if skim.max_depth > MAX_DEPTH {
        return Incoming::Malformed {
            id: skim.id,
            kind: skim.kind.unwrap_or_else(|| "frame".to_string()),
            error: bad_request(format!(
                "the frame nests {} deep and the limit is {MAX_DEPTH}",
                skim.max_depth
            )),
        };
    }
    let value: serde_json::Value = match serde_json::from_str(text) {
        Ok(value) => value,
        Err(_) => return Incoming::NotAnObject,
    };
    if !value.is_object() {
        return Incoming::NotAnObject;
    }
    let id = value.get("id").and_then(|v| v.as_str()).map(str::to_string);
    let kind = value
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("frame")
        .to_string();
    match serde_json::from_value::<ClientFrame>(value) {
        Ok(frame) => {
            if !frame.payload.is_object() {
                return Incoming::Malformed {
                    id,
                    kind,
                    error: bad_request("payload must be an object"),
                };
            }
            Incoming::Frame(Box::new(frame))
        }
        Err(e) => Incoming::Malformed {
            id,
            kind,
            error: bad_request(format!("not a protocol frame: {e}")),
        },
    }
}

/// What one non-recursive pass over the raw text can learn that serde cannot
/// tell us once it has given up: whether this is an object at all, how deep it
/// nests, and the top-level `id` and `type` — so that a frame refused for its
/// depth is still correlated to the request that sent it (§2.2).
#[derive(Debug, Default)]
struct Skim {
    is_object: bool,
    max_depth: usize,
    id: Option<String>,
    kind: Option<String>,
}

/// Walk the bytes once, iteratively. **String contents are skipped with full
/// escape handling, and that is not a nicety:** every `quest.submit` carries a
/// program in `payload.source`, so a depth counter that counted the braces
/// inside `"fn main() { … }"` would refuse every real submission and look like
/// the runner had broken.
fn skim(text: &str) -> Skim {
    let b = text.as_bytes();
    let mut i = 0;
    while i < b.len() && b[i].is_ascii_whitespace() {
        i += 1;
    }
    if i >= b.len() || b[i] != b'{' {
        return Skim::default();
    }

    let mut out = Skim {
        is_object: true,
        ..Skim::default()
    };
    let mut depth = 0usize;
    // Set the moment a key may begin: just after the `{` that opens an object,
    // or after a `,` that separates its members.
    let mut key_position = false;

    while i < b.len() {
        match b[i] {
            b'"' => {
                let (text, next) = read_string(b, i);
                if depth == 1 && key_position {
                    if let Some(key) = text.as_deref() {
                        if key == "id" || key == "type" {
                            let mut j = next;
                            while j < b.len() && b[j].is_ascii_whitespace() {
                                j += 1;
                            }
                            if j < b.len() && b[j] == b':' {
                                j += 1;
                                while j < b.len() && b[j].is_ascii_whitespace() {
                                    j += 1;
                                }
                                if j < b.len() && b[j] == b'"' {
                                    if let (Some(value), _) = read_string(b, j) {
                                        if key == "id" {
                                            out.id = Some(value);
                                        } else {
                                            out.kind = Some(value);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                key_position = false;
                i = next;
                continue;
            }
            b'{' | b'[' => {
                depth += 1;
                out.max_depth = out.max_depth.max(depth);
                key_position = b[i] == b'{';
            }
            b'}' | b']' => {
                depth = depth.saturating_sub(1);
                key_position = false;
            }
            b',' => key_position = true,
            c if c.is_ascii_whitespace() => {}
            _ => key_position = false,
        }
        i += 1;
    }
    out
}

/// Read the JSON string starting at `b[start]` (which must be `"`). Returns
/// its decoded contents — `None` if it never closed — and the index one past
/// the closing quote.
///
/// Only the escapes that can appear in a key or in `id`/`type` are decoded;
/// `\u` is consumed and dropped rather than transcoded, because nothing here
/// needs the character, only the correct place to stop.
fn read_string(b: &[u8], start: usize) -> (Option<String>, usize) {
    let mut i = start + 1;
    let mut out: Vec<u8> = Vec::new();
    while i < b.len() {
        match b[i] {
            b'"' => return (Some(String::from_utf8_lossy(&out).into_owned()), i + 1),
            b'\\' => {
                i += 1;
                if i >= b.len() {
                    break;
                }
                match b[i] {
                    b'n' => out.push(b'\n'),
                    b't' => out.push(b'\t'),
                    b'r' => out.push(b'\r'),
                    b'b' => out.push(0x08),
                    b'f' => out.push(0x0c),
                    b'u' => i += 4,
                    other => out.push(other),
                }
                i += 1;
            }
            other => {
                out.push(other);
                i += 1;
            }
        }
    }
    // Unterminated. Say so, and hand back the end of the text so the caller
    // stops rather than looping; serde will reject the frame right after.
    (None, b.len())
}

/// Payload accessors that produce a `bad_request` rather than a silent
/// default: "the field was missing" is something a client needs told.
pub fn str_field(payload: &serde_json::Value, name: &str) -> Result<String> {
    payload
        .get(name)
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .ok_or_else(|| bad_request(format!("payload.{name} must be a string")))
}

/// The longest search string either search takes (PROTOCOL §4.12, §4.19).
/// Source is capped at 256 KiB and chat text at 64 KiB; a query was the one
/// string with no cap, and every byte of it becomes tokens, a padded copy per
/// word and an FTS5 `MATCH` term, all under the one database lock.
pub const MAX_QUERY_BYTES: usize = 1024;

/// `q`, or `bad_request` when it is longer than a search box could hold.
pub fn query_field(payload: &serde_json::Value) -> cwbhacker_core::error::Result<String> {
    let q = opt_str_field(payload, "q").unwrap_or_default();
    if q.len() > MAX_QUERY_BYTES {
        return Err(cwbhacker_core::error::bad_request(format!(
            "q is {} bytes; the limit is {MAX_QUERY_BYTES}",
            q.len()
        )));
    }
    Ok(q)
}

pub fn opt_str_field(payload: &serde_json::Value, name: &str) -> Option<String> {
    payload
        .get(name)
        .and_then(|v| v.as_str())
        .map(str::to_string)
}

pub fn i64_field(payload: &serde_json::Value, name: &str) -> Result<i64> {
    payload
        .get(name)
        .and_then(|v| v.as_i64())
        .ok_or_else(|| bad_request(format!("payload.{name} must be a number")))
}

pub fn opt_i64_field(payload: &serde_json::Value, name: &str) -> Option<i64> {
    payload.get(name).and_then(|v| v.as_i64())
}

pub fn bool_field(payload: &serde_json::Value, name: &str) -> bool {
    payload.get(name).and_then(|v| v.as_bool()).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn depth(text: &str) -> usize {
        skim(text).max_depth
    }

    #[test]
    fn braces_inside_a_string_are_not_nesting() {
        // The failure this guards against refuses every real `quest.submit`:
        // a program is a JSON string full of `{`, `}`, `"` and `\"`.
        let frame = serde_json::json!({
            "v": 1, "id": "c-1", "type": "quest.submit",
            "payload": { "source": "fn main() { let s = \"}}}\"; println!(\"{s}\"); }" }
        })
        .to_string();
        assert_eq!(
            depth(&frame),
            2,
            "the top object and the payload, and nothing from the program: {frame}"
        );
        match parse(&frame) {
            Incoming::Frame(f) => assert_eq!(f.kind, "quest.submit"),
            _ => panic!("a normal submission was refused"),
        }
    }

    #[test]
    fn an_escaped_backslash_before_a_quote_does_not_swallow_the_string() {
        // `"a\\"` ends at the second quote; a scanner that treated the `\\` as
        // escaping it would run on into the rest of the frame.
        let frame = r#"{"v":1,"id":"c-1","type":"ping","payload":{"s":"a\\"}}"#;
        assert_eq!(depth(frame), 2);
        assert!(matches!(parse(frame), Incoming::Frame(_)));
    }

    #[test]
    fn the_top_level_id_and_type_survive_a_frame_too_deep_to_parse() {
        let deep = format!(
            r#"{{"v":1,"id":"c-9","type":"quest.get","payload":{}}}"#,
            "[".repeat(300) + &"]".repeat(300)
        );
        match parse(&deep) {
            Incoming::Malformed { id, kind, error } => {
                assert_eq!(id.as_deref(), Some("c-9"));
                assert_eq!(kind, "quest.get");
                assert_eq!(error.code, cwbhacker_core::error::Code::BadRequest);
            }
            _ => panic!("a 300-deep frame was accepted"),
        }
    }

    #[test]
    fn a_frame_that_is_not_an_object_is_still_not_an_object() {
        for text in ["[1,2,3]", "\"hello\"", "42", "", "   ", "not json"] {
            assert!(
                matches!(parse(text), Incoming::NotAnObject),
                "{text:?} should be NotAnObject"
            );
        }
    }

    #[test]
    fn a_broken_object_is_left_to_serde() {
        // Depth is fine, the syntax is not: the existing 1003 behaviour.
        assert!(matches!(parse("{\"v\":1,"), Incoming::NotAnObject));
    }

    #[test]
    fn sixty_four_deep_is_allowed_and_sixty_five_is_not() {
        // The payload has to be an object all the way down, or the frame is
        // refused for that instead and the test proves nothing.
        let nest = |total: usize| {
            let inner = total - 1;
            format!(
                r#"{{"v":1,"id":"c-1","type":"ping","payload":{}1{}}}"#,
                r#"{"a":"#.repeat(inner),
                "}".repeat(inner)
            )
        };
        assert_eq!(depth(&nest(MAX_DEPTH)), MAX_DEPTH);
        assert!(matches!(parse(&nest(MAX_DEPTH)), Incoming::Frame(_)));
        assert_eq!(depth(&nest(MAX_DEPTH + 1)), MAX_DEPTH + 1);
        assert!(matches!(
            parse(&nest(MAX_DEPTH + 1)),
            Incoming::Malformed { .. }
        ));
    }
}
