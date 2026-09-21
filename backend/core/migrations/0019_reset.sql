-- 0019_reset — a road a player may walk again from the start.
--
-- RESET clears one land's one road back to untouched: no stamps, no stars,
-- no attempt counts. What it does **not** clear is the attempt log or the
-- mistakes, which are §7's training data and are never deleted by the
-- server, nor the XP ledger, which is history — you keep what you earned and
-- a re-clear after a reset pays nothing, because the `clear` row is already
-- there. That is the whole anti-farm rule, and it needs no code: the ledger's
-- unique index already refuses the second grant.
--
-- The one thing a reset must record is *when*, because stars are counted
-- from the failures before the first clear. Without a mark, re-clearing a
-- road you reset would be judged on every failure you ever made on it, and a
-- fresh start that cannot earn three stars is not a fresh start.

ALTER TABLE progress ADD COLUMN reset_at TEXT;
