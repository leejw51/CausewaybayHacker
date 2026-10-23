-- Particles: LÖVE's own `ParticleSystem`, in a handful of presets.
--
-- `Fx.burst(x, y, "stars")` is a right answer, `"confetti"` a clear,
-- `"sparks"` a button press, `"smoke"` and `"shards"` a wrong one, `"coins"`
-- a node cleared on the map, `"embers"` a verdict that burned. `Fx.ambient
-- ("dust")` is the slow drift behind the title and the land picker. Scenes
-- call `burst`; `src/app.lua` calls `update` and `draw` once a frame, after
-- the scene, so a burst is always over the thing it came from.
--
-- **Headless-safe.** The module loads with no `love` at all — every entry
-- point is a no-op without a graphics context — because `tests/test_layout`
-- draws scenes under LÖVE while the headless suite requires them under a
-- bare luajit, and both have to get past `require("src.fx")`. It is *not*
-- in `make check-layering`'s list: it is allowed to touch `love`, it just
-- must not need it to be required.
--
-- Textures come from `Assets.image` (`fx_star`, `fx_confetti`, `fx_shards`,
-- `fx_dust`, `ui_coin`); a missing one falls back to a 2×2 white dot made
-- from `love.image`, not from `Assets`, so a scene drawn before
-- `Assets.load` still gets its sparks.

local Theme = require("src.theme")
local Assets = require("src.assets")
local Anim = require("src.anim")

local Fx = {}

--- How many burst systems may be alive at once; the oldest goes first.
Fx.MAX_LIVE = 24

local live = {}
local ambient = nil
local textures = {}

local function ready()
  return type(love) == "table" and love.graphics ~= nil
    and love.graphics.newParticleSystem ~= nil
end

Fx.ready = ready

local function dot(w, h)
  local key = ("__dot%dx%d"):format(w, h)
  if not textures[key] then
    local data = love.image.newImageData(w, h)
    data:mapPixel(function() return 1, 1, 1, 1 end)
    textures[key] = love.graphics.newImage(data)
  end
  return textures[key]
end

--- The image for `name`, or the dot when it is missing; `quad` is the
--- first frame of a strip, so a four-frame dust sheet is one puff.
local function texture(name)
  if not name then return dot(2, 2), nil end
  local image = Assets.image(name)
  if not image then return dot(2, 2), nil end
  local strip = Assets.strip and Assets.strip[name]
  if strip and strip.fw then
    local iw, ih = image:getDimensions()
    return image, love.graphics.newQuad(0, 0, strip.fw, strip.fh, iw, ih)
  end
  local iw, ih = image:getDimensions()
  if iw >= ih * 3 then
    -- A strip without a manifest entry: assume square frames.
    return image, love.graphics.newQuad(0, 0, ih, ih, iw, ih)
  end
  return image, nil
end

local function fade(c, a)
  return { c[1], c[2], c[3], a }
end

