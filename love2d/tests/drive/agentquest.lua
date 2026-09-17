-- The Rust coder on a graded screen (§4.8, docs/agent.md §1).
--
--   make -C love2d drive SCRIPT=tests/drive/agentquest.lua ARGS="--home $(mktemp -d)"
--
-- The quest screen gets the same character and a shorter list of powers: it
-- reads, edits and writes the file, and it has no RUN and no room. A quest's
-- RUN is an attempt against a server keeping score, and an agent that could
-- spend one is an agent that could fail a quest on somebody's behalf — so the
-- thing this script is really checking is what the coder is **not** offered.
--
-- It asks a model only if there is a key in the environment; without one it
-- still opens the panel, which is where the tool list is decided.

local steps = {}
local function add(t) steps[#steps + 1] = t end
local fail = false
local function check(ok, why)
  if ok then return true end
  print("FAIL: " .. why)
  fail = true
  return false
end
local function qs(app) return app.scene_name == "quest" and app.scene or nil end
local function coder(app) local s = qs(app); return s and s.coder or nil end

local provider, key = nil, nil
for _, candidate in ipairs({
  { name = "grok", env = "GROK_API_KEY" },
  { name = "openai", env = "OPENAI_API_KEY" },
  { name = "anthropic", env = "ANTHROPIC_API_KEY" },
}) do
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
add({ until_ = function(app) return app.scene.lands ~= nil end, timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "categories" end, timeout = 10 })
add({ until_ = function(app) return app.scene.categories ~= nil end, timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
      note = "the map", timeout = 15 })
add({ until_ = function(app)
      app.scene.cursor, app.scene.at, app.scene.walk = 1, 1, nil
      return true
    end, timeout = 3 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
      note = "in the editor", timeout = 20 })
add({ wait = 0.5 })

-- Into CODE, where the strip has the AGENT button.
add({ until_ = function(app) qs(app).code_mode = true; return true end, timeout = 5 })
add({ wait = 0.4 })
add({ until_ = function(app)
      local r = (qs(app).code_rects or {}).agent
      check(r ~= nil, "no AGENT button in the quest's CODE strip")
      check(coder(app) ~= nil, "the quest made no coder")
      return r ~= nil
    end, timeout = 5 })
add({ click = function(app) local r = qs(app).code_rects.agent
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return coder(app).panel.open end, note = "the panel", timeout = 5 })
add({ wait = 1.2 })
add({ shot = "Q1-agent-quest.png" })

-- What it may do here. The catalogue is decided from the bench, so this is
-- the assertion that matters on a screen that keeps score.
add({ until_ = function(app)
      local Tools = require("src.agent.tools")
      local names = {}
      for _, tool in ipairs(Tools.tools_for(coder(app):bench())) do names[tool.name] = true end
      check(names.read_code, "the coder cannot read the file")
      check(names.write_code and names.edit_code, "the coder cannot write the file")
      check(not names.run_code, "the coder was offered RUN on a graded screen")
      check(not names.search_notes, "the coder was offered the notes on a quest")
      check(not names.make_image, "the coder was offered a picture with no room to put it in")
      local list = {}
      for name in pairs(names) do list[#list + 1] = name end
      table.sort(list)
      print("quest tools: " .. table.concat(list, " "))
      return true
    end, timeout = 5 })

-- And that it is alive: the sprite is on the screen and moving.
add({ until_ = function(app)
      local c = coder(app)
      check(c.presence > 0.5, "the coder is not on the screen")
      print(("coder: state=%s scale=%.2f"):format(c.sprite.state, c.sprite.scale))
      return true
    end, timeout = 5 })

if provider then
  -- One real ask, and the program has to appear in the quest's own editor.
  add({ click = function(app) local r = coder(app).panel.rects["setup"]
        return { r.x + r.w / 2, r.y + r.h / 2 } end })
  add({ until_ = function(app) return coder(app).panel.view == "setup" end, timeout = 5 })
  -- A panel too short for a grid of tabs shows one button that cycles them,
  -- so this presses whichever of the two it is looking at.
  add({ until_ = function(app)
        local p = coder(app).panel
        local ids = {}
        for id in pairs(p.rects) do ids[#ids + 1] = id end
        table.sort(ids)
        print(("panel %dx%d rects: %s"):format(
          (qs(app).agent_rect or {}).w or -1, (qs(app).agent_rect or {}).h or -1,
          table.concat(ids, " ")))
        return true
      end, timeout = 3 })
  add({ until_ = function(app)
        local p = coder(app).panel
        local Prefs = require("src.agent.prefs")
        if p.rects["tab:" .. provider] then return true end
        if Prefs.provider() == provider then return true end
        p:pressed("cycle")
        return false
      end, note = "the provider", timeout = 10 })
  add({ click = function(app)
        local p = coder(app).panel
        local r = p.rects["tab:" .. provider] or p.rects["cycle"] or p.rects["setup"]
        return { r.x + r.w / 2, r.y + r.h / 2 } end,
        when = function(app) return coder(app).panel.rects["tab:" .. provider] ~= nil end })
  add({ click = function(app) local r = coder(app).panel.rects["key"]
        return { r.x + r.w / 2, r.y + r.h / 2 } end })
  add({ text = key })
  add({ key = "escape" })
  add({ until_ = function(app) return coder(app).panel.view == "chat" end, timeout = 5 })
  add({ click = function(app) local r = coder(app).panel.rects["input"]
        return { r.x + r.w / 2, r.y + r.h / 2 } end })
  add({ text = "rewrite the whole file as thirty short lines, one statement each, keeping what it does" })
  local before = nil
  add({ until_ = function(app) before = qs(app).editor:text(); return true end, timeout = 3 })
  add({ click = function(app) local r = coder(app).panel.rects["send"]
        return { r.x + r.w / 2, r.y + r.h / 2 } end })
  add({ until_ = function(app)
        local c = coder(app)
        -- A status instead of a busy session means it refused rather than
        -- asked — a missing key, say — and that is worth failing on here
        -- rather than waiting ten seconds to be told nothing.
        check(c.panel.status == nil, "the coder refused the ask: " .. tostring(c.panel.status))
        return c.session:busy() or c.panel.status ~= nil
      end, note = "the ask went out", timeout = 10 })
  -- Does the quest's code page follow the caret while the coder writes?
  local worst = nil
  add({ until_ = function(app)
        local s, c = qs(app), coder(app)
        local e = s.editor
        local rows = s.visible_rows or 0
        local below = e.line - (e.scroll + rows)
        if below > 0 and (not worst or below > worst.below) then
          worst = { below = below, line = e.line, scroll = e.scroll, rows = rows }
        end
        return not c.session:busy()
      end, note = "the answer", timeout = 240 })
  add({ until_ = function(app)
        local s = qs(app)
        print(("quest page: lines=%d caret=%d scroll=%d rows=%d"):format(
          s.editor:line_count(), s.editor.line, s.editor.scroll, s.visible_rows or 0))
        if worst then
          print(("QUEST WORST: the caret was %d lines below the fold (line %d, scroll %d, rows %d)")
            :format(worst.below, worst.line, worst.scroll, worst.rows))
        else
          print("the quest's caret never went below the fold")
        end
        return true
      end, timeout = 5 })
  add({ wait = 0.5 })
  add({ until_ = function(app)
        local after = qs(app).editor:text()
        print("--- the quest's editor now ---")
        print(after:sub(1, 400))
        check(after ~= before, "the coder changed nothing in the quest's editor")
        return true
      end, timeout = 5 })
  add({ shot = "Q2-agent-quest-edited.png" })
end

add({ until_ = function() print(fail and "DRIVE FAILED" or "drive ok") return true end,
      timeout = 2 })
add({ quit = true })

return steps
