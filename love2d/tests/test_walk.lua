-- The map walk: the curve, the route, and the cap on how long it takes.
--
-- Headless. `Map`'s geometry needs a Layout with a canvas, so the pieces
-- asserted here are the ones that are pure arithmetic — the easing curves and
-- the duration rule — plus the route search, driven through a Map built by
-- hand with no window.

local T = require("tests.framework")
local Ease = require("src.ease")

return function()
  T.section("ease — the expo curves the walk is authored against")

  T.case("expInOut is a real ease-in-out", function()
    T.near(Ease.expInOut(0), 0, 1e-9)
    T.near(Ease.expInOut(1), 1, 1e-9)
    T.near(Ease.expInOut(0.5), 0.5, 1e-9, "symmetric about the middle")
    -- Almost still at the ends: that is the whole character of expo, and it
    -- is what makes the walk read as deliberate rather than as linear drift.
    T.ok(Ease.expInOut(0.1) < 0.01, "still gathering at 10%")
    T.ok(Ease.expInOut(0.9) > 0.99, "already arriving at 90%")
    -- Monotonic, or she walks backwards somewhere in the middle.
    local previous = -1
    for i = 0, 100 do
      local v = Ease.expInOut(i / 100)
      T.ok(v >= previous, ("monotonic at t=%.2f"):format(i / 100))
      previous = v
    end
  end)

  T.case("the expo curve is much faster in the middle than a linear one", function()
    -- The middle tenth should carry a large share of the distance; that is
    -- what lets the duration stay short over a long jump.
    local middle = Ease.expInOut(0.55) - Ease.expInOut(0.45)
    T.ok(middle > 0.3, ("the middle 10%% covers %.0f%% of the distance"):format(middle * 100))
  end)

  T.case("the expo names alias the ported ones", function()
    for _, pair in ipairs({ { "expoIn", "expIn" }, { "expoOut", "expOut" },
      { "expoInOut", "expInOut" } }) do
      T.eq(Ease[pair[1]], Ease[pair[2]], pair[1] .. " is " .. pair[2])
    end
    T.near(Ease.apply("expoInOut", 0.25), Ease.expInOut(0.25), 1e-9)
    T.near(Ease.apply("nonsense", 0.25), Ease.expInOut(0.25), 1e-9, "unknown falls back")
  end)

  T.section("map — how long the walk takes")

  local Map = require("src.scenes.map")

  T.case("duration has a floor, a ceiling, and rises sub-linearly", function()
    local short = Map.walk_duration(nil, 10)
    local medium = Map.walk_duration(nil, 260)
    local long = Map.walk_duration(nil, 2000)
    T.ok(short >= Map.WALK_MIN_S, "a step next door still takes a moment")
    T.ok(long <= Map.WALK_MAX_S + 1e-9, "and a jump across the map is capped")
    T.ok(medium > short)
    T.ok(long >= medium)
    -- Ten times the distance must not be ten times the wait.
    T.ok(Map.walk_duration(nil, 2600) < Map.walk_duration(nil, 260) * 2)
    T.eq(Map.walk_duration(nil, 0), Map.WALK_MIN_S)
    T.eq(Map.walk_duration(nil, -5), Map.WALK_MIN_S, "a negative distance is not a crash")
  end)

  T.case("the ceiling is short enough not to be a toll", function()
    -- Every node is reachable (§4.7), so node 1 -> node 24 is one press. If
    -- that took a second and a half nobody would use the map.
    T.ok(Map.WALK_MAX_S <= 1.0, "the longest walk is under a second")
    T.ok(Map.WALK_MIN_S >= 0.2, "and the shortest is still visible")
  end)

  T.section("map — the route follows the edges")

  --- A Map with nodes and edges but no window.
  local function fake_map(edges)
    local map = setmetatable({}, { __index = Map })
    map.nodes, map.by_id, map.edges = {}, {}, edges
    for i = 1, 6 do
      local id = "q" .. i
      map.nodes[i] = { quest_id = id, node = i, state = "open", x = i / 10, y = 0.5 }
      map.by_id[id] = i
    end
    return map
  end

  T.case("a walk follows the drawn path rather than cutting across", function()
    -- A chain 1-2-3-4-5-6 with a shortcut from 1 to 6 missing.
    local map = fake_map({ { "q1", "q2" }, { "q2", "q3" }, { "q3", "q4" },
      { "q4", "q5" }, { "q5", "q6" } })
    T.same(map:route(1, 4), { 1, 2, 3, 4 })
    T.same(map:route(4, 1), { 4, 3, 2, 1 })
    T.same(map:route(1, 1), { 1 })
    T.same(map:route(2, 3), { 2, 3 })
  end)

  T.case("it takes the short way when the map branches", function()
    -- 1-2-3-4 the long way, 1-4 directly.
    local map = fake_map({ { "q1", "q2" }, { "q2", "q3" }, { "q3", "q4" }, { "q1", "q4" } })
    T.same(map:route(1, 4), { 1, 4 })
  end)

  T.case("an unconnected node is a straight line, not a failure", function()
    -- With nothing locked a player may jump to a node the edges never reach.
    -- There is no path to show, so she goes directly — which is honest.
    local map = fake_map({ { "q1", "q2" } })
    T.same(map:route(1, 5), { 1, 5 })
    T.same(map:route(5, 1), { 5, 1 })
  end)

  T.case("no edges at all still answers", function()
    local map = fake_map({})
    T.same(map:route(1, 3), { 1, 3 })
  end)
end
