//! SPEC §9.6 — the runner's limits, the cases `rust_runner.rs` does not cover.
//!
//! `rust_runner.rs` already proves three of the nine cases in
//! `tests/PLAN.md` §9.6: the infinite loop (9.6.a), the output cap (9.6.b),
//! and the process-group half of the fork bomb (9.6.c). This file is the
//! rest, and nothing here duplicates it — see the table in `tests/PLAN.md`
//! for which test owns which row, so the two files are never counted twice.
//!
//! What is left:
//!
//! * **9.6.e** `RLIMIT_AS` — a program that asks for more address space than
//!   SPEC §5.3's 1 GiB dies, rather than the host swapping.
//! * **9.6.f** `RLIMIT_FSIZE` — a program that writes more than 64 MiB dies,
//!   rather than filling the disk.
//! * **9.6.g** nothing outside the home — the workdir is the only thing a
//!   submission touches, and the environment it runs in cannot lead it
//!   anywhere else.
//! * **the other half of 9.6.c** — after all of that, the runner still works.
//!   "The server is alive" is the assertion that actually matters, and it is
//!   the one nobody writes.
//!
//! * **9.6.d** `GOPROXY=off` — a Go quest that reaches for the internet fails
//!   cleanly instead of hanging on a network CI may not have.
//!
//! 9.6.d was unwritable for a while and this file said so rather than
//! shipping a test that passed because Go was unsupported. BE built the Go
//! runner, so it is written now, and with it **all nine rows of §9.6 have an
//! owner** — see the table in `tests/PLAN.md`.
//!
//! These are slow: each one compiles a real program with a real `rustc`.
//! That is the point. A limit asserted in a comment is not a limit.

use std::sync::Arc;
use std::time::Instant;

use cwbhacker_runner::{no_events, Submission, TestSpec, Verdict};

struct Harness {
    _tmp: tempfile::TempDir,
    root: std::path::PathBuf,
}

fn harness() -> Harness {
    // The home is a directory *inside* the temp dir, not the temp dir itself.
    //
    // `the_runner_itself_writes_only_under_the_home_it_was_given` snapshots
    // the home's parent before and after a run; with the home at the top of
    // `$TMPDIR` that parent is shared with every other test in this binary,
    // and a sibling creating its own `tempdir()` mid-snapshot looked exactly
    // like the runner writing outside its home. One failure in four runs,
    // which teaches people to re-run instead of read.
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("home");
    std::fs::create_dir_all(&root).unwrap();
    Harness { _tmp: tmp, root }
}

/// A `stdio` spec with one visible case and a generous clock, so a test that
/// is about a memory or a file limit fails on that limit and not on time.
fn spec(timeout_ms: u64, expect: &str) -> TestSpec {
    TestSpec::parse(&serde_json::json!({
        "harness": "stdio",
        "timeout_ms": timeout_ms,
        "match": "trim",
        "cases": [ { "name": "only", "stdin": "", "expect": expect, "visible": true } ],
    }))
    .expect("spec parses")
}

fn run_in(h: &Harness, attempt: &str, source: &str, spec: &TestSpec) -> cwbhacker_runner::Report {
    let submission = Submission {
        attempt_id: attempt,
        lang: "rust",
        source,
        spec,
        workdir: h.root.join("build/rust").join(attempt),
        cache_root: h.root.join("build/rust"),
        events: no_events(),
    };
    cwbhacker_runner::run(&submission)
}

// --------------------------------------------------------------- 9.6.e

