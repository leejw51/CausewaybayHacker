//! The envelope of SPEC §6.1.
//!
//! `{ "v": 1, "id": "c-42", "type": "quest.submit", "payload": { } }` in both
//! directions. A reply is `<type>.ok` or `<type>.err`; a server-initiated
//! event has `id: null`.

use serde::{Deserialize, Serialize};

use cwbhacker_core::error::Error;

pub const PROTOCOL_VERSION: i64 = 1;

#[derive(Debug, Clone, Deserialize)]
pub struct ClientFrame {
    #[serde(default)]
    pub v: Option<i64>,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(rename = "type", default)]
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

    /// An unsolicited event (§6.2): `run.log`, `run.stage`, `progress.update`,
    /// `award`, `server.bye`. Always `id: null`.
    pub fn event(kind: &str, payload: serde_json::Value) -> ServerFrame {
        ServerFrame {
            v: PROTOCOL_VERSION,
            id: None,
            kind: kind.to_string(),
            payload,
        }
    }
}

/// Payload accessors that produce a `bad_request` rather than a silent
/// default, because "the field was missing" is something the frontend needs
/// told, not guessed around.
pub fn str_field(payload: &serde_json::Value, name: &str) -> cwbhacker_core::Result<String> {
    payload
        .get(name)
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .ok_or_else(|| {
            cwbhacker_core::error::bad_request(format!("payload.{name} must be a string"))
        })
}

pub fn opt_str_field(payload: &serde_json::Value, name: &str) -> Option<String> {
    payload
        .get(name)
        .and_then(|v| v.as_str())
        .map(str::to_string)
}

pub fn i64_field(payload: &serde_json::Value, name: &str) -> cwbhacker_core::Result<i64> {
    payload.get(name).and_then(|v| v.as_i64()).ok_or_else(|| {
        cwbhacker_core::error::bad_request(format!("payload.{name} must be a number"))
    })
}

pub fn opt_i64_field(payload: &serde_json::Value, name: &str) -> Option<i64> {
    payload.get(name).and_then(|v| v.as_i64())
}
