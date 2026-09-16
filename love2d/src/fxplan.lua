-- What one gesture in the editor throws into the air, as numbers.
--
-- The browser client's `engine/burst.ts` decides *which* particles a
-- keystroke, an ENTER, a deletion or a closed loop gets — how many, which
-- way, what colour, how big, for how long — and its GPU moves them. This is
-- the same set of decisions for the LÖVE client, in the same shape: a plan is
-- a list of particles and rings, a particle's position is a **closed-form
-- function of its age** (`M.at`), and nothing is integrated between frames,
-- so a burst looks the same at 60 Hz and at 144 Hz. `src/codefx.lua` draws
-- them; this file never names `love`, so `tests/test_fxplan.lua` can hold the
-- rules headlessly.
--
-- `cell` is `{ w, h }`, one character's box in pixels. It is the only size
-- these know: a bigger code face is a bigger explosion, and that is right.
--
-- Shapes, as `codefx.lua` draws them:
--   0 a soft glowing disc     1 a four-point star     2 a scrap of paper
--   4 a chunk of brick        5 a puff of dust         6 a pointer ember
--   7 a flat streak: the grain a caret jump drops
-- 4 and 5 are the Grok-drawn strips (`art/fx_bricks.png`, `art/fx_dust.png`)
-- when they have loaded and a plain square when they have not.

local Theme = require("src.theme")
local E = require("src.ease")

local M = {}

local DUST = { Theme.dim, Theme.cream, { 0.6, 0.55, 0.5, 1 }, { 0.45, 0.4, 0.38, 1 } }
local GOLD = { Theme.coin, Theme.cream, { 1, 0.95, 0.7, 1 } }
local SPARK = { Theme.coin, Theme.pink, Theme.cyan, Theme.cream, Theme.admit }
local PAPER = { Theme.coin, Theme.pink, Theme.cyan, Theme.cream, Theme.admit, Theme.brick }
--- The most cells one deletion breaks: past this, the rest went quietly.
M.RUBBLE_MAX = 400

local function between(rng, a, b)
  return a + (b - a) * rng()
end

