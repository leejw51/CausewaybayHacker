-- The art round, the motion round, the clock and FORMAT, in one pass.
--
--   make -C love2d drive SCRIPT=tests/drive/polish.lua
--
-- Animation time is pinned for every screenshot (`freeze`), so a bobbing
-- mascot is the same pixel every run and two runs can be compared. The game
-- still animates; only the captures stand still.

local function on_login(app) return app.scene_name == "login" end
local steps = {}
local function add(t) steps[#steps + 1] = t end

add({ orient = "landscape" })
add({ wait = 0.8 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      timeout = 15 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = on_login })
add({ key = "return", when = on_login })
add({ until_ = function(app) return app.scene_name == "lands" end,
      note = "signed in", timeout = 25 })
add({ until_ = function(app) return app.scene.lands ~= nil end, timeout = 10 })
add({ wait = 0.6 })

add({ note = "lands: mascots per land AND per category row" })
add({ freeze = 3.0 })
add({ shot = "P1-lands.png" })
add({ freeze = false })
add({ key = "down" })
add({ wait = 0.25 })
add({ freeze = 3.1 })
add({ shot = "P2-lands-selected.png" })
add({ freeze = false })
add({ key = "up" })
add({ wait = 0.2 })

add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "categories" and app.scene.categories end,
      note = "categories: the wide emblem bands", timeout = 10 })
add({ wait = 0.7 })
add({ freeze = 4.0 })
add({ shot = "P3-categories.png" })
add({ freeze = false })
add({ key = "down" })
add({ wait = 0.3 })
add({ freeze = 4.2 })
add({ shot = "P4-categories-selected.png" })
add({ freeze = false })

-- HACKER, for the clock.
add({ key = "down" })
add({ wait = 0.3 })
add({ until_ = function(app)
      local cat = app.scene.categories[app.scene.cursor]
      print("category: " .. tostring(cat and cat.category))
      return true
    end, timeout = 3 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
      note = "map", timeout = 12 })
add({ wait = 0.8 })
add({ freeze = 5.0 })
add({ shot = "P5-map.png" })
add({ freeze = false })

add({ note = "the iris out of the node into the quest" })
add({ key = "return" })
add({ wait = 0.12 })
add({ shot = "P6-iris.png" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
      note = "in the quest", timeout = 15 })
add({ wait = 0.9 })
add({ until_ = function(app)
      local Clock = require("src.clock")
      local q = app.scene.quest
      local state = Clock.read(q)
      print(("quest: %s  time_limit_s=%s opened_at=%s deadline_at=%s"):format(
        tostring(q.id), tostring(q.time_limit_s), tostring(q.opened_at),
        tostring(q.deadline_at)))
      if state then
        print(("clock: %s  phase=%s remaining=%.0fs"):format(
          Clock.format(state), state.phase, state.remaining))
      else
        print("clock: none — the server has not shipped §4.8b yet, or this quest is untimed")
      end
      return true
    end, timeout = 5 })
add({ freeze = 6.0 })
add({ shot = "P7-quest-clock.png" })
add({ freeze = false })

add({ note = "FORMAT on deliberately untidy source" })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = "fn main(){let x=1;println!(\"{}\",x);" })
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ until_ = function(app)
      -- Put the caret somewhere worth keeping.
      app.scene.editor:goto_position(2, 8)
      app.scene.format_caret = { line = 2, col = 8,
        ink = #(app.scene.editor:current_line():sub(1, 7):gsub("%s", "")) }
      print(("before format: line=%d col=%d [%s]"):format(
        app.scene.editor.line, app.scene.editor.col, app.scene.editor:current_line()))
      return true
    end, timeout = 3 })
add({ key = "f2" })
add({ until_ = function(app)
      local q = app.scene
      if q.formatting then return false end
      if q.format_note or q.format_problem then
        print(("format: note=%s problem=%s"):format(
          tostring(q.format_note), tostring(q.format_problem)))
        print(("after format:  line=%d col=%d [%s]"):format(
          q.editor.line, q.editor.col, q.editor:current_line()))
        local ink = #(q.editor:current_line():sub(1, q.editor.col - 1):gsub("%s", ""))
        print(("caret ink before=%d after=%d"):format(q.format_caret.ink, ink))
        return true
      end
      return false
    end, note = "format answered", timeout = 30 })
add({ wait = 0.4 })
add({ freeze = 7.0 })
add({ shot = "P8-quest-formatted.png" })
add({ freeze = false })

add({ note = "a failing run shakes the strip, not the editor" })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = "fn main() {\nprintln!(\"nope\");" })
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ key = "f5" })
add({ until_ = function(app) return app.scene.run_attempt ~= nil end,
      note = "the run came back", timeout = 90 })
add({ wait = 0.08 })
add({ shot = "P9-run-shake.png" })

add({ orient = "portrait" })
add({ resize = { 720, 1000 } })
add({ wait = 1.0 })
add({ freeze = 8.0 })
add({ shot = "P10-quest-portrait.png" })
add({ freeze = false })
add({ quit = true })

return steps
