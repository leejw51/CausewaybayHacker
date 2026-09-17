-- The Rust coder, in the client, against a real model (§4.9f, docs/agent.md).
--
--   make -C love2d drive SCRIPT=tests/drive/agent.lua
--
-- What this walks through is the whole feature, in the order a player meets
-- it: sign in, open a scratchpad, press AGENT, put a key in SETUP, ask for a
-- program, watch it be typed in one character at a time, and check the room
-- kept what was said. It needs a key in the environment — `GROK_API_KEY`,
-- `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`, whichever is there — and says so
-- and stops if there is none, because the point of this script is the part
-- that talks to a provider.
--
-- Every key it reads goes into the panel's own field, the way a person would
-- paste it. Nothing here writes one to the store on purpose: the run uses a
-- throwaway home (`ARGS="--home $(mktemp -d)"`) when you want that.

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
local function coder(app) local s = pg(app); return s and s.coder or nil end

-- Which provider this run can afford. The panel's tabs are in this order too.
local PROVIDERS = {
  { name = "grok", env = "GROK_API_KEY" },
  { name = "openai", env = "OPENAI_API_KEY" },
  { name = "anthropic", env = "ANTHROPIC_API_KEY" },
}
local provider, key = nil, nil
for _, candidate in ipairs(PROVIDERS) do
  local value = os.getenv(candidate.env)
  if value and value ~= "" then
    provider, key = candidate.name, value
    break
  end
end

add({ orient = "landscape" })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      note = "login, or already resumed", timeout = 20 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = function(app) return app.scene_name == "login" end })
add({ key = "return", when = function(app) return app.scene_name == "login" end })
add({ until_ = function(app) return app.scene_name == "lands" end,
      note = "signed in", timeout = 30 })
add({ until_ = function(app) app:go("playground"); return true end, timeout = 5 })
add({ until_ = function(app) return pg(app) ~= nil end, note = "the playground", timeout = 10 })
add({ wait = 0.5 })

-- The panel opens from the header's AGENT button, as a player opens it.
add({ until_ = function(app)
      local s = pg(app)
      check(s.agent_button_rect ~= nil, "no AGENT button on the playground")
      check(coder(app) ~= nil, "the playground made no coder")
      return s.agent_button_rect ~= nil
    end, timeout = 5 })
add({ click = function(app) local r = pg(app).agent_button_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return coder(app).panel.open end, note = "the panel", timeout = 5 })
add({ wait = 1.2 })
add({ shot = "A1-agent-open.png" })

-- The sprite arrives on its entrance and then flies: two samples far enough
-- apart to have moved.
local first_x = nil
add({ until_ = function(app)
      first_x = coder(app).sprite.x
      check(coder(app).presence > 0.5, "the coder is not on the screen")
      return true
    end, timeout = 5 })
