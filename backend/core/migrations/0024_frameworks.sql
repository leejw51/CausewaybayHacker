-- 0024_frameworks — the fifth road, for Rust Land.
--
-- FRAMEWORKS is the road after the interview: the job, where nothing is
-- written from scratch and every file starts with `use serde`. Its quests
-- are stdio quests that name `crates` in their test spec (SPEC §5.1, §5.2)
-- and are built by cargo against the crate shelf. To the database that is
-- one more name in one CHECK constraint, `quests.category`, so the `quests`
-- table is rebuilt 0023's way: rowids carried across for the FTS5 index, the
-- three FTS triggers recreated with the `OF`-narrowed update trigger (see
-- 0023 for why it is narrowed), the `lang` fill-in trigger put back, the
-- index rebuilt. `attempts` and `snippets` do not name a category and are
-- not touched. Foreign keys are off for the run (db.rs).

CREATE TABLE quests_new (
  id            TEXT PRIMARY KEY,
  pack          TEXT NOT NULL,
  land          TEXT NOT NULL CHECK (land IN ('rust','go','cpp','python','pytorch','typescript','zig','lua','remix')),
  category      TEXT NOT NULL CHECK (category IN ('verybasic','basic','advanced','hacker','frameworks')),
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
CREATE TRIGGER quests_au AFTER UPDATE OF title, brief, concepts, story ON quests BEGIN
  INSERT INTO quest_fts(quest_fts, rowid, title, brief, concepts, story)
  VALUES ('delete', old.rowid, old.title, old.brief, old.concepts, old.story);
  INSERT INTO quest_fts(rowid, title, brief, concepts, story)
  VALUES (new.rowid, new.title, new.brief, new.concepts, new.story);
END;
CREATE TRIGGER quests_lang_default AFTER INSERT ON quests WHEN new.lang = '' BEGIN
  UPDATE quests SET lang = new.land WHERE rowid = new.rowid;
END;
INSERT INTO quest_fts(quest_fts) VALUES ('rebuild');
