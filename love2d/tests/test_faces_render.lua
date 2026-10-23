-- The faces on a machine that is not this one.
--
-- CI's runner is Ubuntu: there is no `/System/Library/Fonts`, so no Courier
-- New, and LÖVE there is the distribution's 11.5 build, whose FreeType has to
-- read the OpenType files too. `tests/test_fonts.lua` lets a face that will
-- not load fall back to VT323 without a word, which is right for the player
-- and wrong for a test, so here each file is opened directly.

local T = require("tests.framework")

return function()
  T.section("faces — every file opens on its own, .otf included")

  T.case("every face file in assets/fonts is a font LÖVE can open", function()
    local n = 0
    for _, name in ipairs(love.filesystem.getDirectoryItems("assets/fonts")) do
      if name:match("%.[ot]tf$") then
        n = n + 1
        local path = "assets/fonts/" .. name
        local ok, font = pcall(love.graphics.newFont, path, 16)
        T.ok(ok and font ~= nil, path .. " opens: " .. tostring(not ok and font or ""))
        if ok and font then
          T.ok(font:getWidth("fn main()") > 0, path .. " has width")
          T.ok(font:hasGlyphs("0O1lI"), path .. " draws ASCII itself")
        end
      end
    end
    T.ok(n >= 15, n .. " faces opened")
  end)

  T.section("faces — Courier New, where there is none")

  T.case("without the system's Courier New the courier pane is VT323, and still a pane", function()
    -- A copy of the module that has never seen Courier New: `io.open` says
    -- no for that one path, and a fresh `require` asks it from scratch. The
    -- real module, which every other test uses, is put back untouched.
    local real_assets = package.loaded["src.assets"]
    local real_open = io.open
    local courier = real_assets.COURIER_FILE
    io.open = function(path, ...)
      if path == courier then return nil, "no such file (CI has no /System)" end
      return real_open(path, ...)
    end
    package.loaded["src.assets"] = nil
    local ok, err = pcall(function()
      local Assets = require("src.assets")
      T.ok(Assets ~= real_assets, "a fresh copy of the module")
      T.eq(Assets.hasCodeFace("courier"), false, "courier is not there")
      for _, face in ipairs(Assets.CODE_FACES) do
        if face ~= "courier" and face ~= "game" then
          T.ok(Assets.hasCodeFace(face), face .. " still is: it is shipped")
        end
      end
      Assets.setCodeFace("courier")
      T.eq(Assets.codeFace(), "courier", "the choice is kept, so it comes back on a Mac")
      for _, size in ipairs({ 16, 22, 28 }) do
        local font = Assets.mono(size)
        T.ok(font ~= nil, "a face at " .. size)
        local vt = love.graphics.newFont("assets/fonts/VT323-Regular.ttf", Assets.mono_px(size), "mono")
        T.eq(font:getWidth("fn main() {}"), vt:getWidth("fn main() {}"),
          ("at %d it is VT323 at courier's measured size"):format(size))
        T.eq(font:getWidth("i"), font:getWidth("W"), "and fixed-width")
        T.ok(font:hasGlyphs("한글中文čř"), "with Unifont still behind it")
      end
    end)
    io.open = real_open
    package.loaded["src.assets"] = real_assets
    T.ok(ok, "the fallback ran: " .. tostring(err))
    T.ok(require("src.assets") == real_assets, "the suite's module is back")
  end)
end
