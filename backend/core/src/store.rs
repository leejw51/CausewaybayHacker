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

    /// A poisoned mutex means a previous caller panicked mid-statement. The
    /// connection itself is still usable — SQLite's state is in the file, not
    /// in the guard — and refusing to serve anything ever again is a worse
    /// answer than carrying on.
    pub fn conn(&self) -> MutexGuard<'_, Connection> {
        match self.conn.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}
