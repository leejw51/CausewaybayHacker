-- 0001_init — the whole schema of SPEC §2.1, verbatim, plus the FTS5 triggers
-- §2.1 asks for in a comment and does not spell out.
--
-- Forward-only. Never edit this file once it has shipped; add 0002_*.sql.

-- ---------- identity ----------
CREATE TABLE users (
  address       TEXT PRIMARY KEY,          -- lowercase 0x hex, 42 chars (§3.4)
  address_eip55 TEXT NOT NULL,             -- the checksummed form, for display
  name          TEXT NOT NULL,             -- freely chosen; NOT unique
  created_at    TEXT NOT NULL,             -- RFC3339 UTC
  last_seen_at  TEXT NOT NULL,
  settings      TEXT NOT NULL DEFAULT '{}' -- JSON blob, frontend-owned
);

-- ---------- content ----------
CREATE TABLE quests (
  id            TEXT PRIMARY KEY,          -- 'rust.basic.03.shadowing' (§4.1)
  pack          TEXT NOT NULL,
  land          TEXT NOT NULL CHECK (land IN ('rust','go')),
  category      TEXT NOT NULL CHECK (category IN ('basic','advanced','hacker')),
  node          INTEGER NOT NULL,
  title         TEXT NOT NULL,
  brief         TEXT NOT NULL,
  story         TEXT NOT NULL DEFAULT '',
  difficulty    INTEGER NOT NULL,
  time_limit_s  INTEGER,
  starter       TEXT NOT NULL,
  solution      TEXT NOT NULL,
  hints         TEXT NOT NULL DEFAULT '[]',
  concepts      TEXT NOT NULL DEFAULT '[]',
  tests         TEXT NOT NULL,
  checksum      TEXT NOT NULL,
  UNIQUE (land, category, node)
);

-- The map position is content, not chrome: SPEC §12 carries map.x / map.y /
-- map.kind in the pack and §6.3's MapNode carries them on the wire, so they
-- have to live somewhere between the two. §2.1's DDL has no column for them.
-- Added here rather than stuffed into a JSON blob, because world.map reads
-- them on every draw. Proposed in docs/decisions.md.
ALTER TABLE quests ADD COLUMN map_x REAL NOT NULL DEFAULT 0.5;
ALTER TABLE quests ADD COLUMN map_y REAL NOT NULL DEFAULT 0.5;
ALTER TABLE quests ADD COLUMN map_kind TEXT NOT NULL DEFAULT 'quest'
  CHECK (map_kind IN ('quest','boss','gate'));

CREATE TABLE quest_deps (
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  requires_id   TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  PRIMARY KEY (quest_id, requires_id)
);

-- ---------- progress ----------
CREATE TABLE progress (
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  state         TEXT NOT NULL CHECK (state IN ('locked','open','cleared')),
  stars         INTEGER NOT NULL DEFAULT 0,
  best_ms       INTEGER,
  attempts      INTEGER NOT NULL DEFAULT 0,
  hints_used    INTEGER NOT NULL DEFAULT 0,
  first_clear_at TEXT,
  updated_at    TEXT NOT NULL,
  PRIMARY KEY (address, quest_id)
);

-- ---------- every attempt, pass or fail ----------
CREATE TABLE attempts (
  id            TEXT PRIMARY KEY,
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  lang          TEXT NOT NULL CHECK (lang IN ('rust','go')),
  source        TEXT NOT NULL,
  verdict       TEXT NOT NULL CHECK (verdict IN
                  ('accepted','wrong_answer','compile_error','runtime_error',
                   'timeout','output_limit','internal_error')),
  compile_ms    INTEGER NOT NULL DEFAULT 0,
  run_ms        INTEGER NOT NULL DEFAULT 0,
  exit_code     INTEGER,
  stdout_bytes  INTEGER NOT NULL DEFAULT 0,
  stderr        TEXT NOT NULL DEFAULT '',
  tests_passed  INTEGER NOT NULL DEFAULT 0,
  tests_total   INTEGER NOT NULL DEFAULT 0,
  created_at    TEXT NOT NULL
);
CREATE INDEX attempts_by_user ON attempts(address, created_at DESC);
CREATE INDEX attempts_by_quest ON attempts(address, quest_id, created_at DESC);

-- ---------- what went wrong, in the compiler's own words ----------
CREATE TABLE mistakes (
  id            INTEGER PRIMARY KEY,
  attempt_id    TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL,
  code          TEXT,
  message       TEXT NOT NULL,
  line          INTEGER,
  col           INTEGER,
  created_at    TEXT NOT NULL
);
CREATE INDEX mistakes_by_user ON mistakes(address, kind, created_at DESC);

CREATE TABLE mistake_stats (
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  kind          TEXT NOT NULL,
  count         INTEGER NOT NULL DEFAULT 0,
  last_at       TEXT NOT NULL,
  cleared_since INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (address, kind)
);

-- ---------- AI drill sessions ----------
CREATE TABLE drills (
  id            TEXT PRIMARY KEY,
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  mode          TEXT NOT NULL CHECK (mode IN ('repeat','weakness','spaced')),
  plan          TEXT NOT NULL,
  cursor        INTEGER NOT NULL DEFAULT 0,
  created_at    TEXT NOT NULL,
  finished_at   TEXT
);

-- ---------- search ----------
CREATE VIRTUAL TABLE quest_fts USING fts5(
  title, brief, concepts, story,
  content='quests', content_rowid='rowid',
  tokenize='porter unicode61'
);

-- External-content FTS5 tables are not maintained by SQLite: a delete has to
-- be announced with the 'delete' sentinel carrying the OLD column values, or
-- the index keeps rows the table no longer has and bm25() reads garbage.
CREATE TRIGGER quests_ai AFTER INSERT ON quests BEGIN
  INSERT INTO quest_fts(rowid, title, brief, concepts, story)
  VALUES (new.rowid, new.title, new.brief, new.concepts, new.story);
END;
CREATE TRIGGER quests_ad AFTER DELETE ON quests BEGIN
  INSERT INTO quest_fts(quest_fts, rowid, title, brief, concepts, story)
  VALUES ('delete', old.rowid, old.title, old.brief, old.concepts, old.story);
END;
CREATE TRIGGER quests_au AFTER UPDATE ON quests BEGIN
  INSERT INTO quest_fts(quest_fts, rowid, title, brief, concepts, story)
  VALUES ('delete', old.rowid, old.title, old.brief, old.concepts, old.story);
  INSERT INTO quest_fts(rowid, title, brief, concepts, story)
  VALUES (new.rowid, new.title, new.brief, new.concepts, new.story);
END;

CREATE TABLE quest_vec (
  quest_id      TEXT PRIMARY KEY REFERENCES quests(id) ON DELETE CASCADE,
  dim           INTEGER NOT NULL,
  model         TEXT NOT NULL,
  vec           BLOB NOT NULL
);

-- ---------- sessions ----------
CREATE TABLE sessions (
  token_hash    TEXT PRIMARY KEY,
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  created_at    TEXT NOT NULL,
  expires_at    TEXT NOT NULL
);
CREATE INDEX sessions_by_address ON sessions(address);