local function pick(rng, list)
  return list[math.floor(rng() * #list) % #list + 1]
end

--- `col` a little lighter or darker: one brick is never quite its neighbour's.
local function shade(col, k)
  return { math.min(1, col[1] * k), math.min(1, col[2] * k), math.min(1, col[3] * k), col[4] or 1 }
end
M.shade = shade

--- A particle thrown from a point: no second leg, no arc.
local function thrown(x, y, dx, dy, rest)
  rest.x, rest.y, rest.dx, rest.dy = x, y, dx, dy
  rest.tox, rest.toy, rest.liftx, rest.lifty = 0, 0, 0, 0
  return rest
end

-- ------------------------------------------------------------ the motion

--- Where particle `p` is `age` seconds after its birth, and how far through
--- its life it is (`t`, 0..1). Nil when it is not alive at that age.
---
--- The throw eases out; the second leg, if there is one, eases in and out on
--- top of it; the lift bulges as sin(πt); gravity on top of everything.
function M.at(p, age)
  if age < 0 or age > p.life then
    return nil
  end
  local t = age / p.life
  local out = E.expOut(t)
  local leg = E.expInOut(t)
  local lift = math.sin(math.pi * t)
  local x = p.x + p.dx * out + p.tox * leg + p.liftx * lift
  local y = p.y + p.dy * out + p.toy * leg + p.lifty * lift + 0.5 * p.gravity * age * age
  return x, y, t
end

--- How visible a particle is at `t`: pops up over the first tenth of its
--- life, holds, then fades away.
function M.alpha(p, t)
  local grow = math.min(1, t / 0.1)
  local fade = 1 - math.max(0, (t - 0.55) / 0.45)
  return grow * fade
end

-- ---------------------------------------------------------------- the plans

--- Virtual pixels per second past which a core is as white as it gets.
M.SMEAR_HOT = 2400

--- What the pointer leaves behind as it crosses the code page: one ember on
--- the path, in the caret's colour.
---
--- Thin and short on purpose. The first version cycled through colours and
--- was a website's mouse trail pasted over an editor; this is a thread of the
--- same light the caret smears, and it says only "the pointer went this way".
--- The ember drifts a little *against* the motion (`vx, vy`, pixels a second)
--- so the thread lengthens with speed, and it goes whiter the faster the
--- pointer went.
function M.pointer(x, y, vx, vy, rng)
  rng = rng or math.random
  local speed = math.sqrt(vx * vx + vy * vy)
  local nx = speed > 1 and -vx / speed or 0
  local ny = speed > 1 and -vy / speed or 0
  local heat = math.min(1, speed / M.SMEAR_HOT)
  local drift = between(rng, 4, 9) * (0.6 + heat)
  local c = Theme.cyan
  return {
    particles = {
      thrown(x, y, nx * drift, ny * drift, {
        life = between(rng, 0.22, 0.3),
        delay = 0,
        size = 4 + 3 * heat,
        color = { c[1] + (1 - c[1]) * heat * 0.6, c[2] + (1 - c[2]) * heat * 0.6, c[3], 1 },
        shape = 6,
        trail = true,
        gravity = 0,
        seed = rng(),
      }),
    },
    rings = {},
  }
end

-- ------------------------------------------------------------- the caret

--- The caret moved: a smear.
---
--- The light trail follows the *caret* — the thing that actually moves when
--- code is written — the way a good terminal's does: the caret's rectangle
--- stretches from where it was to where it is and shrinks back, its width and
--- alpha dying together inside a fifth of a second, with a thin white core
--- down its middle that burns hotter the faster the caret went. One colour
--- plus white; the caret's own neon.
---
--- Along a line it is a horizontal beam. Across lines it bends: down the
--- column first and then along the new line, an L, with a wink of light at
--- the corner. A smear is `{ path, width, life, color, core }`: `path` is two
--- points for a straight run and three for a bend, `{ x, y }` each, through
--- the middle of the caret's cell; `width` its full width (the cell's
--- height); `core` 0..1, how white the middle burns. `from` and `to` are the
--- top-left of the caret's cell; `speed` is pixels a second.
function M.smear_for(from, to, cell, speed)
  local ch = cell[2]
  local mid = ch / 2
  local a = { from[1], from[2] + mid }
  local b = { to[1], to[2] + mid }
  local bend = math.abs(a[2] - b[2]) > ch * 0.5 and math.abs(a[1] - b[1]) > 0.5
  local path = bend and { a, { a[1], b[2] }, b } or { a, b }
  local dist = M.path_length(path)
  return {
    path = path,
    width = ch,
    -- A step lives a short life; a jump across the screen a little longer,
    -- so the tail has time to cross what the head crossed.
    life = math.min(0.22, 0.12 + dist / 4000),
    color = Theme.cyan,
    core = math.min(1, 0.35 + 0.65 * speed / M.SMEAR_HOT),
  }
end

--- The bend's wink: a small glow where the smear turns the corner. Nothing on
--- a straight run.
function M.corner(smear)
  if #smear.path < 3 then
    return { particles = {}, rings = {} }
  end
  local c = smear.path[2]
  return {
    particles = {},
    rings = {
      { x = c[1], y = c[2], radius = smear.width * 0.9, life = smear.life, delay = 0,
        color = smear.color, glow = true },
    },
  }
end

function M.path_length(path)
  local len = 0
  for i = 2, #path do
    local ax, ay = path[i - 1][1], path[i - 1][2]
    local bx, by = path[i][1], path[i][2]
    len = len + math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
  end
  return len
end

--- The point `u` (0..1) of the way along `path`, by distance: `x, y`.
function M.path_point(path, u)
  local total = M.path_length(path)
  local want = math.max(0, math.min(1, u)) * total
  for i = 2, #path do
    local ax, ay = path[i - 1][1], path[i - 1][2]
    local bx, by = path[i][1], path[i][2]
    local seg = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    if want <= seg or i == #path then
      local f = seg > 0 and math.min(1, want / seg) or 1
      return ax + (bx - ax) * f, ay + (by - ay) * f
    end
    want = want - seg
  end
  return path[1][1], path[1][2]
end

--- Whether a caret move is a *jump* — PageDown, a click on a far line —
--- rather than a step. A jump gets grains; a step never does, so an arrow key
--- held down is a beam and not a game.
function M.is_jump(from, to, cell)
  return math.abs(to[2] - from[2]) >= cell[2] * 2.5 or math.abs(to[1] - from[1]) >= cell[1] * 16
end

--- The grains a jump drops along its smear: a dozen or so flat streaks —
--- never taller than a fraction of the line — that appear in order along the
--- path, fall a little, and are gone in half a second. Shape 7 is that
--- streak. Rare on purpose: this is the moment the smear looks like it was
--- going too fast, not a thing that happens every keystroke.
function M.jump(smear, rng)
  rng = rng or math.random
  local ch = smear.width
  local dist = M.path_length(smear.path)
  local count = math.floor(math.min(20, 8 + dist / (ch * 4)) + 0.5)
  local particles = {}
  for i = 0, count - 1 do
    local u = (i + rng()) / count
    local x, y = M.path_point(smear.path, u)
    particles[#particles + 1] = thrown(x, y + (rng() - 0.5) * ch * 0.5, (rng() - 0.5) * ch,
      between(rng, 0.1, 0.4) * ch, {
        life = between(rng, 0.3, 0.5),
        delay = u * 0.08 + rng() * 0.03,
        size = between(rng, 0.45, 0.8) * ch,
        color = (i % 4 == 3) and Theme.cream or smear.color,
        shape = 7,
        trail = false,
        gravity = 260,
        seed = rng(),
      })
  end
  return { particles = particles, rings = {} }
end

--- One character typed: a few sparks off the caret, in the colour the
--- character is highlighted in, and a wink of light. `n` is how many arrived
--- at once — a paste is one bigger pop, not a pop per letter.
function M.key(x, y, cell, color, n, rng)
  rng = rng or math.random
  local cw, ch = cell[1], cell[2]
  local k = math.min(3, math.sqrt(n or 1))
  local particles = {}
  local count = math.floor(4 * k + 0.5)
  for i = 1, count do
    local ang = -math.pi / 2 + (rng() - 0.5) * math.pi * 1.1
    local reach = between(rng, 0.8, 2.2) * ch * k
    particles[#particles + 1] = thrown(x, y, math.cos(ang) * reach, math.sin(ang) * reach, {
      life = between(rng, 0.35, 0.65),
      delay = rng() * 0.03,
      size = between(rng, 0.25, 0.5) * ch,
      -- Two in three the token's colour, the third white-hot: a spark has a
      -- core. Counted rather than rolled, so one keystroke's four sparks
      -- are always mostly the colour of what was typed.
      color = (i % 3 == 0) and Theme.cream or color,
      shape = 0,
      trail = true,
      gravity = 260,
      seed = rng(),
    })
  end
  return {
    particles = particles,
    rings = {
      { x = x + cw / 2, y = y, radius = ch * 0.9 * k, life = 0.28, delay = 0, color = color, glow = true },
    },
  }
