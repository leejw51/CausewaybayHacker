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

/// SPEC §9.2, against QA's fixture in `tests/vectors/signatures.json`.
///
/// The vectors were generated by `CausewaybayWallet`'s own `cwbwallet`, which
/// is the program whose addresses this one must agree with. A signature this
/// repository produced and this repository verified would prove only that two
/// bugs cancel.
fn qa_vectors() -> serde_json::Value {
    let text = include_str!("../../../tests/vectors/signatures.json");
    serde_json::from_str(text).expect("the shared fixture is JSON")
}

#[test]
fn the_shared_signature_vectors_recover_their_signers() {
    let vectors = qa_vectors();
    let list = vectors["vectors"].as_array().expect("vectors");
    assert!(!list.is_empty(), "the fixture is empty");
    for vector in list {
        let name = vector["name"].as_str().unwrap();
        let message = vector["message"].as_str().unwrap();
        let signature = vector["signature"].as_str().unwrap();
        let address = vector["address"].as_str().unwrap();

        assert_eq!(
            format!("0x{}", hex::encode(eth::eip191_hash(message))),
            vector["eip191_digest"].as_str().unwrap(),
            "{name}: the EIP-191 digest drifted"
        );
        let recovered =
            eth::recover_address(message, signature).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(
            recovered,
            vector["address_lower"].as_str().unwrap(),
            "{name}"
        );
        assert_eq!(eth::to_eip55(&recovered), address, "{name}");
        assert!(
            auth::verify_login(address, message, signature).is_ok(),
            "{name}: a good signature was refused"
        );

        // The fixture carries r, s and v apart as well as joined, so a verifier
        // that reassembles them in the wrong order is caught here rather than
        // by a user who cannot log in.
        let r = vector["r"].as_str().unwrap().trim_start_matches("0x");
        let s = vector["s"].as_str().unwrap().trim_start_matches("0x");
        let v = vector["v"].as_u64().unwrap() as u8;
        let rebuilt = format!("0x{r}{s}{v:02x}");
        assert_eq!(
            eth::recover_address(message, &rebuilt).unwrap(),
            recovered,
            "{name}: r||s||v does not reassemble"
        );
        // k256's recovery id is 0/1; the wire's v is 27/28. Both must work.
        let raw = vector["recovery_id"].as_u64().unwrap() as u8;
        assert_eq!(
            eth::recover_address(message, &format!("0x{r}{s}{raw:02x}")).unwrap(),
            recovered,
            "{name}: the 0/1 encoding of v was refused"
        );
    }
}

#[test]
fn the_shared_must_reject_cases_are_all_refused() {
    let vectors = qa_vectors();
    let cases = vectors["must_reject"].as_array().expect("must_reject");
    assert_eq!(
        cases.len(),
        4,
        "the fixture grew a case this test has not seen"
    );
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let message = case["message"].as_str().unwrap();
        let signature = case["signature"].as_str().unwrap();
        let claimed = case["claimed_address"].as_str().unwrap();
        let expected = case["expect"].as_str().unwrap();

        let err = auth::verify_login(claimed, message, signature)
            .expect_err(&format!("{name}: this must not verify"));
        assert_eq!(
            err.code.as_str(),
            expected,
            "{name}: wrong refusal code ({})",
            err.message
        );
    }
}

/// A signature that does not verify must leave the challenge alive. Being told
/// to start over when a retype would have done is the wrong instruction, and
/// telling the player "expired" when the truth is "spent" is worse.
#[test]
fn a_bad_signature_does_not_spend_the_challenge() {
    let challenges = Challenges::new();
    let vectors = qa_vectors();
    let vector = &vectors["vectors"][0];
    let address = vector["address"].as_str().unwrap();

    let challenge = challenges.issue(address).unwrap();
    // Whatever the client sent, the message it must sign is the stored one.
    let peeked = challenges.peek(address, &challenge.nonce).unwrap();
    assert_eq!(peeked, challenge.message);

    // A failed verification: the nonce is untouched.
    assert!(auth::verify_login(address, &peeked, &"00".repeat(65)).is_err());
    let again = challenges
        .peek(address, &challenge.nonce)
        .expect("the challenge should still be live after a bad signature");
    assert_eq!(again, challenge.message);

    // Success spends it, and only then.
    challenges.burn(&challenge.nonce);
    let err = challenges.peek(address, &challenge.nonce).unwrap_err();
    assert_eq!(err.code, Code::AuthNonceUsed);
}

