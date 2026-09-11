//! BIP-39: mnemonic validation and seed derivation (English wordlist).
//!
//! The same implementation as `CausewaybayWallet`'s `core/src/bip39.rs`, for
//! the reason SPEC §3.1 gives: the same mnemonic must produce the same address
//! in both programs, and a drift here reads to the player as losing their
//! account.

use hmac::Hmac;
use sha2::{Digest, Sha256, Sha512};
use unicode_normalization::UnicodeNormalization;
use zeroize::Zeroizing;

use crate::error::{self, Result};

/// The official BIP-39 English wordlist, 2048 entries.
pub fn wordlist() -> &'static [&'static str] {
    use std::sync::OnceLock;
    static WORDS: OnceLock<Vec<&'static str>> = OnceLock::new();
    WORDS.get_or_init(|| include_str!("wordlist_en.txt").lines().collect())
}

/// Word counts we accept, paired with their entropy size in bits.
pub const WORD_COUNTS: [(usize, usize); 5] =
    [(12, 128), (15, 160), (18, 192), (21, 224), (24, 256)];

fn entropy_bits_for_words(words: usize) -> Result<usize> {
    WORD_COUNTS
        .iter()
        .find(|(w, _)| *w == words)
        .map(|(_, bits)| *bits)
        .ok_or_else(|| {
            error::invalid_mnemonic(format!(
                "unsupported word count {words}; use 12, 15, 18, 21 or 24"
            ))
        })
}

/// Recover the entropy behind a mnemonic, verifying its checksum.
pub fn mnemonic_to_entropy(phrase: &str) -> Result<Zeroizing<Vec<u8>>> {
    let normalized = Zeroizing::new(normalize(phrase));
    let tokens: Vec<&str> = normalized.split(' ').filter(|t| !t.is_empty()).collect();
    entropy_bits_for_words(tokens.len())?;

    let words = wordlist();
    let mut bits: Zeroizing<Vec<bool>> = Zeroizing::new(Vec::with_capacity(tokens.len() * 11));
    for (position, token) in tokens.iter().enumerate() {
        // The word itself stays out of the message. It is a twelfth of
        // somebody's wallet, and an error string goes to stderr and into
        // scrollback. The position is what the user needs to find it anyway.
        let idx = words.binary_search(token).map_err(|_| {
            error::invalid_mnemonic(format!(
                "word {} of {} is not in the BIP-39 word list",
                position + 1,
                tokens.len()
            ))
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
            return Err(error::invalid_mnemonic("mnemonic checksum does not match"));
        }
    }
    Ok(entropy)
}

/// True when the phrase is a well-formed mnemonic with a valid checksum.
pub fn validate(phrase: &str) -> bool {
    mnemonic_to_entropy(phrase).is_ok()
}

/// Derive the 64-byte BIP-39 seed (PBKDF2-HMAC-SHA512, 2048 rounds).
pub fn to_seed(phrase: &str, passphrase: &str) -> Zeroizing<[u8; 64]> {
    let normalized = Zeroizing::new(normalize(phrase));
    // The salt carries the passphrase, so it is key material too.
    let salt = Zeroizing::new(format!("mnemonic{}", passphrase.nfkd().collect::<String>()));
    let mut seed = Zeroizing::new([0u8; 64]);
    pbkdf2::pbkdf2::<Hmac<Sha512>>(normalized.as_bytes(), salt.as_bytes(), 2048, &mut seed[..])
        .expect("PBKDF2 output length is valid");
    seed
}

/// NFKD, lowercase, single-spaced — what BIP-39 hashes, not what was typed.
fn normalize(phrase: &str) -> String {
    phrase
        .nfkd()
        .collect::<String>()
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    const CANONICAL: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn the_wordlist_is_the_bip39_english_one() {
        let words = wordlist();
        assert_eq!(words.len(), 2048);
        assert_eq!(words[0], "abandon");
        assert_eq!(words[2047], "zoo");
        // Sorted, because `mnemonic_to_entropy` binary-searches it.
        assert!(words.windows(2).all(|w| w[0] < w[1]));
    }

    #[test]
    fn the_canonical_phrase_is_all_zero_entropy() {
        let entropy = mnemonic_to_entropy(CANONICAL).unwrap();
        assert_eq!(&entropy[..], &[0u8; 16]);
    }

    #[test]
    fn a_flipped_word_fails_the_checksum() {
        let broken = CANONICAL.replace("about", "abandon");
        assert!(!validate(&broken));
        // And the word itself never appears in the message.
        let err = mnemonic_to_entropy(&broken).unwrap_err();
        assert!(!err.message.contains("abandon"), "{}", err.message);
    }

    #[test]
    fn typing_is_normalized_before_it_is_hashed() {
        let messy = format!("  {}  ", CANONICAL.to_uppercase().replace(' ', "   "));
        assert_eq!(
            &to_seed(&messy, "")[..],
            &to_seed(CANONICAL, "")[..],
            "case and spacing must not change the seed"
        );
    }

    #[test]
    fn bip39_seed_vector() {
        // BIP-39 English test vector 1, passphrase "TREZOR".
        assert_eq!(
            hex::encode(&to_seed(CANONICAL, "TREZOR")[..]),
            "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
        );
    }
}
