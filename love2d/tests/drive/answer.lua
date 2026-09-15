-- CODE mode and ANSWER, on the real server.
local Layout = require("src.layout")
local function scene(n) return function(app) return app.scene_name == n end end
local on_login = scene("login")
local steps = {}
local function add(t) steps[#steps + 1] = t end
local failed = 0
local function check(ok, why) if not ok then print("FAIL: " .. why); failed = failed + 1 end end

add({ orient = "landscape" }) add({ resize = { 1280, 720 } }) add({ wait = 0.6 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end, timeout = 15 })
-- **A wallet minted here.** ANSWER spends a star through `quest.solve`, and
-- `use_solve` is a high-water mark: on a second run of the same account the
-- quest is already solved and the assertions below are watching a screen that
-- got there some other way. NEW WALLET is one key and a fresh account.
add({ key = "n", when = on_login })
add({ until_ = function(app)
      return app.session.authed or app.scene.mode == "new_show"
    end, note = "a phrase and its address", timeout = 20 })
add({ key = "return", when = function(app) return app.scene_name == "login" end })
add({ until_ = scene("lands"), timeout = 25 })
add({ until_ = function(app) return app.scene.lands ~= nil end, timeout = 10 })
-- **Pin the land and the buffer.** The server remembers where a player was
-- (§1.3) and keeps their draft (§4.8), so a run that inherited either would
-- be testing whatever the last run left behind.
add({ until_ = function(app)
      for i, land in ipairs(app.scene.lands or {}) do
        if land.land == "rust" then app.scene.cursor = i; app.scene.land = "rust" end
      end
      return app.scene.land == "rust" end, note = "RUST land", timeout = 5 })
add({ key = "return" }) add({ until_ = function(app) return app.scene_name == "categories" and app.scene.categories end, timeout = 10 })
add({ key = "return" }) add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end, timeout = 10 })
add({ until_ = function(app) app.scene.cursor = 1; app.scene.at = 1; app.scene.walk = nil; return true end, timeout = 3 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end, timeout = 20 })
add({ wait = 0.6 })
-- RESET puts the quest's own starter back, whatever the last run left.
add({ key = "f6" })
add({ until_ = function(app)
      return app.scene.quest and app.scene.editor:text() == app.scene.quest.starter
    end, note = "the starter is back", timeout = 15 })
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
-- **TAB indents.** It is the editor's key and ANSWER must not take it —
-- that conflict is why the completion moved to a button.
add({ until_ = function(app)
      local s = app.scene
      local was = s.editor:text()
      s:keypressed("tab", {})
      check(s.editor:text() ~= was, "TAB did not indent — something is eating the key")
      for _ = 1, #s.editor:text() - #was do s.editor:backspace() end
      check(s.editor:text() == was, "the indent did not come back out")
      return true end, note = "TAB indents", timeout = 5 })
-- +LINE hands over a line at a time. Pressed until it stops, it is the answer.
add({ until_ = function(app)
      local s = app.scene
      for _ = 1, 40 do
        local before = s.editor:text()
        s:complete_line()
        if s.editor:text() == before then break end
      end
      check(s.editor:text() == s.answer_text,
        "+LINE did not land on the answer: " .. string.format("%q", s.editor:text()))
      return true end, note = "+LINE completes", timeout = 5 })
add({ wait = 0.4 })
add({ until_ = function(app)
      local p = app.scene.answer_prog
      check(p.done, ("the count does not say done: %d/%d"):format(p.matched, p.total))
      print(("+line: %d/%d done=%s"):format(p.matched, p.total, tostring(p.done)))
      return true end, timeout = 5 })
add({ shot = "A7-answer-typed.png" })

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
-- BLANKS: the same answer with holes in it. The code is on the screen and
-- only the words are the player's to type.
add({ click = function(app) local r = app.scene.code_rects.blanks; return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return app.scene.drill == "blanks" end, note = "BLANKS on", timeout = 10 })
add({ wait = 0.5 })
add({ until_ = function(app)
      local s = app.scene
      check(s.blanks ~= nil and #s.blanks > 0, "no holes were cut")
      check(#s.editor:text() > 0, "the drill did not fill anything in for the player")
      check(#s.editor:text() < #s.answer_text, "the drill left nothing to type")
      local masked = table.concat(s.answer_lines, "\n")
      check(masked:find("_", 1, true) ~= nil, "the ghost is not masking the holes")
      print(("blanks: %d holes, buffer %d of %d, first hole at %d"):format(
        #s.blanks, #s.editor:text(), #s.answer_text, s.blanks[1].from))
      return true end, timeout = 5 })
add({ shot = "A8-blanks.png" })
-- The holes are typed, one character at a time; the gaps between them
-- arrive on their own.
add({ until_ = function(app)
      local s = app.scene
      for _ = 1, 400 do
        s:fill_blanks()
        local typed = s.editor:text()
        if typed == s.answer_text then break end
        local ch = s.answer_text:sub(#typed + 1, #typed + 1)
        s.editor:insert(ch)
      end
      check(app.scene.editor:text() == app.scene.answer_text,
        "the drill did not play out to the answer: " .. string.format("%q", app.scene.editor:text()))
      return true end, note = "the holes are filled in", timeout = 10 })
add({ wait = 0.4 })
add({ until_ = function(app)
      check(app.scene.answer_prog.done, "the drill finished but the count does not say done")
      print(("blanks done: %d/%d"):format(app.scene.answer_prog.matched, app.scene.answer_prog.total))
      return true end, timeout = 5 })
add({ shot = "A9-blanks-done.png" })

-- ANSWER ONLY: the quest's own scaffold types itself, and what is left to
-- type is the solution. The buffer therefore starts much fuller than in
-- BLANKS, and the holes are whole lines rather than words.
add({ click = function(app) local r = app.scene.code_rects.solution; return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return app.scene.drill == "solution" end, note = "ANSWER ONLY on", timeout = 10 })
add({ wait = 0.5 })
add({ until_ = function(app)
      local s = app.scene
      check(s.blanks ~= nil and #s.blanks > 0, "no holes were cut from the starter")
      local typed = s.editor:text()
      check(#typed > 0, "the scaffold did not type itself")
      check(#typed < #s.answer_text, "there is nothing left for the player to type")
      -- Every hole is a line the starter does not have.
      local starter = s.quest.starter or ""
      for _, b in ipairs(s.blanks) do
        local cut = s.answer_text:sub(b.from + 1, b.to)
        check(not starter:find(cut, 1, true), "a hole was cut from a line the quest gave: " .. cut)
      end
      print(("answer only: %d holes, scaffold typed %d of %d"):format(
        #s.blanks, #typed, #s.answer_text))
      return true end, timeout = 5 })
add({ shot = "B1-answer-only.png" })
add({ until_ = function(app)
      local s = app.scene
      for _ = 1, 4000 do
        s:fill_blanks()
        local typed = s.editor:text()
        if typed == s.answer_text then break end
        if #typed >= #s.answer_text then break end
        local ch = s.answer_text:sub(#typed + 1, #typed + 1)
        if ch == "\n" then s:keypressed("return", {}) else s:textinput(ch) end
      end
      check(s.editor:text() == s.answer_text, "the drill did not play out to the answer")
      return true end, note = "the solution is typed", timeout = 20 })
add({ wait = 0.4 })
add({ until_ = function(app)
      check(app.scene.answer_prog.done, "the drill finished but the count does not say done")
      print(("answer only done: %d/%d"):format(app.scene.answer_prog.matched, app.scene.answer_prog.total))
      return true end, timeout = 5 })
add({ shot = "B2-answer-only-done.png" })

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
