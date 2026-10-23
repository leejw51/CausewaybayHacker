-- The code pane's THEME button, and that it is one remembered preference.
--
--   make -C love2d drive SCRIPT=tests/drive/theme.lua ARGS="--home $(mktemp -d)"
--
-- Into the playground's CODE, LIGHT by the button, a picture; then out of the
-- playground and back, where it must still be LIGHT — it is one preference,
-- and it is stored — a picture, and DARK again by the button.

local Theme = require("src.theme")
local steps = {}
local function add(t) steps[#steps + 1] = t end
local fail = false
local function check(ok, why)
  if ok then return true end
  print("FAIL: " .. why)
  fail = true
  return false
end
local function scene(n) return function(app) return app.scene_name == n end end
local function press(rects, id)
  return function(app)
    local r = rects(app)[id]
    return { r.x + r.w / 2, r.y + r.h / 2 }
  end
end

add({ orient = "landscape" }) add({ resize = { 1280, 720 } }) add({ wait = 0.6 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      note = "login, or already resumed", timeout = 20 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = scene("login") })
add({ key = "return", when = scene("login") })
add({ until_ = scene("lands"), note = "signed in", timeout = 30 })

-- The playground, in CODE.
add({ until_ = function(app) app:go("playground"); return true end, timeout = 5 })
add({ until_ = scene("playground"), note = "the playground", timeout = 10 })
add({ wait = 0.5 })
add({ click = function(app) local r = app.scene.code_button_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return app.scene.big == true end, note = "CODE", timeout = 5 })
add({ wait = 0.4 })
add({ until_ = function(app)
      check(Theme.codeTheme() == "dark", "a fresh home did not start dark")
      check((app.scene.big_rects or {}).theme ~= nil, "no THEME button in the playground's CODE")
      return true end, timeout = 5 })
add({ shot = "T1-playground-dark.png" })
add({ click = press(function(app) return app.scene.big_rects end, "theme") })
add({ wait = 0.4 })
add({ until_ = function()
      check(Theme.codeTheme() == "light", "THEME did not turn the playground light")
      return true end, timeout = 5 })
add({ shot = "T2-playground-light.png" })

-- Out and back in: the same preference, so still light. This used to be a
-- quest's CODE, but a quest is a four-choice pick now (SPEC §0) and has no
-- editor to put in CODE; the playground is the one code screen left, and
-- what the step proved — the choice is one preference, not a scene's — is
-- proved by leaving the scene and coming back, and by the store.
add({ until_ = function(app) app:go("lands"); return true end, timeout = 5 })
add({ until_ = function(app) return app.scene_name == "lands" end, timeout = 10 })
add({ until_ = function(app) app:go("playground"); return true end, timeout = 5 })
add({ until_ = scene("playground"), note = "the playground again", timeout = 10 })
add({ wait = 0.5 })
add({ click = function(app) local r = app.scene.code_button_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return app.scene.big == true end, note = "CODE again", timeout = 5 })
add({ wait = 0.4 })
add({ until_ = function(app)
      check(Theme.codeTheme() == "light", "the playground forgot its own choice")
      check(require("src.store").saved_code_theme() == "light", "LIGHT was not stored")
      check((app.scene.big_rects or {}).theme ~= nil, "no THEME button in CODE")
      return true end, timeout = 5 })
add({ shot = "T3-playground-light-again.png" })
add({ click = press(function(app) return app.scene.big_rects end, "theme") })
add({ wait = 0.4 })
add({ until_ = function()
      check(Theme.codeTheme() == "dark", "THEME did not turn it dark again")
      check(require("src.store").saved_code_theme() == "dark", "DARK was not stored")
      return true end, timeout = 5 })
add({ shot = "T4-playground-dark.png" })

add({ until_ = function()
      print("code theme: " .. (fail and "FAILED" or "0 failures"))
      if fail then error("code theme drive failed", 0) end
      return true
    end, timeout = 3 })
add({ quit = true })
return steps
