-- How the Rust coder moves.
--
-- A state machine in virtual pixels with no canvas in it, so the headless
-- suite can pin it: **wander** drifts on a slow Lissajous inside the editor's
-- rectangle; **peek** flies to the caret and hovers a beat; **typing** sits a
-- cell to the right of the caret while the program appears; **thinking**
-- orbits it; **hold** stops dead still because somebody touched it and wants
-- to read. The shapes are CausewaybayRaiden's agent flight (orbit, spin,
-- follow) scaled to the box.
--
-- This is the LÖVE port of `frontend/src/ui/agent/sprite.ts`, constant for
-- constant. The character is the motion: a coder that drifts at one speed in
-- the browser and another on the desktop is two characters, so the numbers
-- below are the browser's numbers and changing one means changing both.
--
-- ## A journey is a flight, not a slide
--
-- Changing state — going to peek at the caret, coming back, being let go —
-- plans a **flight**: a fixed duration, and the position along it is the
-- exponential in-out curve. It leaves slowly, covers the middle fast, and
-- arrives slowly, which is what a thing with engines looks like and what a
-- constant-rate lerp never does. The destination is re-read every frame (a
-- caret moves while it is being flown to) and a destination that has jumped
-- is a new flight rather than a swerve. With no flight under way it falls
-- back to the exponential follow, which is what tracking a caret wants.
--
-- The barrel roll, the squash on a keystroke and the zoom while typing are
-- all on the same idea: everything chases a target exponentially, so a change
-- of state starts fast and settles soft, and nothing on the screen ever moves
-- at a constant rate.

local Ease = require("src.ease")

local M = {}

