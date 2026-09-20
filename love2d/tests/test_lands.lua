-- Four lands, and everything a land needs to be drawn.
--
-- `src/land.lua` is the one list; this pins that every land on it resolves
-- the things the scenes look up by land — a plate name for the map, a haze
-- and a tint for the theme, a name for the card, a mascot, and a file
-- extension for `$EDITOR` — so a fifth land added to the list without its
-- colours fails here rather than as Rust's orange over the wrong map.

local T = require("tests.framework")
local Land = require("src.land")
local Map = require("src.scenes.map")
local Theme = require("src.theme")
local External = require("src.external")

return function()
  T.section("lands — the four, and what each resolves to")

  T.case("the order is SPEC §0's, and every land has a name", function()
    T.same(Land.ORDER, { "rust", "go", "cpp", "python" })
    T.eq(Land.name("rust"), "RUST")
    T.eq(Land.name("go"), "GO")
    T.eq(Land.name("cpp"), "C++", "nobody calls it CPP")
    T.eq(Land.name("python"), "PYTHON")
    T.eq(Land.name("zig"), "ZIG", "a land the client has not heard of keeps its id")
    T.eq(Land.name(nil), "?")
  end)

  T.case("unknown lands sort last, and the bob phases are spread out", function()
    T.eq(Land.rank("rust"), 1)
    T.eq(Land.rank("python"), 4)
    T.eq(Land.rank("zig"), 5)
    local seen = {}
    for _, land in ipairs(Land.ORDER) do
      local phase = Land.phase(land)
      T.ok(phase >= 0 and phase < 1, land .. "'s phase is within the cycle")
      T.nope(seen[phase], "no two mascots nod in unison")
      seen[phase] = true
    end
  end)

  T.case("each land resolves a plate name, in both orientations", function()
    for _, land in ipairs(Land.ORDER) do
      local first, second, third = Map.plate_names(land, false)
      T.eq(first, "map_" .. land, land .. "'s landscape plate")
      T.eq(second, "map_bg")
      T.eq(third, "map_bg", "and the placeholder behind it")
      first, second = Map.plate_names(land, true)
      T.eq(first, "map_" .. land .. "_p", land .. "'s portrait plate")
      T.eq(second, "map_bg_p")
    end
  end)

  T.case("each land has its own haze and tint", function()
    for _, land in ipairs(Land.ORDER) do
      local haze = Map.haze(land)
      T.ok(haze == Theme.haze[land], land .. " does not fall back to Rust's haze")
      T.eq(#haze, 4, "r, g, b, a")
      T.ok(haze[4] > 0 and haze[4] < 0.3, "a haze, not a wall")
      local tint = Theme.land[land]
      T.ok(tint ~= nil, land .. " has a tint")
      T.eq(tint[4], 1, "the tint is opaque; the haze is the translucent one")
      for i = 1, 3 do
        T.eq(tint[i], haze[i], "the haze is the tint at map strength")
      end
    end
    T.ok(Map.haze("zig") == Theme.haze.rust, "an unknown land gets Rust's, not nothing")
  end)

  T.case("the new tints are the languages' own colours", function()
    -- ISO C++ blue #00599C and Python gold #FFD43B, as DECISIONS names them.
    local cpp, py = Theme.land.cpp, Theme.land.python
    T.same({ math.floor(cpp[1] * 255 + 0.5), math.floor(cpp[2] * 255 + 0.5),
      math.floor(cpp[3] * 255 + 0.5) }, { 0x00, 0x59, 0x9C })
    T.same({ math.floor(py[1] * 255 + 0.5), math.floor(py[2] * 255 + 0.5),
      math.floor(py[3] * 255 + 0.5) }, { 0xFF, 0xD4, 0x3B })
  end)

  T.case("each land names a mascot sprite; the new ones have a stand-in", function()
    for _, land in ipairs(Land.ORDER) do
      T.ok(Land.MASCOT[land] ~= nil, land .. " has a mascot")
    end
    T.eq(Land.MASCOT.cpp, "sprite_cpp")
    T.eq(Land.MASCOT.python, "sprite_python")
    -- Headless there are no images at all, so `pick` finds nothing — which
    -- is the behaviour on a checkout without `art/`, and must not error.
    T.eq(Land.mascot("cpp"), nil)
    T.eq(Land.mascot("zig"), nil)
  end)

  T.case("each land has a scratch-file extension for $EDITOR", function()
    T.same(External.EXT, { rust = "rs", go = "go", cpp = "cpp", python = "py" })
    for _, land in ipairs(Land.ORDER) do
      T.ok(External.EXT[land] ~= nil, land .. " has an extension")
    end
  end)

  T.section("lands — the CODE PLAYGROUND tile leads the screen")

  T.case("the tile sits under the title, above every card, clear of the band, both ways up", function()
    if not (love and love.graphics) then
      T.skip("the playground tile", "needs fonts, so needs LÖVE")
      return
    end
    local Layout = require("src.layout")
    local UI = require("src.ui")
    local Lands = require("src.scenes.lands")
    local was_font, was_mode, was_vw, was_vh = Layout.font, Layout.mode, Layout.vw, Layout.vh
    local app = { session = { authed = true }, land = "rust" }
    for _, step in ipairs({ 1, 2, 4 }) do
      Layout.font = step
      for _, shape in ipairs({ { "landscape", 1280, 720 }, { "portrait", 720, 1280 } }) do
        Layout.mode, Layout.vw, Layout.vh = shape[1], shape[2], shape[3]
        local scene = Lands.new(app)
        local tag = ("step %d %s"):format(step, shape[1])
        local tile = scene:tile_rect()
        local cards = scene:card_rects()
        local band = scene:button_rects().weakest
        local title_bottom = 24 + UI.lineHeight(Lands.title_size(Layout.vw))
        T.ok(tile.y >= title_bottom, tag .. ": the tile is under the title")
        T.ok(tile.x >= 0 and tile.x + tile.w <= Layout.vw, tag .. ": the tile is inside the canvas, across")
        T.ok(tile.h >= Lands.band_height() * 1.8 - 1, tag .. ": the tile is taller than a button")
        for i, c in ipairs(cards) do
          T.ok(c.y >= tile.y + tile.h, tag .. (": card %d starts under the tile"):format(i))
          T.ok(c.y + c.h <= band.y, tag .. (": card %d ends above the band"):format(i))
          T.ok(c.h > 0, tag .. (": card %d has height"):format(i))
        end
        T.ok(tile.y + tile.h < band.y, tag .. ": the tile is clear of the band")
        T.ok(band.y + band.h <= Layout.vh, tag .. ": the band is inside the canvas")
      end
    end
    Layout.font, Layout.mode, Layout.vw, Layout.vh = was_font, was_mode, was_vw, was_vh
  end)
  T.section("lands — the fourth road, and the quiz's pure parts")

  T.case("VERY BASIC walks first, and every road has a label", function()
    T.same(Land.CATEGORIES, { "verybasic", "basic", "advanced", "hacker" })
    T.eq(Land.category_label("verybasic"), "VERY BASIC", "two words on screen, not the id")
    T.eq(Land.category_label("basic"), "BASIC")
    T.eq(Land.category_label("hacker"), "HACKER")
    T.eq(Land.category_label("zig"), "ZIG", "an unknown road keeps its id, upper-cased")
  end)

  T.case("a pick is right only at the wire's 0-based answer", function()
    local Quest = require("src.scenes.quest")
    local quiz = { choices = { "a", "b", "c", "d" }, answer = 2 }
    T.eq(Quest.pick_result(quiz, 3), "right", "the third choice is index 2")
    T.eq(Quest.pick_result(quiz, 1), "wrong")
    T.eq(Quest.pick_result(quiz, 4), "wrong")
    T.eq(Quest.pick_result(quiz, 5), nil, "no fifth choice")
    T.eq(Quest.pick_result(quiz, 0), nil)
    T.eq(Quest.pick_result(nil, 1), nil, "no quiz, no pick")
  end)

  T.case("the choice wells stack without overlapping and keep their column", function()
    local Quest = require("src.scenes.quest")
    local boxes = Quest.choice_boxes(12, 100, 300, { 36, 50, 36, 36 }, 6)
    T.eq(#boxes, 4)
    for i, b in ipairs(boxes) do
      T.eq(b.x, 12); T.eq(b.w, 300)
      if i > 1 then
        local prev = boxes[i - 1]
        T.ok(b.y >= prev.y + prev.h + 6, "well " .. i .. " sits under well " .. (i - 1))
      end
    end
    T.eq(boxes[2].h, 50, "a wrapped choice gets a taller well")
  end)

end
