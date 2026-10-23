-- LAND SELECT. `world.lands` (PROTOCOL §4.6), drawn as a card per land —
-- Balatro's deck select, in this game's furniture (`docs/love2d-ui.md`
-- §lands).
--
-- The counts, the `open` flags and the star totals are all the server's. This
-- screen adds nothing to them: if `go` comes back with every category shut,
-- that is what it draws.
--
-- ## The layout
--
--   * **Landscape:** a 5×2 grid of cards, 232×280 at the design size with a
--     16 px gap, centred in the bounded content area (so a 1920 fullscreen
--     gets the same grid in the middle, not nine cards stretched across).
--     Each card: a 6 px land-colour strip on top, the mascot in a 128 px
--     box, the name in title-32 **text** (never the land colour: C++'s blue
--     on navy was 2:1), an 8 px progress bar and the count. The tenth slot
--     is CODE PLAYGROUND, a gold-strip card with the coder.
--   * **Upright:** the list — a 96 px playground card, then a row per land,
--     each with the strip down its left edge, the mascot in a box, the name
--     and the count, and the bar under the name.
--
-- **Categories are not listed on the card.** That is what the categories
-- screen is for; nine columns of "CHEATSHEET…" twice each was the loudest
-- thing on the old screen.
--
-- The selected card lifts 8 px, scales to 1.05, wears a gold edge and sways
-- under the pointer; the cards deal in from 24 px below on entry, 40 ms
-- apart in reading order.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local SFX = require("src.sfx")
local Anim = require("src.anim")
local Juice = require("src.juice")
local Fx = require("src.fx")
local I18n = require("src.i18n")
local Land = require("src.land")

local Lands = {}
Lands.__index = Lands

local LAND_ORDER = Land.ORDER
local CATEGORY_ORDER = {
  cheatsheet = 0, cheatsheet_advanced = 1, verybasic = 2, basic = 3, advanced = 4, hacker = 5, frameworks = 6,
}

--- SPEC §0's order. `world.lands` does not promise one, and the rows were
--- arriving alphabetical — ADVANCED, BASIC, HACKER — which reads as a list of
--- words rather than a path through a subject. The categories screen is
--- handed this list, so it is sorted here.
local function ordered_categories(categories)
  local out = {}
  for i, cat in ipairs(categories or {}) do out[i] = cat end
  table.sort(out, function(a, b)
    local ra = CATEGORY_ORDER[a.category] or 99
    local rb = CATEGORY_ORDER[b.category] or 99
    if ra ~= rb then return ra < rb end
    return tostring(a.category) < tostring(b.category)
  end)
  return out
end

--- The design-size card and the grid's shape.
Lands.CARD_W, Lands.CARD_H = 232, 280
Lands.COLS = 5

function Lands.new(app)
  return setmetatable({
    app = app, lands = nil, cursor = 1, error = nil, t = 0,
    -- When the cursor last landed here, so the chosen card can lift.
    picked_at = 0,
    -- Which card, the tile or the button the pointer is over.
    hover = nil,
    header_h = UI.headerHeight(),
  }, Lands)
end

function Lands:enter()
  self:refresh()
  Juice.forget("lands:")
end

--- A stable order for the cards, and a stable starting cursor.
local function ordered(lands)
  local out = {}
  for i, land in ipairs(lands or {}) do
    out[i] = land
  end
  table.sort(out, function(a, b)
    local ra, rb = Land.rank(a.land), Land.rank(b.land)
    if ra ~= rb then return ra < rb end
    return tostring(a.land) < tostring(b.land)
  end)
  return out
end

