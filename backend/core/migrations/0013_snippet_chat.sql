-- 0013_snippet_chat — the chatroom under every playground snippet
-- (docs/agent.md §6, PROTOCOL §4.9f).
--
-- The AI agent's conversation about a pad lives with the pad: one room per
-- snippet, every row scoped by the owner's address exactly as the snippet
-- is. The model is called from the browser and the server never sees a key;
-- what it keeps is the transcript, so the room reopens in either client and
-- so `search_notes` has something to search.
--
-- A photo is not a column. The websocket carries a 4 MiB frame and a picture
-- can be most of that, so the bytes go to `photos/<message_id>.<ext>` in the
-- snippet's folder and the row keeps the file name plus a 32-hex capability
-- token; `GET /photos/{id}/{token}.{ext}` serves it to whoever holds the token.

CREATE TABLE snippet_messages (
  id            TEXT PRIMARY KEY,          -- 'msg_' + 16 hex
  snippet_id    TEXT NOT NULL REFERENCES snippets(id) ON DELETE CASCADE,
  address       TEXT NOT NULL,
  role          TEXT NOT NULL CHECK (role IN ('user','agent','tool')),
  kind          TEXT NOT NULL CHECK (kind IN ('text','image')),
  text          TEXT NOT NULL DEFAULT '',  -- the message, or the image's prompt
  photo         TEXT,                      -- file name under photos/, image rows only
  photo_token   TEXT,                      -- 32 hex; the capability that fetches it
  provider      TEXT,                      -- 'openai' | 'anthropic' | 'grok' | NULL
  model         TEXT,
  created_at    TEXT NOT NULL
);
CREATE INDEX snippet_messages_by_snippet ON snippet_messages(snippet_id, created_at);

CREATE VIRTUAL TABLE snippet_message_fts USING fts5(
  text,
  content='snippet_messages', content_rowid='rowid',
  tokenize='porter unicode61'
);

-- External-content FTS5, maintained by the same three triggers quest_fts has:
-- a delete must be announced with the 'delete' sentinel and the OLD values,
-- or the index keeps rows the table no longer has.
CREATE TRIGGER snippet_messages_ai AFTER INSERT ON snippet_messages BEGIN
  INSERT INTO snippet_message_fts(rowid, text) VALUES (new.rowid, new.text);
END;
CREATE TRIGGER snippet_messages_ad AFTER DELETE ON snippet_messages BEGIN
  INSERT INTO snippet_message_fts(snippet_message_fts, rowid, text)
  VALUES ('delete', old.rowid, old.text);
END;
CREATE TRIGGER snippet_messages_au AFTER UPDATE ON snippet_messages BEGIN
  INSERT INTO snippet_message_fts(snippet_message_fts, rowid, text)
  VALUES ('delete', old.rowid, old.text);
  INSERT INTO snippet_message_fts(rowid, text) VALUES (new.rowid, new.text);
END;

CREATE TABLE snippet_message_vec (
  message_id    TEXT PRIMARY KEY REFERENCES snippet_messages(id) ON DELETE CASCADE,
  dim           INTEGER NOT NULL,
  model         TEXT NOT NULL,             -- embedder id, SPEC §8.2
  vec           BLOB NOT NULL              -- dim * f32, little-endian
);