add({ wait = 2.5 })
add({ until_ = function(app)
      local sprite = coder(app).sprite
      check(math.abs(sprite.x - first_x) > 1 or sprite.state ~= "wander",
        "the coder did not move at all")
      print(("coder: state=%s scale=%.2f wake=%d"):format(sprite.state, sprite.scale, #sprite.wake))
      return true
    end, timeout = 5 })

if not provider then
  add({ until_ = function()
      print("no provider key in the environment — set GROK_API_KEY, OPENAI_API_KEY"
        .. " or ANTHROPIC_API_KEY to drive the asking half")
      return true
    end, timeout = 2 })
  add({ shot = "A2-agent-nokey.png" })
  add({ until_ = function() print(fail and "DRIVE FAILED" or "drive ok (panel only)")
      return true end, timeout = 2 })
  add({ quit = true })
  return steps
end

-- SETUP, then the provider's tab, then the key into the field it belongs in.
add({ click = function(app) local r = coder(app).panel.rects["setup"]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return coder(app).panel.view == "setup" end,
      note = "SETUP", timeout = 5 })
add({ click = function(app) local r = coder(app).panel.rects["tab:" .. provider]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ click = function(app) local r = coder(app).panel.rects["key"]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ text = key })
add({ key = "escape" })
add({ until_ = function(app)
      local Prefs = require("src.agent.prefs")
      check(Prefs.provider() == provider, "the provider did not change to " .. provider)
      check(Prefs.key(provider) ~= "", "the key did not reach the preferences")
      print(("setup: %s · %s · key %s"):format(provider, Prefs.model(provider),
        Prefs.mask(Prefs.key(provider))))
      return coder(app).panel.view == "chat"
    end, note = "back to the room", timeout = 5 })
add({ shot = "A3-agent-setup.png" })

-- The ask. WRITE is the verb that makes a program rather than a sentence.
add({ click = function(app) local r = coder(app).panel.rects["input"]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ text = "a program that prints the numbers 1 to 5, one per line" })
add({ click = function(app) local r = coder(app).panel.rects["write"]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return coder(app).session:busy() end,
      note = "the ask went out", timeout = 10 })
add({ wait = 2 })
add({ shot = "A4-agent-thinking.png" })

-- The typing. The whole point of the character: the program appears a
-- character at a time and the screen can be photographed mid-word.
local saw_typing = false
add({ until_ = function(app)
      local c = coder(app)
      if c.typist:busy() then saw_typing = true end
      return saw_typing or not c.session:busy()
    end, note = "the typist", timeout = 180 })
add({ until_ = function(app)
      local c = coder(app)
      if not c.typist:busy() then return true end
      print(("typing %d / %d"):format(c.typist.typed, c.typist.total))
      return false
    end, note = "the program", timeout = 180 })
add({ shot = "A5-agent-typed.png" })

-- And the end of it: the model says what it did, the room keeps it, and the
-- editor holds a program that was not there when we arrived.
add({ until_ = function(app) return not coder(app).session:busy() end,
      note = "the answer", timeout = 240 })
add({ wait = 1 })
add({ until_ = function(app)
      local s = pg(app)
      local c = coder(app)
      local text = s.editor:text()
      check(saw_typing, "the program was never typed a character at a time")
      check(text:find("1", 1, true) ~= nil and #text > 40,
        "the editor does not hold a new program:\n" .. text:sub(1, 200))
      local said = 0
      for _, item in ipairs(c.panel.items) do
        if item.role == "agent" then said = said + 1 end
      end
      check(said > 0, "the coder said nothing in the room")
      print(("room: %d lines, %d from the coder"):format(#c.panel.items, said))
      print("--- the program it wrote ---")
      print(text)
      return true
    end, timeout = 10 })
add({ shot = "A6-agent-done.png" })

-- **The room is the server's, not the screen's.** A pad that had never been
-- saved when the first word was said has an id by now, and everything said
-- before it had one must have reached the server anyway — so this throws the
-- local copy away and reads it back.
add({ until_ = function(app)
      local c = coder(app)
      if c.room_id == nil then
        -- Worth printing rather than only failing: the reason is almost
        -- always the server's, and the note carries it.
        print(("no room: snippet_id=%s tries=%s note=%s"):format(
          tostring(pg(app).snippet_id), tostring(c.save_tries), tostring(pg(app).note)))
      end
      check(c.room_id ~= nil, "the pad was never saved, so there is no room")
      app.probe_room = { id = c.room_id, count = 0, done = false }
      c.host.request("playground.chat.list", { id = c.room_id, limit = 200 },
        function(ok, payload)
          app.probe_room.done = true
          app.probe_room.count = ok and #(payload.messages or {}) or -1
        end)
      return true
    end, timeout = 5 })
add({ until_ = function(app) return app.probe_room.done end,
      note = "the room came back from the server", timeout = 15 })
add({ until_ = function(app)
      print(("server room %s: %d messages"):format(app.probe_room.id, app.probe_room.count))
      check(app.probe_room.count >= 2,
        "the server kept " .. app.probe_room.count .. " messages; the ask and its answer are two")
      return true
    end, timeout = 5 })

-- STOP, mid-word. The one promise the character makes about the editor is
-- that it is yours: whatever it is typing, it stops between two characters
-- and leaves what it had already written where it is.
add({ click = function(app) local r = coder(app).panel.rects["input"]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ text = "rewrite it as a while loop with a counter and a comment on every line" })
add({ click = function(app) local r = coder(app).panel.rects["write"]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return coder(app).typist:busy() end,
      note = "typing again", timeout = 180 })
-- A beat, so the stop lands mid-word rather than on the first frame: what is
-- being checked is that it stops *between two characters* with some of the
-- program already in.
-- Enough of it in to be a stop rather than a cancel. Counted in characters
-- rather than in seconds, because a drive runs as fast as the machine will
-- let it and a wall-clock wait is a different number of frames every time.
add({ until_ = function(app)
      local c = coder(app)
      return not c.typist:busy() or c.typist.typed >= 12
    end, note = "a dozen characters in", timeout = 30 })
local stopped_at, stopped_total = nil, nil
add({ until_ = function(app)
      local c = coder(app)
      stopped_at, stopped_total = c.typist.typed, c.typist.total
      c.panel:pressed("stop")
      return true
    end, timeout = 5 })
add({ wait = 0.6 })
add({ until_ = function(app)
      local c = coder(app)
      check(not c.typist:busy(), "the typist kept going after STOP")
      check(stopped_at > 0 and stopped_at < stopped_total,
        ("STOP did not land mid-program: %d of %d"):format(stopped_at, stopped_total))
      local text = pg(app).editor:text()
      check(#text > 0, "the editor was left empty by a stop")
      print(("stopped at %d of %d characters"):format(stopped_at, stopped_total))
      return true
    end, timeout = 5 })
add({ until_ = function(app) return not coder(app).session:busy() end,
      note = "the ask gave up", timeout = 60 })
add({ shot = "A9-agent-stopped.png" })

-- CODE, which is where the editor gets the window and the room gets a column
-- the whole height of it. This is the mode the coder is actually worked in.
add({ click = function(app) local r = pg(app).code_button_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return pg(app).big == true end, note = "CODE", timeout = 5 })
add({ wait = 0.8 })
add({ until_ = function(app)
      local rect = pg(app).agent_rect
      check(rect ~= nil, "the room did not follow into CODE")
      if rect then print(("CODE: the room is %dx%d"):format(rect.w, rect.h)) end
      return true
    end, timeout = 5 })
add({ shot = "A8-agent-code.png" })
add({ click = function(app) local r = pg(app).done_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return pg(app).big == false end, note = "out of CODE", timeout = 5 })

-- Portrait, where the panel is a band under the editor rather than a column
-- beside it. The same room, re-laid.
-- (The pad this run made is deleted at the end; see below.)
add({ orient = "portrait" })
add({ wait = 1.5 })
add({ shot = "A7-agent-portrait.png" })
add({ until_ = function(app)
      local rect = pg(app).agent_rect
      check(rect ~= nil, "the panel is not on the screen in portrait")
      if rect then
        check(rect.w > rect.h * 0.8, "portrait did not lay the panel across the foot")
      end
      return true
    end, timeout = 5 })

-- **Put the pad back.** This script makes one scratchpad every time it runs,
-- and a player is allowed sixty-four; a drive that ran on every change would
-- fill the test account and then start failing for a reason that has nothing
-- to do with the coder. Which is exactly what happened.
add({ orient = "landscape" })
add({ until_ = function(app)
      local s = pg(app)
      if not s.snippet_id then return true end
      app.probe_deleted = false
      s.app.session:request("playground.delete", { id = s.snippet_id },
        function(ok) app.probe_deleted = ok end)
      return true
    end, timeout = 5 })
add({ until_ = function(app) return app.probe_deleted ~= false end,
      note = "the pad was put back", timeout = 10 })

add({ until_ = function() print(fail and "DRIVE FAILED" or "drive ok") return true end,
      timeout = 2 })
add({ quit = true })

return steps
