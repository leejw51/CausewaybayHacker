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

  T.case("isPortrait follows the mode, not the window", function()
    at("portrait", 1600, 900)
    T.eq(Layout.isPortrait(), true)
    at("landscape", 400, 900)
    T.eq(Layout.isPortrait(), false)
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
      "quest", "result", "search", "stats", "ai",
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
    end
  end)

  Layout.mode = saved
end
