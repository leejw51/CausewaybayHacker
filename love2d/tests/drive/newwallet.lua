-- The way in for a player who owns no BIP-39 phrase.
--
--   rm -f ~/Library/Application\ Support/LOVE/causewaybay-hacker/session.json
--   make -C love2d drive SCRIPT=tests/drive/newwallet.lua
--
-- NEW WALLET → twelve words and the address they derive, on screen → I HAVE
-- WRITTEN IT DOWN → a real `auth.challenge` / `auth.login` against the
-- server, and a map that comes up empty because this account has never
-- existed before.
--
-- There is no confirmation step: the user asked for the button to sign in
-- directly, and `src/scenes/login.lua` says why a softer gate was not
-- substituted for the one that was removed.
--
-- Two things this checks that are easy to get wrong:
--
--   * a **double press** must create one account, not two racing challenges;
--   * the phrase must be **gone from Lua state** the moment the screen is
--     left, whether it was used or cancelled.

local function scene(name)
  return function(app) return app.scene_name == name end
end

local steps = {}
local function add(t) steps[#steps + 1] = t end

add({ orient = "landscape" })
add({ wait = 0.6 })
add({ until_ = scene("login"), note = "login", timeout = 15 })
add({ shot = "N1-signin.png" })

-- Cancel once, first: backing out must create nothing and leave nothing.
add({ note = "NEW WALLET, then ESC — nothing created, nothing kept" })
add({ key = "n" })
add({ until_ = function(app) return app.scene.mode == "new_show" end, timeout = 10 })
add({ key = "escape" })
add({ until_ = function(app)
      if app.scene.mode ~= "signin" then return false end
      if app.scene.words ~= nil then
        print("FAIL: the cancelled phrase is still in the scene")
        return false
      end
      if app.session.authed then
        print("FAIL: cancel created an account")
        return false
      end
      print("cancel: phrase dropped, no account created")
      return true
    end, note = "cancel leaves nothing behind", timeout = 10 })

add({ note = "now for real" })
add({ key = "n" })
add({ until_ = function(app) return app.scene.mode == "new_show" end,
      note = "twelve words and an address, on screen", timeout = 10 })
add({ wait = 0.5 })
add({ until_ = function(app)
      print(("new wallet: %d words, address %s"):format(
        #(app.scene.words or {}), tostring(app.scene.new_address)))
      return #(app.scene.words or {}) == 12 and app.scene.new_address ~= nil
    end, timeout = 5 })
add({ shot = "N2-write-down.png" })

-- Two presses, one frame apart. One account, one challenge.
add({ note = "I HAVE WRITTEN IT DOWN — pressed twice, on purpose" })
add({ key = "return" })
add({ key = "return" })

add({ until_ = scene("lands"), note = "signed straight in, no confirmation step", timeout = 25 })
add({ until_ = function(app)
      -- §4.2/§4.3: exactly one challenge and one login left this client.
      local challenges, logins = 0, 0
      for _, type_name in ipairs(app.client.sent_types) do
        if type_name == "auth.challenge" then challenges = challenges + 1 end
        if type_name == "auth.login" then logins = logins + 1 end
      end
      print(("double press: %d auth.challenge, %d auth.login"):format(challenges, logins))
      if challenges ~= 1 or logins ~= 1 then
        print("FAIL: a double press raced")
        return false
      end
      return true
    end, note = "one account, not two", timeout = 10 })
add({ until_ = function(app)
      local scene_ = app.scene
      if scene_.words ~= nil then
        print("FAIL: the phrase outlived the screen")
        return false
      end
      print("phrase: gone from Lua state after signing in")
      return true
    end, note = "the phrase did not outlive the screen", timeout = 5 })
add({ wait = 0.8 })
add({ shot = "N3-new-account.png" })

add({ until_ = function(app) return app.scene.lands ~= nil end, timeout = 10 })
add({ key = "return" })
add({ until_ = scene("categories"), timeout = 10 })
add({ until_ = function(app) return app.scene.categories ~= nil end, timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
      note = "a fresh map", timeout = 10 })
add({ until_ = function(app)
      local open, locked, cleared = 0, 0, 0
      for _, n in ipairs(app.scene.nodes) do
        if n.state == "open" then open = open + 1 end
        if n.state == "locked" then locked = locked + 1 end
        if n.state == "cleared" then cleared = cleared + 1 end
      end
      print(("map: %d nodes, %d open, %d locked, %d cleared")
        :format(#app.scene.nodes, open, locked, cleared))
      return cleared == 0
    end, note = "nothing cleared — this really is a new account", timeout = 5 })
add({ wait = 1.0 })
add({ shot = "N4-fresh-map.png" })

add({ orient = "portrait" })
add({ resize = { 720, 1000 } })
add({ wait = 1.0 })
add({ shot = "N5-fresh-map-portrait.png" })
add({ quit = true })

return steps
