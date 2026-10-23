-- Stretchable frames from `art/`: a nine-slice draw of a framed panel.
--
-- `ui_quiz_card`, `ui_quiz_choice` and `ui_plaque` were generated for this
-- (see their recipes in `art/prompts.toml`): a border of even width with
-- nothing in the middle of an edge, round a flat blank face. The four corners
-- are drawn at a fixed scale, the edges stretch along one axis, the face along
-- both — so a frame of any size keeps chunky corners instead of smeared ones.
--
-- Only the ink is sliced: the manifest's `box` is the frame's bounds inside
-- its transparent canvas, so the padding `process.py` leaves round a sprite
-- never shows up as a gap between the frame and the thing it frames.
--
-- `ArtFrame.draw` returns false when the image is missing and draws nothing,
-- so every caller keeps its own drawn fallback (usually `UI.panel`).

local Assets = require("src.assets")

local ArtFrame = {}

--- Source pixels from each edge of the ink box to the inside of the corner:
--- the measured border (14 / 9 / 12) plus the corner studs and rounding.
ArtFrame.SLICE = { ui_quiz_card = 18, ui_quiz_choice = 14, ui_plaque = 16 }

local cache = {}

local function quads_for(name, image)
  local q = cache[name]
  if q and q.image == image then return q end
  local iw, ih = image:getDimensions()
  local box = Assets.box[name]
  local x0, y0 = box and box.minx or 0, box and box.miny or 0
  local x1, y1 = box and (box.maxx + 1) or iw, box and (box.maxy + 1) or ih
  local sw, sh = x1 - x0, y1 - y0
  local c = math.min(ArtFrame.SLICE[name] or 8, math.floor(sw / 3), math.floor(sh / 3))
  local mw, mh = sw - 2 * c, sh - 2 * c
  local function quad(x, y, w, h) return love.graphics.newQuad(x, y, w, h, iw, ih) end
  q = {
    image = image, c = c, mw = mw, mh = mh,
    tl = quad(x0, y0, c, c), t = quad(x0 + c, y0, mw, c), tr = quad(x1 - c, y0, c, c),
    l = quad(x0, y0 + c, c, mh), m = quad(x0 + c, y0 + c, mw, mh), r = quad(x1 - c, y0 + c, c, mh),
    bl = quad(x0, y1 - c, c, c), b = quad(x0 + c, y1 - c, mw, c), br = quad(x1 - c, y1 - c, c, c),
  }
  cache[name] = q
  return q
end

--- Draw `name` nine-sliced to fill `(x, y, w, h)`.
---
--- `opts.scale` is screen pixels per source pixel for the corners (default
--- 1, so the frame's art pixel matches a 1x UI pixel); it shrinks on its own
--- when the box is too small for two corners. `opts.alpha` and `opts.color`
--- tint the whole frame; `opts.face = false` leaves the middle undrawn, for a
--- border laid over something that already has a fill.
function ArtFrame.draw(name, x, y, w, h, opts)
  opts = opts or {}
  local image = Assets.image(name)
  if not image or w <= 0 or h <= 0 then return false end
  local q = quads_for(name, image)
  local s = opts.scale or 1
  s = math.max(0.25, math.min(s, w / (2 * q.c + 1), h / (2 * q.c + 1)))
  local c = q.c * s
  local iw, ih = w - 2 * c, h - 2 * c
  local ex, ey = iw / q.mw, ih / q.mh

  love.graphics.setColor(opts.color or { 1, 1, 1, opts.alpha or 1 })
  local g = love.graphics
  g.draw(image, q.tl, x, y, 0, s, s)
  g.draw(image, q.t, x + c, y, 0, ex, s)
  g.draw(image, q.tr, x + w - c, y, 0, s, s)
  g.draw(image, q.l, x, y + c, 0, s, ey)
  if opts.face ~= false then g.draw(image, q.m, x + c, y + c, 0, ex, ey) end
  g.draw(image, q.r, x + w - c, y + c, 0, s, ey)
  g.draw(image, q.bl, x, y + h - c, 0, s, s)
  g.draw(image, q.b, x + c, y + h - c, 0, ex, s)
  g.draw(image, q.br, x + w - c, y + h - c, 0, s, s)
  love.graphics.setColor(1, 1, 1, 1)
  return true
end

return ArtFrame
