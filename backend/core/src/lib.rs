//! Causewaybay Hacker — the domain.
//!
//! No terminal, no socket, no `process::exit`. Every operation is a function
//! that takes what it needs and returns data or an [`error::Error`] carrying
//! one of SPEC §6.1's codes. The server turns those into frames; the CLI turns
//! them into exit statuses. Neither concern lives here.

pub mod attempts;
pub mod auth;
pub mod content;
pub mod db;
pub mod drills;
pub mod error;
pub mod eth;
pub mod ids;
pub mod mistakes;
pub mod paths;
pub mod progress;
pub mod quests;
pub mod search;
pub mod stats;
pub mod store;
pub mod time;
pub mod users;
pub mod world;

pub use error::{Code, Error, Result};
/// Re-exported so a crate that only talks to the store does not have to pin
/// the same `rusqlite` version this one does.
pub use rusqlite::Connection;
pub use paths::Home;
pub use store::Store;
