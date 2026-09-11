//! The store: one home, one connection, held together.
//!
//! One connection behind a mutex is enough for a single-user local trainer and
//! it keeps WAL's writer rules trivially satisfied. The guard is never held
//! across an await — the server does its database work in short synchronous
//! blocks and its waiting somewhere else.

use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use rusqlite::Connection;

use crate::error::Result;
use crate::paths::Home;

pub struct Store {
    home: Home,
    conn: Mutex<Connection>,
}

impl Store {
    /// Open (or create) the home and the database inside it.
    pub fn open(root: &Path) -> Result<Store> {
        let home = Home::open(root)?;
        let conn = crate::db::open(&home.db_path())?;
        Ok(Store {
            home,
            conn: Mutex::new(conn),
        })
    }

    /// A store with no disk behind the database, for tests. The home is still
    /// real, because attempts and profiles are written to it.
    pub fn open_memory(root: &Path) -> Result<Store> {
        let home = Home::open(root)?;
        let conn = crate::db::open_memory()?;
        Ok(Store {
            home,
            conn: Mutex::new(conn),
        })
    }

    pub fn home(&self) -> &Home {
        &self.home
    }

    /// Borrow the connection for one scope. **Prefer this to `conn()`**: the
    /// guard's lifetime is the closure's, so it cannot be accidentally held
    /// across a call that wants its own.
    ///
    /// ```ignore
    /// let quest = store.with_conn(|conn| quests::get(conn, id))?;
    /// ```
    pub fn with_conn<T>(&self, f: impl FnOnce(&Connection) -> T) -> T {
        let guard = self.conn();
        f(&guard)
    }

    /// The same, for the handful of callers that need `&mut` — a transaction,
    /// mostly.
    pub fn with_conn_mut<T>(&self, f: impl FnOnce(&mut Connection) -> T) -> T {
        let mut guard = self.conn();
        f(&mut guard)
    }

    /// **The guard is not reentrant.** Taking it twice on one thread — most
    /// easily by holding it while calling a helper that takes its own — is a
    /// deadlock, and a plain mutex would hang rather than panic, which is a
    /// nastier way to lose an afternoon than a stack trace. It has cost two
    /// agents ten minutes each, so the second take now **panics with the name
    /// of the remedy** instead of hanging. Take it in short scopes, or use
    /// `with_conn`.
    ///
    /// A poisoned mutex means a previous caller panicked mid-statement. The
    /// connection itself is still usable — SQLite's state is in the file, not
    /// in the guard — and refusing to serve anything ever again is a worse
    /// answer than carrying on.
    pub fn conn(&self) -> Conn<'_> {
        let token = self as *const Store as usize;
        HELD.with(|held| {
            if held.borrow().contains(&token) {
                panic!(
                    "Store::conn() was taken twice on one thread. The guard is not \
                     reentrant, so this would have deadlocked: a helper further down \
                     this stack takes its own. Narrow the outer scope, or pass the \
                     &Connection you already have — Store::with_conn(|conn| ..) makes \
                     the scope explicit."
                );
            }
        });
        let guard = match self.conn.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        HELD.with(|held| held.borrow_mut().push(token));
        Conn { guard, token }
    }
}

thread_local! {
    /// Which stores this thread is currently inside. A `Vec` rather than a
    /// flag because a process may hold more than one `Store` — the tests do —
    /// and only *the same* store taken twice is the deadlock.
    static HELD: std::cell::RefCell<Vec<usize>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// The connection, borrowed. Derefs to `rusqlite::Connection`, so every
/// existing call site — `conn.prepare(..)`, `&conn`, `&*conn` — is unchanged;
/// what it adds over a bare `MutexGuard` is that dropping it tells the
/// reentrance check this thread has let go.
pub struct Conn<'a> {
    guard: MutexGuard<'a, Connection>,
    token: usize,
}

impl std::ops::Deref for Conn<'_> {
    type Target = Connection;
    fn deref(&self) -> &Connection {
        &self.guard
    }
}

impl std::ops::DerefMut for Conn<'_> {
    fn deref_mut(&mut self) -> &mut Connection {
        &mut self.guard
    }
}

impl Drop for Conn<'_> {
    fn drop(&mut self) {
        let token = self.token;
        // `try_with`, because a thread tearing down can have destroyed the
        // thread-local already; losing the bookkeeping on a dying thread costs
        // nothing.
        let _ = HELD.try_with(|held| {
            let mut held = held.borrow_mut();
            if let Some(i) = held.iter().rposition(|t| *t == token) {
                held.remove(i);
            }
        });
    }
}
