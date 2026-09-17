-- Folding a room's messages by cursor, with no network in it.
--
-- The server hands out two int64s per message (PROTOCOL §4.9f): `id` names it,
-- `timeid` orders it and is what "after N" means. A client keeps the messages
-- it has and the highest `timeid` it has seen, asks for what came after, and
-- folds the page in: **by `id`** — a message seen twice replaces the copy held
-- rather than appearing twice — and in `timeid` order. The cursor advances
-- over every message received, even ones the fold ignores, or a page that
-- starts with something unwanted would be asked for for ever (PocketSkynet's
-- rule, and its bug).
--
-- This is the LÖVE port of `frontend/src/ui/agent/sync.ts`, function for
-- function and branch for branch. Both clients fold the same way on purpose:
-- the room is the server's, not the screen's, so the same page of messages
-- must settle into the same transcript in a browser and on the desktop. If the
-- two ever disagreed, the same account would show two different conversations
-- depending on which client was open, and neither one would be wrong. Keep
-- them in step: a change here wants the same change there.
--
-- ## Why the numbers are safe as Lua numbers
--
-- `id` and `timeid` are int64 on the wire, and LuaJIT has no integers — every
-- number here is a double, which holds whole numbers exactly only up to 2^53.
-- That is not a gamble taken locally: the server keeps both of them under 2^53
-- for exactly this reason (PROTOCOL §4.9f promises it, for the sake of the
-- JavaScript client, and this one inherits the promise). So comparing and
-- storing them as plain numbers is exact, and a table keyed by `id` really is
-- keyed by identity rather than by a rounded neighbour.
--
-- Pure Lua: nothing in here touches `love.`, so the headless suite can drive
-- it the way `tests/agent-sync.test.ts` drives the browser's copy.

local M = {}

--- A room with nothing in it, at the cold-start cursor.
---
--- `messages` is the transcript in `timeid` order, `cursor` the highest
--- `timeid` folded so far (0 with nothing — the server never hands out 0, it
--- means "I have received nothing"), and `retired` the tombstones folded, by
--- id, with the `timeid` each carried — so a copy of a deleted message that
--- arrives afterwards (a page out of order, a replay) cannot bring it back.
function M.empty_room()
  return { messages = {}, cursor = 0, retired = {} }
end

--- Fold one page into the room.
---
--- Returns **two values**, `room, changed`: a new room table (the one passed in
--- is never touched, so a screen may keep rendering the old one) and whether
--- anything actually moved. The browser returns those as one object; here they
--- are two results, so a caller that writes `local r = M.fold(...)` quietly
--- drops the flag — take both when you mean to redraw only on a change.
function M.fold(room, page)
  if #page == 0 then return room, false end

  -- The fold is by id, so the working set is a table keyed by id rather than a
  -- list: a message seen twice lands on top of the copy held instead of beside
  -- it. Nothing about the order of this table is meaningful; the order is put
  -- back by the sort at the end.
  local by_id = {}
  for _, m in ipairs(room.messages) do by_id[m.id] = m end

  local retired = {}
  for id, timeid in pairs(room.retired) do retired[id] = timeid end

  local changed = false
  local cursor = room.cursor

  for _, m in ipairs(page) do
    if m.timeid > cursor then cursor = m.timeid end
    if m.deleted then
      -- A tombstone retires the copy and is remembered, so nothing older than
      -- it can bring the message back. It is remembered even for an id never
      -- held: the stale copy may still be on its way.
      if by_id[m.id] ~= nil then
        by_id[m.id] = nil
        changed = true
      end
      if retired[m.id] == nil or retired[m.id] < m.timeid then
        retired[m.id] = m.timeid
      end
    elseif retired[m.id] ~= nil and retired[m.id] >= m.timeid then
      -- Older than the tombstone, or the tombstone's own moment: a ghost.
      -- (A post under a retired id with a *later* timeid would be a server
      -- bug, and the fold still takes it, because the number says so.)
    else
      local held = by_id[m.id]
      -- Last writer by timeid wins; an older copy of what is held is noise.
      if not held or m.timeid >= held.timeid then
        -- The flag is about the room a person sees, not about the assignment:
        -- a replayed page carries copies identical to what is held, and a
        -- screen must not flash for those.
        if not held or held.timeid ~= m.timeid or held.text ~= m.text then
          changed = true
        end
        by_id[m.id] = m
      end
    end
  end

  if cursor ~= room.cursor then changed = true end

  local messages = {}
  for _, m in pairs(by_id) do messages[#messages + 1] = m end
  -- `pairs` over a table keyed by id comes out in whatever order the hash part
  -- happens to hold, which is not the order anything was inserted in and can
  -- differ run to run. The browser's `Map` does keep insertion order, so the
  -- sort there is a tidy-up; here it is the only thing standing between the
  -- transcript and nonsense. Sort by `timeid`, and by `id` when two messages
  -- share one, so the order is total and both clients agree on it.
  table.sort(messages, function(a, b)
    if a.timeid ~= b.timeid then return a.timeid < b.timeid end
    return a.id < b.id
  end)

  return { messages = messages, cursor = cursor, retired = retired }, changed
end

--- The cursor to send next: the room's, never lower than what a page carried.
---
--- Asked separately from the fold because the fold may well ignore a message
--- it has already got, while the cursor must still move past it.
function M.next_cursor(room, page)
  local c = room.cursor
  for _, m in ipairs(page) do
    if m.timeid > c then c = m.timeid end
  end
  return c
end

--- Whether a drain loop should ask again: the server said `more`, and the
--- cursor actually moved — a page that moved nothing would be asked for again
--- for ever.
--- Always a true boolean, never the nil a bare `and` would pass on when the
--- server left `more` out of its reply.
function M.should_continue(before, after, more)
  if not more then return false end
  return after > before
end

return M
