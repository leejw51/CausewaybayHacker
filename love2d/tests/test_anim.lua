-- The motion vocabulary, asserted without a window.
--
-- This file is why `src/anim.lua` is pure. "No effect may require a window to
-- test" is a real constraint and it is met by making every effect a function
-- of time rather than a thing that happens to a canvas.

local T = require("tests.framework")
local Anim = require("src.anim")

return function()
  T.section("anim — the clock, and freezing it")

  T.case("the clock is injectable and freezable", function()
    local t = 100
    Anim.set_clock(function() return t end)
    T.eq(Anim.now(), 100)
    t = 105
    T.eq(Anim.now(), 105)
    -- A drive script pins it so a screenshot of a bobbing mascot is the same
    -- screenshot every run.
    Anim.freeze(7)
    T.eq(Anim.now(), 7)
    t = 999
    T.eq(Anim.now(), 7, "frozen means frozen")
    T.eq(Anim.frozen(), 7)
    Anim.freeze(nil)
    T.eq(Anim.now(), 999)
    T.eq(Anim.frozen(), nil)
    Anim.set_clock(nil)
  end)

  T.section("anim — idling")

  T.case("a bob is a closed loop with no jump at the seam", function()
    local opts = { period = 1.6, amount = 3 }
    T.near(Anim.bob(0, opts), 0, 1e-9)
    T.near(Anim.bob(1.6, opts), 0, 1e-9, "one period later it is back")
    -- Highest at the half period.
    T.near(Anim.bob(0.8, opts), -3, 1e-9)
    -- And continuous across the seam: a sawtooth here would read as a glitch.
    T.ok(math.abs(Anim.bob(1.599, opts) - Anim.bob(1.601, opts)) < 0.05)
    -- Always within the amplitude, never below zero (sprites rise, not sink).
    for i = 0, 200 do
      local v = Anim.bob(i / 50, opts)
      T.ok(v <= 1e-9 and v >= -3 - 1e-9, "bob stays in range at " .. tostring(i))
    end
  end)

  T.case("phase keeps a row of sprites out of lockstep", function()
    local a = Anim.bob(0.3, { phase = 0 })
    local b = Anim.bob(0.3, { phase = 0.5 })
    T.ne(a, b, "two mascots on one screen must not pulse together")
  end)

  T.case("a blink is mostly open, briefly shut, and never sticks", function()
    local opts = { period = 4.0, shut = 0.12 }
    local shut_samples, open_samples = 0, 0
    for i = 0, 4000 do
      local v = Anim.blink(i / 1000, opts)
      T.ok(v >= 0 and v <= 1, "openness stays 0..1")
      if v < 0.5 then shut_samples = shut_samples + 1 else open_samples = open_samples + 1 end
    end
    T.ok(open_samples > shut_samples * 20, "eyes are open the overwhelming majority")
    T.ok(shut_samples > 0, "and they do actually shut")
    T.near(Anim.blink(0, opts), 1, 1e-9)
  end)

  T.section("anim — selection")

  T.case("a lift leaves at once and settles", function()
    T.near(Anim.lift(0, 0.2), 0, 1e-9)
    T.near(Anim.lift(0.2, 0.2), 1, 1e-9)
    T.eq(Anim.lift(9, 0.2), 1, "and stays up")
    T.ok(Anim.lift(0.05, 0.2) > 0.5, "a quarter of the way in, it is over half way up")
    T.eq(Anim.lift(-1, 0.2), 0, "a negative age is not a negative lift")
  end)

  T.case("a press goes down fast and comes back, once", function()
    T.near(Anim.press(0, 0.16), 0, 1e-9)
    local peak = Anim.press(0.05, 0.16)
    T.ok(peak > 0.8, "it reaches the bottom quickly")
    T.eq(Anim.press(0.16, 0.16), 0, "and it is over")
    T.eq(Anim.press(5, 0.16), 0)
    -- The two halves are unequal on purpose: an impact and a spring.
    T.ok(Anim.press(0.03, 0.16) > Anim.press(0.13, 0.16))
  end)

  T.section("anim — feedback")

  T.case("a shake decays to nothing and is deterministic", function()
    local x0, y0 = Anim.shake(0.02, { duration = 0.3, amount = 5 })
    local x1, y1 = Anim.shake(0.02, { duration = 0.3, amount = 5 })
    T.eq(x0, x1, "the same moment is the same offset — a screenshot must repeat")
    T.eq(y0, y1)
    local late_x = select(1, Anim.shake(0.28, { duration = 0.3, amount = 5 }))
    T.ok(math.abs(late_x) < math.abs(x0), "it decays")
    T.same({ Anim.shake(0.3, { duration = 0.3 }) }, { 0, 0 }, "and stops dead")
    T.same({ Anim.shake(nil) }, { 0, 0 })
    for i = 0, 30 do
      local x, y = Anim.shake(i / 100, { duration = 0.32, amount = 4 })
      T.ok(math.abs(x) <= 4.001 and math.abs(y) <= 4.001, "never exceeds the amount")
    end
  end)

  T.case("a stamp holds a beat, then lands hard, then settles", function()
    -- The beat is the point: an instant stamp reads as a state change, a
    -- delayed one reads as a verdict.
    T.eq(Anim.stamp(0.0, { hold = 0.2 }), nil, "nothing during the hold")
    T.eq(Anim.stamp(0.19, { hold = 0.2 }), nil)
    local scale, alpha = Anim.stamp(0.21, { hold = 0.2, fall = 0.18 })
    T.ok(scale > 2, "it arrives oversize")
    T.ok(alpha < 0.5, "and faint")
    local s2 = Anim.stamp(0.38, { hold = 0.2, fall = 0.18 })
    T.ok(s2 < 1.3 and s2 >= 1, "then overshoots back through 1")
    local s3, a3 = Anim.stamp(5, { hold = 0.2 })
    T.eq(s3, 1)
    T.eq(a3, 1)
    T.eq(Anim.stamp(nil), nil)
  end)

  T.case("an iris closes from full to nothing", function()
    T.near(Anim.iris(0, 0.3), 1, 1e-9, "it starts covering everything")
    T.near(Anim.iris(0.3, 0.3), 0, 1e-9, "and ends shut")
    T.eq(Anim.iris(9, 0.3), 0)
    T.nope(Anim.iris_done(0.1, 0.3))
    T.ok(Anim.iris_done(0.3, 0.3))
    -- Monotonic, or the hole reopens part way through.
    local previous = 2
    for i = 0, 100 do
      local v = Anim.iris(i / 100 * 0.3, 0.3)
      T.ok(v <= previous + 1e-9, "the iris never reopens")
      previous = v
    end
  end)

  T.section("anim — palette rotation from art/palette.json")

  T.case("a hue rotation of zero changes nothing", function()
    for _, rgb in ipairs({ { 0.7, 0.01, 0.1 }, { 0.02, 0.35, 0.75 }, { 0.89, 0.71, 0.04 } }) do
      local r, g, b = Anim.rotate_hue(rgb[1], rgb[2], rgb[3], 0)
      T.near(r, rgb[1], 0.01)
      T.near(g, rgb[2], 0.01)
      T.near(b, rgb[3], 0.01)
    end
  end)

  T.case("a rotation actually moves the hue, and stays in gamut", function()
    -- Sign 0 in art/palette.json is a red tube at hue 352.
    local r, g, b = Anim.rotate_hue(177 / 255, 2 / 255, 25 / 255, 120)
    T.ok(g > r, "red rotated a third of the way round is no longer reddest")
    for _, v in ipairs({ r, g, b }) do
      T.ok(v >= 0 and v <= 1, "and it is still a colour")
    end
    -- Full circle returns roughly where it started.
    local r2 = select(1, Anim.rotate_hue(177 / 255, 2 / 255, 25 / 255, 360))
    T.near(r2, 177 / 255, 0.02)
  end)

  T.section("anim — no love in the motion layer")

  T.case("src/anim.lua does not reference love", function()
    T.no_love("src/anim.lua")
  end)
end