#[test]
fn a_program_that_wants_more_memory_than_the_limit_dies_rather_than_the_host() {
    // SPEC §5.3: `setrlimit` for address space, 1 GiB. Without it a runaway
    // allocation does not fail — it succeeds, the host starts swapping, and
    // the first thing the player notices is their machine becoming unusable
    // while a quest "runs". The failure mode this prevents is not a wrong
    // verdict; it is the trainer taking the computer down with it.
    //
    // 8 GiB is asked for deliberately: comfortably over the limit on any
    // machine, and comfortably over what a CI box would have spare even if
    // the limit were missing, so a green here cannot be luck.
    let h = harness();
    let source = r#"
fn main() {
    // Touched, not merely reserved: a `Vec::with_capacity` that is never
    // written can be optimised away or lazily mapped, and then the test
    // would prove nothing.
    let mut hoard: Vec<Vec<u8>> = Vec::new();
    for _ in 0..64 {
        let mut block = vec![0u8; 128 * 1024 * 1024];
        for i in (0..block.len()).step_by(4096) {
            block[i] = 1;
        }
        hoard.push(block);
    }
    println!("allocated {}", hoard.len());
}
"#;
    let started = Instant::now();
    let report = run_in(&h, "att_rlimit_as", source, &spec(30_000, "never\n"));
    let elapsed = started.elapsed();

    assert_ne!(
        report.verdict,
        Verdict::Accepted,
        "an 8 GiB allocation was accepted; RLIMIT_AS is not being applied"
    );
    // Which way it dies is the platform's business — an abort on a failed
    // allocation, a SIGSEGV, or the guard page. What is not acceptable is
    // `accepted`, a timeout (which would mean it was swapping rather than
    // being refused), or a hang.
    assert!(
        matches!(
            report.verdict,
            Verdict::RuntimeError | Verdict::WrongAnswer | Verdict::OutputLimit
        ),
        "expected the allocation to be refused; got {:?} with stderr {:?}",
        report.verdict,
        report.runtime_stderr
    );
    assert!(
        elapsed.as_secs() < 60,
        "it took {elapsed:?} — that is the shape of a host that swapped \
         instead of a limit that fired"
    );
}

// --------------------------------------------------------------- 9.6.f

#[test]
fn a_program_that_writes_a_huge_file_is_stopped_by_the_file_size_limit() {
    // SPEC §5.3: `setrlimit` for file size, 64 MiB. Distinct from the stdout
    // cap (9.6.b, already covered in `rust_runner.rs`): that one is counted
    // by the runner while it drains the pipe, this one is the kernel
    // refusing a `write`. A submission that fills the disk takes the home,
    // the database and the player's whole record with it.
    let h = harness();
    let source = r#"
use std::io::Write;
fn main() {
    let mut file = match std::fs::File::create("hoard.bin") {
        Ok(f) => f,
        Err(e) => { eprintln!("create failed: {e}"); return; }
    };
    let block = vec![0u8; 1024 * 1024];
    let mut written = 0u64;
    // 512 MiB, eight times the limit. A loop that ignores the error would
    // spin for ever, so it stops at the first refusal and says so.
    for _ in 0..512 {
        match file.write_all(&block) {
            Ok(()) => written += block.len() as u64,
            Err(e) => { eprintln!("stopped at {written} bytes: {e}"); return; }
        }
    }
    let _ = file.flush();
    println!("wrote {written}");
}
"#;
    let report = run_in(&h, "att_rlimit_fsize", source, &spec(60_000, "never\n"));

    assert_ne!(
        report.verdict,
        Verdict::Accepted,
        "512 MiB was written successfully; RLIMIT_FSIZE is not being applied"
    );

    // The file that did get created must be at or under the limit, whichever
    // way the program died. This is the assertion with teeth: a verdict can
    // be wrong for many reasons, but a 512 MiB file on disk cannot.
    let written = h.root.join("build/rust/att_rlimit_fsize/hoard.bin");
    if written.exists() {
        let size = std::fs::metadata(&written).unwrap().len();
        assert!(
            size <= 64 * 1024 * 1024,
            "the limit is 64 MiB and the file is {size} bytes"
        );
    }
}

// --------------------------------------------------------------- 9.6.g

