-- The components: cards, buttons, chips, keycaps, labels, the footer, the
-- toast dock and the settings sheet. `docs/love2d-ui.md` is the manual.
--
-- The idiom is Balatro's, adapted to a game about code: a calm dark felt,
-- rounded cards and buttons with a **solid** same-hue shadow under them so
-- everything has depth, four accents that each mean one thing (gold acts,
-- blue runs, red is wrong, green is right), one chunky pixel face at three
-- sizes, chunky tactile buttons that lift and sway under the pointer and
-- push in on a click, and very little chrome. Code is the hero.
--
-- Two layers live here:
--
--   * **the roles** — `UI.font("title")`, `UI.label`, `UI.card`, `UI.button`
--     with a variant, `UI.chip`, `UI.keycap`, `UI.modal`, the toast dock and
--     the one-line footer. Fixed pixel sizes (16 / 32 / 48) that never move
--     with F12, so a header or a footer cannot overprint itself at step 4.
--   * **the legacy entry points** — `UI.text(size)`, `UI.panel`, `UI.well`,
--     `UI.button(x, y, w, h, label, state, size)` with seven arguments, and
--     the rest of what every scene already calls. They keep working, drawn
--     in the new furniture, so a screen that has not been rebuilt yet is
--     not broken; the scene agents move each screen onto the roles.
--
-- Everything takes virtual coordinates and nothing here knows which scene
-- it is in. Motion state is held by `src/juice.lua` under a key (`opts.id`
-- or the label), never by position, so a card that lifts does not thrash
-- its own hover.

local Theme = require("src.theme")
local Assets = require("src.assets")
local Layout = require("src.layout")
local I18n = require("src.i18n")
local Juice = require("src.juice")
local Anim = require("src.anim")
local Ease = require("src.ease")
local ArtFrame = require("src.artframe")
local Fx = require("src.fx")

local UI = {}

function UI.setColor(c, alpha)
  if alpha then
    love.graphics.setColor(c[1], c[2], c[3], alpha)
  else
    love.graphics.setColor(c[1], c[2], c[3], c[4] or 1)
  end
end

-- ------------------------------------------------------------------- type

--- The interface face at exactly `px` pixels, whatever face F8 has chosen.
---
--- `Assets.font(size)` multiplies a non-default face by its measured
--- `pixel` scale and snaps the default one onto the 8-grid, so the size it
--- is asked for is `px` taken back through that scale: 16 / 32 / 48 come
--- out at 16 / 32 / 48 in Neo둥근모 (×1.25), Galmuri (×1), Comic (×1.2)
--- and Press Start 2P alike. A role name (`"label"`, `"title"`,
--- `"display"`) is looked up in `Theme.type`.
function UI.font(role_or_px)
  local px = Theme.type[role_or_px] or tonumber(role_or_px) or Theme.type.label
  local spec = Assets.UI_FACE_SPEC[Assets.uiFace()] or { pixel = 1 }
  return Assets.font(px / (spec.pixel or 1))
end

--- The pixel size of a role.
function UI.px(role)
  return Theme.type[role] or Theme.type.label
end

--- The line height of a role: the spec's leading, never less than the
--- face's own height (a CJK fallback inks under the Latin line box).
function UI.lead(role)
  local font = UI.font(role)
  local h = font:getHeight()
  if I18n.is_cjk() then h = h + math.floor(h / 8) end
  return math.max(Theme.leading[role] or h, h)
end

local read_cache = {}

--- The size the reading face is drawn at: 24, moved by the type step onto
--- Galmuri's 12-pixel grid — the one role besides code that F12 scales.
function UI.readPx()
  local want = Theme.type.read * Layout.fontScale() * Layout.growth()
  return math.max(24, math.floor(want / 12 + 0.5) * 12)
end

