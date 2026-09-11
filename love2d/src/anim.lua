-- The motion vocabulary: bobs, lifts, presses, shakes, stamps, irises.
--
-- **Pure.** No `love.`, no window, no global clock of its own — every function
-- takes a time and returns a number. That is the constraint that makes the
-- headless suite able to test the way this game moves at all: a bob is a
-- formula, and a formula can be asserted at t=0, t=half, t=whole without
-- opening anything.
--
-- Scenes hold `Anim.now()`, which is `love.timer.getTime()` unless a drive
-- script has pinned it (`Anim.freeze`). Pinning matters because a screenshot
-- of a bobbing mascot is a different screenshot every run, and a drive script
-- that cannot be compared across runs is a drive script that only proves it
-- did not crash.
--
-- ## What this is for
--
-- Ferris and Gogo standing perfectly still is the single loudest "this is a
-- menu, not a game" signal on the lands screen. None of this is decoration
-- for its own sake: a bob says a thing is alive, a lift says a row is the one
-- you are about to press, a shake says the compiler said no, and a held beat
-- before a stamp says the stamp mattered.

local Ease = require("src.ease")

local Anim = {}

-- The clock. `set_clock` is how the game hands over `love.timer.getTime`;
-- `freeze` is how a drive script makes a screenshot reproducible.
local clock = os.time
local frozen = nil

function Anim.set_clock(fn)
  clock = fn or os.time
end

--- Pin time. `Anim.freeze(nil)` lets it run again.
function Anim.freeze(t)
  frozen = t
end

function Anim.frozen()
  return frozen
end

function Anim.now()
  if frozen then return frozen end
  return clock()
end

-- ------------------------------------------------------------------- idling

--- A bob: a sprite that rises and settles, forever.
---
--- Cosine rather than a sawtooth because the eye reads the pause at the top
--- and the bottom as breathing; a linear rise and snap reads as a glitch.
--- `phase` offsets one sprite from its neighbour so a row of them does not
--- pulse in lockstep, which looks mechanical rather than alive.
function Anim.bob(t, opts)
  opts = opts or {}
  local period = opts.period or 1.6
  local amount = opts.amount or 2
  local phase = opts.phase or 0
  return -amount * (0.5 - 0.5 * math.cos(((t / period) + phase) % 1 * math.pi * 2))
end

-- Deliberately **not** here: a blink, a steam drift, and a palette cycle.
--
-- Every mascot in `art/` is a single frame with no closed-eye variant, so a
-- blink would have to be faked by squashing a whole crab vertically — which
-- reads as a rendering bug, not as a blink. A steam plume in front of a 28px
-- sprite on a category row is noise at that size. And `art/palette.json`'s
-- six measured neon hues have no screen in this client that composes a neon
-- sign: the map plates are painted with the signs already in them, and the
-- only surface a separate strip could overlay is the one somebody writes code
-- on. Shipping three tested functions nothing can call would be worse than
-- the absence of them; see `docs/decisions.md` for the longer version.

-- ---------------------------------------------------------------- selection

--- How far a row has lifted, 0..1, `seconds` after it became selected.
---
--- Expo-out: it leaves immediately and settles, which is what "this one" feels
--- like. A row that eased *in* would feel like it was deciding.
function Anim.lift(seconds, duration)
  return Ease.expOut(math.min(1, math.max(0, seconds) / (duration or 0.18)))
end

--- A plate pushing in: down fast, back slower, once. 0..1 of the push.
---
--- The two halves are deliberately unequal — the press is an impact and the
--- return is a spring, and making them symmetrical is what makes a button
--- feel like a rectangle changing colour.
function Anim.press(seconds, duration)
  duration = duration or 0.16
  local x = math.min(1, math.max(0, seconds) / duration)
  if x >= 1 then return 0 end
  if x < 0.35 then return Ease.expOut(x / 0.35) end
  return 1 - Ease.cosine((x - 0.35) / 0.65)
end

-- ----------------------------------------------------------------- feedback

--- A decaying shake. Returns `dx, dy` in pixels.
---
--- Deterministic: the wobble comes from two sines at incommensurable rates,
--- not from `random`, so the same moment of the same shake is the same pixel
--- offset every run. A drive script screenshotting a shake must not get a
--- different image each time.
function Anim.shake(seconds, opts)
  opts = opts or {}
  local duration = opts.duration or 0.32
  local amount = opts.amount or 4
  if seconds == nil or seconds < 0 or seconds >= duration then return 0, 0 end
  local decay = 1 - (seconds / duration)
  decay = decay * decay
  local a = math.sin(seconds * 54.0) * amount * decay
  local b = math.sin(seconds * 37.7 + 1.3) * amount * 0.6 * decay
  return a, b
end

--- A stamp landing: nothing, then a hard arrival, then a settle.
---
--- Returns `scale, alpha`. The **hold** is the point — `docs/art.md`'s clear
--- sequence and every arcade game that ever mattered wait a beat before the
--- word lands, because an instant stamp reads as a state change and a delayed
--- one reads as a verdict.
function Anim.stamp(seconds, opts)
  opts = opts or {}
  local hold = opts.hold or 0.22
  local fall = opts.fall or 0.18
  local settle = opts.settle or 0.22
  if seconds == nil then return nil end
  if seconds < hold then return nil end          -- the beat before
  local t = seconds - hold
  if t < fall then
    -- Coming down from oversize, fading in.
    local k = Ease.expOut(t / fall)
    return 2.6 - 1.6 * k, k
  end
  if t < fall + settle then
    -- The overshoot bounce back to 1.
    local k = Ease.cosine((t - fall) / settle)
    return 1.0 + 0.14 * (1 - k), 1
  end
  return 1, 1
end

--- An iris: a shrinking circle over the outgoing screen, 1 -> 0.
---
--- Returns `radius_fraction`, where 1 covers the whole screen and 0 is shut.
--- The cheapest thing in this file and the most "game" per line: a scene that
--- irises out of the node you pressed says the two screens are the same
--- place, which a cut never can.
function Anim.iris(seconds, duration)
  duration = duration or 0.28
  if seconds == nil then return nil end
  local x = math.min(1, math.max(0, seconds) / duration)
  return 1 - Ease.expInOut(x)
end

--- True once an iris has finished.
function Anim.iris_done(seconds, duration)
  return (seconds or 0) >= (duration or 0.28)
end

return Anim
