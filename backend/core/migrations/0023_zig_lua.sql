-- 0023_zig_lua — the eighth and ninth lands.
--
-- ZIG and LUA are two more toolchains of their own (SPEC §5.1): `zig
-- build-exe -O Debug` and `luajit`. Like TYPESCRIPT in 0021, what is new to
-- the database is only two names, and the CHECK constraints that do not admit
-- them: `quests.land` and `quests.lang` (0022's shape, with the `lang` column,
-- its fill-in trigger and the `OF`-narrowed FTS update trigger put back
-- verbatim), and `attempts.lang` and `snippets.lang` (0021's shapes, which
-- 0022 did not touch). Rowids are carried across for the FTS5 index, the
-- three FTS triggers are recreated, the indexes rebuilt. Foreign keys are off
-- for the run (db.rs). One difference from 0022's INSERT that matters:
-- 0022 filled the new `lang` column from `land`, because the old table had
-- no `lang`; this one copies `lang`, because a remix row's `land` is `remix`
-- and `remix` is not a language the CHECK admits — the migration test
-- caught exactly that.

-- ---------- quests ----------
CREATE TABLE quests_new (
  id            TEXT PRIMARY KEY,
  pack          TEXT NOT NULL,
  land          TEXT NOT NULL CHECK (land IN ('rust','go','cpp','python','pytorch','typescript','zig','lua','remix')),
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
  -- The language this quest is judged in. '' only between an INSERT that
  -- did not say and the trigger that fills it from `land`; never 'remix'.
  lang          TEXT NOT NULL DEFAULT '' CHECK (lang IN ('','rust','go','cpp','python','pytorch','typescript','zig','lua')),
  UNIQUE (land, category, node)
);
INSERT INTO quests_new (rowid, id, pack, land, category, node, title, brief, story,
                        difficulty, time_limit_s, starter, solution, hints, concepts,
                        tests, checksum, map_x, map_y, map_kind, quiz, lang)
  SELECT rowid, id, pack, land, category, node, title, brief, story,
         difficulty, time_limit_s, starter, solution, hints, concepts,
         tests, checksum, map_x, map_y, map_kind, quiz, lang
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
-- `OF` the four indexed columns, where 0021's fired on any UPDATE. The
-- trigger below updates `lang` from inside an INSERT, and SQLite fires the
-- two AFTER INSERT triggers in an order it does not promise: when this one
-- ran first, the UPDATE's FTS `delete` named a row the index did not hold
-- yet, and the index was corrupt from then on ("database disk image is
-- malformed" on the next search). A `lang` change has nothing to tell the
-- index, so it no longer hears about one.
CREATE TRIGGER quests_au AFTER UPDATE OF title, brief, concepts, story ON quests BEGIN
  INSERT INTO quest_fts(quest_fts, rowid, title, brief, concepts, story)
  VALUES ('delete', old.rowid, old.title, old.brief, old.concepts, old.story);
  INSERT INTO quest_fts(rowid, title, brief, concepts, story)
  VALUES (new.rowid, new.title, new.brief, new.concepts, new.story);
END;
-- A row that did not say its language is in the language of its land. For
-- a `remix` row that is a CHECK failure, which is the right answer: a remix
-- quest that does not say go, rust or python cannot be judged.
CREATE TRIGGER quests_lang_default AFTER INSERT ON quests WHEN new.lang = '' BEGIN
  UPDATE quests SET lang = new.land WHERE rowid = new.rowid;
END;
INSERT INTO quest_fts(quest_fts) VALUES ('rebuild');

-- ---------- attempts ----------
CREATE TABLE attempts_new (
  id            TEXT PRIMARY KEY,
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  lang          TEXT NOT NULL CHECK (lang IN ('rust','go','cpp','python','pytorch','typescript','zig','lua')),
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
  lang          TEXT NOT NULL CHECK (lang IN ('rust','go','cpp','python','pytorch','typescript','zig','lua')),
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
