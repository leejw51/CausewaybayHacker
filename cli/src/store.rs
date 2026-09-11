//! The client's own store — `~/.causewaybayhackercli`, SPEC §1.1.
//!
//! `~/.causewaybayhacker` belongs to the *server*. This is a separate program
//! that may be talking to a server on another machine, so it keeps its own
//! state: a `0700` directory, `0600` files, one append-only JSONL log, and
//! state derived by replaying it.
//!
//! The rules, from §1.1, all of which this file implements:
//!
//! * one compact JSON object per line, UTF-8, `\n` terminated
//! * **append-only** — later records supersede earlier ones, nothing is edited
//! * a torn last line costs that line and not the next one: an append that
//!   finds the file unterminated starts a fresh one
//! * every record carries `schema`, `kind` and an RFC3339 UTC timestamp
//! * an unparsable line, or one from a newer schema, is skipped with a warning
//! * forgetting a session is a **record** (`session.clear`), not an edit
//!
//! And what it holds: the session token, the chosen server, and where each map
//! was left. **No key material, ever** — not the mnemonic, not the private
//! key, not the seed. There is no code path in this file that could write one:
//! the only secret-shaped thing it ever sees is a session token.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{self, Result};

pub const SCHEMA: u32 = 1;
pub const HOME_ENV: &str = "CWBH_HOME";
pub const DEFAULT_DIR: &str = ".causewaybayhackercli";
pub const LOG_FILE: &str = "state.jsonl";

/// What a client knows about one server. The token is keyed by server URL
/// because that is the only thing it is valid against.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Session {
    pub server: String,
    pub token: String,
    /// EIP-55, for display and for naming the work directory (lowercased).
    pub address: String,
    #[serde(default)]
    pub name: String,
}

/// The state a replay produces. Not written anywhere — derived every time.
#[derive(Debug, Default, Clone)]
pub struct State {
    /// server URL -> session
    pub sessions: BTreeMap<String, Session>,
    /// the last server explicitly chosen
    pub server: Option<String>,
    /// "<server>\0<land>.<category>" -> quest id
    pub map_pos: BTreeMap<String, String>,
    /// Lines that could not be replayed, for `cwbh doctor` to mention.
    pub skipped: Vec<String>,
}

impl State {
    pub fn session(&self, server: &str) -> Option<&Session> {
        self.sessions.get(server)
    }
    pub fn map_pos(&self, server: &str, land: &str, category: &str) -> Option<&str> {
        self.map_pos
            .get(&format!("{server}\0{land}.{category}"))
            .map(|s| s.as_str())
    }
}

/// One line of the log.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Record {
    schema: u32,
    kind: String,
    at: String,
    #[serde(flatten)]
    body: serde_json::Value,
}

pub struct Store {
    home: PathBuf,
}

impl Store {
    /// Resolve the home — `--home`, then `CWBH_HOME`, then
    /// `~/.causewaybayhackercli` — and create it `0700`.
    pub fn open(explicit: Option<&Path>) -> Result<Store> {
        let home = resolve_home(explicit)?;
        if !home.exists() {
            std::fs::create_dir_all(&home)?;
        }
        set_mode(&home, 0o700)?;
        Ok(Store { home })
    }

    pub fn home(&self) -> &Path {
        &self.home
    }

    pub fn log_path(&self) -> PathBuf {
        self.home.join(LOG_FILE)
    }

    /// Where the player's own files live. Lowercase address, because SPEC §3.4
    /// is explicit that two spellings of one wallet must never become two
    /// directories — and on a case-insensitive filesystem, which is what this
    /// is being written on, they would silently share one while looking like
    /// two.
    pub fn work_dir(&self, address: &str) -> PathBuf {
        self.home.join("work").join(address.to_lowercase())
    }

