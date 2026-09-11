//! Supervising one child process (SPEC §5.3).
//!
//! Wall-clock timeout with a SIGTERM grace then SIGKILL, an output byte cap
//! enforced **while draining** rather than after, `setrlimit` where the
//! platform actually provides it, and its own process group.
//!
//! The process group alone is not enough and used not to say so: a grandchild
//! that calls `setsid` or spawns with `process_group(0)` is not in the group
//! the kill is aimed at, and outlived it. So the group kill is now one of
//! three layers — see `reap.rs` for the descendant sweep that backs it up and,
//! more importantly, for the exact hole that is left.
//!
//! The other thing a runaway descendant used to do is hold the stdout pipe it
//! inherited, so `run` waited for it and a submission could set its own
//! wall clock by spawning something long-lived. The drain threads are now
//! joined with a bound.
//!
//! This is not a sandbox and does not pretend to be one. It is the set of
//! limits that stops an honest mistake — an infinite loop, a runaway
//! `println!` — from taking the machine with it.

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::reap::Tracker;

/// Called with (`"compile"` | `"stdout"` | `"stderr"`, chunk) as output
/// arrives, so the player watches `rustc` think instead of a spinner (§5.4).
pub type LogSink = Arc<dyn Fn(&str, &str) + Send + Sync>;

pub fn no_logs() -> LogSink {
    Arc::new(|_, _| {})
}

#[derive(Debug, Clone)]
pub struct Limits {
    pub timeout: Duration,
    pub max_stdout: usize,
    pub max_stderr: usize,
    /// 1 GiB of address space and 64 MiB of file size, per §5.3. Skipped for
    /// the compiler, which legitimately wants more than a quest's binary.
    pub apply_rlimits: bool,
    /// The address-space half of `apply_rlimits`, separable for exactly one
    /// caller: a `-race` test binary reserves tens of gigabytes of *virtual*
    /// address space before it runs a line, so a 1 GiB `RLIMIT_AS` does not
    /// limit it, it deletes it. The file-size cap still applies, and so does
    /// everything else in §5.3 — the timeout, the process group, the output
    /// cap, the stripped environment.
    ///
    /// On darwin this is moot in both directions: `setrlimit(RLIMIT_AS)`
    /// returns `EINVAL` there, so the cap is already a no-op. On Linux it is
    /// the difference between a race quest running and a race quest dying
    /// instantly with a signal nobody can explain.
    pub address_space: bool,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            timeout: Duration::from_secs(5),
            max_stdout: 262_144,
            max_stderr: 1_048_576,
            apply_rlimits: true,
            address_space: true,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct Outcome {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub timed_out: bool,
    pub stdout_overflow: bool,
    pub elapsed_ms: u64,
    /// Bytes the child actually produced, before the cap threw the rest away.
    pub stdout_produced: usize,
    /// Descendants that were still alive when the attempt ended and had to be
    /// killed by pid — the ones `killpg` could not reach because they had left
    /// the process group, plus anything a clean exit left behind. Zero for the
    /// overwhelming majority of attempts.
    pub strays_killed: usize,
}

impl Outcome {
    pub fn ok(&self) -> bool {
        !self.timed_out && !self.stdout_overflow && self.exit_code == Some(0)
    }
}

const RLIMIT_AS_BYTES: u64 = 1024 * 1024 * 1024;
const RLIMIT_FSIZE_BYTES: u64 = 64 * 1024 * 1024;

pub fn run(
    mut command: Command,
    stdin_data: &[u8],
    limits: &Limits,
    stdout_label: &str,
    stderr_label: &str,
    logs: LogSink,
) -> std::io::Result<Outcome> {
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // Its own process group: killing the group takes the children a fork
        // bomb spawned, which killing the pid alone would not.
        command.process_group(0);
        if limits.apply_rlimits {
            let address_space = limits.address_space;
            let apply = move || {
                // SAFETY: setrlimit is async-signal-safe and touches only this
                // freshly forked child, between fork and exec.
                unsafe {
                    if address_space {
                        set_rlimit(libc::RLIMIT_AS, RLIMIT_AS_BYTES);
                    }
                    set_rlimit(libc::RLIMIT_FSIZE, RLIMIT_FSIZE_BYTES);
                }
                // RLIMIT_NPROC is deliberately not set. On macOS it is per
                // real UID, not per process: a low value here locks the whole
                // login session out of forking, including the server itself.
                // §5.3 says "where the platform provides it", and this is the
                // platform not providing it.
                Ok(())
            };
            unsafe {
                command.pre_exec(apply);
            }
        }
    }

