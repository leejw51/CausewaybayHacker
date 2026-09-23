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
        // PyTorch Land is Python, so its formatter is Python's: one `black`
        // on the machine formats both lands or neither.
        "python" | "pytorch" => black_is_installed(),
        // `prettier` is to TypeScript what `gofmt` is to Go — the formatter
        // everyone's colleagues actually run — but it ships with neither
        // `tsc` nor `node`, so it is asked of the machine like `black`.
        "typescript" => prettier_is_installed(),
        _ => false,
    }
}

/// Every land that can be formatted on this machine, for a client to draw
/// its button with (PROTOCOL §4.3): a button that always refuses is worse
/// than no button.
pub fn supported_langs() -> Vec<&'static str> {
    ["rust", "go", "cpp", "python", "pytorch", "typescript"]
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

/// How this machine is asked whether it has torch, in one place.
///
/// `-I` is not decoration: it is how the runner starts every program
/// (`python::run`), and it drops `PYTHONPATH` and the user site directory.
/// A torch that only a bare `python3 -c` can see — a `pip install --user`,
/// which is what an externally-managed interpreter pushes people towards —
/// is a torch no quest can import. Asked with the flag that decides it, or
/// `cwbhacker doctor` reports a land that is green and unplayable.
pub(crate) const TORCH_PROBE: &[&str] = &["-I", "-c", "import torch"];

/// What to type when it is not there.
///
/// An environment of the land's own rather than a bare `pip install`,
/// because the interpreters this most often meets — macOS's own, and any PEP
/// 668 distribution — refuse to install into themselves, and the `--user`
/// they suggest instead is the one place `-I` will not look. `numpy` is in
/// the line because torch without it writes a "Failed to initialize NumPy"
/// warning to stderr on every single import, and a warning on every run of
/// every node is the kind of noise a player learns to ignore, including when
/// it is a real one.
///
/// A conda env by name, because that is the fifth toolchain on the list the
/// README prints — RUST, GO, C++, PYTHON, ANACONDA — and because `make`
/// looks for exactly this name. A venv at `~/.causewaybayhacker/venv` is
/// found the same way, for a machine with no conda on it.
pub(crate) const TORCH_HINT: &str = "conda create -n cwbhacker python=3.13 -y && \
     conda run -n cwbhacker pip install torch numpy black   \
     (`make` puts that env first on PATH; started by hand, do it yourself. \
     No conda? python3 -m venv ~/.causewaybayhacker/venv works the same way)";

/// Whether this machine's `python3` can `import torch`, asked by running it.
///
/// Uncached on purpose: `doctor` and the boot report exist to tell the truth
/// about the machine as it is now. The hot path — every submission — caches
/// this behind [`crate::unsupported`].
pub fn torch_is_installed() -> bool {
    answers("python3", TORCH_PROBE)
}

/// What to type when TypeScript Land cannot run.
///
/// `tsc` runs on `node`, so one install line covers both halves once node is
/// there; `prettier` rides along because it is the land's formatter and costs
/// nothing more to ask for in the same breath.
pub(crate) const TYPESCRIPT_HINT: &str = "install node (https://nodejs.org), then: \
     npm install -g typescript prettier";

/// Whether `tsc` and `node` both answer. `tsc` is itself a node script, so a
/// `tsc --version` that succeeds has found a node too — but the runner starts
/// `node` by name as well, so both are asked.
pub fn typescript_is_installed() -> bool {
    answers("tsc", &["--version"]) && answers("node", &["--version"])
}

fn prettier_is_installed() -> bool {
    answers("prettier", &["--version"])
}

/// Where `clang-format` is, if it is anywhere.
///
/// On PATH is the Linux answer and the answer for anyone who installed it
/// themselves. On macOS it usually is **not** on PATH: Xcode's command line
/// tools ship it inside the developer directory, where only `xcrun` knows
/// the way — the same place `c++` itself comes from on that machine. Asking
/// `xcrun` is therefore not a special case, it is how this platform names
/// its toolchain, and without it every Mac reported "no C++ formatter"
/// while holding one.
fn clang_format_path() -> Option<std::ffi::OsString> {
    let runs = |program: &std::ffi::OsStr| {
        std::process::Command::new(program)
            .arg("--version")
            .stdin(std::process::Stdio::null())
            .output()
            .map(|out| out.status.success())
            .unwrap_or(false)
    };
    let plain = std::ffi::OsString::from("clang-format");
    if runs(&plain) {
        return Some(plain);
    }
    let found = std::process::Command::new("xcrun")
        .args(["--find", "clang-format"])
        .stdin(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|out| out.status.success())?;
    let path = String::from_utf8(found.stdout).ok()?.trim().to_string();
    if path.is_empty() {
        return None;
    }
    let path = std::ffi::OsString::from(path);
    runs(&path).then_some(path)
}

