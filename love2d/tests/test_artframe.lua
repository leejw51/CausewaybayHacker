-- `src/artframe.lua`, the nine-slice frames, under a real graphics context.
--
-- What is checked is what was drawn: `love.graphics.draw` is watched for the
-- length of one `ArtFrame.draw`, and every piece's quad and its place on the
-- screen are read back. So the case is about the frame on the screen and not
-- about a table inside the module.
--
--   * no image, or no room: nothing is drawn and the answer is false, so the
--     caller's own `UI.panel` is what shows;
--   * every slice is cut from inside the manifest's ink `box`, so the
--     transparent padding round a sprite never shows as a gap;
--   * the nine pieces cover the rectangle asked for, exactly, without
--     overlapping, at any size and any corner scale.

local T = require("tests.framework")

local FRAMES = { "ui_quiz_card", "ui_quiz_choice", "ui_plaque" }

--- Run `fn` with `love.graphics.draw` recorded rather than drawn.
local function watch(fn)
  local real = love.graphics.draw
  local seen = {}
  love.graphics.draw = function(image, quad, x, y, r, sx, sy)
    seen[#seen + 1] = { image = image, quad = quad, x = x, y = y, sx = sx or 1, sy = sy or sx or 1 }
  end
  local ok, result = pcall(fn)
  love.graphics.draw = real
  if not ok then error(result, 0) end
  return result, seen
end

return function()
  local Assets = require("src.assets")
  local ArtFrame = require("src.artframe")
  if not Assets.image(FRAMES[1]) then Assets.load() end

  T.section("art frames — a nine-slice, or nothing")

  T.case("a missing image, or no room, draws nothing and says so", function()
    local drawn, seen = watch(function()
      return ArtFrame.draw("no_such_frame", 10, 10, 200, 100)
    end)
    T.eq(drawn, false, "an image that is not there")
    T.eq(#seen, 0, "and nothing was drawn for it")
    for _, size in ipairs({ { 0, 40 }, { 40, 0 }, { -5, 40 } }) do
      drawn, seen = watch(function()
        return ArtFrame.draw("ui_plaque", 0, 0, size[1], size[2])
      end)
      T.eq(drawn, false, ("a %dx%d box"):format(size[1], size[2]))
      T.eq(#seen, 0)
    end
  end)

  T.case("every frame is in the manifest, with a box, and loaded", function()
    for _, name in ipairs(FRAMES) do
      T.ok(Assets.image(name) ~= nil, name .. " is loaded from art/")
      T.ok(type(Assets.box[name]) == "table", name .. " has an ink box")
      T.ok(ArtFrame.SLICE[name], name .. " has a measured slice")
    end
  end)

  T.case("every slice is cut from inside the ink box", function()
    for _, name in ipairs(FRAMES) do
      local image, box = Assets.image(name), Assets.box[name]
      if image and box then
        local iw, ih = image:getDimensions()
        local drawn, seen = watch(function()
          return ArtFrame.draw(name, 0, 0, 300, 160)
        end)
        T.eq(drawn, true, name .. " drew")
        T.eq(#seen, 9, name .. " is nine pieces")
        for i, piece in ipairs(seen) do
          local qx, qy, qw, qh = piece.quad:getViewport()
          local tag = ("%s piece %d (%d,%d %dx%d)"):format(name, i, qx, qy, qw, qh)
          T.ok(qw > 0 and qh > 0, tag .. " has an area")
          T.ok(qx >= box.minx and qy >= box.miny, tag .. " starts inside the box")
          T.ok(qx + qw <= box.maxx + 1 and qy + qh <= box.maxy + 1, tag .. " ends inside the box")
          T.ok(qx + qw <= iw and qy + qh <= ih, tag .. " is inside the image")
        end
        -- The corners are the same size, and the four of them leave a middle.
        local _, _, cw, ch = seen[1].quad:getViewport()
        T.eq(cw, ch, name .. "'s corner is square")
        T.ok(cw * 2 < box.maxx - box.minx + 1 and ch * 2 < box.maxy - box.miny + 1,
          name .. "'s two corners leave an edge between them")
      end
    end
  end)

  T.case("the nine pieces tile the rectangle exactly, at any size", function()
    for _, name in ipairs(FRAMES) do
      for _, r in ipairs({
        { 20, 30, 300, 160, 1 }, { 0, 0, 1200, 90, 0.6 }, { 5, 5, 64, 400, 0.5 },
        { 0, 0, 24, 24, 1 }, { 100, 50, 700, 300, 2 },
      }) do
        local x, y, w, h, scale = r[1], r[2], r[3], r[4], r[5]
        local _, seen = watch(function()
          return ArtFrame.draw(name, x, y, w, h, { scale = scale })
        end)
        local tag = ("%s at %d,%d %dx%d scale %s"):format(name, x, y, w, h, scale)
        T.eq(#seen, 9, tag)
        local area = 0
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for _, p in ipairs(seen) do
          local _, _, qw, qh = p.quad:getViewport()
          local pw, ph = qw * p.sx, qh * p.sy
          area = area + pw * ph
          x0, y0 = math.min(x0, p.x), math.min(y0, p.y)
          x1, y1 = math.max(x1, p.x + pw), math.max(y1, p.y + ph)
        end
        T.near(x0, x, 1e-6, tag .. ": the left edge")
        T.near(y0, y, 1e-6, tag .. ": the top edge")
        T.near(x1, x + w, 1e-6, tag .. ": the right edge")
        T.near(y1, y + h, 1e-6, tag .. ": the bottom edge")
        -- Covered once: the areas add up to the rectangle, no more.
        T.near(area, w * h, 1e-3 * w * h, tag .. ": no piece overlaps another")
      end
    end
  end)

  T.case("face = false leaves the middle undrawn", function()
    local _, seen = watch(function()
      return ArtFrame.draw("ui_quiz_card", 0, 0, 300, 160, { face = false })
    end)
    T.eq(#seen, 8, "the border and nothing inside it")
  end)
end
