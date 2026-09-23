-- 0021_typescript — the sixth land.
--
-- TYPESCRIPT is the first land since C++ with a toolchain of its own: `tsc`
-- checks `main.ts`, erases the types, and `node` runs what is left (SPEC
-- §5.1). None of that is the database's business. What is new here is only a
-- name, and the three CHECK constraints that do not admit it —
-- `quests.land`, `attempts.lang` and `snippets.lang` — rebuilt exactly the way
-- 0020 rebuilt them, from 0020's shapes, which are the current ones: rowid
-- carried across for the FTS5 index, the three FTS triggers put back
-- verbatim, the indexes rebuilt. Foreign keys are off for the run (db.rs).

-- ---------- quests ----------
CREATE TABLE quests_new (
  id            TEXT PRIMARY KEY,
  pack          TEXT NOT NULL,
  land          TEXT NOT NULL CHECK (land IN ('rust','go','cpp','python','pytorch','typescript')),
  category      TEXT NOT NULL CHECK (category IN ('verybasic','basic','advanced','hacker')),
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
  quiz          TEXT,                         -- {"choices":[4 strings],"answer":i} or NULL
  UNIQUE (land, category, node)
);
INSERT INTO quests_new (rowid, id, pack, land, category, node, title, brief, story,
                        difficulty, time_limit_s, starter, solution, hints, concepts,
                        tests, checksum, map_x, map_y, map_kind, quiz)
  SELECT rowid, id, pack, land, category, node, title, brief, story,
         difficulty, time_limit_s, starter, solution, hints, concepts,
         tests, checksum, map_x, map_y, map_kind, quiz
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
  lang          TEXT NOT NULL CHECK (lang IN ('rust','go','cpp','python','pytorch','typescript')),
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
-- Rebuilt from its 0012 shape, which added `stdin`.
CREATE TABLE snippets_new (
  id            TEXT PRIMARY KEY,
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  lang          TEXT NOT NULL CHECK (lang IN ('rust','go','cpp','python','pytorch','typescript')),
  source        TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  stdin         TEXT NOT NULL DEFAULT ''
);
INSERT INTO snippets_new (rowid, id, address, name, lang, source, created_at, updated_at, stdin)
  SELECT rowid, id, address, name, lang, source, created_at, updated_at, stdin
    FROM snippets;
DROP TABLE snippets;
ALTER TABLE snippets_new RENAME TO snippets;
CREATE INDEX snippets_by_user ON snippets(address, updated_at DESC);
