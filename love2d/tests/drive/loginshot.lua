-- The sign-in card with a phrase, an account index and the name they imply.
--
--   LANG_CODE=ko make -C love2d drive SCRIPT=tests/drive/loginshot.lua
--
-- Deliberately stops short of pressing ENTER: what is being looked at is the
-- state *before* signing in, which is the whole point of the three boxes.

local WANT = os.getenv("LANG_CODE") or "en"
local INDEX = os.getenv("ACCOUNT") or "7"
local MNEMONIC = "legal winner thank year wave sausage worth useful legal winner "
  .. "thank yellow"

local steps = {}
local function add(t) steps[#steps + 1] = t end
local function scene(name)
  return function(app) return app.scene_name == name end
end

add({ orient = "landscape" })
add({ wait = 0.8 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      timeout = 20 })
add({ until_ = function(app)
      app:set_lang(WANT)
      return true
    end, timeout = 5, when = scene("login") })
add({ wait = 1.2 })
add({ text = MNEMONIC, when = scene("login") })
add({ wait = 0.6 })
-- TAB from the phrase to the account box, clear the 0, type the index.
add({ key = "tab", when = scene("login") })
add({ key = "backspace", when = scene("login") })
add({ text = INDEX, when = scene("login") })
-- Long enough for the lazy derivation in `update` to run and the name to land.
add({ wait = 2.5 })
add({ until_ = function(app)
      local s = app.scene
      print(("index=%s account=%d name=%q preview=%s"):format(
        tostring(s.index), s:account_index(), tostring(s.name), tostring(s.preview)))
      return true
    end, timeout = 5 })
add({ shot = "L-login-account.png" })
add({ wait = 0.3 })
-- TAB on to the name box. The card is taller than the panel now, so this is
-- also the check that the row scrolls into view rather than staying under the
-- rim — `bring_into_view` follows the focus when it moves.
add({ key = "tab", when = scene("login") })
add({ wait = 1.2 })
add({ shot = "L-login-name.png" })
add({ wait = 0.3 })

-- `SIGNIN=1` carries on and actually logs in, which is the only way to check
-- that the index and the name reached the server rather than only the screen.
if os.getenv("SIGNIN") == "1" then
  add({ key = "return", when = scene("login") })
  add({ until_ = scene("lands"), note = "signed in", timeout = 40 })
  add({ wait = 1.0 })
  add({ until_ = function(app)
        local u = app.session and app.session.user or {}
        print(("server says: name=%q address=%s"):format(
          tostring(u.name), tostring(u.address or u.address_eip55)))
        return true
      end, timeout = 5 })
end
add({ quit = true })

return steps
