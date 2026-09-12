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
    let found = mistakes::classify_runtime("rust", stderr);
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
            cwbhacker_core::attempts::Mode::Submit,
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
        mistakes::record(
            &conn,
            n,
            address,
            "rust.basic.01.hello",
            &found,
            cwbhacker_core::attempts::Mode::Submit,
        )
        .unwrap();
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

/// `classify_compile` and `classify_runtime` have the same shape on purpose:
/// the fixture says which one a case wants, and the test picks it.
type Classifier = fn(&str, &str) -> Vec<mistakes::Mistake>;

fn vectors_dir() -> Option<std::path::PathBuf> {
    let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()?
        .parent()?
        .join("tests/vectors/mistakes");
    dir.is_dir().then_some(dir)
}

#[test]
fn the_captured_compiler_output_classifies_as_qa_expects() {
    let Some(dir) = vectors_dir() else {
        eprintln!("no tests/vectors/mistakes yet — nothing to check");
        return;
    };
    let expected: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("expected.json")).unwrap())
            .expect("expected.json is JSON");

    let mut checked = (0, 0);
    let mut missing = Vec::new();
    for group in ["cases", "content_starter_cases"] {
        for case in expected[group].as_array().into_iter().flatten() {
            if !case["assert_me"].as_bool().unwrap_or(false) {
                continue;
            }
            let lang = case["lang"].as_str().unwrap_or("rust");
            let compile_time = case["compile_time"].as_bool().unwrap_or(false);
            // A compile-time case is judged on what the compiler said; a
            // runtime one on what the program said as it died.
            let (key, classify): (&str, Classifier) = if compile_time {
                ("captured", mistakes::classify_compile)
            } else {
                ("captured_runtime", mistakes::classify_runtime)
            };
            let Some(captured) = case[key].as_str() else {
                continue;
            };
            let path = dir.join(captured);
            let Ok(text) = std::fs::read_to_string(&path) else {
                missing.push(captured.to_string());
                continue;
            };
            let label = case["file"]
                .as_str()
                .or_else(|| case["quest_id"].as_str())
                .unwrap_or(captured);
            let want_kind = case["kind"].as_str().unwrap();
            let want_code = case["code"].as_str();

            let found = classify(lang, &text);
            assert!(
                !found.is_empty(),
                "{label}: the classifier found nothing in real {lang} output"
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
                    "{label}: expected the identity '{want_code}', got {:?}",
                    found.iter().map(|m| (&m.kind, &m.code)).collect::<Vec<_>>()
                );
            }
            if lang == "rust" {
                checked.0 += 1;
            } else {
                checked.1 += 1;
            }
        }
    }
    assert!(missing.is_empty(), "captures named but absent: {missing:?}");
    assert!(
        checked.0 >= 10,
        "only {} rust cases were checked",
        checked.0
    );
    assert!(checked.1 >= 8, "only {} go cases were checked", checked.1);
    println!(
        "classified {} captured rustc outputs and {} captured go outputs",
        checked.0, checked.1
    );
}

/// Go has no error codes, so the identity is made from the message's shape —
/// and the player's own identifiers must never reach it, or "your top mistake"
/// becomes a list of one-offs.
#[test]
fn a_go_identity_keeps_the_shape_and_drops_the_names() {
    assert_eq!(mistakes::go_identity("missing return"), "go:missing-return");
    assert_eq!(
        mistakes::go_identity("undefined: tolal"),
        mistakes::go_identity("undefined: subtotal"),
        "two players misspelling different names made the same mistake"
    );
    // Two players, two names, one mistake — one identity.
    assert_eq!(
        mistakes::go_identity("not enough arguments in call to sum"),
        mistakes::go_identity("not enough arguments in call to total"),
    );
    assert!(!mistakes::go_identity("undefined: tolal").contains("tolal"));
    // A bare identifier stops the slug rather than being baked into it.
    assert_eq!(
        mistakes::go_identity("cannot convert x (variable of type float64) to type string"),
        "go:cannot-convert"
    );
    assert!(!mistakes::go_identity("invalid operation: Widget + int").contains("widget"));
}

#[test]
fn an_unrecognised_go_message_is_other_with_its_identity_kept() {
    let stderr = "# command-line-arguments\n./main.go:11:1: missing return\n";
    let found = mistakes::classify_go_build(stderr);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].kind, "other");
    assert_eq!(found[0].code.as_deref(), Some("go:missing-return"));
    assert_eq!(found[0].line, Some(11));
    assert_eq!(found[0].col, Some(1));
    assert_eq!(found[0].message, "missing return");
}

