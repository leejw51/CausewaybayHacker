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

    /// Look a challenge up without spending it, and hand back the message it
    /// was issued with.
    ///
    /// Spending is a separate step ([`Challenges::burn`]) so that a signature
    /// that fails to verify leaves the challenge live: a mistyped mnemonic
    /// should cost the player a retry, not a round trip for a new nonce. The
    /// challenge still dies on success, and still dies at `expires_at`.
    pub fn peek(&self, address: &str, nonce: &str) -> Result<String> {
        let address = normalize_address(address)?;
        let mut entries = self.entries.lock().unwrap();
        sweep(&mut entries);
        let entry = entries
            .get(nonce)
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
        Ok(entry.message.clone())
    }

    /// Spend a challenge. Called only once a signature has verified.
    pub fn burn(&self, nonce: &str) {
        let mut entries = self.entries.lock().unwrap();
        if let Some(entry) = entries.get_mut(nonce) {
            entry.used = true;
        }
    }

    /// Look a challenge up **and** spend it, whatever happens next. Kept for
    /// the tests that assert §3.2's single-use rule directly; the login path
    /// uses [`Challenges::peek`] and [`Challenges::burn`].
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
        let (nonce, message) = self.peek_for(address, nonce)?;
        self.burn(&nonce);
        Ok(message)
    }

    /// The newest live challenge for an address, or the one a client named.
    /// `auth.login`'s payload is `{address, signature}` (PROTOCOL §4.3) — it
    /// does not carry the nonce back, so the server remembers which challenge
    /// it issued. A client that does send a `nonce` gets exactly that one,
    /// which is what a test harness wants.
    pub fn peek_for(&self, address: &str, nonce: Option<&str>) -> Result<(String, String)> {
        if let Some(nonce) = nonce {
            return Ok((nonce.to_string(), self.peek(address, nonce)?));
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
            Some(nonce) => {
                let message = self.peek(&address, &nonce)?;
                Ok((nonce, message))
            }
            None => Err(Error::new(
                Code::AuthExpired,
                "no live challenge for that address",
            )),
        }
    }

    /// The whole of PROTOCOL §4.3's step 4: find the challenge this signature
    /// is over, check it, and spend it — in that order, **under one lock**.
    ///
    /// `auth.login` carries `{address, signature}` and **not** the nonce, so
    /// the server has to work out which of its outstanding challenges the
    /// client signed. Trying them all rather than assuming the newest is what
    /// makes the refusal honest: a replay of a signature over a spent
    /// challenge is `auth_nonce_used`, not `auth_bad_signature`, and those are
    /// two different instructions to the player — "ask for a new challenge"
    /// against "your key is wrong".
    ///
    /// A signature that verifies against nothing leaves every challenge live.
    /// A mistyped mnemonic should cost a retry, not a round trip.
    ///
    /// The mutex is held from the lookup through the burn. Checking unlocked
    /// and burning afterwards let two logins carrying the same signature both
    /// see the challenge unused and both pass; single-use (SPEC §3.2) means
    /// the check and the spend are one step.
    pub fn login(&self, claimed: &str, signature_hex: &str, nonce: Option<&str>) -> Result<String> {
        let address = normalize_address(claimed)?;
        let mut entries = self.entries.lock().unwrap();
        sweep(&mut entries);

        if let Some(nonce) = nonce {
            // A client that named a nonce gets exactly that one's verdict.
            let entry = entries
                .get(nonce)
                .ok_or_else(|| Error::new(Code::AuthExpired, "the challenge expired"))?;
            if entry.used {
                return Err(Error::new(Code::AuthNonceUsed, "the challenge was used"));
            }
            if entry.address != address {
                return Err(Error::new(
                    Code::AuthBadSignature,
                    "the challenge was issued for another address",
                ));
            }
            let who = verify_login(&address, &entry.message, signature_hex)?;
            if let Some(entry) = entries.get_mut(nonce) {
                entry.used = true;
            }
            return Ok(who);
        }

        let mut candidates: Vec<(String, String, bool, chrono::DateTime<chrono::Utc>)> = entries
            .iter()
            .filter(|(_, e)| e.address == address)
            .map(|(nonce, e)| (nonce.clone(), e.message.clone(), e.used, e.expires_at))
            .collect();
        // Newest first: the challenge a client just asked for is the one it
        // is most likely to have signed.
        candidates.sort_by_key(|entry| std::cmp::Reverse(entry.3));
        if candidates.is_empty() {
            return Err(Error::new(
                Code::AuthExpired,
                "no live challenge for that address",
            ));
        }

        let mut any_unused = false;
        for (nonce, message, used, _) in candidates {
            if !used {
                any_unused = true;
            }
            match recover_address(&message, signature_hex) {
                Ok(recovered) if recovered.eq_ignore_ascii_case(&address) => {
                    if used {
                        return Err(Error::new(Code::AuthNonceUsed, "the challenge was used"));
                    }
                    // Spent through the guard this check was made under: no
                    // window between "unused" and "used" for a second copy
                    // of the same signature to slip through.
                    if let Some(entry) = entries.get_mut(&nonce) {
                        entry.used = true;
                    }
                    return Ok(address);
                }
                // A malformed signature is malformed whichever challenge it is
                // held against, so there is no point trying the rest.
                Err(e)
                    if e.code == Code::AuthBadSignature
                        && !signature_is_wellformed(signature_hex) =>
                {
                    return Err(e)
                }
                _ => continue,
            }
        }
        if any_unused {
            Err(Error::new(
                Code::AuthBadSignature,
                "the signature does not belong to that address",
            ))
        } else {
            Err(Error::new(Code::AuthNonceUsed, "the challenge was used"))
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

/// A 65-byte hex blob with a recovery byte this code understands. Used to
/// tell "the client sent nonsense" apart from "the client signed the wrong
/// message", which get different answers.
fn signature_is_wellformed(signature_hex: &str) -> bool {
    let cleaned = signature_hex.trim();
    let cleaned = cleaned.strip_prefix("0x").unwrap_or(cleaned);
    match hex::decode(cleaned) {
        Ok(bytes) => bytes.len() == 65,
        Err(_) => false,
    }
}

/// Step 4 of §3.2: recover, compare case-insensitively, and hand back the
/// lowercase canonical address. Pure: the caller ([`Challenges::login`])
/// spends the nonce only once this has verified, under the lock it looked
/// the challenge up with.
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
        // PROTOCOL §4.4: "an expired or unknown token is `unauthorized`". The
        // two are one answer on purpose — a client holding either has nothing
        // to wait for and goes to the login screen. `auth_expired` is the
        // *challenge* running out, which is a different instruction ("ask
        // again").
        return Err(Error::new(Code::Unauthorized, "the session expired"));
    }
    let fresh = stamp(now() + chrono::Duration::days(SESSION_TTL_DAYS));
    conn.execute(
        "UPDATE sessions SET expires_at = ?2 WHERE token_hash = ?1",
        params![hash, fresh],
    )?;
    Ok(address)
}

