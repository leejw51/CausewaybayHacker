//! `cwbh-ffi` — the C ABI the LÖVE client's `src/wallet.lua` loads.
//!
//! Shape, borrowed wholesale from `CausewaybayWallet/rustcli/ffi`:
//!
//! * one entry point, `cwbh_execute`, taking a JSON request and returning a
//!   JSON envelope as a freshly allocated `char *`;
//! * `cwbh_string_free` is the only legal way to release that pointer, so the
//!   Lua side cannot leak and cannot call `free()` from the wrong allocator;
//! * `cwbh_abi_version` is checked by the binding before any other call, and a
//!   mismatch is refused rather than guessed at.
//!
//! ## What crosses this boundary
//!
//! Mnemonics and private keys go **in**. Nothing derived from them ever comes
//! back **out** except an address, a public key, a digest and a signature.
//! There is no operation that returns a private key, and there must never be
//! one: the client's whole security story (SPEC §3.1, PROTOCOL §4.3) is that
//! the key exists in memory for as long as it takes to sign and nowhere else.
//! Secrets are held in `Zeroizing` buffers so the copy in freed memory is
//! wiped rather than left for a realloc, a swap file or a core dump.
//!
//! **`generate` is the single exception, and it is deliberate.** A first-time
//! player owns no BIP-39 phrase, and without a generator there is no way into
//! the game at all. So a freshly generated mnemonic comes back across the ABI
//! exactly **once**, to be written on paper — it is not stored here, it is not
//! written to disk, and it is never sent anywhere. The alternative is a player
//! improvising a phrase, or a client improvising a CSPRNG, and both are worse
//! than one audited exit. The private key derived from it still never crosses.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use serde::{Deserialize, Serialize};
use serde_json::json;
use zeroize::Zeroizing;

pub mod bip32;
pub mod bip39;
pub mod evm;

/// The ABI this library speaks.
///
/// 1 was: `{op, ...}` in, `{ok, ...}` or `{ok:false, error}` out, five
/// operations. **2 adds `generate`**, which is the only op that returns key
/// material, so a binding written against 1 must not be handed a library that
/// has it — and a login screen written against 2 must not silently lose its
/// NEW WALLET button to an older library. A mismatch is refused rather than
/// guessed at.
pub const ABI_VERSION: i32 = 2;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

// ------------------------------------------------------------------ requests

#[derive(Deserialize)]
struct Request {
    op: String,
    #[serde(default)]
    mnemonic: Option<String>,
    #[serde(default)]
    private_key: Option<String>,
    #[serde(default)]
    passphrase: Option<String>,
    #[serde(default)]
    index: Option<u32>,
    /// The message to sign, as UTF-8 text.
    #[serde(default)]
    message: Option<String>,
    /// The same message as hex, for callers that would rather not trust a
    /// JSON round-trip with the exact bytes. PROTOCOL §4.2 is emphatic that
    /// the server's string is signed byte-for-byte, so both doors exist.
    #[serde(default)]
    message_hex: Option<String>,
    /// `generate` only: how many words. 12, 15, 18, 21 or 24; default 12.
    #[serde(default)]
    words: Option<usize>,
}

#[derive(Serialize)]
struct Account {
    address: String,
    address_lower: String,
    public_key_compressed: String,
    path: Option<String>,
}

// ------------------------------------------------------------------- helpers

fn message_bytes(req: &Request) -> Result<Vec<u8>, String> {
    if let Some(h) = &req.message_hex {
        let body = h.strip_prefix("0x").unwrap_or(h);
        return hex::decode(body).map_err(|_| "message_hex is not hex".to_string());
    }
    match &req.message {
        Some(m) => Ok(m.as_bytes().to_vec()),
        None => Err("no `message` or `message_hex` given".to_string()),
    }
}

