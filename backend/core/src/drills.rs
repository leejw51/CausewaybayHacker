//! AI drills (SPEC §7.3) — the module boundary, and nothing behind it yet.
//!
//! The `drills` table exists in 0001 and the three plan shapes are specified;
//! building them is milestone 2. Until then every `ai.*` call gets the same
//! clean refusal.

use crate::error::{Code, Error, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Repeat,
    Weakness,
    Spaced,
}

impl Mode {
    pub fn parse(s: &str) -> Result<Mode> {
        Ok(match s {
            "repeat" => Mode::Repeat,
            "weakness" => Mode::Weakness,
            "spaced" => Mode::Spaced,
            other => {
                return Err(crate::error::bad_request(format!(
                    "unknown drill mode '{other}'"
                )))
            }
        })
    }
}

pub fn plan(_address: &str, _mode: Mode, _size: usize) -> Result<serde_json::Value> {
    Err(Error::new(
        Code::NotFound,
        "drills are not in this build yet (SPEC §7.3, milestone 2)",
    ))
}
