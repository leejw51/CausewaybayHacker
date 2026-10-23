-- Fonts and images, loaded once and never at draw time.
--
-- ## Two sources, in order
--
-- 1. **`art/`**, at the root of this repository — the generated set, listed
--    in `art/manifest.json` in `CausewaybayGolang`'s shape, with a measured
--    `box` on every sprite. This is the real art and it wins, and it now
--    carries every name a scene asks for, the old placeholders included
--    (`fx_star`, `fx_confetti`, `ui_coin`, `sprite_clerk`, `bg_flat`,
--    `bg_night`).
-- 2. **`love2d/assets/`** — only the two map backgrounds, `map_bg` and
--    `map_bg_p`, the fallback `src/scenes/map.lua` names behind a land's own
--    map when `art/` is not readable.
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
-- `art/manifest.json` does not carry it — which, since `art/` took over the
-- rest, means the map fallback for `map_rust` / `map_go` and nothing else.
local PLACEHOLDERS = {
  map_bg = "assets/map_bg.png",
  map_bg_p = "assets/map_bg_p.png",
}

-- The placeholders that need the magenta screen flooded out. Empty now: the
-- magenta-screen JPEGs it was for all come from `art/`, cut to alpha. Kept
-- as the place to name one, so `knockout` is never run on `art/` by
-- accident — nothing from `art/` should ever be in this list.
local KNOCKOUT = {}

local FONT_FILE = "assets/fonts/PressStart2P-Regular.ttf"
local MONO_FILE = "assets/fonts/VT323-Regular.ttf"

-- ------------------------------------------------------------------- faces
--
-- Two choices, one for the code panes and one for the rest of the screen,
-- ported from `frontend/src/engine/text.ts` (`CODE_FACES`, `UI_FACES`) with
-- the web's names, order and **measured** sizes. The size tables are the
-- whole reason a face swap does not look like a mistake: they were taken
-- from each face's cap height and advance, not judged by eye, so they are
-- copied here number for number rather than re-tuned.
--
-- LÖVE 11.5 reads neither WOFF nor WOFF2, so `assets/fonts/` carries each as
-- TrueType or OpenType, converted with fontTools; `CREDITS.txt` there says
-- what was subset and what was shipped as it came.

--- The faces a code pane can be set in, in the order the button cycles them.
---
--- `game` is the face the rest of the screen is drawn in, and it was the
--- default because changing what somebody already knows is not an
--- improvement. It is not the default any more, and the argument that was
--- written here against it is the reason: VT323's `0` and `O` are the same
--- shape and `1`, `l` and `I` nearly so, and this is a game about reading
--- code. Iosevka separates all five, fits half again as much on a line, and
--- is what a programmer's editor looks like. The cycle button is unchanged
--- and the choice is remembered, so anyone who prefers the terminal face
--- sets it once.
---
--- The twelve after the first three are the web's, in the web's order: three
--- pixel faces that are also interface faces, Comic Mono, Courier New Bold,
--- three home computers, and four outline faces. Every one has a single
--- advance across ASCII. The ones only a code pane uses are subset to what a
--- code pane holds, like Iosevka; a glyph a subset lacks is drawn by VT323
--- and then Unifont behind it.
A.CODE_FACES = {
  "game", "iosevka", "jetbrains", "dos", "dunggeunmo", "galmuri", "comic",
  "courier", "apple2", "msx", "amiga", "victor", "victorscript", "fantasque",
  "radon",
}

--- What to call each on the button. Its own name, not a description.
A.CODE_FACE_NAME = {
  game = "VT323",
  iosevka = "IOSEVKA",
  jetbrains = "JETBRAINS",
  dos = "DOS",
  dunggeunmo = "DUNGGEUNMO",
  galmuri = "GALMURI",
  comic = "COMIC",
  courier = "COURIER NEW BOLD",
  apple2 = "APPLE II",
  msx = "MSX",
  amiga = "AMIGA TOPAZ",
  victor = "VICTOR MONO",
  victorscript = "VICTOR MONO ITALIC",
  fantasque = "FANTASQUE",
  radon = "RADON HANDWRITING",
}

