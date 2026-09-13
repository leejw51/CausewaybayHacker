-- A tab-indented answer, typed out without ever typing a tab.
--
--   make -C love2d drive SCRIPT=tests/drive/tabs.lua ARGS="--home $(mktemp -d)"
--
-- The report this exists for: on a Go quest — gofmt indents with tabs — the
-- ANSWER target could not be finished. This editor's newline guesses
-- `tab_width` spaces, the answer wanted a tab, and no key a player could
-- press would make the two agree: the line stayed red at 161 / 333 for ever.
--
-- So the mode fills a line's indentation itself. What this script proves is
-- exactly that: every character is typed through the real key path, none of
-- them is a tab, and the count reaches the end.

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
-- GO, whose answers gofmt writes with tabs.
add({ until_ = function(app)
      for i, land in ipairs(app.scene.lands or {}) do
        if land.land == "go" then app.scene.cursor = i; app.scene.land = "go" end
      end
      return app.scene.land == "go" end, note = "GO land", timeout = 5 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "categories" and app.scene.categories end, timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end, timeout = 10 })
add({ until_ = function(app)
      app.scene.cursor = 1; app.scene.at = 1; app.scene.walk = nil; return true end, timeout = 3 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end, timeout = 20 })
add({ wait = 0.5 })
-- ANSWER on, through its own button on the band.
add({ click = function(app) local r = app.scene.answer_rect; return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return app.scene.answer_on end, note = "ANSWER on", timeout = 30 })
add({ until_ = function(app)
      local s = app.scene
      check(s.answer_text:find("\t", 1, true) ~= nil,
        "this quest's answer has no tabs in it — the drive is not testing what it says")
      print(("answer: %d chars, tabs=%s"):format(#s.answer_text,
        tostring(s.answer_text:find("\t", 1, true) ~= nil)))
      return true end, timeout = 5 })
-- Typed out through the real key path. Never a tab.
add({ until_ = function(app)
      local s = app.scene
      local tabs_typed = 0
      for _ = 1, 4000 do
        s:fill_blanks()
        local typed = s.editor:text()
        if typed == s.answer_text then break end
        if #typed >= #s.answer_text then break end
        local ch = s.answer_text:sub(#typed + 1, #typed + 1)
        if ch == "\t" then tabs_typed = tabs_typed + 1 end
        if ch == "\n" then s:keypressed("return", {}) else s:textinput(ch) end
      end
      check(tabs_typed == 0, ("the player had to type %d tabs"):format(tabs_typed))
      check(s.editor:text() == s.answer_text, "typing it out did not land on the answer")
      return true end, note = "typed out", timeout = 20 })
add({ wait = 0.4 })
add({ until_ = function(app)
      local p = app.scene.answer_prog
      check(p.done, ("the count does not say done: %d/%d"):format(p.matched, p.total))
      check(p.wrong == 0, ("%d characters are still wrong"):format(p.wrong))
      print(("tabs: %d/%d done=%s wrong=%d"):format(p.matched, p.total, tostring(p.done), p.wrong))
      return true end, timeout = 5 })
add({ shot = "T1-tabs-typed.png" })
add({ until_ = function() print(("tabs flow: %d failures"):format(failed)); return true end, timeout = 1 })
add({ quit = true })
return steps