/// Whose token this is, and nothing else: no refresh, no rotation, no row
/// touched. The same verdicts as [`resume_session`] — unknown and expired are
/// both `unauthorized` — so a caller can decide whether it is *allowed* to
/// resume before anything is spent. An expired row is left where it is
/// rather than deleted, because a read-only question should not have a
/// side effect; `purge_expired_sessions` and the next real resume clear it.
pub fn session_address(conn: &Connection, token: &str) -> Result<String> {
    let row: Option<(String, String)> = conn
        .query_row(
            "SELECT address, expires_at FROM sessions WHERE token_hash = ?1",
            params![token_hash(token)],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let (address, expires_at) =
        row.ok_or_else(|| Error::new(Code::Unauthorized, "unknown session token"))?;
    let expired = parse(&expires_at).map(|t| t <= now()).unwrap_or(true);
    if expired {
        return Err(Error::new(Code::Unauthorized, "the session expired"));
    }
    Ok(address)
}

/// PROTOCOL §4.4: `auth.resume` **rotates** the token. The old one stops
/// working the moment the new one is handed over, so a token read off a disk
/// backup is good for exactly one resume rather than thirty days.
///
/// One transaction: the old row goes and the new one comes in the same
/// step, or neither does. Without it a failure between the INSERT and the
/// DELETE — or a caller that gives up between them — leaves either two live
/// tokens for one resume or none at all.
pub fn rotate_session(conn: &Connection, token: &str) -> Result<(String, String)> {
    let tx = rusqlite::Transaction::new_unchecked(conn, rusqlite::TransactionBehavior::Immediate)?;
    let address = resume_session(&tx, token)?;
    let fresh = mint_session(&tx, &address)?;
    tx.execute(
        "DELETE FROM sessions WHERE token_hash = ?1",
        params![token_hash(token)],
    )?;
    tx.commit()?;
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
