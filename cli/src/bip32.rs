//! BIP-32 hierarchical deterministic derivation over secp256k1.
//!
//! Only private child derivation is needed for `m/44'/60'/0'/0/i`, which keeps
//! this to CKDpriv plus path parsing.

use hmac::{Hmac, Mac};
use k256::elliptic_curve::sec1::ToEncodedPoint;
use k256::SecretKey;
use sha2::Sha512;
use zeroize::Zeroize;

use crate::error::{self, Result};

const HARDENED: u32 = 0x8000_0000;

#[derive(Clone)]
pub struct ExtendedPrivateKey {
    pub key: [u8; 32],
    pub chain_code: [u8; 32],
}

/// An extended key is a private key with a chain code stapled to it; both
/// halves are wiped rather than left in freed memory.
impl Drop for ExtendedPrivateKey {
    fn drop(&mut self) {
        self.key.zeroize();
        self.chain_code.zeroize();
    }
}

impl ExtendedPrivateKey {
    /// The BIP-32 master key for a seed (BIP-39 seeds are 64 bytes).
    pub fn from_seed(seed: &[u8]) -> Result<Self> {
        if seed.len() < 16 || seed.len() > 64 {
            return Err(error::internal("seed must be 16..64 bytes"));
        }
        let mut mac = <Hmac<Sha512> as Mac>::new_from_slice(b"Bitcoin seed")
            .map_err(|e| error::internal(format!("HMAC init failed: {e}")))?;
        mac.update(seed);
        let out = mac.finalize().into_bytes();
        let mut key = [0u8; 32];
        let mut chain_code = [0u8; 32];
        key.copy_from_slice(&out[..32]);
        chain_code.copy_from_slice(&out[32..]);
        SecretKey::from_slice(&key)
            .map_err(|_| error::internal("seed produced an invalid master key"))?;
        Ok(ExtendedPrivateKey { key, chain_code })
    }

    /// Derive one child. Indices >= 2^31 are hardened.
    pub fn derive_child(&self, index: u32) -> Result<Self> {
        let parent = SecretKey::from_slice(&self.key)
            .map_err(|_| error::internal("invalid parent private key"))?;

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
            .map_err(|e| error::internal(format!("HMAC init failed: {e}")))?;
        mac.update(&data);
        data.zeroize();
        let out = mac.finalize().into_bytes();

        // IL must be a valid scalar; per BIP-32 an invalid one means "skip this index".
        let tweak = SecretKey::from_slice(&out[..32]).map_err(|_| {
            error::internal(format!(
                "derivation at index {index} landed on an invalid key"
            ))
        })?;
        let child_scalar =
            *parent.to_nonzero_scalar().as_ref() + *tweak.to_nonzero_scalar().as_ref();
        let child = SecretKey::from_bytes(&child_scalar.to_bytes()).map_err(|_| {
            error::internal(format!(
                "derivation at index {index} landed on an invalid key"
            ))
        })?;

        let mut key = [0u8; 32];
        let mut chain_code = [0u8; 32];
        key.copy_from_slice(&child.to_bytes());
        chain_code.copy_from_slice(&out[32..]);
        Ok(ExtendedPrivateKey { key, chain_code })
    }

    /// Walk a full path such as `m/44'/60'/0'/0/0`.
    pub fn derive_path(&self, path: &str) -> Result<Self> {
        let mut current = self.clone();
        for index in parse_path(path)? {
            current = current.derive_child(index)?;
        }
        Ok(current)
    }
}

/// Parse a derivation path into raw child indices, applying the hardened offset.
pub fn parse_path(path: &str) -> Result<Vec<u32>> {
    let trimmed = path.trim();
    let mut parts = trimmed.split('/');
    let head = parts
        .next()
        .ok_or_else(|| error::usage(format!("invalid derivation path: {path}")))?;
    if head != "m" && head != "M" {
        return Err(error::usage(format!(
            "derivation path must start with 'm': {path}"
        )));
    }
    let mut indices = Vec::new();
    for part in parts {
        if part.is_empty() {
            return Err(error::usage(format!(
                "empty component in derivation path: {path}"
            )));
        }
        let (digits, hardened) = match part.strip_suffix(['\'', 'h', 'H']) {
            Some(rest) => (rest, true),
            None => (part, false),
        };
        let value: u32 = digits
            .parse()
            .map_err(|_| error::usage(format!("invalid path component '{part}' in {path}")))?;
        if value >= HARDENED {
            return Err(error::usage(format!(
                "path component '{part}' is out of range"
            )));
        }
        indices.push(if hardened { value + HARDENED } else { value });
    }
    Ok(indices)
}

/// The BIP-44 Ethereum account path. SPEC §3.1 pins index 0 as the identity.
pub fn ethereum_path(index: u32) -> String {
    format!("m/44'/60'/0'/0/{index}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_paths() {
        assert_eq!(parse_path("m").unwrap(), Vec::<u32>::new());
        assert_eq!(parse_path("m/0'").unwrap(), vec![HARDENED]);
        assert_eq!(
            parse_path("m/44'/60'/0'/0/5").unwrap(),
            vec![44 + HARDENED, 60 + HARDENED, HARDENED, 0, 5]
        );
    }

    #[test]
    fn rejects_bad_paths() {
        assert!(parse_path("44'/60'").is_err());
        assert!(parse_path("m//0").is_err());
        assert!(parse_path("m/abc").is_err());
        assert!(parse_path("m/2147483648").is_err());
    }

    #[test]
    fn ethereum_path_is_bip44() {
        assert_eq!(ethereum_path(0), "m/44'/60'/0'/0/0");
    }

    // BIP-32 test vector 1: seed 000102030405060708090a0b0c0d0e0f.
    #[test]
    fn bip32_vector_one() {
        let seed = hex::decode("000102030405060708090a0b0c0d0e0f").unwrap();
        let master = ExtendedPrivateKey::from_seed(&seed[..]).unwrap();
        assert_eq!(
            hex::encode(master.key),
            "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35"
        );
        assert_eq!(
            hex::encode(master.chain_code),
            "873dff81c02f525623fd1fe5167eac3a55a049de3d314bb42ee227ffed37d508"
        );
        assert_eq!(
            hex::encode(master.derive_path("m/0'/1/2'/2/1000000000").unwrap().key),
            "471b76e389e528d6de6d816857e012c5455051cad6660850e58372a6c3e6e7c8"
        );
    }
}
