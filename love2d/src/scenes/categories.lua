-- CATEGORY SELECT. The three rows of one land, from `world.lands`.
--
-- `open` is the server's word (§4.6: "false when the category's first node is
-- still locked"), so a locked row is drawn locked and refuses to open. The
-- client does not work out for itself whether the player has earned it.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Anim = require("src.anim")

local Categories = {}
Categories.__index = Categories

local BLURB = {
  basic = "grammar. the streets you already walked.",
  advanced = "threads, mutexes, lifetimes, channels.",
  hacker = "timed. the whiteboard is watching.",
}

-- SPEC §0's order. `world.lands` does not promise one, and which row is drawn
-- first is presentation rather than a rule — but a category list that
-- reorders itself between two calls is a category list a player mis-clicks.
local ORDER = { basic = 1, advanced = 2, hacker = 3 }

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

local MASCOT = { rust = "sprite_ferris", go = "sprite_gogo" }

function Categories.new(app)
  return setmetatable({
    app = app, cursor = 1, categories = nil, error = nil,
    picked_at = 0, pressed_at = nil,
  }, Categories)
end

function Categories:enter(params)
  self.land = params.land or self.app.land or "rust"
  self.categories = params.categories and ordered(params.categories) or nil
  if not self.categories then self:refresh() end
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

function Categories:choose()
  local cat = self.categories and self.categories[self.cursor]
  if not cat then return end
  if not cat.open then
    SFX.play("locked")
    self.app:toast(I18n.t("clear the category before it first"))
    return
  end
  self.pressed_at = Anim.now()
  SFX.play("select")
  self.app.category = cat.category
  self.app:go("map", { land = self.land, category = cat.category })
end

