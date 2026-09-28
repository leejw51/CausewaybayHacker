-- 0022_remix — the seventh land, and the first that is not a language.
--
-- REMIX is the same program three times: one concept, one trio of nodes, in
-- Go, in Rust and in Python. So a quest's land no longer says what compiles
-- it. That is a new column, `quests.lang`, which is the language the runner
-- judges the quest in, the file the source is saved as and the grammar the
-- editors colour it with (SPEC §12). In every land but `remix` it equals the
-- land, and the trigger below writes that in for any row that does not say —
-- every row already here, and every raw INSERT that predates the column.
--
-- `quests` is rebuilt the way 0021 rebuilt it — rowid carried across for the
-- FTS5 index, the three FTS triggers put back verbatim — with `remix` in the
-- `land` CHECK and the new column beside it. `attempts.lang` and
-- `snippets.lang` are NOT widened: `remix` is a place, not a language, and
-- an attempt at a remix quest is filed under the language it was judged in.
-- Foreign keys are off for the run (db.rs).

-- ---------- quests ----------
CREATE TABLE quests_new (
  id            TEXT PRIMARY KEY,
  pack          TEXT NOT NULL,
  land          TEXT NOT NULL CHECK (land IN ('rust','go','cpp','python','pytorch','typescript','remix')),
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
  lang          TEXT NOT NULL DEFAULT '' CHECK (lang IN ('','rust','go','cpp','python','pytorch','typescript')),
  UNIQUE (land, category, node)
);
INSERT INTO quests_new (rowid, id, pack, land, category, node, title, brief, story,
                        difficulty, time_limit_s, starter, solution, hints, concepts,
                        tests, checksum, map_x, map_y, map_kind, quiz, lang)
  SELECT rowid, id, pack, land, category, node, title, brief, story,
         difficulty, time_limit_s, starter, solution, hints, concepts,
         tests, checksum, map_x, map_y, map_kind, quiz, land
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