end

--- ENTER: dust. The caret lands on a new line and kicks up a puff along it,
--- soft grey-cream motes that drift up and thin out. `x, y` is the top-left
--- of the caret's cell.
function M.dust(x, y, cell, rng)
  rng = rng or math.random
  local cw, ch = cell[1], cell[2]
  local particles = {}
  for _ = 1, 9 do
    local side = rng() < 0.75 and 1 or -1
    particles[#particles + 1] = thrown(
      x + (rng() - 0.3) * cw,
      y + ch * 0.4,
      between(rng, 0.5, 9) * cw * side,
      -between(rng, 0.3, 1.4) * ch,
      {
        life = between(rng, 0.55, 1.0),
        delay = rng() * 0.08,
        size = between(rng, 0.6, 1.1) * ch,
        color = pick(rng, DUST),
        shape = 5,
        trail = false,
        gravity = -40,
        seed = rng(),
      }
    )
  end
  -- A few brighter grains in the cloud, so it catches the light.
  for _ = 1, 4 do
    particles[#particles + 1] =
      thrown(x, y + ch * 0.4, between(rng, 1, 6) * cw, -between(rng, 0.5, 1.5) * ch, {
        life = between(rng, 0.4, 0.7),
        delay = rng() * 0.05,
        size = between(rng, 0.15, 0.3) * ch,
        color = Theme.cream,
        shape = 0,
        trail = true,
        gravity = 120,
        seed = rng(),
      })
  end
  return {
    particles = particles,
    rings = {
      {
        x = x + cw,
        y = y + ch * 0.3,
        radius = ch * 1.6,
        life = 0.4,
        delay = 0,
        color = Theme.cream,
        glow = true,
      },
    },
  }
end

--- Deleted characters break like bricks — every one of them.
---
--- `cells` is one `{ x =, y =, color = }` per character that went, in that
--- character's own syntax colour, so a deleted line crumbles the way it was
--- written. Each throws its own chunks — right and down for preference, the
--- way rubble falls off a wall hit from the left — heavy, spinning, gone in
--- under a second, with a pinch of dust. The cells go in order, a few
--- milliseconds apart, so a line crumbles across rather than vanishing in
--- one flash. Past forty cells the chunks per cell drop from three to two,
--- and past `RUBBLE_MAX` the rest went quietly.
function M.rubble(cells, cell, rng)
  rng = rng or math.random
  local cw, ch = cell[1], cell[2]
  local particles, rings = {}, {}
  local n = math.min(#cells, M.RUBBLE_MAX)
  if n == 0 then
    return { particles = particles, rings = rings }
  end
  local per = n > 40 and 2 or 3
  local stagger = n > 40 and 0.004 or 0.012
  for i = 1, n do
    local c = cells[i]
    local at = (i - 1) * stagger
    for _ = 1, per do
      local ang = (rng() - 0.35) * math.pi - math.pi / 2
      local reach = between(rng, 1.2, 3.5) * ch
      particles[#particles + 1] =
        thrown(c.x + rng() * cw, c.y + rng() * ch, math.cos(ang) * reach + cw * 0.5, math.sin(ang) * reach, {
          life = between(rng, 0.55, 0.95),
          delay = at + rng() * 0.03,
          size = between(rng, 0.3, 0.55) * ch,
          color = shade(c.color, between(rng, 0.6, 1.15)),
          shape = 4,
          trail = false,
          gravity = 900,
          seed = rng(),
        })
    end
    if i % 2 == 1 then
      particles[#particles + 1] =
        thrown(c.x + rng() * cw, c.y + ch * 0.6, (rng() - 0.3) * 3 * cw, -between(rng, 0.2, 1) * ch, {
          life = between(rng, 0.4, 0.8),
          delay = at + rng() * 0.04,
          size = between(rng, 0.5, 0.9) * ch,
          color = pick(rng, DUST),
          shape = 5,
          trail = false,
          gravity = -20,
          seed = rng(),
        })
    end
  end
  local first, last = cells[1], cells[n]
  rings[1] = {
    x = (first.x + last.x + cw) / 2,
    y = (first.y + last.y + ch) / 2,
    radius = ch * (1.2 + math.min(3, math.sqrt(n) * 0.4)),
    life = 0.3,
    delay = 0,
    color = last.color,
    glow = true,
  }
  return { particles = particles, rings = rings }
end

--- The caret is beside a bracket and its partner lit up: a couple of sparks
--- run the line between them. `a` and `b` are `{ x, y }` centres.
function M.link(a, b, cell, rng)
  rng = rng or math.random
  local ch = cell[2]
  local ddx, ddy = b[1] - a[1], b[2] - a[2]
  local len = math.max(1, math.sqrt(ddx * ddx + ddy * ddy))
  local nx, ny = -ddy / len, ddx / len
  local particles = {}
  for i = 1, 3 do
    local lift = between(rng, 0.08, 0.2) * len * ((i % 2 == 1) and 1 or -1)
    particles[i] = {
      x = a[1],
      y = a[2],
      dx = 0,
      dy = 0,
      tox = ddx,
      toy = ddy,
      liftx = nx * lift,
      lifty = ny * lift,
      life = between(rng, 0.32, 0.45),
      delay = (i - 1) * 0.03,
      size = between(rng, 0.25, 0.45) * ch,
      color = Theme.cyan,
      shape = 0,
      trail = true,
      gravity = 0,
      seed = rng(),
    }
  end
  return {
    particles = particles,
    rings = {
      { x = a[1], y = a[2], radius = ch * 0.9, life = 0.3, delay = 0, color = Theme.cyan, glow = true },
      { x = b[1], y = b[2], radius = ch * 0.9, life = 0.3, delay = 0.3, color = Theme.cyan, glow = true },
    },
  }
end

--- The burst a right answer gets, `n` sparks strong: a shell of glowing
--- points thrown every way with trails, gold stars further out, paper thrown
--- up that takes its time to fall, and a flash with a shockwave. What
--- `sparks.lua` used to draw as squares, in the browser's proportions.
function M.burst(x, y, n, rng)
  rng = rng or math.random
  local k = math.max(0.6, math.min(2.2, n / 36))
  local particles, rings = {}, {}
  for _ = 1, n do
    local ang = rng() * math.pi * 2
    local reach = between(rng, 70, 230) * math.sqrt(k)
    particles[#particles + 1] = thrown(x, y, math.cos(ang) * reach, math.sin(ang) * reach - 40 * k, {
      life = between(rng, 1.1, 1.9),
      delay = rng() * 0.06,
      size = between(rng, 5, 12),
      color = pick(rng, SPARK),
      shape = 0,
      trail = true,
      gravity = 150,
      seed = rng(),
    })
  end
  for _ = 1, math.floor(n / 3 + 0.5) do
    local ang = rng() * math.pi * 2
    local reach = between(rng, 120, 300) * math.sqrt(k)
    particles[#particles + 1] = thrown(x, y, math.cos(ang) * reach, math.sin(ang) * reach - 60 * k, {
      life = between(rng, 1.4, 2.2),
      delay = rng() * 0.1,
      size = between(rng, 14, 26),
      color = pick(rng, GOLD),
      shape = 1,
      trail = true,
      gravity = 90,
      seed = rng(),
    })
  end
  for _ = 1, math.floor(n / 2 + 0.5) do
    local ang = -math.pi / 2 + (rng() - 0.5) * math.pi * 1.3
    local reach = between(rng, 90, 320) * math.sqrt(k)
    particles[#particles + 1] = thrown(x, y, math.cos(ang) * reach, math.sin(ang) * reach, {
      life = between(rng, 1.9, 2.9),
      delay = rng() * 0.12,
      size = between(rng, 9, 16),
      color = pick(rng, PAPER),
      shape = 2,
      trail = false,
      gravity = 220,
      seed = rng(),
    })
  end
  rings[#rings + 1] =
    { x = x, y = y, radius = 90 * math.sqrt(k), life = 0.5, delay = 0, color = Theme.cream, glow = true }
  rings[#rings + 1] =
    { x = x, y = y, radius = 150 * math.sqrt(k), life = 0.8, delay = 0, color = Theme.coin, glow = false }
  if k > 1.4 then
    rings[#rings + 1] = {
      x = x,
      y = y,
      radius = 210 * math.sqrt(k),
      life = 1.0,
      delay = 0.15,
      color = Theme.pink,
      glow = false,
    }
  end
  return { particles = particles, rings = rings }
end

--- A loop closed. Stars run a loop of their own round the block — from the
--- closing brace up to the keyword along one side and back down the other —
--- and where they meet, a burst. `open` and `close` are `{ x, y }` centres.
function M.loop(open, close, cell, rng)
  rng = rng or math.random
  local ch = cell[2]
  local particles, rings = {}, {}
  local ddx, ddy = open[1] - close[1], open[2] - close[2]
  local len = math.max(ch, math.sqrt(ddx * ddx + ddy * ddy))
  local nx, ny = -ddy / len, ddx / len
  -- Tall enough to read as a loop even on a one-line `loop {}`.
  local bulge = math.max(ch * 2.5, len * 0.35)
  local function leg(from, dx, dy, sign, at)
    for i = 0, 11 do
      particles[#particles + 1] = {
        x = from[1],
        y = from[2],
        dx = 0,
        dy = 0,
        tox = dx,
        toy = dy,
        liftx = nx * bulge * sign,
        lifty = ny * bulge * sign,
        life = 0.85,
        delay = at + i * 0.028,
        size = between(rng, 0.7, 1.1) * ch,
        color = pick(rng, GOLD),
        shape = 1,
        trail = true,
        gravity = 0,
        seed = rng(),
      }
    end
  end
  leg(close, ddx, ddy, 1, 0)
  leg(open, -ddx, -ddy, -1, 0.55)
  rings[#rings + 1] =
    { x = close[1], y = close[2], radius = ch * 2.2, life = 0.4, delay = 0, color = Theme.coin, glow = true }
  rings[#rings + 1] =
    { x = open[1], y = open[2], radius = ch * 2.2, life = 0.4, delay = 0.8, color = Theme.coin, glow = true }
  -- The finale, where the second leg lands: a right answer's burst, scaled
  -- to the type size rather than to a streak.
  local finale = M.burst(close[1], close[2], 28, rng)
  local scale = ch / 22
  for _, p in ipairs(finale.particles) do
    p.delay = p.delay + 1.35
    p.dx, p.dy = p.dx * scale, p.dy * scale
    p.size = p.size * math.max(0.6, scale)
    p.gravity = p.gravity * scale
    particles[#particles + 1] = p
  end
  for _, r in ipairs(finale.rings) do
    r.delay = r.delay + 1.35
    r.radius = r.radius * scale
    rings[#rings + 1] = r
  end
  return { particles = particles, rings = rings }
end

return M