--- The presets. Speeds in px/s, lives in s, sizes as multiples of the
--- texture, `accel` the gravity, `spin` in rad/s. `dir` is the centre of
--- the cone (`-pi/2` is up) and `spread` its width.
local PRESETS = {
  confetti = {
    tex = "fx_confetti", n = 48, life = { 0.9, 1.5 }, speed = { 180, 420 },
    dir = -math.pi / 2, spread = math.pi * 2, accel = { 0, 620 }, damping = 1.2,
    spin = { -9, 9 }, sizes = { 1.0, 0.9, 0.4 },
    colors = { Theme.gold, Theme.text, Theme.blue, Theme.green, Theme.redA },
  },
  stars = {
    tex = "fx_star", n = 14, life = { 0.45, 0.9 }, speed = { 120, 280 },
    dir = -math.pi / 2, spread = math.pi * 2, accel = { 0, 160 },
    spin = { -3, 3 }, sizes = { 0.5, 0.8, 0 },
    colors = { Theme.gold, Theme.text, fade(Theme.gold, 0) },
  },
  sparks = {
    tex = nil, n = 10, life = { 0.18, 0.42 }, speed = { 160, 340 },
    dir = -math.pi / 2, spread = math.pi * 2, accel = { 0, 520 },
    sizes = { 3, 2, 0 }, colors = { Theme.text, Theme.gold, fade(Theme.gold, 0) },
  },
  smoke = {
    tex = "fx_dust", n = 10, life = { 0.6, 1.1 }, speed = { 20, 70 },
    dir = -math.pi / 2, spread = 1.3, accel = { 0, -40 },
    spin = { -0.6, 0.6 }, sizes = { 0.4, 1.0, 1.4 },
    colors = { fade(Theme.mute, 0.7), fade(Theme.mute, 0.35), fade(Theme.mute, 0) },
  },
  coins = {
    tex = "ui_coin", n = 10, life = { 0.8, 1.2 }, speed = { 220, 380 },
    dir = -math.pi / 2, spread = 1.1, accel = { 0, 720 },
    spin = { -6, 6 }, sizes = { 0.7, 0.7, 0.5 }, colors = { Theme.text, fade(Theme.text, 0) },
  },
  embers = {
    tex = nil, n = 18, life = { 0.9, 1.8 }, speed = { 20, 80 },
    dir = -math.pi / 2, spread = 0.9, accel = { 0, -30 },
    sizes = { 3, 2, 0 }, colors = { Theme.redA, Theme.gold, fade(Theme.redA, 0) },
  },
  shards = {
    tex = "fx_shards", n = 8, life = { 0.5, 0.9 }, speed = { 160, 340 },
    dir = -math.pi / 2, spread = math.pi * 2, accel = { 0, 720 },
    spin = { -10, 10 }, sizes = { 0.5, 0.5, 0.3 }, colors = { Theme.text, fade(Theme.mute, 0) },
  },
}

Fx.PRESETS = PRESETS

