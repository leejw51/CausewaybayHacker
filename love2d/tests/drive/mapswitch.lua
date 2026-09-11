-- Switching land and category from the map, without leaving it.
--
--   make -C love2d drive SCRIPT=tests/drive/mapswitch.lua
--
-- The point of removing the gates was that somebody with an interview on
-- Thursday goes straight to the hard street. If reaching HACKER still cost
-- ESC → lands → land → category, the gate would be gone and the friction
-- would not. So: TAB for the land, Q for the category, both from here.

local function on_login(app) return app.scene_name == "login" end
local steps = {}
local function add(t) steps[#steps + 1] = t end

local function report(tag)
  return function(app)
    local m = app.scene
    print(("%-22s land=%-5s category=%-9s nodes=%-3s cursor=%s walk=%s")
      :format(tag, tostring(m.land), tostring(m.category),
        m.nodes and #m.nodes or "-", tostring(m.cursor), tostring(m.walk ~= nil)))
    return true
  end
end

local function loaded(app) return app.scene_name == "map" and app.scene.nodes ~= nil end

add({ orient = "landscape" })
add({ wait = 0.6 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      timeout = 15 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = on_login })
add({ key = "return", when = on_login })
add({ until_ = function(app) return app.scene_name == "lands" end, note = "signed in", timeout = 25 })
add({ until_ = function(app) return app.scene.lands ~= nil end, timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "categories" and app.scene.categories end,
      timeout = 10 })
add({ key = "return" })
add({ until_ = loaded, note = "on the map", timeout = 10 })
add({ wait = 0.6 })
add({ until_ = report("start"), timeout = 3 })
add({ shot = "M1-rust-basic.png" })

-- Move the cursor somewhere memorable, so "come back to where I was" is
-- testable rather than assumed.
add({ until_ = function(app)
      app.scene.cursor = math.min(5, #app.scene.nodes)
      app.scene.at = app.scene.cursor
      app.scene.walk = nil
      return true
    end, timeout = 3 })

add({ note = "Q — the next category, one action" })
add({ key = "q" })
add({ until_ = loaded, timeout = 12 })
add({ wait = 0.5 })
add({ until_ = report("after Q"), timeout = 3 })
add({ shot = "M2-rust-advanced.png" })

add({ key = "q" })
add({ until_ = loaded, timeout = 12 })
add({ wait = 0.5 })
add({ until_ = report("after Q Q"), timeout = 3 })
add({ shot = "M3-rust-hacker.png" })

add({ note = "TAB — the other land, and the category must come with it" })
add({ key = "tab" })
add({ until_ = loaded, timeout = 12 })
add({ wait = 0.6 })
add({ until_ = function(app)
      local m = app.scene
      print(("%-22s land=%-5s category=%-9s nodes=%s"):format(
        "after TAB", m.land, m.category, #m.nodes))
      if m.land ~= "go" then print("FAIL: TAB did not change the land"); return false end
      if m.category ~= "hacker" then
        print("FAIL: the land switch lost the category — got " .. m.category)
        return false
      end
      if m.walk then print("FAIL: a walk survived the switch"); return false end
      print("switch: GO / HACKER in one keypress, straight from the map")
      return true
    end, note = "land switched, category kept, no walk across", timeout = 10 })
add({ shot = "M4-go-hacker.png" })

-- Back to where we started: TAB returns to rust/hacker, and one Q wraps
-- hacker -> basic. (Two Q's overshoot to advanced — which this script did on
-- its first run, and the assertion below caught rather than glossing over.)
add({ note = "back to where we were — nothing is lost by looking" })
add({ key = "tab" })
add({ until_ = loaded, timeout = 12 })
add({ key = "q" })
add({ until_ = loaded, timeout = 12 })
add({ wait = 0.6 })
add({ until_ = function(app)
      local m = app.scene
      local node = m.nodes[m.cursor]
      print(("%-22s land=%-5s category=%-9s cursor is node %s (%s)"):format(
        "back at the start", m.land, m.category,
        tostring(node and node.node), tostring(node and node.quest_id)))
      if m.land ~= "rust" or m.category ~= "basic" then
        print("FAIL: did not come back to rust/basic")
        return false
      end
      if not node or node.node ~= 5 then
        print("FAIL: the map did not remember the node it was left on")
        return false
      end
      print("memory: came back to node 5, where it was left")
      return true
    end, note = "the map remembered where it was left", timeout = 10 })
add({ shot = "M5-back-at-start.png" })

add({ orient = "portrait" })
add({ resize = { 720, 1000 } })
add({ wait = 1.0 })
add({ shot = "M6-portrait.png" })
add({ quit = true })

return steps
