-- Does the code page follow the coder's caret while it writes? (drive only)
local steps = {}
local function add(t) steps[#steps + 1] = t end
local function pg(app) return app.scene_name == "playground" and app.scene or nil end
local function coder(app) local s = pg(app); return s and s.coder or nil end
local key = os.getenv("GROK_API_KEY")

add({ orient = "landscape" })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end, timeout = 20 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = function(app) return app.scene_name == "login" end })
add({ key = "return", when = function(app) return app.scene_name == "login" end })
add({ until_ = function(app) return app.scene_name == "lands" end, timeout = 30 })
add({ until_ = function(app) app:go("playground"); return true end, timeout = 5 })
add({ until_ = function(app) return pg(app) ~= nil end, timeout = 10 })
add({ wait = 0.5 })
add({ click = function(app) local r = pg(app).agent_button_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return coder(app).panel.open end, timeout = 5 })
-- key straight into prefs: this script is about scrolling, not about setup
add({ until_ = function()
      local Prefs = require("src.agent.prefs")
      Prefs.set_provider("grok")
      Prefs.set_key("grok", key or "")
      return true
    end, timeout = 3 })
-- In CODE, which is the mode somebody actually writes in.
add({ click = function(app) local r = pg(app).code_button_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return pg(app).big == true end, note = "CODE", timeout = 5 })
add({ wait = 0.5 })
add({ click = function(app) local r = coder(app).panel.rects["input"]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ text = "a program with a function per line that prints the numbers 1 to 30, no loops, one println per number" })
add({ click = function(app) local r = coder(app).panel.rects["write"]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return coder(app).typist:busy() end, note = "typing", timeout = 180 })
local worst = nil
local wide = nil
add({ until_ = function(app)
      local s, c = pg(app), coder(app)
      local e = s.editor
      local rows = s.visible_rows or 0
      local below = e.line - (e.scroll + rows)
      if below > 0 and (not worst or below > worst.below) then
        worst = { below = below, line = e.line, scroll = e.scroll, rows = rows, lines = e:line_count() }
      end
      -- And across: where is the caret, against the right edge of the well?
      local cx = s.pane and s.pane:cell(e.line, e.col)
      local r = s.code_rect
      if cx and r then
        local over = cx - (r.x + r.w - 8)
        if over > 0 and (not wide or over > wide.over) then
          wide = { over = over, line = e.line, col = e.col,
            text = (e.lines[e.line] or ""):sub(1, 70) }
        end
      end
      return not c.typist:busy()
    end, note = "the typing finished", timeout = 240 })
add({ until_ = function(app)
      local s = pg(app)
      local e = s.editor
      print(("final: lines=%d caret=%d scroll=%d rows=%d"):format(
        e:line_count(), e.line, e.scroll, s.visible_rows or 0))
      if worst then
        print(("WORST: the caret was %d lines below the fold (line %d, scroll %d, rows %d, of %d)")
          :format(worst.below, worst.line, worst.scroll, worst.rows, worst.lines))
      else
        print("the caret never went below the fold")
      end
      if wide then
        print(("ACROSS: the caret ran %d px past the right edge on line %d col %d: %s")
          :format(math.floor(wide.over), wide.line, wide.col, wide.text))
      else
        print("the caret never ran past the right edge")
      end
      return true
    end, timeout = 5 })
add({ shot = "S-agent-scroll.png" })
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
