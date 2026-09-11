-- LAND SELECT. `world.lands` (PROTOCOL §4.6), drawn as two cards.
--
-- The counts, the `open` flags and the star totals are all the server's. This
-- screen adds nothing to them: if `go` comes back with every category shut,
-- that is what it draws.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local SFX = require("src.sfx")

local Lands = {}
Lands.__index = Lands

local LAND_ORDER = { "rust", "go" }
local MASCOT = { rust = "sprite_ferris", go = "sprite_gogo" }
local BLURB = {
  rust = "ownership, borrows, lifetimes",
  go = "goroutines, channels, interfaces",
}

function Lands.new(app)
  return setmetatable({ app = app, lands = nil, cursor = 1, error = nil, t = 0 }, Lands)
end

function Lands:enter()
  self:refresh()
end

--- A stable order for the cards, and a stable starting cursor.
---
--- `world.lands` does not promise an order and does not need to: which land
--- is drawn first is presentation, not a rule. Sorting here means the cards
--- do not swap places between two calls, and it means "press enter" lands on
--- the same thing every time — which a player relies on and a drive script
--- depends on. Anything the server sends that is not in `LAND_ORDER` is kept
--- and shown after the ones that are, rather than dropped.
local function ordered(lands)
  local rank = {}
  for i, name in ipairs(LAND_ORDER) do rank[name] = i end
  local out = {}
  for i, land in ipairs(lands or {}) do
    out[i] = land
  end
  table.sort(out, function(a, b)
    local ra = rank[a.land] or (#LAND_ORDER + 1)
    local rb = rank[b.land] or (#LAND_ORDER + 1)
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
  SFX.play("select")
  self.app.land = land.land
  self.app:go("categories", { land = land.land, categories = land.categories })
end

function Lands:update(dt)
  self.t = self.t + dt
end

function Lands:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_street", "bg_flat"), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.6)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local s = Layout.uiScale()
  UI.text("PICK A LAND", 0, 24, math.floor(18 * s), Theme.coin, "center", vw)

  local portrait = Layout.isPortrait()
  local n = math.max(1, self.lands and #self.lands or 2)
  local pad = 16
  local top = 70
  local bottom = vh - 60
  local cw, ch, gap
  if portrait then
    gap = 14
    cw = vw - pad * 2
    ch = math.min(280, (bottom - top - gap * (n - 1)) / n)
  else
    gap = 18
    cw = math.min(420, (vw - pad * 2 - gap * (n - 1)) / n)
    ch = math.min(360, bottom - top)
  end

  for i = 1, n do
    local land = self:land_at(i)
    local x, y
    if portrait then
      x = pad
      y = top + (i - 1) * (ch + gap)
    else
      local total = n * cw + (n - 1) * gap
      x = (vw - total) / 2 + (i - 1) * (cw + gap)
      y = top + (bottom - top - ch) / 2
    end
    self:draw_card(x, y, cw, ch, land, LAND_ORDER[i], i == self.cursor, s)
  end

  if self.error then
    UI.text(self.error, 0, vh - 52, 9, Theme.red, "center", vw)
  elseif not self.lands then
    UI.text("asking the server…", 0, vh - 52, 9,
      Theme.withAlpha(Theme.cream, 0.7), "center", vw)
  end

  self.app:footer("ARROWS choose   ENTER go")
end

function Lands:draw_card(x, y, w, h, land, fallback, selected, s)
  local key = land and land.land or fallback
  local tint = Theme.land[key] or Theme.dim
  UI.panel(x, y, w, h, {
    fill = Theme.withAlpha(Theme.navy, 0.92),
    tint = selected and Theme.coin or tint,
  })

  -- Placed on her feet with the measured `box`, not on the corner of the
  -- transparent canvas (art/manifest.json).
  if not Assets.sprite(MASCOT[key], x + w / 2, y + 124, 96) then
    Assets.fit(MASCOT[key], x + w / 2 - 56, y + 16, 112, 112, 1)
  end

  UI.text((key or "?"):upper() .. " LAND", x, y + 130, math.floor(14 * s), tint, "center", w)
  UI.text(BLURB[key] or "", x, y + 152, 8, Theme.withAlpha(Theme.cream, 0.7), "center", w)

  local row = y + 176
  if land then
    for _, cat in ipairs(land.categories) do
      local color = cat.open and Theme.cream or Theme.dim
      local label = ("%-9s %2d/%-2d"):format(cat.category:upper(), cat.cleared, cat.total)
      UI.text(label, x + 18, row, 9, color)
      -- The old version drew `stars / 4` as a 0..3 star row, which is a third
      -- scale in the same gold glyph and means nothing (design review §4).
      -- A category's star total is a number, so it is drawn as one.
      local total = ("%d\u{2605}"):format(cat.stars or 0)
      UI.text(total, x + w - 18 - UI.textWidth(total, 9), row, 9,
        cat.open and Theme.coin or Theme.dim)
      if not cat.open then
        UI.text("LOCKED", x + w - 60, row + 12, 7, Theme.dim)
      end
      row = row + 26
    end
  else
    UI.text("…", x, row, 10, Theme.dim, "center", w)
  end

  if selected then
    love.graphics.setLineWidth(3)
    UI.setColor(Theme.coin)
    love.graphics.rectangle("line", x - 3, y - 3, w + 6, h + 6)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

function Lands:keypressed(key)
  local n = math.max(1, self.lands and #self.lands or 2)
  if key == "left" or key == "up" then
    self.cursor = ((self.cursor - 2) % n) + 1
    SFX.play("move")
    return true
  end
  if key == "right" or key == "down" then
    self.cursor = (self.cursor % n) + 1
    SFX.play("move")
    return true
  end
  if key == "return" or key == "kpenter" or key == "space" then
    self:choose()
    return true
  end
  if key == "r" then self:refresh(); return true end
  return false
end

function Lands:mousepressed(x, y)
  local vw, vh = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  local n = math.max(1, self.lands and #self.lands or 2)
  local pad, top, bottom = 16, 70, vh - 60
  local cw, ch, gap
  if portrait then
    gap = 14; cw = vw - pad * 2; ch = math.min(280, (bottom - top - gap * (n - 1)) / n)
  else
    gap = 18
    cw = math.min(420, (vw - pad * 2 - gap * (n - 1)) / n)
    ch = math.min(360, bottom - top)
  end
  for i = 1, n do
    local cx, cy
    if portrait then
      cx, cy = pad, top + (i - 1) * (ch + gap)
    else
      local total = n * cw + (n - 1) * gap
      cx = (vw - total) / 2 + (i - 1) * (cw + gap)
      cy = top + (bottom - top - ch) / 2
    end
    if x >= cx and x <= cx + cw and y >= cy and y <= cy + ch then
      self.cursor = i
      self:choose()
      return
    end
  end
end

return Lands
