//! Key material: derivation from a mnemonic or a raw key, the address, and the
//! one signature this client ever makes.
//!
//! **Nothing in here is ever sent.** PROTOCOL §4.3: *"The mnemonic and the
//! private key never appear in this protocol. There is no field for them and
//! there will never be one."* The only value that leaves this module and
//! reaches the socket is the 65-byte signature.

use k256::ecdsa::{RecoveryId, Signature as EcdsaSignature, SigningKey, VerifyingKey};
use k256::SecretKey;
use sha3::{Digest, Keccak256};
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::bip32::{ethereum_path, ExtendedPrivateKey};
use crate::bip39;
use crate::error::{self, Result};

/// A private key and everything derivable from it. Wiped on drop, clones
/// included.
#[derive(Clone, ZeroizeOnDrop)]
pub struct Keypair {
    private_key: [u8; 32],
}

/// Redacted on purpose: a `{:?}` of a keypair must never leak the scalar, and
/// a `dbg!` left in by accident is exactly how that happens.
impl std::fmt::Debug for Keypair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Keypair")
            .field("address", &self.address())
            .field("private_key", &"<redacted>")
            .finish()
    }
}

impl Keypair {
    pub fn from_bytes(bytes: [u8; 32]) -> Result<Self> {
        SecretKey::from_slice(&bytes).map_err(|_| {
            error::invalid_private_key("private key is not a valid secp256k1 scalar")
        })?;
        Ok(Keypair { private_key: bytes })
    }

    /// Accept a private key with or without the `0x` prefix.
    pub fn from_hex(input: &str) -> Result<Self> {
        let trimmed = input.trim();
        let body = trimmed
            .strip_prefix("0x")
            .or_else(|| trimmed.strip_prefix("0X"))
            .unwrap_or(trimmed);
        if body.len() != 64 {
            return Err(error::invalid_private_key(format!(
                "private key must be 64 hex characters, got {}",
                body.len()
            )));
        }
        let mut bytes = hex::decode(body)
            .map_err(|_| error::invalid_private_key("private key is not valid hexadecimal"))?;
        let mut arr = [0u8; 32];
        arr.copy_from_slice(&bytes);
        bytes.zeroize();
        Keypair::from_bytes(arr)
    }

    /// Derive the account at BIP-44 index `index`. SPEC §3.1.
    pub fn from_mnemonic(phrase: &str, index: u32, passphrase: &str) -> Result<Self> {
        // Surface the specific reason (bad word, bad checksum, bad length)
        // rather than a flat "invalid".
        bip39::mnemonic_to_entropy(phrase)?;
        let seed = bip39::to_seed(phrase, passphrase);
        let master = ExtendedPrivateKey::from_seed(&seed[..])?;
        let child = master.derive_path(&ethereum_path(index))?;
        Keypair::from_bytes(child.key)
    }

    /// Accept either form on one entry point: 12..24 words, or `0x` + 64 hex.
    pub fn from_secret(secret: &str, index: u32) -> Result<Self> {
        let trimmed = secret.trim();
        if trimmed.split_whitespace().count() > 1 {
            Keypair::from_mnemonic(trimmed, index, "")
        } else {
            Keypair::from_hex(trimmed)
        }
    }

    fn signing_key(&self) -> SigningKey {
        SigningKey::from_bytes(&self.private_key.into()).expect("validated at construction")
    }

    /// EIP-55 checksummed, which is what PROTOCOL §2.4 puts on the wire.
    pub fn address(&self) -> String {
        let point = self.signing_key().verifying_key().to_encoded_point(false);
        let hash = keccak256(&point.as_bytes()[1..]);
        to_eip55(&hash[12..])
    }

    /// Sign a 32-byte digest, returning 65 bytes of `r ‖ s ‖ v` with `v` in
    /// {27, 28}.
    ///
    /// PROTOCOL §4.3 spends a whole callout on this byte order because
    /// `@noble/curves` hands back `[recid, r, s]` and concatenating it
    /// produces a well-formed signature for a completely different address.
    /// `k256` gives r‖s and the recovery id separately, so the only way to get
    /// it wrong here is to forget the `+ 27`.
    pub fn sign_hash(&self, hash: &[u8; 32]) -> Result<[u8; 65]> {
        let (sig, recovery_id): (EcdsaSignature, RecoveryId) = self
            .signing_key()
            .sign_prehash_recoverable(hash)
            .map_err(|e| error::internal(format!("signing failed: {e}")))?;
        let mut out = [0u8; 65];
        out[..64].copy_from_slice(&sig.to_bytes());
        out[64] = 27 + recovery_id.to_byte();
        Ok(out)
    }

    /// Sign a personal message per EIP-191 — the one thing this client signs.
    pub fn sign_message(&self, message: &[u8]) -> Result<[u8; 65]> {
        self.sign_hash(&eip191_hash(message))
    }

