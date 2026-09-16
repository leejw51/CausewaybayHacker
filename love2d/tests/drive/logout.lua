-- LOGOUT, and the login screen it lands on.
--
--   make -C love2d drive SCRIPT=tests/drive/logout.lua ARGS="--home $(mktemp -d)"
--
-- Signs in, walks to the playground, presses the footer's LOGOUT chip, and
-- checks what the browser client promises for the same verb: the token is
-- gone here and on disk, the socket is fresh and anonymous, the login screen
-- is up with its server field, phrase field and name, and says why — and
-- that signing in again from there works. Run it against a scratch home so
-- it is a throwaway token it forgets, not yours.

local steps = {}
local function add(t) steps[#steps + 1] = t end
local fail = false
local function check(ok, why)
  if ok then return true end
  print("FAIL: " .. why)
  fail = true
  return false
end
local PHRASE = "legal winner thank year wave sausage worth useful legal winner thank yellow"

add({ orient = "landscape" })
-- A scratch home is a first run: the title card, then the opening. SPACE
-- takes the card; ESC skips the opening.
add({ until_ = function(app) return app.scene_name ~= "boot" end, note = "past boot", timeout = 20 })
add({ key = "space", when = function(app) return app.scene_name == "title" end })
add({ wait = 0.6 })
add({ key = "escape", when = function(app) return app.scene_name == "story" end })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      note = "login, or already resumed", timeout = 20 })
add({ text = PHRASE, when = function(app) return app.scene_name == "login" end })
add({ key = "return", when = function(app) return app.scene_name == "login" end })
add({ until_ = function(app) return app.scene_name == "lands" end, note = "signed in", timeout = 30 })
add({ until_ = function(app) app:go("playground"); return true end, timeout = 5 })
add({ until_ = function(app) return app.scene_name == "playground" end, note = "the playground", timeout = 10 })
add({ wait = 0.5 })
add({ until_ = function(app)
      local r = app.display_rects and app.display_rects.logout
      check(r ~= nil, "no LOGOUT chip in the footer while signed in")
      return r ~= nil
    end, note = "the chip is drawn", timeout = 5 })
add({ shot = "L1-logout-chip.png" })
add({ click = function(app) local r = app.display_rects.logout; return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return app.scene_name == "login" end, note = "back at login", timeout = 10 })
add({ wait = 0.6 })
add({ until_ = function(app)
      local s = app.scene
      check(app.session.authed == false, "still authed after LOGOUT")
      check(app.session.token == nil, "the token is still held")
      local Store = require("src.store")
      local kept = Store.load_session(app.session.server or app.server)
      check(kept == nil or kept.token == nil, "the token is still on disk")
      check(s.status == require("src.i18n").t("signed out"), "the login screen does not say why: " .. tostring(s.status))
      check(not (app.display_rects and app.display_rects.logout), "LOGOUT is still drawn while signed out")
      check(s.server ~= nil and s.server ~= "", "the server field is empty")
      return true
    end, timeout = 5 })
add({ shot = "L2-login-after-logout.png" })
-- And back in.
add({ text = PHRASE })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "lands" and app.session.authed end,
      note = "signed in again", timeout = 30 })
add({ until_ = function()
      print(fail and "logout drive: FAILED" or "logout drive: ok")
      return true
    end, timeout = 1 })
add({ quit = true })

return steps