--- Courier New is a **system** face and is never shipped: the one face every
--- Mac already has. Read from where macOS keeps it, through plain `io.open`
--- (`love.filesystem` cannot see outside the game), and VT323 stands in on a
--- machine without it — the web's stack does the same with `Courier, VT323`.
A.COURIER_FILE = "/System/Library/Fonts/Supplemental/Courier New Bold.ttf"

local CODE_FILE = {
  game = MONO_FILE,
  iosevka = "assets/fonts/Iosevka-Code.ttf",
  jetbrains = "assets/fonts/JetBrainsMono-Code.ttf",
  dos = "assets/fonts/IBM-VGA-8x16.ttf",
  -- The Code cut, not the interface one: the same 8×16 cell with a slashed
  -- zero and the punctuation a program needs told apart.
  dunggeunmo = "assets/fonts/neodgm_code.ttf",
  galmuri = "assets/fonts/GalmuriMono11.ttf",
  comic = "assets/fonts/ComicMono.ttf",
  courier = A.COURIER_FILE,
  apple2 = "assets/fonts/PRNumber3.ttf",
  msx = "assets/fonts/MSX1-Code.ttf",
  amiga = "assets/fonts/TopazUnicode-Code.ttf",
  victor = "assets/fonts/VictorMono-Code.otf",
  -- The italic is the cursive, and is its own face here as on the web, so
  -- nothing downstream has to carry a style along with the name.
  victorscript = "assets/fonts/VictorMonoItalic-Code.otf",
  fantasque = "assets/fonts/FantasqueSansMono-Code.ttf",
  radon = "assets/fonts/MonaspaceRadon-Code.otf",
}

--- How big to draw each face, against the size asked for.
---
--- **Not every face is the same size at the same size.** VT323 is a terminal
--- face with a small cap height on a narrow em: drawn at the same nominal
--- size as Iosevka it is smaller to the eye and narrower per character, so
--- the swap *loses* columns, which is the opposite of the reason to offer it.
--- Each face is drawn at the size that matches VT323's apparent size, and
--- then the comparison is the one worth making.
A.CODE_FACE_SCALE = {
  game = 1,
  iosevka = 0.68,
  jetbrains = 0.68,
  -- The four below are matched on cap height to VT323 (0.56 em), from the
  -- same measurement as `UI_FACE_SPEC`.
  dos = 0.85,
  dunggeunmo = 0.85,
  galmuri = 0.62,
  comic = 0.78,
  -- Courier New: cap 0.571 em, advance 0.6 em.
  courier = 0.98,
  -- The three home computers are pixel faces with a 0.875 em cap height.
  -- Apple II is Kreative's PR Number 3, the //e's 80-column text; MSX is the
  -- 8×8 cell of an MSX1's SCREEN 1; Amiga is the A500's Topaz.
  apple2 = 0.64,
  msx = 0.64,
  amiga = 0.64,
  -- Victor Mono: cap 0.727 em, advance 0.545 em. Its italic is the cursive.
  victor = 0.77,
  victorscript = 0.77,
  -- Fantasque Sans Mono: cap 0.625 em, advance 0.518 em.
  fantasque = 0.9,
  -- Monaspace Radon, the handwritten one: cap 0.73 em, advance 0.62 em.
  radon = 0.77,
}
local CODE_SCALE = A.CODE_FACE_SCALE

--- The weight each code face is drawn at. Courier New at its regular weight
--- is a hairline beside the pixel faces round it; the bold cut is the one
--- that holds up on the dark pane. LÖVE has no synthetic bold, so a `bold`
--- here is a promise about the *file* — `COURIER_FILE` is the Bold cut — and
--- `tests/test_fonts.lua` holds the two to each other.
A.CODE_FACE_WEIGHT = {}
for _, face in ipairs(A.CODE_FACES) do A.CODE_FACE_WEIGHT[face] = "normal" end
A.CODE_FACE_WEIGHT.courier = "bold"

