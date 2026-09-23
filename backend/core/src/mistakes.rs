//! The mistake taxonomy (SPEC §7).
//!
//! A mistake is classified by the compiler's own identity for it — `E0382`,
//! not a regex over prose. `rustc --error-format=json` emits one JSON object
//! per line on **stderr**, each carrying `code.code` and a span.
//!
//! The rule that matters: **an unmatched code is never dropped.** It is stored
//! as `other` with its code kept, so the table below can grow out of real data
//! rather than guesses.

use std::collections::BTreeSet;

use rusqlite::{params, Connection};
use serde::Serialize;

use crate::error::Result;
use crate::time::now_stamp;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Mistake {
    pub kind: String,
    pub code: Option<String>,
    pub message: String,
    pub line: Option<i64>,
    pub col: Option<i64>,
}

/// SPEC §7.1, the rust column. Returning `None` means "not in the table", and
/// the caller stores `other` with the code intact.
///
/// `E0277` is absent here on purpose: it is two different lessons and needs
/// the message to tell them apart. See [`rust_kind_with_message`].
pub fn rust_kind(code: &str) -> Option<&'static str> {
    Some(match code {
        "E0382" | "E0505" => "borrow-after-move",
        "E0499" | "E0502" => "borrow-conflict",
        // E0373 is a closure that may outlive the function whose local it
        // borrowed. Nothing was moved — the value escaped — so it is a
        // lifetime lesson, not an ownership one.
        "E0106" | "E0597" | "E0621" | "E0373" => "lifetime",
        "E0308" => "type-mismatch",
        "E0425" | "E0433" => "unknown-name",
        "E0277" => "missing-trait",
        "E0596" | "E0594" => "mutability",
        "unused_variables" | "unused_imports" | "unused_mut" => "unused",
        _ => return None,
    })
}

/// `E0277` fires both for "you forgot to implement `Display`" and for "you
/// ignored a `Result`", and the two want opposite advice: one sends the player
/// to read about traits, the other to read about error handling. Discriminate
/// on the unsatisfied trait the message names.
pub fn rust_kind_with_message(code: &str, message: &str) -> Option<&'static str> {
    if code == "E0277" && mentions_error_handling(message) {
        return Some("unhandled-error");
    }
    rust_kind(code)
}

fn mentions_error_handling(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    // `?` is the discriminator, and rustc has two wordings for it, both seen
    // on this toolchain:
    //
    //   "the `?` operator can only be used in a function that returns …"
    //   "`?` couldn't convert the error to `MyError`"
    //
    // Matching the operator itself rather than one sentence catches both, and
    // an E0277 that mentions `?` at all is about carrying an error. The
    // trait-bound wordings — "`Point` is not an iterator", "`MyError` doesn't
    // implement `Debug`" — never do, even the one on `fn main() -> Result`,
    // and those really are "go and implement the trait".
    lower.contains("`?`")
        || lower.contains("termination")
        || lower.contains("`try`")
        || lower.contains("fromresidual")
}

/// The lint names §7.1 lists under `unused` arrive as warnings, not errors. A
/// filter on `level == "error"` silently loses a whole row of the table.
const KEPT_WARNINGS: &[&str] = &["unused_variables", "unused_imports", "unused_mut"];

/// A human label for the stats screen. Not stored: the slug is the key.
pub fn label(kind: &str) -> &'static str {
    match kind {
        "borrow-after-move" => "use after move",
        "borrow-conflict" => "conflicting borrows",
        "lifetime" => "lifetimes",
        "type-mismatch" => "type mismatch",
        "unknown-name" => "unknown name",
        "missing-trait" => "missing trait bound",
        "unused" => "unused code",
        "mutability" => "mutability",
        "nil-deref" => "nil dereference",
        "index-range" => "index out of range",
        "data-race" => "data race",
        "deadlock" => "deadlock",
        "unhandled-error" => "unhandled error",
        "syntax" => "syntax",
        "wrong-answer" => "wrong answer",
        "timeout" => "too slow",
        _ => "other",
    }
}

/// Squeeze a compiler message down to the one line that goes in the table.
pub fn normalize_message(message: &str) -> String {
    let first = message.lines().next().unwrap_or("").trim();
    let collapsed = first.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() > 300 {
        collapsed.chars().take(297).collect::<String>() + "..."
    } else {
        collapsed
    }
}

/// Classify `rustc --error-format=json` output.
///
/// Lines that are not JSON, or JSON this does not understand, are skipped
/// rather than failing the attempt: newer rustc interleaves `$message_type`
/// variants (`artifact`, `future_incompat`) and a player's attempt should not
/// break because the toolchain grew a field.
pub fn classify_rust_json(stderr: &str) -> Vec<Mistake> {
    let mut out = Vec::new();
    for line in stderr.lines() {
        let line = line.trim();
        if !line.starts_with('{') {
            continue;
        }
        let value: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if let Some(t) = value.get("$message_type").and_then(|v| v.as_str()) {
            if t != "diagnostic" {
                continue;
            }
        }
        let level = value.get("level").and_then(|v| v.as_str()).unwrap_or("");
        if !matches!(level, "error" | "warning") {
            continue;
        }
        let message = value.get("message").and_then(|v| v.as_str()).unwrap_or("");
        if is_summary(message) {
            continue;
        }
        let code = value
            .get("code")
            .and_then(|c| c.get("code"))
            .and_then(|v| v.as_str())
            .map(str::to_string);
        if level == "warning" {
            match code.as_deref() {
                Some(c) if KEPT_WARNINGS.contains(&c) => {}
                // Every other warning is noise for the taxonomy: the code
                // compiled, so it is not a mistake the player has to fix.
                _ => continue,
            }
        }
        let kind = match code.as_deref() {
            Some(c) => rust_kind_with_message(c, message)
                .unwrap_or("other")
                .to_string(),
            None if looks_like_parse_error(message) => "syntax".to_string(),
            None => "other".to_string(),
        };
        let (line_no, col_no) = primary_span(&value);
        out.push(Mistake {
            kind,
            code,
            message: normalize_message(message),
            line: line_no,
            col: col_no,
        });
    }
    out
}