    /// Replay the whole log. Cheap: the log is a handful of lines per session.
    pub fn load(&self) -> Result<State> {
        let mut state = State::default();
        let path = self.log_path();
        let file = match std::fs::File::open(&path) {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(state),
            Err(e) => return Err(e.into()),
        };
        for (number, line) in BufReader::new(file).lines().enumerate() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            let record: Record = match serde_json::from_str(&line) {
                Ok(r) => r,
                Err(e) => {
                    // §1.1: skipped with a warning, never an aborted replay. A
                    // torn line is the normal cost of a crash and must not
                    // cost the player their session.
                    state.skipped.push(format!("line {}: {e}", number + 1));
                    continue;
                }
            };
            if record.schema > SCHEMA {
                state.skipped.push(format!(
                    "line {}: schema {} is newer than this client's {SCHEMA}",
                    number + 1,
                    record.schema
                ));
                continue;
            }
            state.apply(&record);
        }
        Ok(state)
    }

    /// Append one record. Every write goes through here.
    fn append(&self, kind: &str, body: serde_json::Value) -> Result<()> {
        let record = Record {
            schema: SCHEMA,
            kind: kind.to_string(),
            at: now(),
            body,
        };
        // Compact, one line, newline terminated.
        let mut line = serde_json::to_string(&record)?;
        line.push('\n');

        let mut options = std::fs::OpenOptions::new();
        options.create(true).append(true).read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let path = self.log_path();
        let mut file = options.open(&path)?;
        // The mode above applies only on creation; tighten a pre-existing file
        // too, so a store created before a umask change does not stay readable.
        set_mode(&path, 0o600)?;

        // §1.1's torn-write rule: if the previous append died mid-line, start
        // a fresh one rather than gluing this record onto the wreckage — that
        // would cost two lines instead of one, and the second is this one.
        let len = file.seek(SeekFrom::End(0))?;
        if len > 0 {
            file.seek(SeekFrom::Start(len - 1))?;
            let mut last = [0u8; 1];
            std::io::Read::read_exact(&mut file, &mut last)?;
            if last[0] != b'\n' {
                file.write_all(b"\n")?;
            }
            file.seek(SeekFrom::End(0))?;
        }

        file.write_all(line.as_bytes())?;
        file.flush()?;
        Ok(())
    }

    pub fn save_session(&self, session: &Session) -> Result<()> {
        self.append("session.set", serde_json::to_value(session)?)
    }

    /// Forgetting is a record, not an edit to an earlier line (§1.1).
    pub fn clear_session(&self, server: &str) -> Result<()> {
        self.append("session.clear", serde_json::json!({ "server": server }))
    }

    pub fn set_server(&self, server: &str) -> Result<()> {
        self.append("server.set", serde_json::json!({ "server": server }))
    }

    pub fn set_map_pos(&self, server: &str, land: &str, category: &str, quest: &str) -> Result<()> {
        self.append(
            "map.pos",
            serde_json::json!({
                "server": server, "land": land, "category": category, "quest_id": quest
            }),
        )
    }
}

impl State {
    fn apply(&mut self, record: &Record) {
        let get = |key: &str| record.body.get(key).and_then(|v| v.as_str()).unwrap_or("");
        match record.kind.as_str() {
            "session.set" => {
                if let Ok(session) = serde_json::from_value::<Session>(record.body.clone()) {
                    self.sessions.insert(session.server.clone(), session);
                }
            }
            "session.clear" => {
                self.sessions.remove(get("server"));
            }
            "server.set" => {
                let server = get("server");
                if !server.is_empty() {
                    self.server = Some(server.to_string());
                }
            }
            "map.pos" => {
                let (server, land, category, quest) =
                    (get("server"), get("land"), get("category"), get("quest_id"));
                if !quest.is_empty() {
                    self.map_pos
                        .insert(format!("{server}\0{land}.{category}"), quest.to_string());
                }
            }
            // An unknown kind is a record from a newer client at the same
            // schema — ignored, the way an unknown message type is (§2.3).
            _ => {}
        }
    }
}

pub fn resolve_home(explicit: Option<&Path>) -> Result<PathBuf> {
    if let Some(p) = explicit {
        return Ok(expand_tilde(p));
    }
    if let Ok(v) = std::env::var(HOME_ENV) {
        if !v.trim().is_empty() {
            return Ok(expand_tilde(Path::new(v.trim())));
        }
    }
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .map_err(|_| error::internal("cannot find the user home directory; set CWBH_HOME"))?;
    Ok(PathBuf::from(home).join(DEFAULT_DIR))
}

/// Expand a leading `~`, which a shell would have done for an unquoted path.
/// Without it, `--home '~/hacker'` creates a directory literally named `~`.
fn expand_tilde(path: &Path) -> PathBuf {
    let text = path.to_string_lossy();
    let rest = match text.strip_prefix("~/") {
        Some(rest) => rest,
        None if text == "~" => "",
        None => return path.to_path_buf(),
    };
    match std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")) {
        Ok(home) if !home.is_empty() => PathBuf::from(home).join(rest),
        _ => path.to_path_buf(),
    }
}

pub fn set_mode(path: &Path, mode: u32) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))?;
    }
    #[cfg(not(unix))]
    {
        let _ = (path, mode);
    }
    Ok(())
}

