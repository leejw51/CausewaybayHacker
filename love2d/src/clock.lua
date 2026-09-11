-- The quest clock (PROTOCOL §4.8b). **Display only.**
--
-- The server owns it. `Quest.opened_at` and `Quest.deadline_at` are stamped by
-- the first `quest.get` and returned unchanged by every later one, so a
-- reconnect — which this client does properly — shows *one* clock rather than
-- a fresh one. `quest.reset` does not restart it. Nothing here decides
-- anything; it renders a fact the server already knows.
--
-- ## Two rules this file exists to obey
--
-- **Derive the remaining time from `deadline_at` and the wall clock**, never
-- by decrementing a local counter. This client has already been bitten once
-- by the other approach: `src/drive.lua` summed LÖVE's capped `dt` and a
-- 90-second timeout became half an hour on an occluded window, because a
-- window nobody can see gets almost no frames. A countdown built the same way
-- would quietly stop counting the moment the player alt-tabbed away to read
-- documentation — which is exactly when they are using their time.
--
-- **Everything here is a pure function of (`deadline_at`, `now`).** A clock is
-- the classic thing that drags a window and a real elapsed second into a test
-- suite; this one is asserted at chosen instants instead.
--
-- ## It blocks nothing
--
-- §4.8b: time runs out, the quest stays open, the count keeps going into
-- visible overtime, and a late submit is judged exactly like an early one —
-- it simply is not `within_limit`. So there is no modal here, no disabled
-- button, and no state in which this module can refuse anything.

local Clock = {}

-- The wall clock, as epoch seconds with sub-second resolution.
--
-- `os.time()` has one-second granularity, which makes a countdown visibly
-- stutter. `love.timer.getTime()` is monotonic and fine-grained but starts at
-- an arbitrary zero. Pinning one to the other at startup gives both: real
-- wall time, smooth, and immune to the frame-rate trap above.
local epoch0 = nil
local mono0 = nil
local monotonic = nil
local offset = 0

--- `fn` is a monotonic seconds source — `love.timer.getTime` in the game.
function Clock.set_source(fn)
  monotonic = fn
  epoch0 = os.time()
  mono0 = fn and fn() or 0
end

--- Move the client's view of *now*, without touching the deadline.
---
--- For drive scripts, and the same affordance as `Anim.freeze`: a `hacker`
--- quest has a ten-minute limit, and the only honest way to photograph all
--- four registers of a real server-issued `deadline_at` inside one run is to
--- move the clock rather than to invent the pair. Nothing in the game calls
--- it; `make drive` does.
function Clock.shift(seconds)
  offset = tonumber(seconds) or 0
end

function Clock.shifted()
  return offset
end

function Clock.now()
  if monotonic and epoch0 then
    return epoch0 + (monotonic() - mono0) + offset
  end
  return os.time() + offset
end

-- --------------------------------------------------------------- RFC3339

local function days_from_civil(y, m, d)
  -- Howard Hinnant's civil calendar algorithm. Arithmetic rather than
  -- `os.time`, because `os.time` reads a table as *local* time and these
  -- stamps are UTC (§2.4) — a client in Hong Kong would otherwise show a
  -- clock eight hours out.
  y = y - (m <= 2 and 1 or 0)
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- Parse `2026-09-11T04:14:33Z` to epoch seconds. Returns nil on anything
--- else, including the `json.null` a server sends for an untimed quest.
function Clock.parse(stamp)
  if type(stamp) ~= "string" then return nil end
  local y, mo, d, h, mi, sec =
    stamp:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  return days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
end

-- ---------------------------------------------------------------- the state

--- Thresholds, as fractions of the whole limit with a floor in seconds.
---
--- Both, because a 10-minute `hacker` quest and a 10-minute one are different
--- problems: a pure fraction gives a 30-second warning on a ten-minute quest
--- and a 3-second one on a minute-long quest, and a pure constant warns for
--- half the length of a short one. `max` of the two is the honest answer.
Clock.WARNING_FRACTION, Clock.WARNING_FLOOR = 0.25, 60
Clock.URGENT_FRACTION, Clock.URGENT_FLOOR = 0.08, 20

--- Read a quest's clock. Returns nil when the quest is untimed.
---
--- `now` defaults to the wall clock and is a parameter so the suite can ask
--- what the screen would say at any instant without waiting for one.
---
--- The result:
---   remaining   seconds left; **negative in overtime**
---   elapsed     seconds since it opened
---   limit       the whole allowance, seconds
---   phase       "calm" | "warning" | "urgent" | "overtime"
---   fraction    0..1 of the limit still left, clamped
---   overtime    seconds past the deadline, or 0
function Clock.read(quest, now)
  if type(quest) ~= "table" then return nil end
  local deadline = Clock.parse(quest.deadline_at)
  if not deadline then return nil end
  local opened = Clock.parse(quest.opened_at)
  local limit = tonumber(quest.time_limit_s)
  if not limit and opened then limit = deadline - opened end
  if not limit or limit <= 0 then return nil end

  now = now or Clock.now()
  local remaining = deadline - now

  local warning = math.max(Clock.WARNING_FLOOR, limit * Clock.WARNING_FRACTION)
  local urgent = math.max(Clock.URGENT_FLOOR, limit * Clock.URGENT_FRACTION)

  local phase = "calm"
  if remaining < 0 then
    phase = "overtime"
  elseif remaining <= urgent then
    phase = "urgent"
  elseif remaining <= warning then
    phase = "warning"
  end

  return {
    remaining = remaining,
    elapsed = opened and (now - opened) or (limit - remaining),
    limit = limit,
    phase = phase,
    fraction = math.max(0, math.min(1, remaining / limit)),
    overtime = remaining < 0 and -remaining or 0,
    deadline = deadline,
  }
end

--- `12:05`, or `+01:20` past the deadline.
---
--- Overtime counts **up** and wears a sign, because a clock that kept
--- counting down into negatives would read as a bug and one that stopped at
--- zero would hide the thing worth knowing.
function Clock.format(state)
  if not state then return "" end
  local seconds = state.phase == "overtime" and state.overtime or state.remaining
  seconds = math.max(0, math.floor(seconds + 0.5))
  local minutes = math.floor(seconds / 60)
  local rest = seconds % 60
  local sign = state.phase == "overtime" and "+" or ""
  if minutes >= 60 then
    return ("%s%d:%02d:%02d"):format(sign, math.floor(minutes / 60), minutes % 60, rest)
  end
  return ("%s%d:%02d"):format(sign, minutes, rest)
end

--- One line for the player, and not a scold.
function Clock.caption(state)
  if not state then return nil end
  if state.phase == "overtime" then
    return "past the limit — the quest is still open, and a clear still counts"
  end
  if state.phase == "urgent" then return "time is nearly up" end
  return nil
end

--- Did this attempt beat the clock? §4.8b's `within_limit`, rendered.
---
--- `null` on an untimed quest, so nil in, nil out — an untimed quest must not
--- claim anything about a limit it never had.
function Clock.verdict_note(attempt)
  if type(attempt) ~= "table" then return nil end
  local within = attempt.within_limit
  if within == nil then return nil end
  if attempt.mode == "run" then return nil end
  return within and "inside the time limit" or "over the time limit"
end

return Clock