/// Resolve whatever the caller supplied down to a 32-byte secret.
///
/// Private after this function returns: the `Zeroizing` wrapper wipes it when
/// the caller drops it, and no path out of `execute` puts it in the response.
fn secret_of(req: &Request) -> Result<(Zeroizing<[u8; 32]>, Option<String>), String> {
    if let Some(pk) = &req.private_key {
        return Ok((evm::parse_private_key(pk)?, None));
    }
    let phrase = req
        .mnemonic
        .as_deref()
        .ok_or_else(|| "no `mnemonic` or `private_key` given".to_string())?;
    if !bip39::validate(phrase) {
        // Surface the specific reason (bad word position, bad checksum, bad
        // length) — never the word itself.
        bip39::mnemonic_to_entropy(phrase)?;
    }
    let index = req.index.unwrap_or(0);
    let path = bip32::ethereum_path(index);
    let seed = bip39::to_seed(phrase, req.passphrase.as_deref().unwrap_or(""));
    let master = bip32::ExtendedPrivateKey::from_seed(&seed[..])?;
    let child = master.derive_path(&path)?;
    let key = Zeroizing::new(child.key);
    Ok((key, Some(path)))
}

fn account_of(key: &[u8; 32], path: Option<String>) -> Result<Account, String> {
    let vk = evm::verifying_key(key)?;
    let bytes = evm::address_bytes(&vk);
    let eip55 = evm::to_eip55(&bytes);
    Ok(Account {
        address_lower: eip55.to_lowercase(),
        address: eip55,
        public_key_compressed: evm::public_key_compressed(&vk),
        path,
    })
}

// ----------------------------------------------------------------- operations

/// The whole surface, as data, so the Lua side can print it and a test can
/// assert it did not change under anybody's feet.
pub fn describe() -> serde_json::Value {
    json!({
        "library": "cwbh-ffi",
        "version": VERSION,
        "abi": ABI_VERSION,
        "path_template": "m/44'/60'/0'/0/{index}",
        "ops": [
            { "op": "describe", "in": [], "out": ["library","version","abi","ops"] },
            { "op": "validate", "in": ["mnemonic"], "out": ["valid"] },
            { "op": "generate", "in": ["words?"], "out": ["mnemonic","words","address"],
              "note": "the only op that returns key material; shown once, never stored" },
            { "op": "derive",
              "in": ["mnemonic|private_key", "index?", "passphrase?"],
              "out": ["address","address_lower","public_key_compressed","path"] },
            { "op": "eip191",
              "in": ["message|message_hex"],
              "out": ["digest","message_len"] },
            { "op": "sign",
              "in": ["mnemonic|private_key", "index?", "passphrase?", "message|message_hex"],
              "out": ["address","signature","digest","v","recovery_id"] }
        ],
        "never_returns": ["private_key", "seed"],
        "returns_key_material_once": ["generate.mnemonic"]
    })
}

pub fn execute(request_json: &str) -> String {
    let value = match run(request_json) {
        Ok(v) => v,
        Err(e) => json!({ "ok": false, "error": e }),
    };
    serde_json::to_string(&value).unwrap_or_else(|_| {
        r#"{"ok":false,"error":"the response could not be serialised"}"#.to_string()
    })
}

