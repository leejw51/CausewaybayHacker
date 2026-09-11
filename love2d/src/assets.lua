-- Fonts and images, loaded once and never at draw time.
--
-- ## Two sources, in order
--
-- 1. **`art/`**, at the root of this repository — the 32 assets PM generated,
--    listed in `art/manifest.json` in `CausewaybayGolang`'s shape, with a
--    measured `box` on every sprite. This is the real art and it wins.
-- 2. **`love2d/assets/`** — the placeholder set copied from
--    `CausewaybayGolang/love2d/assets/`, still there for the handful of names
--    `art/` does not carry (`fx_star`, `fx_confetti`, `ui_coin`,
--    `sprite_clerk`, `bg_flat`). Those are JPEGs on a magenta screen with no
--    alpha channel, so they go through `knockout`.
--
-- **The `art/` assets are pre-processed to binary alpha and must not go
-- through `knockout`.** Flooding a correctly-cut sprite would eat any dark
-- pixel connected to the border, and on `node_locked` — a padlock with a
-- black outline — that is the padlock.
--
-- ## Reading `art/`
--
-- `love.filesystem` is rooted at the game directory and cannot see `../art`,
-- so the loader tries, in order: `art/…` inside the game (where a packaged
-- build would carry a copy), then the real path `<source>/../art/…` through
-- plain `io.open`, wrapped in a `FileData`. `art/` is this repository's own
-- directory, not another project's, and it is static.
--
-- Every name is *optional*. A missing file is a nil texture and a scene that
-- draws a coloured rectangle instead: placeholder art going missing should
-- not stop a player from finishing a quest.

local Theme = require("src.theme")
local json = require("src.json")

local A = { images = {}, box = {}, strip = {}, quads = {}, fonts = {},
  missing = {}, sources = {} }

-- Placeholder files under `love2d/assets/`. A name here is used only when
-- `art/manifest.json` does not carry it.
local PLACEHOLDERS = {
  bg_flat = "assets/bg_flat.png",
  bg_night = "assets/bg_night.png",
  sprite_clerk = "assets/sprite_clerk.png",
  fx_star = "assets/fx_star.png",
  fx_confetti = "assets/fx_confetti.png",
  ui_coin = "assets/ui_coin.png",
  -- Kept as a fallback for `map_rust` / `map_go` if `art/` is not readable.
  map_bg = "assets/map_bg.png",
  map_bg_p = "assets/map_bg_p.png",
}

-- The placeholders that need the magenta screen flooded out. Nothing from
-- `art/` is in this list, and nothing from `art/` ever should be.
local KNOCKOUT = {
  sprite_clerk = true, fx_star = true, fx_confetti = true, ui_coin = true,
}

local FONT_FILE = "assets/fonts/PressStart2P-Regular.ttf"
local MONO_FILE = "assets/fonts/VT323-Regular.ttf"

-- ------------------------------------------------------------------ knockout

--- Flood the background out of a sprite, from the edges inward.
---
--- The placeholder sprites carried over from `CausewaybayGolang/love2d/assets`
--- are JPEGs — no alpha channel at all — drawn on a magenta screen. Blitted
--- as they are, a sprite arrives sitting on a hot-pink rectangle.
---
--- Ported from that repo's `src/assets.lua`. Flooding from the edges rather
--- than testing every pixel is the point: a magenta pixel *inside* the sprite
--- is part of the art and must survive, and only background connected to the
--- border is a background.
local function knockout(data)
  local w, h = data:getWidth(), data:getHeight()
  local function is_bg(x, y)
    local r, g, b, a = data:getPixel(x, y)
    if a < 0.12 then return true end
    if r > 0.55 and b > 0.30 and g < 0.45 and b < r + 0.2 then return true end
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

-- --------------------------------------------------------------- art/ files

--- Where `art/` is on disk, from the game's own source directory.
local function art_root()
  local source = love.filesystem.getSource()
  if not source or source == "" then return nil end
  -- The game may be a directory or a .love; only the directory case can have
  -- a sibling `art/`.
  return source .. "/../art"
