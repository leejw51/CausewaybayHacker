//! `code.format` (PROTOCOL §4.9d): the language's own formatter, over stdin.
//!
//! `rustfmt` and `gofmt`, not a house style invented here — these are the tools
//! the player's colleagues use, and a trainer that teaches a private formatting
//! style is teaching something they will have to unlearn.
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

pub fn is_supported(lang: &str) -> bool {
    matches!(lang, "rust" | "go")
}

pub fn format(lang: &str, source: &str) -> std::io::Result<Formatted> {
    let mut command = match lang {
        "rust" => {
            let mut c = Command::new("rustfmt");
            c.arg("--edition").arg("2021").arg("--emit").arg("stdout");
            c
        }
        "go" => Command::new("gofmt"),
        other => {
            return Ok(Formatted::unchanged(
                source,
                format!("there is no formatter for '{other}'"),
            ))
        }
    };
    // Both tools read stdin and write stdout, so none of the per-attempt
    // directory machinery is needed. They are trusted tools rather than the
    // player's code, so they keep their environment and get no rlimits — what
    // they do get is the timeout and the output cap.
    command.env("TERM", "dumb");
    let outcome = proc::run(
        command,
        source.as_bytes(),
        &Limits {
            timeout: FORMAT_TIMEOUT,
            max_stdout: 8 << 20,
            max_stderr: 256 * 1024,
            apply_rlimits: false,
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
    let line = line.strip_prefix("<standard input>:").unwrap_or(line);
    if line.chars().count() > 200 {
        line.chars().take(197).collect::<String>() + "..."
    } else {
        line.to_string()
    }
}
