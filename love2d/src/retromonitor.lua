-- The monitor the code sits in, when the playground is an old computer
-- (`src/computer.lua`).
--
-- Ported from the browser client's `ui/monitor.ts`. The editor's well becomes
-- a piece of plastic: a casing in the machine's colour, bevelled light at the
-- top and dark at the bottom, a sloped bezel down to the glass, and a chin
-- with a nameplate, a power LED and whatever else that monitor had on its
-- front -- vents on the Amiga's 1084, the two knobs of the television an MSX
-- was plugged into. The tube itself, with its scanlines and rounded glass, is
-- `src/retroscreen.lua` over the editor.
--
-- Drawn in virtual pixels; returns the glass, which is where the editor goes.

local Computer = require("src.computer")
local Assets = require("src.assets")

local Monitor = {}

local function color(c, a)
  love.graphics.setColor(c[1], c[2], c[3], (a or 1) * (c[4] or 1))
end

local function rrect(x, y, w, h, r)
  love.graphics.rectangle("fill", x, y, w, h, r, r, 8)
end

local function disc(x, y, r)
  love.graphics.circle("fill", x, y, r, 24)
end

--- Draw the monitor filling `rect` and return the glass inside it.
---
--- `t` is the scene clock, for the LED; `busy` is whether a program is
--- running, which makes the power light flicker like a drive light.
function Monitor.draw(rect, machine, t, busy)
  local x, y, w, h = rect.x, rect.y, rect.w, rect.h
  local c = Computer.CASING[machine]
  if not c then return rect end
  local side, chin = Computer.frame(w, h)
  local r = math.floor(side * 0.9 + 0.5)

  -- A shadow on the desk under it.
  love.graphics.setColor(0, 0, 0, 0.45)
  rrect(x + 3, y + 5, w, h, r)
  -- The casing, bevelled: dark edge, light edge, then the body.
  color(c.dark)
  rrect(x, y, w, h, r)
  color(c.light)
  rrect(x, y, w - 2, h - 3, r)
  color(c.body)
  rrect(x + 2, y + 2, w - 4, h - 5, r - 1)

  -- The bezel sloping down to the glass: a frame of its own colour, lit
  -- along the bottom where it faces up into the light.
  local gx, gy = x + side, y + side
  local gw, gh = w - side * 2, h - side - chin
  local lip = math.max(3, math.floor(side * 0.45 + 0.5))
  color(c.light)
  rrect(gx - lip, gy - lip + 1, gw + lip * 2, gh + lip * 2, r)
  color(c.bezel)
  rrect(gx - lip, gy - lip, gw + lip * 2, gh + lip * 2 - 1, r)
  -- The glass, in the tube's own dark.
  local p = Computer.TUBE[machine].paper
  love.graphics.setColor(p[1] * 90 / 255, p[2] * 90 / 255, p[3] * 90 / 255, 1)
  rrect(gx, gy, gw, gh, math.floor(r * 0.8 + 0.5))

  -- The chin: the nameplate in the game's own pixel face, which is the
  -- browser's choice too (PressStart2P).
  local cy = y + h - chin
  local mid = cy + chin * 0.5
  local plate = math.max(6, math.floor(chin * 0.34 + 0.5))
  local font = Assets.font(plate)
  love.graphics.setFont(font)
  color(c.plate)
  love.graphics.print(Computer.NAME[machine], gx, math.floor(mid - font:getHeight() / 2 + 1))

  -- The power LED, steady; it flickers like a drive light while a run is on.
  local led_r = math.max(2, math.floor(chin * 0.12 + 0.5))
  local lx = x + w - side - led_r * 2
  local on = (not busy) or math.sin(t * 40) * math.sin(t * 13) > -0.2
  love.graphics.setColor(0, 0, 0, 0.5)
  disc(lx, mid, led_r + 1)
  if on then color(c.led) else love.graphics.setColor(0x30 / 255, 0x2a / 255, 0x20 / 255, 1) end
  disc(lx, mid, led_r)
  if on then
    color(c.led, 0.25)
    disc(lx, mid, led_r * 3)
  end

  if machine == "msx" then
    -- The television's two knobs, channel and volume.
    local kr = math.max(3, math.floor(chin * 0.26 + 0.5))
    for k = 0, 1 do
      local kx = lx - led_r * 4 - kr - k * (kr * 2.8)
      color(c.dark)
      disc(kx, mid + 1, kr)
      color(c.light)
      disc(kx, mid, kr - 1)
      color(c.dark)
      love.graphics.rectangle("fill", kx - 1, mid - kr + 1, 2, kr)
    end
  else
    -- Vents: a row of slots to the left of the light.
    local slot_w = math.max(2, math.floor(side * 0.25 + 0.5))
    local slot_h = math.floor(chin * 0.4 + 0.5)
    local n = machine == "amiga" and 10 or 6
    color(c.dark)
    for i = 0, n - 1 do
      local sx = lx - led_r * 4 - (i + 1) * slot_w * 2
      love.graphics.rectangle("fill", sx, mid - slot_h / 2, slot_w, slot_h)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
  return { x = gx, y = gy, w = gw, h = gh }
end

return Monitor