end

A.art_root = art_root

--- Read a file from `art/`, whichever of the two places it is in.
---
--- Returns the bytes, or nil. `love.filesystem` first so a packaged build
--- that carries `art/` inside the archive needs no special case.
local function read_art(name)
  if love.filesystem.getInfo("art/" .. name) then
    return love.filesystem.read("art/" .. name), "love.filesystem"
  end
  local root = art_root()
  if not root then return nil end
  local fh = io.open(root .. "/" .. name, "rb")
  if not fh then return nil end
  local bytes = fh:read("*a")
  fh:close()
  return bytes, root
end

A.read_art = read_art

local function image_from_bytes(bytes, name)
  local ok, image = pcall(function()
    local file_data = love.filesystem.newFileData(bytes, name)
    return love.graphics.newImage(file_data)
  end)
  if not ok then return nil end
  return image
end

--- Load everything `art/manifest.json` lists. Returns how many landed.
function A.load_art()
  local body, where = read_art("manifest.json")
  if not body then
    A.art_where = nil
    return 0
  end
  local manifest = json.try_decode(body)
  if type(manifest) ~= "table" or type(manifest.art) ~= "table" then
    A.art_where = nil
    return 0
  end
  A.art_where = where

  local loaded = 0
  for _, entry in ipairs(manifest.art) do
    local name, file = entry.name, entry.file
    if type(name) == "string" and type(file) == "string" then
      local bytes = read_art(file)
      local image = bytes and image_from_bytes(bytes, file)
      if image then
        -- Nearest everywhere: this is pixel art and a linear filter is what
        -- turns it into mush at 1.5×.
        image:setFilter("nearest", "nearest")
        A.images[name] = image
        A.sources[name] = "art/" .. file
        -- `box` places a sprite on its feet rather than on the corner of its
        -- transparent canvas. Measured by `art/tools/manifest.py` from the
        -- actual alpha, so it is not a guess and is not re-derived here.
        if type(entry.box) == "table" then A.box[name] = entry.box end
        -- A strip carries `boxes` (plural, one per frame) instead of `box`,
        -- and reading `box` on one of those gets nil. Both are kept, and
        -- `A.frames` records the cell geometry so nothing has to re-derive
        -- it from the image width.
        if type(entry.boxes) == "table" and entry.frames then
          A.strip[name] = {
            frames = entry.frames,
            fw = entry.fw or math.floor(entry.w / entry.frames),
            fh = entry.fh or entry.h,
            boxes = entry.boxes,
          }
          -- All four cells share their ink extents (the cutter normalises
          -- each figure into its cell), so frame 1's box is the strip's box
          -- and aligning on the cell gives no jitter between frames.
          A.box[name] = A.box[name] or entry.boxes[1]
        end
        loaded = loaded + 1
      else
        A.missing[name] = "art/" .. file
      end
    end
  end
  return loaded
end

-- ---------------------------------------------------------------- the loader

function A.load()
  love.graphics.setDefaultFilter("nearest", "nearest")
  local from_art = A.load_art()

  for name, path in pairs(PLACEHOLDERS) do
    if not A.images[name] then
      if love.filesystem.getInfo(path) then
        local ok, image = pcall(function()
          if KNOCKOUT[name] then
            return love.graphics.newImage(knockout(love.image.newImageData(path)))
          end
          return love.graphics.newImage(path)
        end)
        if ok and image then
          image:setFilter("nearest", "nearest")
          A.images[name] = image
          A.sources[name] = path
        else
          A.missing[name] = path
        end
      else
        A.missing[name] = path
      end
    end
  end

  print(("assets: %d from %s, %d placeholders")
    :format(from_art, tostring(A.art_where or "art/ (not found)"),
      A.count() - from_art))
end

function A.count()
  local n = 0
  for _ in pairs(A.images) do n = n + 1 end
  return n
end

-- --------------------------------------------------------------------- fonts

--- A Press Start 2P face at `size`, cached.
---
--- Press Start 2P is the game's voice and is used for every label. The code
--- editor uses `A.mono` instead, because a player has to read their own
--- program in it and an 8×8 pixel face at 11px is not that.
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

