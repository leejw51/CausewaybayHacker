//! BIP-32 private child derivation over secp256k1.
//!
//! Only CKDpriv and path parsing are needed for `m/44'/60'/0'/0/i`, so only
//! those are here. Mirrors `CausewaybayWallet`'s `rustcli/core/src/bip32.rs`.

use hmac::{Hmac, Mac};
use k256::elliptic_curve::sec1::ToEncodedPoint;
use k256::SecretKey;
use sha2::Sha512;
use zeroize::{Zeroize, ZeroizeOnDrop};

const HARDENED: u32 = 0x8000_0000;

#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct ExtendedPrivateKey {
    pub key: [u8; 32],
    pub chain_code: [u8; 32],
}

impl ExtendedPrivateKey {
    pub fn from_seed(seed: &[u8]) -> Result<Self, String> {
        if seed.len() < 16 || seed.len() > 64 {
            return Err("seed must be 16..64 bytes".into());
        }
        let mut mac = <Hmac<Sha512> as Mac>::new_from_slice(b"Bitcoin seed")
            .map_err(|e| format!("HMAC init failed: {e}"))?;
        mac.update(seed);
        let out = mac.finalize().into_bytes();
        let mut key = [0u8; 32];
        let mut chain_code = [0u8; 32];
        key.copy_from_slice(&out[..32]);
        chain_code.copy_from_slice(&out[32..]);
        SecretKey::from_slice(&key)
            .map_err(|_| "seed produced an invalid master key".to_string())?;
        Ok(ExtendedPrivateKey { key, chain_code })
    }

    pub fn derive_child(&self, index: u32) -> Result<Self, String> {
        let parent = SecretKey::from_slice(&self.key)
            .map_err(|_| "invalid parent private key".to_string())?;

        let mut data = Vec::with_capacity(37);
        if index >= HARDENED {
            data.push(0x00);
            data.extend_from_slice(&self.key);
        } else {
            let point = parent.public_key().to_encoded_point(true);
            data.extend_from_slice(point.as_bytes());
        }
        data.extend_from_slice(&index.to_be_bytes());

        let mut mac = <Hmac<Sha512> as Mac>::new_from_slice(&self.chain_code)
            .map_err(|e| format!("HMAC init failed: {e}"))?;
        mac.update(&data);
        data.zeroize();
        let out = mac.finalize().into_bytes();

        // An IL that is not a valid scalar means "skip this index" per BIP-32;
        // at 1-in-2^127 it is reported rather than silently walked past.
        let tweak = SecretKey::from_slice(&out[..32])
            .map_err(|_| format!("derivation at index {index} landed on an invalid key"))?;
        let child_scalar =
            *parent.to_nonzero_scalar().as_ref() + *tweak.to_nonzero_scalar().as_ref();
        let child = SecretKey::from_bytes(&child_scalar.to_bytes())
            .map_err(|_| format!("derivation at index {index} landed on an invalid key"))?;

        let mut key = [0u8; 32];
        let mut chain_code = [0u8; 32];
        key.copy_from_slice(&child.to_bytes());
        chain_code.copy_from_slice(&out[32..]);
        Ok(ExtendedPrivateKey { key, chain_code })
    }

    pub fn derive_path(&self, path: &str) -> Result<Self, String> {
        let mut current = self.clone();
        for index in parse_path(path)? {
            current = current.derive_child(index)?;
        }
        Ok(current)
    }
}

pub fn parse_path(path: &str) -> Result<Vec<u32>, String> {
    let trimmed = path.trim();
    let mut parts = trimmed.split('/');
    let head = parts.next().unwrap_or("");
    if head != "m" && head != "M" {
        return Err(format!("derivation path must start with 'm': {path}"));
    }
    let mut indices = Vec::new();
    for part in parts {
        if part.is_empty() {
            return Err(format!("empty component in derivation path: {path}"));
        }
        let (digits, hardened) = match part.strip_suffix(['\'', 'h', 'H']) {
            Some(rest) => (rest, true),
            None => (part, false),
        };
        let value: u32 = digits
            .parse()
            .map_err(|_| format!("invalid path component '{part}' in {path}"))?;
        if value >= HARDENED {
            return Err(format!("path component '{part}' is out of range"));
        }
        indices.push(if hardened { value + HARDENED } else { value });
    }
    Ok(indices)
}

/// SPEC §3.1: the BIP-44 Ethereum account path. The client never uses another.
pub fn ethereum_path(index: u32) -> String {
    format!("m/44'/60'/0'/0/{index}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_paths() {
        assert_eq!(parse_path("m").unwrap(), Vec::<u32>::new());
        assert_eq!(
            parse_path("m/44'/60'/0'/0/0").unwrap(),
            vec![44 + HARDENED, 60 + HARDENED, HARDENED, 0, 0]
        );
        assert!(parse_path("44'/60'").is_err());
    }

    #[test]
    fn ethereum_path_is_the_spec_path() {
        assert_eq!(ethereum_path(0), "m/44'/60'/0'/0/0");
        assert_eq!(ethereum_path(7), "m/44'/60'/0'/0/7");
    }
}
