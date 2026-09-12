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
}
-- The haze is the tint at map strength: a deep blue over the typhoon
-- shelter at noon, a warm amber over the wet market at dawn. Python's is
-- the faintest because gold over a whole plate reads as a sepia filter
-- before it reads as a colour.
T.haze = {
  rust = { 0.95, 0.47, 0.16, 0.16 },
  go = { 80 / 255, 216 / 255, 248 / 255, 0.14 },
  cpp = { 0 / 255, 89 / 255, 156 / 255, 0.18 },
  python = { 255 / 255, 212 / 255, 59 / 255, 0.12 },
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
