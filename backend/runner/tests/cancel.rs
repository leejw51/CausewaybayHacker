//! STOP: `run.cancel` reaching the child (PROTOCOL `run.cancel`).
//!
//! `proc::run` against `sh` directly, so these are fast: what is under test
//! is the supervision, not a compiler. Unix only, like the kill they test.
#![cfg(unix)]

use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cwbhacker_runner::proc::{self, cancel_on, no_logs, Limits};

fn sleeper(secs: u32) -> Command {
    let mut c = Command::new("sh");
    c.arg("-c").arg(format!("sleep {secs}"));
    c
}

fn limits() -> Limits {
    Limits {
        timeout: Duration::from_secs(30),
        ..Limits::default()
    }
}

#[test]
fn a_cancel_mid_run_stops_the_child_well_inside_its_clock() {
    let flag = Arc::new(AtomicBool::new(false));
    let guard = cancel_on(flag.clone());
    let setter = {
        let flag = flag.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            flag.store(true, Ordering::SeqCst);
        })
    };
    let t0 = Instant::now();
    let out = proc::run(sleeper(30), b"", &limits(), "stdout", "stderr", no_logs()).unwrap();
    setter.join().unwrap();
    assert!(out.cancelled, "the outcome says it was cancelled: {out:?}");
    assert!(!out.timed_out, "and not that it timed out");
    assert!(guard.fired(), "the guard saw a child stopped for it");
    // 300 ms to the ask, then SIGTERM — `sleep` dies on it — well before 30 s.
    assert!(
        t0.elapsed() < Duration::from_secs(5),
        "took {:?}",
        t0.elapsed()
    );
}

#[test]
fn a_cancel_before_the_child_exists_never_starts_it() {
    let flag = Arc::new(AtomicBool::new(true));
    let guard = cancel_on(flag);
    let t0 = Instant::now();
    let out = proc::run(sleeper(30), b"", &limits(), "stdout", "stderr", no_logs()).unwrap();
    assert!(out.cancelled);
    assert_eq!(out.exit_code, None, "nothing ran, so nothing exited");
    assert!(guard.fired());
    assert!(t0.elapsed() < Duration::from_secs(1));
}

#[test]
fn a_dropped_guard_leaves_nothing_behind_on_the_thread() {
    // The server's runs are on pooled threads: a flag left set by one run
    // must not stop the next run on the same thread.
    let flag = Arc::new(AtomicBool::new(true));
    {
        let _guard = cancel_on(flag.clone());
    }
    let out = proc::run(
        {
            let mut c = Command::new("sh");
            c.arg("-c").arg("echo hi");
            c
        },
        b"",
        &limits(),
        "stdout",
        "stderr",
        no_logs(),
    )
    .unwrap();
    assert!(!out.cancelled);
    assert_eq!(out.exit_code, Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "hi\n");
}

#[test]
fn a_cancel_after_the_child_finished_stopped_nothing() {
    let flag = Arc::new(AtomicBool::new(false));
    let guard = cancel_on(flag.clone());
    let out = proc::run(
        {
            let mut c = Command::new("sh");
            c.arg("-c").arg("true");
            c
        },
        b"",
        &limits(),
        "stdout",
        "stderr",
        no_logs(),
    )
    .unwrap();
    flag.store(true, Ordering::SeqCst);
    assert!(!out.cancelled);
    assert!(
        !guard.fired(),
        "set after the last child finished: nothing was stopped, so the run is not 'cancelled'"
    );
}
