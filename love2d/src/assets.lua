-- Fonts and images, loaded once and never at draw time.
--
-- The art is placeholder, copied into `love2d/assets/` from
-- `CausewaybayGolang/love2d/assets/` per `docs/art.md` §4–§7, which lists
-- which sibling asset stands in for which of this game's. Nothing is loaded
-- from another repository at runtime: a game that reaches outside its own
-- directory is a game that only runs on the machine it was written on.
--
-- Every name here is *optional*. A missing file is a nil texture and a scene
-- that draws a coloured rectangle instead, because a placeholder art pack
-- going missing should not stop a player from finishing a quest.

local Theme = require("src.theme")

local A = { images = {}, fonts = {}, missing = {} }

-- name -> file. The names are this game's (art.md §4.1's left column); the
-- files are the stand-ins.
local IMAGES = {
  title_bg = "assets/title_bg.png",
  title_bg_p = "assets/title_bg_p.png",
  map_bg = "assets/map_bg.png",
  map_bg_p = "assets/map_bg_p.png",
  bg_street = "assets/bg_street.png",
  bg_times = "assets/bg_times.png",
  bg_mtr = "assets/bg_mtr.png",
  bg_flat = "assets/bg_flat.png",
  bg_night = "assets/bg_night.png",
  sprite_mei = "assets/sprite_mei.png",       -- the player (docs/story.md §1)
  sprite_alex = "assets/sprite_hero.png",     -- stand-in, art.md §4.1
  sprite_ferris = "assets/sprite_ferris.png",
  sprite_gogo = "assets/sprite_gogo.png",
  sprite_clerk = "assets/sprite_clerk.png",
  stamp_cleared = "assets/stamp_served.png",  -- stand-in until art.md §7 lands
  fx_ribbon = "assets/fx_ribbon.png",
  fx_medal = "assets/fx_medal.png",
  fx_star = "assets/fx_star.png",
  fx_confetti = "assets/fx_confetti.png",
  ui_panel = "assets/ui_panel.png",
  ui_coin = "assets/ui_coin.png",
}

-- Sprites and effects are cut out of their background; full-bleed plates are
-- not. See `knockout` below for why this list exists at all.
local KNOCKOUT = {
  sprite_mei = true, sprite_alex = true, sprite_ferris = true,
  sprite_gogo = true, sprite_clerk = true, stamp_cleared = true,
  fx_ribbon = true, fx_medal = true, fx_star = true, fx_confetti = true,
  ui_panel = true, ui_coin = true,
}

local FONT_FILE = "assets/fonts/PressStart2P-Regular.ttf"
local MONO_FILE = "assets/fonts/VT323-Regular.ttf"

--- Flood the background out of a sprite, from the edges inward.
---
--- The placeholder sprites carried over from `CausewaybayGolang/love2d/assets`
--- are JPEGs — no alpha channel at all — drawn on a magenta screen. Blitted
--- as they are, Ferris arrives sitting on a hot-pink rectangle, which is
--- exactly what the first screenshot of the login screen showed.
---
--- Ported from that repo's `src/assets.lua`. Flooding from the edges rather
--- than testing every pixel is the point: a magenta pixel *inside* the sprite
--- (an eye highlight, a sign) is part of the art and must survive, and only
--- background connected to the border is a background.
local function knockout(data)
  local w, h = data:getWidth(), data:getHeight()
  local function is_bg(x, y)
    local r, g, b, a = data:getPixel(x, y)
    if a < 0.12 then return true end
    -- The magenta screen. A JPEG round trip drags it toward hot pink, so the
    -- test is generous rather than exact.
    if r > 0.55 and b > 0.30 and g < 0.45 and b < r + 0.2 then return true end
    -- And the lime some of the older plates used.
    if g > 0.62 and r < 0.50 and b < 0.50 then return true end
    return false
  end

  local seen = {}
  local qx, qy, tail, head = {}, {}, 0, 1
  local function push(x, y)
    if x < 0 or y < 0 or x >= w or y >= h then return end
    local k = y * w + x
    if seen[k] then return end
    if not is_bg(x, y) then return end
    seen[k] = true
    tail = tail + 1
    qx[tail], qy[tail] = x, y
  end

  for x = 0, w - 1 do push(x, 0); push(x, h - 1) end
  for y = 0, h - 1 do push(0, y); push(w - 1, y) end

  while head <= tail do
    local x, y = qx[head], qy[head]
    head = head + 1
    data:setPixel(x, y, 0, 0, 0, 0)
    push(x + 1, y); push(x - 1, y); push(x, y + 1); push(x, y - 1)
  end
  return data
end

A.knockout = knockout

function A.load()
  love.graphics.setDefaultFilter("nearest", "nearest")
  for name, path in pairs(IMAGES) do
    if love.filesystem.getInfo(path) then
      local ok, image = pcall(function()
        if KNOCKOUT[name] then
          local data = love.image.newImageData(path)
          return love.graphics.newImage(knockout(data))
        end
        return love.graphics.newImage(path)
      end)
      if ok and image then
        image:setFilter("nearest", "nearest")
        A.images[name] = image
      else
        A.missing[name] = path
      end
    else
      A.missing[name] = path
    end
  end
end

--- A Press Start 2P face at `size`, cached.
---
--- Press Start 2P has no CJK coverage and no lowercase kerning to speak of;
--- it is the game's voice and it is used for every label. The code editor
--- uses `A.mono` instead, because a player has to read their own program in
--- it and an 8×8 pixel face at 11px is not that.
function A.font(size)
  size = math.max(6, math.floor(size))
  local key = "p" .. size
  if not A.fonts[key] then
    if love.filesystem.getInfo(FONT_FILE) then
      A.fonts[key] = love.graphics.newFont(FONT_FILE, size)
    else
      A.fonts[key] = love.graphics.newFont(size)
    end
    A.fonts[key]:setFilter("nearest", "nearest")
  end
  return A.fonts[key]
end

--- The editor face: VT323, a terminal font that is still a pixel font.
function A.mono(size)
  size = math.max(8, math.floor(size))
  local key = "m" .. size
  if not A.fonts[key] then
    if love.filesystem.getInfo(MONO_FILE) then
      A.fonts[key] = love.graphics.newFont(MONO_FILE, size)
    else
      A.fonts[key] = love.graphics.newFont(size)
    end
    A.fonts[key]:setFilter("nearest", "nearest")
  end
  return A.fonts[key]
end

function A.image(name)
  return A.images[name]
end

--- Draw an image to cover `w × h`, cropped rather than squashed.
function A.cover(name, x, y, w, h, tint)
  local image = A.images[name]
  if not image then
    love.graphics.setColor(tint or Theme.navy)
    love.graphics.rectangle("fill", x, y, w, h)
    love.graphics.setColor(1, 1, 1, 1)
    return false
  end
  local iw, ih = image:getDimensions()
  local s = math.max(w / iw, h / ih)
  local dx = x + (w - iw * s) / 2
  local dy = y + (h - ih * s) / 2
  love.graphics.setScissor(x, y, w, h)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(image, dx, dy, 0, s, s)
  love.graphics.setScissor()
  return true
end

--- Draw an image centred in a box at the largest whole-pixel scale that fits.
function A.fit(name, x, y, w, h, max_scale)
  local image = A.images[name]
  if not image then return false end
  local iw, ih = image:getDimensions()
  local s = math.min(w / iw, h / ih, max_scale or 8)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(image, x + (w - iw * s) / 2, y + (h - ih * s) / 2, 0, s, s)
  return true
end

return A