fn is_summary(message: &str) -> bool {
    message.starts_with("aborting due to")
        || message.starts_with("For more information about")
        || message.starts_with("Some errors have detailed")
        || message.starts_with("For more information about an error")
        || message.starts_with("warning: ") && message.contains("generated")
}

fn looks_like_parse_error(message: &str) -> bool {
    const MARKERS: &[&str] = &[
        "expected",
        "unexpected",
        "unclosed",
        "mismatched closing delimiter",
        "unterminated",
        "missing",
        "this file contains an unclosed delimiter",
    ];
    let lower = message.to_ascii_lowercase();
    MARKERS.iter().any(|m| lower.contains(m))
}

fn primary_span(value: &serde_json::Value) -> (Option<i64>, Option<i64>) {
    let spans = match value.get("spans").and_then(|s| s.as_array()) {
        Some(s) => s,
        None => return (None, None),
    };
    let primary = spans
        .iter()
        .find(|s| {
            s.get("is_primary")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
        })
        .or_else(|| spans.first());
    match primary {
        Some(span) => (
            span.get("line_start").and_then(|v| v.as_i64()),
            span.get("column_start").and_then(|v| v.as_i64()),
        ),
        None => (None, None),
    }
}

/// Rust's runtime failures: a panic that made it out of `main`.
pub fn classify_rust_runtime(stderr: &str) -> Vec<Mistake> {
    let mut out = Vec::new();
    let lower = stderr.to_ascii_lowercase();
    if lower.contains("index out of bounds") {
        out.push(Mistake {
            kind: "index-range".into(),
            code: None,
            message: normalize_message(
                stderr
                    .lines()
                    .find(|l| l.to_ascii_lowercase().contains("index out of bounds"))
                    .unwrap_or("index out of bounds"),
            ),
            line: None,
            col: None,
        });
    }
    if lower.contains("called `option::unwrap()` on a `none` value")
        || lower.contains("called `result::unwrap()` on an `err` value")
    {
        out.push(Mistake {
            kind: "unhandled-error".into(),
            code: None,
            message: normalize_message(
                stderr
                    .lines()
                    .find(|l| l.to_ascii_lowercase().contains("unwrap()"))
                    .unwrap_or("unwrap on an empty value"),
            ),
            line: None,
            col: None,
        });
    }
    out
}

// ---------------------------------------------------------------------------
// Go (SPEC §7.1's second column)
//
// Rust hands over `E0382` in JSON. Go hands over prose with a file, a line, a
// column and the player's own identifiers in it. So the identity has to be
// *made*: the message is normalized down to its shape, and the shape is what
// becomes `mistakes.code` — `go:undefined`, `go:cannot-use-as`. The player's
// variable name belongs in `mistakes.message`, never in the identity, or
// "your top mistake" becomes a list of one-offs.
// ---------------------------------------------------------------------------

/// `./main.go:7:14: cannot use "42" (…) as int value` → the kind and the
/// identity. `None` where nothing in §7.1 matches, and the caller then makes
/// an identity out of the message shape rather than dropping it.
pub fn go_kind(message: &str) -> Option<(&'static str, &'static str)> {
    let lower = message.to_ascii_lowercase();
    // Ordered by how specific the phrase is, not alphabetically: "declared and
    // not used: x" and "x declared and not used" are both real wordings across
    // Go versions, so match on the phrase rather than the position.
    if lower.starts_with("syntax error") {
        return Some(("syntax", "go:syntax"));
    }
    if lower.starts_with("undefined:") {
        return Some(("unknown-name", "go:undefined"));
    }
    if lower.starts_with("cannot use ") {
        return Some(("type-mismatch", "go:cannot-use-as"));
    }
    if lower.contains("imported and not used") {
        return Some(("unused", "go:imported-not-used"));
    }
    if lower.contains("declared and not used") {
        return Some(("unused", "go:declared-not-used"));
    }
    None
}

/// An identity for a message §7.1 does not name, made out of its shape.
///
/// Everything variable goes first — quoted text, parenthesised asides, the
/// player's identifiers after a colon, numbers — and what is left is the
/// sentence Go would have printed for anybody. "missing return" stays
/// `go:missing-return`; the identifier in "undefined: tolal" never reaches it.
pub fn go_identity(message: &str) -> String {
    let mut cleaned = String::with_capacity(message.len());
    let mut depth = 0usize;
    let mut quoted = false;
    for ch in message.chars() {
        match ch {
            '(' | '[' => depth += 1,
            ')' | ']' if depth > 0 => depth -= 1,
            '"' | '`' | '\'' => quoted = !quoted,
            _ if depth == 0 && !quoted => cleaned.push(ch),
            _ => {}
        }
    }
    // Anything after a colon is the thing the message is *about*.
    let head = cleaned.split(':').next().unwrap_or("");
    let mut slug: Vec<String> = Vec::new();
    for word in head.split(|c: char| !c.is_ascii_alphanumeric()) {
        if word.is_empty() {
            continue;
        }
        // Stop at the first word that looks like something the player named
        // rather than something Go always says: a single letter, or anything
        // with a capital in it. Better a coarse identity two mistakes share
        // than a fine one that splits a mistake into one row per variable.
        if word.len() == 1 || word.chars().any(|c| c.is_ascii_uppercase()) {
            break;
        }
        slug.push(word.to_ascii_lowercase());
        if slug.len() == 4 {
            break;
        }
    }
    if slug.is_empty() {
        "go:other".to_string()
    } else {
        format!("go:{}", slug.join("-"))
    }
}

