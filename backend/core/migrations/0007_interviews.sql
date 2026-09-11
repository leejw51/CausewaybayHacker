-- 0007_interviews — the live coding screen, simulated (PROTOCOL §4.9e).
--
-- Everything else in this game teaches a topic. This rehearses the hour: read
-- a statement under time pressure, say what you are going to do before you do
-- it, write it while somebody watches, and answer for the result.
--
-- The `approach` is the feature and it is never graded. The server keeps it and
-- hands it back at the end beside what the reference does; scoring it would be
-- inventing a judgement the server cannot make.

CREATE TABLE interviews (
  id            TEXT PRIMARY KEY,          -- 'int_' + 16 hex
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  opened_at     TEXT NOT NULL,             -- the clock, as §4.8b's is
  approach      TEXT,                      -- null until written
  approach_at   TEXT,                      -- the editor unlocks after this
  finished_at   TEXT,                      -- null while live
  created_at    TEXT NOT NULL
);
CREATE INDEX interviews_by_user ON interviews(address, created_at DESC);
