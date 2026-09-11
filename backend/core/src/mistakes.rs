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

/// Compile diagnostics, whichever land they came from.
pub fn classify_compile(lang: &str, stderr: &str) -> Vec<Mistake> {
    match lang {
        "go" => classify_go_build(stderr),
        _ => classify_rust_json(stderr),
    }
}

/// Runtime output, whichever land it came from. Rust says "index out of
/// bounds" and Go says "index out of range"; one dispatcher beats one
/// pattern list that half-matches both.
pub fn classify_runtime(lang: &str, stderr: &str) -> Vec<Mistake> {
    match lang {
        "go" => classify_go_runtime(stderr),
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
/// This runs on **every** attempt, accepted ones included: `cleared_since` is
/// "consecutive clean attempts after", and an accepted attempt with no
/// mistakes is the cleanest one there is.
pub fn record(
    conn: &Connection,
    attempt_id: &str,
    address: &str,
    quest_id: &str,
    mistakes: &[Mistake],
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
    rollup(conn, address, mistakes, &now)
}

fn rollup(conn: &Connection, address: &str, mistakes: &[Mistake], now: &str) -> Result<()> {
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
    // SPEC §7.2, to the letter: "for every kind *not* in this attempt that the
    // user has a row for, increment cleared_since". Read as "you have not made
    // this particular mistake in N attempts", which is the question §7.3's
    // `cleared_since >= 5` asks. The alternative reading — only an attempt
    // with no mistakes at all counts as clean — would make a player who fails
    // in a new way every time never age anything out. If the AI plan wants
    // that stricter rule later, it is one `if mistakes.is_empty()` away.
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
        "borrow-after-move" => &["ownership", "borrowing", "closures", "smart-pointers"],
        "borrow-conflict" => &["borrowing", "mutability", "shared-state"],
        "lifetime" => &["lifetimes", "borrowing", "structs", "traits"],
        "type-mismatch" => &["types", "generics", "error-handling", "pattern-matching"],
        "unknown-name" => &["bindings", "imports", "functions"],
        "missing-trait" => &["traits", "generics", "iteration"],
        "unused" => &["bindings", "imports"],
        "mutability" => &["mutability", "borrowing", "slices"],
        "nil-deref" => &["error-handling", "interfaces", "structs"],
        "index-range" => &["slices", "iteration", "two-pointers"],
        "data-race" => &["data-races", "shared-state", "concurrency"],
        "deadlock" => &["deadlock", "channels", "shared-state"],
        "unhandled-error" => &["error-handling", "pattern-matching"],
        "syntax" => &["bindings", "control-flow", "functions"],
        "wrong-answer" => &["complexity", "iteration", "strings", "io"],
        "timeout" => &["complexity", "hashing", "binary-search", "two-pointers"],
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