#[test]
fn the_runner_itself_writes_only_under_the_home_it_was_given() {
    // SPEC §1: "**Nothing outside the home is written.** No `/tmp`, no
    // project directory."
    //
    // Read carefully, that is a promise about **the runner**, not a
    // containment guarantee about the code it runs — SPEC §5.3 says so in
    // as many words: "This is not a sandbox. Causewaybay Hacker compiles and
    // runs code you typed, on your machine, as you." A submission that wants
    // to write to `~/evil` can, and nothing here pretends otherwise; see the
    // test below, which records that rather than asserting against it.
    //
    // What this test asserts is the part that is a real promise and that a
    // careless change could quietly break: the runner's own footprint — the
    // source it writes, the binary it produces, the cargo and toolchain
    // caches it warms — lands under the directory it was handed and nowhere
    // else. The failure this catches is a `CARGO_HOME` left unset, which
    // would warm the *developer's* `~/.cargo` and make one machine's run
    // differ from another's for reasons nobody can see.
    let h = harness();
    let outside = h.root.parent().unwrap().to_path_buf();
    let before = listing(&outside);

    let report = run_in(
        &h,
        "att_footprint",
        r#"fn main() { println!("hello, causewaybay"); }"#,
        &spec(60_000, "hello, causewaybay\n"),
    );
    assert_eq!(
        report.verdict,
        Verdict::Accepted,
        "{:?}",
        report.compiler_stderr
    );

    let after = listing(&outside);
    let added: Vec<&String> = after.iter().filter(|p| !before.contains(*p)).collect();
    assert!(
        added.is_empty(),
        "the runner created {added:?} outside the home it was given ({})",
        h.root.display()
    );

    // And the things it *did* create are where they were asked to be.
    let workdir = h.root.join("build/rust/att_footprint");
    assert!(workdir.join("main.rs").exists(), "the source was not kept");
    assert!(
        h.root.join("build/rust").exists(),
        "the cache root was not used"
    );
}

