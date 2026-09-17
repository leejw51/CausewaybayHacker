//! The home directory (SPEC §1): where it is, and the rule that everything
//! inside it is the owner's alone.
//!
//! `Home` is passed in, never discovered by the code that uses it. Tests hand
//! it a `TempDir`; resolution from the flag and the environment happens once,
//! in the CLI. Anything that reaches for `$HOME` deep in a call stack is one
//! `set_var` away from a test writing into the real `~/.causewaybayhacker`.

use std::path::{Path, PathBuf};

use crate::error::{internal, Result};

pub const HOME_ENV: &str = "CAUSEWAYBAY_HACKER_HOME";
pub const DEFAULT_DIR: &str = ".causewaybayhacker";

/// Resolve the home: explicit flag, then `CAUSEWAYBAY_HACKER_HOME`, then
/// `~/.causewaybayhacker` (SPEC §1, in that precedence order).
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
        .map_err(|_| internal(format!("cannot find the user home; set {HOME_ENV}")))?;
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

/// The layout of SPEC §1, as methods rather than string concatenation at the
/// call sites.
#[derive(Debug, Clone)]
pub struct Home {
    root: PathBuf,
}

impl Home {
    /// Open the home, creating the directory skeleton if it is not there.
    pub fn open(root: impl Into<PathBuf>) -> Result<Home> {
        let home = Home { root: root.into() };
        for dir in [
            home.root.clone(),
            home.content_dir(),
            home.users_dir(),
            home.build_dir(),
            home.build_lang_dir("rust"),
            home.build_lang_dir("go"),
            home.build_lang_dir("cpp"),
            home.build_lang_dir("python"),
            home.root.join("build/go/gocache"),
            home.root.join("build/go/gomodcache"),
            home.root.join("build/rust/cargo-home"),
            home.root.join("build/rust/target"),
            home.edits_dir(),
            home.logs_dir(),
            home.backups_dir(),
        ] {
            ensure_dir(&dir)?;
        }
        Ok(home)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn db_path(&self) -> PathBuf {
        self.root.join("hacker.db")
    }
    pub fn content_dir(&self) -> PathBuf {
        self.root.join("content")
    }
    pub fn users_dir(&self) -> PathBuf {
        self.root.join("users")
    }
    pub fn build_dir(&self) -> PathBuf {
        self.root.join("build")
    }
    pub fn build_lang_dir(&self, lang: &str) -> PathBuf {
        self.build_dir().join(lang)
    }
    /// `edits/` — the undo/redo stacks' content store (`edits.rs`). A root of
    /// its own rather than a corner of `users/`, because what is under it is
    /// not the player's saved work but the trail behind it: `cwbhacker prune`
    /// may throw the whole tree away and lose nothing that was ever submitted.
    pub fn edits_dir(&self) -> PathBuf {
        self.root.join("edits")
    }
    /// `edits/<address>/<quest_id>/` — one directory per stack, holding the
    /// `<sha>.<ext>` blobs its rows name. The address is lowercased for the
    /// same reason `user_dir` lowercases it (SPEC §3.4).
    pub fn edit_dir(&self, address: &str, quest_id: &str) -> PathBuf {
        self.edits_dir()
            .join(address.to_ascii_lowercase())
            .join(quest_id)
    }
    pub fn logs_dir(&self) -> PathBuf {
        self.root.join("logs")
    }
    /// `backups/hacker-<stamp>.db` — a copy of the database taken at every
    /// start, before the migrations touch it (`db::backup`). The record is
    /// the player's weeks of clears; a home that was wiped, or a migration
    /// that went wrong, must not be the end of it.
    pub fn backups_dir(&self) -> PathBuf {
        self.root.join("backups")
    }
    pub fn log_file(&self) -> PathBuf {
        self.logs_dir().join("server.jsonl")
    }

    /// `users/<address>/` — the address is lowercase (SPEC §3.4). Two
    /// spellings of one wallet must not become two directories, and on a
    /// case-insensitive filesystem they would silently share one anyway.
    pub fn user_dir(&self, address: &str) -> PathBuf {
        self.users_dir().join(address.to_ascii_lowercase())
    }
    pub fn profile_path(&self, address: &str) -> PathBuf {
        self.user_dir(address).join("profile.json")
    }
    /// `users/<address>/progress.json` — the readable mirror of what the
    /// database knows about this player (`snapshot.rs`). Beside `profile.json`
    /// and for the same reason: the home is human-shaped on purpose.
    pub fn progress_path(&self, address: &str) -> PathBuf {
        self.user_dir(address).join("progress.json")
    }
    pub fn attempt_dir(&self, address: &str, attempt_id: &str) -> PathBuf {
        self.user_dir(address).join("attempts").join(attempt_id)
    }
    /// `users/<address>/snippets/<id>/` — the playground's own work, kept
    /// beside the attempts for the same reason they are there: it is the
    /// player's writing, and a database is a worse place to lose it from.
    pub fn snippet_dir(&self, address: &str, snippet_id: &str) -> PathBuf {
        self.user_dir(address).join("snippets").join(snippet_id)
    }
    /// `users/<address>/snippets/<id>/photos/` — the pictures posted in the
    /// pad's chatroom, one file per image message (docs/agent.md §6). Inside
    /// the snippet's own folder so deleting the pad takes the room with it.
    pub fn snippet_photo_dir(&self, address: &str, snippet_id: &str) -> PathBuf {
        self.snippet_dir(address, snippet_id).join("photos")
    }

    /// Scratch for one attempt (SPEC §5.1). Under `build/`, never `/tmp`.
    pub fn attempt_build_dir(&self, lang: &str, attempt_id: &str) -> PathBuf {
        self.build_lang_dir(lang).join(attempt_id)
    }

    pub fn ensure_user_dirs(&self, address: &str) -> Result<()> {
        ensure_dir(&self.user_dir(address))?;
        ensure_dir(&self.user_dir(address).join("attempts"))?;
        ensure_dir(&self.user_dir(address).join("snippets"))
    }
}

/// Create a directory if missing, owner-only.
pub fn ensure_dir(dir: &Path) -> Result<()> {
    if !dir.exists() {
        std::fs::create_dir_all(dir)?;
    }
    set_private(dir, 0o700)
}

/// Write a file that is owner-only from the moment it exists: `fs::write`
/// followed by a chmod leaves a window in which it sits behind the umask.
pub fn write_private(path: &Path, contents: impl AsRef<[u8]>) -> Result<()> {
    use std::io::Write;
    if let Some(parent) = path.parent() {
        ensure_dir(parent)?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    // The mode above applies only on creation; tighten a pre-existing file.
    set_private(path, 0o600)?;
    file.write_all(contents.as_ref())?;
    file.flush()?;
    Ok(())
}

/// Tighten permissions. A no-op where the platform has no Unix modes.
pub fn set_private(path: &Path, mode: u32) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if path.exists() {
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))?;
        }
    }
    #[cfg(not(unix))]
    {
        let _ = (path, mode);
    }
    Ok(())
}
