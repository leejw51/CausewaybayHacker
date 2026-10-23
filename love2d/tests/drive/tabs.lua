-- A tab-indented program in the quiz card, on the real server.
--
--   make -C love2d drive SCRIPT=tests/drive/tabs.lua ARGS="--home $(mktemp -d)"
--
-- This used to type a Go answer out through the ANSWER drill, because gofmt
-- indents with tabs and the drill's newline guessed spaces. Quests are picked
-- now (SPEC §0) and there is no drill, but the tabs did not go anywhere: a GO
-- quest's quiz program is gofmt's, and the card draws it in a face that
-- draws a tab as nothing. So what this proves is the card's half of the same
-- report:
--
--   * the program really has tabs in it (or the drive is not testing them);
--   * every line the card lays out has its tabs as four spaces, and keeps
--     its indentation when it wraps;
--   * the four choices are on the screen and apart;
--   * the right pick goes in at the hole's own indentation and is accepted.
--
-- A wallet minted here: a pick is an attempt, and a second run on the same
-- account would be picking on a cleared node.

local Layout = require("src.layout")
local function scene(n) return function(app) return app.scene_name == n end end
local on_login = scene("login")
local steps = {}
local function add(t) steps[#steps + 1] = t end
local failed = 0
local function check(ok, why) if not ok then print("FAIL: " .. why); failed = failed + 1 end end

add({ orient = "landscape" }) add({ resize = { 1280, 720 } }) add({ wait = 0.6 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end, timeout = 15 })
add({ key = "n", when = on_login })
add({ until_ = function(app)
      return app.session.authed or app.scene.mode == "new_show"
    end, note = "a phrase and its address", timeout = 20 })
add({ key = "return", when = on_login })
add({ until_ = scene("lands"), timeout = 25 })
add({ until_ = function(app) return app.scene.lands ~= nil end, timeout = 10 })
-- GO, whose programs gofmt writes with tabs.
add({ until_ = function(app)
      for i, land in ipairs(app.scene.lands or {}) do
        if land.land == "go" then app.scene.cursor = i; app.scene.land = "go" end
      end
      return app.scene.land == "go" end, note = "GO land", timeout = 5 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "categories" and app.scene.categories end, timeout = 10 })
-- BASIC: a program with a hole, not a sheet question.
add({ until_ = function(app)
      for i, cat in ipairs(app.scene.categories) do
        if cat.category == "basic" then app.scene.cursor = i end
      end
      local cat = app.scene.categories[app.scene.cursor]
      return cat and cat.category == "basic" end, note = "GO BASIC", timeout = 5 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end, timeout = 10 })
add({ until_ = function(app)
      app.scene.cursor = 1; app.scene.at = 1; app.scene.walk = nil; return true end, timeout = 3 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end, timeout = 20 })
add({ wait = 0.8 })

add({ until_ = function(app)
      local s = app.scene
      local quiz = s.quest.quiz
      check(quiz ~= nil, "the GO BASIC quest has no quiz")
      if not quiz then return true end
      local program = quiz.program or ""
      check(program:find("\t", 1, true) ~= nil,
        "this quest's program has no tabs in it — the drive is not testing what it says")
      check(s:quiz_locked(), "the quiz is not open")
      -- Every row the card lays out: no tab survives, and a tab-indented
      -- line is indented by four spaces a tab, wrapped pieces included.
      local Quest = require("src.scenes.quest")
      local Quiz = require("src.quiz")
      local rows, tabbed = 0, 0
      for _, line in ipairs(Quiz.program_lines(program)) do
        local tabs = #(line.text:match("^\t*"))
        if tabs > 0 then tabbed = tabbed + 1 end
        for _, piece in ipairs(Quest.code_wrap(line.text, 420)) do
          rows = rows + 1
          check(not piece:find("\t", 1, true), ("a tab reached the screen: %q"):format(piece))
          if tabs > 0 and piece ~= "" then
            check(piece:sub(1, 4 * tabs) == (" "):rep(4 * tabs),
              ("%q lost its indentation (%d tabs)"):format(piece, tabs))
          end
        end
      end
      print(("tabs: %d program lines with tabs, %d rows laid out"):format(tabbed, rows))
      check(tabbed > 0, "no line of the program is tab-indented")
      return true end, note = "the program's tabs", timeout = 5 })

-- The choices, on the screen and apart.
add({ until_ = function(app)
      local s = app.scene
      if s.choice_hits[s.quest.quiz.answer + 1] then return true end
      s.brief_scroll = s.brief_scroll + 40
      return false end, note = "the right choice in view", timeout = 10 })
add({ wait = 0.2 })
add({ until_ = function(app)
      local s = app.scene
      local hits = {}
      for i = 1, 4 do if s.choice_hits[i] then hits[#hits + 1] = s.choice_hits[i] end end
      for i, r in ipairs(hits) do
        check(r.x >= 0 and r.x + r.w <= Layout.vw, ("choice %d is off the screen"):format(i))
        for j = i + 1, #hits do
          local o = hits[j]
          check(r.x >= o.x + o.w or o.x >= r.x + r.w or r.y >= o.y + o.h or o.y >= r.y + r.h,
            ("choices %d and %d overlap"):format(i, j))
        end
      end
      return true end, timeout = 3 })
add({ shot = "T1-go-quiz-tabs.png" })

-- The right pick, by its key.
add({ text = function(app) return tostring(app.scene.quest.quiz.answer + 1) end })
add({ wait = 0.35 })
add({ shot = "T2-go-quiz-right.png" })
add({ until_ = scene("result"), note = "the verdict screen", timeout = 30 })
add({ until_ = function(app)
      local a = app.last_attempt
      check(a ~= nil and a.verdict == "accepted",
        "the right pick was not accepted: " .. tostring(a and a.verdict))
      return true end, timeout = 5 })
add({ until_ = function()
      if failed > 0 then
        print(("drive: FAILED — %d check(s)"):format(failed))
        love.event.quit(1)
        return true
      end
      print("PASS: a Go program's tabs are spaces in the card, and the pick is accepted")
      return true end, timeout = 2 })
add({ quit = true })
return steps
