//! The player's files, and the editor that opens them.
//!
//! This is the product. A terminal player wants *their* editor, not one
//! written here, so the client's job is to put a real file on a real path and
//! then get out of the way:
//!
//! * `cwbh edit <id>` writes the starter **only if the file does not exist**.
//!   A second `edit` opens what the player wrote. The file is theirs.
//! * `run` and `submit` send that same file. There is no hidden buffer, no
//!   copy, and no "did you mean the one on disk" — one path, and `cwbh edit
//!   --path` prints it so `vim $(cwbh edit --path <id>)` works too.
//! * getting the starter back is `cwbh reset`, an explicit request, because
//!   PROTOCOL §4.11 makes it one. An `edit` that silently overwrote an
//!   afternoon's work would be the last time anybody used this.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::error::{self, Result};
use crate::proto::Quest;
use crate::store::{self, Store};

/// Where one quest's source lives.
///
/// Flat, under the address, named by the quest id: `rust.basic.03.shadowing.rs`
/// is greppable, sorts next to its neighbours, and shows something meaningful
/// in an editor's tab bar — which a directory full of `main.rs` does not.
pub fn path_for(store: &Store, address: &str, quest: &Quest) -> PathBuf {
    store
        .work_dir(address)
        .join(format!("{}.{}", quest.id, quest.file_extension()))
}

pub struct Opened {
    pub path: PathBuf,
    /// True when this call created the file from the quest's starter.
    pub created: bool,
}

/// Make sure the file exists, seeded from the starter if it is new.
pub fn ensure(store: &Store, address: &str, quest: &Quest) -> Result<Opened> {
    let path = path_for(store, address, quest);
    if path.exists() {
        return Ok(Opened {
            path,
            created: false,
        });
    }
    let dir = path.parent().expect("work paths have a parent");
    make_private_dirs(store, dir)?;
    // The work directory sits under the 0700 home, but the player's own source
    // gets 0600 of its own so a later `chmod` on the home cannot widen it.
    write_private(&path, &quest.starter)?;
    Ok(Opened {
        path,
        created: true,
    })
}

/// Overwrite with the starter — `cwbh reset`, and nothing else, calls this.
pub fn reset(store: &Store, path: &Path, starter: &str) -> Result<()> {
    if let Some(dir) = path.parent() {
        make_private_dirs(store, dir)?;
    }
    write_private(path, starter)
}

/// Create every directory between the store's home and `dir`, `0700` all the
/// way down.
///
/// `create_dir_all` applies the umask, which on a default macOS shell leaves
/// the intermediate `work/` at `0755` even though the home above it and the
/// address directory below it are both `0700`. One world-readable link in the
/// chain is enough to make the pair of `0700`s decoration.
fn make_private_dirs(store: &Store, dir: &Path) -> Result<()> {
    std::fs::create_dir_all(dir)?;
    let home = store.home();
    let mut chain = Vec::new();
    let mut cursor = Some(dir);
    while let Some(path) = cursor {
        if path == home {
            break;
        }
        chain.push(path.to_path_buf());
        cursor = path.parent();
    }
    for path in chain {
        store::set_mode(&path, 0o700)?;
    }
    Ok(())
}

pub fn read(path: &Path) -> Result<String> {
    std::fs::read_to_string(path).map_err(|e| {
        error::usage(format!(
            "cannot read {}: {e} — run `cwbh edit` first",
            path.display()
        ))
    })
}

pub fn write_private(path: &Path, contents: &str) -> Result<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    store::set_mode(path, 0o600)?;
    file.write_all(contents.as_bytes())?;
    file.flush()?;
    Ok(())
}

/// What the player's editor is, in the order every other unix tool asks.
///
/// Split on whitespace so `EDITOR="code -w"` and `EDITOR="emacsclient -nw"`
/// work — the common case of a flag that makes a GUI editor *wait* is exactly
/// the one that must not be mangled into a filename.
pub fn editor_command() -> (String, Vec<String>) {
    let configured = std::env::var("VISUAL")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .or_else(|| {
            std::env::var("EDITOR")
                .ok()
                .filter(|v| !v.trim().is_empty())
        })
        .unwrap_or_else(|| default_editor().to_string());
    let mut parts = configured.split_whitespace().map(String::from);
    let program = parts.next().unwrap_or_else(|| default_editor().to_string());
    (program, parts.collect())
}

fn default_editor() -> &'static str {
    // `vi` is in POSIX and is on every machine this runs on. `nano` would be
    // friendlier and is not guaranteed to exist.
    "vi"
}

pub struct EditResult {
    pub changed: bool,
    pub source: String,
}

/// Open the player's editor on `path` and wait for it.
///
/// Afterwards the file is compared with what went in. A GUI editor invoked
/// without its wait flag (`code` rather than `code -w`) returns instantly, and
/// without this check `cwbh play` would cheerfully submit the starter half a
/// second after opening it and report a compile error the player never wrote.
/// Saying "unchanged" is the difference between the loop being pleasant and
/// being baffling.
pub fn edit(path: &Path) -> Result<EditResult> {
    let before = std::fs::read_to_string(path).unwrap_or_default();
    let (program, args) = editor_command();
    let status = Command::new(&program)
        .args(&args)
        .arg(path)
        .status()
        .map_err(|e| {
            error::usage(format!(
                "cannot run your editor ({program}): {e} — set $EDITOR, or edit {} yourself",
                path.display()
            ))
        })?;
    if !status.success() {
        // A non-zero editor is not fatal: `vi` exits 1 on some quits and the
        // file on disk is still the truth.
        eprintln!("  {program} exited {}", status.code().unwrap_or(-1));
    }
    let after = read(path)?;
    Ok(EditResult {
        changed: after != before,
        source: after,
    })
}