#[test]
fn go_build_noise_is_not_a_mistake() {
    // The package header, the indented detail lines of a signature mismatch,
    // and the truncation notice are all things `go build` prints that nobody
    // did wrong.
    let stderr = "# command-line-arguments\n\
        ./main.go:9:14: undefined: tolal\n\
        \thave (int)\n\
        \twant (string)\n\
        too many errors\n";
    let found = mistakes::classify_go_build(stderr);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].kind, "unknown-name");
    assert_eq!(found[0].code.as_deref(), Some("go:undefined"));
    assert_eq!(found[0].message, "undefined: tolal");
}

#[test]
fn a_go_panic_carries_the_players_line_not_the_runtimes() {
    let stderr = "panic: runtime error: index out of range [5] with length 3\n\n\
        goroutine 1 [running]:\n\
        main.main()\n\t<work>/main.go:12 +0x8c\n";
    let found = mistakes::classify_runtime("go", stderr);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].kind, "index-range");
    assert_eq!(found[0].code.as_deref(), Some("go:index-out-of-range"));
    assert_eq!(found[0].line, Some(12));
}

/// The same english word, two lands, two wordings: Rust says "index out of
/// bounds" and Go says "index out of range". One dispatcher rather than one
/// pattern list that half-matches both.
#[test]
fn the_two_lands_runtime_wordings_do_not_cross() {
    let rust_panic = "thread 'main' panicked at main.rs:3:5:\nindex out of bounds: the len is 3 but the index is 7\n";
    let go_panic = "panic: runtime error: index out of range [5] with length 3\n";
    assert_eq!(
        mistakes::classify_runtime("rust", rust_panic)[0].kind,
        "index-range"
    );
    assert_eq!(
        mistakes::classify_runtime("go", go_panic)[0].kind,
        "index-range"
    );
    assert!(mistakes::classify_runtime("go", rust_panic).is_empty());
    assert!(mistakes::classify_runtime("rust", go_panic).is_empty());
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

// ---------------------------------------------------------------------------
// C++ (SPEC §7.1's third column)
// ---------------------------------------------------------------------------

/// clang's wordings and gcc's, side by side: the kind must not depend on
/// which driver `c++` turned out to be.
#[test]
fn every_cpp_row_of_the_table_maps_for_both_compilers() {
    for (message, level, kind, code) in [
        (
            "use of undeclared identifier 'tolal'",
            "error",
            "unknown-name",
            "cpp:undeclared-identifier",
        ),
        (
            "'tolal' was not declared in this scope",
            "error",
            "unknown-name",
            "cpp:undeclared-identifier",
        ),
        (
            "unknown type name 'strng'",
            "error",
            "unknown-name",
            "cpp:undeclared-identifier",
        ),
        (
            "'strng' does not name a type",
            "error",
            "unknown-name",
            "cpp:undeclared-identifier",
        ),
        (
            "no member named 'size' in 'Stall'",
            "error",
            "unknown-name",
            "cpp:undeclared-identifier",
        ),
        (
            "no matching function for call to 'total'",
            "error",
            "type-mismatch",
            "cpp:no-matching-function",
        ),
        (
            "no matching member function for call to 'push_back'",
            "error",
            "type-mismatch",
            "cpp:no-matching-function",
        ),
        (
            "no match for 'operator+' (operand types are 'Stall' and 'int')",
            "error",
            "type-mismatch",
            "cpp:no-matching-function",
        ),
        (
            "no viable conversion from 'int' to 'std::string'",
            "error",
            "type-mismatch",
            "cpp:cannot-convert",
        ),
        (
            "cannot convert 'int' to 'std::string' in initialization",
            "error",
            "type-mismatch",
            "cpp:cannot-convert",
        ),
        (
            "cannot initialize a variable of type 'int' with an lvalue of type 'const char[3]'",
            "error",
            "type-mismatch",
            "cpp:cannot-convert",
        ),
        (
            "invalid conversion from 'const char*' to 'int'",
            "error",
            "type-mismatch",
            "cpp:cannot-convert",
        ),
        (
            "expected ';' after expression",
            "error",
            "syntax",
            "cpp:expected-token",
        ),
        (
            "expected '}' at end of input",
            "error",
            "syntax",
            "cpp:expected-token",
        ),
        (
            "expected primary-expression before ')' token",
            "error",
            "syntax",
            "cpp:expected-token",
        ),
        (
            "missing terminating \" character",
            "error",
            "syntax",
            "cpp:expected-token",
        ),
        (
            "cannot assign to variable 'c' with const-qualified type 'const int'",
            "error",
            "mutability",
            "cpp:const-discard",
        ),
        (
            "assignment of read-only variable 'c'",
            "error",
            "mutability",
            "cpp:const-discard",
        ),
        (
            "passing 'const Stall' as 'this' argument discards qualifiers",
            "error",
            "mutability",
            "cpp:const-discard",
        ),
        (
            "cannot bind non-const lvalue reference of type 'int&' to an rvalue of type 'int'",
            "error",
            "mutability",
            "cpp:const-discard",
        ),
        (
            "unused variable 'unused'",
            "warning",
            "unused",
            "cpp:unused",
        ),
        (
            "variable 'n' set but not used",
            "warning",
            "unused",
            "cpp:unused",
        ),
        (
            "'a' used after it was moved",
            "warning",
            "borrow-after-move",
            "cpp:use-after-move",
        ),
        (
            "invalid use of moved-from object",
            "error",
            "borrow-after-move",
            "cpp:use-after-move",
        ),
    ] {
        assert_eq!(
            mistakes::cpp_kind(message, level),
            (kind, code),
            "{message:?} should be {kind}/{code}"
        );
    }
}

#[test]
fn a_cpp_diagnostic_keeps_its_location_and_the_notes_are_not_mistakes() {
    // What clang prints for one bad `push_back`: the error, the source echo,
    // the caret, two notes from inside <vector>, and the trailer.
    let stderr = "\
main.cpp:9:27: error: no matching member function for call to 'push_back'
    9 |     std::vector<int> v; v.push_back(\"x\");
      |                         ~~^~~~~~~~~
/usr/include/c++/v1/__vector/vector.h:455:60: note: candidate function not viable: no known conversion from 'const char[2]' to 'const value_type' (aka 'const int') for 1st argument
  455 |   void push_back(const_reference __x) { emplace_back(__x); }
      |                                                            ^
main.cpp:10:22: error: expected ';' after expression
   10 |     std::cout << \"hi\"
      |                      ^
2 errors generated.
";
    let found = mistakes::classify_compile("cpp", stderr);
    assert_eq!(found.len(), 2, "{found:?}");
    assert_eq!(found[0].kind, "type-mismatch");
    assert_eq!(found[0].code.as_deref(), Some("cpp:no-matching-function"));
    assert_eq!((found[0].line, found[0].col), (Some(9), Some(27)));
    assert_eq!(found[1].kind, "syntax");
    assert_eq!((found[1].line, found[1].col), (Some(10), Some(22)));
    assert!(
        found[0].message.contains("push_back"),
        "the player's own words stay in the message: {}",
        found[0].message
    );
}

/// gcc frames the same diagnostic with a function header line and the same
/// `file:line:col:` prefix.
#[test]
fn a_gcc_diagnostic_classifies_the_same_way() {
    let stderr = "\
main.cpp: In function 'int main()':
main.cpp:3:18: error: 'tolal' was not declared in this scope
    3 |     std::cout << tolal;
      |                  ^~~~~
";
    let found = mistakes::classify_compile("cpp", stderr);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].kind, "unknown-name");
    assert_eq!(found[0].code.as_deref(), Some("cpp:undeclared-identifier"));
    assert_eq!((found[0].line, found[0].col), (Some(3), Some(18)));
}

