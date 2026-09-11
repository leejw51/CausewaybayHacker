-- PROTOCOL §3.3's closed set of error codes, and what this client does about
-- each one.
--
-- `message` on the wire is English for a log and explicitly **not** for the
-- player, so every code carries its own player-facing line here. A code that
-- is not in the table is a server bug and is treated as `internal`, which is
-- §8 point 4.
--
-- No `love.` in this file.

local M = {}

--- code -> { player, action }
---
--- `action` is what the client does, as a word the scene layer switches on:
---   "stop"    the client cannot continue; say so and stay put
---   "login"   drop to the login screen
---   "rechallenge" start `auth.challenge` again
---   "refresh" refetch the map
---   "show"    render the message in place
---   "backoff" wait `detail.retry_after_ms` and retry
---   "unavailable" real but unbuilt; say so in the story's voice, never retry
---   "log"     a bug in this client; make noise in the console
M.CODES = {
  proto_version = {
    player = "This client is too old for the server. Update it.",
    action = "stop",
  },
  bad_request = {
    player = "The client sent something the server could not read. That is a bug here.",
    action = "log",
  },
  unauthorized = {
    player = "Your session has ended. Sign in again.",
    action = "login",
  },
  auth_expired = {
    player = "The login challenge expired. Trying a fresh one.",
    action = "rechallenge",
  },
  auth_nonce_used = {
    player = "That login challenge was already used. Trying a fresh one.",
    action = "rechallenge",
  },
  auth_bad_signature = {
    player = "That key does not match the address. Check the mnemonic.",
    action = "login",
  },
  not_found = {
    player = "Not here yet.",
    action = "refresh",
  },
  locked = {
    player = "This street is locked. Clear the one before it first.",
    action = "show",
  },
  rate_limited = {
    player = "Too fast. Give it a moment.",
    action = "backoff",
  },
  busy = {
    player = "A submission is already running.",
    action = "show",
  },
  -- **Not `internal`.** §3.3: a feature that is real, specified and merely
  -- unbuilt answers `unavailable` with `detail.milestone`. Reporting it as
  -- `internal` tells the player their machine is broken and invites them to
  -- retry something that will never work; the honest line names the chapter.
  unavailable = {
    player = "Not built yet — it opens in a later chapter.",
    action = "unavailable",
  },
  internal = {
    player = "The server broke. Try again.",
    action = "show",
  },
}

--- Look up a code. An unknown one is folded into `internal` — PROTOCOL §3.3:
--- "A code not in this table is a server bug. A client encountering one
--- should treat it as `internal`."
---
--- The original code comes back in `.code` so a log line can name it.
function M.classify(code)
  local known = M.CODES[code]
  if known then
    return { code = code, known = true, player = known.player, action = known.action }
  end
  return {
    code = code,
    known = false,
    player = M.CODES.internal.player,
    action = M.CODES.internal.action,
  }
end

--- The milestone an `unavailable` feature is waiting for, if the server said.
---
--- §3.3: `unavailable` carries `detail.milestone`, and a screen that can name
--- the chapter says something a player can plan around rather than something
--- they will retry forever.
function M.milestone(payload)
  if type(payload) ~= "table" then return nil end
  local detail = payload.detail
  if type(detail) ~= "table" then return nil end
  return tonumber(detail.milestone)
end

--- True when `payload` is the exact §3.3 shape and nothing else.
---
--- Used by the test suite rather than by the client: the client must cope
--- with whatever it is given, but the suite gets to be strict.
function M.is_error_payload(payload)
  if type(payload) ~= "table" then return false end
  if type(payload.code) ~= "string" then return false end
  if type(payload.message) ~= "string" then return false end
  if type(payload.detail) ~= "table" then return false end
  local n = 0
  for _ in pairs(payload) do n = n + 1 end
  return n == 3
end

return M