--- How fast the sprite eases towards its target, per second (Raiden's `follow`).
local FOLLOW = 5.5
--- The wander's period in seconds along each axis; unequal so it never repeats.
local WANDER_X = 26.0
local WANDER_Y = 18.5
--- The tempo of the wander: 1 left alone, and this much while the pointer is
--- moving — somebody reaching for the sprite should find it slowing to meet
--- them. The change is eased, per second.
local CALM_TEMPO = 0.18
local CALM_EASE = 3.2
--- The entrance: from this zoom down to size, easing out, over this long.
local ENTRY_ZOOM = 3.2
local ENTRY_SECS = 1.5
--- The bob under everything: a hover, not a stand.
local BOB_HZ = 1.6
--- How far the sprite keeps from the box's edge, as a share of its size.
local MARGIN = 0.55
--- The peek: how long it hovers at the caret.
local PEEK_HOLD = 1.6
--- The hold: touched, the sprite stops so its bubble can be read. It does not
--- stop dead — it coasts this many seconds' worth of its speed further and
--- settles there on the exponential follow, an ease-out from wherever it was.
--- It stays until a touch somewhere else.
local HOLD_COAST = 0.22
--- The zoom while held: a touch closer, attentive.
local HOLD_ZOOM = 1.06
--- The orbit while thinking.
local THINK_R = 18
local THINK_HZ = 0.9
--- How fast scale and angle chase their targets, per second.
local EASE = 9
--- How fast a keystroke's pulse dies away, per second.
local PULSE_DECAY = 7
--- The zoom while typing, and the extra a keystroke adds on top.
local TYPING_ZOOM = 1.18
local PULSE_ZOOM = 0.22
--- Squash and stretch: how far a pulse pulls the sprite wide and flat.
local SQUASH = 0.16
--- The rock while typing: amplitude in radians and rate in Hz.
local ROCK = 0.13
local ROCK_HZ = 4.5
--- How far it banks into a turn, per virtual pixel per second of travel.
local BANK = 0.0022
local BANK_MAX = 0.35
--- A barrel roll: one full turn, eased in and out, over this many seconds.
local ROLL_SECS = 0.7
--- A flight's length: a floor, plus this much per virtual pixel, to a ceiling.
local FLIGHT_MIN = 0.4
local FLIGHT_PER_PX = 1 / 520
local FLIGHT_MAX = 1.3
--- A destination that moved further than this mid-flight is a new flight.
local REPLAN_PX = 120
--- The light ribbon: how long each point of it lives, and how many at most.
local WAKE_SECS = 1.1
local WAKE_MAX = 64
--- How fast the sprite must move to leave ribbon behind it.
local WAKE_SPEED = 24
--- The afterimages: how many, and how fast it must move to leave one.
local TRAIL_MAX = 7
local TRAIL_SPEED = 180

M.WAKE_SECS = WAKE_SECS
M.ENTRY_ZOOM = ENTRY_ZOOM
M.HOLD_ZOOM = HOLD_ZOOM

local Sprite = {}
Sprite.__index = Sprite

--- `size` is the sprite's drawn size in virtual pixels, for the margin;
--- `reduced` is a function answering whether motion is to be kept still.
function M.new(size, reduced)
  return setmetatable({
    x = 0,
    y = 0,
    --- −1 faces left, +1 right. Flips with the direction of travel.
    facing = 1,
    size = size,
    reduced = reduced or function() return false end,
    state = "wander",
    --- The wander's own clock; advanced only while wandering so it resumes
    --- where it left off.
    phase = 0,
    --- How fast that clock runs: 1, or towards `CALM_TEMPO` for a reaching pointer.
    tempo = 1,
    calmed = false,
    --- The entrance under way: 0..1, or -1 once it is in.
    entry = -1,
    t = 0,
    held = 0,
    --- Where the caret was last seen, for peek and typing. `{x, y}` or nil.
    caret = nil,
    --- Where it settles while held.
    hold_at = { 0, 0 },
    placed = false,
    --- The zoom, chasing a target by state; 1 at rest.
    scale = 1,
    --- The eased part of the tilt: the bank into a turn.
    bank = 0,
    --- The rock while typing, applied straight: it is already a smooth wave.
    rock = 0,
    --- How far round a barrel roll has turned; 0 when level.
    spin = 0,
    --- A keystroke's kick, 1 on the key and dying away.
    pulse = 0,
    --- The roll's progress, 0..1, or -1 when level.
    rolling = -1,
    --- The flight under way, if any: where from, and how far along.
    flight = nil,
    --- Where it has just been, newest last, for the afterimages.
    trail = {},
    --- Where it has been lately, oldest first, each with its age, for the ribbon.
    wake = {},
    --- Set for one frame when a flight begins, and when one ends.
    took_off = false,
    landed = false,
    vx = 0,
    vy = 0,
  }, Sprite)
end

--- The tilt in radians: bank, rock and roll together. 0 at rest.
function Sprite:angle()
  return self.bank + self.rock + self.spin
end

--- The point the wander wants at its clock.
function Sprite:wander_point(box)
  local m = self.size * MARGIN
  local x, y, w, h = box[1], box[2], box[3], box[4]
  local cx, cy = x + w / 2, y + h / 2
  local rx = math.max(0, w / 2 - m)
  local ry = math.max(0, h / 2 - m)
  local p = self.phase
  return {
    cx + rx * math.sin((p / WANDER_X) * math.pi * 2),
    cy + ry * math.sin((p / WANDER_Y) * math.pi * 2 + 1.1),
  }
end

--- The corner it sits in under reduced motion, and where it starts.
function Sprite:rest_point(box)
  local m = self.size * MARGIN
  return { box[1] + box[3] - m, box[2] + m }
end

--- The seat beside the caret: a cell to the right and a little up.
function Sprite:seat(box, cell)
  local c = self.caret or self:rest_point(box)
  local m = self.size * MARGIN
  return {
    math.min(box[1] + box[3] - m, math.max(box[1] + m, c[1] + cell * 2.5 + self.size * 0.4)),
    math.min(box[2] + box[4] - m, math.max(box[2] + m, c[2] - self.size * 0.15)),
  }
end

--- Change state, and set off: every change of mind is a flight.
function Sprite:go(state)
  if self.state == state then return end
  self.state = state
  self.flight = nil
  self.depart = true
end

--- Go and look at the caret; nothing happens if there is none.
function Sprite:peek()
  if not self.caret or self.state ~= "wander" then return false end
  self:go("peek")
  self.held = 0
  return true
end

function Sprite:typing(on)
  if on then
    self:go("typing")
  elseif self.state == "typing" then
    self:go("wander")
  end
end

function Sprite:thinking(on)
  if on then
    self:go("thinking")
  elseif self.state == "thinking" then
    self:go("wander")
  end
end

--- Touched: stop, so the bubble can be read. Only an idle sprite holds — one
--- at work keeps working — and the stop is a braking curve, not a freeze: the
--- target is a little ahead along its motion and the follow eases it there.
--- Touched somewhere else, it flies off again. Returns whether it is held.
function Sprite:hold(on, box)
  if on then
    if self.state == "typing" or self.state == "thinking" then return false end
    if self.state == "hold" then return true end
    local m = self.size * MARGIN
    local hx = self.x + self.vx * HOLD_COAST
    local hy = self.y + self.vy * HOLD_COAST
    if box then
      hx = math.min(box[1] + box[3] - m, math.max(box[1] + m, hx))
      hy = math.min(box[2] + box[4] - m, math.max(box[2] + m, hy))
    end
    self.hold_at = { hx, hy }
    self.state = "hold"
    self.held = 0
    self.flight = nil
    self.depart = false
    return true
  end
  if self.state == "hold" then self:go("wander") end
  return false
end

--- Whether it is holding still for a reader.
function Sprite:holding()
  return self.state == "hold"
end

--- The pointer is moving: slow the wander so it can be caught.
function Sprite:calm(on)
  self.calmed = on and true or false
end

--- Just switched on: arrive huge and shrink to size.
function Sprite:enter()
  if self.reduced() then return end
  self.entry = 0
  self.scale = ENTRY_ZOOM
end

--- Whether the entrance is still playing.
function Sprite:entering()
  return self.entry >= 0
end

function Sprite:plan(to)
  local dist = math.sqrt((to[1] - self.x) ^ 2 + (to[2] - self.y) ^ 2)
  if dist < 2 then
    self.flight = nil
    return
  end
  local secs = math.min(FLIGHT_MAX, FLIGHT_MIN + dist * FLIGHT_PER_PX)
  self.flight = { from = { self.x, self.y }, to = to, t = 0, secs = secs }
  self.took_off = true
end

--- Whether a flight is under way.
function Sprite:flying()
  return self.flight ~= nil
end

--- A keystroke: the sprite squashes, stretches and zooms for a beat.
function Sprite:kick()
  self.pulse = 1
end

--- One full barrel roll, eased in and out, on top of whatever else the angle
--- is doing.
function Sprite:roll()
  if self.reduced() then return end
  if self.rolling < 0 then self.rolling = 0 end
end

--- Whether a roll is still turning.
function Sprite:rolling_now()
  return self.rolling >= 0
end

--- How fast it is going, in virtual pixels per second.
function Sprite:speed()
  return math.sqrt(self.vx * self.vx + self.vy * self.vy)
end

--- The target for this frame, by state.
function Sprite:target(box, cell)
  if self.reduced() then return self:rest_point(box) end
  if self.state == "wander" then
    return self:wander_point(box)
  elseif self.state == "hold" then
    return self.hold_at
  elseif self.state == "peek" or self.state == "typing" then
    return self:seat(box, cell)
  end
  local seat = self:seat(box, cell)
  local a = self.t * THINK_HZ * math.pi * 2
  return { seat[1] + math.cos(a) * THINK_R, seat[2] + math.sin(a) * THINK_R * 0.5 }
end

function Sprite:update(dt, box, cell)
  self.t = self.t + dt
  local tempo_target = self.calmed and CALM_TEMPO or 1
  self.tempo = self.tempo + (tempo_target - self.tempo) * (1 - math.exp(-CALM_EASE * dt))
  if self.state == "wander" then self.phase = self.phase + dt * self.tempo end
  if self.state == "peek" then
    self.held = self.held + dt
    if self.held >= PEEK_HOLD then self.state = "wander" end
  end
  local target = self:target(box, cell)
  local tx, ty = target[1], target[2]
  if not self.placed then
    local rest = self:rest_point(box)
    self.x, self.y = rest[1], rest[2]
    self.placed = true
  end
  local x0, y0 = self.x, self.y
  self.took_off = false
  self.landed = false
  if self.depart and not self.reduced() then
    self.depart = false
    self:plan({ tx, ty })
  end
  local dx = tx - self.x
  if self.flight then
    -- A flight: the in-out curve from where it set off to where it is going,
    -- the destination re-read every frame. A destination that jumped is a new
    -- flight from here.
    local f = self.flight
    if math.sqrt((tx - f.to[1]) ^ 2 + (ty - f.to[2]) ^ 2) > REPLAN_PX then
      self:plan({ tx, ty })
    else
      f.to = { tx, ty }
      f.t = math.min(1, f.t + dt / f.secs)
      local k = Ease.expInOut(f.t)
      self.x = f.from[1] + (f.to[1] - f.from[1]) * k
      self.y = f.from[2] + (f.to[2] - f.from[2]) * k
      if f.t >= 1 then
        self.flight = nil
        self.landed = true
      end
    end
  else
    -- At rest, or tracking: the exponential follow.
    local k = 1 - math.exp(-FOLLOW * dt)
    self.x = self.x + dx * k
    self.y = self.y + (ty - self.y) * k
  end
  if math.abs(dx) > 0.6 and not self.reduced() then self.facing = dx < 0 and -1 or 1 end
  -- Clamp to the box, whatever the target asked for.
  local m = self.size * MARGIN
  self.x = math.min(box[1] + box[3] - m, math.max(box[1] + m, self.x))
  self.y = math.min(box[2] + box[4] - m, math.max(box[2] + m, self.y))
  if dt > 0 then
    self.vx = (self.x - x0) / dt
    self.vy = (self.y - y0) / dt
  end
  self:carry(dt)
end

--- How it carries itself this frame: the zoom, the tilt, the pulse and the
--- afterimages. Everything chases a target exponentially, so a state change
--- starts fast and settles soft.
function Sprite:carry(dt)
  if self.reduced() then
    self.scale = 1
    self.bank = 0
    self.rock = 0
    self.spin = 0
    self.pulse = 0
    self.rolling = -1
    self.flight = nil
    self.entry = -1
    self.trail = {}
    self.wake = {}
    return
  end
  self.pulse = self.pulse * math.exp(-PULSE_DECAY * dt)
  if self.pulse < 0.005 then self.pulse = 0 end
  local ease = 1 - math.exp(-EASE * dt)
  -- The zoom: in while typing, a touch out while thinking, closer while held,
  -- breathing at rest.
  local target_scale
  if self.state == "typing" then
    target_scale = TYPING_ZOOM + PULSE_ZOOM * self.pulse
  elseif self.state == "thinking" then
    target_scale = 0.92
  elseif self.state == "hold" then
    target_scale = HOLD_ZOOM
  else
    target_scale = 1 + 0.035 * math.sin(self.t * 1.1)
  end
  if self.entry >= 0 then
    -- The entrance owns the zoom: an ease-out from huge, so the first frames
    -- are the fastest shrinking and the last are barely moving.
    self.entry = math.min(1, self.entry + dt / ENTRY_SECS)
    self.scale = ENTRY_ZOOM + (target_scale - ENTRY_ZOOM) * Ease.expOut(self.entry)
    if self.entry >= 1 then self.entry = -1 end
  else
    self.scale = self.scale + (target_scale - self.scale) * ease
  end
  -- The tilt, in three parts. The bank into a turn is eased. The rock while
  -- typing is a wave already and is applied straight, fading in and out with
  -- the state. The roll is spent at a fixed rate until it has gone all the way
  -- round, and a full turn is level again.
  local bank_target = 0
  if self.state ~= "typing" then
    bank_target = math.max(-BANK_MAX, math.min(BANK_MAX, -self.vx * BANK * self.facing))
  end
  self.bank = self.bank + (bank_target - self.bank) * ease
  if self.state == "typing" then
    self.rock = math.sin(self.t * ROCK_HZ * math.pi * 2) * ROCK * (0.6 + 0.4 * self.pulse)
  else
    self.rock = self.rock * (1 - ease)
  end
  if self.rolling >= 0 then
    self.rolling = math.min(1, self.rolling + dt / ROLL_SECS)
    self.spin = math.pi * 2 * Ease.expInOut(self.rolling) * self.facing
    if self.rolling >= 1 then
      self.rolling = -1
      self.spin = 0
    end
  end
  -- The afterimages: only while it is really moving.
  if self:speed() > TRAIL_SPEED then
    self.trail[#self.trail + 1] = { self.x, self.y }
    if #self.trail > TRAIL_MAX then table.remove(self.trail, 1) end
  elseif #self.trail > 0 then
    table.remove(self.trail, 1)
  end
  -- The wake: wherever it has flown lately, each point ageing out. Left
  -- whenever it is really moving — a wander leaves ribbon too, not only a
  -- flight — and gone a second after it stops.
  for _, p in ipairs(self.wake) do
    p.age = p.age + dt
  end
  while #self.wake > 0 and self.wake[1].age > WAKE_SECS do
    table.remove(self.wake, 1)
  end
  if self:speed() > WAKE_SPEED then
    self.wake[#self.wake + 1] = { x = self.x, y = self.y, age = 0 }
    if #self.wake > WAKE_MAX then table.remove(self.wake, 1) end
  end
end

--- The squash and stretch of the moment: `sx, sy` factors on top of `scale`.
function Sprite:squash()
  if self.reduced() then return 1, 1 end
  return 1 + SQUASH * self.pulse, 1 - SQUASH * self.pulse
end

--- The hover bob, in virtual pixels, at this moment.
function Sprite:bob()
  if self.reduced() then return 0 end
  local amp = (self.state == "typing" or self.state == "hold") and 1.5 or 3.5
  return math.sin(self.t * BOB_HZ * math.pi * 2) * amp
end

--- How hard the engine burns: 0..1, for the flame's length.
function Sprite:thrust()
  if self.reduced() then return 0.3 end
  if self.state == "thinking" then return 1 end
  if self.state == "typing" or self.state == "hold" then return 0.35 end
  return 0.6
end

M.Sprite = Sprite

return M