/// PROTOCOL §4.9: *"source over 256 KiB"* is `bad_request`. Refusing locally
/// gives a better sentence than the server's, and saves a round trip.
pub const MAX_SOURCE: usize = 256 * 1024;

pub fn check_size(source: &str) -> Result<()> {
    if source.len() > MAX_SOURCE {
        return Err(error::usage(format!(
            "source is {} bytes; the limit is {} (PROTOCOL §4.9)",
            source.len(),
            MAX_SOURCE
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn quest(id: &str, land: &str) -> Quest {
        serde_json::from_value(serde_json::json!({
            "id": id, "land": land, "category": "basic", "node": 1,
            "title": "T", "difficulty": 1, "starter": "fn main() {}",
            "state": "open", "stars": 0,
            "tests": { "match": "trim", "timeout_ms": 5000, "visible": [], "hidden_count": 1 }
        }))
        .unwrap()
    }

    fn temp() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(Some(&dir.path().join("home"))).unwrap();
        (dir, store)
    }

    #[test]
    fn the_extension_follows_the_land() {
        let (_d, store) = temp();
        let rust = path_for(&store, "0xA", &quest("rust.basic.01.hello", "rust"));
        let go = path_for(&store, "0xA", &quest("go.basic.01.hello", "go"));
        let cpp = path_for(&store, "0xA", &quest("cpp.basic.01.hello", "cpp"));
        let py = path_for(&store, "0xA", &quest("python.basic.01.hello", "python"));
        assert!(rust.ends_with("rust.basic.01.hello.rs"));
        assert!(go.ends_with("go.basic.01.hello.go"));
        assert!(cpp.ends_with("cpp.basic.01.hello.cpp"));
        assert!(py.ends_with("python.basic.01.hello.py"));
    }

    /// The rule the whole editor loop rests on.
    #[test]
    fn a_second_edit_never_clobbers_the_players_work() {
        let (_d, store) = temp();
        let q = quest("rust.basic.01.hello", "rust");
        let first = ensure(&store, "0xA", &q).unwrap();
        assert!(first.created);
        assert_eq!(read(&first.path).unwrap(), "fn main() {}");

        write_private(&first.path, "fn main() { println!(\"mine\"); }").unwrap();
        let second = ensure(&store, "0xA", &q).unwrap();
        assert!(!second.created);
        assert_eq!(second.path, first.path);
        assert_eq!(
            read(&second.path).unwrap(),
            "fn main() { println!(\"mine\"); }",
            "ensure() must never write over an existing file"
        );
    }

    #[test]
    fn reset_is_the_one_thing_that_does_overwrite() {
        let (_d, store) = temp();
        let q = quest("rust.basic.01.hello", "rust");
        let opened = ensure(&store, "0xA", &q).unwrap();
        write_private(&opened.path, "mine").unwrap();
        reset(&store, &opened.path, &q.starter).unwrap();
        assert_eq!(read(&opened.path).unwrap(), "fn main() {}");
    }

    #[cfg(unix)]
    #[test]
    fn the_players_source_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let (_d, store) = temp();
        let opened = ensure(&store, "0xA", &quest("rust.basic.01.hello", "rust")).unwrap();
        let mode = std::fs::metadata(&opened.path)
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);
        // Every directory from the home down, not just the last one: an
        // intermediate `work/` at 0755 would undo both of its neighbours.
        let mut dir = opened.path.parent();
        while let Some(path) = dir {
            let dir_mode = std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
            assert_eq!(dir_mode, 0o700, "{} is not private", path.display());
            if path == store.home() {
                break;
            }
            dir = path.parent();
        }
    }

    #[test]
    fn a_wait_flag_survives_the_split() {
        std::env::remove_var("VISUAL");
        std::env::set_var("EDITOR", "code -w");
        assert_eq!(editor_command(), ("code".into(), vec!["-w".into()]));
        std::env::set_var("VISUAL", "emacsclient -nw");
        assert_eq!(editor_command(), ("emacsclient".into(), vec!["-nw".into()]));
        // VISUAL wins, and an empty one does not.
        std::env::set_var("VISUAL", "");
        assert_eq!(editor_command(), ("code".into(), vec!["-w".into()]));
        std::env::remove_var("VISUAL");
        std::env::remove_var("EDITOR");
        assert_eq!(editor_command(), ("vi".into(), Vec::<String>::new()));
    }

    #[test]
    fn oversized_source_is_refused_before_the_round_trip() {
        assert!(check_size(&"x".repeat(MAX_SOURCE)).is_ok());
        assert!(check_size(&"x".repeat(MAX_SOURCE + 1)).is_err());
    }
}
