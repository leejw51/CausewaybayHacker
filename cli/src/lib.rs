//! Causewaybay Hacker — the terminal client.
//!
//! The fourth implementation of `PROTOCOL.md`, after the browser
//! (`frontend/`), the LÖVE desktop client (`love2d/`) and the smoke harness
//! (`tests/smoke/`). Everything that crosses the network is that file's, not
//! this one's.
//!
//! The split, which is `CausewaybayWallet`'s: the modules below are the client
//! with no terminal attached — they take arguments and return data. What only
//! a terminal has (argv, a tty to prompt on without echo, `$EDITOR`, an exit
//! status, a full-screen TUI) lives in `main.rs`, `secret.rs` and `tui/`.

pub mod bip32;
pub mod bip39;
pub mod client;
pub mod error;
pub mod proto;
pub mod render;
pub mod server;
pub mod session;
pub mod store;
pub mod wallet;
pub mod workspace;

pub use error::{Code, Error, Result};
