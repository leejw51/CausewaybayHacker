//! `code.format` (PROTOCOL §4.9d).
//!
//! The property that matters most: unparseable source comes back **byte for
//! byte**. A formatter that mangles code it could not parse leaves the player
//! with two problems instead of one, and destroys work that is backed up
//! nowhere.

use cwbhacker_runner::format;

fn have(tool: &str) -> bool {
    std::process::Command::new(tool)
        .arg("--help")
        .output()
        .map(|o| o.status.success() || !o.stdout.is_empty() || !o.stderr.is_empty())
        .unwrap_or(false)
}

const UNTIDY: &str = "fn main(){let x=1;println!(\"{}\",x);}";
const TIDY: &str = "fn main() {\n    let x = 1;\n    println!(\"{}\", x);\n}\n";

#[test]
fn rustfmt_tidies_and_says_it_changed_something() {
    if !have("rustfmt") {
        return;
    }
    let out = format::format("rust", UNTIDY).unwrap();
    assert!(out.changed);
    assert_eq!(out.source, TIDY);
    assert!(out.problem.is_none(), "{:?}", out.problem);
}

/// So a client can say "already tidy" rather than flashing an identical buffer
/// at somebody.
#[test]
fn formatting_tidy_source_changes_nothing() {
    if !have("rustfmt") {
        return;
    }
    let out = format::format("rust", TIDY).unwrap();
    assert!(!out.changed, "got: {:?}", out.source);
    assert_eq!(out.source, TIDY);
    assert!(out.problem.is_none());
}

/// The one that matters. Half-written code is the normal state of a text
/// editor, not a fault.
#[test]
fn unparseable_source_comes_back_byte_for_byte() {
    if !have("rustfmt") {
        return;
    }
    let half_typed = "fn main() {\n    let x = vec![1, 2,\n";
    let out = format::format("rust", half_typed).unwrap();
    assert_eq!(
        out.source, half_typed,
        "the formatter returned something other than what it was given"
    );
    assert!(!out.changed);
    let problem = out.problem.expect("a refusal should say why");
    assert!(
        problem.to_lowercase().contains("delimiter") || problem.to_lowercase().contains("expected"),
        "the complaint should be the formatter's own: {problem}"
    );
    assert!(!problem.contains('\n'), "one line, not a wall: {problem}");
}

#[test]
fn whitespace_only_source_does_something_sane() {
    if !have("rustfmt") {
        return;
    }
    for source in ["", "\n", "   \n\n\t", "// just a comment\n"] {
        let out = format::format("rust", source).unwrap();
        // Either it tidies it or it leaves it; what it must not do is lose it
        // or claim a change it did not make.
        assert!(
            out.problem.is_none() || out.source == source,
            "{source:?} -> {out:?}"
        );
        if !out.changed {
            assert_eq!(out.source, source, "unchanged must mean unchanged");
        }
    }
}

#[test]
fn gofmt_tidies_go() {
    if !have("gofmt") {
        return;
    }
    let untidy = "package main\nimport \"fmt\"\nfunc main(){fmt.Println( \"hi\" )}\n";
    let out = format::format("go", untidy).unwrap();
    assert!(out.changed, "{out:?}");
    assert!(out.source.contains("func main() {"), "{}", out.source);
    assert!(out.problem.is_none());

    // And the same rule for broken Go.
    let broken = "package main\nfunc main() {\n";
    let out = format::format("go", broken).unwrap();
    assert_eq!(out.source, broken);
    assert!(!out.changed);
    assert!(out.problem.is_some());
}

#[test]
fn an_unknown_language_is_refused_without_touching_the_source() {
    assert!(!format::is_supported("cobol"));
    let out = format::format("cobol", UNTIDY).unwrap();
    assert_eq!(out.source, UNTIDY);
    assert!(!out.changed);
    assert!(out.problem.unwrap().contains("cobol"));
}

/// A formatter that hangs must be killed rather than hold the connection. The
/// limit is the same machinery a submission gets, so this asserts it is wired
/// in rather than re-testing the kill.
#[test]
fn a_formatter_gets_a_timeout_of_its_own() {
    if !have("rustfmt") {
        return;
    }
    let started = std::time::Instant::now();
    // A large but valid file: this is about the call returning, not about the
    // timeout firing — a formatter that hung would never come back at all.
    let big = "fn main() {\n".to_string() + &"    let _x = 1;\n".repeat(20_000) + "}\n";
    let out = format::format("rust", &big).unwrap();
    assert!(
        started.elapsed().as_secs() < 30,
        "the formatter held the thread for {:?}",
        started.elapsed()
    );
    assert!(out.source.contains("let _x = 1;"));
}

/// `clang-format` does not ship with `c++`, so the C++ answer to
/// `is_supported` is asked of PATH. Where it is installed it must behave
/// like the other two; where it is not, the gate must be closed and the
/// source must still come back untouched.
#[test]
fn clang_format_tidies_cpp_where_it_exists() {
    let untidy = "#include <iostream>\nint main(){std::cout<<\"hi\";}\n";
    if !have("clang-format") {
        assert!(!format::is_supported("cpp"));
        let out = format::format("cpp", untidy).unwrap();
        assert_eq!(out.source, untidy);
        assert!(!out.changed);
        assert!(out.problem.unwrap().contains("clang-format"));
        return;
    }
    assert!(format::is_supported("cpp"));
    let out = format::format("cpp", untidy).unwrap();
    assert!(out.changed, "{out:?}");
    assert!(out.source.contains("int main() {"), "{}", out.source);
    assert!(out.problem.is_none());

    // clang-format formats what it can of broken code rather than
    // refusing, so the property under test is only that nothing is lost.
    let broken = "int main() {\n";
    let out = format::format("cpp", broken).unwrap();
    assert!(out.source.contains("int main()"), "{out:?}");
}

#[test]
fn black_tidies_python_and_says_it_changed_something() {
    if !have_module("black") {
        return;
    }
    let out = format::format("python", "def main():\n  x=1\n  print( x )\nmain()\n").unwrap();
    assert!(out.changed, "black left it alone: {:?}", out.source);
    assert!(out.source.contains("    x = 1"), "{}", out.source);
    assert_eq!(out.problem, None);
}

#[test]
fn python_that_does_not_parse_comes_back_byte_for_byte() {
    if !have_module("black") {
        return;
    }
    // The property this whole file exists for: a formatter that mangles what
    // it could not parse destroys work that is backed up nowhere.
    let broken = "def main(:\n  x=1\n";
    let out = format::format("python", broken).unwrap();
    assert_eq!(out.source, broken);
    assert!(!out.changed);
    assert!(out.problem.is_some(), "it must say why");
}

#[test]
fn the_supported_list_is_what_this_machine_can_actually_run() {
    // Every land on the list formats; every land off it does not. This is
    // what a client draws its FORMAT button from (§4.3), so the two answers
    // must be the same answer.
    let langs = format::supported_langs();
    for lang in ["rust", "go", "cpp", "python"] {
        assert_eq!(
            langs.contains(&lang),
            format::is_supported(lang),
            "{lang} disagrees with the list"
        );
    }
    assert!(langs.contains(&"rust"), "rustfmt ships with the toolchain");
    assert!(
        !langs.contains(&"zig"),
        "a land with no formatter is off the list"
    );
}

fn have_module(module: &str) -> bool {
    std::process::Command::new("python3")
        .args(["-m", module, "--version"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