#[test]
fn an_unrecognised_cpp_message_is_other_with_its_identity_kept() {
    let stderr = "main.cpp:4:5: error: something the table has never seen\n";
    let found = mistakes::classify_compile("cpp", stderr);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].kind, "other");
    assert_eq!(found[0].code.as_deref(), Some("cpp:other"));
    assert_eq!(found[0].line, Some(4));
}

#[test]
fn a_link_error_is_kept_and_not_dropped() {
    let stderr = "\
Undefined symbols for architecture arm64:
  \"foo(int)\", referenced from:
      _main in main-abc123.o
ld: symbol(s) not found for architecture arm64
clang++: error: linker command failed with exit code 1 (use -v to see invocation)
";
    let found = mistakes::classify_compile("cpp", stderr);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].code.as_deref(), Some("cpp:undefined-symbol"));
    assert_eq!(found[0].kind, "other");
}

#[test]
fn cpp_runtime_signals_and_exceptions_classify() {
    let segv = "the program was killed by signal 11 (SIGSEGV: segmentation fault)\n";
    let found = mistakes::classify_runtime("cpp", segv);
    assert_eq!(found[0].kind, "nil-deref");
    assert_eq!(found[0].code.as_deref(), Some("cpp:segfault"));

    // libc++ (macOS) and libstdc++ (Linux) announce an uncaught exception
    // differently; both name the type.
    for stderr in [
        "libc++abi: terminating due to uncaught exception of type std::out_of_range: vector\nthe program was killed by signal 6 (SIGABRT: abort)\n",
        "terminate called after throwing an instance of 'std::out_of_range'\n  what():  vector::_M_range_check\n",
    ] {
        let found = mistakes::classify_runtime("cpp", stderr);
        assert!(
            found.iter().any(|m| m.kind == "index-range" && m.code.as_deref() == Some("cpp:out-of-range")),
            "{found:?}"
        );
        assert!(
            !found.iter().any(|m| m.code.as_deref() == Some("cpp:abort")),
            "an out_of_range is one lesson, not two: {found:?}"
        );
    }
    let found = mistakes::classify_runtime(
        "cpp",
        "libc++abi: terminating due to uncaught exception of type std::runtime_error: boom\n",
    );
    assert_eq!(found[0].kind, "unhandled-error");
    assert_eq!(found[0].code.as_deref(), Some("cpp:abort"));

    let found = mistakes::classify_runtime(
        "cpp",
        "the program was killed by signal 6 (SIGABRT: abort)\n",
    );
    assert_eq!(found[0].code.as_deref(), Some("cpp:abort"));

    // QA's captures spell a signal death as `<signal N>`; signal 1 is not
    // signal 11.
    assert_eq!(
        mistakes::classify_runtime("cpp", "<signal 11>\n")[0]
            .code
            .as_deref(),
        Some("cpp:segfault")
    );
    assert_eq!(
        mistakes::classify_runtime("cpp", "<signal 6>\n")[0]
            .code
            .as_deref(),
        Some("cpp:abort")
    );
    assert!(mistakes::classify_runtime("cpp", "<signal 1>\n").is_empty());

    assert!(mistakes::classify_runtime("cpp", "").is_empty());
    assert!(mistakes::classify_runtime("cpp", "just some output\n").is_empty());
}