/// Every entry directly inside `dir`, as strings. Shallow on purpose: the
/// question is whether something new *appeared*, and walking a whole
/// temp-directory tree would be slow and would churn on the runner's own
/// cache.
fn listing(dir: &std::path::Path) -> std::collections::BTreeSet<String> {
    std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn a_submission_runs_in_a_stripped_environment_pointed_at_the_build_dir() {
    // SPEC §5.3: "a stripped environment (`PATH`, `HOME` pointed at the build
    // dir, the toolchain vars above, nothing else)".
    //
    // This is the half of §1 that *is* enforceable without a sandbox. It does
    // not stop determined code from writing anywhere — nothing short of a
    // real sandbox would, and §5.3 is explicit that this is not one — but it
    // does mean that ordinary code doing ordinary things lands somewhere
    // harmless. A library that writes a dotfile on first use writes it into
    // the build tree; a crash dump goes there; `cargo` warms the project's
    // cache and not the person's.
    //
    // It also closes the leak that is easy to miss: whatever secrets the
    // shell that started the server happened to be carrying — an API token,
    // a proxy, a `CARGO_HOME` pointing at a real cache — are readable by
    // every submission unless the environment is cleared.
    let h = harness();
    let source = r#"
fn main() {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut names: Vec<String> = std::env::vars().map(|(k, _)| k).collect();
    names.sort();
    eprintln!("HOME {home}");
    eprintln!("ENV {}", names.join(","));
    println!("reported");
}
"#;
    let report = run_in(
        &h,
        "att_env",
        source,
        &spec(
            30_000,
            "reported
",
        ),
    );
    assert_eq!(
        report.verdict,
        Verdict::Accepted,
        "{:?}",
        report.compiler_stderr
    );

    let line = |prefix: &str| {
        report
            .runtime_stderr
            .lines()
            .find(|l| l.starts_with(prefix))
            .map(|l| l.trim_start_matches(prefix).trim().to_string())
            .unwrap_or_default()
    };

    let home = line("HOME");
    assert!(
        !home.is_empty(),
        "HOME was not set at all: {:?}",
        report.runtime_stderr
    );
    let real_home = std::env::var("HOME").unwrap_or_default();
    assert_ne!(
        home, real_home,
        "HOME inside a submission is the person's own home directory, so a          library that writes a dotfile writes it into their account"
    );
    assert!(
        std::path::Path::new(&home).starts_with(&h.root),
        "HOME is {home}, outside the home the runner was given ({})",
        h.root.display()
    );

    let names: Vec<String> = line("ENV")
        .split(',')
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect();
    assert!(!names.is_empty(), "no environment was reported at all");
    let allowed = |name: &str| {
        matches!(
            name,
            "PATH" | "HOME" | "TMPDIR" | "LANG" | "LC_ALL" | "PWD" | "LD_LIBRARY_PATH"
        ) || name.starts_with("CARGO")
            || name.starts_with("RUST")
            || name.starts_with("GO")
    };
    let leaked: Vec<&String> = names.iter().filter(|n| !allowed(n)).collect();
    assert!(
        leaked.is_empty(),
        "a submission can read {leaked:?}. SPEC §5.3 says the environment is          stripped to PATH, HOME and the toolchain vars — everything else is          whatever the shell that started the server was carrying. The full          list was {names:?}"
    );
}

#[test]
fn the_compiler_does_not_see_the_servers_environment_either() {
    // The runtime environment is stripped (above), but a compiler is a
    // program the player steers too: `option_env!` bakes a variable of the
    // *compiler's* environment into the binary at compile time, and the
    // stripped runtime environment never gets a say. This is what made an
    // API key in the shell that started the server printable by one line of
    // Rust. The compile phase runs in `harness::toolchain_base`'s allowlist.
    //
    // The variable is set in this test process, which is the "server" the
    // runner is spawned from. Tests in this file run in one process, so the
    // name is unique to this test and is cleared again afterwards.
    const NAME: &str = "CWBH_TEST_CANARY_FOR_OPTION_ENV";
    std::env::set_var(NAME, "the-server-secret");
    let h = harness();
    let source = r#"
fn main() {
    match option_env!("CWBH_TEST_CANARY_FOR_OPTION_ENV") {
        Some(v) => println!("leaked {v}"),
        None => println!("clean"),
    }
}
"#;
    let report = run_in(&h, "att_option_env", source, &spec(30_000, "clean\n"));
    std::env::remove_var(NAME);
    assert_eq!(
        report.verdict,
        Verdict::Accepted,
        "the compiler saw the server's environment: {:?} / {:?}",
        report.compiler_stderr,
        report.cases
    );
}

#[test]
fn it_is_not_a_sandbox_and_this_test_says_so_out_loud() {
    // Deliberately asserts the *weak* thing, because the strong thing is not
    // true and a test claiming otherwise would be the most dangerous file in
    // the repository.
    //
    // SPEC §5.3: "**This is not a sandbox.** Causewaybay Hacker compiles and
    // runs code you typed, on your machine, as you. It is a
    // single-trusted-user local trainer. Do not point it at the internet, and
    // do not paste in code you would not run in a shell."
    //
    // A submission using an absolute path, or `..`, reaches anywhere the
    // person running the server can reach. This test demonstrates it so that
    // the fact is in the suite rather than in somebody's head, and so that
    // the day somebody adds a real sandbox this test fails and gets rewritten
    // into the assertion everyone would prefer.
    //
    // SPEC §1's flat sentence "Nothing outside the home is written" reads as
    // a containment promise and is not one; it describes the runner, not the
    // code. Raised in docs/decisions.md.
    let h = harness();
    let reachable = h.root.parent().unwrap().join("cwbhacker-escape-probe.txt");
    let _ = std::fs::remove_file(&reachable);

    let source = format!(
        r#"fn main() {{
    match std::fs::write("{}", "reached") {{
        Ok(()) => println!("reached"),
        Err(e) => println!("refused: {{e}}"),
    }}
}}"#,
        reachable.display()
    );
    let report = run_in(
        &h,
        "att_not_a_sandbox",
        &source,
        &spec(
            30_000, "reached
",
        ),
    );

    let escaped = reachable.exists();
    let _ = std::fs::remove_file(&reachable);

    assert_eq!(
        report.verdict,
        Verdict::Accepted,
        "the probe did not even run: {:?}",
        report.compiler_stderr
    );
    assert!(
        escaped,
        "a submission could NOT write outside the home. That is better than          the documented behaviour, which means a sandbox has been added —          good, and this test is now wrong. Replace it with the containment          assertion, update SPEC §5.3, and tell the README, which currently          warns people in the opposite direction."
    );
}

// ------------------------------------------------- the other half of 9.6.c

