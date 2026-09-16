-- The typing effects, caught in the act.
--
--   make -C love2d drive SCRIPT=tests/drive/codefx.lua
--
-- Walks into the playground's CODE mode and does the four things
-- `src/codefx.lua` answers — types a loop and closes it, presses ENTER,
-- deletes a line, sweeps the pointer across the well — with a screenshot a
-- few frames into each, while the particles are still in the air. Also
-- checks the editor reported the events at all, so a silent layer fails the
-- run rather than producing four quiet pictures.

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

-- CODE mode, so the editor has the window.
add({ click = function(app) local r = pg(app).code_button_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return pg(app).big == true end, note = "CODE is on", timeout = 5 })
add({ until_ = function(app)
      local s = pg(app)
      s.focus = "editor"
      check(s.fx ~= nil, "the playground has no effects layer")
      check(s.editor.on_event ~= nil, "the editor is not reporting to anything")
      check(s.editor.auto_close == true, "auto-close is off in the playground")
      -- A clean sheet, and a count of what the layer is told.
      s.editor:select_all()
      s.editor:keypressed("backspace", {})
      s.fx_events = {}
      local inner = s.editor.on_event
      s.editor.on_event = function(ev)
        s.fx_events[#s.fx_events + 1] = ev.kind
        inner(ev)
      end
      return true
    end, timeout = 5 })
add({ wait = 0.3 })

-- A loop, typed the way a person types it: the editor indents after `{`.
add({ text = "fn main() {" })
add({ key = "return" })
add({ shot = "FX1-enter-dust.png" })
add({ text = "for i in 0..3 {" })
add({ key = "return" })
add({ text = 'println!("{i}");' })
add({ shot = "FX2-typing-sparks.png" })
add({ until_ = function(app)
      local s = pg(app)
      check(s.editor:text():find('println!%("{i}"%);', 1) ~= nil,
        "auto-close doubled something: " .. s.editor:text())
      return true
    end, timeout = 2 })
add({ key = "return" })
add({ key = "backspace" })
-- Let the typing settle, so the loop is photographed on its own.
add({ wait = 1.3 })
add({ text = "}" })
add({ wait = 0.25 })
add({ shot = "FX3-loop-stars.png" })
add({ wait = 1.2 })
add({ shot = "FX4-loop-finale.png" })
add({ until_ = function(app)
      local s = pg(app)
      local loops = 0
      for _, k in ipairs(s.fx_events) do if k == "loop" then loops = loops + 1 end end
      check(loops == 1, ("expected one loop event, got %d"):format(loops))
      check(#s.fx.live > 0, "nothing is in the air after a closed loop")
      return true
    end, timeout = 2 })

-- Delete the println line: select it and take it out.
add({ key = "up" })
add({ key = "end" })
add({ key = "home", mods = { shift = true } })
add({ wait = 1.5 })
add({ key = "backspace" })
add({ wait = 0.15 })
add({ shot = "FX5-line-rubble.png" })
add({ until_ = function(app)
      local s = pg(app)
      local erased = 0
      for _, k in ipairs(s.fx_events) do if k == "erase" then erased = erased + 1 end end
      check(erased >= 2, ("expected erase events, got %d"):format(erased))
      return true
    end, timeout = 2 })

-- The pointer across the well, well clear of the text so it selects nothing.
add({ wait = 1.2 })
add({ drag = function(app)
      local r = pg(app).code_rect
      return { r.x + r.w * 0.55, r.y + r.h * 0.75 }
    end })
steps[#steps].drag = {
  function(app) local r = pg(app).code_rect; return { r.x + r.w * 0.3, r.y + r.h * 0.8 } end,
  function(app) local r = pg(app).code_rect; return { r.x + r.w * 0.9, r.y + r.h * 0.5 } end,
}
-- A few frames on, so the embers have popped up out of their first tenth.
add({ wait = 0.12 })
add({ shot = "FX6-pointer-ribbon.png" })
add({ until_ = function(app)
      check(#pg(app).fx.live > 0, "the pointer left no trail")
      return true
    end, timeout = 2 })

add({ until_ = function()
      print(fail and "codefx drive: FAILED" or "codefx drive: ok")
      return true
    end, timeout = 1 })
add({ quit = true })

return steps
