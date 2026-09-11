//! SPEC §7: the taxonomy, and the rule that an unrecognized code is kept.

use cwbhacker_core::mistakes::{self, Mistake};

fn diagnostic(level: &str, code: Option<&str>, message: &str) -> String {
    let code = match code {
        Some(code) => format!(r#"{{"code":"{code}","explanation":null}}"#),
        None => "null".to_string(),
    };
    format!(
        r#"{{"$message_type":"diagnostic","message":"{message}","code":{code},"level":"{level}","spans":[{{"file_name":"main.rs","line_start":4,"column_start":9,"is_primary":true}}],"children":[],"rendered":"{level}: {message}\n"}}"#
    )
}

fn kinds(stderr: &str) -> Vec<String> {
    mistakes::classify_rust_json(stderr)
        .into_iter()
        .map(|m| m.kind)
        .collect()
}

#[test]
fn every_rust_row_of_the_table_maps() {
    for (code, expected) in [
        ("E0382", "borrow-after-move"),
        ("E0505", "borrow-after-move"),
        ("E0499", "borrow-conflict"),
        ("E0502", "borrow-conflict"),
        ("E0106", "lifetime"),
        ("E0597", "lifetime"),
        ("E0621", "lifetime"),
        ("E0308", "type-mismatch"),
        ("E0425", "unknown-name"),
        ("E0433", "unknown-name"),
        ("E0277", "missing-trait"),
        ("E0596", "mutability"),
        ("E0594", "mutability"),
    ] {
        assert_eq!(
            mistakes::rust_kind(code),
            Some(expected),
            "{code} should be {expected}"
        );
    }
}

#[test]
fn a_code_nobody_recognizes_is_kept_as_other() {
    let stderr = diagnostic("error", Some("E9999"), "a diagnostic from the future");
    let found = mistakes::classify_rust_json(&stderr);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].kind, "other");
    assert_eq!(
        found[0].code.as_deref(),
        Some("E9999"),
        "the code must never be dropped (SPEC §7.1)"
    );
    assert_eq!(found[0].line, Some(4));
    assert_eq!(found[0].col, Some(9));
}

#[test]
fn unused_arrives_as_a_warning_and_is_still_a_mistake() {
    let stderr = diagnostic("warning", Some("unused_variables"), "unused variable: `x`");
    assert_eq!(kinds(&stderr), vec!["unused".to_string()]);
}

#[test]
fn other_warnings_are_not_mistakes() {
    let stderr = diagnostic("warning", Some("dead_code"), "function is never used");
    assert_eq!(kinds(&stderr), Vec::<String>::new());
}

#[test]
fn a_parse_error_with_no_code_is_syntax() {
    let stderr = diagnostic("error", None, "expected one of `;` or `}`, found `let`");
    assert_eq!(kinds(&stderr), vec!["syntax".to_string()]);
}

#[test]
fn the_summary_lines_are_not_mistakes() {
    let stderr = [
        diagnostic("error", Some("E0308"), "mismatched types"),
        diagnostic("error", None, "aborting due to 1 previous error"),
        diagnostic(
            "error",
            None,
            "For more information about this error, try `rustc --explain E0308`.",
        ),
    ]
    .join("\n");
    assert_eq!(kinds(&stderr), vec!["type-mismatch".to_string()]);
}

#[test]
fn junk_between_the_json_lines_is_skipped_not_fatal() {
    let stderr = format!(
        "warning: something the toolchain printed\n{}\n{{\"$message_type\":\"artifact\",\"artifact\":\"x\"}}\nnot json at all\n",
        diagnostic("error", Some("E0382"), "borrow of moved value: `s`")
    );
    assert_eq!(kinds(&stderr), vec!["borrow-after-move".to_string()]);
}

#[test]
fn the_rendered_text_is_recovered_for_the_player() {
    let stderr = diagnostic("error", Some("E0308"), "mismatched types");
    let rendered = mistakes::rendered_from_json(&stderr);
    assert!(rendered.contains("error: mismatched types"));
    assert!(!rendered.contains("$message_type"), "still raw JSON");
}