#[test]
fn the_runner_still_works_after_every_limit_has_fired() {
    // The assertion SPEC §9.6 actually cares about and that nothing else
    // makes: "Fork bomb → killed, **server alive**".
    //
    // Each limit is tested on its own above and in `rust_runner.rs`. What no
    // single-case test can show is whether the runner survives them — a
    // leaked child, a workdir left locked, a cache corrupted by a process
    // that died mid-write. So: put four pathological submissions through one
    // runner with one shared cache, in sequence, and then ask it to judge a
    // program that should obviously pass.
    //
    // If the last assertion fails, the player's next quest after somebody
    // else's fork bomb is broken, and they have no idea why.
    let h = harness();

    let hostile: [(&str, &str, u64); 4] = [
        (
            "att_after_loop",
            "fn main() { loop { std::hint::spin_loop(); } }",
            1_000,
        ),
        (
            "att_after_flood",
            r#"fn main() { let line = "x".repeat(4096); loop { println!("{line}"); } }"#,
            10_000,
        ),
        (
            "att_after_panic",
            r#"fn main() { let v: Vec<u8> = Vec::new(); println!("{}", v[7]); }"#,
            5_000,
        ),
        (
            "att_after_children",
            r#"
fn main() {
    // Not an unbounded fork bomb — RLIMIT_NPROC is deliberately not set
    // (it is per-user on macOS, so setting it would throttle the whole
    // machine rather than the child). What is asserted is SPEC §5.3's
    // other half: the child is in its own process group and dies with it.
    for _ in 0..8 {
        let _ = std::process::Command::new("/bin/sh")
            .args(["-c", "sleep 120"])
            .spawn();
    }
    println!("spawned");
    loop { std::hint::spin_loop(); }
}
"#,
            2_000,
        ),
    ];

    for (attempt, source, timeout) in hostile {
        let report = run_in(&h, attempt, source, &spec(timeout, "never\n"));
        assert_ne!(
            report.verdict,
            Verdict::Accepted,
            "{attempt} was accepted, which means its limit did not fire"
        );
        assert_ne!(
            report.verdict,
            Verdict::InternalError,
            "{attempt} took the runner down with it: {}",
            report.runtime_stderr
        );
    }

    // And now the thing that matters: a normal submission, judged correctly,
    // through the same runner and the same cache.
    let good = run_in(
        &h,
        "att_after_all",
        r#"fn main() { println!("hello, causewaybay"); }"#,
        &spec(30_000, "hello, causewaybay\n"),
    );
    assert_eq!(
        good.verdict,
        Verdict::Accepted,
        "the runner did not survive four pathological submissions. \
         compiler said {:?}, program said {:?}",
        good.compiler_stderr,
        good.runtime_stderr
    );
    assert_eq!(good.tests_passed, good.tests_total);
}

#[test]
fn a_timeout_is_a_verdict_and_not_a_lost_attempt() {
    // SPEC §9.6.h / PROTOCOL.md §4.9: "A submission is **always recorded**,
    // including a compile error, including a timeout. That is the
    // curriculum." The server-side half of that — the row really reaching
    // `stats.history` — is in `backend/server/tests/integration.rs`; this is
    // the runner's half, which is that a timeout comes back as a *report*
    // with the timing filled in, not as an internal error or an empty shell.
    let h = harness();
    let report = run_in(
        &h,
        "att_timeout_shape",
        "fn main() { loop { std::hint::spin_loop(); } }",
        &spec(1_000, "never\n"),
    );

    assert_eq!(report.verdict, Verdict::Timeout);
    assert_eq!(report.tests_total, 1, "the case still counts as a case");
    assert_eq!(report.tests_passed, 0);
    assert!(
        report.compile_ms > 0,
        "the compile really happened, so its cost is known"
    );
    assert!(
        !report.cases.is_empty(),
        "a timeout must still report the case it timed out on, or the \
         result screen has nothing to show"
    );
    assert!(
        Arc::strong_count(&no_events()) > 0,
        "keeps the Arc import honest"
    );
}

// --------------------------------------------------------------- 9.6.d

