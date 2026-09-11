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
