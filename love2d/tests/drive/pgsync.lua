-- A pad saved on another device while this one has unsaved typing (§4.22),
-- against the real server.
--
--   make -C love2d drive SCRIPT=tests/drive/pgsync.lua ARGS="--home $(mktemp -d)"
--
-- The other device is a second session opened inside this process, signed in
-- as the same account over its own socket: to the server it is a second
-- window like any other, and its saves reach this one as `playground.updated`.
-- The run checks, through the real screen and the real keys:
--
--   1. a clean pad takes the other device's save by itself;
--   2. a dirty pad asks, keeps its text, and saves nothing while it asks;
--   3. T takes theirs, and the T is not typed into the code;
--   4. K keeps mine and saves it, and the other device receives it.

local netclient = require("src.net.client")
local socket_transport = require("src.net.socket")
local Session = require("src.session")

local PHRASE = "legal winner thank year wave sausage worth useful legal winner thank yellow"
local RUN = tostring(os.time())

local steps = {}
local function add(t) steps[#steps + 1] = t end
local fail = false
local function check(ok, why)
  if ok then return true end
  print("FAIL: " .. why)
  fail = true
  return false
end
local function pg(app) return app.scene_name == "playground" and app.scene or nil end
local function has(text, part) return text and text:find(part, 1, true) ~= nil end

-- The other device.
local other = { client = nil, session = nil, authed = false, last = nil, pad = nil }
local function pump(dt) if other.client then other.client:update(dt or 0.016) end end
local function other_save(source, done)
  other.session:request("playground.save", {
    id = other.pad, lang = "rust", source = source, stdin = "",
  }, function(ok, reply)
    check(ok, "the other device's save was refused")
    if done then done(ok, reply) end
  end)
end
-- Hold this screen's autosave off, the way a slow typist would: the other
-- device's save has to land while this pad is still dirty.
local function hold_autosave(s) s.dirty_at = math.huge end

add({ orient = "landscape" })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      note = "login, or already resumed", timeout = 20 })
add({ text = PHRASE, when = function(app) return app.scene_name == "login" end })
add({ key = "return", when = function(app) return app.scene_name == "login" end })
add({ until_ = function(app) return app.scene_name == "lands" end, note = "signed in", timeout = 30 })

-- The second device: its own client, its own socket, the same account.
add({ until_ = function(app)
      other.client = netclient.new({
        url = app.server,
        transport = socket_transport.factory(),
        now = function() return love.timer.getTime() end,
        rand = function(lo, hi) return love.math.random(lo, hi) end,
        log = function() end,
      })
      other.session = Session.new({
        client = other.client,
        lib = app.session.lib,
        store = {
          load_session = function() return nil end,
          save_session = function() end,
          clear_session = function() end,
        },
      })
      other.client:on("playground.updated", function(payload)
        other.last = payload and payload.snippet
      end)
      other.client:connect()
      return true
    end, note = "the other device connects", timeout = 5 })
add({ until_ = function()
      pump()
      return other.client.state == "open"
    end, note = "its socket is open", timeout = 15 })
add({ until_ = function()
      other.session:login(PHRASE, 0, nil, function(ok, why)
        check(ok, "the other device could not sign in: " .. tostring(why))
        other.authed = ok
      end)
      return true
    end, timeout = 5 })
add({ until_ = function() pump(); return other.authed end,
      note = "the other device is signed in", timeout = 20 })

-- The other device makes a pad; this one opens it.
add({ until_ = function()
      other.session:request("playground.save", {
        name = "sync" .. RUN, lang = "rust",
        source = "fn main() { /* one " .. RUN .. " */ }\n", stdin = "",
      }, function(ok, reply)
        check(ok, "the other device could not make a pad")
        if ok then other.pad = reply.snippet.id end
      end)
      return true
    end, timeout = 5 })
add({ until_ = function() pump(); return other.pad ~= nil end, note = "the pad exists", timeout = 15 })
add({ until_ = function(app) app:go("playground"); return true end, timeout = 5 })
add({ until_ = function(app) return pg(app) ~= nil and pg(app).snippets ~= nil end,
      note = "the playground, with its list", timeout = 15 })
add({ until_ = function(app)
      local s = pg(app)
      for i, brief in ipairs(s.snippets) do
        if brief.id == other.pad then s:load(i); return true end
      end
      s:list()
      return false
    end, note = "the pad is in the list", timeout = 15 })
add({ until_ = function(app) return has(pg(app).editor:text(), "one " .. RUN) end,
      note = "and open here", timeout = 10 })