--- How each code face is rasterised, where it is not the `"mono"` every face
--- here was drawn with before.
---
--- `"normal"` is for the outline faces — a cursive or a handwriting drawn
--- aliased comes out as a staircase — and gets antialiasing and a linear
--- filter, as it does in a browser.
---
--- `"light"` is for four pixel faces whose own hinting does not survive a
--- size off their grid: at 18 px `"mono"` gives PR Number 3 an `i` of 7 and a
--- `W` of 8, which in a code pane is a column that wanders. Light hinting
--- leaves the advances alone, so every cell is one width at every size
--- (measured 8 to 40 px), and keeps the nearest filter of a pixel face.
local HINTING = {
  comic = "normal", courier = "normal", victor = "normal",
  victorscript = "normal", fantasque = "normal", radon = "normal",
  galmuri = "light", apple2 = "light", msx = "light", amiga = "light",
}

local code_face = "iosevka"

--- The faces the whole interface can be set in, in the order F8 cycles them.
---
--- `game` is Press Start 2P and stays the default. The others are one face
--- put in front of it, so Press Start 2P still stands behind for a glyph the
--- face lacks — DOS VGA has no `č`, Comic Mono no Hangul — and Unifont behind
--- both; Neo둥근모 and Galmuri carry Hangul and draw Korean themselves.
A.UI_FACES = { "game", "dos", "dunggeunmo", "galmuri", "comic" }

--- What each is called in the toast. Its own name.
A.UI_FACE_NAME = {
  game = "ARCADE",
  dos = "DOS",
  dunggeunmo = "DUNGGEUNMO",
  galmuri = "GALMURI",
  comic = "COMIC",
}

--- The web's `UI_FACE_SPEC`, measured (cap height and advance of each face
--- at 100 px in Chromium). Press Start 2P is a square face — cap height and
--- advance both a full em — so a face swapped into its roles is set larger
--- to keep a label's height, and ends up narrower. `pixel` is against Press
--- Start 2P, for every label (`A.font`); `body` is against VT323, for the
--- prose roles the web draws in VT323 (`A.body`).
A.UI_FACE_SPEC = {
  game = { file = nil, pixel = 1, body = 1 },
  -- IBM VGA 8x16: cap 0.625 em, advance 0.5 em.
  dos = { file = "assets/fonts/IBM-VGA-8x16.ttf", pixel = 1.25, body = 0.9 },
  -- Neo둥근모: the same 8x16 cell, and Hangul in it.
  dunggeunmo = { file = "assets/fonts/neodgm.ttf", pixel = 1.25, body = 0.9 },
  -- Galmuri11: cap 0.917 em on a 12-pixel grid, proportional Latin. Set a
  -- little over its cap-height match: its strokes are one pixel, and at the
  -- matched size a brief in it read smaller than the same brief in VT323.
  galmuri = { file = "assets/fonts/Galmuri11.ttf", pixel = 1, body = 0.75 },
  -- Comic Mono: cap 0.715 em, advance 0.545 em.
  comic = { file = "assets/fonts/ComicMono.ttf", pixel = 1.2, body = 0.78,
    hinting = "normal" },
}

local ui_face = "game"

--- Forget every cached face whose key starts with one of `prefixes`: the
--- sizes already made are the old face at those sizes.
local function drop(prefixes)
  for key in pairs(A.fonts) do
    if prefixes:find(key:sub(1, 1), 1, true) then A.fonts[key] = nil end
  end
end

--- Which face `A.mono` hands back.
function A.setCodeFace(face)
  if not CODE_FILE[face] or face == code_face then return end
  code_face = face
  drop("m")
end

function A.codeFace() return code_face end

--- Which face `A.font` and `A.body` hand back.
function A.setUiFace(face)
  if not A.UI_FACE_SPEC[face] or face == ui_face then return end
  ui_face = face
  drop("pb")
end

function A.uiFace() return ui_face end