function Lands:refresh()
  self.error = nil
  self.app.session:request("world.lands", {}, function(ok, payload, why)
    if not ok then
      self.error = why.player
      return
    end
    self.lands = ordered(payload.lands)
    for _, land in ipairs(self.lands) do
      land.categories = ordered_categories(land.categories)
    end
    -- Come back to the land the player was last in.
    for i, land in ipairs(self.lands) do
      if land.land == self.app.land then self.cursor = i end
    end
    self.cursor = math.max(1, math.min(#self.lands, self.cursor))
  end)
end

function Lands:land_at(index)
  if not self.lands then return nil end
  return self.lands[index]
end

function Lands:choose()
  local land = self:land_at(self.cursor)
  if not land then return end
  local rects = self:card_rects()
  UI.press("lands:card" .. self.cursor, rects[self.cursor], { sfx = false })
  SFX.play("select")
  self.app.land = land.land
  self.app:go("categories", { land = land.land, categories = land.categories })
end

function Lands:update(dt)
  self.t = self.t + dt
end

--- Seconds since this card became the selected one.
function Lands:selected_age()
  return Anim.now() - self.picked_at
end

--- The whole arrangement — **one function, read by the draw and by the
--- click**: the land cards, the playground card and the content box they
--- sit in. The grid never stretches: on a canvas wider than the design it
--- is centred in `Layout.bounded`'s width, and on one taller it is centred
--- in the content height.
function Lands:grid()
  local n = math.max(1, self.lands and #self.lands or #LAND_ORDER)
  local portrait = Layout.isPortrait()
  local header = self.header_h or UI.headerHeight()
  local cx, cy, cw, ch = UI.bounded(nil, header + Theme.space.lg,
    Layout.vh - UI.footerHeight() - Theme.space.lg)
  local gap = Theme.gap
  local cards, tile = {}, nil
  if portrait then
    local tile_h = 96
    local row_gap = Theme.rowGap
    local row_h = math.floor((ch - tile_h - row_gap * n) / n)
    row_h = math.max(36, math.min(88, row_h))
    tile = { x = cx, y = cy, w = cw, h = tile_h }
    local y = cy + tile_h + row_gap
    for i = 1, n do
      cards[i] = { x = cx, y = y, w = cw, h = row_h }
      y = y + row_h + row_gap
    end
  else
    local total = n + 1
    local cols = total <= Lands.COLS * 2 and Lands.COLS or math.ceil(total / 2)
    local rows = math.ceil(total / cols)
    local w = math.min(Lands.CARD_W, math.floor((cw - gap * (cols - 1)) / cols))
    local h = math.min(Lands.CARD_H, math.floor((ch - gap * (rows - 1)) / rows))
    h = math.max(36, h)
    w = math.max(36, w)
    local gw = cols * w + (cols - 1) * gap
    local gh = rows * h + (rows - 1) * gap
    local x0 = cx + math.floor((cw - gw) / 2)
    local y0 = cy + math.floor(math.max(0, ch - gh) / 2)
    for i = 1, total do
      local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
      local r = { x = x0 + col * (w + gap), y = y0 + row * (h + gap), w = w, h = h }
      if i <= n then cards[i] = r else tile = r end
    end
  end
  return { cards = cards, tile = tile, n = n, x = cx, y = cy, w = cw, h = ch }
end

--- Where the land cards go. Returns the rects and how many.
function Lands:card_rects()
  local g = self:grid()
  return g.cards, g.n
end

--- The CODE PLAYGROUND card: the tenth slot in the grid, the first row of
--- the list.
function Lands:tile_rect()
  return self:grid().tile
end

--- The header's one button: AUTO SELECT (W), a secondary M button on the
--- right. Kept under `weakest` for the drive scripts.
function Lands:button_rects()
  local label = I18n.t("AUTO SELECT")
  -- Measured by the component, so the button never grows past the rect
  -- (on a wide canvas its label is Galmuri at 24).
  local bw, bh = UI.buttonSize(label, { key = "W" })
  bw = math.max(120, bw)
  bh = math.max(Theme.control.buttonM, bh)
  local x = Layout.vw - Layout.gutter() - bw
  local y = math.floor(((self.header_h or UI.headerHeight()) - bh) / 2)
  return { weakest = { x = x, y = y, w = bw, h = bh, label = label } }
end

--- A button's height, and the bottom of the content: kept for callers.
function Lands.band_height()
  return Theme.control.buttonM
end

function Lands.band_top()
  return Layout.vh - UI.footerHeight()
end

--- The largest authored size at which the old title fit the canvas — the
--- header draws the title at the fixed role now; kept for callers.
function Lands.title_size(vw)
  local label = I18n.t("PICK A LAND")
  for _, size in ipairs({ 18, 16, 14, 12, 10, 8 }) do
    if UI.textWidth(label, size) <= vw - 40 then return size end
  end
  return 8
end

--- A mascot standing on `(x, bottom)` inside a `box` square: the taller
--- side of its ink is `box`, so a wide crab and a tall cup are the same
--- size on the card and neither overflows.
local function mascot(name, x, bottom, box, opts)
  if not name then return false end
  local b = Assets.box[name]
  local image = Assets.image(name)
  if not image then return false end
  local iw, ih = image:getDimensions()
  local ink_w = (b and b.w and b.w > 0) and b.w or ((b and b.maxx and b.minx) and (b.maxx - b.minx + 1) or iw)
  local ink_h = (b and b.h and b.h > 0) and b.h or ih
  local height = box
  if ink_w > ink_h then height = box * ink_h / ink_w end
  return Assets.sprite(name, x, bottom, height, opts)
end

--- A land with no sprite on disk: a disc in its colour with its initial.
local function standin(key, cx, cy, size)
  UI.setColor(Theme.land[key] or Theme.mute, 0.9)
  love.graphics.circle("fill", cx, cy, size / 2, 16)
  UI.label(Land.name(key):sub(1, 1), cx - size / 2, cy - UI.lead("title") / 2, "title",
    { width = size, align = "center", color = Theme.edge })
end

--- What a card calls its land: "RUST LAND" when that fits `width` in the
--- title role, the bare name when it does not ("PYTORCH LAND" is 192 px at
--- 32 on a 184 px card; "PYTORCH" is the land, "PYTORCH LA…" is a cut).
--- The suffix is the language's — a format string, `ZEMĚ %s` in Czech — so
--- it is the whole phrase that is measured, never a suffix stripped.
function Lands.land_label(key, width, role)
  role = role or "title"
  local name = Land.name(key)
  local full = I18n.t("%s LAND", name)
  if UI.labelWidth(full, role) <= width then return full end
  return name
end

--- The whole land's progress: cleared and total across its roads.
local function tally(land)
  local cleared, total = 0, 0
  for _, cat in ipairs(land and land.categories or {}) do
    cleared = cleared + (cat.cleared or 0)
    total = total + (cat.total or 0)
  end
  return cleared, total
end

--- One land card into its rect. `selected` is the keyboard cursor; the
--- pointer hover is `self.hover == i`. Tall rects are cards, short ones
--- are rows.
function Lands:draw_card(i, r, land, fallback, selected)
  local key = land and land.land or fallback
  local tint = Theme.land[key] or Theme.mute
  local t = Anim.now()
  local k = Juice.enter("lands:card" .. i, { dur = Theme.motion.enter, delay = Juice.stagger(i, Theme.motion.stagger) })
  local hot = (selected or self.hover == i) and 1 or 0
  local a = Juice.follow("lands:hot" .. i, hot, { speed = 18 })
  local press = Juice.pressed("press:lands:card" .. i)
  local tall = r.h >= 160
  local lift = (tall and 8 or 4) * a
  local scale = 1 + (tall and 0.05 or 0.015) * a
  local y = r.y + (1 - k) * 24 - lift + 4 * press
  local alpha = math.min(1, k * 1.5)
  local cx, cy = r.x + r.w / 2, y + r.h / 2
  local sway = (selected and a > 0.01) and math.sin(t * math.pi * 2 * Theme.motion.sway + i) * 1.5 * a * math.pi / 180 or 0

  love.graphics.push()
  love.graphics.translate(cx, cy)
  love.graphics.rotate(sway)
  love.graphics.scale(scale, scale)
  love.graphics.translate(-cx, -cy)

  local cleared, total = tally(land)
  local count = land and ("%d / %d"):format(cleared, total) or "…"
  local sprite = Land.mascot(key)
  local bob = Anim.bob(t, { amount = selected and 3 or 1.5, phase = Land.phase(key) })

  if tall then
    UI.card(r.x, y, r.w, r.h, { strip = tint, stripH = Theme.landStripeH, hot = a, selected = selected,
      alpha = alpha, shadowDy = Theme.shadowDy - 5 * press, pad = 0 })
    local pad = Theme.space.xl
    local inner = r.w - pad * 2
    -- The mascot box: 128, or what the card can hold.
    local box = math.min(128, inner, math.floor(r.h * 0.46))
    local top = y + Theme.landStripeH + Theme.space.lg
    local base = top + box + bob
    if not mascot(sprite, cx, base, box, { alpha = alpha }) then standin(key, cx, top + box / 2 + bob, box * 0.7) end
    local ny = top + box + Theme.space.md
    UI.label(Lands.land_label(key, inner), r.x + pad, ny, "title",
      { width = inner, align = "center", ellipsis = true, alpha = alpha })
    local by = ny + UI.lead("title") + Theme.space.md
    if by + 8 + Theme.space.md + UI.lead("label") <= y + r.h - Theme.space.md then
      UI.bar(r.x + pad, by, inner, 8, total > 0 and cleared / total or 0, Theme.gold)
      UI.label(count, r.x + pad, by + 8 + Theme.space.sm, "label",
        { width = inner, align = "center", color = Theme.mute, alpha = alpha })
    end
  else
    UI.card(r.x, y, r.w, r.h, { stripe = tint, hot = a, selected = selected, alpha = alpha,
      shadowDy = Theme.shadowDy - 5 * press, pad = 0 })
    local pad = Theme.space.lg
    local box = math.min(64, r.h - Theme.space.lg)
    local mx = r.x + Theme.landStripeH + pad + box / 2
    local base = y + (r.h + box) / 2 + bob * 0.5
    if not mascot(sprite, mx, base, box, { alpha = alpha }) then standin(key, mx, y + r.h / 2, box * 0.7) end
    local tx = r.x + Theme.landStripeH + pad + box + pad
    local right = r.x + r.w - Theme.space.xl
    local cw = UI.labelWidth(count, "label")
    local room = right - tx - cw - Theme.space.lg
    local with_bar = r.h >= 60
    local ny = with_bar and (y + Theme.space.sm) or (y + math.floor((r.h - UI.lead("title")) / 2))
    UI.label(Lands.land_label(key, room), tx, ny, "title", { width = room, ellipsis = true, alpha = alpha })
    UI.label(count, right - cw, y + math.floor((r.h - UI.lead("label")) / 2), "label",
      { color = Theme.mute, alpha = alpha })
    if with_bar then
      UI.bar(tx, y + r.h - 14, right - tx, 8, total > 0 and cleared / total or 0, Theme.gold)
    end
  end
  love.graphics.pop()
end

--- The CODE PLAYGROUND card: gold strip, the coder, the name and one line.
function Lands:draw_tile(r)
  local t = Anim.now()
  local i = (self.lands and #self.lands or #LAND_ORDER) + 1
  local k = Juice.enter("lands:tile", { dur = Theme.motion.enter, delay = Juice.stagger(i, Theme.motion.stagger) })
  local hot = self.hover == "tile" and 1 or 0
  local a = Juice.follow("lands:tilehot", hot, { speed = 18 })
  local press = Juice.pressed("press:lands:tile")
  local tall = r.h >= 160
  local y = r.y + (1 - k) * 24 - (tall and 8 or 4) * a + 4 * press
  local alpha = math.min(1, k * 1.5)
  local cx, cy = r.x + r.w / 2, y + r.h / 2
  local scale = 1 + (tall and 0.05 or 0.015) * a
  love.graphics.push()
  love.graphics.translate(cx, cy)
  love.graphics.scale(scale, scale)
  love.graphics.translate(-cx, -cy)
  local title = I18n.t("CODE PLAYGROUND")
  local note = I18n.t("write anything, run it")
  local bob = Anim.bob(t, { amount = 3, period = 2.4 })
  if tall then
    UI.card(r.x, y, r.w, r.h, { strip = Theme.gold, stripH = Theme.landStripeH, hot = a, alpha = alpha,
      shadowDy = Theme.shadowDy - 5 * press, pad = 0 })
    local pad = Theme.space.xl
    local inner = r.w - pad * 2
    local box = math.min(128, inner, math.floor(r.h * 0.46))
    local top = y + Theme.landStripeH + Theme.space.lg
    if not mascot("agent_coder", cx, top + box + bob, box, { alpha = alpha }) then
      standin("remix", cx, top + box / 2 + bob, box * 0.7)
    end
    local ny = top + box + Theme.space.md
    local role = UI.labelWidth(title, "title") <= inner and "title" or "label"
    UI.label(title, r.x + pad, ny + (role == "label" and 8 or 0), role,
      { width = inner, align = "center", color = Theme.gold, ellipsis = true, alpha = alpha })
    local ky = ny + UI.lead("title") + Theme.space.md
    if ky + UI.lead("label") <= y + r.h - Theme.space.md then
      UI.label(note, r.x + pad, ky, "label", { width = inner, align = "center", color = Theme.mute, ellipsis = true, alpha = alpha })
    end
  else
    UI.card(r.x, y, r.w, r.h, { stripe = Theme.gold, hot = a, alpha = alpha,
      shadowDy = Theme.shadowDy - 5 * press, pad = 0 })
    local pad = Theme.space.lg
    local box = math.min(64, r.h - Theme.space.lg)
    local mx = r.x + Theme.landStripeH + pad + box / 2
    if not mascot("agent_coder", mx, y + (r.h + box) / 2 + bob * 0.5, box, { alpha = alpha }) then
      standin("remix", mx, y + r.h / 2, box * 0.7)
    end
    local tx = r.x + Theme.landStripeH + pad + box + pad
    local right = r.x + r.w - Theme.space.xl
    local cap_w = UI.keycapWidth("P")
    local ny = r.h >= 72 and (y + Theme.space.md) or (y + math.floor((r.h - UI.lead("title")) / 2))
    UI.label(title, tx, ny, "title", { width = right - tx - cap_w - Theme.space.lg, ellipsis = true, color = Theme.gold, alpha = alpha })
    if r.h >= 72 then
      UI.label(note, tx, ny + UI.lead("title") + 2, "label",
        { width = right - tx - cap_w - Theme.space.lg, ellipsis = true, color = Theme.mute, alpha = alpha })
    end
    UI.keycap(right - cap_w, y + math.floor((r.h - Theme.control.keycap) / 2), "P", { alpha = alpha })
  end
  love.graphics.pop()
end

--- The header band: the plaque (this screen's one hero frame) with the
--- title on it, the player's name on the left, AUTO SELECT on the right.
function Lands:draw_header()
  local vw = Layout.vw
  local h = self.header_h or UI.headerHeight()
  local g = Layout.gutter()
  UI.card(0, 0, vw, h, { variant = "bar", pad = 0 })
  UI.setColor(Theme.edge, 0.6)
  love.graphics.rectangle("fill", 0, h - 2, vw, 2)
  love.graphics.setColor(1, 1, 1, 1)

  local title = I18n.t("PICK A LAND")
  local b = self:button_rects().weakest
  local tw = UI.labelWidth(title, "title")
  local pw = math.min(360, math.max(tw + 64, 200))
  local ph = 48
  local px = math.floor((vw - pw) / 2)
  -- The plaque gives way to the button on a narrow canvas.
  if px + pw > b.x - Theme.space.md then px = math.max(g, b.x - Theme.space.md - pw) end
  local py = math.floor((h - ph) / 2)
  UI.card(px, py, pw, ph, { variant = "hero", art = "ui_plaque", artScale = 0.5, shadowDy = 4, pad = 0 })
  UI.label(title, px, py + math.floor((ph - UI.lead("title")) / 2), "title",
    { width = pw, align = "center", color = Theme.gold })

  if self.app.session and self.app.session.authed and self.app.session.display_name then
    local who = self.app.session:display_name()
    UI.label(UI.ellipsizeWith(who, px - g - Theme.space.md, UI.font("label")), g,
      math.floor((h - UI.lead("label")) / 2), "label", { color = Theme.mute })
  end

  local state = self.auto_busy and "disabled" or (self.hover == "weakest" and "hot" or "normal")
  UI.button(b.x, b.y, b.w, b.h, b.label, state, nil, { variant = "secondary", id = "lands:auto", key = "W" })
end

function Lands:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_street", "bg_flat"), 0, 0, vw, vh)
  UI.setColor(Theme.felt, Layout.isPortrait() and 0.8 or 0.72)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)
  Fx.ambient("dust", vw, vh)
  Fx.drawAmbient()

  local g = self:grid()
  -- The selected card last, so its lift and scale are over its neighbours.
  for i = 1, g.n do
    if i ~= self.cursor then
      self:draw_card(i, g.cards[i], self:land_at(i), LAND_ORDER[i], false)
    end
  end
  self:draw_tile(g.tile)
  if g.cards[self.cursor] then
    self:draw_card(self.cursor, g.cards[self.cursor], self:land_at(self.cursor), LAND_ORDER[self.cursor], true)
  end

  self:draw_header()

  local note = self.error or self.auto_note or (not self.lands and I18n.t("asking the server…")) or nil
  if note then
    local y = g.y + g.h - UI.lead("label") - Theme.space.sm
    if Layout.isPortrait() then y = g.y + g.h + 2 end
    UI.label(note, 0, y, "label",
      { width = vw, align = "center", color = self.error and Theme.redA or Theme.mute })
  end

  self.app:footer(I18n.t("ARROWS choose   ENTER go   W auto   P playground"))
end

-- Go straight to what the land under the cursor has next (§4.14d): the
-- first street not cleared, then the ones failed and still owed, then round
-- the land evenly. The rule is the server's, so this and the web client send
-- the same player to the same street.
function Lands:auto_select()
  if self.auto_busy then return end
  local land = self:land_at(self.cursor)
  if not land then return end
  self.auto_busy = true
  self.auto_note = I18n.t("looking for your next stage…")
  SFX.play("select")
  self.app.session:request("stats.next", { land = land.land }, function(ok, payload)
    self.auto_busy = false
    local pick = ok and payload.next
    if type(pick) ~= "table" then
      self.auto_note = I18n.t("this land has no stages yet")
      return
    end
    self.auto_note = nil
    self.app:go("quest", {
      quest_id = pick.quest_id,
      land = pick.land,
      category = pick.category,
    })
  end)
end

--- The wheel moves the cursor, because on a desktop that is what a wheel is
--- for.
function Lands:wheelmoved(_, dy)
  if not self.lands or #self.lands == 0 then return end
  local n = #self.lands
  self.cursor = ((self.cursor - 1 + (dy > 0 and -1 or 1)) % n) + 1
  self.picked_at = Anim.now()
  SFX.play("move")
end

--- The cursor through a 5-wide grid: left and right walk the order, up
--- and down move a row.
function Lands:keypressed(key)
  local n = math.max(1, self.lands and #self.lands or #LAND_ORDER)
  local cols = Layout.isPortrait() and 1 or Lands.COLS
  local function move(delta)
    self.cursor = ((self.cursor - 1 + delta) % n) + 1
    self.picked_at = Anim.now()
    SFX.play("move")
  end
  if key == "left" then move(-1); return true end
  if key == "right" then move(1); return true end
  if key == "up" then move(-cols); return true end
  if key == "down" then move(cols); return true end
  if key == "return" or key == "kpenter" or key == "space" then
    self:choose()
    return true
  end
  -- Mei's own desk, reachable without picking a land first: it belongs to
  -- nobody's curriculum (§4.9c).
  if key == "p" then
    UI.press("lands:tile", self:tile_rect(), { sfx = false })
    self.app:go("playground")
    return true
  end
  -- W for the stage that is winning. The ranking is the server's (§4.14c).
  if key == "w" then
    UI.press("lands:auto", self:button_rects().weakest, { sfx = false })
    self:auto_select()
    return true
  end
  if key == "r" then self:refresh(); return true end
  return false
end

--- Inside `r`?
local function inside(r, x, y)
  return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

function Lands:mousemoved(x, y)
  local over = nil
  if inside(self:tile_rect(), x, y) then over = "tile" end
  if inside(self:button_rects().weakest, x, y) then over = "weakest" end
  if not over then
    local rects, n = self:card_rects()
    for i = 1, n do
      if inside(rects[i], x, y) then over = i end
    end
  end
  self.hover = over
end

function Lands:mousepressed(x, y)
  if inside(self:button_rects().weakest, x, y) then
    UI.press("lands:auto", self:button_rects().weakest, { sfx = false })
    self:auto_select()
    return
  end
  if inside(self:tile_rect(), x, y) then
    UI.press("lands:tile", self:tile_rect(), { sfx = false })
    SFX.play("select")
    self.app:go("playground")
    return
  end
  local rects, n = self:card_rects()
  for i = 1, n do
    if inside(rects[i], x, y) then
      -- First click selects, second opens: on a card that lifts, the lift is
      -- the feedback that says which one the next click will take.
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

return Lands
