//! BIP-39: mnemonic → entropy → seed. English wordlist only.
//!
//! The arithmetic is the same as `CausewaybayWallet`'s
//! `rustcli/core/src/bip39.rs`, deliberately: the same mnemonic has to give
//! the same address in the wallet, the browser and this client, and a client
//! that re-derives "its own way" reads to a user as losing their account.

use hmac::Hmac;
use sha2::{Digest, Sha256, Sha512};
use unicode_normalization::UnicodeNormalization;
use zeroize::Zeroizing;

/// The official BIP-39 English wordlist, 2048 entries, sorted.
pub fn wordlist() -> &'static [&'static str] {
    use std::sync::OnceLock;
    static WORDS: OnceLock<Vec<&'static str>> = OnceLock::new();
    WORDS.get_or_init(|| include_str!("wordlist_en.txt").lines().collect())
}

fn entropy_bits_for_words(words: usize) -> Result<usize, String> {
    match words {
        12 => Ok(128),
        15 => Ok(160),
        18 => Ok(192),
        21 => Ok(224),
        24 => Ok(256),
        n => Err(format!(
            "unsupported word count {n}; use 12, 15, 18, 21 or 24"
        )),
    }
}

/// NFKD-normalise, collapse whitespace, lowercase — what BIP-39 hashes.
pub fn normalize(phrase: &str) -> String {
    phrase
        .nfkd()
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// Recover the entropy behind a mnemonic, verifying its checksum.
///
/// The offending *word* never enters an error message. It is a twelfth of
/// somebody's wallet and an error string ends up in scrollback and in
/// whatever the host logs; the position is what a person needs anyway.
pub fn mnemonic_to_entropy(phrase: &str) -> Result<Zeroizing<Vec<u8>>, String> {
    let normalized = Zeroizing::new(normalize(phrase));
    let tokens: Vec<&str> = normalized.split(' ').filter(|t| !t.is_empty()).collect();
    entropy_bits_for_words(tokens.len())?;

    let words = wordlist();
    let mut bits: Zeroizing<Vec<bool>> = Zeroizing::new(Vec::with_capacity(tokens.len() * 11));
    for (position, token) in tokens.iter().enumerate() {
        let idx = words.binary_search(token).map_err(|_| {
            format!(
                "word {} of {} is not in the BIP-39 word list",
                position + 1,
                tokens.len()
            )
        })?;
        for i in (0..11).rev() {
            bits.push((idx >> i) & 1 == 1);
        }
    }

    let entropy_bits = bits.len() * 32 / 33;
    let checksum_bits = bits.len() - entropy_bits;
    let mut entropy = Zeroizing::new(vec![0u8; entropy_bits / 8]);
    for (i, bit) in bits[..entropy_bits].iter().enumerate() {
        if *bit {
            entropy[i / 8] |= 1 << (7 - (i % 8));
        }
    }

    let expected = Sha256::digest(&entropy[..]);
    for i in 0..checksum_bits {
        let want = (expected[i / 8] >> (7 - (i % 8))) & 1 == 1;
        if bits[entropy_bits + i] != want {
            return Err("mnemonic checksum does not match".to_string());
        }
    }
    Ok(entropy)
}

pub fn validate(phrase: &str) -> bool {
    mnemonic_to_entropy(phrase).is_ok()
}

/// The 64-byte BIP-39 seed: PBKDF2-HMAC-SHA512, 2048 rounds, salt
/// `"mnemonic" || passphrase`.
pub fn to_seed(phrase: &str, passphrase: &str) -> Zeroizing<[u8; 64]> {
    let normalized = Zeroizing::new(normalize(phrase));
    // The salt carries the passphrase, so it is key material too.
    let salt = Zeroizing::new(format!("mnemonic{}", passphrase.nfkd().collect::<String>()));
    let mut seed = Zeroizing::new([0u8; 64]);
    pbkdf2::pbkdf2::<Hmac<Sha512>>(normalized.as_bytes(), salt.as_bytes(), 2048, &mut seed[..])
        .expect("PBKDF2 output length is valid");
    seed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wordlist_is_sorted_and_complete() {
        let w = wordlist();
        assert_eq!(w.len(), 2048);
        assert_eq!(w[0], "abandon");
        assert_eq!(w[2047], "zoo");
        assert!(w.windows(2).all(|p| p[0] < p[1]));
    }

    /// The first Trezor BIP-39 vector, passphrase "TREZOR".
    #[test]
    fn trezor_seed_vector() {
        let seed = to_seed(
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            "TREZOR",
        );
        assert_eq!(
            hex::encode(&seed[..]),
            "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
        );
    }

    #[test]
    fn rejects_a_broken_checksum() {
        assert!(!validate(
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
        ));
    }
}
