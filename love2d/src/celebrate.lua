-- The clear. Planned here, painted in `src/scenes/result.lua`.
--
-- The same plan as the browser's `frontend/src/engine/celebrate.ts`, number
-- for number, so a clear looks like the same clear in both clients:
--
--   1. a **flash** — the whole frame lit and let go on the expo curve;
--   2. **light trails** — comets that leave the centre on a spiral, each a
--      bright head with a tail of where it has just been;
--   3. the **XP** — the number zooming in from far too big and counting up,
--      and on a level-up the new level slammed in over it.
--
-- Everything is closed-form — position and alpha are functions of age, as
-- `src/fxplan.lua` does it — so it looks the same at 60 Hz and 144 Hz, and
-- every random choice comes from an injected `rng`. Nothing here draws.

local Ease = require("src.ease")
local Theme = require("src.theme")

local M = {}

local LIGHT = { Theme.coin, Theme.cream, Theme.cyan, Theme.pink, { 1, 0.95, 0.7, 1 } }

local function between(rng, a, b)
  return a + (b - a) * rng()
end

local function default_rng()
  if love and love.math and love.math.random then return love.math.random() end
  return math.random()
end

--- The plan. `n` comets around `(cx, cy)`, reaching out to about `reach`
--- pixels. Half set off at once and the rest trail out over a third of a
--- second, so the burst has a leading edge and a body.
function M.plan(cx, cy, reach, n, rng)
  rng = rng or default_rng
  local comets = {}
  for i = 0, n - 1 do
    local a0 = (i / n) * math.pi * 2 + between(rng, -0.25, 0.25)
    local dir = rng() < 0.5 and -1 or 1
    comets[#comets + 1] = {
      cx = cx, cy = cy,
      r0 = between(rng, reach * 0.04, reach * 0.12),
      r1 = between(rng, reach * 0.55, reach),
      a0 = a0,
      spin = dir * between(rng, 0.9, 2.2),
      life = between(rng, 0.9, 1.5),
      delay = (i % 2 == 0) and 0 or between(rng, 0.05, 0.32),
      color = LIGHT[(math.floor(rng() * #LIGHT) % #LIGHT) + 1],
      width = between(rng, 2, 4.5),
      seed = rng(),
    }
  end
  local rings = {
    { x = cx, y = cy, radius = reach * 0.9, life = 0.8, delay = 0, color = Theme.coin, glow = true },
    { x = cx, y = cy, radius = reach * 1.25, life = 1.05, delay = 0.12, color = Theme.cream, glow = false },
  }
  return { comets = comets, rings = rings, flash = 0.55 }
end

--- Where a comet's head is `age` seconds after its delay, and how bright.
--- Returns x, y, alpha.
function M.at(c, age)
  local u = Ease.clamp(age / c.life, 0, 1)
  local r = c.r0 + (c.r1 - c.r0) * Ease.expOut(u)
  local a = c.a0 + c.spin * Ease.expInOut(u)
  local alpha = (age < 0 or age > c.life) and 0 or (1 - u) ^ 1.6
  return c.cx + math.cos(a) * r, c.cy + math.sin(a) * r, alpha
end

--- The tail: `samples` points ending at the head, going back `span`
--- seconds, oldest first. Points before birth are pinned to the birth
--- position, so a comet that has just set off has no tail.
function M.trail(c, age, samples, span)
  samples = samples or 12
  span = span or 0.22
  local pts = {}
  for k = samples - 1, 0, -1 do
    local t = math.max(0, age - (span * k) / (samples - 1))
    local x, y = M.at(c, t)
    pts[#pts + 1] = { x, y }
  end
  return pts
end

--- Something arriving from far too big: 3.6× and invisible at u = 0, its own
--- size and solid at u = 1, on the expo-out curve. Returns scale, alpha.
function M.zoom_in(u)
  u = Ease.clamp(u, 0, 1)
  local k = Ease.expOut(u)
  return 1 + (1 - k) * 2.6, math.min(1, u * 3)
end

--- The same thing leaving: hangs, then swells and goes on the expo-in curve.
function M.zoom_out(u)
  u = Ease.clamp(u, 0, 1)
  local k = Ease.expIn(u)
  return 1 + k * 1.8, 1 - k
end

--- A number counting up from `from` to `to`: fast first, then the last few.
function M.count_up(from, to, u)
  local v = from + (to - from) * Ease.expOut(Ease.clamp(u, 0, 1))
  return math.floor(v + 0.5)
end

--- The flash: full at the clear, let go on the expo curve over `life`.
function M.flash_alpha(age, life)
  if age < 0 or age >= life then return 0 end
  return 0.85 * (1 - Ease.expOut(age / life))
end

return M
