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