#[test]
fn a_go_quest_that_reaches_for_the_internet_fails_cleanly_rather_than_hanging() {
    // SPEC §9.6: "`GOPROXY=off` → a quest that tries to fetch fails cleanly."
    // §5.1: "`GOPROXY=off` — a quest does not fetch the internet."
    //
    // This was unwritable until BE built the Go runner, and the module
    // doc above said so rather than shipping a test that passed because Go
    // was unsupported. It is writable now, so here it is.
    //
    // **"Cleanly" is the whole assertion.** Without `GOPROXY=off` this does
    // not fail — it *hangs*, resolving a module against a network that CI
    // may not have and a player's laptop may have only intermittently. A
    // player would watch a quest compile for thirty seconds and give up; a CI
    // box would sit on it until something else timed out. A `compile_error`
    // in under a second is the correct outcome, and the difference between
    // the two is invisible unless something asserts it.
    let h = harness();
    let source = r#"
package main

import (
	"fmt"

	"github.com/definitely/not/vendored"
)

func main() {
	fmt.Println(vendored.Anything())
}
"#;
    // Generous on purpose: if the proxy were reachable the resolve would take
    // seconds, and the point is to catch that rather than to race it.
    let started = Instant::now();
    let report = run_go_in(&h, "att_goproxy", source, &spec(60_000, "never\n"));
    let elapsed = started.elapsed();

    assert_ne!(
        report.verdict,
        Verdict::Accepted,
        "a quest importing a module nobody vendored was accepted"
    );
    assert_eq!(
        report.verdict,
        Verdict::CompileError,
        "expected a compile error; got {:?}. A timeout here means the build \
         went looking for the module instead of being told not to.",
        report.verdict
    );
    assert!(
        elapsed.as_secs() < 30,
        "it took {elapsed:?}. With GOPROXY=off this is a refusal, not a \
         network round trip — that shape is what a player sees as a quest \
         that will not compile and will not stop trying."
    );

    // The message has to be about the module, not a bare "cannot find
    // package": a player who reads it should understand that the quest is
    // supposed to use the standard library, not that their machine is broken.
    let said = report.compiler_stderr.to_lowercase();
    assert!(
        said.contains("github.com/definitely/not/vendored")
            || said.contains("no required module")
            || said.contains("goproxy")
            || said.contains("module lookup disabled"),
        "the build failed but said nothing about the import: {:?}",
        report.compiler_stderr
    );

    // And the runner is fine afterwards — a failed module resolution must not
    // poison the shared module cache for the next submission.
    let good = run_go_in(
        &h,
        "att_goproxy_after",
        "package main\n\nimport \"fmt\"\n\nfunc main() { fmt.Println(\"ok\") }\n",
        &spec(30_000, "ok\n"),
    );
    assert_eq!(
        good.verdict,
        Verdict::Accepted,
        "a standard-library program stopped working after a failed module \
         lookup: {:?}",
        good.compiler_stderr
    );
}

/// The Go twin of `run_in`. Kept beside it rather than generalising the one
/// function, because the language is part of what a reader needs to see.
fn run_go_in(
    h: &Harness,
    attempt: &str,
    source: &str,
    spec: &TestSpec,
) -> cwbhacker_runner::Report {
    let submission = Submission {
        attempt_id: attempt,
        lang: "go",
        source,
        spec,
        workdir: h.root.join("build/go").join(attempt),
        cache_root: h.root.join("build/go"),
        events: no_events(),
    };
    cwbhacker_runner::run(&submission)
}

// ------------------------------------------- the escape §5.3 did not cover

/// SPEC §5.3 says the child is put in its own process group "so a fork bomb
/// dies with it", and 9.6.c tests exactly one shape of that: a child that
/// stays in the group, which `killpg` does catch. A child that **leaves** —
/// `Command::process_group(0)`, `setsid`, `setpgid` — is by definition not in
/// the group the kill is aimed at.
///
/// This test is the one that was missing. Whatever the runner does about it,
/// this asserts what is actually true today, so the day the behaviour changes
/// the test fails loudly rather than the claim quietly rotting.
#[test]
fn a_descendant_that_leaves_the_process_group_is_still_reaped() {
    let h = harness();
    let marker = h.root.join("escaped.txt");
    let _ = std::fs::remove_file(&marker);

    // The escapee outlives the timeout on purpose: `sleep 6` against a 5 s
    // clock. If the kill reaches it, the marker never appears; if it does not,
    // the marker is written about a second *after* the runner said it had
    // killed everything.
    let source = format!(
        r#"
use std::os::unix::process::CommandExt;
fn main() {{
    let mut command = std::process::Command::new("/bin/sh");
    command.arg("-c").arg("sleep 6; printf escaped > {}");
    // A new process group. `killpg` on the submission's group cannot reach it.
    command.process_group(0);
    let child = command.spawn().expect("spawn");
    eprintln!("escapee {{}}", child.id());
    loop {{ std::hint::spin_loop(); }}
}}
"#,
        marker.display()
    );

    let started = Instant::now();
    let report = run_in(&h, "att_escape_group", &source, &spec(5_000, "never\n"));
    let elapsed = started.elapsed();

    assert_eq!(
        report.verdict,
        Verdict::Timeout,
        "the submission itself must still be killed on the clock: {:?}",
        report.runtime_stderr
    );

    // The runner returning on its own clock, rather than on a pipe an escapee
    // is holding, is asserted on its own below — with a margin a loaded
    // machine cannot eat — by
    // `a_submission_cannot_set_its_own_wall_clock_by_spawning_something`.
    assert!(
        elapsed < std::time::Duration::from_secs(45),
        "the whole attempt took {elapsed:?}"
    );

    // Now the question the whole test exists for. `sleep 6` from the start of
    // the run; give it four seconds past the 5 s kill and look.
    std::thread::sleep(std::time::Duration::from_secs(4));
    let escaped = marker.exists();
    let _ = std::fs::remove_file(&marker);
    assert!(
        !escaped,
        "a descendant that put itself in a new process group outlived the \
         kill and ran to completion. SPEC §5.3 claims the group kill contains \
         a fork bomb; it does not contain this."
    );
}

