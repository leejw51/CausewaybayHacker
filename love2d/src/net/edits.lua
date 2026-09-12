-- The edit stack: PROTOCOL's five `edit.*` messages, and the two rules a
-- screen needs in order to draw them.
--
-- One stack per `(address, quest_id)`, kept by the server in SQLite and on
-- its own disk, so the history of a quest follows the player between this
-- client and the browser one and survives a reload. This client models none
-- of that. Every one of the five replies is the **whole** state —
--
--     { quest_id, source, cursor, depth, can_undo, can_redo }
--
-- — so the screen renders what it is told rather than keeping a second copy
-- of the stack and discovering later that the two disagree.
--
-- ## Why the two booleans are computed here rather than read
--
-- PROTOCOL defines `can_undo` as `cursor > 0` and `can_redo` as
-- `cursor < depth`, and this file derives both from the numbers instead of
-- taking the server's word for them. Not distrust: the same screen prints
-- `stack 3/5` beside the buttons, and a greyed UNDO under a caption that says
-- there are three steps behind you is a screen contradicting itself. One
-- source of truth for the caption and the button means that cannot happen,
-- and a server that ever disagreed with its own arithmetic would be the bug
-- rather than this.
--
-- A state this client never received is `nil`, and every predicate below
-- answers `false` for it. That is the degradation that matters: a server with
-- no edit stack yet answers `not_found`, the scene keeps `nil`, and the three
-- buttons stay grey while the rest of the quest screen works exactly as it
-- did before.
--
-- LÖVE-free, like everything else under `src/net/`: `make check-layering` and
-- `T.no_love` both assert it, and the whole of this file's behaviour is
-- checked headlessly in `tests/test_edits.lua`.

local M = {}

--- The five messages, spelled once. A typo in a type name is a `not_found`
--- that looks exactly like an old server, which is the most expensive kind of
--- typo this client can make.
M.STATE = "edit.state"
M.PUSH = "edit.push"
M.UNDO = "edit.undo"
M.REDO = "edit.redo"
M.CLEAR = "edit.clear"

--- The same cap `quest.submit` uses: past it the server answers `bad_request`
--- and the push is refused. Checked before sending rather than after, because
--- an autosave that fails is an autosave nobody sees fail.
M.MAX_SOURCE_BYTES = 256 * 1024

--- The deepest a stack goes before the server drops its oldest entry. Not
--- enforced here — it is the server's rule — but the caption that prints
--- `stack %d/%d` is the only place a player ever meets the number, so it is
--- worth being able to say it.
M.MAX_DEPTH = 100

local function number(value, fallback)
  if type(value) == "number" and value == value then return value end
  return fallback
end

--- An `EditState` out of whatever the wire actually carried.
---
--- `src/net/client.lua`'s `denull` has already turned a JSON `null` into
--- absence by the time a scene sees a payload, so `source = nil` here means
--- exactly what `source: null` means on the wire: *the starter*, because the
--- cursor is at the bottom of the stack and nothing has been applied.
--- `text_for` is the one place that rule is written down.
---
--- Anything that is not a table comes back as `nil` rather than as an empty
--- state, so "the server has not answered" and "the stack is empty" stay
--- distinguishable — the first greys the buttons, the second greys only two
--- of them.
function M.normalize(payload)
  if type(payload) ~= "table" then return nil end
  local depth = math.max(0, math.floor(number(payload.depth, 0)))
  local cursor = math.max(0, math.min(depth, math.floor(number(payload.cursor, 0))))
  return {
    quest_id = type(payload.quest_id) == "string" and payload.quest_id or nil,
    source = type(payload.source) == "string" and payload.source or nil,
    cursor = cursor,
    depth = depth,
  }
end

--- `cursor > 0`: there is an entry behind the cursor to step back to.
function M.can_undo(state)
  if type(state) ~= "table" then return false end
  return number(state.cursor, 0) > 0
end

--- `cursor < depth`: the redo tail is not empty. A push after an undo drops
--- that tail, which is the classic rule and the server's to apply.
function M.can_redo(state)
  if type(state) ~= "table" then return false end
  return number(state.cursor, 0) < number(state.depth, 0)
end

--- There is a history to drop. Clearing an empty stack changes nothing, so
--- the button is grey rather than being a control that does nothing.
function M.can_clear(state)
  if type(state) ~= "table" then return false end
  return number(state.depth, 0) > 0
end

--- The text the cursor points at.
---
--- Two cases and they are the whole of it: an entry, which is a string and is
--- used exactly as it is — an **empty** entry is a real edit, somebody who
--- cleared the buffer — and no entry, which means the cursor is at the bottom
--- and the quest's starter is what the editor should show.
function M.text_for(state, starter)
  if type(state) == "table" and type(state.source) == "string" then
    return state.source
  end
  if type(starter) == "string" then return starter end
  return ""
end

--- One send for all five, so the reply shape is parsed in one place.
---
--- `cb(ok, state, payload, why)` — `state` is the normalized `EditState` on
--- success and `nil` otherwise; `payload` is the raw reply (or §3.3's error),
--- and `why` is `src/net/errors.lua`'s classification of a failure. Callers
--- want all three: the state to draw, the code to decide whether this server
--- has the feature at all, and the sentence for anything else.
local function send(session, type_name, payload, cb)
  if type(session) ~= "table" or type(session.request) ~= "function" then
    if cb then
      cb(false, nil, { code = "internal", message = "no session" }, nil)
    end
    return nil
  end
  return session:request(type_name, payload, function(ok, reply, why)
    if not cb then return end
    cb(ok, ok and M.normalize(reply) or nil, reply or {}, why)
  end)
end

M.send = send

--- Where the stack stands, without changing it. Asked once when the quest
--- screen opens.
function M.state(session, quest_id, cb)
  return send(session, M.STATE, { quest_id = quest_id }, cb)
end

--- Put the buffer on the stack. A push whose source equals the entry at the
--- cursor is a no-op on the server, which is what lets the screen call this
--- on a timer without filling the history with duplicates.
function M.push(session, quest_id, source, cb)
  return send(session, M.PUSH, { quest_id = quest_id, source = source }, cb)
end

function M.undo(session, quest_id, cb)
  return send(session, M.UNDO, { quest_id = quest_id }, cb)
end

function M.redo(session, quest_id, cb)
  return send(session, M.REDO, { quest_id = quest_id }, cb)
end

--- Drop every entry. The editor keeps whatever text it is showing: clearing
--- the history is not an edit, and a button that threw away somebody's code
--- would be a different button.
function M.clear(session, quest_id, cb)
  return send(session, M.CLEAR, { quest_id = quest_id }, cb)
end

--- True when a failure means "this server has no edit stack" rather than
--- "something went wrong". Both arrive as an error; only the first is a
--- reason to grey the three buttons for the rest of the visit, which is the
--- trap `quest.run` and `quest.solve` on this same screen already document.
function M.unsupported(payload)
  local code = type(payload) == "table" and payload.code or nil
  return code == "not_found" or code == "unavailable"
end

return M
