//! SPEC §9.4 and §9.5 against whatever is in `content/` right now: every
//! reference solution must be accepted, and no starter may be. Every land.
//!
//! Ignored by default — it compiles every quest in the repository, twice, and
//! takes a couple of minutes. Run it with `cargo test -- --ignored` when the
//! content changes, or from the content CI. A quest whose own answer no longer
//! compiles has no other way of being found.

use std::path::PathBuf;

use cwbhacker_core::content::Pack;
use cwbhacker_runner::{Submission, TestSpec, Verdict};

fn content_root(land: &str) -> Option<PathBuf> {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let root = manifest.parent()?.parent()?.join("content").join(land);
    root.is_dir().then_some(root)
}

#[test]
#[ignore = "compiles every quest in content/rust; run it with --ignored"]
fn every_rust_reference_solution_is_accepted_and_no_starter_is() {
    check_land("rust");
}

#[test]
#[ignore = "compiles every quest in content/go; run it with --ignored"]
fn every_go_reference_solution_is_accepted_and_no_starter_is() {
    check_land("go");
}

#[test]
#[ignore = "compiles every quest in content/cpp; run it with --ignored"]
fn every_cpp_reference_solution_is_accepted_and_no_starter_is() {
    check_land("cpp");
}

#[test]
#[ignore = "runs every quest in content/python; run it with --ignored"]
fn every_python_reference_solution_is_accepted_and_no_starter_is() {
    check_land("python");
}

fn check_land(land: &str) {
    let Some(root) = content_root(land) else {
        eprintln!("no content/{land} yet — nothing to check");
        return;
    };
    let tmp = tempfile::tempdir().unwrap();
    let mut broken = Vec::new();
    let mut checked = 0;

    for entry in std::fs::read_dir(&root).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("toml") {
            continue;
        }
        let pack: Pack = toml::from_str(&std::fs::read_to_string(&path).unwrap())
            .unwrap_or_else(|e| panic!("{} is not a pack: {e}", path.display()));
        for quest in &pack.quests {
            checked += 1;
            let tests = serde_json::to_value(&quest.tests).unwrap();
            let spec = match TestSpec::parse(&tests) {
                Ok(spec) => spec,
                Err(e) => {
                    broken.push(format!("{}: unreadable test spec: {e}", quest.id));
                    continue;
                }
            };
            let solution = run(
                land,
                &quest.id,
                &quest.solution,
                &spec,
                tmp.path(),
                "solution",
            );
            if solution != Verdict::Accepted {
                broken.push(format!("{}: its own solution is {solution:?}", quest.id));
            }
            let starter = run(
                land,
                &quest.id,
                &quest.starter,
                &spec,
                tmp.path(),
                "starter",
            );
            if starter == Verdict::Accepted {
                broken.push(format!(
                    "{}: the starter passes — the map clears itself",
                    quest.id
                ));
            }
        }
    }
    println!("checked {checked} {land} quests");
    assert!(broken.is_empty(), "\n{}", broken.join("\n"));
}

fn run(
    land: &str,
    id: &str,
    source: &str,
    spec: &TestSpec,
    tmp: &std::path::Path,
    tag: &str,
) -> Verdict {
    let submission = Submission {
        attempt_id: id,
        lang: land,
        source,
        spec,
        workdir: tmp.join(format!("{id}-{tag}")),
        cache_root: tmp.join("cache"),
        events: cwbhacker_runner::no_events(),
    };
    cwbhacker_runner::run(&submission).verdict
}
