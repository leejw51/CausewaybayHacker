//! What stops one client degrading the server for everyone else.
//!
//! The server binds `0.0.0.0` by default and the README advertises "many
//! players, one server", so "it is a local trainer" stopped being an answer to
//! this. None of it is a security boundary — SPEC §5.3 is clear that there
//! isn't one — it is the difference between one impatient script and a
//! tailnet full of people watching a spinner.
//!
//! **The numbers are chosen so a person cannot reach them.** A player pressing
//! RUN as fast as a human can press RUN, on a client that fans out a dozen
//! requests on every screen change, must never be throttled: a trainer that
//! tells the player to slow down has failed at the only thing it does. Every
//! limit below is at least an order of magnitude above the fastest plausible
//! hand, and the test `nothing_a_person_can_do_is_throttled` exists to keep it
//! that way.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// Every request on one connection, of any type. Generous: the point is to
/// stop an unattended loop, not to pace a client.
pub const REQUEST_BURST: f64 = 240.0;
pub const REQUEST_PER_SEC: f64 = 60.0;

/// `auth.challenge` before anyone has logged in. Each one mints a nonce that
/// sits in memory for 120 seconds (SPEC §3.2), so this is the one anonymous
/// message that costs the server something to be asked.
pub const CHALLENGE_BURST: f64 = 20.0;
pub const CHALLENGE_PER_SEC: f64 = 1.0;

/// Compiles running at once across **every** connection. The one-execution
/// slot in PROTOCOL §3.2 is per connection, so without this two connections
/// are two compilers, ten are ten, and the machine belongs to whoever opened
/// the most sockets.
pub const MAX_CONCURRENT_EXECUTIONS: usize = 8;
pub const EXECUTION_RETRY_MS: u64 = 2_000;

/// `code.format` deliberately does not take the execution slot — pressing
/// FORMAT while a submit compiles is a normal thing to do (see `ws.rs`) — and
/// that is exactly why a tight loop of it used to spawn `rustfmt` without
/// bound.
pub const MAX_CONCURRENT_FORMATS: usize = 4;
pub const FORMAT_RETRY_MS: u64 = 1_000;

/// A token bucket. Refills continuously, so a client that has been idle gets
/// its whole burst back and a client that never stops gets the steady rate.
#[derive(Debug)]
pub struct Bucket {
    capacity: f64,
    per_sec: f64,
    tokens: f64,
    last: Instant,
}

impl Bucket {
    pub fn new(capacity: f64, per_sec: f64) -> Bucket {
        Bucket {
            capacity,
            per_sec,
            tokens: capacity,
            last: Instant::now(),
        }
    }

    /// Spend one token. `Err(retry_after_ms)` when there is none, carrying how
    /// long until there is — never zero, because a client told to wait 0 ms
    /// has been told nothing.
    pub fn take(&mut self) -> Result<(), u64> {
        self.take_at(Instant::now())
    }

    fn take_at(&mut self, now: Instant) -> Result<(), u64> {
        let elapsed = now.saturating_duration_since(self.last).as_secs_f64();
        self.last = now;
        self.tokens = (self.tokens + elapsed * self.per_sec).min(self.capacity);
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            return Ok(());
        }
        let wait = (1.0 - self.tokens) / self.per_sec;
        Err(((wait * 1000.0).ceil() as u64).max(1))
    }
}

/// One connection's share. Behind mutexes rather than `&mut` because the
/// dispatcher hands pieces of a connection to spawned tasks.
pub struct ConnectionLimits {
    requests: Mutex<Bucket>,
    challenges: Mutex<Bucket>,
}

impl Default for ConnectionLimits {
    fn default() -> Self {
        ConnectionLimits {
            requests: Mutex::new(Bucket::new(REQUEST_BURST, REQUEST_PER_SEC)),
            challenges: Mutex::new(Bucket::new(CHALLENGE_BURST, CHALLENGE_PER_SEC)),
        }
    }
}

impl ConnectionLimits {
    pub fn request(&self) -> Result<(), u64> {
        self.requests.lock().unwrap().take()
    }

    pub fn challenge(&self) -> Result<(), u64> {
        self.challenges.lock().unwrap().take()
    }
}

/// A count of the things happening at once, with a ceiling. Not a queue: over
/// the ceiling the answer is `rate_limited` and the client decides when to
/// come back, because a request parked in a queue looks to a player exactly
/// like a server that has hung.
pub struct Gate {
    limit: usize,
    current: AtomicUsize,
}

impl Gate {
    pub fn new(limit: usize) -> Arc<Gate> {
        Arc::new(Gate {
            limit,
            current: AtomicUsize::new(0),
        })
    }

    /// A pass, or `None` if the gate is full. The pass gives it back when
    /// dropped — including when the task holding it panics, which is the
    /// reason it is a guard and not a pair of calls.
    pub fn enter(self: &Arc<Self>) -> Option<Pass> {
        let mut seen = self.current.load(Ordering::SeqCst);
        loop {
            if seen >= self.limit {
                return None;
            }
            match self.current.compare_exchange_weak(
                seen,
                seen + 1,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return Some(Pass { gate: self.clone() }),
                Err(actual) => seen = actual,
            }
        }
    }

    pub fn in_use(&self) -> usize {
        self.current.load(Ordering::SeqCst)
    }
}

pub struct Pass {
    gate: Arc<Gate>,
}

impl Drop for Pass {
    fn drop(&mut self) {
        self.gate.current.fetch_sub(1, Ordering::SeqCst);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn a_bucket_refills_and_reports_how_long_to_wait() {
        let start = Instant::now();
        let mut bucket = Bucket::new(3.0, 10.0);
        for _ in 0..3 {
            assert!(bucket.take_at(start).is_ok());
        }
        let wait = bucket.take_at(start).expect_err("the burst is spent");
        assert!(wait > 0, "a retry_after_ms of zero tells a client nothing");
        assert!(wait <= 100, "10 a second means 100 ms, not {wait}");

        // And after that long, there is one.
        assert!(bucket.take_at(start + Duration::from_millis(wait)).is_ok());
    }

    #[test]
    fn a_bucket_never_fills_past_its_burst() {
        let start = Instant::now();
        let mut bucket = Bucket::new(3.0, 10.0);
        assert!(bucket.take_at(start + Duration::from_secs(3600)).is_ok());
        for _ in 0..2 {
            assert!(bucket.take_at(start + Duration::from_secs(3600)).is_ok());
        }
        assert!(bucket.take_at(start + Duration::from_secs(3600)).is_err());
    }

    #[test]
    fn a_gate_hands_the_pass_back_when_it_is_dropped() {
        let gate = Gate::new(2);
        let a = gate.enter().expect("first");
        let b = gate.enter().expect("second");
        assert!(gate.enter().is_none(), "the gate is full");
        drop(a);
        let c = gate.enter().expect("a pass came back");
        assert_eq!(gate.in_use(), 2);
        drop((b, c));
        assert_eq!(gate.in_use(), 0);
    }
}
