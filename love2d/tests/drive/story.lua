-- The title card, the opening, and the promise that it plays **once**.
--
--   HOME=$(mktemp -d)
--   make -C love2d drive SCRIPT=tests/drive/story.lua ARGS="--home $HOME"
--   make -C love2d drive SCRIPT=tests/drive/story.lua ARGS="--home $HOME"
--
-- Two runs of one script against **the same store**, because the property
-- under test spans a restart: a returning player must never sit through the
-- opening again unasked. The script asks the store which run it is in and
-- asserts the other half each time —
--
--   run 1 (fresh store)   boot → title → SPACE → story → skip → login
--                         and `story.seen` is on disk afterwards
--   run 2 (same store)    boot → title → SPACE → login, with no story at all
--
-- Run 1 also presses `STORY` on the login screen, which is the way back in,
-- and checks that using it does **not** clear the flag: watching the opening
-- again on purpose is not the same as never having been offered it.

local Store = require("src.store")

local steps = {}
local function add(t) steps[#steps + 1] = t end
local function scene(name)
  return function(app) return app.scene_name == name end
end

--- Which run this is, read from the store the moment the script starts.
local first_run = nil
local seen = {}
local fail = false
local function check(ok, why)
  if ok then return true end
  print("FAIL: " .. why)
  fail = true
  return false
end

add({ orient = "landscape" })
add({ until_ = function()
      first_run = not Store.story_seen()
      print(("drive: this is the %s run — story.seen is %s"):format(
        first_run and "FIRST" or "SECOND", tostring(Store.story_seen())))
      return true
    end, timeout = 5 })

-- The card itself. It must arrive, and it must **wait**: eight seconds is the
-- idle-out, so a screen that is still the title card two seconds in is a
-- screen that is waiting rather than one that auto-advanced.
add({ until_ = scene("title"), note = "the title card", timeout = 12 })
add({ until_ = function(app)
      seen.card_at = love.timer.getTime()
      print("drive: title card up, footer says " .. tostring(app.last_hint))
      return true
    end, timeout = 3 })
add({ wait = 1.5 })
add({ until_ = function(app)
      check(app.scene_name == "title", "the card did not wait — it is on " .. tostring(app.scene_name))
      return true
    end, timeout = 3 })
add({ shot = "S1-title.png" })

add({ note = "SPACE" })
add({ key = "space" })
add({ wait = 0.4 })

-- ------------------------------------------------------------ the first run

add({ until_ = function(app)
      if not first_run then return true end
      check(app.scene_name == "story",
        "the first press should have played the opening, got " .. tostring(app.scene_name))
      seen.story = app.scene_name == "story"
      return true
    end, timeout = 5, when = function() return first_run end })
add({ wait = 5.0, when = function() return first_run end })
add({ until_ = function(app)
      print(("drive: opening at beat %d of %d"):format(
        app.scene.i or 0, require("src.scenes.story").BEATS))
      return true
    end, timeout = 3, when = function() return first_run end })
add({ shot = "S2-story-beat.png", when = function() return first_run end })

add({ note = "skip, mid-beat", when = function() return first_run end })
add({ key = "escape", when = function() return first_run end })
add({ until_ = scene("login"), note = "skipped to the login screen", timeout = 6,
      when = function() return first_run end })
add({ until_ = function()
      check(Store.story_seen(),
        "skipping did not mark the opening as seen, so it would play again")
      return true
    end, timeout = 3, when = function() return first_run end })
add({ shot = "S3-login-with-story-button.png", when = function() return first_run end })

-- The way back in. Aimed at the rectangle the draw actually recorded, so the
-- test is about the control rather than about arithmetic in the test.
add({ note = "STORY on the login screen", when = function() return first_run end })
add({ click = function(app)
      local px, py, pw = app.scene:panel_rect()
      local b = app.scene.story_button
      assert(b, "no STORY button was drawn")
      return { px + 20 + b.w / 2, py + 18 + b.y + b.h / 2 }
    end, when = function() return first_run end })
add({ until_ = scene("story"), note = "the replay", timeout = 5,
      when = function() return first_run end })
add({ wait = 0.6, when = function() return first_run end })
add({ key = "space", when = function() return first_run end })
add({ until_ = scene("login"), note = "back from the replay", timeout = 6,
      when = function() return first_run end })
add({ until_ = function()
      check(Store.story_seen(), "the replay cleared the flag, which it must not")
      return true
    end, timeout = 3, when = function() return first_run end })

-- ----------------------------------------------------------- the second run

add({ until_ = function(app)
      if first_run then return true end
      -- The whole point: no opening, no pause, straight to work.
      check(app.scene_name == "login",
        "a returning player was sent to " .. tostring(app.scene_name)
          .. " instead of straight to the login screen")
      return true
    end, timeout = 6, when = function() return not first_run end })
add({ shot = "S4-second-run-login.png", when = function() return not first_run end })

add({ until_ = function(app)
      if fail then
        print("drive: FAILED")
        love.event.quit(1)
        return true
      end
      if first_run then
        print("PASS: the card waited, SPACE played the opening, a skip counted as"
          .. " watched, and STORY played it again without clearing the flag")
      else
        print("PASS: a store that has seen the opening goes title → login with no"
          .. " opening in between (scene=" .. tostring(app.scene_name) .. ")")
      end
      return true
    end, timeout = 3 })
add({ quit = true })

return steps
