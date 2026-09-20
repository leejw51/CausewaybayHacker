//! `code.format` (PROTOCOL §4.9d): the language's own formatter, over stdin.
//!
//! `rustfmt`, `gofmt` and `clang-format`, not a house style invented here —
//! these are the tools the player's colleagues use, and a trainer that teaches
//! a private formatting style is teaching something they will have to unlearn.
//! Python has none: there is no formatter in a stock Python install, and
//! shipping an opinion about `black` versus `ruff` is not this game's job.
//!
//! The rule that shapes the whole module: **source that does not parse is not
//! an error.** A formatter is most often pressed in the middle of an edit, and
//! half-written code is the normal state of a text editor rather than a fault.
//! When the tool refuses, the original comes back byte for byte and its
//! complaint comes back beside it. Partially formatted text is never returned:
//! a formatter that mangles code it could not parse leaves the player with two
//! problems instead of one, and destroys work that is backed up nowhere.

use std::process::Command;
use std::time::Duration;

use crate::proc::{self, Limits};

/// Short, and its own: a formatter that hangs must not hold the connection.
const FORMAT_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone)]
pub struct Formatted {
    pub source: String,
    pub changed: bool,
    /// The formatter's own one-line complaint, when it had one.
    pub problem: Option<String>,
}

impl Formatted {
    /// The original, untouched, with a reason.
    fn unchanged(source: &str, problem: impl Into<String>) -> Formatted {
        Formatted {
            source: source.to_string(),
            changed: false,
            problem: Some(problem.into()),
        }
    }
}

/// Whether `code.format` is on for this land on this machine.
///
/// `rustfmt` and `gofmt` ship with their toolchains, so a land that runs at
/// all can format. `clang-format` does not ship with `c++` — Xcode's command
/// line tools and most distributions leave it out — so the C++ answer is
/// asked of `PATH` rather than assumed, and a client sees the button gone
/// rather than a button that always refuses.
pub fn is_supported(lang: &str) -> bool {
    match lang {
        "rust" | "go" => true,
        "cpp" => clang_format_is_installed(),
        "python" => black_is_installed(),
        _ => false,
    }
}

/// Every land that can be formatted on this machine, for a client to draw
/// its button with (PROTOCOL §4.3): a button that always refuses is worse
/// than no button.
pub fn supported_langs() -> Vec<&'static str> {
    ["rust", "go", "cpp", "python"]
        .into_iter()
        .filter(|lang| is_supported(lang))
        .collect()
}

/// Python's formatter is `black`, which is not in the standard library and
/// is asked of the machine rather than assumed — the same rule `cpp` gets.
/// It is run through `python3 -m black` so a `pip install black` into the
/// interpreter the runner already uses is found without a second PATH entry.
fn black_is_installed() -> bool {
    std::process::Command::new("python3")
        .args(["-m", "black", "--version"])
        .stdin(std::process::Stdio::null())
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

fn clang_format_is_installed() -> bool {
    std::process::Command::new("clang-format")
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

pub fn format(lang: &str, source: &str) -> std::io::Result<Formatted> {
    let mut command = match lang {
        "rust" => {
            let mut c = Command::new("rustfmt");
            c.arg("--edition").arg("2021").arg("--emit").arg("stdout");
            c
        }
        "go" => Command::new("gofmt"),
        "cpp" if clang_format_is_installed() => {
            // LLVM style is the tool's own default, named so the answer does
            // not depend on a `.clang-format` the player cannot see.
            let mut c = Command::new("clang-format");
            c.arg("--style=LLVM").arg("--assume-filename=main.cpp");
            c
        }
        "cpp" => {
            return Ok(Formatted::unchanged(
                source,
                "clang-format is not installed on this machine",
            ))
        }
        "python" if black_is_installed() => {
            // `-` is stdin to stdout; `-q` keeps the summary off stderr.
            let mut c = Command::new("python3");
            c.args(["-m", "black", "-q", "-"]);
            c
        }
        "python" => {
            return Ok(Formatted::unchanged(
                source,
                "black is not installed on this machine",
            ))
        }
        other => {
            return Ok(Formatted::unchanged(
                source,
                format!("there is no formatter for '{other}'"),
            ))
        }
    };
    // All three tools read stdin and write stdout, so none of the per-attempt
    // directory machinery is needed. They are trusted tools rather than the
    // player's code, so they get no rlimits — what they do get is the
    // timeout, the output cap, and the same allowlisted environment the
    // compilers get, with the scratch in the system temp dir since there is
    // no attempt directory to point it at.
    crate::harness::toolchain_base(&mut command, &std::env::temp_dir());
    let outcome = proc::run(
        command,
        source.as_bytes(),
        &Limits {
            timeout: FORMAT_TIMEOUT,
            max_stdout: 8 << 20,
            max_stderr: 256 * 1024,
            apply_rlimits: false,
            address_space: false,
        },
        "format",
        "format",
        proc::no_logs(),
    )?;

    if outcome.timed_out {
        return Ok(Formatted::unchanged(
            source,
            "the formatter ran out of time",
        ));
    }
    if outcome.exit_code != Some(0) {
        let problem = first_complaint(&String::from_utf8_lossy(&outcome.stderr));
        return Ok(Formatted::unchanged(source, problem));
    }
    let formatted = String::from_utf8_lossy(&outcome.stdout).to_string();
    if formatted.is_empty() && !source.is_empty() {
        // It said it succeeded and produced nothing. Whatever that is, it is
        // not a formatted version of the player's file.
        return Ok(Formatted::unchanged(
            source,
            "the formatter returned nothing",
        ));
    }
    Ok(Formatted {
        changed: formatted != source,
        source: formatted,
        problem: None,
    })
}

/// One line, for a client to show quietly beside the buffer it did not touch.
fn first_complaint(stderr: &str) -> String {
    let line = stderr
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("the formatter refused the file");
    let line = line
        .strip_prefix("error: ")
        .or_else(|| line.strip_prefix("error:"))
        .unwrap_or(line)
        .trim();
    // gofmt's name for stdin, and clang-format's.
    let line = line.strip_prefix("<standard input>:").unwrap_or(line);
    let line = line.strip_prefix("<stdin>:").unwrap_or(line);
    if line.chars().count() > 200 {
        line.chars().take(197).collect::<String>() + "..."
    } else {
        line.to_string()
    }
}
