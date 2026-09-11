-- 0004_awards — the reward loop (PROTOCOL §4.20, PLAN.md milestone 3).
--
-- One row per thing a player has earned, so a client can list a history
-- instead of only catching the live `award` event, and so nothing is ever
-- awarded twice.
--
-- The UNIQUE is the whole design: "not re-awarded" is a constraint the
-- database enforces rather than a convention the code remembers. Every rule
-- can therefore be written as "is this true now?" and run after every submit —
-- it grants what is newly true and the index refuses the rest.

CREATE TABLE awards (
  id            INTEGER PRIMARY KEY,
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  kind          TEXT NOT NULL CHECK (kind IN ('badge','stamp','level','streak')),
  award_id      TEXT NOT NULL,             -- 'first-clear', 'level-4', 'streak-7'
  title         TEXT NOT NULL,
  detail        TEXT NOT NULL DEFAULT '{}',
  created_at    TEXT NOT NULL,
  UNIQUE (address, kind, award_id)
);
CREATE INDEX awards_by_user ON awards(address, created_at DESC);
