-- 0010_edit_stack — the coding page's undo/redo stack, one per (player, quest).
--
-- A stack with a cursor, which is what makes redo possible: `edit_cursor.cursor`
-- is how many of the quest's entries are applied, so the source the editor is
-- showing is the entry at `seq = cursor` and the quest's own `starter` when the
-- cursor is 0. Undo moves it down, redo moves it up, and a push truncates
-- everything above it before appending — the classic "an edit after an undo
-- drops the redo tail".
--
-- Only the *index* is here. The source itself is a file under the home,
-- `edits/<address>/<quest_id>/<sha>.<ext>`, and `sha` is what names it. Both
-- halves are needed and neither would do alone: the order of the entries is a
-- query, which is what SQLite is for, while the source is a blob of up to
-- 256 KiB, and a hundred of those per quest per player in a TEXT column makes
-- this database the wrong shape — every `SELECT` over the stack would drag
-- megabytes through the page cache to answer a question about integers.
-- Content addressing is the other half of the bargain: an undo/redo cycle that
-- comes back to text the player has already written costs no new bytes, and a
-- file is unlinked only once no row names its sha any more.
--
-- `address` has no foreign key, matching `edit_cursor` and matching the way a
-- quest that is cut from a pack takes its history with it: the cascade that
-- matters here is the one on `quest_id`, because a reimport that drops a quest
-- must not leave a stack pointing at a node nobody can open.

CREATE TABLE edit_stack (
  address    TEXT NOT NULL,
  quest_id   TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  seq        INTEGER NOT NULL,          -- 1-based position in the stack
  sha        TEXT NOT NULL,             -- sha256 of the source, names the file
  bytes      INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (address, quest_id, seq)
);
CREATE TABLE edit_cursor (
  address  TEXT NOT NULL,
  quest_id TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  cursor   INTEGER NOT NULL,
  PRIMARY KEY (address, quest_id)
);
