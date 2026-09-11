-- The server field, and the store behind it (SPEC §1.1).
--
--   make -C love2d drive SCRIPT=tests/drive/serverfield.lua
--
-- Signs in, then points the client at the same server by a different address
-- and back, which is the cheap way to prove the thing that actually matters:
-- **the token is per server**. A client that kept one token across the move
-- would send a stranger's credential and be told `unauthorized` for reasons
-- the player cannot see.

local function on_login(app) return app.scene_name == "login" end
local steps = {}
local function add(t) steps[#steps + 1] = t end

add({ orient = "landscape" })
add({ wait = 0.8 })
-- The migration may have brought a session across from LÖVE's save
-- directory, in which case this starts already signed in — which is the
-- migration working, not a failure.
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      note = "login, or already resumed", timeout = 15 })
add({ until_ = function(app)
      local Store = require("src.store")
      print("store: " .. tostring(Store.where()))
      print(("server: %s (%s)"):format(app.server, app.server_from))
      return true
    end, timeout = 3 })
add({ shot = "V1-login-with-server.png" })

-- Start from a known address. The saved field persists across runs — which
-- is the point of it — so a previous run of this script may have left the
-- client pointed somewhere else.
add({ until_ = function(app)
      local ok, why = app:set_server("ws://127.0.0.1:5390/ws")
      print(("reset to the default -> %s %s"):format(tostring(ok), tostring(why)))
      return ok == true
    end, timeout = 5 })
add({ until_ = function(app) return app.client.state == "open" end,
      note = "connected to the default", timeout = 20 })

add({ note = "sign in on the default server (skipped if already resumed)" })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = on_login })
add({ key = "return", when = on_login })
add({ until_ = function(app) return app.scene_name == "lands" end,
      note = "signed in", timeout = 25 })
add({ until_ = function(app)
      local Store = require("src.store")
      print("tokens held for: " .. table.concat(Store.known_servers(), ", "))
      return true
    end, timeout = 3 })

-- A second address for the same machine. `localhost` is deliberate: on this
-- box it resolves to ::1 while the server binds 127.0.0.1, so it is also a
-- server that does not answer — which is the other half of what this field
-- has to handle gracefully.
add({ note = "now point it at a different address" })
add({ until_ = function(app)
      local ok, why = app:set_server("ws://localhost:5390/ws")
      print(("set_server -> %s %s"):format(tostring(ok), tostring(why)))
      return ok == true
    end, note = "the server changed", timeout = 5 })
add({ until_ = function(app)
      -- The assertion that matters, and it does not need the new address to
      -- answer: a different server is a different token, so this client has
      -- none for it and cannot send the other one's.
      print(("after switch: authed=%s token=%s saved=%s"):format(
        tostring(app.session.authed), tostring(app.session.token ~= nil),
        tostring(require("src.store").saved_server())))
      if app.session.token ~= nil then
        print("FAIL: a token followed the client to a different server")
        return false
      end
      return app.session.authed == false
    end, note = "no token for the new address", timeout = 20 })
add({ until_ = function(app) return app.scene_name == "login" end,
      note = "and the login screen, not a silent dead connection", timeout = 25 })
add({ wait = 0.5 })
add({ shot = "V2-new-server-no-token.png" })

add({ note = "and back — the first server's token is still there" })
add({ until_ = function(app)
      local ok = app:set_server("ws://127.0.0.1:5390/ws")
      return ok == true
    end, timeout = 5 })
add({ until_ = function(app)
      return app.session.authed
    end, note = "signed straight back in, no mnemonic typed", timeout = 25 })
add({ until_ = function(app)
      local Store = require("src.store")
      print("tokens held for: " .. table.concat(Store.known_servers(), ", "))
      print("saved server: " .. tostring(Store.saved_server()))
      return true
    end, timeout = 3 })
add({ shot = "V3-back-and-signed-in.png" })

add({ note = "a bad address says what is wrong rather than failing silently" })
add({ until_ = function(app)
      for _, bad in ipairs({
        "", "localhost:5390", "http://127.0.0.1:5390/ws", "wss://example.com/ws",
        "ws://127.0.0.1/ws", "ws://:5390/ws", "ws://127.0.0.1:5390",
      }) do
        local ok, why = app:set_server(bad)
        print(("  %-28s -> %s"):format('"' .. bad .. '"', tostring(why)))
        if ok then print("FAIL: accepted " .. bad); return false end
      end
      return true
    end, note = "every bad shape is refused with a reason", timeout = 5 })

add({ quit = true })
return steps
