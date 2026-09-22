//! `code.format` through the server (PROTOCOL §4.9d), for every land.
//!
//! The runner has its own tests for the tools; this is the handler the two
//! clients actually call, and it exists because the bug it now guards was
//! invisible from either side alone: C++ formatting was reported as "not
//! installed" on every Mac, because `clang-format` ships inside Xcode's
//! developer directory and is not on `PATH`. The library found nothing, the
//! handler dutifully said so, and the button vanished — with the tool sitting
//! on the disk.
//!
//! So the contract asserted here is the one a player feels:
//!
//!   * a land the server advertises in `formats` **formats** — messy source
//!     comes back tidy, and `changed` says so;
//!   * a land it does not advertise refuses **without touching the source**;
//!   * the advertised set is exactly the set that works, so a client drawing
//!     its button from `formats` never draws a button that refuses.
//!
//! A machine missing a formatter does not fail this file — it asserts the
//! other half of the same rule. What it must never do is disagree with
//! itself.
use cwbhacker_runner::format;
use cwbhacker_server::handlers;
use serde_json::json;

/// Deliberately untidy, and deliberately valid: every formatter here refuses
/// source it cannot parse, and a parse failure would prove nothing about
/// formatting.
fn untidy(lang: &str) -> &'static str {
    match lang {
        "rust" => "fn main(){let x=1;println!(\"{}\",x);}\n",
        "go" => "package main\nimport \"fmt\"\nfunc main(){x:=1\nfmt.Println(x)}\n",
        "cpp" => "#include <iostream>\nint main(){int x=1;std::cout<<x<<\"\\n\";}\n",
        "python" => "def main():\n  x=1\n  print( x )\nmain()\n",
        // PyTorch Land is black's too, and the import is what makes the
        // fixture this land's rather than a copy of the one above.
        "pytorch" => "import torch\ndef main():\n  x=torch.tensor([1])\n  print( x )\nmain()\n",
        other => panic!("no fixture for {other}"),
    }
}

/// A mark of tidiness the tool's own default style must produce.
fn tidy_mark(lang: &str) -> &'static str {
    match lang {
        "rust" => "    let x = 1;",
        "go" => "\tx := 1",
        "cpp" => "int main() {",
        "python" => "    x = 1",
        "pytorch" => "    x = torch.tensor([1])",
        other => panic!("no mark for {other}"),
    }
}

const LANDS: [&str; 5] = ["rust", "go", "cpp", "python", "pytorch"];

#[test]
fn every_advertised_land_formats_and_the_rest_refuse_cleanly() {
    let advertised = format::supported_langs();
    for lang in LANDS {
        let source = untidy(lang);
        let reply = handlers::code_format(&json!({ "lang": lang, "source": source }));
        if advertised.contains(&lang) {
            let out = reply.unwrap_or_else(|e| panic!("{lang} is advertised but refused: {e:?}"));
            assert_eq!(
                out["changed"], true,
                "{lang} left untidy source alone: {out}"
            );
            let got = out["source"].as_str().expect("source is a string");
            assert!(
                got.contains(tidy_mark(lang)),
                "{lang} did not tidy it: {got:?}"
            );
            assert!(out.get("problem").is_none(), "{lang}: {out}");
        } else {
            // Not advertised: the handler refuses before spawning anything,
            // and the refusal names the land so a player is not left guessing.
            let err = reply.expect_err("an unsupported land must be refused");
            assert!(
                format!("{err:?}").contains(lang),
                "{lang}: the refusal does not name it: {err:?}"
            );
        }
    }
}

#[test]
fn formatting_tidy_source_is_a_no_op_rather_than_a_rewrite() {
    for lang in format::supported_langs() {
        let once = handlers::code_format(&json!({ "lang": lang, "source": untidy(lang) })).unwrap();
        let tidy = once["source"].as_str().unwrap().to_string();
        let twice = handlers::code_format(&json!({ "lang": lang, "source": &tidy })).unwrap();
        assert_eq!(
            twice["changed"], false,
            "{lang} keeps changing its mind: {twice}"
        );
        assert_eq!(twice["source"].as_str(), Some(tidy.as_str()), "{lang}");
    }
}

#[test]
fn half_written_source_never_loses_a_character() {
    // The property the whole feature hangs on: half-written code is the
    // normal state of an editor, and a formatter that mangles what it could
    // not parse destroys work that is backed up nowhere.
    //
    // Three of the four tools parse before they print, so they refuse and the
    // source comes back **byte for byte**. `clang-format` does not parse at
    // all — it is a token formatter, which is why it can format a fragment
    // inside an IDE — so it always succeeds and always rewrites. That is not
    // a lesser guarantee, but it is a different one, and it is the one worth
    // asserting: it may move whitespace anywhere it likes, and it may not
    // lose so much as a brace.
    let broken = [
        ("rust", "fn main( { let x = ;"),
        ("go", "package main\nfunc main( {"),
        ("cpp", "int main( { std::cout <<"),
        ("python", "def main(:\n  x=1\n"),
    ];
    for (lang, source) in broken {
        if !format::supported_langs().contains(&lang) {
            continue;
        }
        let out = handlers::code_format(&json!({ "lang": lang, "source": source })).unwrap();
        let got = out["source"].as_str().expect("source is a string");
        if lang == "cpp" {
            let strip = |s: &str| s.chars().filter(|c| !c.is_whitespace()).collect::<String>();
            assert_eq!(
                strip(got),
                strip(source),
                "clang-format lost or invented something: {got:?}"
            );
        } else {
            assert_eq!(got, source, "{lang} mangled it");
            assert_eq!(out["changed"], false, "{lang}");
            assert!(out.get("problem").is_some(), "{lang} must say why: {out}");
        }
    }
}

#[test]
fn a_land_with_no_formatter_at_all_is_refused() {
    let err = handlers::code_format(&json!({ "lang": "zig", "source": "fn main() {}" }))
        .expect_err("zig is not a land, let alone a formatted one");
    assert!(format!("{err:?}").contains("zig"), "{err:?}");
}
