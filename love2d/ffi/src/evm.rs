//! Ethereum address rendering and EIP-191 personal-message signing.
//!
//! `sha3::Keccak256` is *legacy* Keccak, which is what Ethereum uses — not
//! `sha3::Sha3_256`, which is the FIPS variant and would produce a different
//! address for every key. That distinction is the whole trap in this file.

use k256::ecdsa::{SigningKey, VerifyingKey};
use sha3::{Digest, Keccak256};
use zeroize::Zeroizing;

pub fn keccak256(bytes: &[u8]) -> [u8; 32] {
    let mut h = Keccak256::new();
    h.update(bytes);
    let out = h.finalize();
    let mut d = [0u8; 32];
    d.copy_from_slice(&out);
    d
}

/// The 20-byte address: keccak of the uncompressed public key without its
/// `0x04` SEC1 tag, last 20 bytes.
pub fn address_bytes(key: &VerifyingKey) -> [u8; 20] {
    let point = key.to_encoded_point(false);
    let hash = keccak256(&point.as_bytes()[1..]);
    let mut a = [0u8; 20];
    a.copy_from_slice(&hash[12..]);
    a
}

/// EIP-55: uppercase the hex nibble where the corresponding nibble of
/// keccak(lowercase-hex-without-0x) is >= 8. SPEC §2.4 puts this form on the
/// wire in both directions.
pub fn to_eip55(address: &[u8; 20]) -> String {
    let lower = hex::encode(address);
    let hash = keccak256(lower.as_bytes());
    let mut out = String::with_capacity(42);
    out.push_str("0x");
    for (i, c) in lower.chars().enumerate() {
        let nibble = if i % 2 == 0 {
            hash[i / 2] >> 4
        } else {
            hash[i / 2] & 0x0f
        };
        if c.is_ascii_digit() || nibble < 8 {
            out.push(c);
        } else {
            out.push(c.to_ascii_uppercase());
        }
    }
    out
}

/// `keccak256("\x19Ethereum Signed Message:\n" || len(message) || message)`.
///
/// `len` is the **byte** length in ASCII decimal. PROTOCOL §4.3's message is
/// 178 bytes of UTF-8 in the shared vectors; counting characters instead of
/// bytes would pass every ASCII test and fail the first non-ASCII name.
pub fn eip191_digest(message: &[u8]) -> [u8; 32] {
    let mut buf = Vec::with_capacity(message.len() + 32);
    buf.extend_from_slice(b"\x19Ethereum Signed Message:\n");
    buf.extend_from_slice(message.len().to_string().as_bytes());
    buf.extend_from_slice(message);
    keccak256(&buf)
}

pub struct Signed {
    /// 65 bytes, `r || s || v` with `v` in {27, 28} — the wire form.
    pub signature: [u8; 65],
    pub digest: [u8; 32],
    /// k256's own recovery id, 0 or 1. `v == recovery_id + 27`.
    pub recovery_id: u8,
}

/// Sign a 32-byte digest, producing the Ethereum `r||s||v` form.
pub fn sign_digest(private_key: &[u8; 32], digest: &[u8; 32]) -> Result<Signed, String> {
    let signing = SigningKey::from_bytes(private_key.into())
        .map_err(|_| "private key is not a valid secp256k1 scalar".to_string())?;
    let (sig, rec) = signing
        .sign_prehash_recoverable(digest)
        .map_err(|e| format!("signing failed: {e}"))?;
    let mut out = [0u8; 65];
    out[..64].copy_from_slice(&sig.to_bytes());
    // k256 hands back 0/1; the wire wants 27/28. Feeding 27/28 into a verifier
    // that expects 0/1 — or the reverse — fails on every single login.
    out[64] = 27 + rec.to_byte();
    Ok(Signed {
        signature: out,
        digest: *digest,
        recovery_id: rec.to_byte(),
    })
}

pub fn verifying_key(private_key: &[u8; 32]) -> Result<VerifyingKey, String> {
    let signing = SigningKey::from_bytes(private_key.into())
        .map_err(|_| "private key is not a valid secp256k1 scalar".to_string())?;
    Ok(*signing.verifying_key())
}

pub fn public_key_compressed(key: &VerifyingKey) -> String {
    format!("0x{}", hex::encode(key.to_encoded_point(true).as_bytes()))
}

/// Parse `0x`-prefixed (or bare) hex into exactly 32 bytes, held in a buffer
/// that wipes itself.
pub fn parse_private_key(text: &str) -> Result<Zeroizing<[u8; 32]>, String> {
    let trimmed = text.trim();
    let body = trimmed.strip_prefix("0x").unwrap_or(trimmed);
    if body.len() != 64 {
        return Err(format!(
            "a private key is 64 hex characters, got {}",
            body.len()
        ));
    }
    let raw = Zeroizing::new(hex::decode(body).map_err(|_| "private key is not hex".to_string())?);
    let mut key = Zeroizing::new([0u8; 32]);
    key.copy_from_slice(&raw[..]);
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eip55_matches_the_reference_cases() {
        // From EIP-55 itself.
        for want in [
            "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
            "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
            "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
            "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
        ] {
            let mut a = [0u8; 20];
            a.copy_from_slice(&hex::decode(&want[2..]).unwrap());
            assert_eq!(to_eip55(&a), want);
        }
    }

    #[test]
    fn eip191_prefix_uses_byte_length() {
        // keccak256("\x19Ethereum Signed Message:\n12Hello World")
        let d = eip191_digest(b"Hello World");
        assert_eq!(
            hex::encode(d),
            "a1de988600a42c4b4ab089b619297c17d53cffae5d5120d82d8a92d0bb3b78f2"
        );
    }
}