/// Classify the output of `go build`.
pub fn classify_go_build(stderr: &str) -> Vec<Mistake> {
    let mut out = Vec::new();
    for line in stderr.lines() {
        // `# command-line-arguments` is the package header, and an indented
        // line is the previous error's detail ("have …" / "want …").
        if line.starts_with('#') || line.starts_with('\t') || line.starts_with("    ") {
            continue;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed == "too many errors" {
            continue;
        }
        let (line_no, col_no, message) = split_go_location(trimmed);
        if message.is_empty() {
            continue;
        }
        let (kind, code) = match go_kind(message) {
            Some((kind, code)) => (kind.to_string(), code.to_string()),
            // Never dropped: an unrecognized message keeps whatever identity
            // can be made of it, so the taxonomy grows out of real data.
            None => ("other".to_string(), go_identity(message)),
        };
        out.push(Mistake {
            kind,
            code: Some(code),
            message: normalize_message(message),
            line: line_no,
            col: col_no,
        });
    }
    out
}

/// `./main.go:7:14: message` → `(7, 14, "message")`. Tolerant of the
/// `file:line: message` form and of anything that is neither.
fn split_go_location(line: &str) -> (Option<i64>, Option<i64>, &str) {
    let parts: Vec<&str> = line.splitn(4, ':').collect();
    let numeric = |s: &str| s.trim().parse::<i64>().ok();
    match parts.as_slice() {
        [_file, line_no, col_no, rest] => match (numeric(line_no), numeric(col_no)) {
            (Some(l), Some(c)) => (Some(l), Some(c), rest.trim()),
            // `undefined: tolal` has a colon of its own; if the second field
            // is not a number this was never a location.
            _ => match numeric(line_no) {
                Some(l) => (
                    Some(l),
                    None,
                    line[line.find(':').map(|i| i + 1).unwrap_or(0)..].trim(),
                ),
                None => (None, None, line),
            },
        },
        [_file, line_no, rest] => match numeric(line_no) {
            Some(l) => (Some(l), None, rest.trim()),
            None => (None, None, line),
        },
        _ => (None, None, line),
    }
}

/// Go's runtime failures. These are the §7.1 rows with no compiler code at
/// all: the program built, ran, and died saying what it died of.
pub fn classify_go_runtime(stderr: &str) -> Vec<Mistake> {
    const PATTERNS: &[(&str, &str, &str)] = &[
        (
            "invalid memory address or nil pointer dereference",
            "nil-deref",
            "go:nil-deref",
        ),
        ("index out of range", "index-range", "go:index-out-of-range"),
        ("all goroutines are asleep", "deadlock", "go:deadlock"),
        ("WARNING: DATA RACE", "data-race", "go:data-race"),
    ];
    let mut out = Vec::new();
    for (needle, kind, code) in PATTERNS {
        let needle_lower = needle.to_ascii_lowercase();
        let hit = stderr
            .lines()
            .find(|l| l.to_ascii_lowercase().contains(&needle_lower));
        if let Some(hit) = hit {
            out.push(Mistake {
                kind: (*kind).to_string(),
                code: Some((*code).to_string()),
                message: normalize_message(hit),
                line: go_panic_line(stderr),
                col: None,
            });
        }
    }
    out
}

/// The first `main.go:N` in a panic trace — the line the player wrote, rather
/// than the one inside the runtime.
fn go_panic_line(stderr: &str) -> Option<i64> {
    for line in stderr.lines() {
        if let Some(rest) = line.split("main.go:").nth(1) {
            let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if let Ok(n) = digits.parse::<i64>() {
                return Some(n);
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// C++ (SPEC §7.1's third column)
//
// clang and gcc agree on the frame of a diagnostic —
// `main.cpp:5:18: error: message` — and disagree on almost every word inside
// it: clang says "use of undeclared identifier 'x'", gcc says "'x' was not
// declared in this scope". The identity is therefore made from what the
// message is *about*, tested against both wordings, and the player's own
// names stay in `mistakes.message` where they belong.
// ---------------------------------------------------------------------------

/// The message after `error:` / `warning:` → the kind and the identity.
///
/// Ordered from the most specific phrase to the least. "cannot bind
/// non-const lvalue reference" is a constness lesson before it is a
/// conversion lesson, and "expected" appears inside plenty of type errors
/// ("expected 2 arguments"), so the syntax markers are checked last.
pub fn cpp_kind(message: &str, level: &str) -> (&'static str, &'static str) {
    const MOVED: [&str; 6] = [
        "use after move",
        "moved-from",
        "use of moved",
        "after being moved",
        "after it was moved",
        "after move",
    ];
    let lower = message.to_ascii_lowercase();
    let has = |needles: &[&str]| needles.iter().any(|n| lower.contains(n));

    if level == "warning" {
        if has(&["unused", "set but not used", "never used"]) {
            return ("unused", "cpp:unused");
        }
        if has(&MOVED) {
            return ("borrow-after-move", "cpp:use-after-move");
        }
        return ("other", "cpp:other");
    }
    if has(&MOVED) {
        return ("borrow-after-move", "cpp:use-after-move");
    }
    if has(&[
        "const-qualified",
        "read-only",
        "discards qualifiers",
        "drops 'const'",
        "drops const",
        "cannot bind non-const",
        "as 'this' argument",
        "assignment of member",
        "increment of read-only",
        "is not assignable",
    ]) {
        return ("mutability", "cpp:const-discard");
    }
    if has(&[
        "undeclared identifier",
        "was not declared",
        "has not been declared",
        "unknown type name",
        "does not name a type",
        "is not a member of",
        "has no member named",
        "no member named",
        "no template named",
        "is not a class, namespace, or enumeration",
        "file not found",
        "no such file or directory",
    ]) {
        return ("unknown-name", "cpp:undeclared-identifier");
    }
    if has(&[
        "no matching function",
        "no matching constructor",
        "no matching member function",
        "no viable overloaded",
        "no viable constructor",
        "too many arguments",
        "too few arguments",
        "requires 1 argument",
        "requires 2 arguments",
        "no match for",
    ]) {
        return ("type-mismatch", "cpp:no-matching-function");
    }
    if has(&[
        "cannot convert",
        "no viable conversion",
        "cannot initialize",
        "invalid conversion",
        "invalid operands",
        "incompatible",
        "no known conversion",
        "cannot be used to initialize",
        "does not match",
        "assigning to",
        "invalid argument type",
        "no member named 'value'",
        "narrowing",
        "binary expression",
        "requires the 'this' argument",
    ]) {
        return ("type-mismatch", "cpp:cannot-convert");
    }
    if has(&[
        "expected",
        "unterminated",
        "missing terminating",
        "stray",
        "unexpected",
        "extraneous",
        "before '",
        "unclosed",
        "unmatched",
    ]) {
        return ("syntax", "cpp:expected-token");
    }
    ("other", "cpp:other")
}

/// Classify the output of `c++`.
///
/// Only the diagnostic lines count. The source echo, the caret line, the
/// `note:` candidates the compiler lists after an overload failure, and the
/// `N errors generated.` trailer are all context for the player and nothing
/// for the table. A `note:` in particular must not become a mistake: one
/// wrong call to `push_back` produces two notes per overload, and "your top
/// mistake" would be the standard library's own signature.
pub fn classify_cpp_build(stderr: &str) -> Vec<Mistake> {
    let mut out = Vec::new();
    for line in stderr.lines() {
        let Some((line_no, col_no, level, message)) = split_cpp_diagnostic(line) else {
            continue;
        };
        if !matches!(level, "error" | "warning") {
            continue;
        }
        let (kind, code) = cpp_kind(message, level);
        out.push(Mistake {
            kind: kind.to_string(),
            code: Some(code.to_string()),
            message: normalize_message(message),
            line: line_no,
            col: col_no,
        });
    }
    // The linker has its own voice and no location: `undefined reference to
    // 'foo(int)'` (ld) or `Undefined symbols for architecture …` (ld64). A
    // function declared and never defined is the usual cause, and there is
    // no §7.1 row for it, so it is kept as `other` under one identity rather
    // than dropped.
    let lower = stderr.to_ascii_lowercase();
    if out.is_empty()
        && (lower.contains("undefined reference to") || lower.contains("undefined symbols for"))
    {
        let hit = stderr
            .lines()
            .find(|l| {
                let l = l.to_ascii_lowercase();
                l.contains("undefined reference to") || l.contains("undefined symbols for")
            })
            .unwrap_or("undefined symbol at link time");
        out.push(Mistake {
            kind: "other".into(),
            code: Some("cpp:undefined-symbol".into()),
            message: normalize_message(hit),
            line: None,
            col: None,
        });
    }
    out
}

/// `main.cpp:5:18: error: message` → `(5, 18, "error", "message")`. Only the
/// player's file counts: a diagnostic inside `<vector>` is a consequence of
/// something in `main.cpp`, and the compiler reports that one too.
fn split_cpp_diagnostic(line: &str) -> Option<(Option<i64>, Option<i64>, &str, &str)> {
    let rest = line.strip_prefix("main.cpp:")?;
    // gcc: `main.cpp:5:18: error: …`; clang the same; both sometimes drop the
    // column (`main.cpp:5: error:`), and a driver-level complaint has no
    // location at all — that one is not a mistake in the player's code.
    let mut parts = rest.splitn(3, ':');
    let line_no = parts.next()?.trim().parse::<i64>().ok()?;
    let second = parts.next()?;
    let (col_no, tail) = match second.trim().parse::<i64>() {
        Ok(c) => (Some(c), parts.next()?),
        Err(_) => {
            // `second` was the level; reassemble what follows it.
            let third = parts.next().unwrap_or("");
            return level_and_message(second, third).map(|(l, m)| (Some(line_no), None, l, m));
        }
    };
    let (level, message) = tail.split_once(':')?;
    level_and_message(level, message).map(|(l, m)| (Some(line_no), col_no, l, m))
}

fn level_and_message<'a>(level: &'a str, message: &'a str) -> Option<(&'a str, &'a str)> {
    let level = match level.trim() {
        "error" | "fatal error" => "error",
        "warning" => "warning",
        "note" => "note",
        _ => return None,
    };
    Some((level, message.trim()))
}

/// C++'s runtime failures. A program that dereferenced nothing does not say
/// so: the harness writes the signal it died of into the stderr the player
/// sees (`killed by signal 11 (SIGSEGV: segmentation fault)`), and QA's
/// captures record the same fact as `<signal 11>`; the number is what both
/// have in common, so the number is what is matched. An uncaught exception is
/// announced by the runtime (`libc++abi: terminating due to uncaught
/// exception of type std::out_of_range` on macOS, `terminate called after
/// throwing an instance of 'std::out_of_range'` with libstdc++) before the
/// abort.
pub fn classify_cpp_runtime(stderr: &str) -> Vec<Mistake> {
    let mut out = Vec::new();
    let lower = stderr.to_ascii_lowercase();
    let first_line_with = |needle: &str| {
        stderr
            .lines()
            .find(|l| l.to_ascii_lowercase().contains(needle))
            .map(normalize_message)
    };
    let push = |out: &mut Vec<Mistake>, kind: &str, code: &str, message: String| {
        out.push(Mistake {
            kind: kind.into(),
            code: Some(code.into()),
            message,
            line: None,
            col: None,
        });
    };

    // `signal N` with a word boundary after the number, so signal 1 does
    // not match signal 11.
    let signalled = |n: u32| {
        let needle = format!("signal {n}");
        lower
            .match_indices(&needle)
            .any(|(at, _)| !lower[at + needle.len()..].starts_with(|c: char| c.is_ascii_digit()))
    };
    // SIGSEGV is 11 everywhere; SIGBUS is 10 on darwin and 7 on linux.
    if lower.contains("sigsegv")
        || lower.contains("segmentation fault")
        || lower.contains("sigbus")
        || signalled(11)
        || signalled(10)
        || signalled(7)
    {
        let message = first_line_with("sig")
            .or_else(|| first_line_with("segmentation"))
            .unwrap_or_else(|| "segmentation fault".into());
        push(&mut out, "nil-deref", "cpp:segfault", message);
    }
    let uncaught = lower.contains("uncaught exception") || lower.contains("terminate called");
    if uncaught && lower.contains("out_of_range") {
        let message = first_line_with("out_of_range").unwrap_or_else(|| "std::out_of_range".into());
        push(&mut out, "index-range", "cpp:out-of-range", message);
    } else if uncaught || lower.contains("sigabrt") || lower.contains("assertion") || signalled(6) {
        let message = first_line_with("exception")
            .or_else(|| first_line_with("terminate"))
            .or_else(|| first_line_with("assert"))
            .or_else(|| first_line_with("sig"))
            .unwrap_or_else(|| "abort".into());
        push(&mut out, "unhandled-error", "cpp:abort", message);
    }
    if lower.contains("sigfpe") || signalled(8) {
        let message = first_line_with("sig").unwrap_or_else(|| "arithmetic exception".into());
        push(&mut out, "unhandled-error", "cpp:fpe", message);
    }
    out
}

// ---------------------------------------------------------------------------
// Python (SPEC §7.1's fourth column)
//
// Python has no compiler and one voice: a traceback ending in the line that
// names the exception, `NameError: name 'tolal' is not defined`. The
// exception class is the identity — it is the closest thing the language has
// to an error code — and the rest of the line is the message.
// ---------------------------------------------------------------------------

/// The exception class and its message → the kind and the identity.
pub fn python_kind(class: &str, message: &str) -> Option<(&'static str, &'static str)> {
    Some(match class {
        "NameError" | "UnboundLocalError" => ("unknown-name", "py:name-error"),
        "TypeError" => ("type-mismatch", "py:type-error"),
        "AttributeError" if message.contains("'NoneType'") => ("nil-deref", "py:none-attribute"),
        "AttributeError" => ("missing-trait", "py:attribute-error"),
        "IndexError" => ("index-range", "py:index-error"),
        "KeyError" => ("index-range", "py:key-error"),
        "ZeroDivisionError" => ("unhandled-error", "py:zero-division"),
        "ValueError" => ("unhandled-error", "py:value-error"),
        // Depth 1000 is a wrong algorithm, not a crash: the recursion that
        // blew the stack would have been a loop.
        "RecursionError" => ("wrong-answer", "py:recursion"),
        "SyntaxError" | "IndentationError" | "TabError" => ("syntax", "py:syntax"),
        _ => return None,
    })
}

/// Classify the output of `python3 -m py_compile`: the one thing it can
/// find is a `SyntaxError` (or its `IndentationError` subclass), and it
/// prints it either as a short traceback or, for indentation, as
/// `Sorry: IndentationError: … (main.py, line 2)`.
pub fn classify_python_compile(stderr: &str) -> Vec<Mistake> {
    let Some((class, message)) = last_python_exception(stderr) else {
        return Vec::new();
    };
    let (kind, code) = python_kind(class, message).unwrap_or(("syntax", "py:syntax"));
    let line = python_line(stderr).or_else(|| sorry_line(message));
    vec![Mistake {
        kind: kind.into(),
        code: Some(code.into()),
        message: normalize_message(&format!("{class}: {message}")),
        line,
        col: None,
    }]
}

/// Python's runtime failures: the traceback's last line names the exception,
/// and the last `main.py` frame above it is where the player's code was.
pub fn classify_python_runtime(stderr: &str) -> Vec<Mistake> {
    let Some((class, message)) = last_python_exception(stderr) else {
        return Vec::new();
    };
    // Anything else that escaped `main` — `RuntimeError`, an
    // `AssertionError`, a class the player wrote — is an error nobody
    // handled, and the class name is kept in the message.
    let (kind, code) = python_kind(class, message).unwrap_or(("unhandled-error", "py:exception"));
    vec![Mistake {
        kind: kind.into(),
        code: Some(code.into()),
        message: normalize_message(&format!("{class}: {message}")),
        line: python_line(stderr),
        col: None,
    }]
}

/// The last `XxxError: message` line of a traceback → `(class, message)`.
/// A chained traceback ("During handling of the above exception…") ends with
/// the one that actually escaped, which is the one the player has to fix.
fn last_python_exception(stderr: &str) -> Option<(&str, &str)> {
    stderr.lines().rev().find_map(|line| {
        let line = line.trim();
        let line = line.strip_prefix("Sorry: ").unwrap_or(line);
        let (class, message) = line.split_once(':')?;
        let class = class.trim();
        // `a.b.SomeError` for an exception from a module; the last segment
        // is the class.
        let class = class.rsplit('.').next().unwrap_or(class);
        let is_class = !class.is_empty()
            && class.chars().next().is_some_and(|c| c.is_ascii_uppercase())
            && class.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            && (class.ends_with("Error")
                || class.ends_with("Exception")
                || class.ends_with("Exit")
                || class.ends_with("Interrupt")
                || class.ends_with("Warning")
                || class == "StopIteration");
        is_class.then(|| (class, message.trim()))
    })
}

/// The deepest `main.py` frame: `File "…/main.py", line 3, in g`. The last
/// one in the traceback is the innermost, which is where it went wrong.
fn python_line(stderr: &str) -> Option<i64> {
    stderr.lines().rev().find_map(|line| {
        let rest = line.split("main.py\", line ").nth(1)?;
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        digits.parse::<i64>().ok()
    })
}

/// `… (main.py, line 2)` at the end of a `Sorry:` line.
fn sorry_line(message: &str) -> Option<i64> {
    let rest = message.rsplit("line ").next()?;
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse::<i64>().ok()
}

// ---------------------------------------------------------------------------
// TypeScript (SPEC §7.1's fifth column)
//
// Two voices, one per half of the land. `tsc` has real error codes, as
// `rustc` does, and they are kept as the identity: `TS2322` is the same
// mistake in every version and every locale, where its prose is neither.
// With `pretty: false` every diagnostic is one line,
// `main.ts(3,5): error TS2322: Type 'string' is not assignable to …`, and
// the indented lines under it elaborate the one above.
//
// Then the types are erased and `node` runs what is left, and its voice is
// an exception class — `TypeError: Cannot read properties of undefined` —
// with the source-mapped `main.ts:12` above it. Those get `ts:` slugs, the
// way Python's classes get `py:` ones.
// ---------------------------------------------------------------------------

/// A `tsc` error code → the kind. `None` is "not in the table": the code is
/// kept and the row is `other`, as for rustc.
pub fn typescript_kind(code: &str) -> Option<&'static str> {
    let number: u32 = code.strip_prefix("TS")?.parse().ok()?;
    Some(match number {
        // Every 1xxx is the parser's: nothing was typed yet, the text did
        // not parse.
        1000..=1999 => "syntax",
        // Cannot find name / did you mean / cannot find module / a lib
        // global that is not in this land's `lib` (TS2583, TS2584).
        2304 | 2552 | 2305 | 2307 | 2583 | 2584 | 2503 | 2448 => "unknown-name",
        // "Object is possibly 'undefined'" in its six wordings, and a
        // variable read before it was ever assigned: the erased `undefined`
        // the checker caught before it reached the screen.
        2531 | 2532 | 2533 | 2454 | 2722 | 18047 | 18048 | 18049 => "nil-deref",
        // "Property 'x' does not exist on type" — Python's AttributeError,
        // found before the run instead of during it.
        2339 | 2551 => "missing-trait",
        // `const`, `readonly`, and a readonly index signature.
        2588 | 2540 | 2542 => "mutability",
        // Declared but never read; reported only where the options ask.
        6133 | 6138 | 6192 | 6196 | 6198 => "unused",
        // Assignability in all its forms, arity, operands, implicit `any`,
        // a missing return, a call on something that is not callable.
        2322 | 2345 | 2352 | 2355 | 2362 | 2363 | 2365 | 2366 | 2367 | 2349 | 2554 | 2555
        | 2556 | 2739 | 2740 | 2741 | 2769 | 2677 | 2678 | 2820 | 7005 | 7006 | 7008 | 7010
        | 7015 | 7018 | 7019 | 7031 | 7034 | 7053 => "type-mismatch",
        _ => return None,
    })
}

/// Classify `tsc -p .` output (`pretty: false`): one mistake per `error`
/// line, in the order the checker reported them.
pub fn classify_typescript_compile(stderr: &str) -> Vec<Mistake> {
    let mut out = Vec::new();
    for line in stderr.lines() {
        // Continuation lines are indented; a diagnostic is not.
        if line.starts_with(char::is_whitespace) {
            continue;
        }
        let Some((location, rest)) = line.split_once(": error ") else {
            continue;
        };
        let Some((code, message)) = rest.split_once(": ") else {
            continue;
        };
        let (line_no, col) = typescript_location(location);
        let kind = typescript_kind(code).unwrap_or("other");
        out.push(Mistake {
            kind: kind.into(),
            code: Some(code.to_string()),
            message: normalize_message(message),
            line: line_no,
            col,
        });
    }
    out
}

/// `main.ts(3,5)` → `(Some(3), Some(5))`. A diagnostic with no file — a bad
/// tsconfig, which is the runner's fault — has neither.
fn typescript_location(location: &str) -> (Option<i64>, Option<i64>) {
    let Some(inner) = location
        .rsplit_once('(')
        .and_then(|(_, rest)| rest.strip_suffix(')'))
    else {
        return (None, None);
    };
    let mut parts = inner.split(',').map(|n| n.trim().parse::<i64>().ok());
    (parts.next().flatten(), parts.next().flatten())
}

/// An uncaught exception's class and message → the kind and the identity.
pub fn typescript_runtime_kind(class: &str, message: &str) -> (&'static str, &'static str) {
    match class {
        // The boss of `typescript.basic`: the type said it was there, and
        // at runtime it was `undefined`.
        "TypeError"
            if message.starts_with("Cannot read properties of")
                || message.starts_with("Cannot set properties of") =>
        {
            ("nil-deref", "ts:undefined-property")
        }
        "TypeError" if message.contains("is not a function") || message.contains("is not iterable") => {
            ("missing-trait", "ts:not-a-function")
        }
        "TypeError" => ("type-mismatch", "ts:type-error"),
        "ReferenceError" => ("unknown-name", "ts:reference-error"),
        // As with Python's depth limit: the recursion that blew the stack
        // would have been a loop.
        "RangeError" if message.contains("Maximum call stack") => ("wrong-answer", "ts:recursion"),
        "RangeError" => ("index-range", "ts:range-error"),
        // At runtime a SyntaxError is `JSON.parse` refusing its input — the
        // feed was not what the type promised, and nothing caught it.
        "SyntaxError" => ("unhandled-error", "ts:json-parse"),
        _ => ("unhandled-error", "ts:exception"),
    }
}

/// Classify what `node --enable-source-maps main.js` left on stderr.
pub fn classify_typescript_runtime(stderr: &str) -> Vec<Mistake> {
    let line = typescript_runtime_line(stderr);
    // A heap that ran out is an algorithm that kept too much — the same
    // lesson as a timeout, reached through memory rather than the clock.
    if stderr.contains("JavaScript heap out of memory") || stderr.contains("Reached heap limit") {
        return vec![Mistake {
            kind: "timeout".into(),
            code: Some("ts:heap-limit".into()),
            message: "JavaScript heap out of memory".into(),
            line,
            col: None,
        }];
    }
    if let Some((class, message)) = first_js_exception(stderr) {
        let (kind, code) = typescript_runtime_kind(class, message);
        return vec![Mistake {
            kind: kind.into(),
            code: Some(code.into()),
            message: normalize_message(&format!("{class}: {message}")),
            line,
            col: None,
        }];
    }
    // `throw "offline"` — something that is not an Error. Node prints the
    // source line, a caret under it, and then the value itself.
    let mut lines = stderr.lines();
    if lines.by_ref().any(|l| l.trim_start().starts_with('^')) {
        if let Some(value) = lines.map(str::trim).find(|l| !l.is_empty()) {
            return vec![Mistake {
                kind: "unhandled-error".into(),
                code: Some("ts:throw".into()),
                message: normalize_message(value),
                line,
                col: None,
            }];
        }
    }
    Vec::new()
}

/// The first `SomethingError: message` line. Node prints the exception once,
/// above its stack, and ends with a `Node.js v…` line that is not one — so
/// the first, not the last as for a Python traceback.
fn first_js_exception(stderr: &str) -> Option<(&str, &str)> {
    stderr.lines().find_map(|line| {
        if line.starts_with(char::is_whitespace) {
            return None;
        }
        let (head, message) = match line.split_once(": ") {
            Some(pair) => pair,
            None => (line, ""),
        };
        // `Error [ERR_X]: …` carries a code after the class.
        let class = head.split(' ').next().unwrap_or(head);
        let is_class = class.chars().next().is_some_and(|c| c.is_ascii_uppercase())
            && class.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            && class.ends_with("Error");
        is_class.then(|| (class, message.trim()))
    })
}

/// The first `main.ts:N` in the output: the source-mapped header above the
/// caret, or failing that the innermost stack frame. Either way it is where
/// the player's code was when it stopped.
fn typescript_runtime_line(stderr: &str) -> Option<i64> {
    stderr.lines().find_map(|line| {
        let (_, rest) = line.split_once("main.ts:")?;
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        digits.parse::<i64>().ok()
    })
}

/// Compile diagnostics, whichever land they came from. Every land has an
/// explicit arm: a new one falling through to the rustc JSON classifier
/// would silently find nothing in it and the table would learn nothing.
pub fn classify_compile(lang: &str, stderr: &str) -> Vec<Mistake> {
    match lang {
        "go" => classify_go_build(stderr),
        "cpp" => classify_cpp_build(stderr),
        // PyTorch Land runs the same interpreter, so a `SyntaxError` there is
        // the same `py:syntax` it is in Python Land.
        "python" | "pytorch" => classify_python_compile(stderr),
        "typescript" => classify_typescript_compile(stderr),
        _ => classify_rust_json(stderr),
    }
}

/// Runtime output, whichever land it came from. Rust says "index out of
/// bounds", Go says "index out of range", Python says `IndexError` and C++
/// says nothing and dies of a signal; one dispatcher beats one pattern list
/// that half-matches all four.
pub fn classify_runtime(lang: &str, stderr: &str) -> Vec<Mistake> {
    match lang {
        "go" => classify_go_runtime(stderr),
        "cpp" => classify_cpp_runtime(stderr),
        "python" | "pytorch" => classify_python_runtime(stderr),
        "typescript" => classify_typescript_runtime(stderr),
        _ => classify_rust_runtime(stderr),
    }
}

pub fn verdict_mistake(verdict: &str, detail: &str) -> Option<Mistake> {
    let kind = match verdict {
        "wrong_answer" => "wrong-answer",
        "timeout" => "timeout",
        _ => return None,
    };
    Some(Mistake {
        kind: kind.into(),
        code: None,
        message: normalize_message(detail),
        line: None,
        col: None,
    })
}

/// Insert the rows, then run the §7.2 rollup.
///
/// This runs on **every** attempt — accepted ones, and runs as well as submits
/// (PROTOCOL §4.9b). A borrow-checker error is the same lesson whichever
/// button produced it, and the mistakes made while iterating are the truest
/// record of what a player is actually struggling with.
pub fn record(
    conn: &Connection,
    attempt_id: &str,
    address: &str,
    quest_id: &str,
    mistakes: &[Mistake],
    mode: crate::attempts::Mode,
) -> Result<()> {
    let now = now_stamp();
    for mistake in mistakes {
        conn.execute(
            "INSERT INTO mistakes (attempt_id, address, quest_id, kind, code, message, line, col, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
            params![
                attempt_id,
                address,
                quest_id,
                mistake.kind,
                mistake.code,
                mistake.message,
                mistake.line,
                mistake.col,
                now
            ],
        )?;
    }
    rollup(conn, address, mistakes, &now, mode)
}

fn rollup(
    conn: &Connection,
    address: &str,
    mistakes: &[Mistake],
    now: &str,
    mode: crate::attempts::Mode,
) -> Result<()> {
    let kinds: BTreeSet<&str> = mistakes.iter().map(|m| m.kind.as_str()).collect();
    for kind in &kinds {
        conn.execute(
            "INSERT INTO mistake_stats (address, kind, count, last_at, cleared_since)
             VALUES (?1, ?2, 1, ?3, 0)
             ON CONFLICT(address, kind) DO UPDATE SET
               count = count + 1, last_at = ?3, cleared_since = 0",
            params![address, kind, now],
        )?;
    }
    // Deliberately asymmetric between the two modes (PROTOCOL §4.9b).
    //
    // Evidence that you *still* make a mistake counts whoever produced it, so
    // the block above runs for a run as well as a submit: the count moves and
    // `cleared_since` goes back to zero. Evidence that you have *stopped*
    // making it should cost something, and pressing RUN five times in a minute
    // is not evidence. §7.3 retires a kind at `cleared_since >= 5`, a
    // threshold written when the only attempt was a submit; letting runs
    // advance it would make "learned" mean "compiled five times", and the
    // weakness drill would quietly stop teaching the thing the player is worst
    // at.
    //
    // So only a submit advances it. The ranking still sees every run, because
    // `count` does.
    if !mode.is_submit() {
        return Ok(());
    }

    // SPEC §7.2, to the letter: "for every kind *not* in this attempt that the
    // user has a row for, increment cleared_since". Read as "you have not made
    // this particular mistake in N attempts", which is the question §7.3's
    // `cleared_since >= 5` asks. The alternative reading — only an attempt
    // with no mistakes at all counts as clean — would make a player who fails
    // in a new way every time never age anything out.
    let placeholders = if kinds.is_empty() {
        String::new()
    } else {
        format!(
            " AND kind NOT IN ({})",
            kinds
                .iter()
                .map(|k| format!("'{}'", k.replace('\'', "''")))
                .collect::<Vec<_>>()
                .join(",")
        )
    };
    conn.execute(
        &format!(
            "UPDATE mistake_stats SET cleared_since = cleared_since + 1
              WHERE address = ?1{placeholders}"
        ),
        params![address],
    )?;
    Ok(())
}

/// The §7.1 kind → concepts join, taken verbatim from `docs/concepts.md`.
///
/// This is the table SPEC §7.3's `weakness` plan runs: take the user's top
/// kind, look it up here, pull every quest whose `concepts` overlap the row.
/// Order within a row is priority — the first concept is the one that most
/// directly teaches the mistake. **Do not invent slugs here**: a slug outside
/// `docs/concepts.md`'s vocabulary reaches no quest, and a drill that reaches
/// nothing reads to the player as the AI mode being broken.
///
/// `other` deliberately has no row. An unrecognized compiler code carries no
/// information about *which* idea is missing, so the drill falls back to the
/// concepts of the quest the mistake happened on.
pub fn concepts_for(kind: &str) -> &'static [&'static str] {
    match kind {
        "borrow-after-move" => &[
            "ownership",
            "borrowing",
            "closures",
            "smart-pointers",
            "move-semantics",
            "raii",
        ],
        "borrow-conflict" => &["borrowing", "mutability", "shared-state"],
        "lifetime" => &[
            "lifetimes",
            "borrowing",
            "structs",
            "traits",
            "raii",
            "pointers",
        ],
        "type-mismatch" => &[
            "types",
            "generics",
            "error-handling",
            "pattern-matching",
            "duck-typing",
            // A shape that does not line up is this land's type error, and it
            // is the one a PyTorch player makes most.
            "tensors",
            "broadcasting",
        ],
        "unknown-name" => &["bindings", "imports", "functions", "decorators", "modules"],
        "missing-trait" => &["traits", "generics", "iteration", "duck-typing"],
        "unused" => &["bindings", "imports"],
        "mutability" => &["mutability", "borrowing", "slices"],
        "nil-deref" => &[
            "error-handling",
            "interfaces",
            "structs",
            "pointers",
            "undefined-behaviour",
            // `.grad` is None until a backward pass has run, which reaches the
            // player as exactly this.
            "autograd",
        ],
        "index-range" => &[
            "slices",
            "iteration",
            "two-pointers",
            "undefined-behaviour",
            // A token id past the end of the table.
            "embeddings",
        ],
        "data-race" => &["data-races", "shared-state", "concurrency"],
        "deadlock" => &["deadlock", "channels", "shared-state"],
        "unhandled-error" => &["error-handling", "pattern-matching", "optimizers"],
        "syntax" => &["bindings", "control-flow", "functions"],
        "wrong-answer" => &[
            "complexity",
            "iteration",
            "strings",
            "io",
            "comprehensions",
            "generators",
            "training-loop",
            "loss-functions",
            "inference",
            "attention",
            "initialization",
        ],
        "timeout" => &[
            "complexity",
            "hashing",
            "binary-search",
            "two-pointers",
            "generators",
            "datasets",
        ],
        _ => &[],
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct MistakeStat {
    pub kind: String,
    pub label: String,
    pub count: i64,
    pub last_at: String,
    pub cleared_since: i64,
    pub example_quest_id: Option<String>,
    pub concepts: Vec<String>,
}

/// PROTOCOL §4.14: most frequent first, and a kind with `cleared_since >= 5`
/// is considered learned and is left out unless it is asked for.
pub fn stats(
    conn: &Connection,
    address: &str,
    limit: i64,
    include_learned: bool,
) -> Result<Vec<MistakeStat>> {
    let learned_filter = if include_learned {
        ""
    } else {
        " AND s.cleared_since < 5"
    };
    let mut stmt = conn.prepare(&format!(
        "SELECT s.kind, s.count, s.last_at, s.cleared_since,
                (SELECT m.quest_id FROM mistakes m
                  WHERE m.address = s.address AND m.kind = s.kind
                  ORDER BY m.created_at DESC LIMIT 1)
           FROM mistake_stats s
          WHERE s.address = ?1{learned_filter}
          ORDER BY s.count DESC, s.last_at DESC
          LIMIT ?2"
    ))?;
    let rows = stmt.query_map(params![address, limit], |r| {
        let kind: String = r.get(0)?;
        Ok(MistakeStat {
            label: label(&kind).to_string(),
            concepts: concepts_for(&kind).iter().map(|c| c.to_string()).collect(),
            kind,
            count: r.get(1)?,
            last_at: r.get(2)?,
            cleared_since: r.get(3)?,
            example_quest_id: r.get(4)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// `--error-format=json` gives the frontend nothing a human can read, but each
/// diagnostic carries a `rendered` field holding exactly the text `rustc`
/// would have printed. Stitch those back together so the result screen shows
/// the compiler's own words rather than a wall of JSON.
pub fn rendered_from_json(stderr: &str) -> String {
    let mut out = String::new();
    for line in stderr.lines() {
        let line = line.trim();
        if !line.starts_with('{') {
            // A line rustc wrote outside the JSON stream (a linker error, an
            // ICE note) is still something the player should see.
            if !line.is_empty() {
                out.push_str(line);
                out.push('\n');
            }
            continue;
        }
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(line) {
            if let Some(rendered) = value.get("rendered").and_then(|v| v.as_str()) {
                out.push_str(rendered);
                if !rendered.ends_with('\n') {
                    out.push('\n');
                }
            }
        }
    }
    out
}
