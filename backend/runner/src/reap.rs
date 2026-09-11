//! Finding and killing what a submission left behind (SPEC §5.3).
//!
//! `killpg` is aimed at one process group, and a process can leave a process
//! group: `Command::process_group(0)`, `setsid(2)`, `setpgid(2)`. A submission
//! that spawns a grandchild in a new group is not covered by the group kill at
//! all, and the escalation is a fork bomb whose children each `setsid` — which
//! would keep multiplying after the runner reported it dead.
//!
//! So the runner does not only kill a group. It **watches the process table
//! for the life of the attempt** and remembers every process that was, at any
//! moment, a descendant of the submission or a member of its group. At the end
//! — any end: a clean exit, the output cap, the timeout — everything on that
//! list that is still alive is killed by pid.
//!
//! **What this is not.** It is not containment, and the day someone reads it
//! as containment is the day it becomes dangerous:
//!
//! * A process born **and** orphaned between two samples (100 ms apart) is
//!   never recorded, and once its parent is gone the kernel has thrown away
//!   the link that would have found it. Nothing short of a real sandbox — a
//!   cgroup, a jail — fixes that, and this project has deliberately not built
//!   one.
//! * The table is sampled, not subscribed to. There is no `PR_SET_PDEATHSIG`
//!   on darwin and no process-tree kill.
//! * It is darwin and linux only. Everywhere else this is a no-op and the
//!   group kill is all there is.
//!
//! Pid reuse is handled rather than hoped about: every recorded pid carries
//! the process's start time, and a pid whose start time no longer matches is
//! somebody else's process and is left alone.

use std::collections::HashMap;
use std::time::{Duration, Instant};

/// How often the process table is walked while an attempt runs. The window a
/// process can be born and orphaned inside — and so the size of the hole.
const SAMPLE_EVERY: Duration = Duration::from_millis(100);

/// A fork bomb is a hostile *input*, not a licence to allocate without bound:
/// the tracker must not be the thing that takes the machine down.
const MAX_TRACKED: usize = 4096;

/// One row of the process table, reduced to what a reaper needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Row {
    pub pid: i32,
    pub ppid: i32,
    pub pgid: i32,
    /// Seconds and microseconds of the process's start, or a monotonic tick on
    /// platforms that report one. Only ever compared for equality: it is an
    /// identity, not a time.
    pub start: (u64, u64),
}

/// The descendants of one submission, as they were seen over its lifetime.
pub struct Tracker {
    root: i32,
    seen: HashMap<i32, (u64, u64)>,
    last: Option<Instant>,
    full: bool,
}

impl Tracker {
    pub fn new(root: i32) -> Tracker {
        Tracker {
            root,
            seen: HashMap::new(),
            last: None,
            full: false,
        }
    }

    /// How many distinct descendants have been seen. Diagnostics, and the
    /// thing a test can assert about.
    pub fn tracked(&self) -> usize {
        self.seen.len()
    }

    pub fn sample_if_due(&mut self) {
        let due = match self.last {
            None => true,
            Some(last) => last.elapsed() >= SAMPLE_EVERY,
        };
        if due {
            self.sample();
        }
    }

    pub fn sample(&mut self) {
        let _ = self.sample_table();
    }

    /// Sample, and hand back the table that was read so a caller can use it
    /// without walking the process list a second time. `None` means the table
    /// could not be read at all — which is **not** the same as "there is
    /// nothing there", and the difference matters below.
    fn sample_table(&mut self) -> Option<Vec<Row>> {
        self.last = Some(Instant::now());
        let table = snapshot();
        if table.is_empty() {
            return None;
        }
        self.absorb(&table);
        Some(table)
    }

    /// Everything in `table` that belongs to this attempt: a member of the
    /// submission's process group, a child of the submission, or a child of
    /// anything already known. Repeated to a fixpoint because the table comes
    /// back in no useful order — a grandchild can appear before its parent.
    fn absorb(&mut self, table: &[Row]) {
        loop {
            let mut added = false;
            for row in table {
                if row.pid == self.root || row.pid <= 1 {
                    continue;
                }
                let ours = row.pgid == self.root
                    || row.ppid == self.root
                    || self.seen.contains_key(&row.ppid);
                if ours && !self.seen.contains_key(&row.pid) {
                    if self.seen.len() >= MAX_TRACKED {
                        self.full = true;
                        return;
                    }
                    self.seen.insert(row.pid, row.start);
                    added = true;
                }
            }
            if !added {
                return;
            }
        }
    }

