-- The motion engine: tweens, springs, and the immediate-mode helpers the
-- components drive their state through.
--
-- **Pure.** No `love.`, no window, no clock of its own: `Juice.update(dt)` is
-- called once a frame from `src/app.lua` and everything in here is a
-- function of the `dt`s it has been handed. That is what lets
-- `tests/test_juice.lua` run a hover to rest, a card in, and a number up,
-- under a bare luajit, and it is why `make check-layering` lists this file.
--
-- `src/ease.lua` and `src/anim.lua` are underneath, not beside: the curves
-- are theirs, the press and the shake are theirs, and **`Anim.freeze` is
-- honoured** — while a drive script has the clock pinned, `update` completes
-- every tween on the spot and every helper answers with its resting value,
-- so a screenshot never catches a card halfway in.
--
-- ## Two ways to use it
--
--   * **Retained**: `Juice.to(obj, { x = 100 }, 0.2, "outExpo")` moves
--     fields on a table the caller owns, and `:after(fn)` / `:chain(...)`
--     string them together. `Juice.spring(obj, "y", 0)` is the same with a
--     spring. For a scene that owns its state.
--   * **Immediate**: the components are drawn every frame and own nothing,
--     so they ask by key. `Juice.follow("btn:RUN", hot and 1 or 0)` is a
--     hover amount that eases toward its target; `Juice.enter("lands:3",
--     { delay = 0.1 })` is a card's slide-in progress; `Juice.counter("xp",
--     425)` is a number on its way to 425. The first call creates the state,
--     every call refreshes it, and `Juice.forget("lands:")` drops a screen's
--     worth when the screen is left.

local Ease = require("src.ease")
local Anim = require("src.anim")

local Juice = {}

-- ----------------------------------------------------------------- curves

local function out_back(t)
  t = Ease.clamp(t, 0, 1)
  local c1 = 1.70158
  local c3 = c1 + 1
  return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
end

local function out_bounce(t)
  t = Ease.clamp(t, 0, 1)
  local n1, d1 = 7.5625, 2.75
  if t < 1 / d1 then return n1 * t * t end
  if t < 2 / d1 then t = t - 1.5 / d1; return n1 * t * t + 0.75 end
  if t < 2.5 / d1 then t = t - 2.25 / d1; return n1 * t * t + 0.9375 end
  t = t - 2.625 / d1
  return n1 * t * t + 0.984375
end

local function out_elastic(t)
  t = Ease.clamp(t, 0, 1)
  if t == 0 or t == 1 then return t end
  local c4 = (2 * math.pi) / 3
  return math.pow(2, -10 * t) * math.sin((t * 10 - 0.75) * c4) + 1
end

--- The curves by name. The ease-outs are the ones a component reaches for:
--- a thing that leaves at once and settles reads as "this one", and a thing
--- that gathers itself first reads as hesitation. `outBack` overshoots a
--- little, for a card landing; `outBounce` for a stamp.
Juice.ease = {
  linear = function(t) return Ease.clamp(t, 0, 1) end,
  outQuad = function(t) t = Ease.clamp(t, 0, 1); return 1 - (1 - t) * (1 - t) end,
  outCubic = function(t) t = Ease.clamp(t, 0, 1); return 1 - (1 - t) ^ 3 end,
  inCubic = function(t) t = Ease.clamp(t, 0, 1); return t * t * t end,
  inOutCubic = function(t)
    t = Ease.clamp(t, 0, 1)
    if t < 0.5 then return 4 * t * t * t end
    return 1 - (-2 * t + 2) ^ 3 / 2
  end,
  outExpo = Ease.expOut,
  inExpo = Ease.expIn,
  inOutExpo = Ease.expInOut,
  cosine = Ease.cosine,
  outBack = out_back,
  outBounce = out_bounce,
  outElastic = out_elastic,
}

local function curve(e)
  if type(e) == "function" then return e end
  return Juice.ease[e or "outExpo"] or Ease[e] or Ease.expOut
end

Juice.curve = curve

-- ----------------------------------------------------------------- tweens

local tweens = {}

local Tween = {}
Tween.__index = Tween

--- Move the fields in `target` on `obj` to their values over `dur` seconds
--- on `ease` (a name from `Juice.ease` or a function). `opts.delay` holds
--- it; `opts.after` is a function for when it lands. Returns the tween.
---
--- A second tween on the same field of the same object replaces the first,
--- so a hover that reverses mid-way does not fight itself.
function Juice.to(obj, target, dur, ease, opts)
  opts = opts or {}
  local tw = setmetatable({
    obj = obj, to = {}, from = {}, dur = math.max(0, dur or 0.2),
    ease = curve(ease), t = -(opts.delay or 0), done = false,
    on_update = opts.on_update, after_fns = {},
  }, Tween)
  for k, v in pairs(target) do
    tw.to[k] = v
    tw.from[k] = tonumber(obj[k]) or 0
    for _, other in ipairs(tweens) do
      if other.obj == obj and other.to[k] ~= nil and not other.done then
        other.to[k] = nil
      end
    end
  end
  if opts.after then tw.after_fns[1] = opts.after end
  tweens[#tweens + 1] = tw
  return tw
end

--- `fn()` when this tween lands.
function Tween:after(fn)
  if self.done then fn() else self.after_fns[#self.after_fns + 1] = fn end
  return self
end

--- A tween that starts when this one lands.
function Tween:chain(target, dur, ease, opts)
  local nxt
  self:after(function()
    nxt = Juice.to(self.obj, target, dur, ease, opts)
    if self.chained then for _, fn in ipairs(self.chained) do nxt:after(fn) end end
  end)
  -- `:after` on the returned handle has to reach the tween that does not
  -- exist yet, so the handle is a stand-in that forwards.
  local handle = setmetatable({ obj = self.obj }, {
    __index = function(_, k)
      if k == "after" then
        return function(h, fn)
          self.chained = self.chained or {}
          self.chained[#self.chained + 1] = fn
          return h
        end
      end
      if k == "chain" then
        return function(_, ...)
          local args = { ... }
          local inner
          self.chained = self.chained or {}
          self.chained[#self.chained + 1] = function() end
          local stub = { }
          self:after(function()
            inner = nxt:chain(unpack(args))
            for _, fn in ipairs(stub) do inner:after(fn) end
          end)
          return setmetatable({}, { __index = function(_, kk)
            if kk == "after" then return function(hh, fn) stub[#stub + 1] = fn; return hh end end
          end })
        end
      end
      return nil
    end,
  })
  return handle
end

local function finish_tween(tw)
  for k, v in pairs(tw.to) do tw.obj[k] = v end
  tw.done = true
  if tw.on_update then tw.on_update(tw.obj, 1) end
  for _, fn in ipairs(tw.after_fns) do fn() end
end

local function step_tween(tw, dt)
  tw.t = tw.t + dt
  if tw.t < 0 then return end
  local u = tw.dur > 0 and math.min(1, tw.t / tw.dur) or 1
  local k = tw.ease(u)
  for key, v in pairs(tw.to) do
    tw.obj[key] = tw.from[key] + (v - tw.from[key]) * k
  end
  if tw.on_update then tw.on_update(tw.obj, u) end
  if u >= 1 then finish_tween(tw) end
end

--- Drop every tween on `obj` (or on `obj[key]`), landing nothing.
function Juice.cancel(obj, key)
  for _, tw in ipairs(tweens) do
    if tw.obj == obj then
      if key then tw.to[key] = nil else tw.done = true end
    end
  end
end

-- ---------------------------------------------------------------- springs

local springs = {}

--- A damped spring on `obj[key]` towards `target`. `opts.k` is stiffness
--- (default 180) and `opts.d` damping (default 2 * sqrt(k), critical — it
--- settles without a wobble; a lower `d` bounces). Call again to retarget.
function Juice.spring(obj, key, target, opts)
  opts = opts or {}
  for _, s in ipairs(springs) do
    if s.obj == obj and s.key == key and not s.done then
      s.target = target
      if opts.k then s.k = opts.k end
      if opts.d then s.d = opts.d end
      return s
    end
  end
  local k = opts.k or 180
  local s = { obj = obj, key = key, target = target, k = k, d = opts.d or 2 * math.sqrt(k),
    v = opts.v or 0, done = false, after = opts.after }
  if obj[key] == nil then obj[key] = target end
  springs[#springs + 1] = s
  return s
end

local function step_spring(s, dt)
  -- Sub-stepped so a long frame cannot fling the spring past its target.
  local x = s.obj[s.key]
  local remaining = dt
  while remaining > 0 do
    local h = math.min(remaining, 1 / 120)
    local a = s.k * (s.target - x) - s.d * s.v
    s.v = s.v + a * h
    x = x + s.v * h
    remaining = remaining - h
  end
  if math.abs(x - s.target) < 0.0005 and math.abs(s.v) < 0.005 then
    x = s.target
    s.v = 0
    s.done = true
    if s.after then s.after() end
  end
  s.obj[s.key] = x
end

-- ------------------------------------------------------- keyed, immediate

local keyed = {}
local frame = 0
-- Updates of silence after which a keyed state is forgotten: a button that
-- was drawn on a screen that has since been left.
local STALE = 600

--- Keyed state is namespaced by kind, so `Juice.enter("card")` and
--- `Juice.follow("card")` on the same key are two states, not one that the
--- second caller finds half-shaped.
local function slot(kind, key, init)
  local full = kind .. "|" .. key
  local s = keyed[full]
  if not s then
    s = init()
    keyed[full] = s
  end
  s.seen = frame
  return s
end

--- A value that eases toward `target`, remembered under `key`.
---
--- The first call answers `target` at once (or `opts.from`); every call
--- after moves it. `opts.speed` is the rate of the exponential approach
--- (default 16: about 90% of the way in 0.15 s). With `opts.spring = true`
--- it is a spring instead (`opts.k`, `opts.d`) and overshoots a little,
--- which is what a button under a pointer wants.
function Juice.follow(key, target, opts)
  opts = opts or {}
  if Anim.frozen() then return target end
  local s = slot("follow", key, function()
    return { kind = "follow", value = opts.from or target, target = target, v = 0 }
  end)
  s.target = target
  s.speed = opts.speed or 16
  s.spring = opts.spring and (opts.k or 220) or nil
  s.damp = opts.d
  return s.value
end

local function step_follow(s, dt)
  if s.spring then
    local k = s.spring
    local d = s.damp or 2 * math.sqrt(k) * 0.8
    local remaining = dt
    while remaining > 0 do
      local h = math.min(remaining, 1 / 120)
      local a = k * (s.target - s.value) - d * s.v
      s.v = s.v + a * h
      s.value = s.value + s.v * h
      remaining = remaining - h
    end
    if math.abs(s.value - s.target) < 0.0005 and math.abs(s.v) < 0.005 then
      s.value, s.v = s.target, 0
    end
  else
    s.value = Ease.smooth(s.value, s.target, dt, s.speed)
    if math.abs(s.value - s.target) < 0.0005 then s.value = s.target end
  end
end

--- A thing arriving: 0 the first time `key` is asked for, 1 once it has
--- settled, eased in between. `opts.dur` (default `0.22`), `opts.delay`
--- (for a stagger), `opts.ease` (default `outCubic`; `outBack` to land with
--- a little overshoot). A screen calls `Juice.forget("lands:")` on `enter`
--- so the cards come in again next visit.
function Juice.enter(key, opts)
  opts = opts or {}
  if Anim.frozen() then return 1 end
  local s = slot("enter", key, function()
    return { kind = "enter", t = -(opts.delay or 0), dur = opts.dur or 0.22,
      ease = curve(opts.ease or "outCubic") }
  end)
  if s.t <= 0 then return 0 end
  return s.ease(math.min(1, s.t / s.dur))
end

--- True once `Juice.enter(key)` has settled.
function Juice.entered(key)
  local s = keyed["enter|" .. key]
  return Anim.frozen() ~= nil or (s ~= nil and s.t >= s.dur)
end

--- A number on its way to `value`. The first call shows `value`; a change
--- counts up (or down) from where it was over `opts.dur` (default 0.6 s),
--- fast first and then the last few, as a score does. Returns the integer
--- to print and whether it is still moving.
function Juice.counter(key, value, opts)
  opts = opts or {}
  value = tonumber(value) or 0
  if Anim.frozen() then return value, false end
  local s = slot("counter", key, function()
    return { kind = "counter", shown = value, from = value, to = value, t = 1, dur = opts.dur or 0.6 }
  end)
  if value ~= s.to then
    s.from, s.to, s.t = s.shown, value, 0
    s.dur = opts.dur or 0.6
  end
  return math.floor(s.shown + 0.5), s.t < 1
end

local function step_counter(s, dt)
  if s.t >= 1 then s.shown = s.to; return end
  s.t = math.min(1, s.t + dt / s.dur)
  s.shown = s.from + (s.to - s.from) * Ease.expOut(s.t)
end

--- A moment: `Juice.trigger(key)` marks now, `Juice.since(key)` is the
--- seconds since, or nil if it never happened. A press, a shake, a stamp.
function Juice.trigger(key)
  local s = slot("since", key, function() return { kind = "since", t = 0 } end)
  s.t = 0
end

function Juice.since(key)
  local s = keyed["since|" .. key]
  if not s then return nil end
  s.seen = frame
  return s.t
end

--- How far a pressed thing is pushed in, 0..1: `Anim.press` on the moment
--- `Juice.trigger(key)` marked. 0 when nothing was pressed.
function Juice.pressed(key)
  local t = Juice.since(key)
  if t == nil then return 0 end
  return Anim.press(t)
end

-- --------------------------------------------------------------- helpers

--- A stable sign for `key`, so a given button always tilts the same way.
local function sign_of(key)
  local h = 0
  for i = 1, #key do h = (h * 31 + key:byte(i)) % 65536 end
  return (h % 2 == 0) and 1 or -1
end

--- Degrees of tilt for a hovered thing: ±`max` (default 2) scaled by
--- `amount`, the sign chosen by the key. In radians if `opts.radians`.
function Juice.tilt(key, amount, max, opts)
  local deg = sign_of(key) * (max or 2) * (amount or 0)
  if opts and opts.radians then return deg * math.pi / 180 end
  return deg
end

--- The hover scale for an amount 0..1: 1 at rest, `max` (default 1.05)
--- under the pointer.
function Juice.scale(amount, max)
  return 1 + ((max or 1.05) - 1) * (amount or 0)
end

--- A decaying shake, `dx, dy` — `Anim.shake`.
Juice.shake = Anim.shake

--- The delay for the `i`-th of a row of things coming in.
function Juice.stagger(i, base)
  return math.max(0, (i or 1) - 1) * (base or 0.045)
end

--- A number counting from `from` to `to`, `u` of the way (0..1), fast first.
--- The pure version of `Juice.counter`.
function Juice.count(from, to, u)
  return math.floor(from + (to - from) * Ease.expOut(Ease.clamp(u or 0, 0, 1)) + 0.5)
end

-- ---------------------------------------------------------------- update

--- Advance everything by `dt`. **Once a frame, from `src/app.lua`.** While
--- `Anim.freeze` holds the clock, every tween lands and every helper rests.
function Juice.update(dt)
  dt = math.max(0, tonumber(dt) or 0)
  frame = frame + 1
  local frozen = Anim.frozen() ~= nil
  if frozen then dt = 1e9 end

  local live = {}
  for _, tw in ipairs(tweens) do
    if not tw.done then
      if frozen then
        tw.t = math.max(tw.t, 0)
        finish_tween(tw)
      else
        step_tween(tw, dt)
      end
    end
    if not tw.done then live[#live + 1] = tw end
  end
  tweens = live

  live = {}
  for _, s in ipairs(springs) do
    if not s.done then
      if frozen then
        s.obj[s.key] = s.target
        s.v, s.done = 0, true
        if s.after then s.after() end
      else
        step_spring(s, dt)
      end
    end
    if not s.done then live[#live + 1] = s end
  end
  springs = live

  for key, s in pairs(keyed) do
    if s.kind == "follow" then
      if frozen then s.value, s.v = s.target, 0 else step_follow(s, dt) end
    elseif s.kind == "enter" then
      s.t = frozen and s.dur or (s.t + dt)
    elseif s.kind == "counter" then
      if frozen then s.t, s.shown = 1, s.to else step_counter(s, dt) end
    elseif s.kind == "since" then
      s.t = s.t + dt
    end
    if frame - (s.seen or frame) > STALE then keyed[key] = nil end
  end
end

--- Drop every keyed state whose key starts with `prefix` (all of them with
--- no prefix). A scene's `enter` does this so its cards come in again.
function Juice.forget(prefix)
  for full in pairs(keyed) do
    local key = full:match("^[^|]*|(.*)$") or full
    if not prefix or key:sub(1, #prefix) == prefix then keyed[full] = nil end
  end
end

--- Everything gone: the tweens, the springs and the keyed state. For tests.
function Juice.clear()
  tweens, springs, keyed, frame = {}, {}, {}, 0
end

--- How much is in flight, for a test or a debug line.
function Juice.active()
  local n = 0
  for _ in pairs(keyed) do n = n + 1 end
  return #tweens, #springs, n
end

return Juice
