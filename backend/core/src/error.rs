//! The error type, carrying one of SPEC §6.1's closed set of codes.
//!
//! The set is closed on purpose: the frontend branches on `code`, so a new
//! string invented at a call site is a protocol change, not a detail.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Code {
    ProtoVersion,
    BadRequest,
    Unauthorized,
    AuthExpired,
    AuthNonceUsed,
    AuthBadSignature,
    NotFound,
    /// Real, specified, and not built yet. Distinct from `Internal` ("the
    /// server broke, a retry might help") and from `NotFound` ("no such
    /// thing"): a client renders it in the story's voice rather than as a
    /// failure. PROTOCOL §3.3 tells a client to treat an unknown code as
    /// `internal`, so an old client degrades to exactly the old behaviour.
    Unavailable,
    Locked,
    RateLimited,
    Busy,
    Internal,
}

impl Code {
    pub fn as_str(self) -> &'static str {
        match self {
            Code::ProtoVersion => "proto_version",
            Code::BadRequest => "bad_request",
            Code::Unauthorized => "unauthorized",
            Code::AuthExpired => "auth_expired",
            Code::AuthNonceUsed => "auth_nonce_used",
            Code::AuthBadSignature => "auth_bad_signature",
            Code::NotFound => "not_found",
            Code::Unavailable => "unavailable",
            Code::Locked => "locked",
            Code::RateLimited => "rate_limited",
            Code::Busy => "busy",
            Code::Internal => "internal",
        }
    }
}

impl fmt::Display for Code {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone)]
pub struct Error {
    pub code: Code,
    pub message: String,
    pub detail: serde_json::Value,
}

impl Error {
    pub fn new(code: Code, message: impl Into<String>) -> Self {
        Error {
            code,
            message: message.into(),
            detail: serde_json::Value::Object(Default::default()),
        }
    }

    pub fn with_detail(mut self, detail: serde_json::Value) -> Self {
        self.detail = detail;
        self
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

pub fn bad_request(m: impl Into<String>) -> Error {
    Error::new(Code::BadRequest, m)
}
pub fn unauthorized(m: impl Into<String>) -> Error {
    Error::new(Code::Unauthorized, m)
}
pub fn not_found(m: impl Into<String>) -> Error {
    Error::new(Code::NotFound, m)
}
pub fn locked(m: impl Into<String>) -> Error {
    Error::new(Code::Locked, m)
}
/// Specified, not built. Always carries the milestone it is waiting on, so a
/// client can say *when* rather than only *no*.
pub fn unavailable(m: impl Into<String>, milestone: u32) -> Error {
    Error::new(Code::Unavailable, m).with_detail(serde_json::json!({ "milestone": milestone }))
}
/// Too many, too fast. **Always** carries `detail.retry_after_ms` — PROTOCOL
/// §3.3 tells a client to "back off; `detail.retry_after_ms`", and a client
/// that is told to back off but not for how long either hammers or gives up.
pub fn rate_limited(m: impl Into<String>, retry_after_ms: u64) -> Error {
    Error::new(Code::RateLimited, m)
        .with_detail(serde_json::json!({ "retry_after_ms": retry_after_ms }))
}
pub fn internal(m: impl Into<String>) -> Error {
    Error::new(Code::Internal, m)
}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        internal(format!("database: {e}"))
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        internal(format!("io: {e}"))
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        internal(format!("json: {e}"))
    }
}
