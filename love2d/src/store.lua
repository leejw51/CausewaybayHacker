-- The LÖVE client's own store: `~/.causewaybayhackerlove2d`, SPEC §1.1.
--
-- `~/.causewaybayhacker` is the **server's**. This client is a separate
-- program that may be talking to a server on another machine entirely, so it
-- keeps its own state, under its own directory, with the same conventions the
-- rest of this family uses: `0700` directory, `0600` files, **append-only
-- JSONL**, and state derived by replaying the log.
--
-- The convention is `CausewaybayWallet`'s `rustcli/core/src/store.rs`, and the
-- four properties its own suite tests are the four that matter here:
--
--   * a **malformed line is skipped**, not fatal — one bad line must not cost
--     the player their session and their map;
--   * a line from a **newer `schema`** is skipped, so an old binary degrades
--     instead of misreading records it does not understand;
--   * a **crash mid-write** costs at worst the last line, because every
--     record is one `write` of one complete line and nothing is rewritten;
--   * a value is the **last line that set it**, so a change is an append.
--
-- ## What is in it
--
-- Only what a client owns: the session token, the chosen server, the
-- orientation and fullscreen pins, and where each map was left.
--
-- **No key material, ever.** Not the mnemonic, not the private key, not the
-- seed. `check_no_secrets` is the belt on top of the braces, and it is
-- non-fatal by design — a false positive must cost a saved line and never the
-- login itself. (It has, once. See `docs/decisions.md`.)
--
-- ## The token is per server
--
-- A session token is minted by one server and means nothing to another. A
-- client that kept one token and pointed it at a new address would send a
-- stranger's credential and be told `unauthorized` for reasons the player
-- cannot possibly see. So tokens are keyed by the server URL — which also
-- means switching servers and switching back leaves you signed in to both.
--
-- ## Why `io.*` and not `love.filesystem`
--
-- `love.filesystem` is sandboxed to LÖVE's own save directory, and this path
-- is deliberately outside it. LuaJIT has the full stdlib, so `io.open` in
-- append mode is all this needs. What it does *not* have is `chmod`, which is
-- why `src/wallet.lua`'s library grew a `secure` op — the file holds a
-- credential and `0600` is not decorative.

local json = require("src.json")

local Store = {}

--- The schema this binary writes. A line claiming a higher one is from a
--- newer client and is skipped rather than guessed at.
Store.SCHEMA = 1

Store.DIR_ENV = "CWBH_LOVE2D_HOME"
Store.DEFAULT_DIR = ".causewaybayhackerlove2d"
Store.FILE = "state.jsonl"

Store.DEFAULT_SERVER = "ws://127.0.0.1:5390/ws"

--- Keys that must never appear in anything this module writes.
local FORBIDDEN = {
  "mnemonic", "phrase", "private_key", "privatekey", "secret", "seed",
  "passphrase", "entropy", "key",
}

-- In-memory state, folded from the log. `nil` until `Store.open` runs.
local state = nil
local path = nil
local dir = nil
local secure = nil       -- function(path, is_directory) -> ok
local warned_perms = false

-- ------------------------------------------------------------------- secrets

--- True when `text` is shaped like a BIP-39 phrase: **space-separated**
--- lowercase alphabetic words, twelve or more.
---
--- An earlier version counted runs of letters and demanded no punctuation,
--- which described a great many strings that are not mnemonics — including
--- roughly one base64url session token in several. It refused them, and the
--- refusal was raised through a reply handler, and the login hung on a
--- spinner forever. A heuristic guarding the most important rule in the
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

--- Check a record for anything that looks like key material.
--- Returns `true`, or `nil, message`. Reports; never raises.
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
    if type(value) == "string" and looks_like_a_mnemonic(value) then
      return nil, ("refusing to persist a %s that looks like a mnemonic"):format(tostring(key))
    end
  end
  return true
end

function Store.assert_no_secrets(record)
  local ok, why = Store.check_no_secrets(record)
  if not ok then error("store: " .. why, 2) end
  return true
end

-- --------------------------------------------------------------------- paths

function Store.home()
  local override = os.getenv(Store.DIR_ENV)
  if override and override ~= "" then return override end
  local home = os.getenv("HOME") or os.getenv("USERPROFILE")
  if not home or home == "" then return nil end
  return home .. "/" .. Store.DEFAULT_DIR
end

function Store.where()
  return path
end

function Store.directory()
  return dir
end

-- ------------------------------------------------------------------ the log

local function now_rfc3339()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

--- Apply the `0700` / `0600` the spec asks for.
---
--- Through the FFI when it is there, because LÖVE has no `chmod`; otherwise
--- once through `os.execute`, which is a process but happens at most twice
--- per launch rather than per write. If neither works the store still
--- functions and says so once — losing the session because a mode could not
--- be set would be the wrong trade, but doing it silently would be worse.
local function make_private(target, is_directory)
  if secure then
    local ok = secure(target, is_directory)
    if ok then return true end
  end
  if os.execute then
    if is_directory then
      os.execute(("mkdir -p %q 2>/dev/null && chmod 700 %q 2>/dev/null"):format(target, target))
    else
      os.execute(("chmod 600 %q 2>/dev/null"):format(target))
    end
    return true
  end
  if not warned_perms then
    warned_perms = true
    print("store: could not set owner-only permissions on " .. tostring(target))
  end
  return false