local function configure(ps, p, opts)
  ps:setParticleLifetime(p.life[1], p.life[2])
  ps:setSpeed(p.speed[1] * (opts.speed or 1), p.speed[2] * (opts.speed or 1))
  ps:setDirection(opts.dir or p.dir or -math.pi / 2)
  ps:setSpread(opts.spread or p.spread or math.pi * 2)
  ps:setLinearAcceleration(0, 0, p.accel[1], p.accel[2])
  if p.damping then ps:setLinearDamping(p.damping, p.damping) end
  if p.spin then ps:setSpin(p.spin[1], p.spin[2]) end
  ps:setRotation(0, math.pi * 2)
  local s = opts.scale or 1
  local sizes = {}
  for i, v in ipairs(p.sizes) do sizes[i] = v * s end
  ps:setSizes(unpack(sizes))
  ps:setSizeVariation(0.3)
  local colors = opts.color and { opts.color, fade(opts.color, 0) } or p.colors
  local flat = {}
  for _, c in ipairs(colors) do
    flat[#flat + 1] = c[1]; flat[#flat + 1] = c[2]; flat[#flat + 1] = c[3]; flat[#flat + 1] = c[4] or 1
  end
  ps:setColors(unpack(flat))
end

--- A burst of `kind` at `(x, y)`. `opts.n` scales the count, `opts.scale`
--- the size, `opts.color` replaces the palette, `opts.dir`/`opts.spread`
--- the cone, `opts.area = { w, h }` spreads the origin over a box (confetti
--- raining from a ribbon). Returns the system, or nil headless.
function Fx.burst(x, y, kind, opts)
  if not ready() then return nil end
  opts = opts or {}
  local p = PRESETS[kind] or PRESETS.sparks
  local n = math.max(1, math.floor(p.n * (opts.n or 1) + 0.5))
  local image, quad = texture(p.tex)
  local ps = love.graphics.newParticleSystem(image, n)
  if quad then ps:setQuads(quad) end
  configure(ps, p, opts)
  ps:setPosition(x, y)
  if opts.area then ps:setEmissionArea("uniform", opts.area[1] / 2, opts.area[2] / 2) end
  ps:emit(n)
  live[#live + 1] = { ps = ps, ttl = p.life[2] + 0.1, kind = kind }
  while #live > Fx.MAX_LIVE do table.remove(live, 1) end
  return ps
end

--- The ambient emitters: a canvas-wide system that never stops.
local AMBIENT = {
  dust = function(ps, w, h)
    ps:setParticleLifetime(5, 10)
    ps:setEmissionRate(math.max(2, (w * h) / 90000))
    ps:setSpeed(6, 18)
    ps:setDirection(-math.pi / 2 + 0.5)
    ps:setSpread(0.8)
    ps:setSizes(2, 3, 2, 0)
    ps:setSizeVariation(0.6)
    ps:setColors(1, 1, 1, 0, 1, 1, 1, 0.28, 1, 1, 1, 0.18, 1, 1, 1, 0)
    ps:setEmissionArea("uniform", w / 2, h / 2)
  end,
  neon = function(ps, w, h)
    ps:setParticleLifetime(0.3, 0.9)
    ps:setEmissionRate(math.max(3, (w * h) / 60000))
    ps:setSpeed(0, 4)
    ps:setSizes(0, 2, 0)
    ps:setColors(Theme.gold[1], Theme.gold[2], Theme.gold[3], 0,
      Theme.blue[1], Theme.blue[2], Theme.blue[3], 0.5,
      Theme.text[1], Theme.text[2], Theme.text[3], 0)
    ps:setEmissionArea("uniform", w / 2, h / 2)
  end,
  rain = function(ps, w, h)
    ps:setParticleLifetime(0.6, 1.0)
    ps:setEmissionRate(math.max(10, w / 6))
    ps:setSpeed(900, 1200)
    ps:setDirection(math.pi / 2 + 0.08)
    ps:setSpread(0.04)
    ps:setSizes(1, 1)
    ps:setColors(Theme.text[1], Theme.text[2], Theme.text[3], 0.16,
      Theme.text[1], Theme.text[2], Theme.text[3], 0.06)
    ps:setEmissionArea("uniform", w / 2 + 60, 4)
    ps:setPosition(w / 2, -8)
    return true -- positioned itself
  end,
}

--- Start (or switch to) the ambient `kind` over a canvas `w × h`; `nil`
--- turns it off. The system is rebuilt when the canvas changes shape.
function Fx.ambient(kind, w, h)
  if not ready() then return end
  if not kind or not AMBIENT[kind] then ambient = nil; return end
  if ambient and ambient.kind == kind and ambient.w == w and ambient.h == h then return end
  local image = kind == "rain" and dot(1, 10) or dot(2, 2)
  local ps = love.graphics.newParticleSystem(image, 400)
  local placed = AMBIENT[kind](ps, w, h)
  if not placed then ps:setPosition(w / 2, h / 2) end
  ps:start()
  -- Warm it up so the first frame is not empty.
  for _ = 1, 40 do ps:update(0.1) end
  ambient = { ps = ps, kind = kind, w = w, h = h }
end

function Fx.ambientKind()
  return ambient and ambient.kind or nil
end

function Fx.update(dt)
  if not ready() then return end
  -- Pinned clock, pinned particles: a drive screenshot is the same picture
  -- across runs, as far as a random system can be.
  if Anim.frozen() then return end
  local keep = {}
  for _, entry in ipairs(live) do
    entry.ps:update(dt)
    entry.ttl = entry.ttl - dt
    if entry.ttl > 0 and (entry.ps:getCount() > 0 or entry.ttl > 0.05) then
      keep[#keep + 1] = entry
    end
  end
  live = keep
  if ambient then ambient.ps:update(dt) end
end

--- The bursts, over everything.
function Fx.draw()
  if not ready() then return end
  love.graphics.setColor(1, 1, 1, 1)
  for _, entry in ipairs(live) do
    love.graphics.draw(entry.ps)
  end
end

--- The ambient drift, under a scene's cards: the scene calls this right
--- after its backdrop.
function Fx.drawAmbient()
  if not ready() or not ambient then return end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(ambient.ps)
end

function Fx.count()
  return #live
end

function Fx.clear()
  live = {}
  ambient = nil
end

return Fx