    /// `0x` + 130 hex, the shape `auth.login` wants.
    pub fn sign_message_hex(&self, message: &[u8]) -> Result<String> {
        Ok(format!("0x{}", hex::encode(self.sign_message(message)?)))
    }
}

pub fn keccak256(bytes: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    out.copy_from_slice(&Keccak256::digest(bytes));
    out
}

/// `keccak256("\x19Ethereum Signed Message:\n" || len || message)`.
///
/// `len` is the **byte** length in ASCII decimal — not the character count.
/// The login message is ASCII today, but a display name never reaches it, so
/// this is correct rather than merely lucky.
pub fn eip191_hash(message: &[u8]) -> [u8; 32] {
    let mut buf = Vec::with_capacity(message.len() + 32);
    buf.extend_from_slice(b"\x19Ethereum Signed Message:\n");
    buf.extend_from_slice(message.len().to_string().as_bytes());
    buf.extend_from_slice(message);
    keccak256(&buf)
}

/// Render 20 bytes as an EIP-55 checksummed address.
pub fn to_eip55(address: &[u8]) -> String {
    let lower = hex::encode(address);
    let hash = keccak256(lower.as_bytes());
    let mut out = String::with_capacity(42);
    out.push_str("0x");
    for (i, ch) in lower.chars().enumerate() {
        let nibble = if i % 2 == 0 {
            hash[i / 2] >> 4
        } else {
            hash[i / 2] & 0x0f
        };
        if ch.is_ascii_digit() || nibble < 8 {
            out.push(ch);
        } else {
            out.push(ch.to_ascii_uppercase());
        }
    }
    out
}

/// Recover the signer of an EIP-191 personal message. Only the tests need it —
/// the server is the one that recovers in production — but a client that can
/// check its own signature before sending it turns `auth_bad_signature` from a
/// day of guessing into a local assertion.
pub fn recover_message(message: &[u8], signature: &[u8]) -> Result<String> {
    if signature.len() != 65 {
        return Err(error::usage(format!(
            "signature must be 65 bytes, got {}",
            signature.len()
        )));
    }
    let recovery = match signature[64] {
        v @ (0 | 1) => v,
        v @ (27 | 28) => v - 27,
        v => return Err(error::usage(format!("unsupported signature v value {v}"))),
    };
    let recovery_id =
        RecoveryId::from_byte(recovery).ok_or_else(|| error::usage("unsupported recovery id"))?;
    let sig = EcdsaSignature::from_slice(&signature[..64])
        .map_err(|e| error::usage(format!("malformed signature: {e}")))?;
    let key: VerifyingKey =
        VerifyingKey::recover_from_prehash(&eip191_hash(message), &sig, recovery_id)
            .map_err(|e| error::usage(format!("could not recover a public key: {e}")))?;
    let point = key.to_encoded_point(false);
    let hash = keccak256(&point.as_bytes()[1..]);
    Ok(to_eip55(&hash[12..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CANONICAL: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn the_conformance_address() {
        // SPEC §9.1 / tests/vectors/addresses.json. Three implementations
        // already agree on this line.
        let key = Keypair::from_mnemonic(CANONICAL, 0, "").unwrap();
        assert_eq!(key.address(), "0x9858EfFD232B4033E47d90003D41EC34EcaEda94");
    }

    #[test]
    fn eip55_matches_the_reference_vectors() {
        // From EIP-55 itself.
        for want in [
            "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
            "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
            "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
            "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
        ] {
            let raw = hex::decode(&want[2..]).unwrap();
            assert_eq!(to_eip55(&raw), want);
        }
    }

    #[test]
    fn a_private_key_and_its_mnemonic_agree() {
        let from_phrase = Keypair::from_mnemonic(CANONICAL, 0, "").unwrap();
        let from_hex =
            Keypair::from_hex("0x1ab42cc412b618bdea3a599e3c9bae199ebf030895b039e9db1e30dafb12b727")
                .unwrap();
        assert_eq!(from_phrase.address(), from_hex.address());
        // And `from_secret` routes both without being told which it got.
        assert_eq!(
            Keypair::from_secret(CANONICAL, 0).unwrap().address(),
            from_phrase.address()
        );
    }

    #[test]
    fn debug_never_prints_the_key() {
        let key = Keypair::from_mnemonic(CANONICAL, 0, "").unwrap();
        let rendered = format!("{key:?}");
        assert!(rendered.contains("<redacted>"));
        assert!(!rendered.contains("1ab42cc4"));
    }

    #[test]
    fn a_signature_recovers_to_its_own_address() {
        let key = Keypair::from_mnemonic(CANONICAL, 0, "").unwrap();
        let message = b"Causewaybay Hacker login\naddress: x\nnonce: y\nexpires: z";
        let sig = key.sign_message(message).unwrap();
        assert_eq!(sig[64], 27 + (sig[64] - 27));
        assert!(sig[64] == 27 || sig[64] == 28);
        assert_eq!(recover_message(message, &sig).unwrap(), key.address());
    }
}
