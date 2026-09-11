-- PROTOCOL §8 point 9, over the real socket.
--
-- Pointed at a port nothing is listening on, so LuaSocket returns a real
-- ECONNREFUSED and the backoff ladder runs against the actual transport
-- rather than the in-process fake:
--
--   CWBH_SERVER=ws://127.0.0.1:5999/ws make -C love2d drive SCRIPT=tests/drive/offline.lua
--
-- What it checks: the client retries rather than dying, the waits grow, and
-- the login screen is reachable and says where it was trying to connect.

local seen = {}

return {
  { wait = 0.4 },
  { until_ = function(app)
      if app.client.retry_at and seen[#seen] ~= app.client.attempt then
        seen[#seen + 1] = app.client.attempt
        print(("offline: attempt %d, next try in %.2fs")
          :format(app.client.attempt, app.client.retry_at - love.timer.getTime()))
      end
      return app.client.attempt >= 5
    end, note = "five refused connections, backing off", timeout = 60 },
  -- Twenty, not ten. The client rests on a title card that waits
  -- (`src/scenes/title.lua`) and hands over to the login screen after eight
  -- seconds with nobody at the keyboard, so the offline path to login is
  -- "the socket gave up" plus that eight. It measured 9.6 s against the old
  -- ten, which passed and should not have been asked to.
  { until_ = function(app) return app.scene_name == "login" end,
    note = "the login screen, not a crash", timeout = 20 },
  { wait = 0.5 },
  { shot = "O1-offline.png" },
  { note = "and typing a key while offline is refused politely" },
  { text = "legal winner thank year wave sausage worth useful legal winner thank yellow" },
  { key = "return" },
  { wait = 0.6 },
  { shot = "O2-offline-login.png" },
  { quit = true },
}
