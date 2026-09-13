-- CODE mode and ANSWER, on the real server.
local Layout = require("src.layout")
local MNEMONIC = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
local function scene(n) return function(app) return app.scene_name == n end end
local on_login = scene("login")
local steps = {}
local function add(t) steps[#steps + 1] = t end
local failed = 0
local function check(ok, why) if not ok then print("FAIL: " .. why); failed = failed + 1 end end

add({ orient = "landscape" }) add({ resize = { 1280, 720 } }) add({ wait = 0.6 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end, timeout = 15 })
add({ text = MNEMONIC, when = on_login }) add({ key = "return", when = on_login })
add({ until_ = scene("lands"), timeout = 25 })
add({ until_ = function(app) return app.scene.lands ~= nil end, timeout = 10 })
add({ key = "return" }) add({ until_ = function(app) return app.scene_name == "categories" and app.scene.categories end, timeout = 10 })
add({ key = "return" }) add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end, timeout = 10 })
add({ until_ = function(app) app.scene.cursor = 1; app.scene.at = 1; app.scene.walk = nil; return true end, timeout = 3 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end, timeout = 20 })
add({ wait = 0.6 })
add({ shot = "A1-quest-band.png" })
-- CODE, by its button.
add({ until_ = function(app)
      local r = app.scene.code_rect
      check(r ~= nil, "no CODE button on the band")
      return r ~= nil end, timeout = 5 })
add({ click = function(app) local r = app.scene.code_rect; return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return app.scene.code_mode end, note = "CODE", timeout = 5 })
add({ wait = 0.5 })
add({ shot = "A2-code-mode.png" })
-- ANSWER, by its button in CODE mode.
add({ click = function(app) local r = app.scene.code_rects.answer; return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return app.scene.answer_on end, note = "ANSWER on", timeout = 30 })
add({ until_ = function(app)
      local s = app.scene
      check(s.answer_text ~= nil and #s.answer_text > 0, "no answer text")
      check(s.answer_lines ~= nil and #s.answer_lines > 0, "answer not split into lines")
      check(s.editor:text() == "", "the starter was not cleared: " .. string.format("%q", s.editor:text()))
      check(s.answer_prog.total == #s.answer_text, "progress total wrong")
      print(("answer: %d chars, %d lines, buffer %d"):format(#s.answer_text, #s.answer_lines, #s.editor:text()))
      return true end, timeout = 5 })
add({ wait = 0.4 })
add({ shot = "A3-answer-ghost.png" })
-- Type the first line of the answer, exactly: the count must move.
add({ until_ = function(app)
      app.probe_first = app.scene.answer_lines[1]
      return true end, timeout = 3 })
add({ text = function(app) return app.probe_first end })
add({ wait = 0.4 })
add({ until_ = function(app)
      local p = app.scene.answer_prog
      check(p.matched == #app.probe_first, ("matched %d, wanted %d"):format(p.matched, #app.probe_first))
      check(p.wrong == 0, "wrong should be 0 after typing it exactly")
      print(("typed line 1: matched=%d wrong=%d"):format(p.matched, p.wrong))
      return true end, timeout = 5 })
add({ shot = "A4-answer-on-target.png" })
-- TAB takes the rest of the line, until there is nothing left to take.
add({ until_ = function(app)
      for _ = 1, 40 do
        local before = app.scene.editor:text()
        app.scene:keypressed("tab", {})
        if app.scene.editor:text() == before then break end
      end
      local s = app.scene
      check(s.editor:text() == s.answer_text,
        "TAB did not land on the answer: " .. string.format("%q", s.editor:text()))
      return true end, note = "TAB completes", timeout = 5 })
-- The count is a display value, refreshed by `answer_tick` on the next
-- frame, so it is read after one rather than in the same breath.
add({ wait = 0.4 })
add({ until_ = function(app)
      local p = app.scene.answer_prog
      check(p.done, ("the count does not say done: %d/%d"):format(p.matched, p.total))
      print(("tab: %d/%d done=%s"):format(p.matched, p.total, tostring(p.done)))
      return true end, timeout = 5 })
add({ shot = "A7-answer-tabbed.png" })

-- Now a character that is not the answer: a burst, and the count stops.
add({ text = "z" })
add({ wait = 0.2 })
add({ until_ = function(app)
      local s = app.scene
      check(s.answer_prog.wrong > 0, "a wrong character was not counted")
      check(#s.sparks.bursts > 0, "no burst for the mistake")
      print(("mistake: wrong=%d bursts=%d"):format(s.answer_prog.wrong, #s.sparks.bursts))
      return true end, timeout = 5 })
add({ shot = "A5-answer-mistake.png" })
-- DONE goes back to the quest, not to the map.
add({ click = function(app) local r = app.scene.code_done_rect; return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app)
      check(app.scene_name == "quest", "DONE left the quest screen: " .. tostring(app.scene_name))
      check(not app.scene.code_mode, "still in CODE mode")
      return true end, note = "DONE", timeout = 5 })
add({ wait = 0.4 })
add({ shot = "A6-back-on-the-quest.png" })
add({ until_ = function() print(("answer flow: %d failures"):format(failed)); return true end, timeout = 1 })
add({ quit = true })
return steps
