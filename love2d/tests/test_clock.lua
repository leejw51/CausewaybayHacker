-- The quest clock (PROTOCOL §4.8b), asserted without waiting a second.
--
-- A clock is the classic thing that drags a window and a real elapsed second
-- into a suite. This one does not, because everything in `src/clock.lua` is a
-- pure function of (`deadline_at`, `now`) — so the questions are asked at
-- chosen instants instead of lived through.

local T = require("tests.framework")
local Clock = require("src.clock")
local Ease = require("src.ease")

--- A `Quest` with a ten-minute limit that opened at a known instant.
local function timed(limit, opened_at, deadline_at)
  return {
    id = "rust.hacker.01.two-sum",
    time_limit_s = limit,
    opened_at = opened_at or "2026-09-11T04:00:00Z",
    deadline_at = deadline_at or "2026-09-11T04:10:00Z",
  }
end

local OPEN = Clock.parse("2026-09-11T04:00:00Z")

return function()
  T.section("clock — RFC3339, in UTC")

  T.case("stamps parse to epoch seconds, in UTC and not local time", function()
    -- The epoch itself, which pins the arithmetic.
    T.eq(Clock.parse("1970-01-01T00:00:00Z"), 0)
    T.eq(Clock.parse("1970-01-02T00:00:00Z"), 86400)
    T.eq(Clock.parse("2000-01-01T00:00:00Z"), 946684800)
    T.eq(Clock.parse("2026-09-11T04:14:33Z"), 1789100073)
    -- A leap day, because the civil algorithm is where that goes wrong.
    T.eq(Clock.parse("2024-02-29T00:00:00Z") - Clock.parse("2024-02-28T00:00:00Z"), 86400)
    -- And the difference between two stamps is the obvious number whatever
    -- timezone this machine is in.
    T.eq(Clock.parse("2026-09-11T04:10:00Z") - Clock.parse("2026-09-11T04:00:00Z"), 600)
  end)

  T.case("anything that is not a stamp is nil, including null", function()
    local json = require("src.json")
    T.eq(Clock.parse(nil), nil)
    T.eq(Clock.parse(json.null), nil, "an untimed quest sends null (§5.3)")
    T.eq(Clock.parse(""), nil)
    T.eq(Clock.parse("tomorrow"), nil)
    T.eq(Clock.parse(1788063273), nil)
  end)

  T.section("clock — reading a quest")

  T.case("an untimed quest has no clock at all", function()
    local json = require("src.json")
    T.eq(Clock.read({ time_limit_s = nil, deadline_at = nil }), nil)
    T.eq(Clock.read({ time_limit_s = json.null, deadline_at = json.null }), nil)
    T.eq(Clock.read(nil), nil)
    T.eq(Clock.read({}), nil)
  end)

  T.case("remaining comes from the deadline and the wall clock", function()
    local q = timed(600)
    T.eq(Clock.read(q, OPEN).remaining, 600, "all of it, at the instant it opened")
    T.eq(Clock.read(q, OPEN + 60).remaining, 540)
    T.eq(Clock.read(q, OPEN + 599).remaining, 1)
    T.eq(Clock.read(q, OPEN + 600).remaining, 0)
    -- **Negative**, not clamped: overtime is a real number and the screen
    -- has to be able to say how far past.
    T.eq(Clock.read(q, OPEN + 700).remaining, -100)
    T.eq(Clock.read(q, OPEN + 700).overtime, 100)
    T.eq(Clock.read(q, OPEN + 100).overtime, 0)
  end)

  T.case("elapsed and fraction track the other way", function()
    local q = timed(600)
    T.eq(Clock.read(q, OPEN).elapsed, 0)
    T.eq(Clock.read(q, OPEN + 300).elapsed, 300)
    T.near(Clock.read(q, OPEN + 300).fraction, 0.5, 1e-9)
    T.eq(Clock.read(q, OPEN + 900).fraction, 0, "fraction is clamped even though remaining is not")
    T.eq(Clock.read(q, OPEN - 10).fraction, 1)
  end)

  T.case("the limit can be derived when the server sends only the pair", function()
    -- `time_limit_s` is on the Quest, but a client should not fall over if it
    -- arrives with only the two stamps.
    local q = { opened_at = "2026-09-11T04:00:00Z", deadline_at = "2026-09-11T04:10:00Z" }
    local state = Clock.read(q, OPEN + 60)
    T.ok(state ~= nil)
    T.eq(state.limit, 600)
    T.eq(state.remaining, 540)
  end)

  T.case("a null pair is normal, not an error", function()
    -- Two rules BE implemented, and both produce a null pair a client meets
    -- in ordinary play rather than as a fault:
    --
    --   * a quest **cleared before the clock existed** never grows an
    --     `opened_at` — nothing is invented after the fact;
    --   * **re-entering a cleared quest is untimed**, so `deadline_at` comes
    --     back null and there is simply no clock.
    --
    -- Either way the screen shows nothing, which is the correct nothing.
    local json = require("src.json")
    local cleared_before_clocks = {
      id = "rust.hacker.01.two-sum", state = "cleared",
      time_limit_s = 600, opened_at = json.null, deadline_at = json.null,
    }
    T.eq(Clock.read(cleared_before_clocks), nil)

    local re_entered = {
      id = "rust.hacker.01.two-sum", state = "cleared",
      time_limit_s = 600,   -- the quest still HAS a limit
      -- …but this visit is not being timed.
    }
    T.eq(Clock.read(re_entered), nil,
      "a limit with no deadline is not a clock — it is a fact about the quest")

    -- And a half-populated pair is not half a clock.
    T.eq(Clock.read({ time_limit_s = 600, opened_at = "2026-09-11T04:00:00Z" }), nil)
  end)

  T.section("clock — the phases")

  T.case("calm for most of its life, which is the whole point", function()
    local q = timed(600)
    -- Warning at 25% or 60s, urgent at 8% or 20s — for ten minutes that is
    -- 150s and 48s.
    T.eq(Clock.read(q, OPEN).phase, "calm")
    T.eq(Clock.read(q, OPEN + 300).phase, "calm")
    T.eq(Clock.read(q, OPEN + 449).phase, "calm")
    T.eq(Clock.read(q, OPEN + 450).phase, "warning")
    T.eq(Clock.read(q, OPEN + 551).phase, "warning")
    T.eq(Clock.read(q, OPEN + 552).phase, "urgent")
    T.eq(Clock.read(q, OPEN + 600).phase, "urgent", "zero is still not overtime")
    T.eq(Clock.read(q, OPEN + 601).phase, "overtime")
    T.eq(Clock.read(q, OPEN + 5000).phase, "overtime")
  end)

  T.case("the thresholds have a floor, so a short quest still gets a warning", function()
    -- A fraction alone would give a one-minute quest a 15-second warning and
    -- a 5-second urgency, which is no warning at all.
    local short = timed(60, "2026-09-11T04:00:00Z", "2026-09-11T04:01:00Z")
    T.eq(Clock.read(short, OPEN + 1).phase, "warning", "the floor takes over")
    T.eq(Clock.read(short, OPEN + 41).phase, "urgent")
    -- And a long quest is not warned at for a quarter of an hour.
    local long = timed(3600, "2026-09-11T04:00:00Z", "2026-09-11T05:00:00Z")
    T.eq(Clock.read(long, OPEN + 1800).phase, "calm")
    T.eq(Clock.read(long, OPEN + 2700).phase, "warning")
  end)

  T.section("clock — what it says")

  T.case("the countdown reads as a clock", function()
    local q = timed(600)
    T.eq(Clock.format(Clock.read(q, OPEN)), "10:00")
    T.eq(Clock.format(Clock.read(q, OPEN + 1)), "9:59")
    T.eq(Clock.format(Clock.read(q, OPEN + 540)), "1:00")
    T.eq(Clock.format(Clock.read(q, OPEN + 599)), "0:01")
    T.eq(Clock.format(Clock.read(q, OPEN + 600)), "0:00")
    T.eq(Clock.format(nil), "")
    local hour = timed(7200, "2026-09-11T04:00:00Z", "2026-09-11T06:00:00Z")
    T.eq(Clock.format(Clock.read(hour, OPEN)), "2:00:00")
  end)

  T.case("overtime counts UP and wears a sign", function()
    -- A clock that kept counting down into negatives would read as a bug; one
    -- that stopped at zero would hide the thing worth knowing.
    local q = timed(600)
    T.eq(Clock.format(Clock.read(q, OPEN + 601)), "+0:01")
    T.eq(Clock.format(Clock.read(q, OPEN + 680)), "+1:20")
    T.eq(Clock.format(Clock.read(q, OPEN + 4200)), "+1:00:00")
  end)

  T.case("the caption appears only when it has something to say", function()
    local q = timed(600)
    T.eq(Clock.caption(Clock.read(q, OPEN)), nil, "silence while there is time")
    T.eq(Clock.caption(Clock.read(q, OPEN + 450)), nil, "and through the warning too")
    T.ok(Clock.caption(Clock.read(q, OPEN + 590)) ~= nil)
    local over = Clock.caption(Clock.read(q, OPEN + 700))
    T.ok(over:find("still open") ~= nil, "§4.8b: the clock blocks nothing, and says so")
    T.eq(Clock.caption(nil), nil)
  end)

  T.section("clock — §4.8b's within_limit")

  T.case("a submit says whether it beat the clock; a run never does", function()
    T.eq(Clock.verdict_note({ mode = "submit", within_limit = true }), "inside the time limit")
    T.eq(Clock.verdict_note({ mode = "submit", within_limit = false }), "over the time limit")
    -- `null` on an untimed quest: an untimed quest must not claim anything
    -- about a limit it never had.
    T.eq(Clock.verdict_note({ mode = "submit" }), nil)
    T.eq(Clock.verdict_note({ mode = "run", within_limit = false }), nil,
      "a run never changes it, so it must not report it either")
    T.eq(Clock.verdict_note(nil), nil)
  end)

  T.section("clock — the attention curve lives in ease.lua")

  T.case("attention is zero for three quarters of the clock", function()
    -- The constraint, as an assertion: the clock is calm for most of its
    -- life, because it sits on the screen somebody is coding on.
    for _, fraction in ipairs({ 1.0, 0.9, 0.5, 0.3, 0.26, 0.25 }) do
      T.eq(Ease.attention(fraction), 0, ("silent at %.2f remaining"):format(fraction))
    end
    T.ok(Ease.attention(0.1) > 0, "and it does rise near the end")
    T.ok(Ease.attention(0.02) > Ease.attention(0.1), "getting more insistent")
    T.near(Ease.attention(0), 1, 1e-9)
    T.eq(Ease.attention(nil), 0)
  end)

  T.case("a pulse is one event, not a loop", function()
    T.near(Ease.pulse(0, 0.5), 1, 1e-9)
    T.ok(Ease.pulse(0.25, 0.5) < 1)
    T.eq(Ease.pulse(0.5, 0.5), 0)
    T.eq(Ease.pulse(9, 0.5), 0, "and it does not come back")
    T.eq(Ease.pulse(nil), 0)
    T.eq(Ease.pulse(-1), 0)
  end)

  T.section("clock — shifting the view of now")

  T.case("shift moves now and leaves the deadline alone", function()
    -- The drive affordance, and the property that makes it honest: the
    -- deadline is untouched, so a screenshot taken under a shift is a
    -- screenshot of the server's own pair seen from a different instant.
    local q = timed(600)
    local base = Clock.read(q, OPEN + 60)
    T.eq(base.remaining, 540)
    Clock.shift(120)
    T.eq(Clock.shifted(), 120)
    -- An explicit `now` still wins, so the pure path is unaffected.
    T.eq(Clock.read(q, OPEN + 60).remaining, 540)
    Clock.shift(0)
    T.eq(Clock.shifted(), 0)
  end)

  T.section("clock — no love in the clock")

  T.case("src/clock.lua does not reference love", function()
    T.no_love("src/clock.lua")
  end)
end