// ---------------------------------------------------------------------------
// Python (SPEC §7.1's fourth column)
// ---------------------------------------------------------------------------

#[test]
fn every_python_row_of_the_table_maps() {
    for (class, message, kind, code) in [
        (
            "NameError",
            "name 'tolal' is not defined",
            "unknown-name",
            "py:name-error",
        ),
        (
            "TypeError",
            "can only concatenate str (not \"int\") to str",
            "type-mismatch",
            "py:type-error",
        ),
        (
            "AttributeError",
            "'NoneType' object has no attribute 'price'",
            "nil-deref",
            "py:none-attribute",
        ),
        (
            "AttributeError",
            "'Stall' object has no attribute 'price'",
            "missing-trait",
            "py:attribute-error",
        ),
        (
            "IndexError",
            "list index out of range",
            "index-range",
            "py:index-error",
        ),
        ("KeyError", "'k'", "index-range", "py:key-error"),
        (
            "ZeroDivisionError",
            "division by zero",
            "unhandled-error",
            "py:zero-division",
        ),
        (
            "ValueError",
            "invalid literal for int() with base 10: 'x'",
            "unhandled-error",
            "py:value-error",
        ),
        (
            "RecursionError",
            "maximum recursion depth exceeded",
            "wrong-answer",
            "py:recursion",
        ),
        ("SyntaxError", "invalid syntax", "syntax", "py:syntax"),
        (
            "IndentationError",
            "expected an indented block",
            "syntax",
            "py:syntax",
        ),
    ] {
        assert_eq!(
            mistakes::python_kind(class, message),
            Some((kind, code)),
            "{class}: {message} should be {kind}/{code}"
        );
    }
}

#[test]
fn a_python_traceback_carries_the_innermost_frame_of_the_players_file() {
    let stderr = "\
Traceback (most recent call last):
  File \"/home/build/python/att_1/main.py\", line 4, in <module>
    g()
    ~^^
  File \"/home/build/python/att_1/main.py\", line 3, in g
    return x.price
           ^^^^^^^
AttributeError: 'NoneType' object has no attribute 'price'
";
    let found = mistakes::classify_runtime("python", stderr);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].kind, "nil-deref");
    assert_eq!(found[0].code.as_deref(), Some("py:none-attribute"));
    assert_eq!(found[0].line, Some(3));
    assert!(
        found[0].message.starts_with("AttributeError:"),
        "{}",
        found[0].message
    );
}

