-- 0009_quest_text — the quests in the player's own language (SPEC §12.1).
--
-- The English text stays on `quests`: it is the source, the thing the checksum
-- covers, the thing search indexes, and the thing every client shows when no
-- translation exists. A translation is a separate row per (quest, locale),
-- keyed to the quest and nothing else, so a quest that is cut from a pack
-- takes its translations with it and a translation file that goes stale
-- cannot leave a title on the map for a quest that no longer exists.
--
-- `hints` is a JSON array, the way `quests.hints` is, and the importer refuses
-- a translation whose count differs from the English: hints are revealed by
-- index, and a player who paid a star for hint 2 must get hint 2.

CREATE TABLE quest_text (
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  locale        TEXT NOT NULL,             -- ko | yue | zh | ja | cs
  title         TEXT NOT NULL,
  story         TEXT NOT NULL,
  brief         TEXT NOT NULL,             -- markdown, same code blocks as the English
  hints         TEXT NOT NULL,             -- JSON array, same length as quests.hints
  PRIMARY KEY (quest_id, locale)
);
