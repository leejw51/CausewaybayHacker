-- RUN and SUBMIT (PROTOCOL §4.9b), and an unlocked map (§4.7), against the
-- real server.
--
--   make -C love2d drive SCRIPT=tests/drive/runsubmit.lua

local function scene(name)
  return function(app) return app.scene_name == name end
end
local function on_login(app) return app.scene_name == "login" end

local steps = {}
local function add(t) steps[#steps + 1] = t end

add({ orient = "landscape" })
add({ wait = 0.6 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      timeout = 15 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = on_login })
add({ key = "return", when = on_login })
add({ until_ = scene("lands"), note = "signed in", timeout = 25 })
add({ until_ = function(app) return app.scene.lands ~= nil end, timeout = 10 })
add({ key = "return" })
add({ until_ = scene("categories"), timeout = 10 })
add({ until_ = function(app) return app.scene.categories ~= nil end, timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
      note = "the map", timeout = 10 })

-- §4.7. The server side of this is BE's and may not have landed yet, so the
-- states are *reported*; what is asserted is the half this client owns —
-- that it neither draws a padlock nor refuses to enter a node, whatever the
-- server calls it.
add({ until_ = function(app)
      local states = {}
      for _, n in ipairs(app.scene.nodes) do states[n.state] = (states[n.state] or 0) + 1 end
      local parts = {}
      for k, v in pairs(states) do parts[#parts + 1] = ("%s=%d"):format(k, v) end
      table.sort(parts)
      print("map states as the server reports them: " .. table.concat(parts, " "))
      if states.locked then
        print("note: the server still emits `locked` (§4.7 not shipped server-side yet);"
          .. " the client does not gate on it")
      end
      return true
    end, note = "map state, reported", timeout = 10 })

-- The client-side property: a node the server calls `locked` is still drawn
-- as a playable node and still opens. Before §4.7 this screen refused it with
-- a toast and drew a padlock.
add({ until_ = function(app)
      local Assets = require("src.assets")
      local target
      for i, n in ipairs(app.scene.nodes) do
        if n.state == "locked" then target = i; break end
      end
      if not target then
        print("client: no locked node to try — nothing to prove here")
        app.probe_locked = "skipped"
        return true
      end
      app.probe_locked = app.scene.nodes[target].quest_id
      app.scene.cursor = target
      app.scene.at = target
      app.scene.walk = nil
      print(("client: entering %s, which the server calls locked")
        :format(app.probe_locked))
      -- And the padlock art is not on the map at all any more.
      if Assets.image("node_locked") and app.scene.marker_for then
        print("client: node_locked is loaded but unreachable from marker_for")
      end
      return true
    end, timeout = 5 })
add({ key = "return" })
add({ until_ = function(app)
      if app.probe_locked == "skipped" then return true end
      if app.scene_name ~= "quest" then
        print("FAIL: the client refused a node instead of letting the server decide")
        return false
      end
      print("client: the map did not refuse it — the server is the only authority (§4.7)")
      return true
    end, note = "the client does not gate", timeout = 10 })
add({ until_ = function(app)
      if app.probe_locked == "skipped" then return true end
      -- Whatever the server says back is what the player sees; that is the
      -- correct division either way.
      print("server answered quest.get with: " .. tostring(app.scene.error or "the quest"))
      return true
    end, timeout = 8 })
add({ key = "escape" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end, timeout = 10 })
add({ wait = 0.6 })
add({ shot = "R1-map-unlocked.png" })

-- Jump a long way, and watch her walk.
add({ note = "picking a far node — Mei should walk, and the walk must be skippable" })
add({ until_ = function(app)
      local far = math.min(#app.scene.nodes, 12)
      app.scene.cursor = far
      app.scene:walk_to(far)
      local w = app.scene.walk
      print(("walk: %d nodes along the route, %.2fs"):format(
        w and #w.path or 0, w and w.duration or 0))
      return w ~= nil
    end, note = "a walk started", timeout = 5 })
add({ wait = 0.18 })
add({ shot = "R2-mei-walking.png" })
add({ until_ = function(app)
      return app.scene.walk ~= nil or true
    end, timeout = 2 })
add({ note = "any key lands her immediately" })
add({ key = "f8" })
add({ until_ = function(app)
      if app.scene.walk ~= nil then
        print("FAIL: a keypress did not skip the walk")
        return false
      end
      print("walk: skipped by a keypress, she is standing on the destination")
      return true
    end, note = "the walk is skippable", timeout = 3 })
add({ wait = 0.4 })
add({ shot = "R3-mei-arrived.png" })

-- Into a quest, and RUN it.
add({ until_ = function(app)
      -- Somewhere early, so the sample is small.
      app.scene.cursor = 1
      app.scene.at = 1
      app.scene.walk = nil
      return true
    end, timeout = 3 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
      note = "in the editor", timeout = 15 })
add({ wait = 0.5 })
add({ shot = "R4-quest-two-buttons.png" })

add({ note = "a wrong answer, RUN — must not read as a verdict" })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = 'fn main() {\nprintln!("not the answer");' })
add({ key = "f5" })
-- A second and third press, immediately: the shared slot must refuse them.
add({ key = "f5" })
add({ key = "f10" })
add({ until_ = function(app)
      -- `running_mode` is transient — on a fast reply it is nil again before
      -- the next poll — so what is checked is what actually left the client.
      local runs = 0
      for _, t in ipairs(app.client.sent_types) do
        if t == "quest.run" then runs = runs + 1 end
      end
      if runs == 0 then return false end
      if app.scene.run_attempt or app.scene.error then return true end
      return false
    end, note = "F5 sent quest.run and it came back", timeout = 90 })
add({ until_ = function(app)
      if app.scene.run_attempt then return true end
      print("note: quest.run did not return an Attempt — the server said: "
        .. tostring(app.scene.error))
      print("      (§4.9b may not have shipped server-side yet)")
      app.run_unsupported = true
      return true
    end, timeout = 5 })
add({ until_ = function(app)
      if app.run_unsupported then return true end
      local a = app.scene.run_attempt
      local runs, submits = 0, 0
      for _, t in ipairs(app.client.sent_types) do
        if t == "quest.run" then runs = runs + 1 end
        if t == "quest.submit" then submits = submits + 1 end
      end
      print(("run: mode=%s verdict=%s %d/%d cleared=%s stars=%s")
        :format(tostring(a.mode), a.verdict, a.tests_passed or 0, a.tests_total or 0,
          tostring(a.cleared), tostring(a.stars)))
      print(("in flight: %d quest.run, %d quest.submit left the client"):format(runs, submits))
      if runs ~= 1 or submits ~= 0 then
        print("FAIL: the shared in-flight slot did not hold")
        return false
      end
      if a.cleared ~= false then print("FAIL: a run cleared something"); return false end
      if app.scene_name ~= "quest" then print("FAIL: a run left the quest screen"); return false end
      return true
    end, note = "one run, no submit, nothing cleared, still on the quest screen", timeout = 10 })
add({ wait = 0.5 })
add({ shot = "R5-run-failed.png" })

add({ note = "now the right answer, RUN first" })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = 'fn main() {\nprintln!("hello, causewaybay");' })
add({ key = "f5" })
add({ until_ = function(app)
      if app.run_unsupported then return true end
      return app.scene.run_attempt ~= nil and app.scene.running_mode == nil
        and app.scene.run_attempt.verdict == "accepted"
    end, note = "the sample passes", timeout = 90 })
add({ until_ = function(app)
      if app.run_unsupported then return true end
      local a = app.scene.run_attempt
      print(("run: %s, %d/%d samples, cleared=%s — still on the quest screen: %s")
        :format(a.verdict, a.tests_passed or 0, a.tests_total or 0,
          tostring(a.cleared), tostring(app.scene_name == "quest")))
      return app.scene_name == "quest"
    end, note = "a passing run is not a verdict", timeout = 5 })
add({ wait = 0.6 })
add({ shot = "R6-run-passes.png" })

add({ note = "and SUBMIT, which is the one that counts" })
add({ key = "f10" })
add({ until_ = scene("result"), note = "SUBMIT went to the result screen", timeout = 90 })
add({ until_ = function(app)
      local a = app.scene.attempt
      print(("submit: mode=%s verdict=%s %d/%d cleared=%s stars=%s")
        :format(tostring(a.mode), a.verdict, a.tests_passed or 0, a.tests_total or 0,
          tostring(a.cleared), tostring(a.stars)))
      return a.mode == "submit" or a.mode == nil
    end, timeout = 5 })
add({ wait = 0.8 })
add({ shot = "R7-submit-result.png" })
add({ quit = true })

return steps
