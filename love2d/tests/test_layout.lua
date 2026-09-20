-- The virtual canvas, under a real LÖVE graphics context.
--
-- SPEC §10's requirement is "both orientations are first-class on **every**
-- screen", and the arithmetic that delivers it is `Layout.updateViewport`:
-- grow along the long axis up to 1.5×, do not letterbox, keep an integer
-- scale once there is room for one. This asserts that arithmetic at the
-- window sizes the two orientations actually meet.
--
-- Skipped in the headless run, by name, because it needs `love.graphics`.

local T = require("tests.framework")
local Layout = require("src.layout")
local Theme = require("src.theme")

--- Drive `updateViewport` at a window size without opening that window.
local function at(mode, ww, wh)
  Layout.mode = mode
  local real = love.graphics.getDimensions
  love.graphics.getDimensions = function() return ww, wh end
  Layout.updateViewport()
  love.graphics.getDimensions = real
  return {
    vw = Layout.vw, vh = Layout.vh, scale = Layout.scale,
    ox = Layout.ox, oy = Layout.oy, ui = Layout.uiScale(),
  }
end

return function()
  T.section("layout — the virtual canvas (SPEC §10)")

  local saved = Layout.mode

  T.case("the design sizes are the sibling's", function()
    T.eq(Theme.landW, 1280)
    T.eq(Theme.landH, 720)
    T.eq(Theme.portW, 720)
    T.eq(Theme.portH, 1280)
  end)

  T.case("at the design size the canvas is exactly the design", function()
    local r = at("landscape", 1280, 720)
    T.eq(r.scale, 1)
    T.eq(r.vw, 1280)
    T.eq(r.vh, 720)
    T.eq(r.ox, 0)
    T.eq(r.oy, 0)

    local p = at("portrait", 720, 1280)
    T.eq(p.scale, 1)
    T.eq(p.vw, 720)
    T.eq(p.vh, 1280)
  end)

  T.case("the canvas grows along the long axis rather than letterboxing", function()
    -- A landscape layout in a very wide window: the canvas gets wider, it
    -- does not get black bars.
    local r = at("landscape", 2560, 720)
    T.eq(r.vh, 720)
    T.ok(r.vw > 1280, "the virtual width grew")
    T.eq(r.oy, 0, "no vertical letterbox")
    T.ok(r.vw <= 1280 * 1.5 + 1, "growth is capped at 1.5x (MAX_STRETCH)")

    -- A portrait layout in a very tall window.
    local p = at("portrait", 720, 2400)
    T.eq(p.vw, 720)
    T.ok(p.vh > 1280)
    T.ok(p.vh <= 1280 * 1.5 + 1)
  end)

  T.case("a landscape layout survives a portrait window", function()
    -- The case SPEC §10 is really about: the window is the wrong shape for
    -- the authored layout, and the screen still has to work.
    local r = at("landscape", 800, 1400)
    T.ok(r.vw > 0 and r.vh > 0)
    T.ok(r.scale > 0)
    -- The canvas covers the window in at least one axis, so there is no
    -- double letterbox.
    T.ok(math.abs(r.vw * r.scale - 800) < 2 or math.abs(r.vh * r.scale - 1400) < 2)
    T.ok(r.ox >= 0 and r.oy >= 0)
  end)

  T.case("scale becomes an integer once there is room for one", function()
    local r = at("landscape", 2560, 1440)
    T.eq(r.scale, 2, "exactly 2x fits")
    T.eq(r.vw, 1280)
    T.eq(r.vh, 720)
    local r3 = at("landscape", 3840, 2160)
    T.eq(r3.scale, 3)
  end)

  T.case("a tiny window scales down rather than clipping", function()
    local r = at("landscape", 640, 360)
    T.ok(r.scale < 1)
    T.ok(r.scale >= 0.35, "clamped at 0.35, the floor in the ported arithmetic")
    T.ok(r.vw >= 1280, "the virtual canvas is at least the design width")
  end)

  T.case("uiScale is 1 at the design size and grows with the canvas", function()
    at("landscape", 1280, 720)
    T.near(Layout.uiScale(), 1, 0.001)
    at("landscape", 2560, 720)
    T.near(Layout.uiScale(), 1, 0.001, "a wider canvas does not enlarge type")
    local tall = at("portrait", 900, 1600)
    T.ok(tall.ui >= 1)
  end)

  T.case("screen coordinates map back to virtual ones", function()
    at("landscape", 2560, 1440)
    local vx, vy = Layout.toVirtual(Layout.ox, Layout.oy)
    T.near(vx, 0, 0.001)
    T.near(vy, 0, 0.001)
    local cx, cy = Layout.toVirtual(Layout.ox + 640, Layout.oy + 360)
    T.near(cx, 320, 0.001)
    T.near(cy, 180, 0.001)
    T.eq(Layout.toVirtual(-50, -50), nil, "outside the canvas is nil, not a negative")
  end)

  T.case("safe() gives a padded rect in either orientation", function()
    at("landscape", 1280, 720)
    local x, y, w, h = Layout.safe(16)
    T.eq(x, 16); T.eq(y, 16); T.eq(w, 1280 - 32); T.eq(h, 720 - 32)
    at("portrait", 720, 1280)
    local _, _, pw, ph = Layout.safe(16)
    T.eq(pw, 720 - 32); T.eq(ph, 1280 - 32)
  end)

  T.case("a pinned orientation ignores the window's shape", function()
    Layout.pinned = true
    at("portrait", 1600, 900)
    T.eq(Layout.isPortrait(), true, "a pinned portrait survives a wide window")
    T.eq(Layout.mode, "portrait")
    at("landscape", 400, 900)
    T.eq(Layout.isPortrait(), false, "and a pinned landscape survives a tall one")
    T.eq(Layout.mode, "landscape")
  end)

  T.section("layout — pinned vs inferred orientation")

  T.case("orientationFor is the rule, and it has a dead zone", function()
    T.eq(Layout.orientationFor(1280, 720), "landscape")
    T.eq(Layout.orientationFor(720, 1280), "portrait")
    T.eq(Layout.orientationFor(2560, 1440), "landscape")
    T.eq(Layout.orientationFor(1080, 1920), "portrait")
    -- Square-ish stays landscape: the authored layout is 1280x720 and a slow
    -- drag of a window border must not thrash the whole UI at 1.01:1.
    T.eq(Layout.orientationFor(900, 900), "landscape")
    T.eq(Layout.orientationFor(900, 940), "landscape")
    T.eq(Layout.orientationFor(900, 950), "portrait", "5% past square flips")
    T.eq(Layout.orientationFor(0, 0), "landscape", "a degenerate size is not a crash")
    T.eq(Layout.orientationFor(nil, nil), "landscape")
  end)

  T.case("an unpinned orientation follows the window, including into fullscreen", function()
    Layout.pinned = false
    Layout.mode = "landscape"
    at("landscape", 1280, 720)
    T.eq(Layout.mode, "landscape")
    -- The player drags the window tall, or goes fullscreen on a rotated
    -- monitor. Nothing was pinned, so the layout follows.
    at(Layout.mode, 900, 1600)
    T.eq(Layout.mode, "portrait", "a tall window re-derives portrait")
    T.eq(Layout.isPortrait(), true)
    at(Layout.mode, 2560, 1440)
    T.eq(Layout.mode, "landscape", "and back again")
  end)

  T.case("the fullscreen transition re-measures rather than keeping a stale canvas", function()
    Layout.pinned = false
    local windowed = at("landscape", 1280, 720)
    T.eq(windowed.vw, 1280)
    T.eq(windowed.vh, 720)
    -- A 16:10 display, entering desktop fullscreen.
    local full = at(Layout.mode, 1920, 1200)
    T.eq(Layout.mode, "landscape")
    T.ok(full.vw ~= windowed.vw or full.vh ~= windowed.vh, "the canvas was re-measured")
    T.ok(full.vh >= 720)
    T.ok(math.abs(full.vw * full.scale - 1920) < 2 or math.abs(full.vh * full.scale - 1200) < 2,
      "fullscreen fills at least one axis — no double letterbox")
    -- A portrait display, entering fullscreen, unpinned: portrait wins.
    at(Layout.mode, 1200, 1920)
    T.eq(Layout.mode, "portrait")
  end)

  T.case("a pin made in a window survives the fullscreen transition", function()
    -- The case worth being sure about: the player pressed F1 for portrait in
    -- a windowed session and then hit F11 on a landscape display. The pin is
    -- theirs and the display does not get to overrule it.
    Layout.pinned = false
    at("landscape", 1280, 720)
    Layout.setOrientation("portrait", true)
    T.eq(Layout.pinned, true)
    at(Layout.mode, 2560, 1440)
    T.eq(Layout.mode, "portrait", "the pin survived fullscreen on a wide display")
    T.ok(Layout.vw < Layout.vh, "and the canvas is still taller than it is wide")
  end)

  T.case("the fullscreen type is desktop unless somebody asks otherwise", function()
    local saved = Layout.fullscreenPref
    Layout.fullscreenPref = nil
    T.eq(Layout.fullscreenType(), "desktop",
      "exclusive changes the display mode and is not a default")
    Layout.fullscreenPref = "exclusive"
    T.eq(Layout.fullscreenType(), "exclusive")
    Layout.fullscreenPref = "EXCLUSIVE"
    T.eq(Layout.fullscreenType(), "exclusive", "case does not matter")
    Layout.fullscreenPref = "nonsense"
    T.eq(Layout.fullscreenType(), "desktop", "an unknown value falls back rather than failing")
    Layout.fullscreenPref = saved
  end)

  T.section("scenes — every screen constructs in both orientations")

  T.case("every scene can be built and drawn at both design sizes", function()
    -- Not a screenshot test: it catches the thing that actually breaks when a
    -- scene is written in one orientation and never opened in the other — a
    -- nil arithmetic or a missing asset on the portrait path.
    local App = require("src.app")
    local app = App.new()
    -- A session that answers nothing: every scene has to render its "asking
    -- the server…" state, which is the state a player sees for the first
    -- frame of every screen.
    app.session = {
      authed = false,
      request = function() return nil end,
      on = function() return {} end,
      off = function() end,
      off_all = function() end,
      login = function(_, _, _, _, cb) if cb then cb(false, "no server") end end,
      display_name = function() return "tester" end,
      short_address = function() return "0x0000…0000" end,
      remembered = nil,
      last_error = nil,
    }
    app.client = { state = "open", url = "ws://127.0.0.1:5390/ws" }
    app.wallet_lib = nil
    app.wallet_error = "not built (this is the test's point)"

    local names = {
      "boot", "login", "lands", "categories", "map",
      "quest", "result", "search", "stats", "ai", "playground",
    }
    for _, mode in ipairs({ "landscape", "portrait" }) do
      at(mode, mode == "portrait" and 720 or 1280, mode == "portrait" and 1280 or 720)
      for _, name in ipairs(names) do
        local ok, err = pcall(function()
          app:go(name, { land = "rust", category = "basic", quest_id = "rust.basic.01.x" })
          love.graphics.setCanvas(Layout.canvas)
          app:draw()
          love.graphics.setCanvas()
        end)
        T.ok(ok, ("%s in %s: %s"):format(name, mode, tostring(err)))
        if not ok then love.graphics.setCanvas() end
      end

      -- The map with something on it: the scenes above draw their empty
      -- state, and the branches that only exist once `world.map` has
      -- answered — the hand over a node not yet cleared, the road's tally on
      -- the card and its bar — would never run. A nil in either is a crash
      -- on the one screen a player looks at most.
      local ok, err = pcall(function()
        app:go("map", { land = "rust", category = "basic" })
        local scene = app.scene
        scene.nodes = {
          { quest_id = "a", node = 1, title = "FIRST LIGHT", state = "cleared",
            stars = 3, practised = 2, difficulty = 1, attempts = 4, x = 0.2, y = 0.3,
            kind = "quest", requires = {} },
          { quest_id = "b", node = 2, title = "THE FARE BOARD", state = "open",
            stars = 0, difficulty = 2, attempts = 0, x = 0.6, y = 0.7,
            kind = "quest", requires = { "a" } },
        }
        scene.by_id = { a = 1, b = 2 }
        scene.edges = { { "a", "b" } }
        scene.tally = { cleared = 1, total = 2, stars = 3, stars_total = 6 }
        for _, at_node in ipairs({ 1, 2 }) do
          scene.cursor = at_node
          love.graphics.setCanvas(Layout.canvas)
          app:draw()
          love.graphics.setCanvas()
        end
      end)
      T.ok(ok, ("map with nodes in %s: %s"):format(mode, tostring(err)))
      if not ok then love.graphics.setCanvas() end
    end
  end)

  Layout.mode = saved
end
