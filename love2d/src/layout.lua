-- The virtual canvas.
--
-- **Ported from `CausewaybayGolang/love2d/src/layout.lua`**, which is itself
-- the Lua half of `CausewaybayGolang/typescript/src/engine/layout.ts`. SPEC
-- §10 says to take it as it stands, and this does: the authored sizes, the
-- integer scale above 2×, the `MAX_STRETCH = 1.5` growth along the long axis
-- instead of letterboxing, and `uiScale()` are unchanged arithmetic.
--
-- What is different from the original:
--
--   * the sibling's `Persist`, `I18n` and `SFX` dependencies are gone. This
--     game has one language on screen and its settings live on the server
--     (PROTOCOL §4.5's `settings`), so the save/load hooks are *injected*
--     (`Layout.storage`) rather than reached for. That also lets the layout
--     tests run without a save directory.
--   * `Layout.init` takes a preferred mode, so a `settings.orientation` that
--     came back from `auth.resume` wins over the display shape.
--
-- The requirement this file exists to satisfy: **both orientations are
-- first-class on every screen** (SPEC §10), not just the map. Every scene
-- draws into `Layout.vw × Layout.vh` and asks `Layout.isPortrait()`; nothing
-- hard-codes 1280 or 720.

local Theme = require("src.theme")

local Layout = {
  mode = "landscape",
  fullscreen = false,
  pendingWindow = false,
  vw = Theme.landW,
  vh = Theme.landH,
  scale = 1,
  ox = 0,
  oy = 0,
  canvas = nil,
  -- { save = function(record), load = function() -> record }
  storage = nil,
  on_change = nil,
}

-- Extra virtual pixels allowed past the design size so fullscreen does not
-- sit in a tiny letterbox.
local MAX_STRETCH = 1.5

local function highdpi()
  return true
end

--- Vsync, as `conf.lua` chose it.
---
--- `applyWindow` re-creates the window on every orientation and fullscreen
--- change, and a hard-coded `vsync = 1` here would put it back on halfway
--- through a drive script — which is exactly the stall `conf.lua` turns it
--- off to avoid.
local function vsync()
  if os.getenv("CWBH_TEST") == "1" then return 0 end
  if (os.getenv("CWBH_DRIVE") or "") ~= "" then return 0 end
  return 1
end

local function windowedFlags()
  return {
    fullscreen = false,
    fullscreentype = "desktop",
    resizable = true,
    vsync = vsync(),
    msaa = 0,
    minwidth = 640,
    minheight = 400,
    centered = true,
    highdpi = highdpi(),
  }
end

local function fitWindow(wantW, wantH)
  local dw, dh = love.window.getDesktopDimensions()
  local maxW = math.max(640, dw - 80)
  local maxH = math.max(400, dh - 100)
  local w, h = wantW, wantH
  local s = math.min(1, maxW / w, maxH / h)
  w = math.max(560, math.floor(w * s))
  h = math.max(400, math.floor(h * s))
  return w, h
end

function Layout.applyWindow()
  if love.graphics.getCanvas() then
    love.graphics.setCanvas()
  end
  if Layout.fullscreen then
    local dw, dh = love.window.getDesktopDimensions()
    local _, _, cur = love.window.getMode()
    if not (cur.fullscreen and cur.fullscreentype == "desktop") then
      love.window.setMode(dw, dh, {
        fullscreen = true,
        fullscreentype = "desktop",
        vsync = vsync(),
        msaa = 0,
        highdpi = highdpi(),
        resizable = false,
      })
    end
  else
    local w, h
    if Layout.mode == "portrait" then
      w, h = fitWindow(Theme.portW, Theme.portH)
    else
      w, h = fitWindow(Theme.landW, Theme.landH)
    end
    local cw, ch, cur = love.window.getMode()
    if cur.fullscreen or math.abs(cw - w) > 8 or math.abs(ch - h) > 8 then
      love.window.setMode(w, h, windowedFlags())
    end
  end
  Layout.updateViewport()
end

--- Window changes are deferred to the top of the next frame: `love.window
--- .setMode` while a canvas is bound throws the canvas away mid-draw.
function Layout.flush()
  if not Layout.pendingWindow then return end
  Layout.pendingWindow = false
  Layout.applyWindow()
end

function Layout.save()
  if Layout.storage and Layout.storage.save then
    Layout.storage.save({ mode = Layout.mode, fullscreen = Layout.fullscreen })
  end
end

function Layout.load()
  if not (Layout.storage and Layout.storage.load) then return false end
  local rec = Layout.storage.load()
  if type(rec) ~= "table" then return false end
  local applied = false
  if rec.mode == "portrait" or rec.mode == "landscape" then
    Layout.mode = rec.mode
    applied = true
  end
  if type(rec.fullscreen) == "boolean" then
    Layout.fullscreen = rec.fullscreen
    applied = true
  end
  return applied
end

function Layout.toggleFullscreen()
  Layout.fullscreen = not Layout.fullscreen
  Layout.pendingWindow = true
  Layout.save()
end

function Layout.toggleOrientation()
  Layout.setOrientation(Layout.mode == "landscape" and "portrait" or "landscape")
end

function Layout.setOrientation(mode)
  if mode ~= "portrait" and mode ~= "landscape" then return end
  if Layout.mode == mode then return end
  Layout.mode = mode
  Layout.pendingWindow = true
  Layout.save()
  if Layout.on_change then Layout.on_change(mode) end
end

local function baseSize()
  if Layout.mode == "portrait" then
    return Theme.portW, Theme.portH
  end
  return Theme.landW, Theme.landH
end

Layout.baseSize = baseSize

function Layout.ensureCanvas()
  local w, h = math.max(1, math.floor(Layout.vw)), math.max(1, math.floor(Layout.vh))
  if Layout.canvas and Layout.canvas:getWidth() == w and Layout.canvas:getHeight() == h then
    return
  end
  if Layout.canvas then
    Layout.canvas:release()
  end
  Layout.canvas = love.graphics.newCanvas(w, h)
  Layout.canvas:setFilter("nearest", "nearest")
end

function Layout.updateViewport()
  local ww, wh = love.graphics.getDimensions()
  if ww < 1 then ww = Theme.landW end
  if wh < 1 then wh = Theme.landH end
  local bw, bh = baseSize()
  local s = math.min(ww / bw, wh / bh)
  if s >= 2 then
    Layout.scale = math.floor(s)
  else
    -- Fill the window: grow the virtual canvas along the longer axis instead
    -- of letterboxing (a landscape layout on a portrait screen, a tall
    -- window). Fonts stay at design size below 1×.
    Layout.scale = s >= 1 and 1 or math.max(0.35, s)
  end
  Layout.vw = math.min(math.floor(ww / Layout.scale), math.floor(bw * MAX_STRETCH))
  Layout.vh = math.min(math.floor(wh / Layout.scale), math.floor(bh * MAX_STRETCH))
  Layout.ox = math.floor((ww - Layout.vw * Layout.scale) / 2)
  Layout.oy = math.floor((wh - Layout.vh * Layout.scale) / 2)
  Layout.ensureCanvas()
end

--- Fonts are authored for the 1280×720 / 720×1280 design. When the virtual
--- canvas grows (windowed stretch, tall fullscreen), scale type with it.
function Layout.uiScale()
  local bw, bh = baseSize()
  return math.max(1, math.min(Layout.vw / bw, Layout.vh / bh))
end

function Layout.init(preferred)
  local dw, dh = love.window.getDesktopDimensions()
  -- First run on a portrait display: start in portrait. A saved record, and
  -- then an explicit preference, override it.
  if dh > dw then Layout.mode = "portrait" end
  Layout.load()
  if preferred == "portrait" or preferred == "landscape" then
    Layout.mode = preferred
  end
  Layout.updateViewport()
  Layout.applyWindow()
end

function Layout.begin()
  Layout.updateViewport()
  love.graphics.setCanvas(Layout.canvas)
  love.graphics.clear(Theme.void)
end

function Layout.finish()
  love.graphics.setCanvas()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.clear(0, 0, 0, 1)
  local dw = Layout.vw * Layout.scale
  local dh = Layout.vh * Layout.scale
  love.graphics.draw(Layout.canvas, Layout.ox, Layout.oy, 0, Layout.scale, Layout.scale)
  love.graphics.setColor(Theme.coin[1], Theme.coin[2], Theme.coin[3], 0.45)
  love.graphics.setLineWidth(1)
  love.graphics.rectangle("line", Layout.ox - 1, Layout.oy - 1, dw + 2, dh + 2)
  love.graphics.setColor(1, 1, 1, 1)
end

function Layout.toVirtual(sx, sy)
  local vx = (sx - Layout.ox) / Layout.scale
  local vy = (sy - Layout.oy) / Layout.scale
  if vx < 0 or vy < 0 or vx >= Layout.vw or vy >= Layout.vh then
    return nil, nil
  end
  return vx, vy
end

function Layout.hit(x, y, w, h)
  local vx, vy = Layout.toVirtual(love.mouse.getPosition())
  if not vx then return false end
  return vx >= x and vy >= y and vx < x + w and vy < y + h
end

function Layout.isPortrait()
  return Layout.mode == "portrait"
end

--- A padded rectangle covering the whole virtual canvas — the one every
--- scene builds its layout from, so nothing has to know which orientation it
--- is in to place a panel.
function Layout.safe(pad)
  pad = pad or 16
  return pad, pad, Layout.vw - pad * 2, Layout.vh - pad * 2
end

return Layout
