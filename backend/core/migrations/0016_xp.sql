-- 0016_xp — XP as a record, not a recomputation.
--
-- Until now `User.xp` was derived on every read: stars × difficulty × the
-- category weight, summed over cleared progress. That could never disagree
-- with the record, and it could never be *shown* either — a clear had no
-- number of its own to put on the screen, and a quest that left the content
-- pack took its XP with it. This is the ledger: one row per grant, written the
-- moment a node is first cleared, carrying the amount that clear was worth.
--
-- No foreign key to `quests`, on purpose. XP is history: the road that gave it
-- may be renumbered, moved to another category or retired, and the player
-- still earned it. The player, on the other hand, owns the rows and takes
-- them along when the account goes.
--
-- The backfill grants every clear already on the record exactly what the old
-- formula was reading for it, dated at the clear, so nobody's level moves on
-- upgrade — `awards::total_xp` reads the ledger from here on and must agree
-- with what it computed yesterday.

CREATE TABLE xp_ledger (
  id            INTEGER PRIMARY KEY,
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL,             -- no FK: history outlives content
  reason        TEXT NOT NULL CHECK (reason IN ('clear')),
  amount        INTEGER NOT NULL CHECK (amount >= 0),
  stars         INTEGER NOT NULL,          -- what the amount was computed from
  created_at    TEXT NOT NULL,
  UNIQUE (address, quest_id, reason)       -- a clear is granted once
);
CREATE INDEX xp_ledger_by_user ON xp_ledger(address, created_at DESC);

INSERT INTO xp_ledger (address, quest_id, reason, amount, stars, created_at)
SELECT p.address, p.quest_id, 'clear',
       25 * p.stars * q.difficulty *
         CASE q.category WHEN 'hacker' THEN 3 WHEN 'advanced' THEN 2 ELSE 1 END,
       p.stars,
       COALESCE(p.first_clear_at, p.updated_at)
  FROM progress p JOIN quests q ON q.id = p.quest_id
 WHERE p.state = 'cleared';
