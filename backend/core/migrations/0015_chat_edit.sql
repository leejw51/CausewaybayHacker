-- 0015_chat_edit — a message can be edited or deleted, and sync says so.
--
-- A messenger's messages are not append-only: the person changes their mind
-- and the room has to follow, on every device. Both are done the way
-- PocketSkynet does them — the row stays, `timeid` is bumped so a cursor
-- past the original still receives the change, and the row says what it
-- now is. An edit keeps its `text` and sets `edited`. A delete scrubs the
-- text, drops the photo and the vector, and sets `deleted`: a tombstone,
-- delivered to whoever holds a copy, hidden from a room read from the start.

ALTER TABLE snippet_messages ADD COLUMN edited INTEGER NOT NULL DEFAULT 0;
ALTER TABLE snippet_messages ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;
