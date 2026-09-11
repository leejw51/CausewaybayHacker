-- The fonts, and whether they can draw what the interface says.
--
-- Needs a graphics context, so this runs under `make test` and is skipped by
-- name in the headless run.
--
-- Two families of check, both ported rather than invented:
--
--   * **advance widths**, from `CausewaybayOffice/love2d/src/test.lua`. It is
--     the right thing to assert about a bitmap face because it catches a
--     wrong file, a wrong size and a missing glyph in one number: Unifont is
--     8×16, so ASCII advances 8 and a CJK ideograph advances exactly 16. A
--     glyph that came from somewhere else, or at a size that was resampled,
--     is not 8 and not 16.
--   * **coverage**, from `CausewaybayGolang/love2d/tests/test_flow.lua`
--     ("the fonts cover every language"). Every character any language file
--     can put on screen has to exist in the face that will draw it, or LÖVE
--     draws a box and nothing says so.
--
-- The second one is the regression guard that matters. A translation added
-- next month in a script nothing can draw fails here instead of shipping.

local T = require("tests.framework")
local I18n = require("src.i18n")
local Assets = require("src.assets")

--- Every character any language can put on screen, once each.
local function corpus()
  local text = {}
  for _, lang in ipairs(I18n.LANGS) do
    local tr = I18n.TR[lang]
    if tr then
      for english, translated in pairs(tr) do
        text[#text + 1] = english
        text[#text + 1] = translated
      end
    end
  end
  for _, name in pairs(I18n.NAMES) do text[#text + 1] = name end
  local seen, out = {}, {}
  for _, ch in ipairs(require("src.ui").chars(table.concat(text, ""))) do
    if ch ~= "\n" and ch ~= "\t" and not seen[ch] then
      seen[ch] = true
      out[#out + 1] = ch
    end
  end
  return out
end

return function()
  T.section("fonts — GNU Unifont is 8×16, and that is how you know it loaded")

  T.case("the CJK face has the advances a bitmap face is supposed to have", function()
    local unifont = Assets.cjk_font(16)
    if not unifont then
      T.skip("unifont", "assets/fonts/unifont.otf is not there")
      return
    end
    -- `CausewaybayOffice/love2d/src/test.lua`, line for line. A wrong face
    -- or a resampled size fails every one of these.
    T.eq(unifont:getWidth("a"), 8, "ASCII is one 8-pixel cell")
    T.eq(unifont:getWidth("你"), 16, "a CJK ideograph is exactly two cells")
    T.eq(unifont:getWidth("안"), 16, "and so is a Hangul syllable")
    T.eq(unifont:getWidth("ř"), 8, "a Czech letter is one cell")
    T.eq(unifont:getHeight(), 16, "the face is 16 pixels tall")
  end)

  T.case("it draws all six languages, Czech included", function()
    local unifont = Assets.cjk_font(16)
    if not unifont then
      T.skip("unifont", "not present")
      return
    end
    -- The line that decided the file. The obvious alternative — a Noto Sans
    -- CJK subset — is 11.2 MB and has none of the Czech diacritics, so it
    -- would have made the four hard languages work and quietly broken the
    -- easy one.
    for name, sample in pairs({
      Latin = "Wallet", Czech = "čřšžůě",
      Hangul = "한글", Hiragana = "あ", Katakana = "ア",
      Chinese = "中文", Cantonese = "嘅咗喺冇",
    }) do
      T.ok(unifont:hasGlyphs(sample), name .. ": " .. sample)
    end
  end)

  T.section("fonts — every glyph the interface can say")

  T.case("the fonts cover every language", function()
    local chars = corpus()
    T.ok(#chars > 100, "the corpus is " .. #chars .. " distinct characters")
    -- Both faces, at the two sizes the interface actually asks for most, and
    -- through the same entry points the screens use — so this is testing the
    -- fallback wiring and not a font file in isolation.
    for _, spec in ipairs({
      { "label", Assets.font(16) },
      { "heading", Assets.font(32) },
      { "code", Assets.mono(16) },
    }) do
      local name, font = spec[1], spec[2]
      local missing = {}
      for _, ch in ipairs(chars) do
        if not font:hasGlyphs(ch) then missing[#missing + 1] = ch end
      end
      T.eq(#missing, 0,
        name .. " cannot draw: " .. table.concat(missing, " "))
    end
  end)

  T.section("fonts — the 8-pixel grid, which is the whole integer-scale rule")

  T.case("every size handed to the rasteriser is a multiple of 8", function()
    -- Press Start 2P is an 8×8 design and Unifont is 8×16. At 9, 10 or 15 px
    -- a one-pixel stem lands on a fraction of a screen pixel and is either
    -- smeared or dropped — the type reads soft, and soft reads as smaller.
    -- This client's authored ladder was 7, 8, 9, 10, 11, 12, 13.
    for _, n in ipairs({ 1, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 18, 23, 28, 32, 45 }) do
      T.eq(Assets.snap8(n) % 8, 0, n .. " snaps onto the grid")
      T.ok(Assets.snap8(n) >= 8, n .. " never rounds to nothing")
    end
    T.eq(Assets.snap8(7), 8)
    T.eq(Assets.snap8(12), 16)
    T.eq(Assets.snap8(28), 32)
    -- And the face really is the size it was asked for.
    T.eq(Assets.font(16):getHeight() % 8, 0, "the label face is a whole cell tall")
  end)

  T.case("the type ladder lands on the grid at every step", function()
    local Layout = require("src.layout")
    local was = Layout.font
    for step = 1, #Layout.FONT_STEPS do
      Layout.font = step
      for _, authored in ipairs({ 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 28 }) do
        local px = Assets.snap8(Layout.ui(authored))
        T.eq(px % 8, 0,
          ("step %d, authored %d -> %d px"):format(step, authored, px))
      end
    end
    Layout.font = was
  end)
end
