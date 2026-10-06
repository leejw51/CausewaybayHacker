//! The crate shelf (SPEC §5.1): the crates a Rust quest may depend on, and
//! whether this machine has them built.
//!
//! A Rust quest is `rustc` on one file, offline, and that is the right
//! default: the language's own grammar needs nothing from crates.io. The
//! FRAMEWORKS road is the exception on purpose — anyhow, serde, tokio, clap
//! are what every file on a real street starts with — and a quest there
//! names `crates = [...]` in its test spec. The runner then builds it with
//! cargo against **every** crate in `shelf/Cargo.toml`, with the lockfile
//! beside it copied in, so each such quest resolves one dependency graph and
//! links against artifacts compiled once.
//!
//! "Compiled once" is `cwbhacker warm`: [`warm`] builds the shelf package
//! into the shared `CARGO_HOME` / `CARGO_TARGET_DIR` under `build/rust/`,
//! with the network allowed, and writes a marker holding the digest of the
//! two embedded files. [`is_warm`] reads it back. A quest is refused before
//! an attempt row exists when the marker is missing or stale
//! (`crate::unsupported`), because the alternative — a cold `tokio` compiled
//! inside the quest's compile budget — is a `timeout` verdict on a correct
//! answer, and `prune --builds` makes the cache cold again at any time.
//!
//! Only the digest is compared: the shelf's two files are embedded, so a
//! server built from a newer shelf than the one a machine warmed says so,
//! and the fix is the same command.

use std::path::{Path, PathBuf};
use std::process::Command;

use sha2::{Digest, Sha256};

/// `backend/runner/shelf/Cargo.toml`, as text: the dependency table is
/// copied into every crate quest's manifest and the names are what a quest's
/// `crates` list is checked against.
pub const MANIFEST: &str = include_str!("../shelf/Cargo.toml");
/// `backend/runner/shelf/Cargo.lock`: copied beside every crate quest's
/// manifest so cargo resolves nothing and the build is the warm build.
pub const LOCKFILE: &str = include_str!("../shelf/Cargo.lock");
/// The shelf's own source, rebuilt where `warm` runs.
const LIB_RS: &str = include_str!("../shelf/src/lib.rs");

/// The marker `warm` leaves under the Rust build directory.
const MARKER: &str = "shelf.ok";

/// The command a refusal names. One spelling, so the message the player
/// reads and the one `doctor` prints are the same words.
pub const WARM_HINT: &str = "cwbhacker warm   (builds the crate shelf under ~/.causewaybayhacker/build/rust; needs the network once)";

/// Every crate on the shelf, in manifest order: the keys of the embedded
/// manifest's `[dependencies]` table.
///
/// Read off the text rather than kept as a second list, so there is one
/// place a crate is added. The file is this repository's own and has one
/// `[dependencies]` table with one dependency per line, which is all the
/// parsing below assumes — and a unit test holds it to that.
pub fn names() -> Vec<&'static str> {
    dependency_lines().map(key_of).collect()
}

