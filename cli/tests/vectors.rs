//! The shared conformance vectors — SPEC §9.1 and §9.2.
//!
//! `tests/vectors/addresses.json` and `signatures.json` are the repository's
//! fixtures; the browser, the LÖVE client and the smoke harness are all
//! checked against them. This file makes the terminal client the fourth.
//!
//! It reads the fixtures from the repo rather than copying them. A copied
//! fixture is a fixture that drifts, and the whole point of these two files is
//! that four implementations cannot drift apart without something going red.

use serde_json::Value;
use std::path::PathBuf;

use causewaybay_hacker_cli::wallet::{eip191_hash, recover_message, to_eip55, Keypair};

fn vectors(name: &str) -> Value {
    let path: PathBuf = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../tests/vectors")
        .join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    serde_json::from_str(&text).expect("fixture is JSON")
}

/// SPEC §9.1: every mnemonic, every index, both spellings of the address.
#[test]
fn derivation_matches_the_shared_address_vectors() {
    let doc = vectors("addresses.json");
    let mut checked = 0usize;
    for entry in doc["mnemonics"].as_array().expect("mnemonics") {
        let phrase = entry["phrase"].as_str().unwrap();
        for account in entry["accounts"].as_array().unwrap() {
            let index = account["index"].as_u64().unwrap() as u32;
            let key = Keypair::from_mnemonic(phrase, index, "").unwrap();
            assert_eq!(
                key.address(),
                account["address"].as_str().unwrap(),
                "{} index {index}",
                entry["name"]
            );
            assert_eq!(
                key.address().to_lowercase(),
                account["address_lower"].as_str().unwrap()
            );
            // The private key itself is pinned too, so a derivation that lands
            // on the right address by luck still fails.
            let from_key = Keypair::from_hex(account["private_key"].as_str().unwrap()).unwrap();
            assert_eq!(from_key.address(), key.address());
            checked += 1;
        }
    }
    assert!(checked >= 10, "only {checked} accounts checked");
}

/// The one line the task singles out.
#[test]
fn the_canonical_phrase_gives_the_canonical_address() {
    let key = Keypair::from_mnemonic(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        0,
        "",
    )
    .unwrap();
    assert_eq!(key.address(), "0x9858EfFD232B4033E47d90003D41EC34EcaEda94");
}

/// SPEC §9.2 / PROTOCOL §4.2–§4.3: the message bytes, the EIP-191 digest, and
/// the `r ‖ s ‖ v` byte order with `v` in {27, 28}.
#[test]
fn signing_matches_the_shared_signature_vectors() {
    let doc = vectors("signatures.json");
    let mut checked = 0usize;
    for vector in doc["vectors"].as_array().expect("vectors") {
        let name = vector["name"].as_str().unwrap();
        let message = vector["message"].as_str().unwrap();
        let key = Keypair::from_hex(vector["private_key"].as_str().unwrap()).unwrap();

        assert_eq!(key.address(), vector["address"].as_str().unwrap(), "{name}");

        // The exact bytes that get hashed — §4.2's "sign it byte-for-byte".
        let message_hex = vector["message_hex"].as_str().unwrap();
        assert_eq!(
            format!("0x{}", hex::encode(message.as_bytes())),
            message_hex,
            "{name}: message bytes"
        );
        assert_eq!(
            message.len(),
            vector["message_len"].as_u64().unwrap() as usize,
            "{name}: byte length feeds the EIP-191 prefix"
        );
        assert!(!message.ends_with('\n'), "{name}: no trailing newline");

        assert_eq!(
            format!("0x{}", hex::encode(eip191_hash(message.as_bytes()))),
            vector["eip191_digest"].as_str().unwrap(),
            "{name}: EIP-191 digest"
        );

        // secp256k1 signing here is deterministic (RFC 6979), so the whole
        // signature is comparable rather than merely verifiable.
        let signature = key.sign_message(message.as_bytes()).unwrap();
        assert_eq!(
            format!("0x{}", hex::encode(signature)),
            vector["signature"].as_str().unwrap(),
            "{name}: r || s || v"
        );
        assert_eq!(
            format!("0x{}", hex::encode(&signature[..32])),
            vector["r"].as_str().unwrap(),
            "{name}: r is the FIRST 32 bytes"
        );
        assert_eq!(
            format!("0x{}", hex::encode(&signature[32..64])),
            vector["s"].as_str().unwrap()
        );
        assert_eq!(signature[64] as u64, vector["v"].as_u64().unwrap());
        assert_eq!(
            (signature[64] - 27) as u64,
            vector["recovery_id"].as_u64().unwrap()
        );

        assert_eq!(
            recover_message(message.as_bytes(), &signature).unwrap(),
            vector["address"].as_str().unwrap(),
            "{name}: recovers to the claimed address"
        );
        checked += 1;
    }
    assert!(checked >= 2, "only {checked} signature vectors checked");
}

/// The failure PROTOCOL §4.3 warns about, asserted rather than described: a
/// signature assembled as `v ‖ r ‖ s` recovers a different address, and the
/// server can only answer `auth_bad_signature`.
#[test]
fn the_recovery_id_first_mistake_is_a_different_address() {
    let doc = vectors("signatures.json");
    let vector = &doc["vectors"][0];
    let message = vector["message"].as_str().unwrap().as_bytes();
    let key = Keypair::from_hex(vector["private_key"].as_str().unwrap()).unwrap();
    let correct = key.sign_message(message).unwrap();

    let mut wrong = [0u8; 65];
    wrong[0] = correct[64] - 27; // the recovery id, first, as noble hands it over
    wrong[1..].copy_from_slice(&correct[..64]);
    wrong[64] = 27; // and something plausible in the last byte

    match recover_message(message, &wrong) {
        Ok(address) => assert_ne!(
            address,
            key.address(),
            "v||r||s must not recover the right address"
        ),
        Err(_) => { /* also fine: it is simply not a signature */ }
    }
}

/// PROTOCOL §2.4: addresses are EIP-55 on the wire, in both directions.
#[test]
fn eip55_rendering() {
    for want in [
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
        "0x9858EfFD232B4033E47d90003D41EC34EcaEda94",
        "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    ] {
        assert_eq!(to_eip55(&hex::decode(&want[2..]).unwrap()), want);
    }
}
