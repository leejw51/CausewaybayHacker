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
  T.section("fonts — the web's code faces and interface faces")

  -- Every case here sets a face and must put the defaults back, or the rest
  -- of the suite is measured in whatever the last loop left behind.
  local function restore(code, ui)
    Assets.setCodeFace(code)
    Assets.setUiFace(ui)
  end

  T.case("every code face has a name, a measured size and a weight", function()
    T.eq(#Assets.CODE_FACES, 15, "the web's fifteen, in the web's order")
    T.eq(Assets.CODE_FACES[1], "game")
    T.eq(Assets.CODE_FACES[#Assets.CODE_FACES], "radon")
    for _, face in ipairs(Assets.CODE_FACES) do
      T.ok(type(Assets.CODE_FACE_NAME[face]) == "string", face .. " has a name")
      local scale = Assets.CODE_FACE_SCALE[face]
      T.ok(type(scale) == "number" and scale > 0.5 and scale <= 1,
        face .. " has a size factor: " .. tostring(scale))
      T.ok(Assets.CODE_FACE_WEIGHT[face] == "normal"
        or Assets.CODE_FACE_WEIGHT[face] == "bold", face .. " has a weight")
    end
    -- A few of the table's numbers, so a re-tune by eye fails here.
    T.eq(Assets.CODE_FACE_SCALE.iosevka, 0.68)
    T.eq(Assets.CODE_FACE_SCALE.courier, 0.98)
    T.eq(Assets.CODE_FACE_SCALE.apple2, 0.64)
    T.eq(Assets.CODE_FACE_SCALE.radon, 0.77)
    -- No synthetic bold in LÖVE: the bold weight is the Bold file.
    T.eq(Assets.CODE_FACE_WEIGHT.courier, "bold")
    T.ok(Assets.COURIER_FILE:find("Bold", 1, true), "Courier is the Bold cut")
  end)

  T.case("every shipped code face loads, and is drawn in itself", function()
    local was = Assets.codeFace()
    for _, face in ipairs(Assets.CODE_FACES) do
      if face == "courier" then
        -- A system face: on a machine without it, VT323 draws instead and
        -- the pane still works.
        Assets.setCodeFace(face)
        T.ok(Assets.mono(28):getWidth("fn main()") > 0, "courier draws either way")
      else
        T.ok(Assets.hasCodeFace(face), face .. " is in assets/fonts")
        Assets.setCodeFace(face)
        T.eq(Assets.codeFace(), face)
        -- One advance across ASCII is the reason each was picked, and it
        -- has to survive every size the type steps ask for: a pixel face
        -- hinted off its grid can give `i` 7 px and `W` 8.
        for _, n in ipairs({ 14, 16, 18, 22, 28, 36 }) do
          local font = Assets.mono(n)
          T.eq(font:getWidth("i"), font:getWidth("W"),
            ("%s is fixed-width at %d"):format(face, n))
          T.eq(font:getWidth("0O1lI;"), 6 * font:getWidth("i"),
            ("%s at %d: six letters, six cells"):format(face, n))
        end
      end
    end
    Assets.setCodeFace(was)
  end)

  T.case("a code face is set at its measured size, in whole pixels", function()
    for _, n in ipairs({ 16, 18, 22, 28, 40 }) do
      T.eq(Assets.mono_px(n, "game") % 8, 0, "VT323 stays on the grid")
      for _, face in ipairs(Assets.CODE_FACES) do
        local grid = Assets.CODE_FACE_GRID[face]
        if grid then
          -- A pixel face lands on a whole multiple of its own grid, and
          -- within one step of its measured size.
          local px = Assets.mono_px(n, face)
          T.eq(px % grid, 0, ("%s at %d is on its %d px grid"):format(face, n, grid))
          T.ok(math.abs(px - n * Assets.CODE_FACE_SCALE[face]) <= grid,
            ("%s at %d: %d px is within a step of measured"):format(face, n, px))
        elseif face ~= "game" then
          T.eq(Assets.mono_px(n, face),
            math.max(8, math.floor(n * Assets.CODE_FACE_SCALE[face] + 0.5)),
            ("%s at %d"):format(face, n))
        end
      end
    end
    -- The bug the table exists to prevent: Iosevka snapped up to VT323's
    -- size is a third bigger to the eye at the same step.
    T.ok(Assets.mono_px(18, "iosevka") < Assets.mono_px(18, "game"),
      "Iosevka is set smaller than VT323 at the same step")
  end)

  T.case("every code face still draws every language", function()
    local was = Assets.codeFace()
    local chars = corpus()
    for _, face in ipairs(Assets.CODE_FACES) do
      Assets.setCodeFace(face)
      local font = Assets.mono(18)
      local missing = {}
      for _, ch in ipairs(chars) do
        if not font:hasGlyphs(ch) then missing[#missing + 1] = ch end
      end
      T.eq(#missing, 0, face .. " cannot draw: " .. table.concat(missing, " "))
    end
    Assets.setCodeFace(was)
  end)

  T.case("every interface face loads, and still draws every language", function()
    local was = Assets.uiFace()
    T.eq(#Assets.UI_FACES, 5)
    T.eq(Assets.UI_FACES[1], "game", "the game's own face is the default")
    local chars = corpus()
    for _, face in ipairs(Assets.UI_FACES) do
      local spec = Assets.UI_FACE_SPEC[face]
      T.ok(spec and type(Assets.UI_FACE_NAME[face]) == "string", face .. " is named")
      if spec.file then
        T.ok(love.filesystem.getInfo(spec.file), spec.file .. " is shipped")
      end
      Assets.setUiFace(face)
      for _, size in ipairs({ 16, 32 }) do
        local font = Assets.font(size)
        local missing = {}
        for _, ch in ipairs(chars) do
          if not font:hasGlyphs(ch) then missing[#missing + 1] = ch end
        end
        T.eq(#missing, 0, ("%s at %d cannot draw: %s")
          :format(face, size, table.concat(missing, " ")))
      end
      T.ok(Assets.body(30):hasGlyphs("한글中文čř"), face .. "'s body face too")
    end
    Assets.setUiFace(was)
  end)

  T.case("an interface face is set at its measured multiple of the label", function()
    local was = Assets.uiFace()
    Assets.setUiFace("game")
    local game = Assets.font(16)
    for _, face in ipairs({ "dos", "comic" }) do
      Assets.setUiFace(face)
      local f = Assets.font(16)
      T.ok(f ~= game, face .. " is a different font object")
      -- Press Start 2P is square; a swapped face is set larger and ends up
      -- narrower, which is the whole of the measurement.
      T.ok(f:getHeight() > game:getHeight() - 1, face .. " keeps the label's height")
      T.ok(f:getWidth("SETTINGS") < game:getWidth("SETTINGS"),
        face .. " is narrower than Press Start 2P")
    end
    Assets.setUiFace(was)
  end)

  T.case("the two choices cycle and wrap, and do not move each other", function()
    local code, ui = Assets.codeFace(), Assets.uiFace()
    Assets.setCodeFace("radon")
    T.eq(Assets.cycleCodeFace(), "game", "the code cycle wraps")
    T.eq(Assets.cycleCodeFace(), "iosevka")
    Assets.setUiFace("comic")
    T.eq(Assets.cycleUiFace(), "game", "the interface cycle wraps")
    T.eq(Assets.codeFace(), "iosevka", "and leaves the code face alone")
    Assets.setUiFace("nonsense")
    T.eq(Assets.uiFace(), "game", "a face that is not one is ignored")
    restore(code, ui)
  end)

  T.case("the interface face is remembered, apart from the code face", function()
    local Store = require("src.store")
    T.eq(Store.replay({}).ui_face, nil)
    local folded = Store.replay({
      { kind = "uiface.set", face = "dos" },
      { kind = "face.set", face = "victor" },
      { kind = "uiface.set", face = "galmuri" },
    })
    T.eq(folded.ui_face, "galmuri", "the last choice wins")
    T.eq(folded.face, "victor", "and the code face is its own record")
    T.eq(Store.replay({ { kind = "uiface.set", face = 7 } }).ui_face, nil)
  end)
end