/// The hole the sweep does **not** close, asserted out loud so that it is in
/// the suite rather than in somebody's head — the same reason
/// `it_is_not_a_sandbox_and_this_test_says_so_out_loud` exists.
///
/// A process that both **leaves the process group and is orphaned** before the
/// runner's next sample of the process table is gone: its parent is dead, so
/// the kernel no longer holds the link that would identify it as ours, and it
/// is in nobody's group we know. `ps`/`libproc` on macOS will not report a
/// session id to a non-root user, so there is no third key to match on.
///
/// The day this test fails, something has closed the hole — a sandbox, a
/// cgroup, root privileges. That is good news, and the thing to do is rewrite
/// this test into the assertion everyone would prefer and **correct SPEC
/// §5.3**, which is written to match exactly what is asserted here.
#[test]
fn a_descendant_orphaned_between_two_samples_escapes_and_this_is_documented() {
    let h = harness();
    let marker = h.root.join("orphan.txt");
    let _ = std::fs::remove_file(&marker);

    // `sh` starts a background subshell in its own process group and exits at
    // once. The subshell is then an orphan (`ppid` 1) outside the group — the
    // one shape nothing can find. The submission lingers just long enough to
    // guarantee the orphaning has happened before the run ends, so this is a
    // deterministic escape rather than a race the test might win.
    let source = format!(
        r#"
use std::os::unix::process::CommandExt;
fn main() {{
    let mut command = std::process::Command::new("/bin/sh");
    command.arg("-c").arg("(sleep 4; printf escaped > {}) & exit 0");
    command.process_group(0);
    let mut child = command.spawn().expect("spawn");
    let _ = child.wait();
    std::thread::sleep(std::time::Duration::from_millis(400));
    println!("done");
}}
"#,
        marker.display()
    );

    let report = run_in(&h, "att_escape_orphan", &source, &spec(10_000, "done\n"));
    assert_eq!(
        report.verdict,
        Verdict::Accepted,
        "the probe did not even run: {:?} / {:?}",
        report.compiler_stderr,
        report.runtime_stderr
    );

    std::thread::sleep(std::time::Duration::from_secs(5));
    let escaped = marker.exists();
    let _ = std::fs::remove_file(&marker);
    assert!(
        escaped,
        "the orphan did NOT escape. That is better than SPEC §5.3 claims, \
         which means containment has improved — rewrite this test into the \
         assertion everyone would prefer and correct §5.3, which is written \
         to describe exactly the hole this test asserts."
    );
}

