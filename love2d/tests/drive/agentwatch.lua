-- Photograph the code page *while* the coder writes, to see what a person
-- sees rather than what a number says.
local steps = {}
local function add(t) steps[#steps + 1] = t end
local function pg(app) return app.scene_name == "playground" and app.scene or nil end
local function coder(app) local s = pg(app); return s and s.coder or nil end
local key = os.getenv("GROK_API_KEY")

add({ orient = "portrait" })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end, timeout = 20 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = function(app) return app.scene_name == "login" end })
add({ key = "return", when = function(app) return app.scene_name == "login" end })
add({ until_ = function(app) return app.scene_name == "lands" end, timeout = 30 })
add({ until_ = function(app) app:go("playground"); return true end, timeout = 5 })
add({ until_ = function(app) return pg(app) ~= nil end, timeout = 10 })
add({ wait = 0.4 })
add({ click = function(app) local r = pg(app).agent_button_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return coder(app).panel.open end, timeout = 5 })
add({ until_ = function()
      local Prefs = require("src.agent.prefs")
      Prefs.set_provider("grok"); Prefs.set_key("grok", key or "")
      return true
    end, timeout = 3 })
add({ click = function(app) local r = coder(app).panel.rects["input"]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ text = "write fifty short lines: a separate fn per number that prints it, f1 to f24, then main calling them all in order" })
add({ click = function(app) local r = coder(app).panel.rects["write"]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return coder(app).typist:busy() end, note = "typing", timeout = 180 })
-- Six pictures across the typing, and the numbers beside each.
for i = 1, 6 do
  add({ until_ = function(app)
        local s, c = pg(app), coder(app)
        print(("shot %d: typed=%d/%d caret=%d scroll=%d rows=%d lines=%d"):format(
          i, c.typist.typed, c.typist.total, s.editor.line, s.editor.scroll,
          s.visible_rows or 0, s.editor:line_count()))
        return true
      end, timeout = 5 })
  add({ shot = ("W%d-writing.png"):format(i) })
  add({ until_ = function(app)
        local c = coder(app)
        if not c.typist:busy() then return true end
        -- a chunk of the program between pictures
        return c.typist.typed > (i * 90)
      end, timeout = 120 })
end
add({ until_ = function(app) return not coder(app).typist:busy() end, timeout = 200 })
add({ shot = "W7-done.png" })
add({ until_ = function(app)
      local s = pg(app)
      if not s.snippet_id then return true end
      app.gone = false
      s.app.session:request("playground.delete", { id = s.snippet_id }, function(ok) app.gone = ok end)
      return true
    end, timeout = 5 })
add({ until_ = function(app) return app.gone ~= false end, timeout = 10 })
add({ quit = true })
return steps
