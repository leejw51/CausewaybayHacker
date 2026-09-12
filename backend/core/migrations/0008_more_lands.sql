-- 0008_more_lands — the C++ and Python lands.
--
-- Three CHECK constraints name the lands: `quests.land`, `attempts.lang` and
-- `snippets.lang`, all `IN ('rust','go')`. SQLite cannot alter a constraint in
-- place, so each table is rebuilt the way the SQLite manual prescribes: a new
-- table with the wider CHECK, the rows copied across, the old table dropped,
-- the new one renamed, and the indexes and triggers put back. The runner has
-- foreign keys off for the duration (db.rs), which is what makes dropping a
-- table that six others reference safe: with them on, the drop would be an
-- implicit DELETE that cascades through progress, attempts and mistakes.
--
-- `quests` is the delicate one. `quest_fts` is an external-content FTS5 table
-- indexed by `quests.rowid`, so the copy carries the rowid across and the
-- index is rebuilt afterwards regardless; and dropping the table drops its
-- three FTS triggers, which are recreated verbatim from 0001.

-- ---------- quests ----------
CREATE TABLE quests_new (
  id            TEXT PRIMARY KEY,
  pack          TEXT NOT NULL,
  land          TEXT NOT NULL CHECK (land IN ('rust','go','cpp','python')),
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
  map_x         REAL NOT NULL DEFAULT 0.5,
  map_y         REAL NOT NULL DEFAULT 0.5,
  map_kind      TEXT NOT NULL DEFAULT 'quest' CHECK (map_kind IN ('quest','boss','gate')),
  UNIQUE (land, category, node)
);
INSERT INTO quests_new (rowid, id, pack, land, category, node, title, brief, story,
                        difficulty, time_limit_s, starter, solution, hints, concepts,
                        tests, checksum, map_x, map_y, map_kind)
  SELECT rowid, id, pack, land, category, node, title, brief, story,
         difficulty, time_limit_s, starter, solution, hints, concepts,
         tests, checksum, map_x, map_y, map_kind
    FROM quests;
DROP TABLE quests;
ALTER TABLE quests_new RENAME TO quests;

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
INSERT INTO quest_fts(quest_fts) VALUES ('rebuild');

-- ---------- attempts ----------
CREATE TABLE attempts_new (
  id            TEXT PRIMARY KEY,
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  lang          TEXT NOT NULL CHECK (lang IN ('rust','go','cpp','python')),
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
  created_at    TEXT NOT NULL,
  mode          TEXT NOT NULL DEFAULT 'submit' CHECK (mode IN ('run','submit')),
  within_limit  INTEGER
);
INSERT INTO attempts_new (rowid, id, address, quest_id, lang, source, verdict,
                          compile_ms, run_ms, exit_code, stdout_bytes, stderr,
                          tests_passed, tests_total, created_at, mode, within_limit)
  SELECT rowid, id, address, quest_id, lang, source, verdict,
         compile_ms, run_ms, exit_code, stdout_bytes, stderr,
         tests_passed, tests_total, created_at, mode, within_limit
    FROM attempts;
DROP TABLE attempts;
ALTER TABLE attempts_new RENAME TO attempts;
CREATE INDEX attempts_by_user ON attempts(address, created_at DESC);
CREATE INDEX attempts_by_quest ON attempts(address, quest_id, created_at DESC);
CREATE INDEX attempts_by_mode ON attempts(address, mode, created_at DESC);
CREATE INDEX attempts_quest_mode ON attempts(address, quest_id, mode);

-- ---------- snippets ----------
CREATE TABLE snippets_new (
  id            TEXT PRIMARY KEY,
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  lang          TEXT NOT NULL CHECK (lang IN ('rust','go','cpp','python')),
  source        TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);
INSERT INTO snippets_new (rowid, id, address, name, lang, source, created_at, updated_at)
  SELECT rowid, id, address, name, lang, source, created_at, updated_at
    FROM snippets;
DROP TABLE snippets;
ALTER TABLE snippets_new RENAME TO snippets;
CREATE INDEX snippets_by_user ON snippets(address, updated_at DESC);
