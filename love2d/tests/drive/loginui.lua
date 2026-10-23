-- The login card in every state it has, both orientations: for looking at.
--
--   SHOT_TAG=comic CWBH_UI_FACE=comic make -C love2d drive \
--     SCRIPT=tests/drive/loginui.lua ARGS="--home $(mktemp -d)"
--   TYPE_STEP=4 make -C love2d drive SCRIPT=tests/drive/loginui.lua ARGS="--home $(mktemp -d)"
--
-- Empty, a phrase typed (the word grid and the derived address), revealed,
-- the SERVER chip open, a refusal (the red-ruled card under the well), the
-- KEPT KEY chip, and the WRITE THIS DOWN sheet — landscape 1280×720, then
-- portrait 720×958. `SHOT_TAG` names the files; `TYPE_STEP` is the F12 step.
--
-- Against a scratch home: the title card, the opening, then the login.

local TAG = os.getenv("SHOT_TAG") or "ui"
local STEP = tonumber(os.getenv("TYPE_STEP") or "1")
local PHRASE = "legal winner thank year wave sausage worth useful legal winner thank yellow"
local BAD = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo"

local steps = {}
local function add(t) steps[#steps + 1] = t end
local function scene(name)
  return function(app) return app.scene_name == name end
end
local function shot(name)
  add({ wait = 0.3 })
  add({ shot = ("LG-%s-%s.png"):format(TAG, name) })
end
--- The centre of a hit on the card, in virtual coordinates.
local function on_card(id)
  return function(app)
    local s = app.scene
    local r = s.hits and s.hits[id]
    if not r then error("no hit " .. id) end
    return { s.view.x + r.x + r.w / 2, s.view.y + r.y - (s.scroll or 0) + r.h / 2 }
  end
end

local function states(prefix)
  shot(prefix .. "1-empty")
  add({ text = PHRASE })
  -- Long enough for the lazy derivation in `update` to land the address.
  add({ wait = 2.0 })
  shot(prefix .. "2-phrase")
  add({ key = "f2" })
  shot(prefix .. "3-revealed")
  add({ key = "f2" })
  add({ click = on_card("server") })
  shot(prefix .. "4-server")
  add({ key = "escape", note = "close the server chip" })
  add({ key = "escape", note = "clear the phrase" })
  add({ text = BAD })
  add({ key = "return" })
  add({ until_ = function(app) return app.scene.error ~= nil end, note = "refused", timeout = 10 })
  shot(prefix .. "5-error")
  add({ key = "escape" })
  add({ until_ = function(app) app.scene.error = nil; return true end, timeout = 2 })
  add({ key = "n" })
  add({ until_ = function(app) return app.scene.mode == "new_show" end, note = "the sheet", timeout = 10 })
  add({ wait = 0.5 })
  shot(prefix .. "6-newwallet")
  add({ key = "escape" })
  add({ until_ = function(app) return app.scene.mode == "signin" end, timeout = 5 })
end

add({ orient = "landscape" })
add({ resize = { 1280, 720 } })
add({ until_ = function(app) return app.scene_name ~= "boot" end, note = "past boot", timeout = 20 })
add({ key = "space", when = scene("title") })
add({ wait = 0.6 })
add({ key = "escape", when = scene("story") })
add({ until_ = scene("login"), note = "the login screen", timeout = 20 })
add({ until_ = function(app)
      require("src.layout").setFont(STEP)
      return true
    end, timeout = 2 })
add({ freeze = 3 })
add({ wait = 0.5 })
states("L")

-- A key kept on this machine with nobody signed in: the chip.
add({ until_ = function(app)
      require("src.store").save_key("0x31c0C9a6b8D2e4F1a7c3B5d9E8f2A4c6B8d0e99F", PHRASE, 0)
      app.scene:read_kept()
      return true
    end, timeout = 2 })
shot("L7-kept")

add({ orient = "portrait" })
add({ resize = { 720, 958 } })
add({ wait = 0.5 })
states("P")
shot("P7-kept")
add({ quit = true })

return steps
