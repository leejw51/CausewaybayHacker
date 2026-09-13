-- Small bursts, thrown at a point on the screen.
--
-- ANSWER mode needs something to happen where a mistake is, and the whole of
-- what it needs is: a dozen squares thrown outwards, easing to a stop and then
-- falling, fading as they go. The browser client has a particle engine and a
-- confetti planner for its result screen; this is the same idea at the size
-- this client actually uses it, in one file, with no dependencies beyond the
-- clock the scene already keeps.
--
-- **A particle's position is a function of its age**, not something integrated
-- between frames. That is what makes a burst look the same on a 60 Hz panel
-- and a 144 Hz one, and it is why `update` only advances a clock.

local Sparks = {}
Sparks.__index = Sparks

--- How long the longest particle lives. Nothing is kept past this.
local LIFE = 1.25

function Sparks.new()
  return setmetatable({ t = 0, bursts = {} }, Sparks)
end

--- `n` squares in `color`, from `(x, y)`.
---
--- `n` is the whole dial: ten is "you typed a character that is not the
--- answer", seventy is "you have typed the entire thing, exactly".
function Sparks:add(x, y, n, color)
  local parts = {}
  for i = 1, n do
    local angle = math.random() * math.pi * 2
    local reach = 40 + math.random() * 110 * math.sqrt(math.max(0.6, n / 24))
    parts[i] = {
      x = x,
      y = y,
      dx = math.cos(angle) * reach,
      dy = math.sin(angle) * reach - 30,
      size = 2 + math.random() * 4,
      life = 0.5 + math.random() * (LIFE - 0.5),
      delay = math.random() * 0.05,
      gravity = 150 + math.random() * 120,
    }
  end
  self.bursts[#self.bursts + 1] = {
    born = self.t,
    color = color,
    parts = parts,
    -- The ring is what makes a burst read as *one event* rather than as a
    -- handful of dots that happen to have started together.
    ring = 10 + n * 0.6,
  }
  -- A cap, not a queue: a player typing fast can ask for one per keystroke,
  -- and what matters on screen is the last few.
  if #self.bursts > 8 then table.remove(self.bursts, 1) end
end

function Sparks:update(dt)
  self.t = self.t + dt
  -- Drop what has finished, so an idle screen costs nothing.
  for i = #self.bursts, 1, -1 do
    if self.t - self.bursts[i].born > LIFE + 0.1 then table.remove(self.bursts, i) end
  end
end

function Sparks:clear()
  self.bursts = {}
end

function Sparks:draw()
  for _, b in ipairs(self.bursts) do
    local age = self.t - b.born
    local c = b.color
    if age < 0.45 then
      local u = age / 0.45
      love.graphics.setColor(c[1], c[2], c[3], (1 - u) * 0.55)
      love.graphics.setLineWidth(math.max(1, 3 * (1 - u)))
      love.graphics.circle("line", b.parts[1] and b.parts[1].x or 0,
        b.parts[1] and b.parts[1].y or 0, b.ring * (1 - (1 - u) * (1 - u)), 24)
      love.graphics.setLineWidth(1)
    end
    for _, p in ipairs(b.parts) do
      local a = age - p.delay
      if a > 0 and a < p.life then
        local u = a / p.life
        -- Ease out along the throw, then gravity on top of it.
        local out = 1 - (1 - u) * (1 - u) * (1 - u)
        local x = p.x + p.dx * out
        local y = p.y + p.dy * out + 0.5 * p.gravity * a * a
        love.graphics.setColor(c[1], c[2], c[3], math.max(0, 1 - u * u))
        love.graphics.rectangle("fill", x - p.size / 2, y - p.size / 2, p.size, p.size)
      end
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return Sparks
