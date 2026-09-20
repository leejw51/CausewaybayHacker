-- The clear celebration, checked without a window (`src/celebrate.lua`).
--
-- The same properties the browser pins in `frontend/tests/celebrate.test.ts`:
-- the plan is deterministic under a fixed rng, every streak stays inside its
-- reach, a head is bright at birth and gone at the end, a tail is where the
-- head *was* and never ahead of it, and the zoom and the count land exactly
-- on their targets.

local T = require("tests.framework")
local C = require("src.celebrate")

--- A tiny LCG, so two plans from the same seed are the same plan.
local function rng_from(seed)
  local s = seed % 4294967296
  return function()
    s = (s * 1664525 + 1013904223) % 4294967296
    return s / 4294967296
  end
end

local function dist(x, y, cx, cy)
  return math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2)
end

return function()
  T.section("celebrate — the plan")

  T.case("is the same plan for the same seed, and a different one for another", function()
    local a = C.plan(400, 300, 260, 24, rng_from(7))
    local b = C.plan(400, 300, 260, 24, rng_from(7))
    local c = C.plan(400, 300, 260, 24, rng_from(8))
    T.same(a, b)
    T.ne(a.comets[1].r1, c.comets[1].r1)
  end)

  T.case("makes as many comets as asked, spread round the whole circle", function()
    local plan = C.plan(0, 0, 200, 16, rng_from(1))
    T.eq(#plan.comets, 16)
    local quadrant = { false, false, false, false }
    for _, c in ipairs(plan.comets) do
      local a = c.a0 % (math.pi * 2)
      quadrant[math.floor(a / (math.pi / 2)) + 1] = true
    end
    for q = 1, 4 do T.ok(quadrant[q], "quadrant " .. q .. " has a comet") end
  end)

  T.case("keeps every streak inside its reach for its whole life", function()
    local reach = 240
    local plan = C.plan(500, 400, reach, 32, rng_from(3))
    for _, c in ipairs(plan.comets) do
      T.ok(c.life > 0, "a life")
      T.ok(c.delay >= 0, "no negative delay")
      for k = 0, 40 do
        local x, y = C.at(c, c.life * k / 40)
        T.ok(dist(x, y, 500, 400) <= reach + 1e-6, "inside the reach")
      end
    end
  end)

  T.case("sends half the comets off at once so the burst has a leading edge", function()
    local plan = C.plan(0, 0, 200, 20, rng_from(5))
    local now = 0
    for _, c in ipairs(plan.comets) do if c.delay == 0 then now = now + 1 end end
    T.eq(now, 10)
  end)

  T.case("carries two rings and a flash", function()
    local plan = C.plan(10, 20, 100, 4, rng_from(2))
    T.eq(#plan.rings, 2)
    for _, r in ipairs(plan.rings) do
      T.ok(r.x == 10 and r.y == 20 and r.life > 0, "a ring on the centre")
    end
    T.ok(plan.flash > 0, "a flash")
  end)

  T.section("celebrate — a comet's head")

  local c = C.plan(100, 100, 200, 1, rng_from(9)).comets[1]

  T.case("is bright at birth, gone at the end, and dark before it sets off", function()
    local _, _, a0 = C.at(c, 0)
    local _, _, a1 = C.at(c, c.life)
    local _, _, before = C.at(c, -0.01)
    local _, _, after = C.at(c, c.life + 0.01)
    T.eq(a0, 1)
    T.eq(a1, 0)
    T.eq(before, 0)
    T.eq(after, 0)
  end)

  T.case("starts at the inner radius and ends at the outer one", function()
    local x0, y0 = C.at(c, 0)
    local x1, y1 = C.at(c, c.life)
    T.near(dist(x0, y0, 100, 100), c.r0, 1e-6)
    T.near(dist(x1, y1, 100, 100), c.r1, 1e-6)
  end)

  T.case("only ever moves outward, and does most of it in the first third", function()
    local last = -1
    for k = 0, 50 do
      local x, y = C.at(c, c.life * k / 50)
      local r = dist(x, y, 100, 100)
      T.ok(r >= last - 1e-9, "outward")
      last = r
    end
    local x, y = C.at(c, c.life / 3)
    local third = (dist(x, y, 100, 100) - c.r0) / (c.r1 - c.r0)
    T.ok(third > 0.85, "the expo shape: " .. third)
  end)

  T.section("celebrate — a comet's tail")

  local d = C.plan(0, 0, 300, 1, rng_from(11)).comets[1]

  T.case("ends at the head and reads oldest-first", function()
    local pts = C.trail(d, 0.5, 8, 0.2)
    T.eq(#pts, 8)
    local hx, hy = C.at(d, 0.5)
    T.near(pts[8][1], hx, 1e-9)
    T.near(pts[8][2], hy, 1e-9)
    local last = math.huge
    for i = #pts, 1, -1 do
      local r = dist(pts[i][1], pts[i][2], 0, 0)
      T.ok(r <= last + 1e-9, "no further out than the head")
      last = r
    end
  end)

  T.case("has no length at birth rather than reaching back to nowhere", function()
    local pts = C.trail(d, 0, 6, 0.2)
    for _, p in ipairs(pts) do
      T.near(p[1], pts[6][1], 1e-9)
      T.near(p[2], pts[6][2], 1e-9)
    end
  end)

  T.section("celebrate — zoom, count and flash")

  T.case("zoom_in arrives from far too big and lands exactly at its own size", function()
    local s0, a0 = C.zoom_in(0)
    local s1, a1 = C.zoom_in(1)
    local s3 = C.zoom_in(1 / 3)
    T.ok(s0 > 3, "far too big")
    T.eq(a0, 0)
    T.eq(s1, 1)
    T.eq(a1, 1)
    T.ok(s3 < 1.4, "most of the shrink is over by a third")
  end)

  T.case("zoom_out hangs, then swells and goes", function()
    local s0, a0 = C.zoom_out(0)
    local s5 = C.zoom_out(0.5)
    local _, a1 = C.zoom_out(1)
    T.eq(s0, 1)
    T.eq(a0, 1)
    T.ok(s5 < 1.15, "still hanging at the half")
    T.eq(a1, 0)
  end)

  T.case("count_up lands on the exact number and never overshoots", function()
    T.eq(C.count_up(0, 150, 0), 0)
    T.eq(C.count_up(0, 150, 1), 150)
    T.eq(C.count_up(100, 250, 1), 250)
    local last = -1
    for k = 0, 100 do
      local v = C.count_up(0, 150, k / 100)
      T.ok(v >= last and v <= 150, "monotonic and capped")
      last = v
    end
  end)

  T.case("flash_alpha is brightest at the clear and gone by the end", function()
    T.ok(C.flash_alpha(0, 0.5) > 0.8, "bright")
    T.ok(C.flash_alpha(0.25, 0.5) < C.flash_alpha(0, 0.5), "letting go")
    T.eq(C.flash_alpha(0.5, 0.5), 0)
    T.eq(C.flash_alpha(-1, 0.5), 0)
  end)
end