    let started = Instant::now();
    let mut child = command.spawn()?;
    let pid = child.id() as i32;

    // Feed stdin from its own thread: a case whose input is larger than the
    // pipe buffer deadlocks if the parent writes it inline while the child is
    // already blocked writing output.
    if let Some(mut sink) = child.stdin.take() {
        let data = stdin_data.to_vec();
        std::thread::spawn(move || {
            let _ = sink.write_all(&data);
            let _ = sink.flush();
        });
    }

    let overflow = Arc::new(AtomicBool::new(false));
    let produced = Arc::new(AtomicUsize::new(0));

    let stdout_buf = Arc::new(Mutex::new(Vec::new()));
    let stderr_buf = Arc::new(Mutex::new(Vec::new()));

    let stdout_handle = child.stdout.take().map(|pipe| {
        drain(
            pipe,
            stdout_buf.clone(),
            limits.max_stdout,
            Some((overflow.clone(), produced.clone())),
            stdout_label.to_string(),
            logs.clone(),
        )
    });
    let stderr_handle = child.stderr.take().map(|pipe| {
        drain(
            pipe,
            stderr_buf.clone(),
            limits.max_stderr,
            None,
            stderr_label.to_string(),
            logs.clone(),
        )
    });

    // Watch the process table for the life of the attempt, so that a
    // descendant which leaves the process group is still on a list when the
    // time comes to kill it (`reap.rs`).
    let mut tracker = Tracker::new(pid);

    let mut timed_out = false;
    let status = loop {
        // Before `try_wait`, always: once the child is reaped its pid is free
        // to be handed to somebody else, and a sample taken after that could
        // record a stranger.
        tracker.sample_if_due();
        if let Some(status) = child.try_wait()? {
            break Some(status);
        }
        if overflow.load(Ordering::Relaxed) {
            // The cap is enforced the moment it is crossed, not after the
            // child has finished writing a gigabyte into memory.
            stop_and_kill(&mut tracker, pid);
            break child.wait().ok();
        }
        if started.elapsed() >= limits.timeout {
            timed_out = true;
            stop_and_kill(&mut tracker, pid);
            break child.wait().ok();
        }
        std::thread::sleep(Duration::from_millis(5));
    };

    // On every path, including a clean exit: a submission that returned 0
    // having left `sleep 120` behind has still left it behind, and it is
    // holding the pipe this function is about to wait on.
    let strays_killed = tracker.kill_strays();
    if strays_killed > 0 {
        // Worth a line in `logs/server.jsonl`: it is the only evidence that
        // something outran the group kill, and the number is 0 for every
        // ordinary attempt.
        tracing::warn!(
            pid,
            strays_killed,
            incomplete = tracker.overflowed(),
            "the attempt left processes behind and they were killed by pid"
        );
    }

    // Bounded, and that is the point. The drain threads end when the *last*
    // holder of the write end closes it, which is not necessarily the child —
    // anything it spawned inherited the same pipe. Waiting for them without a
    // bound let a submission choose its own wall clock, which is the opposite
    // of what §5.3 promises. The buffers are shared, so what did arrive is
    // already in them; an abandoned thread writes into an `Arc` nobody reads.
    // One deadline for both, not one each: the promise is that `run` returns
    // within half a second of the kill, and two sequential half-seconds would
    // make it a whole one.
    let drained_by = Instant::now() + Duration::from_millis(500);
    join_bounded(stdout_handle, drained_by);
    join_bounded(stderr_handle, drained_by);

    let exit_code = status.as_ref().and_then(|s| s.code());
    let signal = signal_of(status.as_ref());

    let stdout = std::mem::take(&mut *stdout_buf.lock().unwrap());
    let stderr = std::mem::take(&mut *stderr_buf.lock().unwrap());

