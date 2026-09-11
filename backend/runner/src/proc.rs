//! Supervising one child process (SPEC §5.3).
//!
//! Wall-clock timeout with a SIGTERM grace then SIGKILL, an output byte cap
//! enforced **while draining** rather than after, `setrlimit` where the
//! platform actually provides it, and its own process group so a fork bomb
//! dies with its parent.
//!
//! This is not a sandbox and does not pretend to be one. It is the set of
//! limits that stops an honest mistake — an infinite loop, a runaway
//! `println!` — from taking the machine with it.

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

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
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            timeout: Duration::from_secs(5),
            max_stdout: 262_144,
            max_stderr: 1_048_576,
            apply_rlimits: true,
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
            let apply = move || {
                // SAFETY: setrlimit is async-signal-safe and touches only this
                // freshly forked child, between fork and exec.
                unsafe {
                    set_rlimit(libc::RLIMIT_AS, RLIMIT_AS_BYTES);
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

    let mut timed_out = false;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break Some(status);
        }
        if overflow.load(Ordering::Relaxed) {
            // The cap is enforced the moment it is crossed, not after the
            // child has finished writing a gigabyte into memory.
            kill_group(pid);
            break child.wait().ok();
        }
        if started.elapsed() >= limits.timeout {
            timed_out = true;
            kill_group(pid);
            break child.wait().ok();
        }
        std::thread::sleep(Duration::from_millis(5));
    };

    if let Some(handle) = stdout_handle {
        let _ = handle.join();
    }
    if let Some(handle) = stderr_handle {
        let _ = handle.join();
    }

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
    })
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