// ---------------------------------------------------------------------------
// `Challenges::login` — the no-nonce path, which is the one `auth.login`
// actually takes (PROTOCOL §4.3 carries `{address, signature}` and no nonce)
// and the one that was wrong once already: a rejected signature spent the
// challenge, and the replay after it reported the wrong reason.
// ---------------------------------------------------------------------------

fn sign_with(key_hex: &str, message: &str) -> String {
    let key = k256::ecdsa::SigningKey::from_slice(&hex::decode(key_hex).unwrap()).unwrap();
    let digest = eth::eip191_hash(message);
    let (signature, recovery) = key.sign_prehash_recoverable(&digest).unwrap();
    let mut bytes = signature.to_bytes().to_vec();
    bytes.push(recovery.to_byte());
    format!("0x{}", hex::encode(bytes))
}

fn address_of(key_hex: &str) -> String {
    let key = k256::ecdsa::SigningKey::from_slice(&hex::decode(key_hex).unwrap()).unwrap();
    eth::address_from_pubkey(key.verifying_key())
}

const KEY: &str = "4646464646464646464646464646464646464646464646464646464646464646";
const OTHER_KEY: &str = "1111111111111111111111111111111111111111111111111111111111111111";

#[test]
fn a_login_without_a_nonce_spends_exactly_one_challenge() {
    let challenges = Challenges::new();
    let address = address_of(KEY);
    let challenge = challenges.issue(&address).unwrap();
    let signature = sign_with(KEY, &challenge.message);

    assert_eq!(
        challenges.login(&address, &signature, None).unwrap(),
        address
    );

    // Replaying the same signature is `auth_nonce_used` — "ask for a new
    // challenge" — and never `auth_expired`, which says "wait".
    let replay = challenges.login(&address, &signature, None).unwrap_err();
    assert_eq!(replay.code, Code::AuthNonceUsed, "{}", replay.message);
}

#[test]
fn a_rejected_login_leaves_every_challenge_live() {
    let challenges = Challenges::new();
    let address = address_of(KEY);
    let challenge = challenges.issue(&address).unwrap();
    let forged = sign_with(OTHER_KEY, &challenge.message);

    let err = challenges.login(&address, &forged, None).unwrap_err();
    assert_eq!(err.code, Code::AuthBadSignature);
    assert_eq!(
        challenges.peek(&address, &challenge.nonce).unwrap(),
        challenge.message,
        "a mistyped mnemonic must not cost a round trip"
    );

    // And the honest signature still works, on the same challenge.
    let honest = sign_with(KEY, &challenge.message);
    assert!(challenges.login(&address, &honest, None).is_ok());
}

#[test]
fn a_login_with_no_challenge_at_all_is_expired() {
    let challenges = Challenges::new();
    let address = address_of(KEY);
    let err = challenges
        .login(&address, &sign_with(KEY, "anything"), None)
        .unwrap_err();
    assert_eq!(err.code, Code::AuthExpired);
}

/// Several challenges may be outstanding at once (PROTOCOL §4.2), and the
/// client signs whichever one it got. The server tries them all rather than
/// assuming the newest, or a client that asked twice can never log in.
#[test]
fn the_older_of_two_live_challenges_still_works() {
    let challenges = Challenges::new();
    let address = address_of(KEY);
    let older = challenges.issue(&address).unwrap();
    let newer = challenges.issue(&address).unwrap();
    assert_ne!(older.nonce, newer.nonce);

    let signature = sign_with(KEY, &older.message);
    assert_eq!(
        challenges.login(&address, &signature, None).unwrap(),
        address
    );

    // Only the one that was signed is spent.
    assert_eq!(
        challenges.peek(&address, &newer.nonce).unwrap(),
        newer.message
    );
    assert_eq!(
        challenges.peek(&address, &older.nonce).unwrap_err().code,
        Code::AuthNonceUsed
    );
}