/// A chained traceback ends with the exception that actually escaped.
#[test]
fn a_chained_python_traceback_classifies_the_one_that_escaped() {
    let stderr = "\
Traceback (most recent call last):
  File \"main.py\", line 2, in <module>
    d['k']
KeyError: 'k'

During handling of the above exception, another exception occurred:

Traceback (most recent call last):
  File \"main.py\", line 4, in <module>
    raise ValueError('no such stall')
ValueError: no such stall
";
    let found = mistakes::classify_runtime("python", stderr);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].code.as_deref(), Some("py:value-error"));
    assert_eq!(found[0].line, Some(4));
}

#[test]
fn an_exception_nobody_named_is_unhandled_error_with_its_class_kept() {
    let stderr = "Traceback (most recent call last):\n  File \"main.py\", line 1, in <module>\n    raise RuntimeError('closed')\nRuntimeError: closed\n";
    let found = mistakes::classify_runtime("python", stderr);
    assert_eq!(found[0].kind, "unhandled-error");
    assert_eq!(found[0].code.as_deref(), Some("py:exception"));
    assert!(
        found[0].message.contains("RuntimeError"),
        "{}",
        found[0].message
    );

    // A player's own exception class is still an exception.
    let stderr = "Traceback (most recent call last):\n  File \"main.py\", line 5, in <module>\n    raise StallClosedError()\n__main__.StallClosedError\n";
    let found = mistakes::classify_runtime("python", stderr);
    assert!(
        found.is_empty() || found[0].kind == "unhandled-error",
        "{found:?}"
    );
}

#[test]
fn py_compile_output_is_syntax_with_the_parsers_line() {
    let stderr =
        "  File \"main.py\", line 1\n    def f(:\n          ^\nSyntaxError: invalid syntax\n";
    let found = mistakes::classify_compile("python", stderr);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].kind, "syntax");
    assert_eq!(found[0].code.as_deref(), Some("py:syntax"));
    assert_eq!(found[0].line, Some(1));

    // The `Sorry:` form py_compile uses for an IndentationError.
    let stderr = "Sorry: IndentationError: expected an indented block after 'if' statement on line 1 (main.py, line 2)\n";
    let found = mistakes::classify_compile("python", stderr);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].kind, "syntax");
    assert_eq!(found[0].line, Some(2));

    assert!(mistakes::classify_compile("python", "").is_empty());
}

/// Four lands, four wordings; the dispatcher keeps them apart.
#[test]
fn the_four_lands_runtime_wordings_do_not_cross() {
    let py = "Traceback (most recent call last):\n  File \"main.py\", line 1, in <module>\nKeyError: 'k'\n";
    let cpp = "the program was killed by signal 11 (SIGSEGV: segmentation fault)\n";
    assert_eq!(
        mistakes::classify_runtime("python", py)[0].kind,
        "index-range"
    );
    assert_eq!(mistakes::classify_runtime("cpp", cpp)[0].kind, "nil-deref");
    assert!(mistakes::classify_runtime("rust", py).is_empty());
    assert!(mistakes::classify_runtime("go", py).is_empty());
    assert!(mistakes::classify_runtime("cpp", py).is_empty());
    assert!(mistakes::classify_runtime("python", cpp).is_empty());
}

/// The §2 additions of docs/concepts.md: every new slug is reachable from a
/// mistake kind, and every slug named here is in the vocabulary.
#[test]
fn the_new_concepts_are_reachable_from_the_taxonomy() {
    for (kind, slug) in [
        ("borrow-after-move", "move-semantics"),
        ("borrow-after-move", "raii"),
        ("lifetime", "raii"),
        ("lifetime", "pointers"),
        ("nil-deref", "pointers"),
        ("nil-deref", "undefined-behaviour"),
        ("index-range", "undefined-behaviour"),
        ("type-mismatch", "duck-typing"),
        ("missing-trait", "duck-typing"),
        ("unknown-name", "decorators"),
        ("wrong-answer", "comprehensions"),
        ("wrong-answer", "generators"),
        ("timeout", "generators"),
    ] {
        assert!(
            mistakes::concepts_for(kind).contains(&slug),
            "{kind} should reach {slug}"
        );
    }
    for kind in [
        "borrow-after-move",
        "borrow-conflict",
        "lifetime",
        "type-mismatch",
        "unknown-name",
        "missing-trait",
        "unused",
        "mutability",
        "nil-deref",
        "index-range",
        "data-race",
        "deadlock",
        "unhandled-error",
        "syntax",
        "wrong-answer",
        "timeout",
    ] {
        for slug in mistakes::concepts_for(kind) {
            assert!(
                cwbhacker_core::content::CONCEPT_VOCABULARY.contains(slug),
                "{kind} names '{slug}', which is outside the vocabulary"
            );
        }
    }
}
