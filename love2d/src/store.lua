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
--   display.json   { mode, fullscreen }
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

--- Raise if `record` carries anything that looks like key material.
---
--- A belt-and-braces check on the one rule in this program that cannot be
--- walked back: a mnemonic written to disk is a mnemonic on somebody's
--- backup, and no later fix removes it.
function Store.assert_no_secrets(record)
  for key, value in pairs(record or {}) do
    local lowered = tostring(key):lower()
    for _, bad in ipairs(FORBIDDEN) do
      if lowered:find(bad, 1, true) then
        error("store: refusing to persist a field named " .. tostring(key), 2)
      end
    end
    if type(value) == "table" then
      Store.assert_no_secrets(value)
    end
    -- A twelve-word string is a mnemonic no matter what the key is called.
    if type(value) == "string" then
      local words = 0
      for _ in value:gmatch("%a+") do words = words + 1 end
      if words >= 12 and not value:find("[%p]") and #value > 40 then
        error("store: refusing to persist a value that looks like a mnemonic", 2)
      end
    end
  end
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
  Store.assert_no_secrets(record)
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

function Store.save_display(record)
  return write(DISPLAY, { mode = record.mode, fullscreen = record.fullscreen })
end

--- Where the save directory is, for the footer and for a bug report.
function Store.where()
  return love.filesystem.getSaveDirectory()
end

return Store