fn run(request_json: &str) -> Result<serde_json::Value, String> {
    let req: Request =
        serde_json::from_str(request_json).map_err(|e| format!("malformed request: {e}"))?;

    match req.op.as_str() {
        "describe" => {
            let mut v = describe();
            v["ok"] = json!(true);
            Ok(v)
        }

        "validate" => {
            let phrase = req
                .mnemonic
                .as_deref()
                .ok_or_else(|| "no `mnemonic` given".to_string())?;
            match bip39::mnemonic_to_entropy(phrase) {
                Ok(_) => Ok(json!({ "ok": true, "valid": true })),
                Err(e) => Ok(json!({ "ok": true, "valid": false, "reason": e })),
            }
        }

        // The one exception to `never_returns`, and the reason a first-time
        // player can start at all. The phrase is handed back once, with the
        // address it derives so the screen can show both without a second
        // call, and nothing here keeps a copy.
        "generate" => {
            let words = req.words.unwrap_or(12);
            let phrase = bip39::generate(words)?;
            let path = bip32::ethereum_path(0);
            let seed = bip39::to_seed(&phrase, "");
            let master = bip32::ExtendedPrivateKey::from_seed(&seed[..])?;
            let child = master.derive_path(&path)?;
            let key = Zeroizing::new(child.key);
            let acct = account_of(&key, Some(path))?;
            Ok(json!({
                "ok": true,
                "mnemonic": phrase.as_str(),
                "words": words,
                "address": acct.address,
                "address_lower": acct.address_lower,
                "path": acct.path,
            }))
        }

        "derive" => {
            let (key, path) = secret_of(&req)?;
            let acct = account_of(&key, path)?;
            Ok(json!({
                "ok": true,
                "address": acct.address,
                "address_lower": acct.address_lower,
                "public_key_compressed": acct.public_key_compressed,
                "path": acct.path,
            }))
        }

        // The digest on its own, so a failing signature can be bisected: a
        // wrong digest is a message/length bug, a right digest with a wrong
        // signature is a curve bug. Splitting them is the difference between
        // a minute and a day.
        "eip191" => {
            let msg = message_bytes(&req)?;
            Ok(json!({
                "ok": true,
                "digest": format!("0x{}", hex::encode(evm::eip191_digest(&msg))),
                "message_len": msg.len(),
            }))
        }

        "sign" => {
            let msg = message_bytes(&req)?;
            let (key, path) = secret_of(&req)?;
            let acct = account_of(&key, path)?;
            let digest = evm::eip191_digest(&msg);
            let signed = evm::sign_digest(&key, &digest)?;
            Ok(json!({
                "ok": true,
                "address": acct.address,
                "address_lower": acct.address_lower,
                "path": acct.path,
                "message_len": msg.len(),
                "digest": format!("0x{}", hex::encode(signed.digest)),
                "signature": format!("0x{}", hex::encode(signed.signature)),
                "r": format!("0x{}", hex::encode(&signed.signature[..32])),
                "s": format!("0x{}", hex::encode(&signed.signature[32..64])),
                "v": signed.signature[64],
                "recovery_id": signed.recovery_id,
            }))
        }

        other => Err(format!("unknown op `{other}`")),
    }
}

// --------------------------------------------------------------------- C ABI