#[test]
fn a_runtime_panic_is_classified() {
    let stderr = "thread 'main' panicked at main.rs:3:5:\nindex out of bounds: the len is 3 but the index is 7\n";
    let found = mistakes::classify_runtime(stderr);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].kind, "index-range");
}

/// SPEC §7.2: a kind seen in this attempt resets to zero; every other kind the
/// user has a row for gains one consecutive clean attempt.
#[test]
fn the_rollup_counts_clean_attempts() {
    let conn = cwbhacker_core::db::open_memory().unwrap();
    let address = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f";
    cwbhacker_core::users::upsert(&conn, address).unwrap();
    conn.execute(
        "INSERT INTO quests (id,pack,land,category,node,title,brief,difficulty,starter,solution,tests,checksum)
         VALUES ('rust.basic.01.hello','p','rust','basic',1,'t','b',1,'s','s','{}','c')",
        [],
    )
    .unwrap();

    let attempt = |n: &str, kinds: &[(&str, &str)]| {
        let mut record = cwbhacker_core::attempts::new_record(
            n.to_string(),
            address,
            "rust.basic.01.hello",
            "rust",
            "fn main(){}".into(),
        );
        record.verdict = if kinds.is_empty() {
            "accepted".into()
        } else {
            "compile_error".into()
        };
        cwbhacker_core::attempts::insert(&conn, &record).unwrap();
        let found: Vec<Mistake> = kinds
            .iter()
            .map(|(kind, code)| Mistake {
                kind: kind.to_string(),
                code: Some(code.to_string()),
                message: "m".into(),
                line: None,
                col: None,
            })
            .collect();
        mistakes::record(&conn, n, address, "rust.basic.01.hello", &found).unwrap();
    };

    attempt("att_1", &[("borrow-after-move", "E0382")]);
    attempt("att_2", &[("type-mismatch", "E0308")]);
    attempt("att_3", &[]);

    let stats = mistakes::stats(&conn, address, 10, true).unwrap();
    let borrow = stats
        .iter()
        .find(|s| s.kind == "borrow-after-move")
        .unwrap();
    let mismatch = stats.iter().find(|s| s.kind == "type-mismatch").unwrap();
    assert_eq!(borrow.count, 1);
    // §7.2 counts attempts in which the kind did not appear, not attempts
    // that were clean overall: att_2 made a different mistake and att_3 made
    // none, and neither of them was a borrow-after-move.
    assert_eq!(
        borrow.cleared_since, 2,
        "two attempts without a borrow mistake"
    );
    assert_eq!(mismatch.cleared_since, 1);
    assert_eq!(borrow.label, "use after move");
    assert_eq!(
        borrow.example_quest_id.as_deref(),
        Some("rust.basic.01.hello")
    );
}

// ---------------------------------------------------------------------------
// SPEC §9.7, against QA's captured fixtures in `tests/vectors/mistakes/`.
//
// These are not hand-written diagnostics: they are what `rustc 1.97.1` on this
// host actually printed for each source. A classifier that passes the
// hand-rolled tests above and fails these is a classifier built against what I
// assumed rustc emits.
// ---------------------------------------------------------------------------

fn vectors_dir() -> Option<std::path::PathBuf> {
    let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()?
        .parent()?
        .join("tests/vectors/mistakes");
    dir.is_dir().then_some(dir)
}

