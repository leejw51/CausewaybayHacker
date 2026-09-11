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

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClientFrame {
    pub v: i64,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default = "empty_object")]
    pub payload: serde_json::Value,
}

fn empty_object() -> serde_json::Value {
    serde_json::Value::Object(Default::default())
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

/// Payload accessors that produce a `bad_request` rather than a silent
/// default: "the field was missing" is something a client needs told.
pub fn str_field(payload: &serde_json::Value, name: &str) -> Result<String> {
    payload
        .get(name)
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .ok_or_else(|| bad_request(format!("payload.{name} must be a string")))
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
