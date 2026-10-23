-- The map's header row and the land picker, laid out at every shape.
--
-- The header is a bar of chips: the land as a badge, the other lands as
-- their mascots, the roads as chips and RESET THIS ROAD as a ghost button.
-- It reflows rather than squeezes: every chip as wide as its own label, and,
-- as the row runs out, the ‹ BACK ghost goes, then RESET moves to the row
-- after the roads, and the roads wrap onto as many rows as they need. What
-- a player would see go wrong is a chip on top of another, a chip off the
-- edge of the screen, or the map's nodes under a second row the plate did
-- not know about. Each is asserted here at both orientations, several
-- window shapes, three type steps and every language, with RESET THIS ROAD
-- offered and not.
--
-- And one more, which is the point of building it on the roles: **the
-- header is the same height at every type step.** F12 moves the reading
-- face and the code, never the chrome, so a header measured at step 4 is
-- the header measured at step 1.
--
-- Under LÖVE only: the widths are measured from the fonts.

local T = require("tests.framework")

local SHAPES = {
  { "landscape", 1280, 720 }, { "landscape", 1280, 800 }, { "landscape", 1920, 720 },
  { "portrait", 720, 1280 }, { "portrait", 720, 958 }, { "portrait", 1080, 1920 },
}

local function overlap(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

return function()
  local Layout = require("src.layout")
  local I18n = require("src.i18n")
  local Land = require("src.land")
  local Map = require("src.scenes.map")
  local Lands = require("src.scenes.lands")

  local saved = {
    font = Layout.font, mode = Layout.mode, vw = Layout.vw, vh = Layout.vh, lang = I18n.lang,
  }
  local function restore()
    Layout.font, Layout.mode, Layout.vw, Layout.vh = saved.font, saved.mode, saved.vw, saved.vh
    I18n.set(saved.lang)
  end

  T.section("map header — chips in one row or two, never on top of themselves")

  T.case("every chip is on the screen, apart, above the plate, and the same height at every step", function()
    local worst = 0
    local two_rows = 0
    local heights = {}
    local ok, err = pcall(function()
      local map = Map.new({ session = {} })
      local lands = map:lands()
      for _, lang in ipairs(I18n.LANGS) do
        I18n.set(lang)
        for _, step in ipairs({ 1, 2, 4 }) do
          Layout.font = step
          for _, shape in ipairs(SHAPES) do
            Layout.mode, Layout.vw, Layout.vh = shape[1], shape[2], shape[3]
            -- RUST has the most roads; the last land is never the first.
            for _, here in ipairs({ { "rust", "frameworks" }, { lands[#lands], "hacker" } }) do
              for _, tally in ipairs({ false, { total = 5, cleared = 1 } }) do
                map.land, map.category = here[1], here[2]
                map.tally = tally or nil
                map:draw_header()
                local vw, vh = Layout.vw, Layout.vh
                local tag = ("%s step %d %s %dx%d %s%s"):format(lang, step, shape[1], vw, vh,
                  here[1], tally and " +reset" or "")
                local h = map.header_h
                T.ok(type(h) == "number" and h > 0, tag .. ": a header height")
                worst = math.max(worst, h / vh)
                -- The same arrangement at every step: the chrome never
                -- moves with F12.
                local key = ("%s %s %dx%d %s%s"):format(lang, shape[1], vw, vh, here[1], tally and " +reset" or "")
                if heights[key] then
                  T.eq(h, heights[key], tag .. ": the header is as tall as it was at step 1")
                else
                  heights[key] = h
                end
                local rects = {}
                for _, land in ipairs(lands) do
                  local r = map.land_rects[land]
                  T.ok(r ~= nil, tag .. ": a chip for " .. land)
                  if r then rects[#rects + 1] = { r, "land " .. land } end
                end
                for _, road in ipairs(Land.roads(here[1])) do
                  local r = map.category_rects[road]
                  T.ok(r ~= nil, tag .. ": a chip for " .. road)
                  if r then
                    rects[#rects + 1] = { r, "road " .. road }
                    T.ok(r.w >= 20, ("%s: the %s chip is %d wide"):format(tag, road, r.w))
                  end
                end
                if map.back_rect then rects[#rects + 1] = { map.back_rect, "back" } end
                if map.reset_rect then rects[#rects + 1] = { map.reset_rect, "reset" } end
                if tally == false then
                  T.eq(map.reset_rect, nil, tag .. ": no reset for a road with nothing on it")
                else
                  T.ok(map.reset_rect ~= nil, tag .. ": RESET THIS ROAD is offered, and on the screen")
                end
                for i, entry in ipairs(rects) do
                  local r, name = entry[1], entry[2]
                  T.ok(r.x >= 0 and r.x + r.w <= vw + 0.5,
                    ("%s: %s is across %d..%d of %d"):format(tag, name, r.x, r.x + r.w, vw))
                  T.ok(r.y >= 0 and r.y + r.h <= h + 0.5,
                    ("%s: %s ends at %d, in a %d header"):format(tag, name, r.y + r.h, h))
                  for j = i + 1, #rects do
                    T.nope(overlap(r, rects[j][1]),
                      ("%s: %s overlaps %s"):format(tag, name, rects[j][2]))
                  end
                end
                local _, top = map:plate_rect()
                T.ok(top >= h, ("%s: the plate starts at %d, under the %d header"):format(tag, top, h))
                -- A second row is the roads under the lands.
                local first = map.land_rects[lands[1]]
                local road = map.category_rects[Land.roads(here[1])[1]]
                if first and road and road.y >= first.y + first.h then two_rows = two_rows + 1 end
              end
            end
          end
        end
      end
    end)
    restore()
    T.ok(ok, "the header drew everywhere: " .. tostring(err))
    T.ok(worst <= 0.25, ("the header never takes more than a quarter of the screen (%.2f)"):format(worst))
    T.ok(two_rows > 0, "and the two-row layout was reached at least once")
  end)

  T.section("map — the node card")

  T.case("the sheet keeps the plate above it, upright, and is docked right across", function()
    local ok, err = pcall(function()
      local map = Map.new({ session = {} })
      map.land, map.category = "rust", "basic"
      for _, step in ipairs({ 1, 4 }) do
        Layout.font = step
        for _, shape in ipairs(SHAPES) do
          Layout.mode, Layout.vw, Layout.vh = shape[1], shape[2], shape[3]
          map:draw_header()
          local tag = ("step %d %s %dx%d"):format(step, shape[1], shape[2], shape[3])
          local card = map:card_rect()
          local _, top, _, ph = map:plate_rect()
          T.ok(card.x >= 0 and card.x + card.w <= Layout.vw, tag .. ": the card is on the screen")
          T.ok(card.y + card.h <= Layout.vh - 48 + 0.5, tag .. ": the card is above the footer")
          if shape[1] == "portrait" then
            T.ok(top + ph <= card.y + 0.5, tag .. ": the plate stops above the sheet")
          else
            T.ok(card.y >= map.header_h, tag .. ": the card is under the header")
          end
        end
      end
    end)
    restore()
    T.ok(ok, "the card laid out everywhere: " .. tostring(err))
  end)

  T.section("land picker — the cards at more window shapes")

  T.case("nine land cards are on the screen, apart and pressable at every shape", function()
    local ok, err = pcall(function()
      local lands = {}
      for i = 1, 9 do lands[i] = { land = "rust", categories = {} } end
      local self = setmetatable({ lands = lands }, Lands)
      for _, step in ipairs({ 1, 2, 3, 4 }) do
        Layout.font = step
        for _, shape in ipairs(SHAPES) do
          Layout.mode, Layout.vw, Layout.vh = shape[1], shape[2], shape[3]
          local tag = ("step %d %s %dx%d"):format(step, shape[1], shape[2], shape[3])
          local tile = self:tile_rect()
          T.ok(tile.y >= 24, tag .. ": the tile is under the title")
          local rects, n = self:card_rects()
          T.eq(n, 9, tag)
          for i, r in ipairs(rects) do
            T.nope(overlap(r, tile), tag .. ": card " .. i .. " clear of the playground tile")
            T.ok(r.y + r.h <= Lands.band_top(), tag .. ": card " .. i .. " above the band")
            T.ok(r.x >= 0 and r.x + r.w <= Layout.vw, tag .. ": card " .. i .. " on the screen")
            T.ok(r.h >= 36 and r.w >= 36, tag .. (": card %d is %dx%d"):format(i, r.w, r.h))
            for j = i + 1, #rects do
              T.nope(overlap(r, rects[j]), tag .. (": cards %d and %d overlap"):format(i, j))
            end
          end
        end
      end
    end)
    restore()
    T.ok(ok, "laid out everywhere: " .. tostring(err))
  end)
end
