//! One error type for the whole client.
//!
//! It carries the protocol's own `code` (PROTOCOL §3.3) unchanged when the
//! failure came from the server, so a command can switch on it exhaustively
//! without re-parsing strings, and adds the codes only a client can have
//! (a bad mnemonic, a missing editor, a socket that went away).

use std::fmt;

/// PROTOCOL §3.3's closed set, plus the client's own.
///
/// `Unknown` is what an unrecognised server code becomes. §3.3: *"A code not
/// in this table is a server bug. A client encountering one should treat it as
/// `internal`."* Keeping the original string means the log can still say what
/// it was.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Code {
    // --- the wire's closed set ---
    ProtoVersion,
    BadRequest,
    Unauthorized,
    AuthExpired,
    AuthNonceUsed,
    AuthBadSignature,
    NotFound,
    Locked,
    RateLimited,
    Busy,
    Unavailable,
    Internal,
    /// A server code this client does not know. Treated as `internal`.
    Unknown(String),

    // --- the client's own ---
    Usage,
    InvalidMnemonic,
    InvalidPrivateKey,
    /// The connection dropped. Not a protocol error; PROTOCOL §6.
    Disconnected,
    /// A reply this client could not read — the payload did not match §5's
    /// shape. Deliberately *not* `bad_request`: that code means the server
    /// refused something this client sent, and blaming it for a field this
    /// client got wrong sends the reader to the wrong half of the system.
    Malformed,
    Io,
}

impl Code {
    pub fn from_wire(code: &str) -> Code {
        match code {
            "proto_version" => Code::ProtoVersion,
            "bad_request" => Code::BadRequest,
            "unauthorized" => Code::Unauthorized,
            "auth_expired" => Code::AuthExpired,
            "auth_nonce_used" => Code::AuthNonceUsed,
            "auth_bad_signature" => Code::AuthBadSignature,
            "not_found" => Code::NotFound,
            "locked" => Code::Locked,
            "rate_limited" => Code::RateLimited,
            "busy" => Code::Busy,
            "unavailable" => Code::Unavailable,
            "internal" => Code::Internal,
            other => Code::Unknown(other.to_string()),
        }
    }

    pub fn as_str(&self) -> &str {
        match self {
            Code::ProtoVersion => "proto_version",
            Code::BadRequest => "bad_request",
            Code::Unauthorized => "unauthorized",
            Code::AuthExpired => "auth_expired",
            Code::AuthNonceUsed => "auth_nonce_used",
            Code::AuthBadSignature => "auth_bad_signature",
            Code::NotFound => "not_found",
            Code::Locked => "locked",
            Code::RateLimited => "rate_limited",
            Code::Busy => "busy",
            Code::Unavailable => "unavailable",
            Code::Internal => "internal",
            Code::Unknown(s) => s,
            Code::Usage => "usage",
            Code::InvalidMnemonic => "invalid_mnemonic",
            Code::InvalidPrivateKey => "invalid_private_key",
            Code::Disconnected => "disconnected",
            Code::Malformed => "malformed_reply",
            Code::Io => "io",
        }
    }

    /// §3.3: an unknown code degrades to exactly `internal`'s behaviour.
    pub fn effective(&self) -> &Code {
        match self {
            Code::Unknown(_) => &Code::Internal,
            other => other,
        }
    }

    /// The exit status a shell should see. `2` is the conventional usage
    /// failure, which is what `cwbh` uses for a wrong command line.
    pub fn exit_status(&self) -> u8 {
        match self {
            Code::Usage => 2,
            _ => 1,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Error {
    pub code: Code,
    /// One line, English, for a log — PROTOCOL §3.3. Never rendered as the
    /// player-facing sentence; the commands write their own from `code`.
    pub message: String,
    pub detail: serde_json::Value,
}

impl Error {
    pub fn new(code: Code, message: impl Into<String>) -> Error {
        Error {
            code,
            message: message.into(),
            detail: serde_json::json!({}),
        }
    }

    pub fn with_detail(mut self, detail: serde_json::Value) -> Error {
        self.detail = detail;
        self
    }

    /// `detail.milestone` for `unavailable`, `detail.trace_id` for `internal`.
    pub fn detail_str(&self, key: &str) -> Option<&str> {
        self.detail.get(key).and_then(|v| v.as_str())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Error {
        Error::new(Code::Io, e.to_string())
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Error {
        Error::new(Code::Malformed, format!("could not read the reply: {e}"))
    }
}

pub type Result<T> = std::result::Result<T, Error>;

pub fn usage(message: impl Into<String>) -> Error {
    Error::new(Code::Usage, message)
}
pub fn internal(message: impl Into<String>) -> Error {
    Error::new(Code::Internal, message)
}
pub fn invalid_mnemonic(message: impl Into<String>) -> Error {
    Error::new(Code::InvalidMnemonic, message)
}
pub fn invalid_private_key(message: impl Into<String>) -> Error {
    Error::new(Code::InvalidPrivateKey, message)
}
pub fn disconnected(message: impl Into<String>) -> Error {
    Error::new(Code::Disconnected, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_wire_code_round_trips() {
        for code in [
            "proto_version",
            "bad_request",
            "unauthorized",
            "auth_expired",
            "auth_nonce_used",
            "auth_bad_signature",
            "not_found",
            "locked",
            "rate_limited",
            "busy",
            "unavailable",
            "internal",
        ] {
            let parsed = Code::from_wire(code);
            assert!(!matches!(parsed, Code::Unknown(_)), "{code} not in the set");
            assert_eq!(parsed.as_str(), code);
        }
    }

    /// §8.4. A code added to the server tomorrow must behave here today
    /// exactly as `internal` does.
    #[test]
    fn an_unknown_code_degrades_to_internal() {
        let parsed = Code::from_wire("quantum_flux");
        assert_eq!(parsed, Code::Unknown("quantum_flux".into()));
        assert_eq!(parsed.effective(), &Code::Internal);
        assert_eq!(parsed.as_str(), "quantum_flux");
    }
}
