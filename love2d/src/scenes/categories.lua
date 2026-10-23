-- CATEGORY SELECT. The roads of one land (seven, or REMIX's four), from
-- `world.lands`, drawn as a column of cards led by CODE PLAYGROUND
-- (`docs/love2d-ui.md`).
--
-- `open` is the server's word (§4.6: "false when the category's first node is
-- still locked"), so a locked row is drawn locked and refuses to open. The
-- client does not work out for itself whether the player has earned it.
--
-- ## The layout
--
--   * **CODE PLAYGROUND leads the column**, as it does in the browser client
--     (`frontend/src/scenes/lands.ts`): the same card as a road, the same
--     height and width, first in the list and the first thing the arrows
--     land on — a gold stripe instead of the land's, the desk and the coder
--     where a road keeps its emblem, and the P keycap where a road keeps its
--     count. It is the main feature, and a player one step into a land
--     should not have to go back out to find it. `P` still opens it from
--     anywhere on the screen.
--   * **A road is a card** with the land's stripe down its left edge, the
--     name in title-32, the blurb in the reading face, the count as a chip
--     on the right and a progress bar along the bottom. The road's emblem
--     stands at the right edge beside the chip, at its own aspect, and only
--     where it leaves the words alone. The two CHEATSHEET roads have no
--     emblem, in either client, and are left clean rather than given one.
--   * **The blurb takes the width it has.** In a tall window it sits under
--     the name across the whole card, as many lines as the row holds; in a
--     short one it runs after the name on one line and ends in "…"; and at
--     the larger reading sizes, where a paragraph is bigger than the title
--     beside it, the short rows leave it out.
--
-- `Categories.metrics` is the one arrangement the draw and the click both
-- read, and `tests/test_screens.lua` asks it what the answer *is* at every
-- type step and shape without drawing anything. The chrome never moves with
-- F12 — only the blurb does — so what gives way when eight cards do not fit
-- is the blurb, then the bar, and in landscape the column splits in two
-- before a card is ever cut below its name.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Anim = require("src.anim")
local Juice = require("src.juice")
local Fx = require("src.fx")
local Land = require("src.land")

local Categories = {}
Categories.__index = Categories

local BLURB = {
  cheatsheet = "the cheatsheet, basic. four lines, one right; pick it and the node is cleared.",
  cheatsheet_advanced = "the cheatsheet, advanced. traits, channels, generics, closures; four lines, one right.",
  verybasic = "the quiz. four lines, one right; pick it, then type it.",
  basic = "grammar. one construct, one to four lines, untimed.",
  advanced = "the live coding test, untimed. whole programs, hidden cases.",
  hacker = "timed. the whiteboard is watching.",
  frameworks = "the job. anyhow, serde, tokio, clap: the crates every file starts with.",
}

-- SPEC §0's order. `world.lands` does not promise one, and which row is drawn
-- first is presentation rather than a rule — but a category list that
-- reorders itself between two calls is a category list a player mis-clicks.
local ORDER = {
  cheatsheet = 0, cheatsheet_advanced = 1, verybasic = 2, basic = 3, advanced = 4, hacker = 5, frameworks = 6,
}

local function ordered(categories)
  local out = {}
  for i, cat in ipairs(categories or {}) do out[i] = cat end
  table.sort(out, function(a, b)
    local ra = ORDER[a.category] or 99
    local rb = ORDER[b.category] or 99
    if ra ~= rb then return ra < rb end
    return tostring(a.category) < tostring(b.category)
  end)
  return out
end

function Categories.new(app)
  return setmetatable({
    app = app,
    -- 0 is CODE PLAYGROUND; 1..n are the roads, in `ORDER`. The drive
    -- scripts set `cursor = i` from `ipairs(categories)` and press ENTER, so
    -- the roads keep their indices and the playground sits before 1.
    cursor = 1,
    categories = nil, error = nil,
    picked_at = 0, hover = nil,
    header_h = UI.headerHeight(),
  }, Categories)
end

function Categories:enter(params)
  self.land = params.land or self.app.land or "rust"
  self.categories = params.categories and ordered(params.categories) or nil
  if not self.categories then self:refresh() end
  Juice.forget("cats:")
end

function Categories:refresh()
  self.error = nil
  self.app.session:request("world.lands", {}, function(ok, payload, why)
    if not ok then self.error = why.player; return end
    for _, land in ipairs(payload.lands) do
      if land.land == self.land then self.categories = ordered(land.categories) end
    end
  end)
end

--- The card's rect for slot `i` (0 is the playground).
function Categories:card_rect(i)
  local m = self.metrics or Categories.metrics(Layout.vw, Layout.vh, self.categories or {})
  local x, y = Categories.row_at(m, i)
  return { x = x, y = y, w = m.w, h = m.rh }
end

--- Mei's own desk (§4.9c), the same key as on the lands screen and the map.
function Categories:open_playground()
  UI.press("cats:row0", self:card_rect(0), { sfx = false })
  SFX.play("select")
  self.app:go("playground")
end

function Categories:choose()
  if self.cursor == 0 then
    self:open_playground()
    return
  end
  local cat = self.categories and self.categories[self.cursor]
  if not cat then return end
  if not cat.open then
    SFX.play("locked")
    self.app:toast(I18n.t("clear the category before it first"))
    return
  end
  UI.press("cats:row" .. self.cursor, self:card_rect(self.cursor), { sfx = false })
  SFX.play("select")
  self.app.category = cat.category
  self.app:go("map", { land = self.land, category = cat.category })
end

-- ------------------------------------------------------------------ layout

--- The legacy authored sizes `tests/test_screens.lua` measures the rows
--- against. The names are set in the title role and the counts in the
--- label role, which never move with F12; these are the largest authored
--- sizes that are no taller than those roles at the current step, so a row
--- measured either way holds its type.
local function authored_within(from, floor, role)
  local limit = UI.font(role):getHeight()
  for size = from, floor, -1 do
    if UI.fontFor(size):getHeight() <= limit then return size end
  end
  return floor
end

local COL_GAP = Theme.gap
local ROW_GAP = Theme.rowGap
--- The least room a blurb is drawn into beside the name: fewer pixels than
--- this is three words and an ellipsis, which says less than nothing.
local BLURB_MIN_W = 240

--- One arrangement for a given column count; `fits` says whether every
--- card ends above the footer.
local function measure(vw, vh, rows, cols)
  local g = Layout.gutter()
  local header = UI.headerHeight()
  local cw = math.min(Theme.maxContentW, vw - g * 2)
  local cx = math.floor((vw - cw) / 2)
  local y0 = header + Theme.space.lg
  local bottom = Categories.band_top(vh) - 10

  local title_h = UI.lead("title")
  local title_y = math.floor((header - title_h) / 2)

  local w = math.floor((cw - COL_GAP * (cols - 1)) / cols)
  -- The playground and the roads, as slots of one column.
  local slots = #rows + 1
  local n = math.max(1, math.ceil(slots / cols))
  local avail = math.floor((bottom - y0 + ROW_GAP) / n) - ROW_GAP

  -- The type in the row, at the roles.
  local name_size = authored_within(13, 5, "title")
  local count_size = authored_within(10, 5, "label")
  local widest = UI.labelWidth(I18n.t("CODE PLAYGROUND"), "title")
  for _, cat in ipairs(rows) do
    widest = math.max(widest, UI.labelWidth(I18n.t(Land.category_label(cat.category)), "title"))
  end
  -- The count chip: wide enough for `NN / NN` whichever way it is measured.
  local count_w = math.max(UI.chipWidth("00 / 00"), UI.textWidth("00 / 00", 10),
    UI.textWidth("00 / 00", count_size))
  local count_h = Theme.control.chip

  local pad = Theme.space.lg
  local text_x = Theme.landStripeH + pad
  local label_w = w - text_x - pad - count_w - Theme.space.md
  -- A name wider than the room beside the chip takes the row, and the chip
  -- moves down onto the bar's line.
  local chip_below = widest > label_w
  if chip_below then label_w = w - text_x - pad end

  local _, read_lead = UI.readHeight("x", 100)
  -- What a card needs: the name alone (the floor), the name with its bar,
  -- and the name over a line of blurb with the bar.
  local glyph_h = UI.font("title"):getHeight()
  if I18n.is_cjk() then glyph_h = glyph_h + math.floor(glyph_h / 8) end
  local floor_h = math.max(52, Theme.space.md + glyph_h + 14)
  local bar_h = Theme.space.sm + title_h + Theme.space.sm + 8 + Theme.space.sm
  local stacked_h = Theme.space.sm + title_h + Theme.space.xs + read_lead + Theme.space.sm + 8 + Theme.space.sm
  if chip_below then
    bar_h = math.max(bar_h, Theme.space.sm + title_h + Theme.space.sm + count_h + Theme.space.sm)
    stacked_h = stacked_h + count_h - 8
  end

  -- **Content-sized.** A card is as tall as what it holds, up to the room
  -- the column has: the name over one or two lines of blurb and the bar;
  -- the name beside one line of blurb with the bar; the name alone.
  local rh, blurb_lines, inline, label_blurb = floor_h, 0, false, false
  local lines = math.min(2, math.floor((avail - (stacked_h - read_lead)) / read_lead))
  if lines >= 1 then
    rh = stacked_h + (lines - 1) * read_lead
    blurb_lines = lines
  elseif avail >= bar_h then
    -- No line of the reading face fits. The row still holds its name and a
    -- line of blurb at the legacy sizes (`tests/test_screens.lua` holds it
    -- to that), and the blurb goes under the name in the label role when
    -- that room is there — a paragraph face too big for the row is not a
    -- reason to say nothing.
    local legacy = Theme.space.md + UI.lineHeight(13) + Theme.space.xs + UI.lineHeight(7) + 14
    rh = math.min(avail, math.max(bar_h, legacy))
    inline = read_lead <= title_h and not chip_below
    label_blurb = not inline and (rh - bar_h) >= UI.lead("label") + Theme.space.xs
  else
    rh = math.max(floor_h, avail)
  end
  local with_bar = rh >= bar_h

  return {
    title_y = title_y, title_h = title_h, header = header,
    x0 = cx, y0 = y0, pad = cx, cw = cw, w = w, rh = rh,
    gutter = text_x, label_w = label_w, widest = widest,
    count_w = count_w, count_h = count_h, chip_below = chip_below,
    blurb_lines = blurb_lines, inline = inline, label_blurb = label_blurb, with_bar = with_bar,
    read_lead = read_lead, bar_h = bar_h,
    name_size = name_size, count_size = count_size,
    cols = cols, per_col = n, slots = slots, bottom = bottom,
    fits = y0 + n * (rh + ROW_GAP) - ROW_GAP <= bottom and widest <= label_w,
  }
end

--- Every measurement the screen is drawn from, for `rows` on a `vw × vh`
--- canvas. One column while its cards keep their bar; in landscape two
--- columns before the cards shrink to their names; then whatever fits.
function Categories.metrics(vw, vh, rows)
  rows = rows or {}
  local one = measure(vw, vh, rows, 1)
  if one.fits and one.with_bar then return one end
  if not Layout.isPortrait() then
    local two = measure(vw, vh, rows, 2)
    if two.fits and two.with_bar then return two end
  end
  if one.fits or Layout.isPortrait() then return one end
  for cols = 2, 3 do
    local c = measure(vw, vh, rows, cols)
    if c.fits then return c end
  end
  return one
end

--- Where slot `i` stands — 0 is CODE PLAYGROUND, 1.. the roads: its left
--- edge and its top. One column, or two filled top to bottom — read by the
--- draw and by the click alike.
function Categories.row_at(m, i)
  local col = math.floor(i / m.per_col)
  local r = i % m.per_col
  return m.x0 + col * (m.w + COL_GAP), m.y0 + r * (m.rh + ROW_GAP)
end

--- The strip under the rows is gone — CODE PLAYGROUND leads the column now
--- — and these two are kept for the callers that measure against them: the
--- cards end a gap above the footer.
function Categories.band_height()
  return 0
end

function Categories.band_top(vh)
  return vh - UI.footerHeight() - 14
end

-- ----------------------------------------------------------------- drawing

--- A mascot standing on `(x, bottom)` inside a `box` square.
local function mascot(name, x, bottom, box, opts)
  if not name then return false end
  local b = Assets.box[name]
  local image = Assets.image(name)
  if not image then return false end
  local iw, ih = image:getDimensions()
  local ink_w = (b and b.w and b.w > 0) and b.w or iw
  local ink_h = (b and b.h and b.h > 0) and b.h or ih
  local height = box
  if ink_w > ink_h then height = box * ink_h / ink_w end
  return Assets.sprite(name, x, bottom, height, opts)
end

--- A band of art at its own aspect, as tall as `h`, anchored to `right`,
--- with a short fade on its left edge into `fill`. Returns its left edge.
local function band(name, right, y, h, fill, alpha)
  local image = Assets.image(name)
  if not image then return right end
  local iw, ih = image:getDimensions()
  local s = h / ih
  local ew = iw * s
  local ex = right - ew
  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.draw(image, ex, y, 0, s, s)
  local steps = 14
  local fw = math.min(52, ew * 0.35)
  for k = 0, steps - 1 do
    UI.setColor(fill, alpha * (0.95 - k * (0.95 / steps)))
    love.graphics.rectangle("fill", ex + k * (fw / steps), y, fw / steps + 1, h)
  end
  love.graphics.setColor(1, 1, 1, 1)
  return ex
end

--- The header band: ‹ BACK, the land's mascot and name, the land's total.
function Categories:draw_header()
  local vw = Layout.vw
  local h = self.header_h or UI.headerHeight()
  local g = Layout.gutter()
  UI.card(0, 0, vw, h, { variant = "bar", pad = 0 })
  UI.setColor(Theme.edge, 0.6)
  love.graphics.rectangle("fill", 0, h - 2, vw, 2)
  love.graphics.setColor(1, 1, 1, 1)

  local back = "‹ " .. I18n.t("BACK")
  local bw, bh = UI.buttonSize(back)
  bh = math.max(Theme.control.buttonM, bh)
  self.back_rect = { x = g, y = math.floor((h - bh) / 2), w = bw, h = bh }
  UI.button(self.back_rect.x, self.back_rect.y, bw, bh, back,
    self.hover == "back" and "hot" or "normal", nil, { variant = "ghost", id = "cats:back" })

  local x = g + bw + Theme.space.lg
  local box = 40
  local bob = Anim.bob(Anim.now(), { amount = 2, phase = Land.phase(self.land) })
  mascot(Land.mascot(self.land), x + box / 2, math.floor((h + box) / 2) + bob, box)
  x = x + box + Theme.space.md

  local cleared, total = 0, 0
  for _, cat in ipairs(self.categories or {}) do
    cleared, total = cleared + (cat.cleared or 0), total + (cat.total or 0)
  end
  local count = self.categories and ("%d / %d"):format(cleared, total) or ""
  local count_w = UI.labelWidth(count, "label")
  UI.label(count, vw - g - count_w, math.floor((h - UI.lead("label")) / 2), "label", { color = Theme.mute })
  UI.label(I18n.t("%s LAND", Land.name(self.land)), x, math.floor((h - UI.lead("title")) / 2), "title",
    { width = vw - g - count_w - Theme.space.lg - x, ellipsis = true })
end

--- One card of the column, into slot `i`. `c` is what it shows:
---
---   `tint` (the stripe), `name`, `name_color`, `blurb`, `art` (a band name
---   and `art_sprite` for a standing figure beside it), `count` (a chip
---   label) or `key` (a keycap where the chip would be), `done`, `open`.
function Categories:draw_card(m, i, c)
  local t = Anim.now()
  local selected = i == self.cursor
  local k = Juice.enter("cats:row" .. i, { dur = Theme.motion.enter, delay = Juice.stagger(i + 1, Theme.motion.stagger) })
  local hot = (selected or self.hover == i) and 1 or 0
  local a = Juice.follow("cats:hot" .. i, hot, { speed = 18 })
  local press = Juice.pressed("press:cats:row" .. i)
  local x, ry0 = Categories.row_at(m, i)
  local w, rh = m.w, m.rh
  local y = ry0 + (1 - k) * 24 - 4 * a + 4 * press
  local alpha = math.min(1, k * 1.5)
  local cx, cy = x + w / 2, y + rh / 2
  local scale = 1 + 0.015 * a
  local sway = (selected and a > 0.01) and math.sin(t * math.pi * 2 * Theme.motion.sway + i) * 0.6 * a * math.pi / 180 or 0
  love.graphics.push()
  love.graphics.translate(cx, cy)
  love.graphics.rotate(sway)
  love.graphics.scale(scale, scale)
  love.graphics.translate(-cx, -cy)

  UI.card(x, y, w, rh, { stripe = c.tint, hot = a, selected = selected, alpha = alpha,
    shadowDy = Theme.shadowDy - 5 * press, pad = 0 })
  local fill = Theme.mix(Theme.card, Theme.cardHi, a)
  local pad = Theme.space.lg
  local tx = x + m.gutter
  local right = x + w - pad
  local color = c.name_color or (c.open and Theme.text or Theme.mute)

  -- The chip (or the keycap), and the art beside it when there is room for
  -- both it and the words.
  local chip_x = right - m.count_w
  local chip_y = m.chip_below and (y + rh - Theme.space.sm - m.count_h)
    or (y + math.floor((rh - m.count_h) / 2))
  if m.with_bar and not m.chip_below then chip_y = y + Theme.space.sm + math.floor((UI.lead("title") - m.count_h) / 2) end
  if c.count then
    UI.chip(chip_x, chip_y, c.count, { w = m.count_w, alpha = alpha,
      color = c.done and Theme.green or (not c.open and Theme.bar or nil) })
  elseif c.key then
    local kw = UI.keycapWidth(c.key)
    UI.keycap(right - kw, chip_y + math.floor((m.count_h - Theme.control.keycap) / 2), c.key, { alpha = alpha })
  end

  local art_left = (c.count and chip_x or (right - UI.keycapWidth(c.key or "P"))) - Theme.space.md
  local art_h = rh - Theme.space.sm * 2
  -- The words come first: the art takes what is left after the widest
  -- name, and, when the blurb runs beside the name, after the blurb's
  -- minimum too.
  local need = tx + m.widest + Theme.space.xl
  if m.inline and (c.blurb or "") ~= "" then
    need = math.max(need, tx + UI.labelWidth(c.name, "title") + Theme.space.lg + BLURB_MIN_W)
  end
  if c.art and art_h >= 40 then
    -- At its own aspect, as tall as the card or as wide as the room beside
    -- the words, whichever is the tighter — a half-width column gets a
    -- smaller picture, not none.
    local image = Assets.image(c.art)
    local eh = image and art_h or nil
    if image then
      local iw, ih = image:getDimensions()
      eh = ih * math.min(art_h / ih, math.max(0, art_left - need) / iw)
    end
    if eh and eh >= 40 then
      local ey = y + rh - Theme.space.sm - eh
      art_left = band(c.art, art_left, ey, eh, fill, alpha * (c.open and 1 or 0.6))
      if c.art_sprite and eh >= 56 then
        -- The coder, hovering over the desk, engine on — when the card is
        -- tall enough for a figure to read as one.
        local size = math.floor(eh * 0.78)
        local bob = Anim.bob(t, { amount = 3, period = 2.4 })
        mascot(c.art_sprite, art_left + size * 0.45, ey + size + bob, size, { alpha = alpha })
      end
    elseif not image and c.art_sprite and art_left - art_h >= need then
      -- No band on disk: the figure alone, standing where it would have been.
      mascot(c.art_sprite, art_left - art_h / 2, y + rh - Theme.space.sm, art_h, { alpha = alpha })
      art_left = art_left - art_h
    end
  end

  -- The name, then the blurb: after it on one line, or under it.
  local label_w = m.chip_below and (art_left - Theme.space.md - tx) or math.min(m.label_w, art_left - Theme.space.md - tx)
  local ny = m.with_bar and (y + Theme.space.sm) or (y + math.floor((rh - UI.lead("title")) / 2))
  UI.label(c.name, tx, ny, "title", { width = label_w, ellipsis = true, color = color, alpha = alpha })
  local blurb = c.blurb or ""
  if m.inline and blurb ~= "" then
    local nw = math.min(label_w, UI.labelWidth(c.name, "title"))
    local bx = tx + nw + Theme.space.lg
    local bw = art_left - Theme.space.md - bx
    if bw >= BLURB_MIN_W then
      UI.read(blurb, bx, ny + math.floor((UI.lead("title") - m.read_lead) / 2), bw,
        { maxLines = 1, color = Theme.mute, alpha = alpha })
    end
  elseif m.blurb_lines > 0 and blurb ~= "" then
    local bw = art_left - Theme.space.md - tx
    UI.read(blurb, tx, ny + UI.lead("title") + Theme.space.xs, bw,
      { maxLines = m.blurb_lines, color = Theme.mute, alpha = alpha })
  elseif m.label_blurb and blurb ~= "" then
    UI.label(blurb, tx, ny + UI.lead("title") + Theme.space.xs, "label",
      { color = Theme.mute, width = art_left - Theme.space.md - tx, ellipsis = true, alpha = alpha })
  end

  if m.with_bar and c.count then
    local bar_right = m.chip_below and (chip_x - Theme.space.md) or (art_left - Theme.space.md)
    UI.bar(tx, y + rh - Theme.space.sm - 8, math.max(40, bar_right - tx), 8,
      c.fraction or 0, c.open and Theme.gold or Theme.mute)
  end

  if c.done then
    Assets.marker("badge_cleared", chip_x - Theme.space.lg - 14, chip_y + m.count_h / 2, 28, { alpha = alpha })
  elseif c.count and not c.open then
    -- Only a category that genuinely cannot be entered. Nothing on the map
    -- is locked (§4.7); this is for a pack that failed to import.
    Assets.marker("badge_locked", chip_x - Theme.space.lg - 14, chip_y + m.count_h / 2, 24, { alpha = 0.85 * alpha })
    UI.label(I18n.t("UNAVAILABLE"), tx, y + rh - Theme.space.sm - UI.lead("label"), "label",
      { color = Theme.mute, alpha = alpha })
  end
  love.graphics.pop()
end

--- What the card for slot `i` shows.
function Categories:card_spec(i)
  if i == 0 then
    return {
      tint = Theme.gold, name = I18n.t("CODE PLAYGROUND"), name_color = Theme.gold,
      blurb = I18n.t("write anything, run it — the Rust coder flies beside you"),
      art = "emblem_playground", art_sprite = "agent_coder", key = "P", open = true,
    }
  end
  local cat = self.categories[i]
  local done = (cat.total or 0) > 0 and (cat.cleared or 0) >= cat.total
  return {
    tint = Theme.land[self.land] or Theme.gold,
    name = I18n.t(Land.category_label(cat.category)),
    blurb = I18n.t(BLURB[cat.category] or ""),
    art = ("emblem_%s_%s"):format(self.land, cat.category),
    count = ("%d / %d"):format(cat.cleared or 0, cat.total or 0),
    fraction = (cat.total or 0) > 0 and (cat.cleared or 0) / cat.total or 0,
    done = done, open = cat.open,
  }
end

function Categories:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_times", "bg_flat"), 0, 0, vw, vh)
  UI.setColor(Theme.felt, Layout.isPortrait() and 0.8 or 0.72)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)
  Fx.ambient("dust", vw, vh)
  Fx.drawAmbient()

  local rows = self.categories or {}
  local m = Categories.metrics(vw, vh, rows)
  self.metrics = m

  -- The selected card last, so its lift is over its neighbours.
  for i = 0, #rows do
    if i ~= self.cursor then self:draw_card(m, i, self:card_spec(i)) end
  end
  if self.cursor == 0 or rows[self.cursor] then
    self:draw_card(m, self.cursor, self:card_spec(self.cursor))
  end
  self:draw_header()

  if #rows == 0 then
    UI.label(self.error or I18n.t("asking the server…"), 0, math.floor(vh / 2), "label",
      { width = vw, align = "center", color = self.error and Theme.redA or Theme.mute })
  end

  self.app:footer(I18n.t("ARROWS choose   ENTER go   P playground   ESC back"))
