//! Challenge–response login (SPEC §3.2) and the session table (§3.3).
//!
//! Nothing here ever receives key material. The client signs the exact string
//! the server handed it, and the server recovers the address from the
//! signature.

use std::collections::HashMap;
use std::sync::Mutex;

use base64::Engine;
use rand::RngCore;
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::error::{Code, Error, Result};
use crate::eth::{normalize_address, recover_address, to_eip55};
use crate::time::{now, now_stamp, parse, stamp};

pub const CHALLENGE_TTL_SECS: i64 = 120;
pub const SESSION_TTL_DAYS: i64 = 30;

#[derive(Debug, Clone, Serialize)]
pub struct Challenge {
    pub nonce: String,
    pub message: String,
    pub expires_at: String,
}

struct Entry {
    address: String,
    message: String,
    expires_at: chrono::DateTime<chrono::Utc>,
    used: bool,
}

/// The live nonces. In memory with their expiry and single-use, per SPEC §3.2
/// — a restart invalidates every outstanding challenge, which is correct: a
/// challenge is 120 seconds of state, not a record.
#[derive(Default)]
pub struct Challenges {
    entries: Mutex<HashMap<String, Entry>>,
}

impl Challenges {
    pub fn new() -> Self {
        Self::default()
    }

    /// Mint a nonce and the exact message to sign. The message is kept here
    /// verbatim and verified against later: the bytes the server handed out
    /// are the contract, so no rendering difference can creep in between
    /// issuing and checking.
    pub fn issue(&self, address: &str) -> Result<Challenge> {
        self.issue_with_ttl(address, CHALLENGE_TTL_SECS)
    }

    /// The same, with the lifetime chosen by the caller. Expiry is a rule
    /// worth a test, and a test that waits 120 seconds is a test nobody runs.
    pub fn issue_with_ttl(&self, address: &str, ttl_secs: i64) -> Result<Challenge> {
        let address = normalize_address(address)?;
        let mut raw = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut raw);
        let nonce = hex::encode(raw);
        let expires = now() + chrono::Duration::seconds(ttl_secs);
        let expires_at = stamp(expires);
        let message = format!(
            "Causewaybay Hacker login\naddress: {}\nnonce: {}\nexpires: {}",
            to_eip55(&address),
            nonce,
            expires_at
        );
        let mut entries = self.entries.lock().unwrap();
        sweep(&mut entries);
        entries.insert(
            nonce.clone(),
            Entry {
                address: address.clone(),
                message: message.clone(),
                expires_at: expires,
                used: false,
            },
        );
        Ok(Challenge {
            nonce,
            message,
            expires_at,
        })
    }

    /// Burn a nonce and hand back the message it was issued with.
    ///
    /// A replay inside the window is `auth_nonce_used`; one after it, or a
    /// nonce nobody issued, is `auth_expired` (§3.2).
    pub fn redeem(&self, address: &str, nonce: &str) -> Result<String> {
        let address = normalize_address(address)?;
        let mut entries = self.entries.lock().unwrap();
        sweep(&mut entries);
        let entry = entries
            .get_mut(nonce)
            .ok_or_else(|| Error::new(Code::AuthExpired, "the challenge expired"))?;
        if entry.expires_at <= now() {
            return Err(Error::new(Code::AuthExpired, "the challenge expired"));
        }
        if entry.used {
            return Err(Error::new(Code::AuthNonceUsed, "the challenge was used"));
        }
        if entry.address != address {
            return Err(Error::new(
                Code::AuthBadSignature,
                "the challenge was issued for another address",
            ));
        }
        entry.used = true;
        Ok(entry.message.clone())
    }

    /// `auth.login`'s payload is `{address, signature}` (SPEC §6.2) — it does
    /// not carry the nonce back. The server therefore remembers which
    /// challenge it issued for that address and redeems the newest live one.
    /// A client that does send a `nonce` gets exactly that one, which is what
    /// a test harness wants.
    pub fn redeem_for(&self, address: &str, nonce: Option<&str>) -> Result<String> {
        if let Some(nonce) = nonce {
            return self.redeem(address, nonce);
        }
        let address = normalize_address(address)?;
        let newest = {
            let mut entries = self.entries.lock().unwrap();
            sweep(&mut entries);
            entries
                .iter()
                .filter(|(_, e)| e.address == address && !e.used && e.expires_at > now())
                .max_by_key(|(_, e)| e.expires_at)
                .map(|(nonce, _)| nonce.clone())
        };
        match newest {
            Some(nonce) => self.redeem(&address, &nonce),
            None => Err(Error::new(
                Code::AuthExpired,
                "no live challenge for that address",
            )),
        }
    }

    pub fn len(&self) -> usize {
        let mut entries = self.entries.lock().unwrap();
        sweep(&mut entries);
        entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Expired entries are dropped, used or not — after the deadline the answer
/// is `auth_expired` either way, so there is nothing left to remember.
fn sweep(entries: &mut HashMap<String, Entry>) {
    let cutoff = now();
    entries.retain(|_, e| e.expires_at > cutoff);
}

/// Step 4 of §3.2: recover, compare case-insensitively, and hand back the
/// lowercase canonical address. The nonce is burned by the caller first, so a
/// bad signature does not let the same nonce be tried again.
pub fn verify_login(claimed: &str, message: &str, signature_hex: &str) -> Result<String> {
    let claimed = normalize_address(claimed)?;
    let recovered = recover_address(message, signature_hex)?;
    if !recovered.eq_ignore_ascii_case(&claimed) {
        return Err(Error::new(
            Code::AuthBadSignature,
            "the signature does not belong to that address",
        ));
    }
    Ok(claimed)
}

pub fn token_hash(token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hex::encode(hasher.finalize())
}

/// 32 random bytes, base64url. Only the sha256 is stored (§3.3), so a stolen
/// database does not hand over live sessions.
pub fn mint_session(conn: &Connection, address: &str) -> Result<String> {
    let mut raw = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut raw);
    let token = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(raw);
    let expires = now() + chrono::Duration::days(SESSION_TTL_DAYS);
    conn.execute(
        "INSERT INTO sessions (token_hash, address, created_at, expires_at)
         VALUES (?1, ?2, ?3, ?4)",
        params![
            token_hash(&token),
            address.to_ascii_lowercase(),
            now_stamp(),
            stamp(expires)
        ],
    )?;
    Ok(token)
}