    /// Whether the tracker gave up recording. If this is true the sweep below
    /// is incomplete and says so, rather than reporting success.
    pub fn overflowed(&self) -> bool {
        self.full
    }

    /// Stop every known descendant that is **outside** the submission's
    /// process group, so it cannot fork while the group kill runs.
    ///
    /// In-group processes are deliberately left running: SPEC §5.3 promises
    /// them a SIGTERM and 500 ms of grace, and a stopped process does not
    /// handle SIGTERM, so stopping them would quietly delete the grace.
    ///
    /// Repeated to a fixpoint (bounded), because a process that is still
    /// running can fork one more while we work.
    pub fn freeze_escapees(&mut self) {
        for _ in 0..5 {
            let Some(table) = self.sample_table() else {
                return;
            };
            let mut stopped = 0usize;
            for row in matching(&table, &self.seen) {
                if row.pgid != self.root {
                    // SAFETY: a signal to a pid whose identity we verified
                    // against its start time, owned by this user.
                    unsafe {
                        libc::kill(row.pid, libc::SIGSTOP);
                    }
                    stopped += 1;
                }
            }
            if stopped == 0 {
                return;
            }
        }
    }

    /// SIGKILL everything still alive that this attempt ever started. Safe to
    /// call on a clean exit as well as after a timeout: a submission that
    /// returns 0 having left `sleep 120` behind is still a submission that has
    /// left something behind, and it would otherwise hold the output pipe open
    /// for two minutes.
    ///
    /// Returns how many were killed, which is `0` for the overwhelming
    /// majority of attempts.
    pub fn kill_strays(&mut self) -> usize {
        let mut killed = 0usize;
        let mut table_read = false;
        for _ in 0..3 {
            // "No strays" and "no answer from the kernel" are different
            // things, and an empty `Vec` is how both would look. Conflating
            // them would leave anything `freeze_escapees` stopped stopped for
            // ever — holding the output pipe, never dying, which is a worse
            // outcome than the escape this module is about.
            let Some(table) = self.sample_table() else {
                std::thread::sleep(Duration::from_millis(20));
                continue;
            };
            table_read = true;
            let rows = matching(&table, &self.seen);
            if rows.is_empty() {
                break;
            }
            for row in rows {
                // SIGKILL, not SIGTERM: these are the ones that were already
                // given the grace, or never had a claim to it. It is delivered
                // to a stopped process, so freezing them first costs nothing.
                unsafe {
                    libc::kill(row.pid, libc::SIGKILL);
                }
                killed += 1;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        if !table_read {
            // The table never came back, so nothing was verified and nothing
            // was killed. Let anything that was stopped run again: SIGCONT is
            // a no-op for a process that was never stopped and for one whose
            // pid has since been recycled, which is why it is the one signal
            // worth sending unverified.
            for pid in self.seen.keys() {
                unsafe {
                    libc::kill(*pid, libc::SIGCONT);
                }
            }
        }
        killed
    }
}

/// The rows of a table whose pid **and start time** match something we
/// recorded. The start time is the whole point: a pid on its own is a promise
/// the kernel does not keep, and killing a recycled one would be the runner
/// shooting a stranger.
fn matching(table: &[Row], seen: &HashMap<i32, (u64, u64)>) -> Vec<Row> {
    table
        .iter()
        .copied()
        .filter(|row| seen.get(&row.pid) == Some(&row.start))
        .collect()
}

// --------------------------------------------------------------- the table

#[cfg(target_os = "macos")]
pub fn snapshot() -> Vec<Row> {
    const PROC_ALL_PIDS: u32 = 1;
    let info_size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: every call below is given a buffer it owns and the length of it.
    unsafe {
        let wanted = libc::proc_listpids(PROC_ALL_PIDS, 0, std::ptr::null_mut(), 0);
        if wanted <= 0 {
            return Vec::new();
        }
        // Headroom: the table can grow between asking the size and reading it.
        let slots = wanted as usize / std::mem::size_of::<i32>() + 128;
        let mut pids = vec![0i32; slots];
        let got = libc::proc_listpids(
            PROC_ALL_PIDS,
            0,
            pids.as_mut_ptr() as *mut libc::c_void,
            (slots * std::mem::size_of::<i32>()) as libc::c_int,
        );
        if got <= 0 {
            return Vec::new();
        }
        pids.truncate(got as usize / std::mem::size_of::<i32>());

        let uid = libc::getuid();
        let mut rows = Vec::with_capacity(pids.len());
        for pid in pids {
            if pid <= 0 {
                continue;
            }
            let mut info: libc::proc_bsdinfo = std::mem::zeroed();
            let n = libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                &mut info as *mut _ as *mut libc::c_void,
                info_size,
            );
            // A process that died between the listing and the query, or one
            // this user may not look at. Either way, not ours.
            if n != info_size || info.pbi_uid != uid {
                continue;
            }
            rows.push(Row {
                pid: info.pbi_pid as i32,
                ppid: info.pbi_ppid as i32,
                pgid: info.pbi_pgid as i32,
                start: (info.pbi_start_tvsec, info.pbi_start_tvusec),
            });
        }
        rows
    }
}

#[cfg(target_os = "linux")]
pub fn snapshot() -> Vec<Row> {
    let mut rows = Vec::new();
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return rows;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Ok(pid) = name.parse::<i32>() else {
            continue;
        };
        let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
            continue;
        };
        // `comm` is in parentheses and may itself contain spaces and
        // parentheses, so everything is read from the *last* ')'.
        let Some(close) = stat.rfind(')') else {
            continue;
        };
        let fields: Vec<&str> = stat[close + 1..].split_whitespace().collect();
        // After comm: state(0) ppid(1) pgrp(2) … starttime(19).
        if fields.len() < 20 {
            continue;
        }
        let (Ok(ppid), Ok(pgid), Ok(start)) = (
            fields[1].parse::<i32>(),
            fields[2].parse::<i32>(),
            fields[19].parse::<u64>(),
        ) else {
            continue;
        };
        rows.push(Row {
            pid,
            ppid,
            pgid,
            start: (start, 0),
        });
    }
    rows
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub fn snapshot() -> Vec<Row> {
    // No table, no sweep. The group kill is the whole of the containment here
    // and SPEC §5.3 says so.
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_process_table_can_be_read_and_contains_this_process() {
        let table = snapshot();
        assert!(
            !table.is_empty(),
            "the process table came back empty; the sweep in §5.3 is a no-op \
             on this platform and the spec has to say so"
        );
        let me = std::process::id() as i32;
        let mine = table
            .iter()
            .find(|row| row.pid == me)
            .expect("this test process is not in its own process table");
        assert!(mine.ppid > 0);
        assert_ne!(mine.start, (0, 0), "a start time is the pid-reuse guard");
    }

    #[test]
    fn a_descendant_is_recorded_and_a_stranger_is_not() {
        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "sleep 30"])
            .spawn()
            .expect("spawn");
        let pid = child.id() as i32;

        let mut tracker = Tracker::new(std::process::id() as i32);
        // Give the shell a moment to exist in the table.
        std::thread::sleep(Duration::from_millis(100));
        tracker.sample();
        assert!(
            tracker.seen.contains_key(&pid),
            "a direct child was not recorded"
        );
        assert!(
            !tracker.seen.contains_key(&1),
            "launchd is not a descendant of this test"
        );

        let killed = tracker.kill_strays();
        assert!(killed >= 1, "the child was not killed");
        let _ = child.wait();
    }

    #[test]
    fn a_recycled_pid_is_not_killed() {
        // The guard that makes killing by pid safe at all: a recorded pid
        // whose start time no longer matches belongs to somebody else.
        let me = std::process::id() as i32;
        let mut seen = HashMap::new();
        seen.insert(me, (1, 1)); // a start time this process cannot have
        let table = snapshot();
        assert!(
            matching(&table, &seen).is_empty(),
            "a pid with the wrong start time was treated as ours"
        );
        let real = table.iter().find(|r| r.pid == me).copied().unwrap();
        seen.insert(me, real.start);
        assert_eq!(matching(&table, &seen).len(), 1);
    }
}
