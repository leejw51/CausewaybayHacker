-- 0005_clock — the countdown on a timed quest (PROTOCOL §4.8b).
--
-- The server owns the clock. A client-side timer cannot support a claim like
-- "cleared inside the limit", because a page reload would reset it and the
-- claim would mean nothing; a fact the game asserts about a player has to be
-- one the game actually knows.
--
-- Both columns are nullable and both defaults are NULL, which is what makes
-- this safe on a live database: a quest cleared before the clock existed has
-- no `opened_at`, and an attempt made before it has no `within_limit`. Neither
-- is invented after the fact.

ALTER TABLE progress ADD COLUMN opened_at TEXT;
ALTER TABLE attempts ADD COLUMN within_limit INTEGER;
