//! The Ethereum-shaped half of identity: keccak256, EIP-55 rendering, and
//! recovering an address from an EIP-191 personal signature (SPEC §3).
//!
//! Nothing here ever sees a private key. The browser signs; this recovers.

use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
use sha3::{Digest, Keccak256};

use crate::error::{Code, Error, Result};

pub fn keccak256(bytes: &[u8]) -> [u8; 32] {
    let mut hasher = Keccak256::new();
    hasher.update(bytes);
    hasher.finalize().into()
}

/// `keccak256(uncompressed_pubkey[1..])[12..]`, lowercase 0x hex.
pub fn address_from_pubkey(key: &VerifyingKey) -> String {
    let point = key.to_encoded_point(false);
    let digest = keccak256(&point.as_bytes()[1..]);
    format!("0x{}", hex::encode(&digest[12..]))
}

/// EIP-55: uppercase a hex nibble when the matching nibble of the keccak of
/// the lowercase address is >= 8. Display only — `users.address` stays
/// lowercase (SPEC §3.4).
pub fn to_eip55(address: &str) -> String {
    let lower = address.trim_start_matches("0x").to_ascii_lowercase();
    let hash = keccak256(lower.as_bytes());
    let mut out = String::with_capacity(42);
    out.push_str("0x");
    for (i, ch) in lower.chars().enumerate() {
        let nibble = if i % 2 == 0 {
            hash[i / 2] >> 4
        } else {
            hash[i / 2] & 0x0f
        };
        if ch.is_ascii_alphabetic() && nibble >= 8 {
            out.push(ch.to_ascii_uppercase());
        } else {
            out.push(ch);
        }
    }
    out
}

/// Accept `0xABC…` in any case, hand back the lowercase canonical form.
pub fn normalize_address(address: &str) -> Result<String> {
    let trimmed = address.trim();
    let body = trimmed
        .strip_prefix("0x")
        .or_else(|| trimmed.strip_prefix("0X"));
    let body = match body {
        Some(b) => b,
        None => return Err(Error::new(Code::BadRequest, "address must start with 0x")),
    };
    if body.len() != 40 || !body.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(Error::new(
            Code::BadRequest,
            "address must be 0x followed by 40 hex characters",
        ));
    }
    Ok(format!("0x{}", body.to_ascii_lowercase()))
}

/// The EIP-191 personal-sign preimage: the prefix, the byte length in decimal
/// ASCII, then the message bytes. Length in *bytes*, and no separator.
pub fn eip191_hash(message: &str) -> [u8; 32] {
    let mut buf = Vec::with_capacity(message.len() + 32);
    buf.extend_from_slice(b"\x19Ethereum Signed Message:\n");
    buf.extend_from_slice(message.len().to_string().as_bytes());
    buf.extend_from_slice(message.as_bytes());
    keccak256(&buf)
}

/// Recover the signer of `message` from a 65-byte `r||s||v` hex signature.
///
/// `v` is accepted both as `@noble/curves`' raw recovery id (0/1) and as the
/// Ethereum convention (27/28). The frontend derives with `@noble/curves`
/// (SPEC §3.1) but a user pasting a signature from anywhere else should not
/// be told their key is wrong.
pub fn recover_address(message: &str, signature_hex: &str) -> Result<String> {
    let cleaned = signature_hex.trim();
    let cleaned = cleaned.strip_prefix("0x").unwrap_or(cleaned);
    let bytes = hex::decode(cleaned)
        .map_err(|_| Error::new(Code::AuthBadSignature, "signature is not hex"))?;
    if bytes.len() != 65 {
        return Err(Error::new(
            Code::AuthBadSignature,
            format!("signature must be 65 bytes, got {}", bytes.len()),
        ));
    }
    let v = bytes[64];
    let recid = match v {
        0 | 1 => v,
        27 | 28 => v - 27,
        // EIP-155 chain-encoded v has no business in a personal_sign, but it
        // is cheap to accept rather than reject a working signer.
        _ if v >= 35 => ((v as u32 - 35) % 2) as u8,
        _ => {
            return Err(Error::new(
                Code::AuthBadSignature,
                format!("unknown signature recovery byte {v}"),
            ))
        }
    };
    let sig = Signature::from_slice(&bytes[..64])
        .map_err(|_| Error::new(Code::AuthBadSignature, "signature r/s is not on the curve"))?;
    let recid = RecoveryId::from_byte(recid)
        .ok_or_else(|| Error::new(Code::AuthBadSignature, "bad recovery id"))?;
    let digest = eip191_hash(message);
    let key = VerifyingKey::recover_from_prehash(&digest, &sig, recid)
        .map_err(|_| Error::new(Code::AuthBadSignature, "could not recover a key"))?;
    Ok(address_from_pubkey(&key))
}
