-- 0014_chat_seq — a chat message gets two int64s: `id` to name it and
-- `timeid` to sync it.
--
-- A client that keeps a copy of a room needs one question: "what came after
-- the last thing I saw?" A random text id cannot answer it and a timestamp
-- cannot be trusted to — two posts in one millisecond, a clock that moved.
-- So, as PocketSkynet does it:
--
--   * `id` is the identity: an INTEGER PRIMARY KEY that SQLite hands out and
--     never reuses. It names the row, the photo file and the photo URL.
--   * `timeid` is the cursor: milliseconds since the epoch at post time, or
--     one past the last `timeid` handed out when the clock has not moved on
--     — strictly increasing across every room this server has, so one cursor
--     syncs everything a player owns. "After N" is one indexed query.
--
-- The last `timeid` handed out lives in `chat_clock`, bumped in the same
-- transaction as the row that takes it, and NOT derived from the messages:
-- a cleared room takes its rows with it, and the next post must still land
-- past everything any client has seen. 0 is never handed out — it is the
-- "I have received nothing" cursor.
--
-- The table is rebuilt because SQLite cannot retype a primary key in place.
-- The rows that exist keep their order: `timeid` from their own `created_at`
-- in milliseconds, ties spaced by insertion. The photos on disk keep the
-- file names the `photo` column points at; nothing under `photos/` is
-- renamed.

CREATE TABLE snippet_messages_new (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  timeid        INTEGER NOT NULL UNIQUE,   -- ms since the epoch, strictly increasing
  snippet_id    TEXT NOT NULL REFERENCES snippets(id) ON DELETE CASCADE,
  address       TEXT NOT NULL,
  role          TEXT NOT NULL CHECK (role IN ('user','agent','tool')),
  kind          TEXT NOT NULL CHECK (kind IN ('text','image')),
  text          TEXT NOT NULL DEFAULT '',
  photo         TEXT,
  photo_token   TEXT,
  provider      TEXT,
  model         TEXT,
  created_at    TEXT NOT NULL
);

INSERT INTO snippet_messages_new
  (timeid, snippet_id, address, role, kind, text, photo, photo_token, provider, model, created_at)
SELECT CAST((julianday(created_at) - 2440587.5) * 86400000 AS INTEGER)
         + (SELECT count(*) FROM snippet_messages AS tie
             WHERE tie.created_at = m.created_at AND tie.rowid < m.rowid),
       snippet_id, address, role, kind, text, photo, photo_token, provider, model, created_at
  FROM snippet_messages AS m
 ORDER BY created_at, rowid;

CREATE TABLE snippet_message_vec_new (
  message_id    INTEGER PRIMARY KEY REFERENCES snippet_messages_new(id) ON DELETE CASCADE,
  dim           INTEGER NOT NULL,
  model         TEXT NOT NULL,
  vec           BLOB NOT NULL
);
INSERT INTO snippet_message_vec_new (message_id, dim, model, vec)
SELECT n.id, v.dim, v.model, v.vec
  FROM snippet_message_vec v
  JOIN snippet_messages m ON m.id = v.message_id
  JOIN snippet_messages_new n
    ON n.snippet_id = m.snippet_id AND n.created_at = m.created_at AND n.text = m.text
       AND n.role = m.role AND coalesce(n.photo, '') = coalesce(m.photo, '');

DROP TRIGGER snippet_messages_ai;
DROP TRIGGER snippet_messages_ad;
DROP TRIGGER snippet_messages_au;
DROP TABLE snippet_message_fts;
DROP TABLE snippet_message_vec;
DROP TABLE snippet_messages;
ALTER TABLE snippet_messages_new RENAME TO snippet_messages;
ALTER TABLE snippet_message_vec_new RENAME TO snippet_message_vec;

CREATE INDEX snippet_messages_by_snippet ON snippet_messages(snippet_id, timeid);
CREATE INDEX snippet_messages_by_address ON snippet_messages(address, timeid);

-- The clock: one row, the last timeid handed out. Seeded past every row
-- that exists so the next post is newer than all of them.
CREATE TABLE chat_clock (
  one           INTEGER PRIMARY KEY CHECK (one = 1),
  last_timeid   INTEGER NOT NULL
);
INSERT INTO chat_clock (one, last_timeid)
  VALUES (1, (SELECT coalesce(max(timeid), 0) FROM snippet_messages));

CREATE VIRTUAL TABLE snippet_message_fts USING fts5(
  text,
  content='snippet_messages', content_rowid='id',
  tokenize='porter unicode61'
);
CREATE TRIGGER snippet_messages_ai AFTER INSERT ON snippet_messages BEGIN
  INSERT INTO snippet_message_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER snippet_messages_ad AFTER DELETE ON snippet_messages BEGIN
  INSERT INTO snippet_message_fts(snippet_message_fts, rowid, text)
  VALUES ('delete', old.id, old.text);
END;
CREATE TRIGGER snippet_messages_au AFTER UPDATE ON snippet_messages BEGIN
  INSERT INTO snippet_message_fts(snippet_message_fts, rowid, text)
  VALUES ('delete', old.id, old.text);
  INSERT INTO snippet_message_fts(rowid, text) VALUES (new.id, new.text);
END;
INSERT INTO snippet_message_fts(snippet_message_fts) VALUES ('rebuild');
