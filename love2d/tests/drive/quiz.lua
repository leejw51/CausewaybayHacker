-- The quiz card, on the real server: before a pick, after a wrong one and
-- after the right one, on a sheet question (the snippet in the brief) and on
-- a program with a hole in it, in landscape and in portrait.
--
--   make -C love2d drive SCRIPT=tests/drive/quiz.lua ARGS="--home $(mktemp -d)"
--
-- A wallet minted here: a wrong pick is a failed attempt and costs a star,
-- and a second run on the same account would be picking on cleared nodes.
--
-- A wrong row **stays** struck and dead for the rest of the attempt
-- (`wrong_picks`); `quiz_wrong` is the latest miss. The right pick holds
-- the card `Quiz.HOLD` for its burst before the verdict screen.

local Layout = require("src.layout")
local function scene(n) return function(app) return app.scene_name == n end end
local on_login = scene("login")
local steps = {}
local function add(t) steps[#steps + 1] = t end
local failed = 0
local function check(ok, why) if not ok then print("FAIL: " .. why); failed = failed + 1 end end

add({ wait = 0.6 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end, timeout = 15 })
add({ key = "n", when = on_login })
add({ until_ = function(app)
      return app.session.authed or app.scene.mode == "new_show"
    end, note = "a phrase and its address", timeout = 20 })
add({ key = "return", when = on_login })
add({ until_ = scene("lands"), timeout = 25 })

-- Which wrong choice to take: the first that is not the answer.
local function wrong_of(quiz)
  for i = 1, #quiz.choices do
    if (i - 1) ~= quiz.answer then return i end
  end
end

local QUESTS = {
  { id = "rust.cheatsheet.01.read-all", tag = "sheet" },
  { id = "rust.hacker.01.two-sum", tag = "program" },
}

for _, mode in ipairs({ "landscape", "portrait" }) do
  for _, q in ipairs(QUESTS) do
    local tag = ("%s-%s"):format(q.tag, mode)
    add({ note = "---- " .. tag .. " ----" })
    add({ orient = mode })
    add({ resize = mode == "portrait" and { 720, 1280 } or { 1280, 720 } })
    add({ wait = 0.3 })
    add({ until_ = function(app)
          app:go("quest", { quest_id = q.id, land = "rust", category = q.id:match("^rust%.([%w_]+)%.") })
          return true end, timeout = 3 })
    add({ until_ = function(app)
          return app.scene_name == "quest" and app.scene.quest ~= nil
        end, note = "quest " .. tag, timeout = 20 })
    add({ wait = 1.2 })
    add({ shot = ("Q-%s-0-top.png"):format(tag) })
    -- A long program in portrait puts the four a scroll away; scroll as a
    -- player would until the first is in view.
    add({ until_ = function(app)
          local s = app.scene
          if s.choice_hits[1] then return true end
          s.brief_scroll = s.brief_scroll + 40
          return false end, note = "a choice in view", timeout = 10 })
    add({ wait = 0.2 })
    add({ until_ = function(app)
          local s = app.scene
          check(s.quest.quiz ~= nil, tag .. ": no quiz")
          check(s:quiz_locked(), tag .. ": the quiz is not open")
          local n = 0
          for i = 1, 4 do if s.choice_hits[i] then n = n + 1 end end
          print(("%s: %d of 4 choices take a tap"):format(tag, n))
          check(n >= 1, tag .. ": no choice on screen")
          return true end, timeout = 3 })
    -- Hover the second choice, so the shot shows the hover state.
    add({ until_ = function(app)
          local r = app.scene.choice_hits[2]
          if r then app.scene:mousemoved(r.x + r.w / 2, r.y + r.h / 2) end
          return true end, timeout = 2 })
    add({ wait = 0.1 })
    add({ shot = ("Q-%s-1-before.png"):format(tag) })

    -- A wrong pick, by its key.
    add({ text = function(app) return tostring(wrong_of(app.scene.quest.quiz)) end })
    add({ wait = 0.12 })
    add({ shot = ("Q-%s-2-wrong.png"):format(tag) })
    add({ until_ = function(app)
          local s = app.scene
          check(s.quiz_wrong == wrong_of(s.quest.quiz), tag .. ": the wrong pick is not marked")
          return not s.running_mode end, note = "the wrong pick is judged", timeout = 30 })
    add({ wait = 1.0 })
    add({ until_ = function(app)
          local s = app.scene
          check(app.scene_name == "quest", tag .. ": a wrong pick left the quest")
          check(s:quiz_locked(), tag .. ": a wrong pick unlocked the quiz")
          check(s.wrong_picks[wrong_of(s.quest.quiz)] == true, tag .. ": the wrong row is not struck")
          check(s.choice_hits[wrong_of(s.quest.quiz)] == nil, tag .. ": a struck row still takes a tap")
          return true end, timeout = 3 })
    add({ shot = ("Q-%s-3-after-wrong.png"):format(tag) })

    -- The right one, by a click on its box.
    add({ until_ = function(app)
          local s = app.scene
          local i = s.quest.quiz.answer + 1
          local r = s.choice_hits[i]
          while not r and s.brief_scroll < 4000 do
            s.brief_scroll = s.brief_scroll + 40
            return false
          end
          return r ~= nil end, note = "the right choice in view", timeout = 10 })
    add({ wait = 0.2 })
    add({ click = function(app)
          local s = app.scene
          local r = s.choice_hits[s.quest.quiz.answer + 1]
          return { r.x + r.w / 2, r.y + r.h / 2 } end })
    add({ wait = 0.35 })
    add({ shot = ("Q-%s-4-right.png"):format(tag) })
    add({ until_ = function(app)
          return app.scene_name == "result"
        end, note = "the verdict screen, after the fireworks", timeout = 30 })
    add({ wait = 0.5 })
  end
end

add({ until_ = function()
      Layout.setOrientation("landscape")
      if failed > 0 then
        print(("drive: FAILED — %d check(s)"):format(failed))
        love.event.quit(1)
        return true
      end
      print("PASS: the quiz card before, after a wrong pick and after the right one")
      return true end, timeout = 2 })
add({ quit = true })
return steps
