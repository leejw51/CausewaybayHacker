-- The client's own store: `~/.causewaybayhackerlove2d`, SPEC §1.1.
--
-- The four properties `CausewaybayWallet`'s own suite tests, because they are
-- the ones that decide whether an append-only log is a feature or a way to
-- lose somebody's session:
--
--   1. a malformed line is skipped, not fatal;
--   2. a line from a newer `schema` is skipped;
--   3. a crash mid-write costs at worst the last line;
--   4. two tokens for two servers do not collide.
--
-- Headless: `Store` touches no `love`, and everything here goes through a
-- real file under `$TMPDIR` so the `io.*` path is the one being tested rather
-- than a stub of it.

local T = require("tests.framework")
local Store = require("src.store")
local json = require("src.json")

local function scratch()
  local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")
  local dir = ("%s/cwbh-store-%d-%d"):format(base, os.time(), math.random(1, 1e6))
  os.execute(("mkdir -p %q"):format(dir))
  return dir
end

local function wipe(dir)
  os.remove(dir .. "/" .. Store.FILE)
  os.execute(("rmdir %q 2>/dev/null"):format(dir))
end

local function lines_of(dir)
  local out = {}
  local fh = io.open(dir .. "/" .. Store.FILE, "r")
  if not fh then return out end
  for line in fh:lines() do out[#out + 1] = line end
  fh:close()
  return out
end

local function raw_append(dir, text)
  local fh = io.open(dir .. "/" .. Store.FILE, "a")
  fh:write(text)
  fh:close()
end

return function()
  T.section("store — append and replay")

  T.case("a value is the last line that set it", function()
    local dir = scratch()
    Store.open({ dir = dir })
    Store.set_server("ws://127.0.0.1:5390/ws")
    Store.set_server("ws://100.64.0.2:5390/ws")
    T.eq(Store.saved_server(), "ws://100.64.0.2:5390/ws")
    -- And it is two lines, not one rewritten: that is what append-only means.
    T.eq(#lines_of(dir), 2)

    -- Reopening replays to the same answer.
    Store.reset()
    Store.open({ dir = dir })
    T.eq(Store.saved_server(), "ws://100.64.0.2:5390/ws")
    Store.reset()
    wipe(dir)
  end)

  T.case("every line carries a schema and a timestamp", function()
    local dir = scratch()
    Store.open({ dir = dir })
    Store.set_server("ws://127.0.0.1:5390/ws")
    local record = json.decode(lines_of(dir)[1])
    T.eq(record.schema, Store.SCHEMA)
    T.eq(record.kind, "server.set")
    T.ok(record.t:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil,
      "RFC3339 UTC, as §2.4 spells timestamps: " .. tostring(record.t))
    Store.reset()
    wipe(dir)
  end)

  T.section("store — a bad line costs itself and nothing else")

  T.case("malformed lines are skipped, not fatal", function()
    local dir = scratch()
    Store.open({ dir = dir })
    Store.set_server("ws://one:5390/ws")
    Store.reset()

    -- Every shape of junk somebody could end up with.
    raw_append(dir, "this is not json at all\n")
    raw_append(dir, "\n")
    raw_append(dir, "   \n")
    raw_append(dir, "[1,2,3]\n")          -- JSON, but not an object
    raw_append(dir, '"a string"\n')
    raw_append(dir, "{unclosed\n")

    Store.open({ dir = dir })
    Store.set_server("ws://two:5390/ws")
    T.eq(Store.saved_server(), "ws://two:5390/ws", "the log still replays")
    Store.reset()

    Store.open({ dir = dir })
    T.eq(Store.saved_server(), "ws://two:5390/ws", "and again after a reopen")
    Store.reset()
    wipe(dir)
  end)

  T.case("a line from a newer schema is skipped", function()
    local dir = scratch()
    Store.open({ dir = dir })
    Store.set_server("ws://known:5390/ws")
    Store.reset()

    -- A future client wrote this. An old binary must degrade rather than
    -- misread a record it does not understand.
    raw_append(dir, json.encode({
      schema = Store.SCHEMA + 1, kind = "server.set", url = "ws://from-the-future:1/ws",
    }) .. "\n")

    Store.open({ dir = dir })
    T.eq(Store.saved_server(), "ws://known:5390/ws",
      "the newer line was skipped, not applied")
    Store.reset()
    wipe(dir)
  end)

  T.case("a crash mid-write costs at worst the last line", function()
    local dir = scratch()
    Store.open({ dir = dir })
    Store.save_session("token-one", { address = "0xaaa", name = "mei" }, "ws://a:5390/ws")
    Store.set_server("ws://a:5390/ws")
    Store.reset()

    -- The machine died halfway through the next line.
    raw_append(dir, '{"schema":1,"kind":"server.set","url":"ws://b:53')

    Store.open({ dir = dir })
    T.eq(Store.saved_server(), "ws://a:5390/ws", "the torn line is gone")
    local session = Store.load_session("ws://a:5390/ws")
    T.ok(session ~= nil, "and everything before it survived")
    T.eq(session.token, "token-one")

    -- Writing after a torn line still works: the next append starts on its
    -- own line, and the fragment is skipped for good.
    Store.set_server("ws://c:5390/ws")
    Store.reset()
    Store.open({ dir = dir })
    T.eq(Store.saved_server(), "ws://c:5390/ws")
    Store.reset()
    wipe(dir)
  end)

  T.section("store — SPEC §1.1: the token is per server")

  T.case("two servers keep two tokens, and neither is sent to the other", function()
    local dir = scratch()
    Store.open({ dir = dir })
    local a, b = "ws://127.0.0.1:5390/ws", "ws://100.64.0.2:5390/ws"
    Store.save_session("token-local", { address = "0xaaa", name = "mei" }, a)
    Store.save_session("token-remote", { address = "0xbbb", name = "mei" }, b)

    T.eq(Store.load_session(a).token, "token-local")
    T.eq(Store.load_session(b).token, "token-remote")
    T.eq(Store.load_session(a).address, "0xaaa")
    T.eq(Store.load_session(b).address, "0xbbb")
    T.eq(Store.load_session("ws://never-seen:5390/ws"), nil,
      "a server this client has never met has no token, not somebody else's")
    T.same(Store.known_servers(), { b, a })

    -- Signing out of one leaves the other alone — which is what makes
    -- switching away and back leave you signed in to both.
    Store.clear_session(a)
    T.eq(Store.load_session(a), nil)
    T.eq(Store.load_session(b).token, "token-remote")

    Store.reset()
    Store.open({ dir = dir })
    T.eq(Store.load_session(a), nil, "and that survives a replay")
    T.eq(Store.load_session(b).token, "token-remote")
    Store.reset()
    wipe(dir)
  end)

  T.section("store — no key material, ever")

  T.case("a record that looks like key material is refused, not written", function()
    local dir = scratch()
    Store.open({ dir = dir })
    local phrase =
      "legal winner thank year wave sausage worth useful legal winner thank yellow"
    T.eq(Store.append({ kind = "server.set", url = "ws://a:1/ws", note = phrase }), false)
    T.eq(Store.append({ kind = "server.set", mnemonic = "x" }), false)
    T.eq(Store.append({ kind = "server.set", nested = { private_key = "0x00" } }), false)
    T.eq(#lines_of(dir), 0, "nothing reached the disk")

    -- And the thing that actually gets written does not trip it: a base64url
    -- token has twelve runs of letters often enough that a sloppier
    -- heuristic refused them, and hung the login. See docs/decisions.md.
    T.eq(Store.save_session("kR3aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkLmN", nil,
      "ws://a:1/ws"), true)
    T.eq(#lines_of(dir), 1)
    Store.reset()
    wipe(dir)
  end)

  T.section("store — migration from LÖVE's save directory")

  T.case("the old session and display come across, once", function()
    local dir = scratch()
    Store.open({ dir = dir })
    local old = {
      ["session.json"] = json.encode({
        token = "old-token", address = "0xaaa", name = "mei",
        server = "ws://127.0.0.1:5390/ws",
      }),
      ["display.json"] = json.encode({ mode = "portrait", fullscreen = true }),
    }
    local read = function(name) return old[name] end

    T.eq(Store.migrate(read, Store.DEFAULT_SERVER), true)
    T.eq(Store.load_session("ws://127.0.0.1:5390/ws").token, "old-token")
    local display = Store.load_display()
    T.eq(display.mode, "portrait")
    T.eq(display.fullscreen, true)
    T.eq(display.pinned, false, "an old record has no pin, and guessing one is the unsafe side")

    -- Once. A second call must not re-apply a stale token over a newer one.
    Store.save_session("newer-token", nil, "ws://127.0.0.1:5390/ws")
    T.eq(Store.migrate(read, Store.DEFAULT_SERVER), false)
    T.eq(Store.load_session("ws://127.0.0.1:5390/ws").token, "newer-token")

    Store.reset()
    Store.open({ dir = dir })
    T.eq(Store.migrate(read, Store.DEFAULT_SERVER), false, "and not after a restart either")
    T.eq(Store.load_session("ws://127.0.0.1:5390/ws").token, "newer-token")
    Store.reset()
    wipe(dir)
  end)

  T.case("a missing or unreadable old save is not an error", function()
    local dir = scratch()
    Store.open({ dir = dir })
    T.eq(Store.migrate(function() return nil end, Store.DEFAULT_SERVER), false)
    T.eq(Store.migrate(function() return "{not json" end, Store.DEFAULT_SERVER), false)
    T.eq(Store.migrate(nil, Store.DEFAULT_SERVER), false)
    Store.reset()
    wipe(dir)
  end)

  T.section("store — the map cursor and the display")

  T.case("each map's cursor is remembered, per land and category", function()
    local dir = scratch()
    Store.open({ dir = dir })
    Store.set_map_cursor("rust.basic", "rust.basic.05.slices")
    Store.set_map_cursor("go.hacker", "go.hacker.03.intervals")
    T.eq(Store.map_cursor("rust.basic"), "rust.basic.05.slices")
    T.eq(Store.map_cursor("go.hacker"), "go.hacker.03.intervals")
    T.eq(Store.map_cursor("rust.hacker"), nil)
    Store.reset()
    Store.open({ dir = dir })
    T.eq(Store.map_cursor("rust.basic"), "rust.basic.05.slices", "across a restart")
    Store.reset()
    wipe(dir)
  end)

  T.case("the display pins round-trip, `pinned` included", function()
    local dir = scratch()
    Store.open({ dir = dir })
    Store.save_display({ mode = "portrait", pinned = true, fullscreen = true })
    Store.reset()
    Store.open({ dir = dir })
    local d = Store.load_display()
    T.eq(d.mode, "portrait")
    T.eq(d.pinned, true)
    T.eq(d.fullscreen, true)
    Store.reset()
    wipe(dir)
  end)

  T.section("store — replay is a pure fold")

  T.case("replay can be driven with no filesystem at all", function()
    local folded = Store.replay({
      { kind = "server.set", url = "ws://a:1/ws" },
      { kind = "session.set", server = "ws://a:1/ws", token = "t1", name = "mei" },
      { kind = "server.set", url = "ws://b:1/ws" },
      { kind = "session.clear", server = "ws://a:1/ws" },
      { kind = "map.cursor", map = "rust.basic", quest_id = "rust.basic.02.bindings" },
      { kind = "who.knows", anything = true },     -- an unknown kind is ignored
    })
    T.eq(folded.server, "ws://b:1/ws")
    T.eq(folded.sessions["ws://a:1/ws"], nil)
    T.eq(folded.map["rust.basic"], "rust.basic.02.bindings")
    T.eq(folded.lines, 6)
  end)

  T.case("with no home the store runs in memory rather than failing", function()
    -- `dir = false` is the explicit "there is nowhere to write" case. The
    -- game still runs; nothing survives the process, and it says so once.
    Store.reset()
    Store.open({ dir = false })
    T.ok(Store.state() ~= nil, "there is still state to read")
    T.eq(Store.where(), nil, "and no file behind it")
    T.eq(Store.set_server("ws://a:1/ws"), true, "writes are accepted")
    T.eq(Store.saved_server(), "ws://a:1/ws", "and readable for this run")
    Store.reset()
  end)
end
