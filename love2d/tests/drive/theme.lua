-- The code pane's THEME button, on both code screens.
--
--   make -C love2d drive SCRIPT=tests/drive/theme.lua ARGS="--home $(mktemp -d)"
--
-- Into the playground's CODE, LIGHT by the button, a picture; then a quest's
-- CODE, which must already be LIGHT — it is one preference — a picture, and
-- DARK again by the button there.

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

-- A quest, in CODE: the same preference, so already light.
add({ until_ = function(app) app:go("lands"); return true end, timeout = 5 })
add({ until_ = function(app) return app.scene_name == "lands" and app.scene.lands ~= nil end,
      timeout = 10 })
add({ until_ = function(app)
      for i, land in ipairs(app.scene.lands or {}) do
        if land.land == "rust" then app.scene.cursor = i; app.scene.land = "rust" end
      end
      return app.scene.land == "rust" end, note = "RUST land", timeout = 5 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "categories" and app.scene.categories end,
      timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end, timeout = 10 })
add({ until_ = function(app)
      app.scene.cursor = 1; app.scene.at = 1; app.scene.walk = nil; return true end, timeout = 3 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
      timeout = 20 })
add({ wait = 0.6 })
add({ click = function(app) local r = app.scene.code_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return app.scene.code_mode end, note = "CODE", timeout = 5 })
add({ wait = 0.4 })
add({ until_ = function(app)
      check(Theme.codeTheme() == "light", "the quest did not keep the playground's choice")
      check((app.scene.code_rects or {}).theme ~= nil, "no THEME button in the quest's CODE")
      return true end, timeout = 5 })
add({ shot = "T3-quest-light.png" })
add({ click = press(function(app) return app.scene.code_rects end, "theme") })
add({ wait = 0.4 })
add({ until_ = function()
      check(Theme.codeTheme() == "dark", "THEME did not turn the quest dark again")
      return true end, timeout = 5 })
add({ shot = "T4-quest-dark.png" })

add({ until_ = function()
      print("code theme: " .. (fail and "FAILED" or "0 failures"))
      if fail then error("code theme drive failed", 0) end
      return true
    end, timeout = 3 })
add({ quit = true })
return steps
