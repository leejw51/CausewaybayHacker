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

-- ------------------------------------------------------------- the roles
--
-- `docs/love2d-ui.md` §1, from the designer's spec: a calm dark felt carries
-- everything and four saturated accents carry meaning — **gold acts and
-- rewards, blue runs, red is wrong, green is right**. Each accent has a dark
-- pair for its solid shadow. The paint above is *history*; a component asks
-- for a *job*, and the old names are re-pointed below so every existing
-- call site lands on the new palette without being edited.
--
-- **`Theme.ink` is dark** — it is `edge`, the outline and the drop under a
-- label — and 62 call sites rely on it being dark. The role for *text* is
-- `Theme.text` (also `Theme.fg`).

local function hex(h)
  return { tonumber(h:sub(2, 3), 16) / 255, tonumber(h:sub(4, 5), 16) / 255,
    tonumber(h:sub(6, 7), 16) / 255, 1 }
end
T.hex = hex

T.felt = hex("#16203A")     -- the backdrop wash
T.bar = hex("#1E2A4A")      -- header and footer bars, an unselected chip
T.card = hex("#26345A")     -- a card
T.cardHi = hex("#30406C")   -- a hovered card, a keycap face
T.edge = hex("#0B1020")     -- every outline and every neutral shadow
T.codeBg = hex("#0E1426")   -- a code well
T.text = hex("#F4ECDC")     -- all prose and labels (10.4:1 on card)
T.mute = hex("#9AA3BF")     -- captions, metadata, a hint's verb (4.9:1)
T.gold, T.goldD = hex("#F5B83D"), hex("#A8741A")    -- act and reward
T.blue, T.blueD = hex("#3E8EF0"), hex("#1F4E94")    -- run and info
T.redA, T.redD = hex("#E8504A"), hex("#8E2A26")     -- wrong and danger
T.green, T.greenD = hex("#3FBF6A"), hex("#1F7A40")  -- right

-- The old names, re-pointed. A screen painted with `Theme.navy` is now
-- painted with a card; one painted with `Theme.dim` now reads at 4.9:1.
T.void = T.felt
T.navy = T.card
T.ink = T.edge
T.cream = T.text
T.dim = T.mute
T.coin = T.gold
T.red = T.redA
T.admit = T.green
T.sky = T.blue

-- The role names the components use.
T.bg = T.felt
T.surface = T.card
T.surface2 = T.cardHi
T.fg = T.text
T.fgDim = T.mute
T.inkDim = T.mute
T.accent = T.gold          -- the one primary: gold
T.accentD = T.goldD
T.accent2 = T.blue
T.good = T.green
T.bad = T.redA
T.warn = T.gold
T.shadow = T.edge
T.line = { T.text[1], T.text[2], T.text[3], 0.14 }   -- a hairline rule

T.roles = {
  bg = T.felt, bar = T.bar, surface = T.card, surface2 = T.cardHi, ink = T.text,
  inkDim = T.mute, accent = T.gold, good = T.green, bad = T.redA, warn = T.gold,
  gold = T.gold, shadow = T.edge, code = T.codeBg,
}

--- The dark pair of an accent, for the solid shadow under a button in it.
local DARK = { [T.gold] = T.goldD, [T.blue] = T.blueD, [T.redA] = T.redD, [T.green] = T.greenD }
function T.shadowOf(c)
  return DARK[c] or T.edge
end

--- The spacing scale, in virtual pixels: 4 · 8 · 12 · 16 · 24 · 32 · 48 and
--- no other values. `gutter` and `cardPad` are 24 in landscape, 16 upright.
T.space = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32, xxxl = 48 }
T.gap = 16            -- between cards
T.rowGap = 12         -- between rows inside a card

--- Corner radii.
T.radius = 8          -- a card, a button
T.radiusInner = 6     -- a card's inner fill, a chip, a code well
T.radiusSm = 4        -- a keycap
T.stroke = 2          -- the edge around everything

--- Solid shadows, in pixels down: a card, a button, a selected chip.
T.shadowDy = 6
T.buttonShadowDy = 5
T.chipShadowDy = 3
T.shadowAlpha = 0.85

--- The accent strip along a card's top inside edge, and a land stripe.
T.stripH = 4
T.landStripeH = 6

--- The type roles, in **pixels** of the interface face (`UI.font(role)`),
--- which never scale with F12: `display` 48, `title` 32, `label` 16. `read`
--- is Galmuri11 at 24 and `code` the chosen code face at 16, and those two
--- are the ones the type step moves. Line heights per the spec.
T.type = { display = 48, title = 32, label = 16, read = 24, code = 16, button = 16, buttonWide = 24 }

--- A canvas at least this wide is "wide": a 1920 fullscreen, where a 16 px
--- label at arm's length is too small to read. Buttons (and the keycaps
--- inside them) step up to `type.buttonWide` there — on the canvas width,
--- never on F12, so a row of buttons cannot break its own layout.
T.wideCanvas = 1600

--- The pixel size a button's label is set in on a canvas `vw` wide.
function T.buttonPx(vw)
  if (vw or 0) >= T.wideCanvas then return T.type.buttonWide end
  return T.type.button
end
T.leading = { display = 52, title = 36, label = 20, read = 30 }

--- Control heights. Every hit target is at least 44 tall, 48 upright.
T.control = { buttonL = 56, buttonM = 44, chip = 32, keycap = 24, keycapIn = 28,
  footer = 48, footerP = 64, header = 56, headerP = 72, gear = 40, touch = 44, touchP = 48 }

--- The widest a screen's content is laid out at before it is centred in the
--- canvas rather than stretched across it. `Layout.bounded` applies it.
T.maxContentW = 1232

--- Motion, in seconds. `docs/love2d-ui.md` §motion.
T.motion = {
  hover = 0.12,      -- a button reaching its hover lift and scale
  press = 0.06,      -- the push in
  release = 0.12,    -- and the spring back (outBack)
  enter = 0.26,      -- a card dealing in and settling
  stagger = 0.04,    -- between one card and the next
  toastIn = 0.20,    -- a toast sliding down
  toastHold = 2.4,
  toastOut = 0.16,
  modal = 0.22,      -- a sheet arriving
  transition = 0.12, -- the fade between two scenes
  count = 0.6,       -- a number counting up
  sway = 0.4,        -- Hz of the idle tilt under a pointer
}


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

--- `c` taken towards black by `k` (0 leaves it, 1 is black). The Balatro
--- shadow: the same hue, darker — never a grey, which reads as a smudge.
function T.darken(c, k)
  k = 1 - (k or 0.45)
  return { c[1] * k, c[2] * k, c[3] * k, c[4] or 1 }
end

--- `c` taken towards white by `k`. For a hovered surface.
function T.lighten(c, k)
  k = k or 0.15
  return { c[1] + (1 - c[1]) * k, c[2] + (1 - c[2]) * k, c[3] + (1 - c[3]) * k, c[4] or 1 }
end

--- `a` and `b` mixed, `t` of the way from `a` to `b`.
function T.mix(a, b, t)
  return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t,
    a[3] + (b[3] - a[3]) * t, (a[4] or 1) + ((b[4] or 1) - (a[4] or 1)) * t }
end

return T
