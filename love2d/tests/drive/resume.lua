-- Restart persistence: PLAN.md's "still cleared after a restart".
--
-- Run this straight after `slice.lua`, without clearing the save directory.
-- Nothing is typed: the only thing on disk is the session token (PROTOCOL §6
-- rule 1), and `auth.resume` trades it for an authenticated connection
-- without the key ever existing again. The map is refetched from the server,
-- so the stamp on node 1 is the server's memory and not this client's.
--
--   make -C love2d drive SCRIPT=tests/drive/resume.lua

return {
  { orient = "landscape" },
  { wait = 0.5 },
  { until_ = function(app) return app.session.authed end,
    note = "auth.resume with the stored token — no mnemonic typed", timeout = 15 },
  { until_ = function(app) return app.scene_name == "lands" end,
    note = "straight past the login screen", timeout = 10 },
  { wait = 0.6 },
  { shot = "R1-resumed.png" },

  { key = "return" },
  { until_ = function(app) return app.scene_name == "categories" end, timeout = 10 },
  { key = "return" },
  { until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
    note = "world.map refetched (§6 rule 5)", timeout = 10 },
  { until_ = function(app)
      for _, n in ipairs(app.scene.nodes) do
        if n.node == 1 and n.state == "cleared" then return true end
      end
      return false
    end, note = "node 1 is STILL cleared after a restart", timeout = 10 },
  { wait = 0.8 },
  { shot = "R2-still-cleared.png" },
  { quit = true },
}
