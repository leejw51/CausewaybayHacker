-- 0003_snippets — the playground's scratchpads (PROTOCOL §4.9c).
--
-- Server-side and per user, so the same scratchpad opens in the browser and in
-- the LÖVE client. Nothing here touches the curriculum: a playground run is
-- not recorded at all, and these rows are the player's own notes rather than
-- anything §7's drills read.

CREATE TABLE snippets (
  id            TEXT PRIMARY KEY,          -- 'pg_' + 16 hex
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  lang          TEXT NOT NULL CHECK (lang IN ('rust','go')),
  source        TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);
CREATE INDEX snippets_by_user ON snippets(address, updated_at DESC);
