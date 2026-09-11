-- Every implemented screen, in both orientations, as screenshots.
--
--   make -C love2d shots
--
-- SPEC §10: "Both orientations are first-class on every screen, not just the
-- map." `tests/test_layout.lua` asserts that every scene *constructs and
-- draws* at both design sizes; this is the version a person looks at.
--
-- It signs in with the public BIP-39 test mnemonic, exactly as
-- `slice.lua` does, and then walks the screen order without submitting
-- anything — so it is quick and leaves no attempts behind.

local MNEMONIC = "abandon abandon abandon abandon abandon abandon abandon abandon "
  .. "abandon abandon abandon about"

local function scene(name)
  return function(app) return app.scene_name == name end
end

local steps = {}
local function add(t) steps[#steps + 1] = t end

add({ orient = "landscape" })
add({ wait = 0.6 })
-- A stored token resumes straight past the login screen (§4.4), so the two
-- typing steps only fire when there is a login screen to type into.
local function on_login(app) return app.scene_name == "login" end
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      note = "login or an already-live session", timeout = 15 })
add({ text = MNEMONIC, when = on_login, note = "typing the mnemonic" })
add({ key = "return", when = on_login })
add({ until_ = scene("lands"), note = "signed in", timeout = 20 })

-- The screens that need no argument, in each orientation.
for _, mode in ipairs({ "landscape", "portrait" }) do
  add({ orient = mode })
  add({ resize = mode == "portrait" and { 720, 1000 } or { 1280, 720 } })
  add({ wait = 0.8 })

  add({ shot = ("lands-%s.png"):format(mode) })
  add({ key = "return" })
  add({ until_ = scene("categories"), timeout = 10, note = "categories " .. mode })
  add({ wait = 0.5 })
  add({ shot = ("categories-%s.png"):format(mode) })

  add({ key = "return" })
  add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
        timeout = 10, note = "map " .. mode })
  add({ wait = 0.6 })
  add({ shot = ("map-%s.png"):format(mode) })

  add({ key = "return" })
  add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
        timeout = 10, note = "quest " .. mode })
  add({ wait = 0.5 })
  add({ shot = ("quest-%s.png"):format(mode) })
  add({ key = "escape" })
  add({ wait = 0.5 })

  add({ key = "t" })
  add({ until_ = scene("stats"), timeout = 10, note = "stats " .. mode })
  add({ wait = 0.9 })
  add({ shot = ("stats-%s.png"):format(mode) })
  add({ key = "escape" })
  add({ wait = 0.4 })

  add({ key = "s" })
  add({ until_ = scene("search"), timeout = 10, note = "search " .. mode })
  add({ wait = 0.9 })
  add({ shot = ("search-%s.png"):format(mode) })
  add({ key = "escape" })
  add({ wait = 0.4 })

  add({ key = "a" })
  add({ until_ = scene("ai"), timeout = 10, note = "ai " .. mode })
  add({ wait = 0.9 })
  add({ shot = ("ai-%s.png"):format(mode) })
  add({ key = "escape" })
  add({ wait = 0.4 })

  -- Back up to the land select for the next pass.
  add({ key = "escape" })
  add({ wait = 0.3 })
  add({ key = "escape" })
  add({ until_ = scene("lands"), timeout = 10 })
  add({ wait = 0.4 })
end

add({ quit = true })

return steps
