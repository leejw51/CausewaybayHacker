-- 0011_position — where each player is, so a client can be told rather than
-- having to remember.
--
-- Everything else about a player already lives here; their place in the world
-- did not, and each client kept its own answer. The web client hardcoded
-- "rust" every time the lobby was constructed, so walking out of a quest lost
-- the land you were in; the LÖVE client remembered it in its own home. Two
-- clients talking to one server disagreed about where the same person was, and
-- logging out lost it either way.
--
-- One row per player, overwritten in place: this is a bookmark, not a history.
-- The trail is `attempts`, which is kept forever and is a different question.
--
-- The columns are deliberately not foreign keys onto `quests`. A bookmark
-- pointing at a quest a reimport has dropped must degrade to "the lobby of
-- that land", not cascade the row away and lose the land too — and `land` and
-- `category` outlive any particular pack. `quest_id` is checked when it is
-- read, which is also where a quest that no longer exists has to be handled
-- anyway.
--
-- `quest_id` is NULL when the player is in a lobby rather than on a stage,
-- and that is a real state: "I chose rust/basic and have not opened anything"
-- is where somebody browsing lands, and restoring them onto a stage they never
-- opened would be worse than putting them back on the map they were reading.

CREATE TABLE user_position (
  address    TEXT PRIMARY KEY REFERENCES users(address) ON DELETE CASCADE,
  land       TEXT NOT NULL,
  category   TEXT,
  quest_id   TEXT,
  updated_at TEXT NOT NULL
);