--- The three category bands of one land.
---
--- Each row is `art/emblem_<land>_<category>.png`, a 384x128 band drawn
--- full-width.
---
--- **The trap, and it is worth stating.** DESIGN composed these with an empty
--- left quarter for the label, and `art/tools/process.py` then cropped to the
--- ink and re-centred — right for every other sprite in the pack, wrong for
--- these. The manifest's `box` proves it: `emblem_go_basic` has ink from
--- x=24 to x=359 of 384, so the reserved quarter is gone and the art now
--- fills the cell. So the label does not sit *on* the band; the band is inset
--- to the right of it, and the counts sit clear on the other side. Assuming
--- the empty quarter was still there would have put the word CATEGORY on top
--- of a crate of oranges.
--- Every measurement the rows are drawn from, taken from the type at the
--- current step. A function of the canvas and the rows rather than of the
--- scene, so `tests/test_screens.lua` can ask what the answer *is* at every
--- step without drawing anything.
---
---   * the gutter is the widest category name plus its padding, never less
---     than the authored share of the row, and never so wide that the
---     emblem has no band left — when the name alone needs the row, the
---     band gives way, because a name wrapped one letter to a line is not a
---     name;
---   * the row is as tall as the name, one line of blurb and the plates
---     need, and taller when the screen has the room;
---   * the counts plate is as wide as `NN / NN` at its size, and the right
---     margin follows it.
function Categories.metrics(vw, vh, rows)
  local title_y = 22
  local title_h = UI.lineHeight(16)
  local y0 = title_y + title_h + 18
  local pad = Layout.isPortrait() and 12 or 60
  local w = vw - pad * 2

  local name_h, blurb_h = UI.lineHeight(13), UI.lineHeight(7)
  local plate_h = name_h + 8
  local count_h = UI.lineHeight(10) + 4 + 7 + 10
  local widest = 0
  for _, cat in ipairs(rows) do
    widest = math.max(widest, UI.textWidth(tostring(cat.category or ""):upper(), 13))
  end
  local count_w = math.max(76, UI.textWidth("00 / 00", 10) + 16)
  local right = count_w + 20

  local gutter = math.max(math.floor(math.min(150, w * 0.28)), widest + 28)
  -- The band wants at least a square of the row; below that it is a sliver
  -- of a painting and the name takes the width instead.
  local band_min = 120
  if gutter > w - right - band_min then gutter = w - right end
  -- And when the name does not fit beside the counts either — the largest
  -- type step in a narrow portrait — the counts go **under** the name, on
  -- the row's second line, and the name gets the whole row.
  local stacked = widest + 28 > w - right
  if stacked then gutter = w - 12 end
  local label_w = math.max(40, gutter - 24)
  local count_y = stacked and (12 + name_h + 8) or 8

  -- Rows: what the type needs, stretched to what the screen has.
  local n = math.max(1, #rows)
  local bottom = vh - UI.footerHeight() - 12
  local need = 12 + name_h + 4 + blurb_h + 14
  need = math.max(need, 8 + math.max(plate_h, count_h) + 8 + 22)
  if stacked then need = math.max(need, count_y + count_h + 10) end
  local avail = math.floor((bottom - y0) / n) - 12
  local rh = math.max(need, math.min(math.max(84, avail), math.max(128, need)))
  rh = math.min(rh, math.max(need, avail))

  -- Blurb lines that fit under the name inside the row, above the badge
  -- strip at the bottom.
  local blurb_y = 12 + name_h + 4
  local blurb_lh = blurb_h + 2
  local blurb_lines = math.max(0, math.floor((rh - blurb_y - 12) / blurb_lh))
  -- Stacked, the blurb would run under the counts plate: it goes.
  if stacked then blurb_lines = 0 end

  return {
    title_y = title_y, title_h = title_h, y0 = y0,
    pad = pad, w = w, rh = rh, gutter = gutter, right = right,
    label_w = label_w, plate_h = plate_h,
    blurb_y = blurb_y, blurb_lh = blurb_lh, blurb_lines = math.min(blurb_lines, 3),
    count_w = count_w, count_h = count_h, count_y = count_y,
    stacked = stacked, widest = widest,
  }
end

function Categories:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_times", "bg_flat"), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.7)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

    local tint = Theme.land[self.land] or Theme.coin
  local t = Anim.now()

  -- Every size on this screen is taken from the type it has to hold, at
  -- the player's step. It used to be a set of numbers — a 150 px gutter, a
  -- 40 px plate, rows starting at y=66 — that were right at the authored
  -- size and wrong at every other: at step 4 in portrait the category name
  -- was 65 px tall in a 150 px gutter, and wrapped one letter to a line.
  -- The browser client measures the same way (`lands.ts`: the row is the
  -- taller of a touch target and the type it holds).
  local m = Categories.metrics(vw, vh, self.categories or {})

  -- The land's own mascot beside the title, idling, so the screen says which
  -- land it is without reading.
  Assets.sprite(MASCOT[self.land], 40, m.title_y + m.title_h * 0.9 + Anim.bob(t, { amount = 2 }),
    math.max(44, m.title_h * 1.4))
  UI.text(self.land:upper() .. " LAND", 72, m.title_y, 16, tint)

  local rows = self.categories or {}
  local pad, w, rh = m.pad, m.w, m.rh
  local y = m.y0

  for i, cat in ipairs(rows) do
    local selected = i == self.cursor
    local lift = selected and Anim.lift(Anim.now() - self.picked_at) * 5 or 0
    local push = (selected and self.pressed_at) and Anim.press(t - self.pressed_at) * 4 or 0
    local ry = y - lift + push

    if selected then
      UI.setColor(Theme.ink, 0.32)
      love.graphics.rectangle("fill", pad + 4, ry + rh + 2, w - 8, 3 + lift)
      love.graphics.setColor(1, 1, 1, 1)
    end

    UI.panel(pad, ry, w, rh, {
      fill = Theme.withAlpha(cat.open and Theme.navy or Theme.ink, selected and 0.95 or 0.86),
      tint = selected and Theme.coin or tint,
    })

    -- The label gutter on the left, then the band, then the counts.
    local gutter, right = m.gutter, m.right
    local band_x = pad + gutter
    local band_w = w - gutter - right
    -- **Adapted, not assumed.** The emblems are 384x128 — 3:1 — and DESIGN
    -- sized that for the browser's category row. This row is nearer 9:1, so
    -- `cover` scaled to the width and threw away two thirds of the picture
    -- vertically: a horizontal slice of a tram. Instead the band is drawn at
    -- its own aspect, as tall as the row, anchored to the **right** so it
    -- never runs under the label, with the panel showing through beside it.
    local emblem = ("emblem_%s_%s"):format(self.land, cat.category)
    local image = Assets.image(emblem)
    if m.stacked then
      -- The name has the row; there is no band to draw a painting in.
    elseif band_w > 40 and image then
      local iw, ih = image:getDimensions()
      local es = (rh - 8) / ih
      local ew = iw * es
      local ex = band_x + band_w - ew
      love.graphics.setScissor(band_x, ry + 4, band_w, rh - 8)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.draw(image, ex, ry + 4, 0, es, es)
      -- A short fade on its left edge so the art does not cut hard against
      -- the panel it sits in.
      for k = 0, 14 do
        UI.setColor(Theme.navy, 0.95 - k * 0.068)
        love.graphics.rectangle("fill", ex + k * 3, ry + 4, 3, rh - 8)
      end
      love.graphics.setScissor()
      love.graphics.setColor(1, 1, 1, 1)
    elseif band_w > 40 then
      -- No art: the action mascot alone rather than a coloured hole.
      Assets.sprite(("mascot_%s_%s"):format(self.land, cat.category),
        band_x + band_w - 40, ry + rh - 8, rh - 20)
    end

    local color = cat.open and Theme.cream or Theme.dim
    UI.setColor(Theme.ink, 0.55)
    love.graphics.rectangle("fill", pad + 6, ry + 8, gutter - 4, m.plate_h)
    love.graphics.setColor(1, 1, 1, 1)
    -- The gutter plate's width, not the whole row: to its right is the
    -- mascot, and a blurb given the row would be drawn underneath it.
    local blurb_w = m.label_w
    UI.text(cat.category:upper(), pad + 14, ry + 12, 13, color, "left", blurb_w)
    -- Only the blurb lines the row has room for, and none when it has room
    -- for none: a blurb wrapped to eight lines is drawn through the plate
    -- under it, and one clipped mid-sentence says less than nothing.
    if m.blurb_lines > 0 then
      local lines = UI.wrap(I18n.t(BLURB[cat.category] or ""), blurb_w, 7)
      for k = 1, math.min(#lines, m.blurb_lines) do
        UI.text(lines[k], pad + 14, m.blurb_y + ry + (k - 1) * m.blurb_lh, 7,
          Theme.withAlpha(color, 0.75))
      end
    end

    -- The counts sit on their own plate, because behind them is artwork and
    -- a number over a painted crate is a number nobody can read.
    local progress = ("%d / %d"):format(cat.cleared, cat.total)
    local pw = m.count_w
    UI.setColor(Theme.ink, 0.72)
    local cy = ry + m.count_y
    love.graphics.rectangle("fill", pad + w - 14 - pw, cy, pw, m.count_h)
    love.graphics.setColor(1, 1, 1, 1)
    UI.text(progress, pad + w - 14 - pw + (pw - UI.textWidth(progress, 10)) / 2,
      cy + 4, 10, color)
    UI.bar(pad + w - 14 - pw + 6, cy + 4 + UI.lineHeight(10) + 4, pw - 12, 7,
      cat.total > 0 and cat.cleared / cat.total or 0,
      cat.open and Theme.admit or Theme.dim)

    -- The badge keeps clear of the counts plate, which sits at the bottom
    -- right when the row is stacked.
    local bx = m.stacked and (pad + w - 14 - pw - 36) or (pad + w - 40)
    if cat.total > 0 and cat.cleared >= cat.total then
      Assets.marker("badge_cleared", bx, ry + rh - 22, 30)
    elseif not cat.open then
      -- Only a category that genuinely cannot be entered. Nothing on the map
      -- is locked (§4.7); this is for a pack that failed to import.
      Assets.marker("badge_locked", bx, ry + rh - 22, 26, { alpha = 0.85 })
      UI.text(I18n.t("UNAVAILABLE"), pad + 14, ry + rh - 18, 7, Theme.dim)
    end

    y = y + rh + 12
  end

  if #rows == 0 then
    UI.text(self.error or "asking the server…", 0, vh / 2, 9,
      self.error and Theme.red or Theme.withAlpha(Theme.cream, 0.7), "center", vw)
  end

  self.app:footer(I18n.t("ARROWS choose   ENTER go   ESC back"))
end

function Categories:keypressed(key)
  local n = math.max(1, self.categories and #self.categories or 1)
  if key == "up" or key == "left" then
    self.cursor = ((self.cursor - 2) % n) + 1
    self.picked_at = Anim.now(); SFX.play("move"); return true
  end
  if key == "down" or key == "right" then
    self.cursor = (self.cursor % n) + 1
    self.picked_at = Anim.now(); SFX.play("move"); return true
  end
  if key == "return" or key == "kpenter" or key == "space" then self:choose(); return true end
  return false
end

function Categories:mousepressed(x, y)
  local rows = self.categories or {}
  -- The same numbers the draw used. This had its own copy — with a different
  -- margin, even — so a press was tested against rows that were not where
  -- the rows were drawn.
  local m = Categories.metrics(Layout.vw, Layout.vh, rows)
  local pad, w, rh = m.pad, m.w, m.rh
  local ry = m.y0
  for i = 1, #rows do
    if x >= pad and x <= pad + w and y >= ry and y <= ry + rh then
      if self.cursor ~= i then
        self.cursor = i
        self.picked_at = Anim.now()
        SFX.play("move")
        return
      end
      self:choose()
      return
    end
    ry = ry + rh + 12
  end
end

return Categories