/// RFC3339 UTC with seconds — PROTOCOL §2.4's timestamp shape, used for the
/// client's own records too so one format covers the whole program.
pub fn now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_store() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(Some(&dir.path().join("home"))).unwrap();
        (dir, store)
    }

    fn session(server: &str, token: &str) -> Session {
        Session {
            server: server.into(),
            token: token.into(),
            address: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94".into(),
            name: "ferris".into(),
        }
    }

    #[test]
    fn a_session_survives_a_replay() {
        let (_dir, store) = temp_store();
        assert!(store.load().unwrap().sessions.is_empty());
        store.save_session(&session("ws://a/ws", "tok-1")).unwrap();
        let state = store.load().unwrap();
        assert_eq!(state.session("ws://a/ws").unwrap().token, "tok-1");
    }

    /// SPEC §1.1 and PROTOCOL §4.4: the rotated token replaces the old one,
    /// and it does so by appending, not by editing the earlier line.
    #[test]
    fn a_rotated_token_supersedes_rather_than_edits() {
        let (_dir, store) = temp_store();
        store.save_session(&session("ws://a/ws", "tok-1")).unwrap();
        store.save_session(&session("ws://a/ws", "tok-2")).unwrap();
        assert_eq!(
            store.load().unwrap().session("ws://a/ws").unwrap().token,
            "tok-2"
        );
        let text = std::fs::read_to_string(store.log_path()).unwrap();
        assert_eq!(text.lines().count(), 2, "the first line is still there");
        assert!(text.contains("tok-1"));
    }

    /// The point of keying by URL: one token must never be offered to another
    /// server.
    #[test]
    fn two_servers_keep_two_tokens() {
        let (_dir, store) = temp_store();
        store.save_session(&session("ws://a/ws", "tok-a")).unwrap();
        store.save_session(&session("ws://b/ws", "tok-b")).unwrap();
        let state = store.load().unwrap();
        assert_eq!(state.session("ws://a/ws").unwrap().token, "tok-a");
        assert_eq!(state.session("ws://b/ws").unwrap().token, "tok-b");
        assert!(state.session("ws://c/ws").is_none());
    }

    #[test]
    fn forgetting_is_a_record() {
        let (_dir, store) = temp_store();
        store.save_session(&session("ws://a/ws", "tok-1")).unwrap();
        store.clear_session("ws://a/ws").unwrap();
        assert!(store.load().unwrap().session("ws://a/ws").is_none());
        assert_eq!(
            std::fs::read_to_string(store.log_path())
                .unwrap()
                .lines()
                .count(),
            2
        );
    }

    /// §1.1: "a crash can at worst lose the last, partial line — and an append
    /// that finds the previous line unterminated starts a fresh one, so a torn
    /// write costs that line and not the next one too."
    #[test]
    fn a_torn_line_costs_one_line_and_not_two() {
        let (_dir, store) = temp_store();
        store.save_session(&session("ws://a/ws", "tok-1")).unwrap();
        // Simulate a crash mid-append.
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(store.log_path())
            .unwrap();
        file.write_all(b"{\"schema\":1,\"kind\":\"sess").unwrap();
        drop(file);

        store.save_session(&session("ws://a/ws", "tok-2")).unwrap();
        let state = store.load().unwrap();
        assert_eq!(state.session("ws://a/ws").unwrap().token, "tok-2");
        assert_eq!(state.skipped.len(), 1, "exactly the torn line was skipped");
    }

    #[test]
    fn a_record_from_a_newer_schema_is_skipped_not_fatal() {
        let (_dir, store) = temp_store();
        store.save_session(&session("ws://a/ws", "tok-1")).unwrap();
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(store.log_path())
            .unwrap();
        file.write_all(b"{\"schema\":99,\"kind\":\"session.set\",\"at\":\"2026-09-11T00:00:00Z\",\"server\":\"ws://a/ws\",\"token\":\"from-the-future\",\"address\":\"0x0\"}\n").unwrap();
        drop(file);
        let state = store.load().unwrap();
        assert_eq!(state.session("ws://a/ws").unwrap().token, "tok-1");
        assert_eq!(state.skipped.len(), 1);
    }

    #[test]
    fn every_record_carries_schema_kind_and_a_timestamp() {
        let (_dir, store) = temp_store();
        store.set_server("ws://a/ws").unwrap();
        let line = std::fs::read_to_string(store.log_path()).unwrap();
        let value: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(value["schema"], 1);
        assert_eq!(value["kind"], "server.set");
        let at = value["at"].as_str().unwrap();
        assert!(at.ends_with('Z') && at.len() == 20, "{at}");
        assert!(!line.trim_end_matches('\n').contains('\n'), "one line");
    }

    #[cfg(unix)]
    #[test]
    fn the_store_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let (_dir, store) = temp_store();
        store.set_server("ws://a/ws").unwrap();
        let dir_mode = std::fs::metadata(store.home())
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        let file_mode = std::fs::metadata(store.log_path())
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(dir_mode, 0o700);
        assert_eq!(file_mode, 0o600);
    }

    #[test]
    fn the_work_dir_lowercases_the_address() {
        let (_dir, store) = temp_store();
        let mixed = store.work_dir("0x9858EfFD232B4033E47d90003D41EC34EcaEda94");
        let lower = store.work_dir("0x9858effd232b4033e47d90003d41ec34ecaeda94");
        assert_eq!(mixed, lower);
        assert!(mixed.ends_with("0x9858effd232b4033e47d90003d41ec34ecaeda94"));
    }

    #[test]
    fn an_unknown_kind_is_ignored_like_an_unknown_message_type() {
        let (_dir, store) = temp_store();
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(store.log_path())
            .unwrap();
        file.write_all(b"{\"schema\":1,\"kind\":\"ui.theme\",\"at\":\"2026-09-11T00:00:00Z\",\"theme\":\"amber\"}\n").unwrap();
        drop(file);
        let state = store.load().unwrap();
        assert!(state.skipped.is_empty(), "parsed fine, just not understood");
    }
}