--- The face after `face` in `list`, wrapping; the first if `face` is not in it.
local function after(list, face)
  for i, name in ipairs(list) do
    if name == face then return list[(i % #list) + 1] end
  end
  return list[1]
end

--- Move to the next code face and return its name. The cycle the two code
--- screens' buttons share, so neither keeps its own copy of the order.
function A.cycleCodeFace()
  A.setCodeFace(after(A.CODE_FACES, code_face))
  return code_face
end

--- Move to the next interface face and return its name. F8.
function A.cycleUiFace()
  A.setUiFace(after(A.UI_FACES, ui_face))
  return ui_face
end

--- GNU Unifont, 5.1 MB, taken whole from `CausewaybayOffice/love2d`.
---
--- **One face for every script this interface speaks.** 58,909 glyphs — the
--- whole Basic Multilingual Plane — so Korean, Japanese kana, Chinese,
--- Cantonese's own characters (嘅 咗 喺 冇) *and* Czech's `č ř š ž ů ě` all
--- come out of one file. The obvious alternative, a Noto Sans CJK subset, is
--- 11.2 MB and does **not** carry the Czech diacritics, which would have made
--- four hard languages work and quietly broken the easy one.
---
--- And it is a **bitmap** face by design: 8×16 px per cell, 16 px wide for a
--- double-width ideograph. That is the wallet's "the font is baked, not
--- shrunk" argument satisfied natively rather than approximated — there is no
--- size at which it needs antialiasing to look right, because it was drawn on
--- the pixel grid this game draws on. Sizes are multiples of 8 for exactly
--- that reason; see `A.snap8`.
local CJK_FILE = "assets/fonts/unifont.otf"

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

--- Round a pixel size onto the 8-pixel grid both faces are drawn on.
---
--- **This is the whole of the "integer scale" rule, applied where it belongs.**
--- Press Start 2P is an 8×8 design and GNU Unifont is 8×16; at 9, 10 or 15 px
--- a one-pixel stem lands on a fraction of a screen pixel and the rasteriser
--- either smears it grey or drops it. `CausewaybayWallet`'s README calls that
--- out in as many words — *"at 2.5× a one-pixel line lands on half a screen
--- pixel … and the whole illusion goes"* — and this client was doing it at
--- every label, because the authored ladder was 7, 8, 9, 10, 11, 12, 13.
---
--- `CausewaybayOffice` avoids it by only ever asking for 8 and 16. Same rule,
--- one function: every size this module hands to the rasteriser is a multiple
--- of 8, so no glyph is ever resampled.
function A.snap8(size)
  return math.max(8, math.floor((tonumber(size) or 8) / 8 + 0.5) * 8)
end

--- Unifont at `size`, or nil when the file is not there.
---
--- Lazily loaded and cached per size: 5.1 MB is not something to read on a
--- frame that does not need it, and a client whose assets did not ship must
--- still start and say so rather than crash on a missing font.
local cjk_data = nil
local function cjk_font(size)
  local key = "u" .. size
  if A.fonts[key] ~= nil then return A.fonts[key] or nil end
  if cjk_data == nil then
    cjk_data = love.filesystem.getInfo(CJK_FILE)
      and love.filesystem.newFileData(CJK_FILE) or false
  end
  if not cjk_data then return nil end
  -- `"mono"` hinting, as `CausewaybayOffice` does it: a bitmap face wants no
  -- hinting decisions made for it, and the greys that the default hinting
  -- puts on the edges are the thing a nearest filter turns into blocks.
  local ok, font = pcall(love.graphics.newFont, cjk_data, size, "mono")
  if not ok or not font then
    A.fonts[key] = false
    return nil
  end
  font:setFilter("nearest", "nearest")
  A.fonts[key] = font
  return font
end

A.cjk_font = cjk_font

--- The bytes of a face file, read once and kept: every size of a face is
--- made from the same `FileData`, and Galmuri is not something to read off
--- the disk again for each one.
---
--- A path starting with `/` is outside the game — the system's Courier New —
--- and goes through plain `io.open`, the way `read_art` reaches `art/`.
--- `false` is cached for a file that is not there, so a missing face is asked
--- about once and not on every frame.
local face_data = {}
local function face_file(path)
  if not path then return nil end
  if face_data[path] == nil then
    local ok, data = pcall(function()
      if path:sub(1, 1) == "/" then
        local fh = io.open(path, "rb")
        if not fh then return false end
        local bytes = fh:read("*a")
        fh:close()
        return love.filesystem.newFileData(bytes, path:match("[^/]+$"))
      end
      if not love.filesystem.getInfo(path) then return false end
      return love.filesystem.newFileData(path)
    end)
    face_data[path] = (ok and data) or false
  end
  return face_data[path] or nil
end

--- Is `face` (a code face) really there, or would it be drawn in VT323?
--- Courier New on a machine without it is the only one that should say no.
function A.hasCodeFace(face)
  return face_file(CODE_FILE[face]) ~= nil
end

--- A face from `path` at `size`, or nil. `"mono"` hinting and a nearest
--- filter unless `hinting` says otherwise (`HINTING`); a `"normal"` face is
--- antialiased and filtered linearly.
local function make(path, size, hinting)
  local data = face_file(path)
  if not data then return nil end
  hinting = hinting or "mono"
  local ok, font = pcall(love.graphics.newFont, data, size, hinting)
  if not ok or not font then return nil end
  if hinting == "normal" then font:setFilter("linear", "linear")
  else font:setFilter("nearest", "nearest") end
  return font
end

--- Attach faces behind `font`, so anything it cannot draw is drawn rather
--- than shown as a box. `behind` is the game face that stands next in line
--- (Press Start 2P behind an interface face, VT323 behind a code face), or
--- nil when `font` already is that face; Unifont is always last.
---
--- **The fallback is per-glyph.** Press Start 2P keeps drawing the ASCII
--- range, so English is pixel for pixel what it has always been; Korean,
--- Japanese, Chinese and Cantonese come out of Unifont. Czech could come from
--- either — both faces have `č ř š ž ů ě` — and it comes from Press Start 2P
--- because that face wins wherever it has the glyph, which is what keeps a
--- Czech sentence looking like the rest of the game rather than like a
--- fallback.
local function with_fallback(font, size, behind)
  local cjk = cjk_font(size)
  if font.setFallbacks then
    if behind and cjk then pcall(font.setFallbacks, font, behind, cjk)
    elseif behind then pcall(font.setFallbacks, font, behind)
    elseif cjk then pcall(font.setFallbacks, font, cjk) end
  end
  return font
end

--- The game's own two faces at exactly `size`, with nothing behind them: the
--- faces that stand *behind* a chosen one. Cached under their own keys so a
--- face change does not drop them.
local function game_face(file, prefix, size)
  local key = prefix .. size
  if A.fonts[key] == nil then
    A.fonts[key] = make(file, size) or false
  end
  return A.fonts[key] or nil
end

--- The interface face at `size`, cached. Every label is drawn in it.
---
--- In the default `game` face it is Press Start 2P, and `size` is snapped to
--- the grid. Another face is set at its measured multiple of the size asked
--- for (`UI_FACE_SPEC.pixel`), in whole pixels, as the web does it; snapping
--- that onto Press Start 2P's grid as well would undo the measurement.
---
--- Press Start 2P is the game's voice. The code editor uses `A.mono`
--- instead, because a player has to read their own program in it and an
--- 8×8 pixel face at 11px is not that.
function A.font(size)
  local spec = A.UI_FACE_SPEC[ui_face]
  if spec.file then
    size = math.max(8, math.floor((tonumber(size) or 8) * spec.pixel + 0.5))
  else
    size = A.snap8(size)
  end
  local key = "p" .. size .. ui_face
  if not A.fonts[key] then
    local font = spec.file and make(spec.file, size, spec.hinting)
    if font then
      A.fonts[key] = with_fallback(font, size,
        game_face(FONT_FILE, "g", A.snap8(size)))
    else
      font = make(FONT_FILE, size) or love.graphics.newFont(size)
      font:setFilter("nearest", "nearest")
      A.fonts[key] = with_fallback(font, size)
    end
  end
  return A.fonts[key]
end

--- The interface's **body** face at `size`: VT323 in the game face, the
--- chosen face at its body multiple (`UI_FACE_SPEC.body`) otherwise.
---
--- The web draws its prose roles — briefs, bubbles, help — in VT323 and its
--- chrome in Press Start 2P, and a face swap is measured against each. This
--- client draws its labels in `A.font`; this is here for a screen that wants
--- the web's body role, and it follows the interface face, not the code one.
function A.body(size)
  local spec = A.UI_FACE_SPEC[ui_face]
  size = math.max(8, math.floor((tonumber(size) or 8) * spec.body + 0.5))
  local key = "b" .. size .. ui_face
  if not A.fonts[key] then
    local font = spec.file and make(spec.file, size, spec.hinting)
    if font then
      A.fonts[key] = with_fallback(font, size, game_face(MONO_FILE, "v", size))
    else
      font = make(MONO_FILE, size) or love.graphics.newFont(size)
      A.fonts[key] = with_fallback(font, size)
    end
  end
  return A.fonts[key]
end

--- The pixel faces' own grids: the em, in pixels, each was drawn on.
---
--- **A pixel face is only legible at a whole multiple of its grid.** The
--- three home computers are 8×8 designs (cap 7 of 8 rows, which is the web's
--- "0.875 em"), the DOS and 둥근모 faces 8×16, GalmuriMono 12. Set at its
--- measured 0.64 of an 18 px request, PR Number 3 lands on 12 px — one and a
--- half screen pixels per design pixel — and its seven-row capitals come out
--- as grey mush, which on screen read as "far too small" though the cap
--- height matched VT323's to the pixel. So the measured size picks the
--- multiple and the grid decides the pixels: the nearest multiple, leaning up
--- (a quarter of a step past one is enough to take the next), never under
--- one. A browser gets away without this because it draws at the device's
--- resolution; this client draws on its own pixel grid and then scales.
local PIXEL_GRID = {
  dos = 16, dunggeunmo = 16, galmuri = 12, apple2 = 8, msx = 8, amiga = 8,
}
A.CODE_FACE_GRID = PIXEL_GRID

--- The pixel size `A.mono(size)` rasterises the chosen code face at.
function A.mono_px(size, face)
  face = face or code_face
  size = tonumber(size) or 8
  if face == "game" then return A.snap8(math.max(8, math.floor(size))) end
  local want = size * (CODE_SCALE[face] or 1)
  local grid = PIXEL_GRID[face]
  if grid then
    return grid * math.max(1, math.floor(want / grid + 0.75))
  end
  return math.max(8, math.floor(want + 0.5))
end

--- The code face at `size`: whichever the player chose (`A.setCodeFace`).
---
--- VT323 is snapped to the grid, as it always was. Every other face is set
--- at its measured multiple (`CODE_FACE_SCALE`), in whole pixels: snapping
--- 0.68 × 18 up to 16 is what drew Iosevka a third larger than VT323 at the
--- same step, and the table exists so that a swap does not do that.
---
--- Carrying VT323 and Unifont behind it: a player can paste a Chinese comment
--- into the editor, and a box where a character should be would look like
--- the client had corrupted their program.
function A.mono(size)
  size = A.mono_px(size)
  local key = "m" .. size .. code_face
  if not A.fonts[key] then
    -- The chosen face, or the game's own if the file is not there: a client
    -- built without the code faces, or a machine without Courier New, still
    -- draws code.
    local font = code_face ~= "game"
      and make(CODE_FILE[code_face], size, HINTING[code_face])
    if font then
      A.fonts[key] = with_fallback(font, size, game_face(MONO_FILE, "v", size))
    else
      font = make(MONO_FILE, size) or love.graphics.newFont(size)
      A.fonts[key] = with_fallback(font, size)
    end
  end
  return A.fonts[key]
end

--- The names the playground and the quest screens are written against: the
--- code face and the interface face, each respecting the player's choice.
A.code_font = A.mono
A.ui_font = A.font
A.body_font = A.body

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
--- `alpha` is for a cross-fade: `src/scenes/story.lua` draws the outgoing
--- painting, then the incoming one over it as it arrives, and a cover that
--- always painted at full opacity would make every cut a hard cut.
function A.cover(name, x, y, w, h, tint, alpha)
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
  love.graphics.setColor(1, 1, 1, alpha or 1)
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
