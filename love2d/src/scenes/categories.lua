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
function Categories:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_times", "bg_flat"), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.7)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

    local tint = Theme.land[self.land] or Theme.coin
  local t = Anim.now()

  -- The land's own mascot beside the title, idling, so the screen says which
  -- land it is without reading.
  Assets.sprite(MASCOT[self.land], 40, 52 + Anim.bob(t, { amount = 2 }), 44)
  UI.text(self.land:upper() .. " LAND", 72, 22, 16, tint)

  local rows = self.categories or {}
  local pad = Layout.isPortrait() and 12 or 60
  local w = vw - pad * 2
  -- Taller rows: the emblems are 3:1 and a short row shows very little of
  -- one. This is the number the art wants rather than the number the old
  -- text rows wanted.
  local rh = math.min(128, math.max(84, (vh - 120) / math.max(1, #rows) - 12))
  local y = 66

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
    local gutter = math.floor(math.min(150, w * 0.28))
    local right = 96
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
    if band_w > 40 and image then
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
    love.graphics.rectangle("fill", pad + 6, ry + 8, gutter - 4, 40)
    love.graphics.setColor(1, 1, 1, 1)
    -- The gutter plate's width, not the whole row: to its right is the
    -- mascot, and a blurb given the row would be drawn underneath it.
    local blurb_w = math.max(60, band_x - (pad + 14) - 10)
    UI.text(cat.category:upper(), pad + 14, ry + 12, 13, color, "left", blurb_w)
    UI.text(I18n.t(BLURB[cat.category] or ""), pad + 14, ry + 32, 7,
      Theme.withAlpha(color, 0.75), "left", blurb_w)

    -- The counts sit on their own plate, because behind them is artwork and
    -- a number over a painted crate is a number nobody can read.
    local progress = ("%d / %d"):format(cat.cleared, cat.total)
    local pw = math.max(76, UI.textWidth(progress, 10) + 12)
    UI.setColor(Theme.ink, 0.72)
    love.graphics.rectangle("fill", pad + w - 14 - pw, ry + 8, pw, 34)
    love.graphics.setColor(1, 1, 1, 1)
    UI.text(progress, pad + w - 8 - pw + (pw - UI.textWidth(progress, 10)) / 2,
      ry + 12, 10, color)
    UI.bar(pad + w - 10 - pw + 4, ry + 30, pw - 12, 7,
      cat.total > 0 and cat.cleared / cat.total or 0,
      cat.open and Theme.admit or Theme.dim)

    if cat.total > 0 and cat.cleared >= cat.total then
      Assets.marker("badge_cleared", pad + w - 40, ry + rh - 22, 30)
    elseif not cat.open then
      -- Only a category that genuinely cannot be entered. Nothing on the map
      -- is locked (§4.7); this is for a pack that failed to import.
      Assets.marker("badge_locked", pad + w - 40, ry + rh - 22, 26, { alpha = 0.85 })
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
  local pad = Layout.isPortrait() and 16 or 80
  local w = Layout.vw - pad * 2
  local rh = math.min(128, math.max(84, (Layout.vh - 120) / math.max(1, #rows) - 12))
  local ry = 66
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
