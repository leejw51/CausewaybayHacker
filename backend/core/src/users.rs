//! The user row (SPEC §2.1) and the mirror of it on disk (§1 `profile.json`).

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::error::{not_found, Result};
use crate::eth::to_eip55;
use crate::paths::{write_private, Home};
use crate::time::now_stamp;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub address: String,
    pub address_eip55: String,
    pub name: String,
    pub created_at: String,
    pub last_seen_at: String,
    pub settings: serde_json::Value,
}

/// Create the row on first sight, refresh `last_seen_at` on every one after.
/// The name is only defaulted, never overwritten: a returning player keeps
/// whatever they chose.
pub fn upsert(conn: &Connection, address: &str) -> Result<User> {
    upsert_named(conn, address, None)
}

/// The same, with the display name a first login may seed (PROTOCOL §4.3).
/// An existing user keeps whatever they chose: `name` is only ever a default.
pub fn upsert_named(conn: &Connection, address: &str, name: Option<&str>) -> Result<User> {
    let address = address.to_ascii_lowercase();
    let now = now_stamp();
    let eip55 = to_eip55(&address);
    // The name a client seeded, or one derived from the address. It used to be
    // `hacker-<first 6 of address>`, which is hex with a word in front and has
    // hex's problem: `hacker-58a57e` and `hacker-0d3eb2` are two accounts one
    // player owns, and neither is a name anybody would say out loud or
    // recognise a day later. `username::deterministic` gives the same address
    // the same `AdjectiveNoun####` on every client, forever, which is what
    // makes it safe to fill a login box in with.
    //
    // Only ever a **default**. The `ON CONFLICT` below does not touch `name`,
    // so an account that already exists keeps whatever it has — including the
    // `hacker-…` names handed out before this, which are still that player's
    // name until they change it.
    let default_name = match name.map(str::trim).filter(|n| !n.is_empty()) {
        Some(name) => name.chars().take(48).collect::<String>(),
        None => crate::username::deterministic(&address),
    };
    conn.execute(
        "INSERT INTO users (address, address_eip55, name, created_at, last_seen_at, settings)
         VALUES (?1, ?2, ?3, ?4, ?4, '{}')
         ON CONFLICT(address) DO UPDATE SET last_seen_at = ?4, address_eip55 = ?2",
        params![address, eip55, default_name, now],
    )?;
    get(conn, &address)
}

pub fn get(conn: &Connection, address: &str) -> Result<User> {
    let address = address.to_ascii_lowercase();
    conn.query_row(
        "SELECT address, address_eip55, name, created_at, last_seen_at, settings
           FROM users WHERE address = ?1",
        params![address],
        row_to_user,
    )
    .optional()?
    .ok_or_else(|| not_found("no such user"))
}

fn row_to_user(row: &rusqlite::Row<'_>) -> rusqlite::Result<User> {
    let settings: String = row.get(5)?;
    Ok(User {
        address: row.get(0)?,
        address_eip55: row.get(1)?,
        name: row.get(2)?,
        created_at: row.get(3)?,
        last_seen_at: row.get(4)?,
        settings: serde_json::from_str(&settings).unwrap_or_else(|_| serde_json::json!({})),
    })
}

/// `profile.update` (SPEC §6.2). Both fields are optional; an absent one is
/// left alone rather than cleared.
pub fn update_profile(
    conn: &Connection,
    address: &str,
    name: Option<&str>,
    settings: Option<&serde_json::Value>,
) -> Result<User> {
    let address = address.to_ascii_lowercase();
    if let Some(name) = name {
        let name = name.trim();
        if !name.is_empty() {
            let name: String = name.chars().take(48).collect();
            conn.execute(
                "UPDATE users SET name = ?2 WHERE address = ?1",
                params![address, name],
            )?;
        }
    }
    if let Some(settings) = settings {
        conn.execute(
            "UPDATE users SET settings = ?2 WHERE address = ?1",
            params![address, settings.to_string()],
        )?;
    }
    get(conn, &address)
}

/// The on-disk copy of §1. The database is the truth; this is so a user can
/// read their own directory without sqlite, which is the whole point of
/// keeping the home human-shaped.
pub fn write_profile(home: &Home, user: &User) -> Result<()> {
    home.ensure_user_dirs(&user.address)?;
    write_private(
        &home.profile_path(&user.address),
        serde_json::to_vec_pretty(user)?,
    )
}
