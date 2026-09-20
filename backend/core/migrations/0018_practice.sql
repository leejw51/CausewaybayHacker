-- 0018_practice — XP for coming back.
--
-- A node cleared once is a node worth playing again: the grammar goes back
-- into the fingers by repetition, and the ledger should say so. A re-clear
-- writes a `practice` row worth a fifth of the clear, at most ten times a
-- quest, so practising pays and farming does not. The ledger's CHECK and
-- its UNIQUE both said "one row, reason clear"; SQLite cannot widen either,
-- so the table is rebuilt: the CHECK admits `practice`, and the once-only
-- rule becomes a partial index over the `clear` rows alone.

CREATE TABLE xp_ledger_new (
  id            INTEGER PRIMARY KEY,
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL,
  reason        TEXT NOT NULL CHECK (reason IN ('clear','practice')),
  amount        INTEGER NOT NULL CHECK (amount >= 0),
  stars         INTEGER NOT NULL,
  created_at    TEXT NOT NULL
);
INSERT INTO xp_ledger_new (id, address, quest_id, reason, amount, stars, created_at)
  SELECT id, address, quest_id, reason, amount, stars, created_at FROM xp_ledger;
DROP TABLE xp_ledger;
ALTER TABLE xp_ledger_new RENAME TO xp_ledger;
CREATE INDEX xp_ledger_by_user ON xp_ledger(address, created_at DESC);
CREATE UNIQUE INDEX xp_ledger_one_clear ON xp_ledger(address, quest_id) WHERE reason = 'clear';
CREATE INDEX xp_ledger_practice ON xp_ledger(address, quest_id, reason);
