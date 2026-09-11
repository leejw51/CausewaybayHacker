-- 0002_attempt_mode — PROTOCOL §4.9b's RUN button.
--
-- A run is an attempt too: it compiles, it runs, it fails in the same ways,
-- and its mistakes are the truest record of what a player is struggling with
-- (SPEC §2.2). What it is not is part of the *record* — it does not move
-- progress, does not count toward a node's attempts, and does not enter
-- accuracy.
--
-- The default is what makes this migration safe on a live database: every row
-- that existed before the RUN button did was a submit, and now says so.

ALTER TABLE attempts ADD COLUMN mode TEXT NOT NULL DEFAULT 'submit'
  CHECK (mode IN ('run','submit'));

-- Every query that cares about the record filters on mode, and the two that
-- run per submission — "how many times has this player failed this node" and
-- the accuracy rollup — are the ones worth an index.
CREATE INDEX attempts_by_mode ON attempts(address, mode, created_at DESC);
CREATE INDEX attempts_quest_mode ON attempts(address, quest_id, mode);
