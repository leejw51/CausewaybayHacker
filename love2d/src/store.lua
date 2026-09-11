-- What this client is allowed to keep on disk.
--
-- PROTOCOL §6, rule 1: "Keep the session `token` (and only the token) in
-- durable storage. **Never the mnemonic or the private key.**"
--
-- So this file writes exactly two things, into LÖVE's save directory
-- (`love.filesystem`, `~/Library/Application Support/LOVE/causewaybay-hacker`
-- on macOS):
--
--   session.json   { token, address, name, server }
--   display.json   { mode, pinned, fullscreen }
--
-- `address` and `name` are here so the login screen can say "resume as Mei"
-- rather than an opaque token, and because the address is public by
-- construction — it is on the wire in both directions (§2.4). There is no
-- field for anything secret and `save_session` refuses a record that looks
-- like it carries one, because the check costs nothing and the mistake is
-- unrecoverable.

local json = require("src.json")

local Store = {}

local SESSION = "session.json"
local DISPLAY = "display.json"

--- Keys that must never appear in anything this module writes.
local FORBIDDEN = {
  "mnemonic", "phrase", "private_key", "privatekey", "secret", "seed",
  "passphrase", "entropy", "key",
}

local function read(name)
  if not love.filesystem.getInfo(name) then return nil end
  local body = love.filesystem.read(name)
  if not body then return nil end
  local value = json.try_decode(body)
  if type(value) ~= "table" then return nil end
  return value
end

local function write(name, value)
  local ok, err = love.filesystem.write(name, json.encode(value))
  if not ok then
    print("store: could not write " .. name .. ": " .. tostring(err))
  end
  return ok
end

--- True when `text` is shaped like a BIP-39 phrase.
---
--- **Space-separated** lowercase alphabetic words, twelve or more of them.
---
--- The first version of this counted runs of letters with `%a+` and demanded
--- no punctuation, which is not a description of a mnemonic — it is a
--- description of quite a lot of strings. The session token is base64url, 43
--- characters, and roughly one token in several has twelve letter-runs and
--- happens to contain neither `-` nor `_`. Those tokens were refused, the
--- refusal was raised through the reply handler, and the player's login hung
--- on a spinner forever. A heuristic guarding the most important rule in the
--- program has to be a heuristic about the actual thing.
local function looks_like_a_mnemonic(text)
  if #text < 30 then return false end
  local words = 0
  for word in text:gmatch("%S+") do
    if not word:match("^%a%a+$") then return false end
    words = words + 1
  end
  return words >= 12
end

Store.looks_like_a_mnemonic = looks_like_a_mnemonic

--- Check `record` for anything that looks like key material.
---
--- Returns true, or `nil, message`. A belt-and-braces check on the one rule
--- in this program that cannot be walked back: a mnemonic written to disk is
--- a mnemonic on somebody's backup, and no later fix removes it.
---
--- It reports rather than raising, because a false positive here must cost a
--- persisted session and nothing more — never the login itself.
function Store.check_no_secrets(record)
  for key, value in pairs(record or {}) do
    local lowered = tostring(key):lower()
    for _, bad in ipairs(FORBIDDEN) do
      if lowered:find(bad, 1, true) then
        return nil, "refusing to persist a field named " .. tostring(key)
      end
    end
    if type(value) == "table" then
      local ok, why = Store.check_no_secrets(value)
      if not ok then return nil, why end
    end
    -- A twelve-word phrase is a mnemonic no matter what the key is called.
    if type(value) == "string" and looks_like_a_mnemonic(value) then
      return nil, ("refusing to persist a %s that looks like a mnemonic"):format(tostring(key))
    end
  end
  return true
end

--- The raising form, for a caller that wants the program to stop.
function Store.assert_no_secrets(record)
  local ok, why = Store.check_no_secrets(record)
  if not ok then error("store: " .. why, 2) end
  return true
end

--- The stored session, or nil. Only ever the token and public identity.
function Store.load_session()
  local rec = read(SESSION)
  if not rec or type(rec.token) ~= "string" or rec.token == "" then return nil end
  return {
    token = rec.token,
    address = type(rec.address) == "string" and rec.address or nil,
    name = type(rec.name) == "string" and rec.name or nil,
    server = type(rec.server) == "string" and rec.server or nil,
  }
end

--- PROTOCOL §4.4 / §8 point 7: "The returned token may differ from the one
--- sent — the server rotates on use. **Store the returned one.**"
function Store.save_session(token, user, server)
  local record = {
    token = token,
    address = user and user.address or nil,
    name = user and user.name or nil,
    server = server,
  }
  local ok, why = Store.check_no_secrets(record)
  if not ok then
    -- Loud, and not fatal. Refusing to write is the safe half; taking the
    -- session down with it is not.
    print("store: " .. why .. " — the session was NOT saved")
    return false, why
  end
  return write(SESSION, record)
end

function Store.clear_session()
  if love.filesystem.getInfo(SESSION) then
    love.filesystem.remove(SESSION)
  end
end

function Store.load_display()
  return read(DISPLAY)
end

--- `pinned` is written alongside `mode`, and it is the field that matters:
--- without it a restored mode cannot be told from a chosen one, and the
--- client can never re-derive an orientation again. See `src/layout.lua`.
function Store.save_display(record)
  return write(DISPLAY, {
    mode = record.mode,
    pinned = record.pinned and true or false,
    fullscreen = record.fullscreen,
  })
end

--- Where the save directory is, for the footer and for a bug report.
function Store.where()
  return love.filesystem.getSaveDirectory()
end

return Store