end

-- ------------------------------------------------------------------- input

--- The wheel moves the cursor, because on a desktop that is what a wheel is
--- for. Every screen in this client that has a list has one of these now.
function Categories:wheelmoved(_, dy)
  local n = self.categories and #self.categories or 0
  self.cursor = (self.cursor + (dy > 0 and -1 or 1)) % (n + 1)
  self.picked_at = Anim.now()
  SFX.play("move")
end

function Categories:keypressed(key)
  local n = self.categories and #self.categories or 0
  if key == "up" or key == "left" then
    self.cursor = (self.cursor - 1) % (n + 1)
    self.picked_at = Anim.now(); SFX.play("move"); return true
  end
  if key == "down" or key == "right" then
    self.cursor = (self.cursor + 1) % (n + 1)
    self.picked_at = Anim.now(); SFX.play("move"); return true
  end
  if key == "return" or key == "kpenter" or key == "space" then self:choose(); return true end
  if key == "p" then self:open_playground(); return true end
  return false
end

local function inside(r, x, y)
  return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

function Categories:mousemoved(x, y)
  if inside(self.back_rect, x, y) then self.hover = "back"; return end
  self.hover = nil
  for i = 0, #(self.categories or {}) do
    if inside(self:card_rect(i), x, y) then self.hover = i end
  end
end

function Categories:mousepressed(x, y)
  if inside(self.back_rect, x, y) then
    UI.press("cats:back", self.back_rect, { sfx = false })
    self.app:back()
    return
  end
  for i = 0, #(self.categories or {}) do
    if inside(self:card_rect(i), x, y) then
      -- First click selects, second opens: the lift is the feedback that
      -- says which one the next click will take.
      if self.cursor ~= i then
        self.cursor = i
        self.picked_at = Anim.now()
        SFX.play("move")
        return
      end
      self:choose()
      return
    end
  end
end

return Categories