fn clang_format_is_installed() -> bool {
    clang_format_path().is_some()
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
            // not depend on a `.clang-format` the player cannot see. The
            // program is the resolved path, not the bare name: on macOS the
            // bare name is not on PATH at all.
            let mut c = Command::new(clang_format_path().expect("just checked"));
            c.arg("--style=LLVM").arg("--assume-filename=main.cpp");
            c
        }
        "cpp" => {
            return Ok(Formatted::unchanged(
                source,
                "clang-format is not installed on this machine",
            ))
        }
        "python" | "pytorch" if black_is_installed() => {
            // `-` is stdin to stdout; `-q` keeps the summary off stderr.
            let mut c = Command::new("python3");
            c.args(["-m", "black", "-q", "-"]);
            c
        }
        "python" | "pytorch" => {
            return Ok(Formatted::unchanged(
                source,
                "black is not installed on this machine",
            ))
        }
        "typescript" if prettier_is_installed() => {
            // The file name is how prettier picks its parser from stdin; its
            // defaults are the style, as LLVM's are for clang-format.
            let mut c = Command::new("prettier");
            c.arg("--stdin-filepath").arg("main.ts");
            c
        }
        "typescript" => {
            return Ok(Formatted::unchanged(
                source,
                "prettier is not installed on this machine",
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

// ---------------------------------------------------------------------------
// What this machine can actually do
// ---------------------------------------------------------------------------

/// One land's toolchain, as this machine has it.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Toolchain {
    pub land: &'static str,
    /// The compiler or interpreter, and whether it answered.
    pub compiler: &'static str,
    pub compiles: bool,
    /// The formatter behind `code.format`, and whether it answered.
    pub formatter: &'static str,
    pub formats: bool,
    /// What to type when one of them is missing. Empty when both are here.
    pub install: String,
}

fn answers(program: &str, args: &[&str]) -> bool {
    std::process::Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::null())
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

/// Every land, its compiler and its formatter, checked by running them.
///
/// The server prints this on the way up. A land whose compiler is missing is
/// a fifth of the map that cannot be played, and a land whose formatter is
/// missing is a button that will not be drawn — both are worth knowing at
/// boot rather than at the moment a player presses something. The advice is
/// per platform, because "install clang-format" is three different sentences
/// on three machines.
pub fn toolchains() -> Vec<Toolchain> {
    let mac = cfg!(target_os = "macos");
    let cpp_hint = if mac {
        "xcode-select --install   (Xcode ships clang-format; xcrun finds it)"
    } else {
        "apt install build-essential clang-format"
    };
    let mut out = Vec::new();
    for (land, compiler, args, formatter, hint) in [
        (
            "rust",
            "rustc",
            &["--version"][..],
            "rustfmt",
            "https://rustup.rs   then: rustup component add rustfmt",
        ),
        (
            "go",
            "go",
            &["version"][..],
            "gofmt",
            "https://go.dev/dl/   (gofmt ships with it)",
        ),
        ("cpp", "c++", &["--version"][..], "clang-format", cpp_hint),
        (
            "python",
            "python3",
            &["--version"][..],
            "black",
            "python3 -m pip install black",
        ),
        // PyTorch Land's "compiler" is the same `python3`, but a python3
        // without torch cannot run one node of it. Asking the interpreter to
        // import it is the only honest check, and it is the one whose answer
        // decides whether a submission to the land is accepted at all
        // (`crate::unsupported`).
        ("pytorch", "python3", TORCH_PROBE, "black", TORCH_HINT),
        // TypeScript Land's compiler is `tsc`; the `node` it runs on and the
        // `node` that runs the program are the same one, and a `tsc` that
        // answers has found it.
        ("typescript", "tsc", &["--version"][..], "prettier", TYPESCRIPT_HINT),
    ] {
        let compiles = answers(compiler, args);
        let formats = is_supported(land);
        out.push(Toolchain {
            land,
            compiler,
            compiles,
            formatter,
            formats,
            install: if compiles && formats {
                String::new()
            } else {
                hint.to_string()
            },
        });
    }
    out
}
