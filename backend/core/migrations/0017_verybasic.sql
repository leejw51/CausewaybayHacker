-- 0017_verybasic — the fourth road, and the quiz that comes with it.
--
-- VERY BASIC is the grammar asked as a question first: four choices, one
-- right, and then that one line typed. Two changes: `quests.category` admits
-- 'verybasic', and a quest may carry a `quiz` — the choices and the index of
-- the right one, as JSON, NULL on every other road. SQLite cannot widen a
-- CHECK in place, so `quests` is rebuilt the way 0008 did it: rowid carried
-- across for the FTS5 index, the three FTS triggers put back verbatim, the
-- index rebuilt. Foreign keys are off for the run (db.rs).

CREATE TABLE quests_new (
  id            TEXT PRIMARY KEY,
  pack          TEXT NOT NULL,
  land          TEXT NOT NULL CHECK (land IN ('rust','go','cpp','python')),
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
