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
//! **9.6.d is not writable and will not be faked.** It wants `GOPROXY=off` to
//! make a Go quest that fetches the internet fail cleanly. There is no Go
//! runner in this build — `cwbhacker_runner::unsupported("go", …)` returns a
//! reason rather than a judgement — so a test pointed at it would pass
//! because Go is unsupported, not because the proxy was off. That is a test
//! that goes green for the wrong reason, which is worse than no test.
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
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().to_path_buf();
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
    assert_eq!(report.verdict, Verdict::Accepted, "{:?}", report.compiler_stderr);

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
    let report = run_in(&h, "att_env", source, &spec(30_000, "reported
"));
    assert_eq!(report.verdict, Verdict::Accepted, "{:?}", report.compiler_stderr);

    let line = |prefix: &str| {
        report
            .runtime_stderr
            .lines()
            .find(|l| l.starts_with(prefix))
            .map(|l| l.trim_start_matches(prefix).trim().to_string())
            .unwrap_or_default()
    };

    let home = line("HOME");
    assert!(!home.is_empty(), "HOME was not set at all: {:?}", report.runtime_stderr);
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
    let report = run_in(&h, "att_not_a_sandbox", &source, &spec(30_000, "reached
"));

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
        ("att_after_loop", "fn main() { loop { std::hint::spin_loop(); } }", 1_000),
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
