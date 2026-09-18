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

//! ## The one operation here that is not cryptography
//!
//! `secure` creates a directory `0700` and sets a file `0600`. It is in a key
//! library because LÖVE has no `chmod` and its `love.filesystem` is sandboxed
//! to a save directory this client does not use (SPEC §1.1) — and the file it
//! is protecting holds a session token. The alternative is spawning `chmod`
//! through `os.execute` on every write, which is a process per line and a
//! shell quoting problem in a program that must never have one.
//!
//! It touches no key material, reads nothing back, and returns only whether
//! the mode was set.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use serde::{Deserialize, Serialize};
use serde_json::json;
use zeroize::Zeroizing;

pub mod disk;
pub mod http;

pub mod bip32;
pub mod bip39;
pub mod evm;

/// The ABI this library speaks.
///
/// 1 was: `{op, ...}` in, `{ok, ...}` or `{ok:false, error}` out, five
/// operations. **2 adds `generate`**, which is the only op that returns key
/// material, so a binding written against 1 must not be handed a library that
/// has it — and a login screen written against 2 must not silently lose its
/// NEW WALLET button to an older library. **3 adds `secure`**, which is not
/// about keys at all — see below. A mismatch is refused rather than guessed
/// at.
/// 4 added the poster's four ops — `qr`, `recover`, `png_text`, `disk_read`
/// — none of which touch a key. A binding at 3 would offer POSTER and fail
/// on the label.
/// 5 adds the Rust coder's door to the network: `http_start`, `http_poll`,
/// `http_cancel`, `http_close` (`http.rs`). LÖVE ships LuaSocket and no TLS,
/// so without these the client cannot reach a model provider at all — a
/// binding at 4 would draw the agent panel and fail on the first ask.
pub const ABI_VERSION: i32 = 6;

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
    /// `secure` only: an absolute path.
    #[serde(default)]
    path: Option<String>,
    /// `secure` only: create it as a directory first.
    #[serde(default)]
    directory: Option<bool>,
    /// `recover` only: `0x` + 130 hex, `r || s || v`.
    #[serde(default)]
    signature: Option<String>,
    /// `png_text` only: the keyword→text pairs to write.
    #[serde(default)]
    entries: Option<std::collections::BTreeMap<String, String>>,
    /// `jpeg` only: where to write it, and how well.
    #[serde(default)]
    out: Option<String>,
    #[serde(default)]
    quality: Option<u32>,
    /// `disk_read` only: decode the label even when the chunks answer. The
    /// pre-save proof wants both halves of the same file.
    #[serde(default)]
    label: Option<bool>,
    /// `inflate` only: a raw-deflate stream, base64.
    #[serde(default)]
    base64: Option<String>,
    /// `http_start` only: where to, how, with what.
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    method: Option<String>,
    #[serde(default)]
    headers: Option<std::collections::HashMap<String, String>>,
    #[serde(default)]
    body: Option<String>,
    /// `http_poll`, `http_cancel`, `http_close`: which call.
    #[serde(default)]
    handle: Option<u64>,
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
            { "op": "keccak",
              "in": ["message|message_hex"],
              "out": ["digest","message_len"],
              "note": "raw keccak256, no §3.2 envelope; no key material involved" },
            { "op": "sign",
              "in": ["mnemonic|private_key", "index?", "passphrase?", "message|message_hex"],
              "out": ["address","signature","digest","v","recovery_id"] },
            { "op": "secure", "in": ["path", "directory?"], "out": ["mode"],
              "note": "0700 a directory or 0600 a file; no key material involved" },
            { "op": "qr", "in": ["message"], "out": ["size","rows"],
              "note": "the poster's label: byte mode, EC level M; no key material involved" },
            { "op": "recover", "in": ["message|message_hex", "signature"],
              "out": ["address","address_lower"],
              "note": "who signed: EIP-191 over the message; no key material involved" },
            { "op": "png_text", "in": ["path", "entries"], "out": ["written"],
              "note": "adds iTXt chunks to a PNG in place; no key material involved" },
            { "op": "jpeg", "in": ["path", "out", "quality?"], "out": ["out"],
              "note": "re-encodes a PNG as a JPEG; no key material involved" },
            { "op": "disk_read", "in": ["path", "label?"], "out": ["chunks","label"],
              "note": "a poster's text chunks and/or its QR label; no key material involved" },
            { "op": "inflate", "in": ["base64"], "out": ["text"],
              "note": "a label's `deflate:` body back to the source: raw deflate, UTF-8; no key material involved" },
            { "op": "http_start", "in": ["url", "method?", "headers?", "body?"], "out": ["handle"],
              "note": "the coder's door to a model provider: TLS LÖVE has not got; no key material involved" },
            { "op": "http_poll", "in": ["handle"],
              "out": ["status","chunks","bytes","done","cancelled","error"],
              "note": "whatever has arrived since the last poll, base64; never blocks" },
            { "op": "http_cancel", "in": ["handle"], "out": ["cancelled"],
              "note": "stop at the next read; the handle stays pollable" },
            { "op": "http_close", "in": ["handle"], "out": ["closed"],
              "note": "cancel and forget; the only way a handle is released" }
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

        // SPEC §1.1: the client's store is `0700`, its files `0600`, and that
        // is not decorative — one of those files holds a session token.
        //
        // The mode is applied to something that already exists rather than at
        // creation, because the Lua side opens the file with `io.open`; so
        // there is a window between create and chmod. It is narrowed by
        // calling `secure` immediately after the first `io.open`, and it is
        // the same window `umask 077` would close for good. A caller that
        // wants no window at all should create the file here instead.
        // The Rust coder's network. Generic on purpose: this library knows
        // about URLs and bytes, and `love2d/src/agent/providers.lua` knows
        // about providers — the same split the web client has between
        // `ai/providers.ts` and `fetch`.
        "http_start" => {
            let handle = http::start(&http::HttpRequest {
                url: req.url.clone(),
                method: req.method.clone(),
                headers: req.headers.clone(),
                body: req.body.clone(),
            })?;
            Ok(json!({ "ok": true, "handle": handle }))
        }

        "http_poll" => {
            let handle = req.handle.ok_or_else(|| "no `handle` given".to_string())?;
            http::poll(handle)
        }

        "http_cancel" => {
            let handle = req.handle.ok_or_else(|| "no `handle` given".to_string())?;
            http::cancel(handle)
        }

        "http_close" => {
            let handle = req.handle.ok_or_else(|| "no `handle` given".to_string())?;
            http::close(handle)
        }

        "secure" => {
            let path = req
                .path
                .as_deref()
                .ok_or_else(|| "no `path` given".to_string())?;
            if path.is_empty() {
                return Err("`path` is empty".to_string());
            }
            let as_directory = req.directory.unwrap_or(false);
            let mode: u32 = if as_directory { 0o700 } else { 0o600 };

            if as_directory {
                std::fs::create_dir_all(path).map_err(|e| format!("cannot create {path}: {e}"))?;
            }

            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
                    .map_err(|e| format!("cannot set the mode on {path}: {e}"))?;
                Ok(json!({ "ok": true, "mode": format!("{mode:o}"), "path": path }))
            }
            #[cfg(not(unix))]
            {
                // Windows has no mode bits worth pretending about. Saying so
                // is better than reporting a `0600` that does not exist.
                Ok(json!({ "ok": true, "mode": serde_json::Value::Null, "path": path }))
            }
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

        // Raw keccak256 over the bytes given, with nothing prepended.
        //
        // `eip191` is the other hash this library does and is deliberately not
        // this one: it prefixes the §3.2 envelope, which is right for a
        // signature and wrong for anything else. The caller with a use for
        // this is the login screen, which derives a display name from the
        // address (`src/username.lua`) and would otherwise need a keccak
        // implementation in Lua.
        //
        // It touches no key material, which is why it is allowed to take
        // arbitrary input at all: hashing a *secret* here would be a way to
        // ask this library a question about a key, and it does not answer
        // those.
        "keccak" => {
            let msg = message_bytes(&req)?;
            Ok(json!({
                "ok": true,
                "digest": format!("0x{}", hex::encode(evm::keccak256(&msg))),
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

        // The poster's label. Text in, a grid of `0`/`1` rows out; the Lua
        // side draws the squares. Nothing about a key.
        "qr" => {
            let text = req
                .message
                .as_deref()
                .ok_or_else(|| "no `message` given".to_string())?;
            let rows = disk::qr_rows(text)?;
            Ok(json!({ "ok": true, "size": rows.len(), "rows": rows }))
        }

        // Who signed. The reader's whole verdict rests on this, and it is
        // the inverse of `sign` above: same digest, same `v` convention.
        "recover" => {
            let msg = message_bytes(&req)?;
            let sig = req
                .signature
                .as_deref()
                .ok_or_else(|| "no `signature` given".to_string())?;
            let addr = disk::recover(&msg, sig)?;
            let eip55 = evm::to_eip55(&addr);
            Ok(json!({ "ok": true, "address": eip55, "address_lower": eip55.to_lowercase() }))
        }

        // The proof, into the file. The Lua side has written the PNG at
        // `path` with `love.image`; this reads it, adds the chunks, writes it
        // back — because `love.filesystem` cannot reach the path and a 4 MB
        // PNG through a JSON string would be the wrong door.
        "png_text" => {
            let path = req
                .path
                .as_deref()
                .ok_or_else(|| "no `path` given".to_string())?;
            let entries = req.entries.clone().unwrap_or_default();
            let bytes = std::fs::read(path).map_err(|e| format!("cannot read {path}: {e}"))?;
            let out = disk::with_png_text(&bytes, &entries)?;
            std::fs::write(path, &out).map_err(|e| format!("cannot write {path}: {e}"))?;
            Ok(json!({ "ok": true, "written": entries.len() }))
        }

        // The same picture as a JPEG, for the places that want one. LÖVE 11
        // encodes PNG and TGA and nothing else, so the JPEG the browser client
        // writes beside its PNG is made here from the PNG on disk.
        "jpeg" => {
            let path = req
                .path
                .as_deref()
                .ok_or_else(|| "no `path` given".to_string())?;
            let out = req
                .out
                .as_deref()
                .ok_or_else(|| "no `out` given".to_string())?;
            let img = image::open(path).map_err(|e| format!("cannot decode {path}: {e}"))?;
            let file =
                std::fs::File::create(out).map_err(|e| format!("cannot write {out}: {e}"))?;
            let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(
                std::io::BufWriter::new(file),
                req.quality.unwrap_or(92).clamp(1, 100) as u8,
            );
            enc.encode_image(&img.to_rgb8())
                .map_err(|e| format!("cannot encode {out}: {e}"))?;
            Ok(json!({ "ok": true, "out": out }))
        }

        // A picture back into what it says. Chunks when it is our PNG, the
        // label decoded from the pixels otherwise; the Lua side judges it.
        "disk_read" => {
            let path = req
                .path
                .as_deref()
                .ok_or_else(|| "no `path` given".to_string())?;
            let d = disk::read_disk(path, req.label.unwrap_or(false))?;
            Ok(json!({ "ok": true, "chunks": d.chunks, "label": d.label }))
        }

        // A `deflate:` label back into the program it carries. Raw deflate
        // (no zlib header), the way the web poster's `CompressionStream`
        // wrote it, and UTF-8 or nothing: a stream that is not one of ours
        // is an error, not a source.
        "inflate" => {
            let b64 = req
                .base64
                .as_deref()
                .ok_or_else(|| "no `base64` given".to_string())?;
            let text = disk::inflate_label(b64)?;
            Ok(json!({ "ok": true, "text": text }))
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
        Err(_) => {
            return into_c_string(r#"{"ok":false,"error":"request is not UTF-8"}"#.to_string())
        }
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
    fn recover_is_the_inverse_of_sign() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let signed = call(json!({ "op": "sign", "mnemonic": phrase, "message": "fn main() {}\n" }));
        let back = call(json!({
            "op": "recover", "message": "fn main() {}\n", "signature": signed["signature"]
        }));
        assert_eq!(back["ok"], true);
        assert_eq!(back["address"], signed["address"]);
        let other = call(json!({
            "op": "recover", "message": "fn main() {}", "signature": signed["signature"]
        }));
        assert_ne!(other["address"], signed["address"]);
    }

    #[test]
    fn qr_and_png_text_over_the_abi() {
        let qr = call(json!({ "op": "qr", "message": "CWBH1\nx\n-\nrust\nfn main() {}" }));
        assert_eq!(qr["ok"], true);
        assert_eq!(
            qr["rows"].as_array().unwrap().len(),
            qr["size"].as_u64().unwrap() as usize
        );
        let dir = std::env::temp_dir().join(format!("cwbh-ffi-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.png");
        let img = image::GrayImage::from_pixel(1, 1, image::Luma([0u8]));
        img.save(&path).unwrap();
        let w = call(json!({
            "op": "png_text", "path": path.to_str().unwrap(),
            "entries": { "Source": "fn main() {}\n", "Signer": "0xabc" }
        }));
        assert_eq!(w["ok"], true);
        let jpg = dir.join("t.jpg");
        let j = call(
            json!({ "op": "jpeg", "path": path.to_str().unwrap(), "out": jpg.to_str().unwrap() }),
        );
        assert_eq!(j["ok"], true);
        assert!(image::open(&jpg).is_ok());
        let r = call(json!({ "op": "disk_read", "path": path.to_str().unwrap() }));
        assert_eq!(r["chunks"]["Source"], "fn main() {}\n");
        assert!(
            r["label"].is_null(),
            "chunks answered, so no label was looked for"
        );
        let _ = std::fs::remove_dir_all(&dir);
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
        assert_eq!(
            call(json!({ "op": "validate", "mnemonic": phrase }))["valid"],
            true
        );
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