    Ok(Outcome {
        stdout,
        stderr,
        exit_code,
        signal,
        timed_out,
        stdout_overflow: overflow.load(Ordering::Relaxed),
        elapsed_ms: started.elapsed().as_millis() as u64,
        stdout_produced: produced.load(Ordering::Relaxed),
        strays_killed,
    })
}

/// The kill, in the order that survives a process which is still forking.
///
/// 1. Stop the descendants that have left the process group, so they cannot
///    fork while the rest of this runs.
/// 2. The documented path for the group itself: SIGTERM, 500 ms of grace,
///    SIGKILL (SPEC §5.3). In-group processes are deliberately *not* stopped
///    first — a stopped process does not handle SIGTERM, so stopping them
///    would delete the grace the spec promises.
/// 3. The stopped escapees are killed by `kill_strays` on the way out. SIGKILL
///    is delivered to a stopped process, so freezing them first costs nothing.
fn stop_and_kill(tracker: &mut Tracker, pid: i32) {
    tracker.freeze_escapees();
    kill_group(pid);
}

/// Join a drain thread, or give up on it and let it run detached.
fn join_bounded(handle: Option<std::thread::JoinHandle<()>>, deadline: Instant) {
    let Some(handle) = handle else { return };
    while Instant::now() < deadline {
        if handle.is_finished() {
            let _ = handle.join();
            return;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    // Dropped, not joined: the thread is blocked in `read` on a pipe somebody
    // we could not kill is still holding, and this function has a promise to
    // keep about when it returns.
    drop(handle);
}

fn drain<R: Read + Send + 'static>(
    mut pipe: R,
    buf: Arc<Mutex<Vec<u8>>>,
    cap: usize,
    overflow: Option<(Arc<AtomicBool>, Arc<AtomicUsize>)>,
    label: String,
    logs: LogSink,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut chunk = [0u8; 8192];
        loop {
            match pipe.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let slice = &chunk[..n];
                    let total = {
                        let mut guard = buf.lock().unwrap();
                        let room = cap.saturating_sub(guard.len());
                        if room > 0 {
                            guard.extend_from_slice(&slice[..room.min(n)]);
                        }
                        guard.len()
                    };
                    if let Some((flag, produced)) = overflow.as_ref() {
                        let seen = produced.fetch_add(n, Ordering::Relaxed) + n;
                        if seen > cap {
                            flag.store(true, Ordering::Relaxed);
                        }
                    } else if total >= cap {
                        // stderr is capped but not fatal: the compiler is
                        // allowed to be verbose.
                    }
                    logs(&label, &String::from_utf8_lossy(slice));
                }
            }
        }
    })
}

#[cfg(unix)]
fn kill_group(pid: i32) {
    // SIGTERM, 500 ms of grace, then SIGKILL (§5.3).
    unsafe {
        libc::killpg(pid, libc::SIGTERM);
    }
    let deadline = Instant::now() + Duration::from_millis(500);
    while Instant::now() < deadline {
        unsafe {
            if libc::killpg(pid, 0) != 0 {
                return;
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    unsafe {
        libc::killpg(pid, libc::SIGKILL);
    }
}

#[cfg(not(unix))]
fn kill_group(_pid: i32) {}

#[cfg(unix)]
fn signal_of(status: Option<&std::process::ExitStatus>) -> Option<i32> {
    use std::os::unix::process::ExitStatusExt;
    status.and_then(|s| s.signal())
}

#[cfg(not(unix))]
fn signal_of(_status: Option<&std::process::ExitStatus>) -> Option<i32> {
    None
}

#[cfg(unix)]
unsafe fn set_rlimit(resource: libc::c_int, value: u64) {
    let mut current = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    if libc::getrlimit(resource, &mut current) != 0 {
        return;
    }
    // Never raise a limit, only lower one: the hard limit is the ceiling and
    // asking above it fails the whole call.
    let hard = current.rlim_max;
    let want = value as libc::rlim_t;
    let cur = if hard != libc::RLIM_INFINITY && want > hard {
        hard
    } else {
        want
    };
    let limit = libc::rlimit {
        rlim_cur: cur,
        rlim_max: hard,
    };
    libc::setrlimit(resource, &limit);
}