fn into_c_string(text: String) -> *mut c_char {
    // An interior NUL cannot happen (serde_json never emits one unescaped),
    // but a panic across the FFI boundary is undefined behaviour, so it is
    // handled rather than unwrapped.
    match CString::new(text) {
        Ok(s) => s.into_raw(),
        Err(_) => CString::new(r#"{"ok":false,"error":"response contained a NUL"}"#)
            .expect("static string has no NUL")
            .into_raw(),
    }
}

/// The ABI number. Call this first; refuse the library if it is not yours.
#[no_mangle]
pub extern "C" fn cwbh_abi_version() -> i32 {
    ABI_VERSION
}

/// The crate version, as a JSON-free bare string. Free with `cwbh_string_free`.
#[no_mangle]
pub extern "C" fn cwbh_version() -> *mut c_char {
    into_c_string(VERSION.to_string())
}

/// The operation catalogue, as JSON. Free with `cwbh_string_free`.
#[no_mangle]
pub extern "C" fn cwbh_describe() -> *mut c_char {
    let mut v = describe();
    v["ok"] = json!(true);
    into_c_string(serde_json::to_string(&v).unwrap_or_default())
}

/// Run one request. JSON in, JSON out. Free the result with
/// `cwbh_string_free` and nothing else.
///
/// # Safety
/// `request_json` must be a NUL-terminated C string valid for the call.
#[no_mangle]
pub unsafe extern "C" fn cwbh_execute(request_json: *const c_char) -> *mut c_char {
    if request_json.is_null() {
        return into_c_string(r#"{"ok":false,"error":"null request"}"#.to_string());
    }
    let raw = CStr::from_ptr(request_json);
    let text = match raw.to_str() {
        Ok(t) => t.to_string(),
        Err(_) => return into_c_string(r#"{"ok":false,"error":"request is not UTF-8"}"#.to_string()),
    };
    // A panic unwinding into LuaJIT is undefined behaviour; it becomes an
    // error envelope instead.
    let out = std::panic::catch_unwind(move || execute(&text))
        .unwrap_or_else(|_| r#"{"ok":false,"error":"internal panic"}"#.to_string());
    into_c_string(out)
}

/// Release a string this library returned. Calling it on anything else, or
/// twice on the same pointer, is undefined behaviour.
///
/// # Safety
/// `s` must be a pointer previously returned by one of the functions above
/// and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn cwbh_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(req: serde_json::Value) -> serde_json::Value {
        serde_json::from_str(&execute(&req.to_string())).unwrap()
    }

    #[test]
    fn derives_the_spec_address() {
        let v = call(json!({
            "op": "derive",
            "mnemonic": "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            "index": 0
        }));
        assert_eq!(v["ok"], true);
        assert_eq!(v["address"], "0x9858EfFD232B4033E47d90003D41EC34EcaEda94");
        assert_eq!(v["path"], "m/44'/60'/0'/0/0");
    }

    #[test]
    fn a_generated_phrase_derives_a_real_address() {
        let v = call(json!({ "op": "generate" }));
        assert_eq!(v["ok"], true);
        assert_eq!(v["words"], 12);
        let phrase = v["mnemonic"].as_str().unwrap();
        assert_eq!(phrase.split(' ').count(), 12);
        assert_eq!(v["path"], "m/44'/60'/0'/0/0");

        // The address `generate` reports must be the one `derive` gets from
        // the same phrase — otherwise the screen shows one account and the
        // player logs into another.
        let derived = call(json!({ "op": "derive", "mnemonic": phrase, "index": 0 }));
        assert_eq!(derived["ok"], true);
        assert_eq!(derived["address"], v["address"]);
        assert_eq!(v["address"].as_str().unwrap().len(), 42);

        // And it can sign, which is the only thing a login actually needs.
        let signed = call(json!({ "op": "sign", "mnemonic": phrase, "message": "hello" }));
        assert_eq!(signed["ok"], true);
        assert_eq!(signed["address"], v["address"]);
        assert_eq!(signed["signature"].as_str().unwrap().len(), 132);

        // `validate` agrees with `generate`.
        assert_eq!(call(json!({ "op": "validate", "mnemonic": phrase }))["valid"], true);
    }

    #[test]
    fn generate_never_repeats() {
        let mut seen = std::collections::HashSet::new();
        for _ in 0..32 {
            let v = call(json!({ "op": "generate" }));
            assert!(
                seen.insert(v["mnemonic"].as_str().unwrap().to_string()),
                "two generations collided — the RNG is not what it claims"
            );
        }
    }

    #[test]
    fn generate_refuses_a_word_count_bip39_does_not_have() {
        let v = call(json!({ "op": "generate", "words": 13 }));
        assert_eq!(v["ok"], false);
        assert!(v["error"].as_str().unwrap().contains("13"));
        assert!(v.get("mnemonic").is_none());
    }

    #[test]
    fn never_hands_back_key_material() {
        let text = execute(
            &json!({
                "op": "sign",
                "private_key": "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
                "message": "hi"
            })
            .to_string(),
        );
        assert!(!text.contains("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"));
        assert!(!text.contains("private_key"));
        assert!(!text.contains("mnemonic"));
    }

    #[test]
    fn an_unknown_op_is_an_error_envelope_not_a_panic() {
        let v = call(json!({ "op": "exfiltrate" }));
        assert_eq!(v["ok"], false);
        assert!(v["error"].as_str().unwrap().contains("exfiltrate"));
    }
}