/// The `[dependencies]` table of the embedded manifest, verbatim, header
/// included — what a crate quest's manifest carries.
pub fn dependencies_block() -> String {
    let mut out = String::from("[dependencies]\n");
    for line in dependency_lines() {
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// The lines of the `[dependencies]` table: from its header to the next
/// table header, comments and blanks dropped.
fn dependency_lines() -> impl Iterator<Item = &'static str> {
    MANIFEST
        .lines()
        .skip_while(|line| line.trim() != "[dependencies]")
        .skip(1)
        .take_while(|line| !line.trim_start().starts_with('['))
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
}

fn key_of(line: &str) -> &str {
    line.split('=').next().unwrap_or("").trim()
}

/// Is every name on the shelf? The first that is not, with what the shelf
/// has, so a pack author can fix the spelling or propose the crate.
pub fn unknown(crates: &[String]) -> Option<String> {
    let shelf = names();
    crates
        .iter()
        .find(|c| !shelf.contains(&c.as_str()))
        .map(|c| {
            format!(
                "crate '{c}' is not on the shelf; the shelf has: {}",
                shelf.join(", ")
            )
        })
}

/// sha256 over the two embedded files, hex. What the marker holds.
pub fn digest() -> String {
    let mut hasher = Sha256::new();
    hasher.update(MANIFEST.as_bytes());
    hasher.update(LOCKFILE.as_bytes());
    hex(&hasher.finalize())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Where the marker lives for the Rust build directory `build_dir`
/// (`build/rust/`, the `cache_root` of every Rust submission).
pub fn marker_path(build_dir: &Path) -> PathBuf {
    build_dir.join(MARKER)
}

/// Was the shelf built under `build_dir` from exactly the embedded manifest
/// and lockfile?
pub fn is_warm(build_dir: &Path) -> bool {
    std::fs::read_to_string(marker_path(build_dir))
        .map(|text| text.trim() == digest())
        .unwrap_or(false)
}

/// Why a crate quest cannot be judged on this machine, if it cannot.
pub fn refusal(build_dir: &Path) -> Option<String> {
    (!is_warm(build_dir)).then(|| {
        format!(
            "this machine has not built the crate shelf that every FRAMEWORKS \
             quest links against, or built an older one: {WARM_HINT}"
        )
    })
}

/// Build the shelf under `build_dir`: `cargo fetch --locked` and then
/// `cargo build --release --locked` of the shelf package, with `CARGO_HOME`
/// and `CARGO_TARGET_DIR` exactly where a submission's are (§5.1), so what
/// is compiled here is what a quest's build finds already compiled. The
/// network is allowed; nothing else about the environment differs from a
/// quest build — the same cleared environment, because a `RUSTFLAGS` in the
/// operator's shell would change every artifact's hash and warm nothing.
///
/// `log` receives cargo's own lines as they come. On success the marker is
/// written last, so a build that died half way leaves the shelf cold.
pub fn warm(build_dir: &Path, log: &dyn Fn(&str)) -> std::io::Result<()> {
    let shelf = build_dir.join("shelf");
    std::fs::create_dir_all(shelf.join("src"))?;
    std::fs::write(shelf.join("Cargo.toml"), MANIFEST)?;
    std::fs::write(shelf.join("Cargo.lock"), LOCKFILE)?;
    std::fs::write(shelf.join("src/lib.rs"), LIB_RS)?;
    // A stale marker must not outlive a rebuild that fails.
    let _ = std::fs::remove_file(marker_path(build_dir));

    for args in [
        &["fetch", "--locked"][..],
        &["build", "--release", "--locked"][..],
    ] {
        log(&format!("$ cargo {}", args.join(" ")));
        let mut cargo = Command::new("cargo");
        cargo.current_dir(&shelf).args(args);
        env(&mut cargo, build_dir, &shelf);
        let out = cargo.output()?;
        for line in String::from_utf8_lossy(&out.stderr).lines() {
            log(line);
        }
        if !out.status.success() {
            return Err(std::io::Error::other(format!(
                "cargo {} failed with {}",
                args.join(" "),
                out.status
            )));
        }
    }
    std::fs::write(marker_path(build_dir), format!("{}\n", digest()))?;
    Ok(())
}

/// A quest build's environment plus what reaching crates.io may need.
fn env(cargo: &mut Command, build_dir: &Path, workdir: &Path) {
    crate::harness::toolchain_base(cargo, workdir);
    for name in [
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "http_proxy",
        "https_proxy",
        "NO_PROXY",
        "no_proxy",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "CARGO_HTTP_CAINFO",
        "CARGO_REGISTRIES_CRATES_IO_PROTOCOL",
    ] {
        if let Some(value) = std::env::var_os(name) {
            cargo.env(name, value);
        }
    }
    cargo
        .env("CARGO_HOME", build_dir.join("cargo-home"))
        .env("CARGO_TARGET_DIR", build_dir.join("target"))
        .env("CARGO_TERM_COLOR", "never");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shelf_has_the_crates_the_frameworks_road_is_about() {
        let shelf = names();
        for crate_name in [
            "anyhow",
            "thiserror",
            "serde",
            "serde_json",
            "toml",
            "clap",
            "tokio",
            "futures",
            "crossbeam",
            "rayon",
            "parking_lot",
            "rand",
            "regex",
            "chrono",
            "itertools",
            "log",
            "indexmap",
            "hex",
            "bytes",
            "uuid",
            "bincode",
            "tracing",
            "tracing-subscriber",
            "reqwest",
            "rusqlite",
        ] {
            assert!(
                shelf.contains(&crate_name),
                "{crate_name} missing from the shelf"
            );
        }
        assert_eq!(shelf.len(), 25, "{shelf:?}");
    }

    #[test]
    fn every_dependency_line_is_one_crate_with_a_version() {
        // What `names` and `dependencies_block` assume of the file.
        for line in dependency_lines() {
            let key = key_of(line);
            assert!(
                !key.is_empty()
                    && key
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-'),
                "{line:?}"
            );
            assert!(line.contains("version") || line.contains('"'), "{line:?}");
        }
        let block = dependencies_block();
        assert!(block.starts_with("[dependencies]\n"));
        assert!(block.contains("\ntokio = "));
        assert!(!block.contains("[workspace]"));
        assert!(!block.contains("[package]"));
    }

    #[test]
    fn the_lockfile_pins_every_shelf_crate() {
        for name in names() {
            assert!(
                LOCKFILE.contains(&format!("name = \"{name}\"\n")),
                "{name} is not in Cargo.lock; run cargo generate-lockfile in runner/shelf"
            );
        }
    }

    #[test]
    fn an_unknown_crate_is_named_with_the_shelf() {
        assert_eq!(unknown(&["serde".into(), "tokio".into()]), None);
        let why = unknown(&["serde".into(), "diesel".into()]).unwrap();
        assert!(why.contains("'diesel'"), "{why}");
        assert!(why.contains("anyhow"), "{why}");
    }

    #[test]
    fn a_missing_or_stale_marker_is_cold() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(!is_warm(tmp.path()));
        assert!(refusal(tmp.path()).unwrap().contains("cwbhacker warm"));
        std::fs::write(marker_path(tmp.path()), "0000\n").unwrap();
        assert!(!is_warm(tmp.path()), "a marker from another shelf is cold");
        std::fs::write(marker_path(tmp.path()), format!("{}\n", digest())).unwrap();
        assert!(is_warm(tmp.path()));
        assert_eq!(refusal(tmp.path()), None);
    }

    #[test]
    fn the_digest_is_hex_sha256() {
        let d = digest();
        assert_eq!(d.len(), 64);
        assert!(d.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
