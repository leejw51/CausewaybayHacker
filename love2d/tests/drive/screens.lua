-- SEARCH, STATS and AI MODE against the live server.
--
--   make -C love2d drive SCRIPT=tests/drive/screens.lua
--
-- `stats.*` is live; `search.query` and `ai.plan` answer `unavailable` with
-- `detail.milestone`, and what is checked is that the screens say so in the
-- story's voice rather than reporting a broken server.

local function on_login(app) return app.scene_name == "login" end
local steps = {}
local function add(t) steps[#steps + 1] = t end

add({ orient = "landscape" })
add({ wait = 0.8 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end, timeout = 15 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = on_login })
add({ key = "return", when = on_login })
add({ until_ = function(app) return app.scene_name == "lands" end, note = "signed in", timeout = 25 })
add({ until_ = function(app) return app.scene.lands ~= nil end, timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "categories" and app.scene.categories end, timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end, timeout = 12 })

add({ note = "STATS — live" })
add({ key = "t" })
add({ until_ = function(app) return app.scene_name == "stats" end, timeout = 10 })
add({ until_ = function(app)
      local sc = app.scene
      return sc.summary ~= nil and sc.mistakes ~= nil and sc.awards ~= nil and sc.history ~= nil
    end, note = "all four stats calls answered", timeout = 20 })
add({ until_ = function(app)
      local sc = app.scene
      print(("stats: cleared=%d/%d submits=%d accuracy=%.3f stars=%d streak=%dd"):format(
        sc.summary.cleared or 0, sc.summary.total or 0, sc.summary.attempts or 0,
        sc.summary.accuracy or 0, sc.summary.stars or 0, sc.summary.streak_days or 0))
      print(("mistakes: %d kinds   awards: %d   history: %d"):format(
        #sc.mistakes, #sc.awards, #sc.history))
      for _, m in ipairs(sc.mistakes) do
        local learned = (m.cleared_since or 0) >= 5
        print(("  %-16s x%-3d cleared_since=%d %s"):format(
          tostring(m.kind), m.count or 0, m.cleared_since or 0,
          learned and "(learned)" or ("(" .. (5 - (m.cleared_since or 0)) .. " to go)")))
      end
      return true
    end, timeout = 5 })
add({ wait = 0.6 })
add({ shot = "X1-stats.png" })
add({ key = "h" })
add({ wait = 0.6 })
add({ shot = "X2-stats-history.png" })
add({ key = "escape" })
add({ until_ = function(app) return app.scene_name == "map" end, timeout = 10 })

add({ note = "SEARCH — unavailable, and it must not read as a broken server" })
add({ key = "s" })
add({ until_ = function(app) return app.scene_name == "search" end, timeout = 10 })
add({ text = "borrow checker" })
add({ key = "return" })
add({ until_ = function(app)
      local sc = app.scene
      if sc.searching then return false end
      if sc.unavailable then
        print(("search: unavailable, milestone=%s"):format(tostring(sc.unavailable.milestone)))
        print("  server said: " .. tostring(sc.unavailable.message))
        return true
      end
      if sc.hits then print("search: " .. #sc.hits .. " hits"); return true end
      if sc.error then print("search: FAIL treated as an error — " .. sc.error); return true end
      return false
    end, note = "search answered", timeout = 20 })
add({ wait = 0.6 })
add({ shot = "X3-search.png" })
add({ key = "escape" })
add({ until_ = function(app) return app.scene_name == "map" end, timeout = 10 })

add({ note = "AI MODE" })
add({ key = "a" })
add({ until_ = function(app) return app.scene_name == "ai" end, timeout = 10 })
add({ until_ = function(app) return app.scene.mistakes ~= nil end,
      note = "it knows whether there is anything to drill", timeout = 15 })
add({ wait = 0.5 })
add({ shot = "X4-ai-modes.png" })
add({ key = "return" })
add({ until_ = function(app)
      local sc = app.scene
      if sc.busy then return false end
      if sc.unavailable then
        print(("ai: unavailable, milestone=%s"):format(tostring(sc.unavailable.milestone)))
        print("  server said: " .. tostring(sc.unavailable.message))
        return true
      end
      if sc.drill then print("ai: a drill of " .. tostring(#(sc.drill.plan or {}))); return true end
      if sc.error then print("ai: FAIL treated as an error — " .. sc.error); return true end
      return false
    end, note = "ai.plan answered", timeout = 20 })
add({ wait = 0.6 })
add({ shot = "X5-ai.png" })

add({ orient = "portrait" })
add({ resize = { 720, 1000 } })
add({ wait = 1.0 })
add({ shot = "X6-ai-portrait.png" })
add({ quit = true })
return steps
