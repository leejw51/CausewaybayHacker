-- The palette, as numbers.
--
-- Ported from `CausewaybayGolang/love2d/src/theme.lua`, which is the same
-- table `CausewaybayGolang/typescript/src/engine/theme.ts` carries, and which
-- `docs/art.md` §2 names as the register for this game too: "Super Mario
-- World sky and Wonder Boy candy, not neon cyberpunk."
--
-- Added here: the land tints from art.md §2, which are what separates
-- RUST LAND from GO LAND without a second set of sprites — and, since the
-- same trick scales, C++ LAND (ISO C++ blue, #00599C) and PYTHON LAND
-- (Python gold, #FFD43B) from both.

local T = {}

T.void = { 20 / 255, 28 / 255, 72 / 255, 1 }
T.sky = { 92 / 255, 148 / 255, 252 / 255, 1 }
T.navy = { 28 / 255, 36 / 255, 92 / 255, 1 }
T.panel = { 248 / 255, 208 / 255, 136 / 255, 1 }
T.wood = { 176 / 255, 104 / 255, 40 / 255, 1 }
T.coin = { 248 / 255, 208 / 255, 48 / 255, 1 }
T.brick = { 200 / 255, 76 / 255, 12 / 255, 1 }
T.grass = { 0 / 255, 168 / 255, 0 / 255, 1 }
T.red = { 216 / 255, 40 / 255, 0 / 255, 1 }
T.cyan = { 80 / 255, 216 / 255, 248 / 255, 1 }
T.pink = { 248 / 255, 120 / 255, 168 / 255, 1 }
T.cream = { 252 / 255, 236 / 255, 200 / 255, 1 }
T.ink = { 40 / 255, 24 / 255, 16 / 255, 1 }
T.admit = { 0 / 255, 168 / 255, 68 / 255, 1 }
T.dim = { 120 / 255, 104 / 255, 88 / 255, 1 }

-- art.md §2: the land tint is a haze over the map and a border on the panels.
T.land = {
  rust = { 0.95, 0.47, 0.16, 1 },
  go = { 80 / 255, 216 / 255, 248 / 255, 1 },
  cpp = { 0 / 255, 89 / 255, 156 / 255, 1 },
  python = { 255 / 255, 212 / 255, 59 / 255, 1 },
  pytorch = { 232 / 255, 72 / 255, 32 / 255, 1 },
  -- TypeScript blue #3178C6: lighter and colder than C++'s navy #00599C,
  -- with red and green both well up where C++ has almost none.
  typescript = { 49 / 255, 120 / 255, 198 / 255, 1 },
  -- ZIG LAND is the toll plaza at 06:00: Zig amber #F8B010 off wet
  -- concrete, a deeper, yellower orange than Rust's and darker than
  -- Python's gold — its green sits between the two and its blue below both.
  zig = { 248 / 255, 176 / 255, 16 / 255, 1 },
  -- LUA LAND is Tai Hang under the full moon (lua is the moon): indigo
  -- #6850D0, the first violet on the map — blue leads, and red runs well
  -- ahead of green, which no other blue-led land's does.
  lua = { 104 / 255, 80 / 255, 208 / 255, 1 },
  -- REMIX LAND is the yuenyeung café at tea time: milk tea with the coffee
  -- in it, a caramel warmer and greyer than Rust's orange and darker than
  -- Python's gold.
  remix = { 216 / 255, 168 / 255, 112 / 255, 1 },
}
-- The haze is the tint at map strength: a deep blue over the typhoon
-- shelter at noon, a warm amber over the wet market at dawn, and a torch
-- red over the machine room at night. Python's is the faintest because gold
-- over a whole plate reads as a sepia filter before it reads as a colour.
T.haze = {
  rust = { 0.95, 0.47, 0.16, 0.16 },
  go = { 80 / 255, 216 / 255, 248 / 255, 0.14 },
  cpp = { 0 / 255, 89 / 255, 156 / 255, 0.18 },
  python = { 255 / 255, 212 / 255, 59 / 255, 0.12 },
  pytorch = { 232 / 255, 72 / 255, 32 / 255, 0.18 },
  typescript = { 49 / 255, 120 / 255, 198 / 255, 0.16 },
  -- Amber over concrete at dawn is nearly gold over a plate, so it is
  -- kept light, as Go's is; the moon indigo over a night street can carry
  -- the full weight.
  zig = { 248 / 255, 176 / 255, 16 / 255, 0.14 },
  lua = { 104 / 255, 80 / 255, 208 / 255, 0.18 },
  remix = { 216 / 255, 168 / 255, 112 / 255, 0.14 },
}

-- The editor's colours, keyed by `src/editor.lua`'s span kinds. Chosen out of
-- the palette above rather than from a syntax theme, so the editor looks like
-- the rest of the game and not like an IDE somebody embedded.
T.code = {
  text = T.cream,
  keyword = { 248 / 255, 120 / 255, 168 / 255, 1 },
  type = { 80 / 255, 216 / 255, 248 / 255, 1 },
  string = { 152 / 255, 216 / 255, 120 / 255, 1 },
  number = T.coin,
  comment = { 140 / 255, 128 / 255, 112 / 255, 1 },
  macro = { 0.95, 0.62, 0.30, 1 },
  punct = { 208 / 255, 196 / 255, 172 / 255, 1 },
}

-- The rest of what a code pane is painted with: the page under the text, the
-- ruler, the active line, the selection, the caret, the bracket outline, the
-- answer's ghost and its holes, and the scrollbar. `paper = nil` means "the
-- well as it is" — the dark pane is drawn exactly as it was before there
-- was a choice.
T.pane = {
  paper = nil,
  gutter = { T.void[1], T.void[2], T.void[3], 0.92 },
  active = { T.cream[1], T.cream[2], T.cream[3], 0.06 },
  select = { T.coin[1], T.coin[2], T.coin[3], 0.28 },
  caret = T.coin,
  match = T.cyan,
  ghost = { T.cream[1], T.cream[2], T.cream[3], 0.42 },
  hole = T.coin,
  scroll = { T.cream[1], T.cream[2], T.cream[3], 0.25 },
}

--- The two code themes, in the order the THEME button cycles them.
---
--- **The code pane only.** The panels, the buttons and the console around it
--- are the game, and the game is drawn at night; what changes is the one
--- surface somebody reads their own program on, which some people read
--- better as ink on paper. The light page is the palette's own cream, and
--- every syntax colour is the dark one taken down until it holds its own on
--- it — the same hues, so a keyword is still the pink one.
T.CODE_THEMES = { "dark", "light" }
local CODE = {
  dark = { code = T.code, pane = T.pane },
  light = {
    code = {
      text = T.ink,
      keyword = { 176 / 255, 32 / 255, 96 / 255, 1 },
      type = { 16 / 255, 96 / 255, 168 / 255, 1 },
      string = { 32 / 255, 120 / 255, 24 / 255, 1 },
      number = { 168 / 255, 96 / 255, 0 / 255, 1 },
      comment = { 136 / 255, 124 / 255, 108 / 255, 1 },
      macro = { 184 / 255, 72 / 255, 8 / 255, 1 },
      punct = { 88 / 255, 72 / 255, 56 / 255, 1 },
    },
    pane = {
      paper = { 252 / 255, 244 / 255, 224 / 255, 1 },
      gutter = { 232 / 255, 216 / 255, 184 / 255, 1 },
      active = { T.ink[1], T.ink[2], T.ink[3], 0.06 },
      select = { T.sky[1], T.sky[2], T.sky[3], 0.32 },
      caret = T.ink,
      match = { 16 / 255, 96 / 255, 168 / 255, 1 },
      ghost = { T.ink[1], T.ink[2], T.ink[3], 0.36 },
      hole = T.brick,
      scroll = { T.ink[1], T.ink[2], T.ink[3], 0.3 },
    },
  },
}
local code_theme = "dark"

--- Which theme `T.code` and `T.pane` hold. Swapped in place of the tables
--- rather than copied into them, so a caller that read `T.code[kind]` a
--- frame ago reads the new colour on the next one.
function T.setCodeTheme(name)
  local theme = CODE[name]
  if not theme then return end
  code_theme = name
  T.code, T.pane = theme.code, theme.pane
end

function T.codeTheme() return code_theme end

-- The verdict colours from §5.4's closed set.
T.verdict = {
  accepted = T.admit,
  wrong_answer = T.brick,
  compile_error = T.red,
  runtime_error = T.red,
  timeout = T.coin,
  output_limit = T.coin,
  internal_error = T.dim,
}

T.landW, T.landH = 1280, 720
T.portW, T.portH = 720, 1280

function T.withAlpha(c, a)
  return { c[1], c[2], c[3], a }
end

return T