#[test]
fn the_captured_rustc_diagnostics_classify_as_qa_expects() {
    let Some(dir) = vectors_dir() else {
        eprintln!("no tests/vectors/mistakes yet — nothing to check");
        return;
    };
    let expected: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("expected.json")).unwrap())
            .expect("expected.json is JSON");

    let mut checked = 0;
    let mut missing = Vec::new();
    let groups = ["cases", "content_starter_cases"];
    for group in groups {
        for case in expected[group].as_array().into_iter().flatten() {
            if case["lang"].as_str() != Some("rust")
                || !case["assert_me"].as_bool().unwrap_or(false)
                || !case["compile_time"].as_bool().unwrap_or(false)
            {
                continue;
            }
            let Some(captured) = case["captured"].as_str() else {
                continue;
            };
            let path = dir.join(captured);
            let Ok(stderr) = std::fs::read_to_string(&path) else {
                missing.push(captured.to_string());
                continue;
            };
            let label = case["file"]
                .as_str()
                .or_else(|| case["quest_id"].as_str())
                .unwrap_or(captured);
            let want_kind = case["kind"].as_str().unwrap();
            let want_code = case["code"].as_str();

            let found = mistakes::classify_rust_json(&stderr);
            assert!(
                !found.is_empty(),
                "{label}: the classifier found nothing in real rustc output"
            );
            assert!(
                found.iter().any(|m| m.kind == want_kind),
                "{label}: expected kind '{want_kind}', got {:?}",
                found.iter().map(|m| (&m.kind, &m.code)).collect::<Vec<_>>()
            );
            if let Some(want_code) = want_code {
                assert!(
                    found
                        .iter()
                        .any(|m| m.kind == want_kind && m.code.as_deref() == Some(want_code)),
                    "{label}: the code '{want_code}' was not kept beside the kind"
                );
            }
            checked += 1;
        }
    }
    assert!(missing.is_empty(), "captures named but absent: {missing:?}");
    assert!(checked >= 10, "only {checked} rust cases were checked");
    println!("classified {checked} captured rustc outputs");
}

/// §7.1 as amended: `E0277` is two lessons. Sending a player who dropped an
/// error to go and read about traits is worse than not classifying it at all.
#[test]
fn e0277_is_split_between_missing_trait_and_unhandled_error() {
    let dropped_error = diagnostic(
        "error",
        Some("E0277"),
        "the `?` operator can only be used in a function that returns `Result` or `Option` (or another type that implements `FromResidual`)",
    );
    assert_eq!(kinds(&dropped_error), vec!["unhandled-error".to_string()]);

    let main_returns_result = diagnostic(
        "error",
        Some("E0277"),
        "`main` has invalid return type; the trait `Termination` is not implemented",
    );
    assert_eq!(
        kinds(&main_returns_result),
        vec!["unhandled-error".to_string()]
    );

    // The other wording rustc 1.97.1 uses for the same mistake, captured from
    // a real compile: a `?` whose error type does not convert. It shares no
    // words with the first one, which is why the discriminator is the `?`
    // itself rather than a sentence.
    let no_conversion = diagnostic(
        "error",
        Some("E0277"),
        "`?` couldn't convert the error to `MyError`",
    );
    assert_eq!(kinds(&no_conversion), vec!["unhandled-error".to_string()]);

    let no_display = diagnostic("error", Some("E0277"), "`Point` doesn't implement `Debug`");
    assert_eq!(kinds(&no_display), vec!["missing-trait".to_string()]);

    // Also real: `fn main() -> Result<(), MyError>` where `MyError` has no
    // `Debug`. It looks like an error-handling context and is not — the
    // lesson is to implement the trait.
    let main_needs_debug = diagnostic(
        "error",
        Some("E0277"),
        "`MyError` doesn't implement `Debug`",
    );
    assert_eq!(kinds(&main_needs_debug), vec!["missing-trait".to_string()]);

    let not_an_iterator = diagnostic("error", Some("E0277"), "`Point` is not an iterator");
    assert_eq!(kinds(&not_an_iterator), vec!["missing-trait".to_string()]);

    // Either way the code survives, because the code is the identity.
    let found = mistakes::classify_rust_json(&dropped_error);
    assert_eq!(found[0].code.as_deref(), Some("E0277"));
}

/// §7.1 as amended: E0373 is a value escaping, not a value moving. It is
/// `rust.advanced.02`'s own starter, so it meets players on their first
/// submit.
#[test]
fn e0373_is_a_lifetime_lesson() {
    assert_eq!(mistakes::rust_kind("E0373"), Some("lifetime"));
    let closure_outlives = diagnostic(
        "error",
        Some("E0373"),
        "closure may outlive the current function, but it borrows `name`, which is owned by the current function",
    );
    assert_eq!(kinds(&closure_outlives), vec!["lifetime".to_string()]);
}