/// Trade a token for the address it belongs to, refreshing its lifetime
/// (§3.3 "refreshed on use"). An expired row is deleted rather than left to
/// accumulate.
pub fn resume_session(conn: &Connection, token: &str) -> Result<String> {
    let hash = token_hash(token);
    let row: Option<(String, String)> = conn
        .query_row(
            "SELECT address, expires_at FROM sessions WHERE token_hash = ?1",
            params![hash],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let (address, expires_at) =
        row.ok_or_else(|| Error::new(Code::Unauthorized, "unknown session token"))?;
    let expired = parse(&expires_at).map(|t| t <= now()).unwrap_or(true);
    if expired {
        conn.execute("DELETE FROM sessions WHERE token_hash = ?1", params![hash])?;
        return Err(Error::new(Code::AuthExpired, "the session expired"));
    }
    let fresh = stamp(now() + chrono::Duration::days(SESSION_TTL_DAYS));
    conn.execute(
        "UPDATE sessions SET expires_at = ?2 WHERE token_hash = ?1",
        params![hash, fresh],
    )?;
    Ok(address)
}

/// PROTOCOL §4.4: `auth.resume` **rotates** the token. The old one stops
/// working the moment the new one is handed over, so a token read off a disk
/// backup is good for exactly one resume rather than thirty days.
pub fn rotate_session(conn: &Connection, token: &str) -> Result<(String, String)> {
    let address = resume_session(conn, token)?;
    let fresh = mint_session(conn, &address)?;
    conn.execute(
        "DELETE FROM sessions WHERE token_hash = ?1",
        params![token_hash(token)],
    )?;
    Ok((address, fresh))
}

/// Everything a wallet has open stops working. PROTOCOL §1.2's close code
/// 4001 is what a connection gets told when this happens under it.
pub fn revoke_all(conn: &Connection, address: &str) -> Result<usize> {
    Ok(conn.execute(
        "DELETE FROM sessions WHERE address = ?1",
        params![address.to_ascii_lowercase()],
    )?)
}

pub fn revoke_session(conn: &Connection, token: &str) -> Result<()> {
    conn.execute(
        "DELETE FROM sessions WHERE token_hash = ?1",
        params![token_hash(token)],
    )?;
    Ok(())
}

/// Housekeeping for `cwbhacker prune` and startup.
pub fn purge_expired_sessions(conn: &Connection) -> Result<usize> {
    Ok(conn.execute(
        "DELETE FROM sessions WHERE expires_at <= ?1",
        params![now_stamp()],
    )?)
}
