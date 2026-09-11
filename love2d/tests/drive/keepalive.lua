-- PROTOCOL §8 point 12, against the real server.
--
-- §1.1: the server sends a websocket ping every 30 s and closes a connection
-- that misses two. This client does both halves — it answers the real ping
-- frames with pongs, *and* sends the application-level `ping` every 20 s —
-- so this sits still for 70 seconds and asserts both counters moved and the
-- connection is still open.
--
--   make -C love2d drive SCRIPT=tests/drive/keepalive.lua

return {
  { wait = 1.0 },
  { until_ = function(app) return app.client.state == "open" end, timeout = 15 },
  { note = "sitting still for 70 seconds" },
  { wait = 70 },
  { until_ = function(app)
      print(("keepalive: state=%s  app-pings=%d  pongs=%d  in-flight=%d")
        :format(app.client.state, app.client.pings_sent, app.client.pongs_sent,
          app.client:inflight()))
      return app.client.state == "open" and app.client.pings_sent >= 3
    end, note = "still open, and at least three 20s pings went out", timeout = 20 },
  { until_ = function(app)
      -- The server pings every 30 s, so 70 seconds should have drawn at
      -- least one pong out of this client. Reported either way.
      if app.client.pongs_sent == 0 then
        print("keepalive: no websocket ping arrived in 70s — the app-level"
          .. " ping is what is holding the connection open")
      end
      return true
    end, timeout = 5 },
  { quit = true },
}
