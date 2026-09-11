//! Reading key material from a person, without echoing it.
//!
//! There is deliberately **no `--mnemonic` flag** anywhere in this client.
//! Not one with a warning, not one "for testing" — the flag does not exist,
//! because argv lands in `~/.zsh_history`, in `ps`, and in whatever shell
//! integration is watching. The only two ways a phrase gets in are this
//! prompt, which does not echo, and `--stdin`, which is a pipe.
//!
//! What comes out is `Zeroizing<String>`: it is wiped when it goes out of
//! scope rather than left in freed memory, where a realloc, a swap file or a
//! core dump can still carry it.

use std::io::{IsTerminal, Write};

use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use zeroize::Zeroizing;

use causewaybay_hacker_cli::error::{self, Result};

/// Raw mode, restored whatever happens.
///
/// Without this, a `?` on a read error — or a panic, or the Ctrl-C branch
/// below — leaves the player's shell with echo off and no way to see what they
/// are typing. The fix is a `Drop`, not a tidy-up at the end of the happy path.
struct RawMode;

impl RawMode {
    fn enter() -> Result<RawMode> {
        enable_raw_mode().map_err(|e| error::internal(format!("cannot read without echo: {e}")))?;
        Ok(RawMode)
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
    }
}

/// Prompt on **stderr** and read a secret with no echo.
///
/// The prompt goes to stderr so `cwbh … > file` still works and so the secret
/// can never be the thing that scrolls past on stdout.
pub fn prompt(label: &str) -> Result<Zeroizing<String>> {
    if !std::io::stdin().is_terminal() {
        return Err(error::usage(
            "no terminal to prompt on; pipe the phrase in with `cwbh login --stdin`",
        ));
    }

    eprint!("{label}: ");
    let _ = std::io::stderr().flush();

    let mut buffer = Zeroizing::new(String::new());
    {
        let _raw = RawMode::enter()?;
        loop {
            let e = event::read().map_err(|e| error::internal(format!("input failed: {e}")))?;
            let Event::Key(key) = e else { continue };
            // On Windows crossterm reports press *and* release; only one of
            // them is a character.
            if key.kind != KeyEventKind::Press {
                continue;
            }
            match key.code {
                KeyCode::Enter => break,
                KeyCode::Backspace => {
                    buffer.pop();
                }
                KeyCode::Esc => {
                    return Err(error::usage("cancelled"));
                }
                KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    return Err(error::usage("cancelled"));
                }
                KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    buffer.clear();
                }
                KeyCode::Char(c) => buffer.push(c),
                _ => {}
            }
        }
    }
    // Nothing is echoed, not even asterisks: a shoulder-surfer counting twelve
    // groups of stars learns the word count, and a screen recording keeps it.
    eprintln!();
    Ok(buffer)
}

/// Read the secret from stdin — one line, for a pipe or a test.
pub fn from_stdin() -> Result<Zeroizing<String>> {
    use std::io::BufRead;
    let mut line = Zeroizing::new(String::new());
    std::io::stdin().lock().read_line(&mut line)?;
    if line.trim().is_empty() {
        return Err(error::usage("nothing on stdin"));
    }
    Ok(Zeroizing::new(line.trim().to_string()))
}
