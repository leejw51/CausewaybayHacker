-- A resumed session still gets the title card — and one press lands on `lands`.
--
--   make -C love2d drive SCRIPT=tests/drive/resume_title.lua
--
-- Against the real store (a session that resumes), because that is the case
-- `make gui` is: the card must not be skipped, the resume must not yank the
-- player off it, and pressing SPACE must go to the map, not to a login prompt.

local steps = {}
local function add(t) steps[#steps + 1] = t end
local function scene(name)
  return function(app) return app.scene_name == name end
end
local fail = false
local function check(ok, why)
  if not ok then print("FAIL: " .. why); fail = true end
end

add({ orient = "landscape" })
add({ until_ = scene("title"), note = "the title card", timeout = 12 })
add({ wait = 1.5 })
add({ until_ = function(app)
      check(app.scene_name == "title", "the card did not wait — on " .. tostring(app.scene_name))
      check(app.session.authed, "the session did not resume — this script needs a stored token")
      print(("drive: card up, authed=%s"):format(tostring(app.session.authed)))
      return true
    end, timeout = 3 })
add({ shot = "R1-title-resumed.png" })
add({ key = "space", note = "press" })
add({ until_ = function(app) return app.scene_name ~= "title" end, timeout = 5 })
add({ until_ = function(app)
      if app.scene_name == "story" then
        print("drive: first press on this store plays the opening; skipping")
        return true
      end
      return app.scene_name == "lands"
    end, timeout = 5 })
-- Conditional, not unconditional: on `lands` SPACE means "go", and a press
-- meant for an opening that never appeared walked the run into `categories`.
add({ key = "space", note = "skip the opening if it is up",
      when = function(app) return app.scene_name == "story" end })
add({ until_ = scene("lands"), note = "the map, not a login prompt", timeout = 6 })
add({ shot = "R2-lands-after-title.png" })
add({ until_ = function()
      if fail then love.event.quit(1) return true end
      print("PASS: a resumed session saw the title card, and SPACE took it to lands")
      return true
    end, timeout = 1 })
add({ quit = true })

return steps
