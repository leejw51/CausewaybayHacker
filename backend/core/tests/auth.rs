//! SPEC §3: recovery, the nonce rules and sessions.

use cwbhacker_core::auth::{self, Challenges};
use cwbhacker_core::error::Code;
use cwbhacker_core::eth;

fn vectors() -> serde_json::Value {
    let text = include_str!("fixtures/eip191.json");
    serde_json::from_str(text).expect("fixture is JSON")
}

/// SPEC §9.2. The signatures come from `eth-account`, not from this codebase:
/// signing with the same code that verifies proves only that two bugs cancel.
#[test]
fn recovers_the_signer_of_an_independent_signature() {
    let vectors = vectors();
    for vector in vectors["vectors"].as_array().unwrap() {
        let message = vector["message"].as_str().unwrap();
        let signature = vector["signature"].as_str().unwrap();
        let signer = vector["signer"].as_str().unwrap();
        let recovered = eth::recover_address(message, signature).expect("recovers");
        assert_eq!(
            recovered,
            signer.to_ascii_lowercase(),
            "message {message:?} recovered the wrong address"
        );
        // And the display form round-trips back to exactly what eth-account
        // printed, which is the §3.4 rendering.
        assert_eq!(eth::to_eip55(&recovered), signer);
    }
}

#[test]
fn the_eip191_prefix_matches_the_reference_hash() {
    let vectors = vectors();
    for vector in vectors["vectors"].as_array().unwrap() {
        let message = vector["message"].as_str().unwrap();
        let expected = vector["prefixed_hash"].as_str().unwrap();
        assert_eq!(
            format!("0x{}", hex::encode(eth::eip191_hash(message))),
            expected,
            "prefixed hash drifted for {message:?}"
        );
    }
}

#[test]
fn eip55_matches_the_reference_addresses() {
    let text = include_str!("fixtures/eip55.json");
    let vectors: serde_json::Value = serde_json::from_str(text).unwrap();
    for vector in vectors["vectors"].as_array().unwrap() {
        let lower = vector["lowercase"].as_str().unwrap();
        let checksummed = vector["checksummed"].as_str().unwrap();
        assert_eq!(eth::to_eip55(lower), checksummed);
        // And the canonical form of the checksummed spelling is the lowercase
        // one — two spellings of one wallet must never become two players.
        assert_eq!(eth::normalize_address(checksummed).unwrap(), lower);
    }
}

#[test]
fn a_signature_from_another_address_is_refused() {
    let vectors = vectors();
    let vector = &vectors["vectors"][1];
    let message = vector["message"].as_str().unwrap();
    let signature = vector["signature"].as_str().unwrap();
    let someone_else = "0x0000000000000000000000000000000000000001";
    let err = auth::verify_login(someone_else, message, signature).unwrap_err();
    assert_eq!(err.code, Code::AuthBadSignature);
}

#[test]
fn a_nonce_is_single_use() {
    let challenges = Challenges::new();
    let address = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F";
    let challenge = challenges.issue(address).unwrap();
    assert!(challenge.message.contains(&challenge.nonce));
    assert!(challenge.message.starts_with("Causewaybay Hacker login\n"));

    let first = challenges.redeem(address, &challenge.nonce).unwrap();
    assert_eq!(first, challenge.message);

    let replay = challenges.redeem(address, &challenge.nonce).unwrap_err();
    assert_eq!(replay.code, Code::AuthNonceUsed);
}

#[test]
fn an_expired_nonce_is_expired_not_used() {
    let challenges = Challenges::new();
    let address = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F";
    let challenge = challenges.issue_with_ttl(address, -1).unwrap();
    let err = challenges.redeem(address, &challenge.nonce).unwrap_err();
    assert_eq!(err.code, Code::AuthExpired);
}

#[test]
fn a_nonce_issued_for_one_address_does_not_work_for_another() {
    let challenges = Challenges::new();
    let mine = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F";
    let theirs = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";
    let challenge = challenges.issue(mine).unwrap();
    let err = challenges.redeem(theirs, &challenge.nonce).unwrap_err();
    assert_eq!(err.code, Code::AuthBadSignature);
}

#[test]
fn an_unknown_nonce_reads_as_expired() {
    let challenges = Challenges::new();
    let err = challenges
        .redeem(
            "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F",
            &"ab".repeat(32),
        )
        .unwrap_err();
    assert_eq!(err.code, Code::AuthExpired);
}

#[test]
fn sessions_resume_and_expire() {
    let conn = cwbhacker_core::db::open_memory().unwrap();
    let address = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";
    cwbhacker_core::users::upsert(&conn, address).unwrap();

    let token = auth::mint_session(&conn, address).unwrap();
    assert_eq!(auth::resume_session(&conn, &token).unwrap(), address);

    // Only the hash is stored: the token itself is not in the database.
    let stored: String = conn
        .query_row("SELECT token_hash FROM sessions", [], |r| r.get(0))
        .unwrap();
    assert_ne!(stored, token);
    assert_eq!(stored, auth::token_hash(&token));

    let bogus = auth::resume_session(&conn, "not-a-token").unwrap_err();
    assert_eq!(bogus.code, Code::Unauthorized);

    conn.execute(
        "UPDATE sessions SET expires_at = '2000-01-01T00:00:00Z'",
        [],
    )
    .unwrap();
    let expired = auth::resume_session(&conn, &token).unwrap_err();
    assert_eq!(expired.code, Code::AuthExpired);
    let left: i64 = conn
        .query_row("SELECT count(*) FROM sessions", [], |r| r.get(0))
        .unwrap();
    assert_eq!(left, 0, "an expired session should not be left lying about");
}