-- 1. Clean here: the other device's save simply arrives.
add({ until_ = function() other_save("fn main() { /* two " .. RUN .. " */ }\n"); return true end,
      timeout = 5 })
add({ until_ = function(app) pump(); return has(pg(app).editor:text(), "two " .. RUN) end,
      note = "a clean pad took the save", timeout = 15 })
add({ until_ = function(app)
      check(pg(app).conflict == nil, "a clean pad asked a question")
      return true
    end, timeout = 3 })

-- 2. Dirty here, and the other device saves: the question.
add({ until_ = function(app) pg(app).focus = "editor"; return true end, timeout = 2 })
add({ key = "end", mods = { ctrl = true } })
add({ text = "// here" })
add({ until_ = function(app)
      local s = pg(app)
      hold_autosave(s)
      return s.editor.dirty
    end, note = "typing here, unsaved", timeout = 5 })
add({ until_ = function() other_save("fn main() { /* three " .. RUN .. " */ }\n"); return true end,
      timeout = 5 })
add({ until_ = function(app) pump(); return pg(app).conflict ~= nil end,
      note = "the question is asked", timeout = 15 })
add({ wait = 3.5 }) -- past the sign-in toast, which is drawn over every screen
add({ shot = "S1-playground-conflict.png" })
add({ until_ = function(app)
      local s = pg(app)
      check(has(s.editor:text(), "// here"), "the typing here was replaced before anybody chose")
      check(s.conflict_rects ~= nil, "the question was not drawn")
      return true
    end, timeout = 3 })
-- Nothing is saved while it asks: the autosave comes due, and SAVE is pressed.
add({ until_ = function(app) pg(app).dirty_at = -1e9; return true end, timeout = 2 })
add({ key = "s", mods = { ctrl = true } })
add({ wait = 1.5 })
add({ until_ = function()
      pump()
      check(other.last == nil or not has(other.last.source, "// here"),
        "a save went out while the question was open")
      return true
    end, timeout = 3 })

-- 3. T: take theirs, and no T in the code.
-- The drive's key sends the letter on as `textinput` after the key, the way
-- LÖVE itself does, so this is the real double delivery the scene guards.
add({ key = "t" })
add({ until_ = function(app)
      local s = pg(app)
      return s.conflict == nil and has(s.editor:text(), "three " .. RUN)
    end, note = "took theirs", timeout = 5 })
add({ until_ = function(app)
      local s = pg(app)
      check(not has(s.editor:text(), "// here"), "the typing here survived TAKE THEIRS")
      check(not s.editor.dirty, "the pad was left dirty after TAKE THEIRS")
      check(s.editor:text() == "fn main() { /* three " .. RUN .. " */ }\n",
        "the answering T was typed into the code: " .. s.editor:text())
      return true
    end, timeout = 3 })
add({ shot = "S2-playground-took-theirs.png" })

-- 4. Again, and K: keep mine, and the other device receives it.
add({ key = "end", mods = { ctrl = true } })
add({ text = "// mine wins" })
add({ until_ = function(app)
      local s = pg(app)
      hold_autosave(s)
      return s.editor.dirty
    end, note = "typing here again", timeout = 5 })
add({ until_ = function() other_save("fn main() { /* four " .. RUN .. " */ }\n"); return true end,
      timeout = 5 })
add({ until_ = function(app) pump(); return pg(app).conflict ~= nil end,
      note = "asked again", timeout = 15 })
-- Upright, the way a tablet is held: the question has to fit there too.
add({ orient = "portrait" })
add({ wait = 0.5 })
add({ shot = "S3-playground-conflict-portrait.png" })
-- By the button this time, the way a finger answers.
add({ click = function(app) local r = pg(app).conflict_rects.mine
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function()
      pump()
      return other.last ~= nil and has(other.last.source, "// mine wins")
    end, note = "the other device received KEEP MINE", timeout = 15 })
add({ until_ = function(app)
      local s = pg(app)
      check(s.conflict == nil, "the question stayed open after KEEP MINE")
      check(has(s.editor:text(), "// mine wins"), "KEEP MINE lost the text here")
      check(has(other.last.source, "three " .. RUN), "KEEP MINE did not save this device's text")
      return true
    end, timeout = 3 })
add({ shot = "S4-playground-kept-mine.png" })

add({ until_ = function()
      if other.client then other.client:close(1000, "done") end
      print("playground sync: " .. (fail and "FAILED" or "0 failures"))
      if fail then error("playground sync drive failed", 0) end
      return true
    end, timeout = 3 })
add({ quit = true })
return steps