end

--- Read every well-formed record from the log, skipping junk.
---
--- Junk is: an empty line, a line that is not JSON, a line that is not an
--- object, and a line whose `schema` is newer than this binary's. A partial
--- last line — the one a crash mid-write leaves — is not JSON, so it falls
--- out here with everything else and costs exactly itself.
function Store.read_lines(file_path)
  local out = {}
  local fh = io.open(file_path, "r")
  if not fh then return out end
  for line in fh:lines() do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      local value = json.try_decode(trimmed)
      if type(value) == "table" and not getmetatable(value) then
        local schema = tonumber(value.schema) or 0
        if schema <= Store.SCHEMA then
          out[#out + 1] = value
        end
      end
    end
  end
  fh:close()
  return out
end

--- Fold a list of records into live state.
---
--- A pure function of the records, so the replay can be tested without a
--- filesystem — which is the whole point of an append-only log.
function Store.replay(records)
  local folded = {
    sessions = {},      -- server url -> { token, address, name }
    display = nil,
    server = nil,
    map = {},           -- "land.category" -> quest_id
    migrated = false,
    lines = 0,
  }
  for _, record in ipairs(records or {}) do
    folded.lines = folded.lines + 1
    local kind = record.kind
    if kind == "session.set" and type(record.server) == "string"
      and type(record.token) == "string" then
      folded.sessions[record.server] = {
        token = record.token,
        address = type(record.address) == "string" and record.address or nil,
        name = type(record.name) == "string" and record.name or nil,
      }
    elseif kind == "session.clear" and type(record.server) == "string" then
      folded.sessions[record.server] = nil
    elseif kind == "display.set" then
      folded.display = {
        mode = (record.mode == "portrait" or record.mode == "landscape")
          and record.mode or nil,
        pinned = record.pinned == true,
        fullscreen = type(record.fullscreen) == "boolean" and record.fullscreen or nil,
      }
    elseif kind == "server.set" and type(record.url) == "string" then
      folded.server = record.url
    elseif kind == "map.cursor" and type(record.map) == "string" then
      -- The field is `map`, not `key`: `check_no_secrets` refuses any field
      -- whose name contains "key" (to catch `private_key` and its spellings),
      -- and a field called `key` was therefore silently never written. Caught
      -- by `tests/test_store.lua`, which is the entire reason it exists.
      folded.map[record.map] = type(record.quest_id) == "string" and record.quest_id or nil
    elseif kind == "migrated" then
      folded.migrated = true
    end
  end
  return folded
end

--- Append one record. Returns true, or false and a reason.
function Store.append(record)
  if not state then return false, "the store is not open" end
  record.schema = Store.SCHEMA
  record.t = record.t or now_rfc3339()

  local ok, why = Store.check_no_secrets(record)
  if not ok then
    print("store: " .. why .. " — the line was NOT written")
    return false, why
  end

  -- No file to write to (no home): fold and carry on. The game works for
  -- this run and says nothing survives it, which beats refusing to start.
  if not path then
    Store.fold(record)
    return true
  end

  -- Does the file exist, and did the last write finish? A crash mid-write
  -- leaves a line with no newline on the end, and appending straight onto it
  -- would splice the fragment and the new record into one unparseable line —
  -- costing the good record as well as the torn one. So: start on a fresh
  -- line when the previous one did not end.
  local needs_newline = false
  local existed = io.open(path, "r")
  if existed then
    local size = existed:seek("end")
    if size > 0 then
      existed:seek("set", size - 1)
      needs_newline = existed:read(1) ~= "\n"
    end
    existed:close()
  end

  local fh, err = io.open(path, "a")
  if not fh then
    print("store: cannot append to " .. tostring(path) .. ": " .. tostring(err))
    return false, tostring(err)
  end
  -- One `write` of one complete line. A crash before it loses this record and
  -- nothing else; a crash during it leaves a partial line that `read_lines`
  -- discards as not-JSON and that the guard above will not splice onto.
  fh:write((needs_newline and "\n" or "") .. json.encode(record) .. "\n")
  fh:close()
  if not existed then make_private(path, false) end

  Store.fold(record)
  return true
end

--- Apply one record to live state, rather than re-reading the whole log.
---
--- One `replay` of one record, so the in-memory answer and the on-disk answer
--- can never drift: there is exactly one place that knows what a record
--- means.
function Store.fold(record)
  local folded = Store.replay({ record })
  if record.kind == "session.set" then
    state.sessions[record.server] = folded.sessions[record.server]
  elseif record.kind == "session.clear" then
    state.sessions[record.server] = nil
  elseif record.kind == "display.set" then
    state.display = folded.display
  elseif record.kind == "server.set" then
    state.server = folded.server
  elseif record.kind == "map.cursor" then
    state.map[record.map] = folded.map[record.map]
  elseif record.kind == "migrated" then
    state.migrated = true
  end
  state.lines = state.lines + 1
end

-- --------------------------------------------------------------------- open

--- Open (and create) the store. `opts.secure` is `function(path, is_dir)`.
function Store.open(opts)
  opts = opts or {}
  secure = opts.secure
  -- An explicit `false` means "no directory, run in memory"; `nil` means
  -- "work it out". A test that wanted the in-memory path and got the real
  -- store would write to the player's own file, which is worse than a
  -- failing test.
  dir = opts.dir
  if dir == nil then dir = Store.home() end
  if not dir then
    -- No home: run in memory, and say so. The game still works; nothing
    -- survives the process.
    print("store: no home directory — running without persistence")
    state = Store.replay({})
    path = nil
    return state
  end
  path = dir .. "/" .. Store.FILE
  make_private(dir, true)
  state = Store.replay(Store.read_lines(path))
  return state
end

function Store.state()
  return state
end

--- Close and forget, for tests.
function Store.reset()
  state, path, dir, secure = nil, nil, nil, nil
end

-- ------------------------------------------------------------------ sessions

--- The stored session **for this server**, or nil.
function Store.load_session(server)
  if not state then return nil end
  local record = state.sessions[server or Store.DEFAULT_SERVER]
  if not record or type(record.token) ~= "string" or record.token == "" then return nil end
  return {
    token = record.token,
    address = record.address,
    name = record.name,
    server = server,
  }
end

--- PROTOCOL §4.4 / §8.7: store the token that came back, not the one sent.
function Store.save_session(token, user, server)
  return Store.append({
    kind = "session.set",
    server = server or Store.DEFAULT_SERVER,
    token = token,
    address = user and user.address or nil,
    name = user and user.name or nil,
  })
end

function Store.clear_session(server)
  return Store.append({ kind = "session.clear", server = server or Store.DEFAULT_SERVER })
end

--- Every server this client holds a token for, for a "signed in to" list.
function Store.known_servers()
  local out = {}
  for server in pairs(state and state.sessions or {}) do out[#out + 1] = server end
  table.sort(out)
  return out
end

-- ------------------------------------------------------------------- display

function Store.load_display()
  return state and state.display or nil
end

function Store.save_display(record)
  return Store.append({
    kind = "display.set",
    mode = record.mode,
    pinned = record.pinned and true or false,
    fullscreen = record.fullscreen,
  })
end

-- -------------------------------------------------------------------- server

--- The saved server, or nil if the player has never chosen one.
function Store.saved_server()
  return state and state.server or nil
end

function Store.set_server(url)
  return Store.append({ kind = "server.set", url = url })
end

-- ----------------------------------------------------------------- map cursor

function Store.map_cursor(key)
  return state and state.map[key] or nil
end

function Store.set_map_cursor(key, quest_id)
  return Store.append({ kind = "map.cursor", map = key, quest_id = quest_id })
end

function Store.map_cursors()
  local out = {}
  for k, v in pairs(state and state.map or {}) do out[k] = v end
  return out
end

-- ----------------------------------------------------------------- migration

--- Bring LÖVE's old save directory across, once.
---
--- Somebody is playing right now with a session and a cleared map behind
--- `love.filesystem`. Starting fresh because the storage moved would be a
--- self-inflicted version of exactly the thing this game keeps warning
--- players about. The old files are **not deleted** — if this goes wrong, the
--- evidence should still be there.
---
--- `read` is `function(name) -> string|nil`, so this is testable without LÖVE.
function Store.migrate(read, server)
  if not state or state.migrated then return false end
  if type(read) ~= "function" then return false end

  local brought = {}

  local body = read("session.json")
  local old = body and json.try_decode(body)
  if type(old) == "table" and type(old.token) == "string" and old.token ~= "" then
    -- The old file held one token with the server it was minted by beside it.
    -- If that field is missing it predates the server field entirely, and the
    -- only server that ever existed then was the default.
    local from = type(old.server) == "string" and old.server or (server or Store.DEFAULT_SERVER)
    Store.save_session(old.token, { address = old.address, name = old.name }, from)
    brought[#brought + 1] = "session for " .. from
  end

  local display_body = read("display.json")
  local display = display_body and json.try_decode(display_body)
  if type(display) == "table" then
    Store.save_display({
      mode = display.mode,
      -- An old record has no `pinned`, and reading it as "not pinned" is the
      -- safe side: an unpinned mode is re-derived from the window, a wrongly
      -- pinned one never is.
      pinned = display.pinned == true,
      fullscreen = display.fullscreen,
    })
    brought[#brought + 1] = "display"
  end

  Store.append({ kind = "migrated", from = "love.filesystem", brought = #brought })
  if #brought > 0 then
    print("store: migrated " .. table.concat(brought, ", ") .. " from LÖVE's save directory")
  end
  return #brought > 0
end

return Store
