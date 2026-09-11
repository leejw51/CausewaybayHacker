-- CATEGORY SELECT. The three rows of one land, from `world.lands`.
--
-- `open` is the server's word (§4.6: "false when the category's first node is
-- still locked"), so a locked row is drawn locked and refuses to open. The
-- client does not work out for itself whether the player has earned it.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local SFX = require("src.sfx")

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

function Categories.new(app)
  return setmetatable({ app = app, cursor = 1, categories = nil, error = nil }, Categories)
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
    self.app:toast("clear the category before it first")
    return
  end
  SFX.play("select")
  self.app.category = cat.category
  self.app:go("map", { land = self.land, category = cat.category })
end

function Categories:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_times", "bg_flat"), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.66)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local s = Layout.uiScale()
  local tint = Theme.land[self.land] or Theme.coin
  UI.text(self.land:upper() .. " LAND", 0, 22, math.floor(18 * s), tint, "center", vw)

  local rows = self.categories or {}
  local pad = Layout.isPortrait() and 16 or 80
  local w = vw - pad * 2
  local rh = math.min(96, math.max(64, (vh - 140) / math.max(1, #rows) - 12))
  local y = 68

  for i, cat in ipairs(rows) do
    local selected = i == self.cursor
    UI.panel(pad, y, w, rh, {
      fill = Theme.withAlpha(cat.open and Theme.navy or Theme.ink, 0.9),
      tint = selected and Theme.coin or tint,
    })
    local color = cat.open and Theme.cream or Theme.dim
    UI.text(cat.category:upper(), pad + 16, y + 12, math.floor(14 * s), color)
    UI.text(BLURB[cat.category] or "", pad + 16, y + 12 + 20, 8,
      Theme.withAlpha(color, 0.75))
    local progress = ("%d / %d"):format(cat.cleared, cat.total)
    UI.text(progress, pad + w - 16 - UI.textWidth(progress, 10), y + 14, 10, color)
    UI.bar(pad + 16, y + rh - 20, w - 32, 8,
      cat.total > 0 and cat.cleared / cat.total or 0, cat.open and Theme.admit or Theme.dim)
    if not cat.open then
      UI.text("LOCKED", pad + w - 16 - UI.textWidth("LOCKED", 8), y + rh - 34, 8, Theme.dim)
    end
    y = y + rh + 12
  end

  if #rows == 0 then
    UI.text(self.error or "asking the server…", 0, vh / 2, 9,
      self.error and Theme.red or Theme.withAlpha(Theme.cream, 0.7), "center", vw)
  end

  self.app:footer("ARROWS choose   ENTER go   ESC back")
end

function Categories:keypressed(key)
  local n = math.max(1, self.categories and #self.categories or 1)
  if key == "up" or key == "left" then
    self.cursor = ((self.cursor - 2) % n) + 1; SFX.play("move"); return true
  end
  if key == "down" or key == "right" then
    self.cursor = (self.cursor % n) + 1; SFX.play("move"); return true
  end
  if key == "return" or key == "kpenter" or key == "space" then self:choose(); return true end
  return false
end

function Categories:mousepressed(x, y)
  local rows = self.categories or {}
  local pad = Layout.isPortrait() and 16 or 80
  local w = Layout.vw - pad * 2
  local rh = math.min(96, math.max(64, (Layout.vh - 140) / math.max(1, #rows) - 12))
  local ry = 68
  for i = 1, #rows do
    if x >= pad and x <= pad + w and y >= ry and y <= ry + rh then
      self.cursor = i
      self:choose()
      return
    end
    ry = ry + rh + 12
  end
end

return Categories