-- ------------------------------------------------------------------ drawing

function A.image(name)
  return A.images[name]
end

--- The first of `names` that exists, so a caller can name the real asset and
--- its fallback in one place.
function A.pick(...)
  for _, name in ipairs({ ... }) do
    if A.images[name] then return name end
  end
  return nil
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

--- Draw an image centred in a box at the largest scale that fits.
function A.fit(name, x, y, w, h, max_scale)
  local image = A.images[name]
  if not image then return false end
  local iw, ih = image:getDimensions()
  local s = math.min(w / iw, h / ih, max_scale or 8)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(image, x + (w - iw * s) / 2, y + (h - ih * s) / 2, 0, s, s)
  return true
end

--- Draw a sprite standing on `(x, y)`, using its measured `box`.
---
--- This is the whole reason `box` is in the manifest: `feet` is the row the
--- ink stands on and `cx` its horizontal centre of mass, so a character is
--- placed by where she touches the ground rather than by the corner of a
--- transparent canvas. `height` is the ink height wanted on screen, so two
--- sprites asked for the same height *look* the same height even when one has
--- more empty canvas above it than the other.
function A.sprite(name, x, y, height, opts)
  opts = opts or {}
  local image = A.images[name]
  if not image then return false end
  local iw, ih = image:getDimensions()
  local box = A.box[name]
  local ink = (box and box.h and box.h > 0) and box.h or ih
  local s = (height or ih) / ink
  local ox = box and box.cx or (iw * 0.5)
  local oy = box and box.feet or ih
  love.graphics.setColor(opts.color or { 1, 1, 1, opts.alpha or 1 })
  love.graphics.draw(image, x, y, opts.rotation or 0,
    (opts.flip and -s or s), s, ox, oy)
  love.graphics.setColor(1, 1, 1, 1)
  return true
end

--- One frame of a sprite strip, standing on `(x, y)`.
---
--- `frame` is 1-based and wraps, so a caller can hand it a raw animation
--- counter. Placement is by the frame's own `boxes[i]` — the same `feet` and
--- `cx` idea as `A.sprite`, per cell.
function A.frame(name, index, x, y, height, opts)
  opts = opts or {}
  local image = A.images[name]
  local strip = A.strip[name]
  if not (image and strip) then return false end

  index = ((math.floor(index) - 1) % strip.frames) + 1
  local quads = A.quads[name]
  if not quads then
    quads = {}
    local iw, ih = image:getDimensions()
    for i = 1, strip.frames do
      quads[i] = love.graphics.newQuad((i - 1) * strip.fw, 0, strip.fw, strip.fh, iw, ih)
    end
    A.quads[name] = quads
  end

  local box = strip.boxes[index] or strip.boxes[1]
  local ink = (box and box.h and box.h > 0) and box.h or strip.fh
  local s = (height or strip.fh) / ink
  local ox = box and box.cx or (strip.fw * 0.5)
  local oy = box and box.feet or strip.fh
  love.graphics.setColor(opts.color or { 1, 1, 1, opts.alpha or 1 })
  love.graphics.draw(image, quads[index], x, y, opts.rotation or 0,
    (opts.flip and -s or s), s, ox, oy)
  love.graphics.setColor(1, 1, 1, 1)
  return true
end

function A.frames(name)
  local strip = A.strip[name]
  return strip and strip.frames or 0
end

--- Draw a marker centred on `(x, y)` at `size` pixels across — for the map's
--- node art, which is square and wants its middle on the path, not its feet.
function A.marker(name, x, y, size, opts)
  opts = opts or {}
  local image = A.images[name]
  if not image then return false end
  local iw, ih = image:getDimensions()
  local s = size / math.max(iw, ih)
  love.graphics.setColor(opts.color or { 1, 1, 1, opts.alpha or 1 })
  love.graphics.draw(image, x, y, 0, s, s, iw * 0.5, ih * 0.5)
  love.graphics.setColor(1, 1, 1, 1)
  return true
end

return A
