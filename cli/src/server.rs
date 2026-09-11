//! Which server, and how its address is spelled.
//!
//! SPEC §1.1: *"The token is stored per server. A session token is minted by
//! one server and means nothing to another; a client that keeps one token and
//! points it at a new address will send a stranger's credential and be told
//! `unauthorized` for reasons the player cannot see. Key it by the server
//! URL."*
//!
//! That makes the spelling load-bearing. A person at a shell types
//! `--server localhost:5390`, `http://localhost:5390`, `ws://localhost:5390/ws`
//! and `localhost:5390/` on four different days and means one server every
//! time. All four canonicalise to the same key here, so the token is found
//! rather than silently re-minted.

use crate::error::{self, Result};

pub const DEFAULT: &str = "ws://127.0.0.1:5390/ws";
pub const ENV: &str = "CWBH_SERVER";

/// Resolve the server, in precedence order:
///
/// 1. `--server <URL>`
/// 2. `CWBH_SERVER`
/// 3. the last server stored in the client's own log (`server.set`)
/// 4. `ws://127.0.0.1:5390/ws`
///
/// The flag beats the environment because a flag is typed on purpose, and the
/// environment beats the store because a shell that exports `CWBH_SERVER` is
/// saying "this window talks to that one" and should not be overruled by what
/// some other window logged.
pub fn resolve(flag: Option<&str>, stored: Option<&str>) -> Result<String> {
    if let Some(url) = flag {
        return canonical(url);
    }
    if let Ok(v) = std::env::var(ENV) {
        if !v.trim().is_empty() {
            return canonical(v.trim());
        }
    }
    if let Some(url) = stored {
        return canonical(url);
    }
    canonical(DEFAULT)
}

/// Rewrite whatever was typed into the one spelling used as the store key and
/// handed to the websocket.
///
/// * a bare `host:port` becomes `ws://host:port/ws`
/// * `http(s)://` becomes `ws(s)://` — the same origin serves both (§1)
/// * an empty or `/` path becomes `/ws`, because that is where the socket is
/// * a trailing slash is dropped, the scheme and host lowercased
pub fn canonical(input: &str) -> Result<String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(error::usage("--server needs an address"));
    }

    // The scheme is case-insensitive (RFC 3986 §3.1) and a shell history is
    // full of `HTTP://` from somewhere it was pasted.
    let (scheme, rest) = match trimmed
        .split_once("://")
        .map(|(scheme, rest)| (scheme.to_ascii_lowercase(), rest))
    {
        Some((s, rest)) if s == "ws" => ("ws", rest),
        Some((s, rest)) if s == "wss" => ("wss", rest),
        Some((s, rest)) if s == "http" => ("ws", rest),
        Some((s, rest)) if s == "https" => ("wss", rest),
        Some((other, _)) => {
            return Err(error::usage(format!(
                "unsupported scheme '{other}://'; use ws://, wss://, http:// or https://"
            )))
        }
        // No scheme at all: `localhost:5390`. Plain ws, because the only
        // server this talks to today is on a loopback or a tailnet.
        None => ("ws", trimmed),
    };

    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, ""),
    };
    if authority.is_empty() {
        return Err(error::usage(format!("no host in '{input}'")));
    }

    let path = path.trim_end_matches('/');
    let path = if path.is_empty() { "/ws" } else { path };

    Ok(format!("{scheme}://{}{path}", authority.to_lowercase()))
}

/// What to print beside a prompt: `127.0.0.1:5390` rather than the full URL.
pub fn short(url: &str) -> String {
    url.split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or(url)
        .trim_end_matches("/ws")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn four_spellings_of_one_server_are_one_key() {
        let want = "ws://localhost:5390/ws";
        for typed in [
            "localhost:5390",
            "localhost:5390/",
            "http://localhost:5390",
            "ws://localhost:5390/ws",
            "HTTP://LocalHost:5390/",
            "  localhost:5390  ",
        ] {
            assert_eq!(canonical(typed).unwrap(), want, "{typed}");
        }
    }

    #[test]
    fn tls_survives_the_rewrite() {
        assert_eq!(
            canonical("https://hacker.example/ws").unwrap(),
            "wss://hacker.example/ws"
        );
        assert_eq!(
            canonical("wss://hacker.example").unwrap(),
            "wss://hacker.example/ws"
        );
    }

    #[test]
    fn a_non_default_path_is_kept() {
        assert_eq!(
            canonical("http://box:8080/hacker/ws").unwrap(),
            "ws://box:8080/hacker/ws"
        );
    }

    #[test]
    fn nonsense_is_refused_rather_than_guessed() {
        assert!(canonical("").is_err());
        assert!(canonical("ftp://box").is_err());
        assert!(canonical("http:///ws").is_err());
    }

    #[test]
    fn precedence_is_flag_then_env_then_store_then_default() {
        // The environment is process-wide, so this test owns it for its run.
        std::env::remove_var(ENV);
        assert_eq!(resolve(None, None).unwrap(), DEFAULT);
        assert_eq!(resolve(None, Some("box:1234")).unwrap(), "ws://box:1234/ws");
        assert_eq!(
            resolve(Some("flag:1"), Some("box:1234")).unwrap(),
            "ws://flag:1/ws"
        );
        std::env::set_var(ENV, "env:2");
        assert_eq!(resolve(None, Some("box:1234")).unwrap(), "ws://env:2/ws");
        assert_eq!(
            resolve(Some("flag:1"), Some("box:1234")).unwrap(),
            "ws://flag:1/ws"
        );
        std::env::remove_var(ENV);
    }

    #[test]
    fn short_is_what_a_prompt_shows() {
        assert_eq!(short("ws://127.0.0.1:5390/ws"), "127.0.0.1:5390");
    }
}