--- The reading face: Galmuri11, with the interface face and Unifont behind
--- it for a glyph it lacks. For any paragraph over two lines.
function UI.readFont()
  local px = UI.readPx()
  if not read_cache[px] then
    local ok, font = pcall(function()
      if not love.filesystem.getInfo("assets/fonts/Galmuri11.ttf") then return nil end
      return love.graphics.newFont("assets/fonts/Galmuri11.ttf", px, "mono")
    end)
    font = ok and font or nil
    if font then
      font:setFilter("nearest", "nearest")
      local behind = { UI.font(32) }
      local cjk = Assets.cjk_font and Assets.cjk_font(px)
      if cjk then behind[#behind + 1] = cjk end
      pcall(font.setFallbacks, font, unpack(behind))
    else
      font = UI.font(32)
    end
    read_cache[px] = font
  end
  return read_cache[px]
end

local logo_cache = {}

--- Press Start 2P at `px`, for the logo and nothing else — the one place
--- the square arcade face is kept whatever F8 says. The interface face
--- stands behind it, so a translated title still draws.
function UI.logoFont(px)
  px = Assets.snap8(px)
  if not logo_cache[px] then
    local ok, font = pcall(function()
      if not love.filesystem.getInfo("assets/fonts/PressStart2P-Regular.ttf") then return nil end
      return love.graphics.newFont("assets/fonts/PressStart2P-Regular.ttf", px, "mono")
    end)
    font = ok and font or nil
    if font then
      font:setFilter("nearest", "nearest")
      local behind = { UI.font(px >= 48 and 48 or 32) }
      local cjk = Assets.cjk_font and Assets.cjk_font(px)
      if cjk then behind[#behind + 1] = cjk end
      pcall(font.setFallbacks, font, unpack(behind))
    else
      font = UI.font(48)
    end
    logo_cache[px] = font
  end
  return logo_cache[px]
end

local button_cache = {}

--- The face a button's label is set in: `Theme.buttonPx(Layout.vw)` pixels
--- — the interface face at 16 on a canvas under 1600 wide, and **Galmuri11
--- at 24, drawn twice a pixel apart for weight**, on a wide one (a 1920
--- fullscreen). Chosen on a specimen: Neo둥근모 at 24 is a 1.5× resample of
--- a 16-cell face and reads uneven; Galmuri at 24 sits on its own 12-grid
--- and is crisp. Returns `font, bold` — `bold` says to double the print.
function UI.buttonFont()
  local px = Theme.buttonPx(Layout.vw)
  if px <= 16 then return UI.font(16), false end
  if not button_cache[px] then
    local ok, font = pcall(function()
      if not love.filesystem.getInfo("assets/fonts/Galmuri11.ttf") then return nil end
      return love.graphics.newFont("assets/fonts/Galmuri11.ttf", px, "mono")
    end)
    font = ok and font or nil
    if font then
      font:setFilter("nearest", "nearest")
      local behind = { UI.font(32) }
      local cjk = Assets.cjk_font and Assets.cjk_font(px)
      if cjk then behind[#behind + 1] = cjk end
      pcall(font.setFallbacks, font, unpack(behind))
      button_cache[px] = { font, true }
    else
      button_cache[px] = { UI.font(32), false }
    end
  end
  return button_cache[px][1], button_cache[px][2]
end

--- A label with the lift every button label gets: a one-pixel edge shadow
--- under it (not for dark ink on gold), doubled a pixel to the right when
--- the face asks for weight. `align` with `w` centres it.
function UI.buttonLabel(text, x, y, font, color, bold, opts)
  opts = opts or {}
  love.graphics.setFont(font)
  local alpha = opts.alpha or 1
  local tw = font:getWidth(text) + (bold and 1 or 0)
  if opts.w then
    if opts.align == "left" then x = x
    elseif opts.align == "right" then x = x + opts.w - tw
    else x = x + (opts.w - tw) / 2 end
  end
  x, y = math.floor(x), math.floor(y)
  if opts.shadow ~= false then
    UI.setColor(opts.shadowColor or Theme.edge, 0.8 * alpha)
    love.graphics.print(text, x + 1, y + 1)
    if bold then love.graphics.print(text, x + 2, y + 1) end
  end
  UI.setColor(color, (color[4] or 1) * alpha)
  love.graphics.print(text, x, y)
  if bold then love.graphics.print(text, x + 1, y) end
  love.graphics.setColor(1, 1, 1, 1)
  return tw
end

-- ----------------------------------------------------------- legacy type

--- The pixel size an **authored** size lands on under the current face.
---
--- `Layout.ui` doubles it and takes it through the type step. In Press
--- Start 2P that is snapped onto the 8-grid as it always was; in a 16-cell
--- face (Neo둥근모, DOS) it is snapped onto the 16-grid leaning *down* —
--- 16..27 → 16, 28..43 → 32, 44+ → 48 — because a bitmap face off its grid
--- is grey mush, and the spec's ladder is 16 / 32 / 48 and nothing between.
function UI.legacyPx(size)
  local px = Layout.ui(size or 12)
  if Assets.uiFace() == "game" then return Assets.snap8(px) end
  return math.max(16, math.floor(px / 16 + 0.25) * 16)
end

--- The font for an authored size. Every legacy entry point goes through
--- this one pair, so a paragraph measured at one size is drawn at it.
function UI.fontFor(size)
  if Assets.uiFace() == "game" then return Assets.font(Layout.ui(size or 12)) end
  return UI.font(UI.legacyPx(size))
end

--- One line at an authored size, with a one-pixel edge drop so it reads
--- over art. `size` is authored (see `UI.fontFor`).
function UI.text(text, x, y, size, color, align, width)
  local font = UI.fontFor(size)
  love.graphics.setFont(font)
  if align and width then
    UI.setColor(Theme.edge, 0.65)
    love.graphics.printf(text, x + 1, y + 1, width, align)
    UI.setColor(color or Theme.text)
    love.graphics.printf(text, x, y, width, align)
  else
    UI.setColor(Theme.edge, 0.65)
    love.graphics.print(text, x + 1, y + 1)
    UI.setColor(color or Theme.text)
    love.graphics.print(text, x, y)
  end
  love.graphics.setColor(1, 1, 1, 1)
  return UI.lineHeight(size)
end

function UI.textWidth(text, size)
  return UI.fontFor(size):getWidth(text)
end

--- The pixel height of a line at an authored size, an eighth taller in a
--- CJK language (Unifont inks under the Latin line box).
function UI.lineHeight(size)
  local h = UI.fontFor(size):getHeight()
  if I18n.is_cjk() then h = h + math.floor(h / 8) end
  return h
end

--- Split a string into UTF-8 characters.
function UI.chars(text)
  local out = {}
  local i, n = 1, #text
  while i <= n do
    local b = text:byte(i)
    local width = 1
    if b >= 0xF0 then width = 4
    elseif b >= 0xE0 then width = 3
    elseif b >= 0xC0 then width = 2 end
    out[#out + 1] = text:sub(i, i + width - 1)
    i = i + width
  end
  return out
end

--- Wrap a paragraph to a pixel width with `font`. A word longer than the
--- line is broken by character (which is also the right rule for a script
--- without spaces).
function UI.wrapWith(text, width, font)
  local space = font:getWidth(" ")
  local lines = {}
  local function break_long(word)
    local pieces, current = {}, ""
    for _, ch in ipairs(UI.chars(word)) do
      if current ~= "" and font:getWidth(current .. ch) > width then
        pieces[#pieces + 1] = current
        current = ch
      else
        current = current .. ch
      end
    end
    if current ~= "" then pieces[#pieces + 1] = current end
    return pieces
  end
  for raw in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    if raw == "" then
      lines[#lines + 1] = ""
    else
      local line, line_w = "", 0
      for word in raw:gmatch("%S+") do
        local ww = font:getWidth(word)
        if ww > width then
          if line ~= "" then lines[#lines + 1] = line; line, line_w = "", 0 end
          for _, piece in ipairs(break_long(word)) do lines[#lines + 1] = piece end
        elseif line == "" then
          line, line_w = word, ww
        elseif line_w + space + ww <= width then
          line = line .. " " .. word
          line_w = line_w + space + ww
        else
          lines[#lines + 1] = line
          line, line_w = word, ww
        end
      end
      if line ~= "" then lines[#lines + 1] = line end
    end
  end
  return lines
end

--- Wrap at an authored size.
function UI.wrap(text, width, size)
  return UI.wrapWith(text, width, UI.fontFor(size or 8))
end

--- The largest authored size at or under `size` at which `text` fits
--- `width` on one line, never under `floor`.
function UI.fitSize(text, width, size, floor)
  size = size or 8
  floor = floor or 5
  while size > floor and UI.textWidth(text, size) > width do
    size = size - 1
  end
  return size
end

--- `text` cut to `width` with an ellipsis, measured with `font`.
function UI.ellipsizeWith(text, width, font)
  text = tostring(text or "")
  if font:getWidth(text) <= width then return text end
  local chars = UI.chars(text)
  for n = #chars - 1, 1, -1 do
    local cut = table.concat(chars, "", 1, n):gsub("%s+$", "") .. "…"
    if font:getWidth(cut) <= width then return cut end
  end
  return ""
end

function UI.ellipsize(text, width, size)
  return UI.ellipsizeWith(text, width, UI.fontFor(size))
end

--- A paragraph at an authored size, wrapped and drawn line by line.
--- Returns the height it took.
function UI.paragraph(text, x, y, width, size, color, max_lines)
  local lines = UI.wrap(text, width, size)
  local step = UI.lineHeight(size) + 2
  local n = max_lines and math.min(#lines, max_lines) or #lines
  for i = 1, n do
    UI.text(lines[i], x, y + (i - 1) * step, size, color)
  end
  return math.max(0, n * step - 2)
end

-- -------------------------------------------------------------- role type

--- The width of `text` in a role.
function UI.labelWidth(text, role)
  return UI.font(role or "label"):getWidth(tostring(text or ""))
end

--- One line in a role: `display` 48, `title` 32, `label` 16.
---
--- `opts.color` (default text), `opts.align` with `opts.width`
--- (`"left" | "center" | "right"`), `opts.caps` upper-cases, `opts.ellipsis`
--- cuts to `opts.width` with "…" instead of letting it run, `opts.shadow`
--- is the one-pixel edge drop (on by default for title and display),
--- `opts.alpha`. Returns the role's line height.
function UI.label(text, x, y, role, opts)
  opts = opts or {}
  role = role or "label"
  local font = UI.font(role)
  text = tostring(text or "")
  if opts.caps then text = text:upper() end
  if opts.ellipsis and opts.width then text = UI.ellipsizeWith(text, opts.width, font) end
  love.graphics.setFont(font)
  local shadow = opts.shadow
  if shadow == nil then shadow = role ~= "label" end
  local alpha = opts.alpha or 1
  local color = opts.color or Theme.text
  -- Vertically: the role's line box, with the glyphs centred in it.
  local dy = math.floor((UI.lead(role) - font:getHeight()) / 2)
  if opts.align and opts.width then
    if shadow then
      UI.setColor(Theme.edge, 0.7 * alpha)
      love.graphics.printf(text, x + 1, y + dy + 1, opts.width, opts.align)
    end
    UI.setColor(color, (color[4] or 1) * alpha)
    love.graphics.printf(text, x, y + dy, opts.width, opts.align)
  else
    if shadow then
      UI.setColor(Theme.edge, 0.7 * alpha)
      love.graphics.print(text, x + 1, y + dy + 1)
    end
    UI.setColor(color, (color[4] or 1) * alpha)
    love.graphics.print(text, x, y + dy)
  end
  love.graphics.setColor(1, 1, 1, 1)
  return UI.lead(role)
end

--- A paragraph in the reading face, wrapped to `w`. `opts.maxLines` ends
--- the last line in "…" rather than cutting; `opts.color` (default text);
--- `opts.align`. Returns the height drawn; `UI.readHeight` measures it.
function UI.read(text, x, y, w, opts)
  opts = opts or {}
  local font = UI.readFont()
  local lines = UI.wrapWith(tostring(text or ""), w, font)
  local lead = math.max(Theme.leading.read, font:getHeight() + 4)
  if UI.readPx() > 24 then lead = math.floor(font:getHeight() * 1.25) end
  local n = #lines
  if opts.maxLines and n > opts.maxLines then
    n = opts.maxLines
    -- The last line ends in "…": appended when it fits, cut to make room
    -- for it when it does not.
    lines[n] = UI.ellipsizeWith(lines[n] .. "…", w, font)
  end
  love.graphics.setFont(font)
  for i = 1, n do
    local ly = y + (i - 1) * lead + math.floor((lead - font:getHeight()) / 2)
    if opts.align then
      UI.setColor(opts.color or Theme.text, opts.alpha)
      love.graphics.printf(lines[i], x, ly, w, opts.align)
    else
      UI.setColor(opts.color or Theme.text, opts.alpha)
      love.graphics.print(lines[i], x, ly)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
  return n * lead
end

function UI.readHeight(text, w, maxLines)
  local font = UI.readFont()
  local lines = UI.wrapWith(tostring(text or ""), w, font)
  local lead = math.max(Theme.leading.read, font:getHeight() + 4)
  if UI.readPx() > 24 then lead = math.floor(font:getHeight() * 1.25) end
  return math.min(#lines, maxLines or #lines) * lead, lead
end

-- -------------------------------------------------------------- surfaces

--- A rounded rectangle.
function UI.rrect(mode, x, y, w, h, r)
  if w <= 0 or h <= 0 then return end
  r = math.min(r or Theme.radius, w / 2, h / 2)
  love.graphics.rectangle(mode, x, y, w, h, r, r, 8)
end

--- The solid shadow under a thing: the same shape, `dy` lower, in `color`
--- (default edge at 85%). Drawn **before** the thing.
function UI.shadow(x, y, w, h, r, color, dy, alpha)
  dy = dy or Theme.shadowDy
  if dy <= 0 then return end
  UI.setColor(color or Theme.edge, alpha or (color and 1 or Theme.shadowAlpha))
  UI.rrect("fill", x, y + dy, w, h, r)
  love.graphics.setColor(1, 1, 1, 1)
end

--- A 2 px edge stroke, inside the rectangle.
function UI.stroke(x, y, w, h, r, color, width)
  width = width or Theme.stroke
  love.graphics.setLineWidth(width)
  UI.setColor(color or Theme.edge)
  UI.rrect("line", x + width / 2, y + width / 2, w - width, h - width, (r or Theme.radius) - width / 2)
  love.graphics.setColor(1, 1, 1, 1)
end

--- The card. Returns the content rect `cx, cy, cw, ch` inside the padding.
---
---   * `opts.variant`: `"card"` (default) — fill `card`, 2 px edge, solid
---     shadow +6; `"well"` — `codeBg`, inset 1 px edge line, no shadow, for
---     code and logs; `"hero"` — the gold art frame (`opts.art`, default
---     `ui_quiz_card`; `ui_plaque` for a wide strip) over the same shadow,
---     **at most once per screen**; `"bar"` — the header/footer fill, no
---     radius, no shadow; `"flat"` — fill only.
---   * `opts.strip`: a 4 px accent strip along the top inside edge, in that
---     colour (gold on the thing the screen is about, blue on information).
---   * `opts.stripe`: a 6 px land stripe down the left inside edge.
---   * `opts.hot`: 0..1 (or true) — the fill goes to `cardHi`, the edge to
---     gold. `opts.selected`: a gold edge. `opts.edge` overrides the edge.
---   * `opts.fill`, `opts.alpha`, `opts.radius`, `opts.shadow` (false to
---     drop it), `opts.pad` (default 24, 16 upright).
function UI.card(x, y, w, h, opts)
  opts = opts or {}
  local variant = opts.variant or "card"
  local r = opts.radius or Theme.radius
  local alpha = opts.alpha or 1
  local hot = opts.hot == true and 1 or (tonumber(opts.hot) or 0)
  local pad = opts.pad or (Layout.isPortrait() and Theme.space.lg or Theme.space.xl)

  if variant == "hero" then
    if opts.shadow ~= false then
      UI.shadow(x, y, w, h, r, nil, opts.shadowDy or Theme.shadowDy, Theme.shadowAlpha * alpha)
    end
    if not ArtFrame.draw(opts.art or "ui_quiz_card", x, y, w, h, { scale = opts.artScale or 0.75, alpha = alpha }) then
      -- No art: a card with a gold strip is the same statement.
      local o = {}
      for k, v in pairs(opts) do o[k] = v end
      o.variant, o.strip = "card", o.strip or Theme.gold
      return UI.card(x, y, w, h, o)
    end
    return x + pad, y + pad, w - pad * 2, h - pad * 2
  end

  local fill = opts.fill
  if variant == "well" then
    fill = fill or Theme.codeBg
    r = opts.radius or Theme.radiusInner
  elseif variant == "bar" then
    fill = fill or Theme.bar
    r = 0
  else
    fill = fill or Theme.card
  end
  if hot > 0 and variant == "card" then fill = Theme.mix(fill, Theme.cardHi, hot) end

  if (variant == "card" or variant == "flat") and opts.shadow ~= false and variant ~= "flat" then
    UI.shadow(x, y, w, h, r, opts.shadowColor, opts.shadowDy or Theme.shadowDy, Theme.shadowAlpha * alpha)
  end
  UI.setColor(fill, (fill[4] or 1) * alpha)
  UI.rrect("fill", x, y, w, h, r)

  -- The strips are a rounded rect with its far corners painted back over
  -- in the fill — **no scissor**: a scissor is in screen space and ignores
  -- the push/scale a lifted card is drawn under, which cut the strip off
  -- every selected card.
  if opts.strip then
    local sh = opts.stripH or Theme.stripH
    UI.setColor(opts.strip, alpha)
    UI.rrect("fill", x, y, w, sh + r, r)
    UI.setColor(fill, (fill[4] or 1) * alpha)
    love.graphics.rectangle("fill", x, y + sh, w, r)
  end
  if opts.stripe then
    UI.setColor(opts.stripe, alpha)
    UI.rrect("fill", x, y, Theme.landStripeH + r, h, r)
    UI.setColor(fill, (fill[4] or 1) * alpha)
    love.graphics.rectangle("fill", x + Theme.landStripeH, y, r, h)
  end

  if variant == "well" then
    love.graphics.setLineWidth(1)
    UI.setColor(opts.edge or Theme.edge, alpha)
    UI.rrect("line", x + 0.5, y + 0.5, w - 1, h - 1, r)
  elseif variant ~= "flat" and variant ~= "bar" then
    local edge = opts.edge or Theme.edge
    if opts.selected then edge = Theme.gold
    elseif hot > 0 then edge = Theme.mix(edge, Theme.gold, hot) end
    UI.stroke(x, y, w, h, r, Theme.withAlpha(edge, alpha))
  end
  love.graphics.setColor(1, 1, 1, 1)
  return x + pad, y + pad, w - pad * 2, h - pad * 2
end

--- Legacy: a cream panel with a hard border. Drawn as a card now (radius,
--- edge, shadow), the cream kept because the text inside it is dark.
function UI.panel(x, y, w, h, opts)
  opts = opts or {}
  UI.card(x, y, w, h, {
    fill = opts.fill or Theme.panel, alpha = opts.alpha, edge = opts.border,
    stripe = opts.tint, pad = 0,
  })
end

--- Legacy: a dark panel, for the code editor and the log.
function UI.well(x, y, w, h, tint)
  UI.card(x, y, w, h, { variant = "well", edge = tint, pad = 0 })
end

-- --------------------------------------------------------------- buttons

--- Every filled variant carries its label in full `text` (or dark ink on
--- gold) over a face that stands off the bar: a secondary button is
--- `cardHi`, not `card`, because `card` on `bar` was the "buttons are not
--- clear" report. `shadowOn` is whether the label gets its edge drop.
local VARIANT = {
  primary = { fill = Theme.gold, text = Theme.edge, shadow = Theme.goldD, shadowOn = false },
  run = { fill = Theme.blue, text = Theme.text, shadow = Theme.blueD, shadowOn = true },
  secondary = { fill = Theme.cardHi, text = Theme.text, shadow = Theme.edge, shadowOn = true },
  ghost = { fill = nil, text = Theme.text, shadow = nil, shadowOn = true },
  danger = { fill = Theme.redA, text = Theme.text, shadow = Theme.redD, shadowOn = true },
}

UI.VARIANT = VARIANT

--- Where the pointer is, in virtual coordinates, or nil (under a drive
--- script, or outside the letterbox).
local function pointer()
  if not (love.mouse and love.mouse.getPosition) then return nil end
  local ok, mx, my = pcall(love.mouse.getPosition)
  if not ok then return nil end
  return Layout.toVirtual(mx, my)
end

UI.pointer = pointer

local function inside(r, x, y)
  return r and x and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

UI.inside = inside

--- The keycap's width for `key` in `font` (the label face by default):
--- the label plus 16, never under the cap's height.
function UI.keycapWidth(key, h, font)
  font = font or UI.font("label")
  return math.max(h or Theme.control.keycap, font:getWidth(tostring(key)) + 16)
end

--- A keycap: 24 tall (28 inside a button; `opts.h`), radius 4, a lifted
--- `cardHi` face with a 2 px edge and a 3 px darker lip at the bottom, the
--- label in full `text` with its edge drop. `opts.font` sets the face (a
--- button hands its own in). Returns its width.
function UI.keycap(x, y, key, opts)
  opts = opts or {}
  local font = opts.font or UI.font("label")
  local h = opts.h or math.max(Theme.control.keycap, font:getHeight() + 8)
  local w = UI.keycapWidth(key, h, font)
  local alpha = opts.alpha or 1
  -- The lip is the shadow: the cap stands 3 px proud of it.
  UI.setColor(Theme.edge, alpha)
  UI.rrect("fill", x, y + 3, w, h - 3, Theme.radiusSm)
  UI.setColor(opts.fill or Theme.lighten(Theme.cardHi, 0.1), alpha)
  UI.rrect("fill", x, y, w, h - 3, Theme.radiusSm)
  UI.stroke(x, y, w, h - 3, Theme.radiusSm, Theme.withAlpha(Theme.edge, alpha))
  UI.buttonLabel(tostring(key), x, y + math.floor((h - 3 - font:getHeight()) / 2), font,
    opts.color or Theme.text, opts.bold, { w = w, alpha = alpha })
  return w
end

--- Push a button in: the next frames of `UI.button` with this id draw it
--- pressed, a puff of sparks leaves its centre, and the select sound
--- plays. Scenes call it from their own hit test, with the rect they hit.
function UI.press(id, rect, opts)
  opts = opts or {}
  Juice.trigger("press:" .. tostring(id))
  if rect and opts.fx ~= false then
    Fx.burst(rect.x + rect.w / 2, rect.y + rect.h / 2, "sparks", { n = 0.6 })
  end
  if opts.sfx ~= false then require("src.sfx").play(opts.sfx or "select") end
end

--- The width a button needs for `label` (and `opts.key`), and the height
--- its font needs. Size a row from these; `UI.button` never shrinks a
--- label and grows its box to fit one.
function UI.buttonSize(label, opts)
  opts = opts or {}
  local font, bold
  if opts.role == "title" or (opts.h or 0) >= Theme.control.buttonL then
    font, bold = UI.font("title"), false
  else
    font, bold = UI.buttonFont()
  end
  local padx = opts.padx or (font:getHeight() >= 32 and Theme.space.xl or Theme.space.lg)
  local cap_w = opts.key and (UI.keycapWidth(opts.key, font:getHeight() + 8, font) + Theme.space.sm) or 0
  local w = font:getWidth(tostring(label or "")) + (bold and 1 or 0) + padx * 2 + cap_w
  local h = font:getHeight() + (font:getHeight() >= 32 and 24 or 20)
  return w, h, font, bold, padx, cap_w
end

--- The button.
---
---   `UI.button(x, y, w, h, label, state, size, opts)`
---
--- `state` is `"normal" | "hot" | "disabled"` — `hot` is **the keyboard
--- cursor as well as the pointer**, and it changes the colour (a gold edge
--- and a brighter face), not only the motion, so a selection made with the
--- arrow keys is as visible as one made with the mouse. `size` is the
--- legacy authored label size and is ignored: the label is set in
--- `UI.buttonFont()` (16 on a canvas under 1600 wide, Galmuri 24 doubled on
--- a wider one), or the 32 title face in a button 56 tall or more.
---
--- **The label is never ellipsised or shrunk.** A box too small for its
--- label grows, centred on the rect it was given, and the rect it actually
--- drew is returned — size a row from `UI.buttonSize` and there is nothing
--- to grow.
---
--- `opts.variant`: `primary` (gold, one per screen), `run` (blue), the
--- default `secondary`, `ghost` (hollow; tertiary actions only), `danger`.
--- `opts.id` keys the motion state (default: the label). `opts.key` draws a
--- keycap inside, on the right. `opts.lift` is the hover lift (default 2).
--- `opts.sway = false` turns the idle tilt off.
function UI.button(x, y, w, h, label, state, size, opts)
  opts = opts or {}
  state = state or "normal"
  local variant = VARIANT[opts.variant or "secondary"] or VARIANT.secondary
  local id = tostring(opts.id or label)
  local disabled = state == "disabled"
  local hot = (state == "hot") and 1 or 0
  local a = disabled and 0 or Juice.follow("btn:" .. id, hot, { speed = 22 })
  local press = disabled and 0 or Juice.pressed("press:" .. id)
  local alpha = opts.alpha or 1
  local shown = tostring(label or "")

  -- Measured from the label: the box never shrinks it.
  local need_w, need_h, font, bold, padx, cap_w = UI.buttonSize(shown, { role = opts.role, h = h, padx = opts.padx, key = opts.key })
  if shown ~= "" and w < need_w then x = x - math.floor((need_w - w) / 2); w = need_w end
  if h < need_h then y = y - math.floor((need_h - h) / 2); h = need_h end

  local lift = (opts.lift or 2) * a
  local scale = 1 + ((opts.scale or 1.03) - 1) * a
  local sway = 0
  if opts.sway ~= false and a > 0.01 then
    sway = math.sin(Anim.now() * math.pi * 2 * Theme.motion.sway + x * 0.01) * 1.5 * a * math.pi / 180
  end
  local cx, cy = x + w / 2, y + h / 2
  love.graphics.push()
  love.graphics.translate(cx, cy - lift + 4 * press)
  love.graphics.rotate(sway)
  love.graphics.scale(scale, scale)
  love.graphics.translate(-cx, -cy)

  local r = Theme.radius
  local fill = variant.fill
  local text = variant.text
  local label_shadow = variant.shadowOn
  if disabled then
    fill = variant.fill and Theme.bar or nil
    text = Theme.withAlpha(Theme.mute, 0.7)
    label_shadow = false
  elseif variant.fill == nil then
    -- Ghost: hollow at rest, a face under the pointer.
    if a > 0.01 then
      UI.setColor(Theme.cardHi, 0.7 * a * alpha)
      UI.rrect("fill", x, y, w, h, r)
    end
    text = Theme.withAlpha(Theme.text, 0.85 + 0.15 * a)
  end
  if fill then
    if variant.shadow and not disabled then
      local dy = Theme.buttonShadowDy - (Theme.buttonShadowDy - 1) * press
      UI.setColor(variant.shadow, alpha)
      UI.rrect("fill", x, y + dy, w, h, r)
    end
    local face = fill
    if a > 0 and not disabled then face = Theme.lighten(fill, 0.14 * a) end
    UI.setColor(face, alpha)
    UI.rrect("fill", x, y, w, h, r)
    local edge = Theme.edge
    if not disabled and (hot > 0 or a > 0.5) then edge = Theme.mix(Theme.edge, Theme.gold, math.max(hot, a)) end
    UI.stroke(x, y, w, h, r, Theme.withAlpha(edge, alpha))
  elseif hot > 0 then
    UI.stroke(x, y, w, h, r, Theme.withAlpha(Theme.gold, alpha * 0.9))
  end

  -- The label, whole, and the keycap on the right in the same face.
  local ty = y + math.floor((h - font:getHeight()) / 2)
  local room = w - padx * 2 - cap_w
  local tx = x + padx
  local tw = font:getWidth(shown) + (bold and 1 or 0)
  if opts.align ~= "left" then tx = x + padx + math.floor((room - tw) / 2) end
  if opts.key then
    local cap_h = font:getHeight() + 8
    UI.keycap(x + w - padx - (cap_w - Theme.space.sm), y + math.floor((h - cap_h) / 2), opts.key,
      { h = cap_h, font = font, bold = bold, alpha = alpha,
        color = disabled and Theme.mute or nil })
  end
  if shown ~= "" then
    UI.buttonLabel(shown, tx, ty, font, text, bold, { alpha = alpha, shadow = label_shadow,
      shadowColor = opts.variant == "primary" and Theme.goldD or nil })
  end
  love.graphics.pop()
  return { x = x, y = y, w = w, h = h }
end

--- A chip: 32 tall, radius 6, padding 12, label 16 CAPS. Unselected is
--- `bar` and mute; selected is gold with ink text and a 3 px gold-dark
--- shadow. `opts.color` makes it a land badge (that colour's fill, ink
--- text). `opts.hot`. Returns its width; `UI.chipWidth` measures it.
function UI.chipWidth(label)
  return UI.font("label"):getWidth(tostring(label or ""):upper()) + Theme.space.md * 2
end

function UI.chip(x, y, label, opts)
  opts = opts or {}
  local h = opts.h or Theme.control.chip
  local text = tostring(label or ""):upper()
  local font = UI.font("label")
  local w = opts.w or (font:getWidth(text) + Theme.space.md * 2)
  local alpha = opts.alpha or 1
  local r = Theme.radiusInner
  local fill, ink, drop
  if opts.selected then
    fill, ink, drop = Theme.gold, Theme.edge, false
    UI.setColor(Theme.goldD, alpha)
    UI.rrect("fill", x, y + Theme.chipShadowDy, w, h, r)
  elseif opts.color then
    fill, ink, drop = opts.color, Theme.edge, false
  else
    -- Unselected: a lifted face and the label in full text — a chip in
    -- `bar` with mute text is the same faint box the buttons were.
    fill, ink, drop = opts.hot and Theme.lighten(Theme.cardHi, 0.14) or Theme.cardHi, Theme.text, true
  end
  UI.setColor(fill, alpha)
  UI.rrect("fill", x, y, w, h, r)
  UI.stroke(x, y, w, h, r, Theme.withAlpha(opts.selected and Theme.goldD or Theme.edge, alpha))
  UI.buttonLabel(text, x, y + math.floor((h - font:getHeight()) / 2), font, ink, false,
    { w = w, alpha = alpha, shadow = drop })
  return w
end

-- ---------------------------------------------------------------- hints

--- `"SPACE start   F10 story"` as `{ { key = "SPACE", verb = "start" }, … }`:
--- items are separated by two or more spaces, and the first word of each
--- is the key. A scene can hand the footer that list directly instead.
function UI.parseHint(str)
  local items = {}
  for chunk in (tostring(str or "") .. "  "):gmatch("(.-)%s%s+") do
    chunk = chunk:gsub("^%s+", "")
    if chunk ~= "" then
      local key, verb = chunk:match("^(%S+)%s*(.*)$")
      if key then items[#items + 1] = { key = key, verb = verb or "" } end
    end
  end
  return items
end

--- The width of a row of hints: cap + 8 + verb per item, 24 between.
function UI.hintWidth(items, measure)
  measure = measure or function(s) return UI.font("label"):getWidth(s) end
  local total = 0
  for i, it in ipairs(items) do
    local cap = math.max(Theme.control.keycap, measure(it.key) + 16)
    total = total + cap + (it.verb ~= "" and (Theme.space.sm + measure(it.verb)) or 0)
    if i > 1 then total = total + Theme.space.xl end
  end
  return total
end

--- **Pure.** The longest prefix of `items` whose row fits `room`, at most
--- `cap` of them. `measure(text)` is injected so a test can run it with a
--- ruler instead of a font.
function UI.fitHints(items, room, cap, measure)
  local kept = {}
  for i, it in ipairs(items) do
    if cap and #kept >= cap then break end
    kept[#kept + 1] = it
    if UI.hintWidth(kept, measure) > room then
      kept[#kept] = nil
      break
    end
  end
  return kept
end

--- Draw hints at `(x, y)`; `opts.w` centres them in that width; `opts.align
--- = "right"` right-aligns. Returns the width drawn.
function UI.hint(x, y, items, opts)
  opts = opts or {}
  local total = UI.hintWidth(items)
  local font = UI.font("label")
  local hx = x
  if opts.w and opts.align == "right" then hx = x + opts.w - total
  elseif opts.w then hx = x + math.floor((opts.w - total) / 2) end
  for i, it in ipairs(items) do
    if i > 1 then hx = hx + Theme.space.xl end
    hx = hx + UI.keycap(hx, y, it.key, { alpha = opts.alpha })
    if it.verb ~= "" then
      hx = hx + Theme.space.sm
      UI.buttonLabel(it.verb, hx, y + math.floor((Theme.control.keycap - 3 - font:getHeight()) / 2), font,
        opts.color or Theme.withAlpha(Theme.text, 0.88), false, { alpha = opts.alpha })
      hx = hx + font:getWidth(it.verb)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
  return total
end

-- ------------------------------------------------------- small furniture

--- Difficulty, 1..5, as pips (never stars: stars are earned).
function UI.pips(x, y, level, size, total)
  total = total or 5
  size = size or 6
  local gap = 2
  for i = 1, total do
    local filled = i <= (level or 0)
    UI.setColor(filled and Theme.brick or Theme.withAlpha(Theme.mute, 0.45))
    love.graphics.rectangle("fill", x + (i - 1) * (size + gap), y, size, size * 2)
  end
  love.graphics.setColor(1, 1, 1, 1)
  return total * (size + gap) - gap
end

function UI.pipsWidth(size, total)
  return (total or 5) * ((size or 6) + 2) - 2
end

--- 0..3 earned stars.
function UI.stars(x, y, count, size, total)
  total = total or 3
  size = size or 10
  for i = 1, total do
    local filled = i <= (count or 0)
    UI.setColor(filled and Theme.gold or Theme.withAlpha(Theme.mute, 0.5))
    local cx, cy = x + (i - 1) * (size + 3) + size / 2, y + size / 2
    love.graphics.polygon("fill",
      cx, cy - size / 2, cx + size / 4, cy, cx, cy + size / 2, cx - size / 4, cy)
    love.graphics.polygon("fill",
      cx - size / 2, cy, cx, cy - size / 4, cx + size / 2, cy, cx, cy + size / 4)
  end
  love.graphics.setColor(1, 1, 1, 1)
  return total * (size + 3)
end

--- A progress bar: a rounded `edge` track with `color` (default gold) in it.
function UI.bar(x, y, w, h, fraction, color)
  local r = math.min(Theme.radiusSm, h / 2)
  UI.setColor(Theme.edge, 0.9)
  UI.rrect("fill", x, y, w, h, r)
  local fw = math.floor((w - 2) * math.min(1, math.max(0, fraction or 0)))
  if fw > 0 then
    UI.setColor(color or Theme.gold)
    UI.rrect("fill", x + 1, y + 1, fw, h - 2, math.max(0, r - 1))
  end
  love.graphics.setColor(1, 1, 1, 1)
end

--- A scrollbar: a 6 px track inside the card padding, a `cardHi` thumb
--- (radius 3, at least 32 tall). `visible` and `offset` are fractions of
--- the content. `opts.alpha` fades it (hold it at 1 while scrolling and let
--- it go after 800 ms). Nothing is drawn when everything is visible.
function UI.scrollbar(x, y, h, visible, offset, opts)
  opts = opts or {}
  if not visible or visible >= 1 then return end
  local alpha = opts.alpha or 1
  local th = math.max(32, math.floor(h * visible))
  local ty = y + math.floor((h - th) * math.min(1, math.max(0, offset or 0)))
  UI.setColor(Theme.edge, 0.35 * alpha)
  UI.rrect("fill", x, y, 6, h, 3)
  UI.setColor(Theme.cardHi, alpha)
  UI.rrect("fill", x, ty, 6, th, 3)
  love.graphics.setColor(1, 1, 1, 1)
end

--- A 24 px fade from `color` (default card) to nothing at a clipped edge,
--- so "more below" is visible. `edge` is `"top"` or `"bottom"`.
function UI.scrollFade(x, y, w, color, edge, h)
  h = h or Theme.space.xl
  color = color or Theme.card
  local steps = 8
  for i = 0, steps - 1 do
    local k = i / steps
    local a = (edge == "top") and (1 - k) or k
    UI.setColor(color, a * a)
    love.graphics.rectangle("fill", x, y + i * (h / steps), w, h / steps + 1)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

--- A gear, drawn: a ring with six teeth. The one symbol the faces lack.
function UI.gear(cx, cy, r, color, alpha)
  UI.setColor(color or Theme.text, alpha)
  love.graphics.setLineWidth(2)
  love.graphics.circle("line", cx, cy, r * 0.55, 12)
  for i = 0, 5 do
    local a = i / 6 * math.pi * 2
    love.graphics.line(cx + math.cos(a) * r * 0.62, cy + math.sin(a) * r * 0.62,
      cx + math.cos(a) * r, cy + math.sin(a) * r)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- --------------------------------------------------------------- bounded

--- A centred content rect of max width `w` (default `Layout.MAX_CONTENT_W`).
--- Returns `x, y, w, h`, from under the header band to above the footer.
function UI.bounded(w, top, bottom)
  return Layout.bounded(w, top or UI.headerHeight(), bottom or (Layout.vh - UI.footerHeight()))
end

--- The header band: 56 in landscape, 72 upright.
function UI.headerHeight()
  return Layout.isPortrait() and Theme.control.headerP or Theme.control.header
end

-- ------------------------------------------------------------------ modal

local modal_open = {}

--- A modal. Returns the content rect `x, y, w, h` and the close button's
--- rect. Landscape: a centred card, max 640 wide; upright: a bottom sheet
--- 688 wide slid up from the footer. The scrim is felt at 70%; a click on
--- it, or ESC, is the caller's dismiss. `opts.id` keys the arrival
--- (`Juice.enter`, 220 ms outBack); `opts.title`; `opts.h` (content height
--- wanted, clamped); `opts.w`.
function UI.modal(opts)
  opts = opts or {}
  local vw, vh = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  local id = "modal:" .. tostring(opts.id or "sheet")
  local k = Juice.enter(id, { dur = Theme.motion.modal, ease = "outBack" })
  modal_open[id] = true

  UI.setColor(Theme.felt, 0.7 * math.min(1, k * 1.5))
  love.graphics.rectangle("fill", 0, 0, vw, vh)

  local pad = portrait and Theme.space.lg or Theme.space.xl
  local title_h = opts.title and (UI.lead("title") + Theme.space.md) or 0
  local w = math.min(opts.w or 640, vw - pad * 2)
  local h = math.min((opts.h or 320) + pad * 2 + title_h, vh - UI.footerHeight() - pad * 2)
  local x, y
  if portrait then
    w = vw - Theme.space.lg * 2
    x = Theme.space.lg
    y = vh - UI.footerHeight() - h + math.floor((1 - k) * 48)
  else
    x = math.floor((vw - w) / 2)
    y = math.floor((vh - h) / 2) + math.floor((1 - k) * 24)
  end
  local s = 0.94 + 0.06 * math.min(1, k)
  love.graphics.push()
  love.graphics.translate(x + w / 2, y + h / 2)
  love.graphics.scale(s, s)
  love.graphics.translate(-(x + w / 2), -(y + h / 2))
  UI.card(x, y, w, h, { strip = opts.strip or Theme.gold, pad = pad })
  local close = { x = x + w - pad - 32, y = y + pad - 4, w = 32, h = 32 }
  if opts.title then
    UI.label(opts.title, x + pad, y + pad, "title", { width = w - pad * 2 - 40, ellipsis = true })
    UI.button(close.x, close.y, close.w, close.h, "×", "normal", nil, { variant = "ghost", id = id .. ":close", lift = 0, sway = false, padx = 4 })
  end
  love.graphics.pop()
  return x + pad, y + pad + title_h, w - pad * 2, h - pad * 2 - title_h, close, { x = x, y = y, w = w, h = h }
end

--- Forget a modal's arrival so it slides in again next time.
function UI.modalReset(id)
  Juice.forget("modal:" .. tostring(id or "sheet"))
end

-- ------------------------------------------------------------------ toasts

local toasts = {}
UI.TOAST_MAX = 2

--- Say something, briefly, at the top centre. `opts.kind` is `"info"`
--- (blue strip), `"good"`, `"bad"` or `"warn"`; `opts.seconds` the hold
--- (default 2.4); `opts.role` `"label"` or `"title"`. A third toast
--- replaces the oldest. Returns the toast.
function UI.pushToast(text, opts)
  opts = opts or {}
  if not text or text == "" then return nil end
  local t = { text = tostring(text), kind = opts.kind or "info", role = opts.role or "label",
    hold = opts.seconds or Theme.motion.toastHold, age = 0, arrived = false, id = opts.id }
  -- A toast with an id replaces the one before it with the same id: four
  -- presses of F12 are one "code size n/4" slip with the latest number on
  -- it, not four slips stacked up the screen.
  if t.id then
    for i = #toasts, 1, -1 do
      if toasts[i].id == t.id then table.remove(toasts, i) end
    end
  end
  toasts[#toasts + 1] = t
  while #toasts > UI.TOAST_MAX do table.remove(toasts, 1) end
  return t
end

function UI.clearToasts()
  toasts = {}
end

function UI.toasts()
  return toasts
end

function UI.updateToasts(dt)
  local keep = {}
  for _, t in ipairs(toasts) do
    if Anim.frozen() then
      t.age = math.max(t.age, Theme.motion.toastIn)
    else
      t.age = t.age + dt
    end
    if t.age < Theme.motion.toastIn + t.hold + Theme.motion.toastOut then keep[#keep + 1] = t end
  end
  toasts = keep
end

local STRIP = { info = Theme.blue, good = Theme.green, bad = Theme.redA, warn = Theme.gold }

--- Draw the dock, 12 px under `top` (the header's bottom), stacked 8 apart.
function UI.drawToasts(top)
  if #toasts == 0 then return end
  local vw = Layout.vw
  local maxw = Layout.isPortrait() and math.min(640, vw - 32) or math.min(560, vw - 48)
  local y = (top or 0) + Theme.space.md
  for _, t in ipairs(toasts) do
    local font = UI.font(t.role)
    local pad = Theme.space.md
    local lines = UI.wrapWith(t.text, maxw - pad * 2, font)
    local lead = UI.lead(t.role)
    local w = 0
    for _, line in ipairs(lines) do w = math.max(w, font:getWidth(line)) end
    w = math.min(maxw, w + pad * 2)
    local h = #lines * lead + pad * 2 - 4 + Theme.stripH
    local x = math.floor((vw - w) / 2)
    -- In: slides down from above with a little overshoot; out: up and gone.
    local tin, hold, tout = Theme.motion.toastIn, t.hold, Theme.motion.toastOut
    local off, alpha = 0, 1
    if t.age < tin then
      local k = Juice.ease.outBack(t.age / tin)
      off = -(h + y) * (1 - k)
      alpha = math.min(1, t.age / tin * 2)
    elseif t.age > tin + hold then
      local k = Juice.ease.inCubic((t.age - tin - hold) / tout)
      off = -(h + y) * k
      alpha = 1 - k
    end
    if not t.arrived and t.age >= tin * 0.6 then
      t.arrived = true
      Fx.burst(x + w / 2, y + h / 2, "stars", { n = 0.5 })
    end
    local ty = y + off
    UI.card(x, ty, w, h, { strip = STRIP[t.kind] or Theme.blue, alpha = alpha, pad = 0 })
    for i, line in ipairs(lines) do
      UI.label(line, x, ty + Theme.stripH + pad - 2 + (i - 1) * lead, t.role,
        { width = w, align = "center", alpha = alpha, shadow = false })
    end
    y = y + h + Theme.space.sm
  end
end

--- Legacy: one notice, drawn where it is asked. Kept for a caller that
--- still holds its own text; new code uses `UI.pushToast`.
function UI.toast(text, alpha, lift)
  if not text or alpha <= 0 then return end
  local font = UI.font("label")
  local pad = Theme.space.md
  local w = math.min(Layout.vw - 40, font:getWidth(text) + pad * 2)
  local lines = UI.wrapWith(text, w - pad * 2, font)
  local h = #lines * UI.lead("label") + pad * 2
  local x = math.floor((Layout.vw - w) / 2)
  local y = math.max(4, Layout.vh - UI.footerHeight() - h - 20 - math.max(0, lift or 0))
  UI.card(x, y, w, h, { strip = Theme.blue, alpha = alpha, pad = 0 })
  for i, line in ipairs(lines) do
    UI.label(line, x, y + pad + (i - 1) * UI.lead("label"), "label", { width = w, align = "center", alpha = alpha })
  end
end

-- ------------------------------------------------------------------ footer
--
-- One line, always: `LV n` and the XP bar on the left, the scene's key
-- hints as keycaps in the middle, the connection dot and the ⚙ on the
-- right. Name, address and the display controls live in the settings sheet
-- (`UI.displayControls`), which the ⚙ opens.

--- The authored size of a legacy footer hint, read by drive scripts.
UI.FOOTER_SIZE = 8

--- The size the display buttons are set in — the button face, not the
--- caption face; `tests/test_screens.lua` holds it to SUBMIT's size.
UI.CHIP_SIZE = 9

--- The floor under a display button's height: a finger-sized target.
UI.CHIP_MIN_H = 44

--- Always one now: the footer never wraps. Kept for the drive scripts and
--- the strip's height formula.
UI.hint_rows = 1

--- True when the scene's hints did not all fit and some were dropped.
UI.hint_clipped = false

--- The height of the footer's line: 48, or 64 upright.
function UI.footerRow()
  return Layout.isPortrait() and Theme.control.footerP or Theme.control.footer
end

--- How tall one display button is, in the settings sheet.
function UI.chipHeight()
  return math.max(UI.CHIP_MIN_H, UI.lead("label") + 14)
end

--- The display controls' own row under the hint — **zero now**: the five
--- buttons moved into the settings sheet, and the footer is one line.
function UI.controlRow()
  return 0
end

--- The whole strip: the hint's rows, plus the controls' row.
function UI.footerHeight()
  return UI.footerRow() * UI.hint_rows + UI.controlRow()
end

--- Space kept clear on the right for the dot and the ⚙, whatever the
--- connection says, so the hints never jump.
local function badge_reserve()
  return 72
end

UI.badgeReserve = badge_reserve

--- The five controls, with their labels already decided. Each says the
--- state it is in, not the one it moves to; `every` is every label it can
--- wear, which is what its width is measured from (`btnBox`).
local function chips(state)
  local steps = {}
  for i = 1, #Layout.FONT_STEPS do steps[i] = ("%d/%d"):format(i, #Layout.FONT_STEPS) end
  local codes = {}
  for _, code in ipairs(I18n.LANGS) do codes[#codes + 1] = I18n.CODES[code] or "EN" end
  local list = {
    { id = "fullscreen", caption = "WINDOW", label = state.fullscreen and "FULL" or "WINDOW",
      every = { "FULL", "WINDOW" } },
    { id = "orient", caption = "ORIENTATION",
      label = (state.orientation == "auto") and "AUTO"
        or (state.orientation == "portrait" and "PORT" or "LAND"),
      every = { "AUTO", "PORT", "LAND" } },
    { id = "font", caption = "TYPE SIZE", label = "A " .. (state.font_label or "1/4"), every = steps },
    { id = "lang", caption = "LANGUAGE", label = state.lang_code or "EN", every = codes },
    { id = "face", caption = "INTERFACE FACE", label = state.ui_face or "ARCADE", every = { state.ui_face or "ARCADE" } },
    { id = "codeface", caption = "CODE FACE", label = state.code_face or "IOSEVKA", every = { state.code_face or "IOSEVKA" } },
    { id = "sound", caption = "SOUND", label = state.sound and "ON" or "OFF", every = { "ON", "OFF" } },
  }
  if state.authed then
    list[#list + 1] = { id = "copy", caption = "ACCOUNT", label = "COPY", every = { "COPY" },
      note = (state.name or "") .. "  " .. (state.address or "") }
    list[#list + 1] = { id = "logout", caption = "", label = "LOG OUT", every = { "LOG OUT" }, danger = true }
  end
  return list
end

--- Measured from every label a control can wear: the width of its button.
local function chip_width(chip)
  local w = 0
  for _, label in ipairs(chip.every) do
    w = math.max(w, (UI.buttonSize(label)))
  end
  w = math.max(w, (UI.buttonSize(chip.label)))
  return math.max(88, w)
end

--- Kept for `src/app.lua`: the controls cost the footer nothing now.
function UI.displayReserve(state)
  return 0
end

--- The settings sheet: a modal with one row per control. Draws it and
--- returns the rects it drew, keyed by id, plus `close` and `sheet`.
---
--- **The same controls, reachable from every screen** — drawn from
--- `App:draw`, which every scene is under, so a new scene gets them without
--- knowing they exist. The keys (F1, F11, F12, L, F8, F4) still work.
function UI.displayControls(state)
  local list = chips(state)
  local _, need_h = UI.buttonSize("A")
  local row_h = math.max(Theme.control.buttonM, need_h)
  local gap = Theme.rowGap
  local rows = #list
  local content_h = rows * row_h + (rows - 1) * gap
  local x, y, w, h, close, sheet = UI.modal({ id = "settings", title = I18n.t("SETTINGS"), h = content_h, w = 560 })
  local px, py = pointer()
  local rects = { close = close, sheet = sheet }
  love.graphics.setScissor(x, y, w, h)
  local ry = y
  for _, chip in ipairs(list) do
    local bw = chip_width(chip)
    local bx = x + w - bw
    if chip.caption ~= "" then
      UI.label(I18n.t(chip.caption), x, ry + math.floor((row_h - UI.lead("label")) / 2), "label", { color = Theme.text })
    end
    if chip.note then
      local font = UI.font("label")
      UI.label(UI.ellipsizeWith(chip.note, bx - x - Theme.space.md - font:getWidth(I18n.t(chip.caption)) - Theme.space.lg, font),
        x + font:getWidth(I18n.t(chip.caption)) + Theme.space.lg, ry + math.floor((row_h - UI.lead("label")) / 2), "label")
    end
    local r = { x = bx, y = ry, w = bw, h = row_h }
    local hot = inside(r, px, py)
    UI.button(bx, ry, bw, row_h, chip.label, hot and "hot" or "normal", nil,
      { variant = chip.danger and "danger" or "secondary", id = "settings:" .. chip.id, align = chip.danger and nil })
    rects[chip.id] = r
    ry = ry + row_h + gap
  end
  love.graphics.setScissor()
  -- The glyph half: the orientation glyph says which shape AUTO landed on.
  rects.shape = state.shape
  return rects
end

--- The one-line footer. Returns the room the hints were given.
---
---   `UI.footer(hint, connection, status, opts)`
---
--- `hint` is the scene's key list — a string (`"SPACE start   F10 story"`,
--- split at double spaces, first word the key) or a list of `{ key =,
--- verb = }` in priority order; the longest prefix that fits is shown, at
--- most 4 (3 upright). `connection` is the client state; the dot is green
--- when open and red with OFFLINE otherwise. `status` is `{ level =, xp =,
--- frac = }` or nil when nobody is signed in. `opts.bare` draws no bar and
--- no status (the title card). The ⚙'s rect is left in `UI.gear_rect`.
function UI.footer(hint, connection, status, opts)
  opts = opts or {}
  local vw, vh = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  local h = UI.footerRow()
  local y = vh - h
  local g = portrait and Theme.space.lg or Theme.space.xl
  local items = type(hint) == "table" and hint or UI.parseHint(hint)
  local font = UI.font("label")

  if not opts.bare then
    UI.setColor(Theme.bar)
    love.graphics.rectangle("fill", 0, y, vw, h)
    UI.setColor(Theme.edge, 0.6)
    love.graphics.rectangle("fill", 0, y, vw, 2)
  end

  -- The right block: the dot, OFFLINE when it is not open, and the ⚙.
  local gear = Theme.control.gear
  local gx = vw - g - gear
  local gy = y + math.floor((h - gear) / 2)
  local px, py = pointer()
  local gear_rect = { x = gx, y = gy, w = gear, h = gear }
  UI.gear_rect = gear_rect
  local hot = inside(gear_rect, px, py) or opts.gear_hot
  UI.button(gx, gy, gear, gear, "", hot and "hot" or "normal", nil,
    { variant = "secondary", id = "footer:gear", padx = 0 })
  UI.gear(gx + gear / 2, gy + gear / 2 + (hot and -2 or 0), 11, Theme.text)
  local dot_x = gx - Theme.space.md - 6
  local open = connection == "open"
  local dot = open and Theme.green or (connection == "closed" or connection == "idle") and Theme.redA or Theme.gold
  if connection then
    UI.setColor(Theme.edge)
    love.graphics.circle("fill", dot_x, y + h / 2 + 1, 7, 12)
    UI.setColor(dot)
    love.graphics.circle("fill", dot_x, y + h / 2, 6, 12)
    love.graphics.setColor(1, 1, 1, 1)
  end
  local right = dot_x - 10
  if connection and not open and not opts.bare then
    local word = connection == "closed" and I18n.t("OFFLINE") or I18n.t("CONNECTING")
    local ww = font:getWidth(word)
    UI.label(word, right - ww, y + math.floor((h - UI.lead("label")) / 2), "label",
      { color = open and Theme.green or (connection == "closed" and Theme.redA or Theme.gold) })
    right = right - ww - Theme.space.md
  end

  -- The left block: LV n, the bar, the count.
  local left = g
  if status and not opts.bare then
    local lv = I18n.t("LV %d", status.level or 1)
    local lw = UI.font("title"):getWidth(lv)
    UI.label(lv, left, y + math.floor((h - UI.lead("title")) / 2), "title", { color = Theme.gold })
    left = left + lw + Theme.space.md
    UI.bar(left, y + math.floor(h / 2) - 4, 96, 8, status.frac or 0, Theme.gold)
    left = left + 96 + Theme.space.md
    if not portrait and status.xp then
      local count = I18n.t("%d XP", status.xp)
      UI.label(count, left, y + math.floor((h - UI.lead("label")) / 2), "label", { color = Theme.mute })
      left = left + font:getWidth(count) + Theme.space.md
    end
  end

  -- The hints, centred in what is left, the longest prefix that fits.
  local room = math.max(0, right - left - Theme.space.xl * 2)
  local kept = opts.bare and {} or UI.fitHints(items, room, portrait and 3 or 4)
  UI.hint_clipped = #kept < #items
  UI.hint_rows = 1
  if #kept > 0 then
    UI.hint(left + Theme.space.xl, y + math.floor((h - Theme.control.keycap) / 2), kept, { w = room })
  end
  UI.last_hints = kept
  return room
end

return UI
