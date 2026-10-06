-- Switching land and category from the map itself.
--
-- Headless: the parts asserted here are the ones that decide *what* you land
-- on — the cycle order, that a land switch keeps the category, and that the
-- map you come back to remembers where you were. The drawing and the click
-- targets need a window and are exercised by `tests/drive/mapswitch.lua`.

local T = require("tests.framework")
local Map = require("src.scenes.map")
local Land = require("src.land")

--- A Map with just enough around it to switch, and a record of every
--- `world.map` the switch asked for.
---
--- `lands` is what the session kept from the last `world.lands` (ids), or nil
--- for a client that has not heard it yet.
local function fake_map(land, category, lands)
  local asked = {}
  local app = {
    land = land, category = category,
    toast = function() end,
    session = {
      lands = lands,
      request = function(_, type_name, payload)
        if type_name == "world.map" then
          asked[#asked + 1] = payload.land .. "." .. payload.category
        end
      end,
      on = function() return {} end,
      off_all = function() end,
    },
  }
  local map = setmetatable({}, { __index = Map })
  map.app = app
  map.land, map.category = land, category
  map.t = 0
  map.cursor = 1
  map.stamped = {}
  map.nodes, map.by_id, map.edges = {}, {}, {}
  for i = 1, 5 do
    local id = ("%s.%s.%02d.x"):format(land, category, i)
    map.nodes[i] = { quest_id = id, node = i, state = "open", x = 0.5, y = 0.5 }
    map.by_id[id] = i
  end
  return map, asked, app
end

return function()
  T.section("map — switching land and category in place")

  T.case("TAB switches land and KEEPS the category", function()
    -- The requirement, in one assertion: somebody comparing how Rust and Go
    -- do concurrency wants the concurrency map, not the top of GO BASIC.
    for _, category in ipairs({ "basic", "advanced", "hacker" }) do
      local map, asked, app = fake_map("rust", category)
      map:cycle_land()
      T.eq(map.land, "go")
      T.eq(map.category, category, "the category survived the land switch")
      T.same(asked, { "go." .. category }, "one world.map, for the right map")
      T.eq(app.land, "go", "the app followed")
      T.eq(app.category, category)
    end
  end)

  T.case("TAB walks rust → go → cpp → python → pytorch → typescript → zig → lua → remix and wraps", function()
    -- SPEC §0's order, the same one the land cards come in, so what TAB does
    -- on the map is what RIGHT does on the land screen.
    T.same(Land.ORDER,
      { "rust", "go", "cpp", "python", "pytorch", "typescript", "zig", "lua", "remix" })
    -- On BASIC, a road every land has; a road REMIX lacks is the next case.
    local map, asked, app = fake_map("rust", "basic")
    local seen = {}
    for _ = 1, #Land.ORDER do
      map:cycle_land()
      seen[#seen + 1] = map.land
      T.eq(map.category, "basic", "the category never moves")
      T.eq(app.land, map.land, "the app followed")
    end
    T.same(seen, { "go", "cpp", "python", "pytorch", "typescript", "zig", "lua", "remix", "rust" })
    T.same(asked,
      { "go.basic", "cpp.basic", "python.basic", "pytorch.basic", "typescript.basic",
        "zig.basic", "lua.basic", "remix.basic", "rust.basic" },
      "one world.map per step, each for the right map")
  end)

  T.case("TAB into a land without this road lands on the last road it has", function()
    -- LUA × HACKER, then TAB: REMIX has no hacker road, and the switch must
    -- not ask the server for a map it would answer not_found.
    local map, asked, app = fake_map("lua", "hacker")
    map:cycle_land()
    T.eq(map.land, "remix")
    T.eq(map.category, "basic")
    T.same(asked, { "remix.basic" })
    T.eq(app.category, "basic")
    -- And Q on REMIX walks only its two roads.
    map:cycle_category()
    T.eq(map.category, "verybasic")
    map:cycle_category()
    T.eq(map.category, "basic")
  end)

  T.case("TAB wraps back", function()
    local map = fake_map("remix", "advanced")
    map:cycle_land()
    T.eq(map.land, "rust")
    T.eq(map.category, "advanced")
  end)

  T.section("map — TAB walks the server's lands, not the client's")

  --- A `world.lands` reply (PROTOCOL §4.6) as the wire carries it, with the
  --- rows in no particular order, run through the real `Session:request` so
  --- the ids the map reads are the ones the session actually keeps.
  local function heard(ids)
    local Session = require("src.session").Session
    local rows = {}
    for i = #ids, 1, -1 do
      rows[#rows + 1] = { land = ids[i], categories = { { category = "basic", open = true } } }
    end
    local session = setmetatable({
      client = { request = function(_, _, _, cb) cb(true, { lands = rows }) end },
    }, { __index = Session })
    session:request("world.lands", {}, function() end)
    return session.lands
  end

  T.case("a server without ZIG and REMIX: TAB skips both and wraps", function()
    local lands = heard({ "rust", "go", "cpp", "python", "pytorch", "typescript", "lua" })
    local map, asked = fake_map("rust", "basic", lands)
    T.same(map:lands(), { "rust", "go", "cpp", "python", "pytorch", "typescript", "lua" },
      "the server's lands, in SPEC §0's order whatever order they came in")
    local seen = {}
    for _ = 1, 7 do
      map:cycle_land()
      seen[#seen + 1] = map.land
    end
    T.same(seen, { "go", "cpp", "python", "pytorch", "typescript", "lua", "rust" },
      "TYPESCRIPT → LUA, skipping ZIG; LUA → RUST, skipping REMIX")
    for _, key in ipairs(asked) do
      T.ok(not key:find("^zig%.") and not key:find("^remix%."),
        "no world.map for a land the server does not have: " .. key)
    end
    T.eq(#asked, 7, "one world.map per step")
  end)

  T.case("the kept rule still holds on the server's list: no road, the last road", function()
    -- LUA × HACKER, and the server has REMIX: TAB lands on REMIX BASIC.
    local map, asked = fake_map("lua", "hacker", heard({ "lua", "remix", "rust" }))
    map:cycle_land()
    T.eq(map.land, "remix")
    T.eq(map.category, "basic")
    map:cycle_land()
    T.eq(map.land, "rust", "and wraps to the first")
    T.eq(map.category, "basic", "the category REMIX left it on")
    T.same(asked, { "remix.basic", "rust.basic" })
  end)

  T.case("a land the server has and the client does not comes last", function()
    local map = fake_map("rust", "basic", heard({ "kotlin", "rust", "go" }))
    T.same(map:lands(), { "rust", "go", "kotlin" })
  end)

  T.case("standing on a land the server did not report, TAB goes to its first", function()
    local map = fake_map("zig", "basic", heard({ "rust", "go" }))
    map:cycle_land()
    T.eq(map.land, "rust")
  end)

  T.case("before world.lands is heard, TAB walks every land the client knows", function()
    local map = fake_map("rust", "basic", nil)
    T.same(map:lands(), Land.ORDER, "the fallback is Land.ORDER")
    map:cycle_land()
    T.eq(map.land, "go")
    local last = fake_map("remix", "basic", nil)
    last:cycle_land()
    T.eq(last.land, "rust", "and it wraps")
  end)

  T.case("the session forgets the lands when it is pointed at another server", function()
    local Session = require("src.session").Session
    local session = setmetatable({
      lands = { "rust" },
      store = { load_session = function() return nil end },
      fire = function() end,
    }, { __index = Session })
    session:rebind("ws://127.0.0.1:1/ws")
    T.eq(session.lands, nil, "another server's lands are not this one's")
  end)

  T.case("Q cycles the category in one action, wrapping", function()
    -- Five roads on RUST (SPEC §0, PROTOCOL §5.3): VERY BASIC walks first,
    -- FRAMEWORKS last.
    local map, asked = fake_map("rust", "basic")
    map:cycle_category()
    T.eq(map.category, "advanced")
    map:cycle_category()
    T.eq(map.category, "hacker")
    map:cycle_category()
    T.eq(map.category, "frameworks", "the crates road, after the interview")
    map:cycle_category()
    T.eq(map.category, "verybasic", "and round again, through the quiz road")
    map:cycle_category()
    T.eq(map.category, "basic")
    T.eq(map.land, "rust", "the land never moved")
    T.same(asked, { "rust.advanced", "rust.hacker", "rust.frameworks", "rust.verybasic", "rust.basic" })
  end)

  T.case("switching to the map you are already on does nothing", function()
    local map, asked = fake_map("rust", "basic")
    map:switch("rust", "basic")
    T.same(asked, {}, "no request, no flicker")
  end)

  T.section("map — a switch is a cut, not a walk")

  T.case("the walk state is dropped across a switch", function()
    -- Mei stands on a node of the map being left; on the next map she is
    -- somewhere else entirely. Animating between two overworlds is nonsense,
    -- and a walk left running would interpolate between nodes that no longer
    -- exist.
    local map = fake_map("rust", "basic")
    map.at = 3
    map.walk = { path = { 1, 2, 3 }, elapsed = 0.1, duration = 0.5 }
    map.adjacency = { [1] = { 2 } }
    map.stamped = { ["rust.basic.01.x"] = 0.2 }
    map:cycle_land()
    T.eq(map.walk, nil, "no walk survives a switch")
    T.eq(map.at, nil, "and she is not standing on a node of the old map")
    T.eq(map.adjacency, nil, "the old map's routes are gone")
    T.eq(map.nodes, nil, "the old nodes are gone — the screen says 'asking'")
    T.same(map.stamped, {}, "and no stamp animation bleeds across")
  end)

  T.section("map — nothing is lost by looking")

  T.case("each map remembers the node it was left on", function()
    Map.last_node = {}
    local map = fake_map("rust", "basic")
    map.cursor = 4
    map:cycle_land()
    T.eq(Map.last_node["rust.basic"], "rust.basic.04.x",
      "leaving rust/basic remembered node 4")
    -- And coming back restores it, which `refresh`'s reply handler does.
    T.eq(Map.last_node["go.basic"], nil, "a map never visited remembers nothing")
    Map.last_node = {}
  end)

  T.case("the remembered node is per land AND category", function()
    Map.last_node = {}
    local map = fake_map("rust", "basic")
    map.cursor = 2
    map:cycle_category()          -- leaves rust.basic on node 2
    map.nodes, map.by_id = {}, {}
    for i = 1, 5 do
      local id = ("rust.advanced.%02d.x"):format(i)
      map.nodes[i] = { quest_id = id, node = i, state = "open" }
      map.by_id[id] = i
    end
    map.cursor = 5
    map:cycle_land()              -- leaves rust.advanced on node 5
    T.eq(Map.last_node["rust.basic"], "rust.basic.02.x")
    T.eq(Map.last_node["rust.advanced"], "rust.advanced.05.x")
    Map.last_node = {}
  end)
end