/// The escalation SPEC §9.6's fork-bomb row does not reach: children that each
/// leave the process group. The existing test covers the in-group shape, which
/// `killpg` catches on its own.
#[test]
fn a_fork_bomb_whose_children_leave_the_group_is_still_stopped() {
    let h = harness();
    let source = r#"
use std::os::unix::process::CommandExt;
fn main() {
    // Not unbounded — RLIMIT_NPROC is per real UID on macOS and setting it
    // would throttle the whole login session (see §5.3) — but every one of
    // these is in a process group of its own, so `killpg` reaches exactly
    // none of them. Before the descendant sweep they all ran to completion
    // after the runner reported the attempt killed.
    for _ in 0..24 {
        let mut command = std::process::Command::new("/bin/sh");
        command.arg("-c").arg("sleep 317");
        command.process_group(0);
        let _ = command.spawn();
    }
    println!("spawned");
    loop { std::hint::spin_loop(); }
}
"#;
    let started = Instant::now();
    let report = run_in(&h, "att_bomb_setsid", source, &spec(3_000, "never\n"));
    let elapsed = started.elapsed();

    assert_eq!(report.verdict, Verdict::Timeout);

    // The assertion with teeth: nothing of ours is left running. The sleep is
    // an odd number of seconds nothing else in the suite uses, so a sibling
    // test's `sleep` cannot be mistaken for one of these.
    std::thread::sleep(std::time::Duration::from_millis(500));
    // `expect`, not `unwrap_or(0)`: a missing `pgrep` would otherwise make
    // this assertion pass having tested nothing, in the same file as
    // `it_is_not_a_sandbox_and_this_test_says_so_out_loud`.
    let found = std::process::Command::new("/usr/bin/pgrep")
        .args(["-f", "sleep 317"])
        .output()
        .expect("pgrep ran; without it this test cannot check anything");
    // pgrep exits 1 when it matches nothing, which is the answer this test
    // wants, and 2 or 3 when it could not do its job at all.
    let code = found.status.code().unwrap_or(-1);
    assert!(
        code == 0 || code == 1,
        "pgrep failed ({code}): {}",
        String::from_utf8_lossy(&found.stderr)
    );
    let survivors = String::from_utf8_lossy(&found.stdout)
        .split_whitespace()
        .count();
    assert_eq!(
        survivors, 0,
        "{survivors} children survived the kill in their own process groups"
    );

    // And the runner still works, which is what §9.6 actually asks.
    let good = run_in(
        &h,
        "att_bomb_setsid_after",
        r#"fn main() { println!("hello, causewaybay"); }"#,
        &spec(30_000, "hello, causewaybay\n"),
    );
    assert_eq!(
        good.verdict,
        Verdict::Accepted,
        "{:?}",
        good.compiler_stderr
    );
    assert!(elapsed.as_secs() < 90, "the whole thing took {elapsed:?}");
}

/// SPEC §5.3 calls `timeout_ms` "a hard wall-clock timeout". It was not one.
///
/// The drain threads end when the **last** holder of the pipe's write end
/// closes it, and everything a submission spawns inherits that pipe. So a
/// submission could set its own clock: spawn something long-lived, and the
/// runner sat in `join()` waiting for it long after it had reported the
/// attempt killed — the reviewer's probe returned at 6.4 s against a 5 s
/// timeout. The join is bounded now, and what it gave up on is exactly what
/// the runner could not kill.
///
/// The margin here is deliberately enormous: the orphan lives thirty seconds,
/// so "the runner waited for it" and "the machine was busy" cannot be confused
/// for one another.
#[test]
fn a_submission_cannot_set_its_own_wall_clock_by_spawning_something() {
    let h = harness();
    let source = r#"
use std::os::unix::process::CommandExt;
fn main() {
    // Orphaned and out of the group — the one thing the sweep cannot reach —
    // holding the stdout pipe it inherited for half a minute.
    let mut command = std::process::Command::new("/bin/sh");
    command.arg("-c").arg("(sleep 30) & exit 0");
    command.process_group(0);
    let mut child = command.spawn().expect("spawn");
    let _ = child.wait();
    std::thread::sleep(std::time::Duration::from_millis(300));
    println!("done");
}
"#;
    let report = run_in(&h, "att_own_clock", source, &spec(10_000, "done\n"));
    assert_eq!(
        report.verdict,
        Verdict::Accepted,
        "the probe did not run: {:?} / {:?}",
        report.compiler_stderr,
        report.runtime_stderr
    );
    assert!(
        report.run_ms < 10_000,
        "a program that printed one line took {} ms, and the only thing still \
         running was a `sleep 30` it left behind. The runner is waiting on a \
         pipe rather than on its own clock.",
        report.run_ms
    );
}
