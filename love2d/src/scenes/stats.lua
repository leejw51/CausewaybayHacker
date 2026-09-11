-- STATS. `stats.summary` (§4.13) and `stats.mistakes` (§4.14).
--
-- Milestone 1 ends with "the failed attempt shows up in `stats.mistakes`"
-- (PLAN.md), so this screen is real rather than a stub: it is the half of the
-- slice that proves the mistakes were actually classified and stored.
--
-- `accuracy`, `streak_days` and `cleared_since` are the server's arithmetic.
-- This draws them.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")

local Stats = {}
Stats.__index = Stats

function Stats.new(app)
  return setmetatable({ app = app, summary = nil, mistakes = nil, scroll = 0 }, Stats)
end

function Stats:enter()
  self:refresh()
end

function Stats:refresh()
  self.error = nil
  self.app.session:request("stats.summary", {}, function(ok, payload, why)
    if ok then self.summary = payload else self.error = why.player end
  end)
  self.app.session:request("stats.mistakes", { limit = 12 }, function(ok, payload, why)
    if ok then self.mistakes = payload.mistakes else self.mistakes_error = why.player end
  end)
end

function Stats:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover("bg_flat", 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.8)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local s = Layout.uiScale()
  UI.text("STATS", 0, 18, math.floor(16 * s), Theme.coin, "center", vw)

  local pad = Layout.isPortrait() and 12 or 60
  local w = vw - pad * 2
  local y = 56

  local sm = self.summary
  local head_h = 86
  UI.panel(pad, y, w, head_h, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.coin })
  if sm then
    local cells = {
      { "CLEARED", ("%d / %d"):format(sm.cleared or 0, sm.total or 0) },
      { "ATTEMPTS", tostring(sm.attempts or 0) },
      { "ACCURACY", ("%d%%"):format(math.floor((sm.accuracy or 0) * 100 + 0.5)) },
      { "STARS", tostring(sm.stars or 0) },
      { "STREAK", ("%dd"):format(sm.streak_days or 0) },
    }
    local cw = w / #cells
    for i, cell in ipairs(cells) do
      local cx = pad + (i - 1) * cw
      UI.text(cell[1], cx, y + 14, 8, Theme.withAlpha(Theme.cream, 0.6), "center", cw)
      UI.text(cell[2], cx, y + 30, math.floor(14 * s), Theme.cream, "center", cw)
    end
    local by = y + 62
    UI.bar(pad + 16, by, w - 32, 10,
      (sm.total or 0) > 0 and (sm.cleared or 0) / sm.total or 0, Theme.admit)
  else
    UI.text(self.error or "asking the server…", pad, y + 34, 9,
      self.error and Theme.red or Theme.withAlpha(Theme.cream, 0.7), "center", w)
  end

  y = y + head_h + 12
  local list_h = vh - y - 46
  UI.panel(pad, y, w, list_h, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.red })
  love.graphics.setScissor(pad + 4, y + 4, w - 8, list_h - 8)
  local cy = y + 10 - self.scroll
  cy = cy + UI.text("YOUR MISTAKES, MOST FREQUENT FIRST", pad + 14, cy, 9, Theme.red) + 10

  if self.mistakes and #self.mistakes > 0 then
    for _, m in ipairs(self.mistakes) do
      UI.text(m.kind or "", pad + 14, cy, 9, Theme.brick)
      local count = ("×%d"):format(m.count or 0)
      UI.text(count, pad + w - 14 - UI.textWidth(count, 9), cy, 9, Theme.coin)
      cy = cy + 14
      for _, line in ipairs(UI.wrap(m.label or "", w - 40, 8)) do
        cy = cy + UI.text(line, pad + 22, cy, 8, Theme.cream) + 2
      end
      if m.concepts and #m.concepts > 0 then
        cy = cy + UI.text("drill: " .. table.concat(m.concepts, ", "), pad + 22, cy, 7,
          Theme.withAlpha(Theme.cyan, 0.85)) + 2
      end
      cy = cy + UI.text(("%d clean attempts since"):format(m.cleared_since or 0),
        pad + 22, cy, 7, Theme.withAlpha(Theme.cream, 0.5)) + 8
    end
  elseif self.mistakes then
    UI.text("nothing yet. that is either very good or very new.",
      pad + 14, cy, 8, Theme.withAlpha(Theme.cream, 0.6))
  else
    UI.text(self.mistakes_error or "asking the server…", pad + 14, cy, 8,
      self.mistakes_error and Theme.red or Theme.withAlpha(Theme.cream, 0.6))
  end
  love.graphics.setScissor()

  self.app:footer("R refresh   ARROWS scroll   ESC map")
end

function Stats:keypressed(key)
  if key == "r" then self:refresh(); return true end
  if key == "up" then self.scroll = math.max(0, self.scroll - 28); return true end
  if key == "down" then self.scroll = self.scroll + 28; return true end
  return false
end

function Stats:wheelmoved(_, dy)
  self.scroll = math.max(0, self.scroll - dy * 28)
end

return Stats
