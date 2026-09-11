-- RESULT. One `Attempt` (§5.4), rendered.
--
-- Every number on this screen is the server's. The verdict, the star count,
-- whether `cleared` is true — none of it is recomputed here, and `cleared`
-- means "did this submission just clear the node", not "is the node cleared"
-- (§5.4), so a re-solve says ALREADY CLEARED rather than stamping twice.
--
-- The mistakes list is the point of the whole game (SPEC §7): the compiler's
-- own error identity, kept, so `stats.mistakes` has something to count.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local Ease = require("src.ease")

local Result = {}
Result.__index = Result

local VERDICT_LABEL = {
  accepted = "ACCEPTED",
  wrong_answer = "WRONG ANSWER",
  compile_error = "COMPILE ERROR",
  runtime_error = "RUNTIME ERROR",
  timeout = "TIMEOUT",
  output_limit = "OUTPUT LIMIT",
  internal_error = "INTERNAL ERROR",
}

function Result.new(app)
  return setmetatable({ app = app, t = 0, scroll = 0 }, Result)
end

function Result:enter(params)
  self.attempt = params.attempt or self.app.last_attempt
  self.quest = params.quest
  self.log = params.log
  self.t = 0
end

function Result:update(dt)
  self.t = self.t + dt
end

function Result:draw()
  local vw, vh = Layout.vw, Layout.vh
  -- The quest's own plate, dimmed (docs/art.md §5), so the result reads as
  -- the same place rather than a new screen.
  local land = (self.quest and self.quest.land) or self.app.land or "rust"
  Assets.cover(require("src.scenes.quest").backdrop(land,
    (self.quest and self.quest.category) or self.app.category), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.82)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local a = self.attempt
  if not a then
    UI.text("no attempt", 0, vh / 2, 12, Theme.dim, "center", vw)
    self.app:footer("ESC map")
    return
  end

  local s = Layout.uiScale()
  local accepted = a.verdict == "accepted"
  local color = Theme.verdict[a.verdict] or Theme.dim

  -- The banner drops in (docs/art.md §7's clear sequence, in miniature).
  local drop = Ease.expOut(math.min(1, self.t / 0.45))
  local by = -40 + drop * 84
  UI.setColor(color, 0.92)
  love.graphics.rectangle("fill", 0, by, vw, 56)
  UI.setColor(Theme.ink)
  love.graphics.setLineWidth(3)
  love.graphics.rectangle("line", 0, by, vw, 56)
  love.graphics.setColor(1, 1, 1, 1)
  UI.text(VERDICT_LABEL[a.verdict] or a.verdict:upper(), 0, by + 18,
    math.floor(18 * s), Theme.cream, "center", vw)

  local pad = Layout.isPortrait() and 14 or 60
  local x = pad
  local y = by + 76
  local w = vw - pad * 2

  UI.panel(x, y, w, vh - y - 56, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = color })
  love.graphics.setScissor(x + 4, y + 4, w - 8, vh - y - 64)
  local cx = x + 16
  local cy = y + 12 - self.scroll
  local column = w - 32
  local indent = column - 16

  if self.quest then
    cy = cy + UI.text(self.quest.title or "", cx, cy, 12, Theme.coin) + 6
  end

  cy = cy + UI.text(("TESTS  %d / %d"):format(a.tests_passed or 0, a.tests_total or 0),
    cx, cy, 10, Theme.cream) + 6
  cy = cy + UI.text(("COMPILE %dms   RUN %dms   EXIT %s"):format(
    a.compile_ms or 0, a.run_ms or 0,
    a.exit_code == nil and "-" or tostring(a.exit_code)), cx, cy, 8,
    Theme.withAlpha(Theme.cream, 0.75)) + 10

  -- SPEC §0: the node is stamped CLEARED, for good.
  if a.cleared then
    UI.setColor(Theme.admit, 0.25)
    love.graphics.rectangle("fill", cx, cy, w - 32, 34)
    UI.text("CLEARED", cx + 10, cy + 11, 12, Theme.admit)
    UI.stars(cx + w - 32 - 3 * 15, cy + 9, a.stars or 0, 12)
    cy = cy + 42
  elseif accepted then
    cy = cy + UI.text("already cleared — stars keep the best run", cx, cy, 8,
      Theme.withAlpha(Theme.cream, 0.7)) + 10
  end

  if a.mistakes and #a.mistakes > 0 then
    cy = cy + UI.text("WHAT WENT WRONG", cx, cy, 9, Theme.red) + 6
    for _, m in ipairs(a.mistakes) do
      local head = ("%s%s"):format(m.kind, m.code and (" [" .. m.code .. "]") or "")
      cy = cy + UI.text(head, cx, cy, 9, Theme.brick) + 3
      for _, line in ipairs(UI.wrap(m.message or "", indent, 8)) do
        cy = cy + UI.text("  " .. line, cx, cy, 8, Theme.cream) + 2
      end
      if m.line then
        cy = cy + UI.text(("  line %d%s"):format(m.line, m.col and (":" .. m.col) or ""),
          cx, cy, 7, Theme.withAlpha(Theme.cream, 0.6)) + 2
      end
      cy = cy + 6
    end
    cy = cy + 4
  end

  if a.cases and #a.cases > 0 then
    cy = cy + UI.text("CASES", cx, cy, 9, Theme.withAlpha(Theme.cream, 0.7)) + 6
    for _, case in ipairs(a.cases) do
      local mark = case.passed and "PASS" or "FAIL"
      cy = cy + UI.text(("%s  %s%s"):format(mark, case.name,
        case.visible and "" or "  (hidden)"), cx, cy, 8,
        case.passed and Theme.admit or Theme.red) + 3
      if case.visible and not case.passed then
        for _, pair in ipairs({ { "want", case.expect }, { "got ", case.got } }) do
          if pair[2] then
            for _, line in ipairs(UI.wrap(pair[1] .. " " .. tostring(pair[2]):gsub("\n", "⏎"),
              indent, 7)) do
              cy = cy + UI.text("  " .. line, cx, cy, 7,
                Theme.withAlpha(Theme.cream, 0.8)) + 2
            end
          end
        end
      end
      cy = cy + 4
    end
  end

  if a.stderr and a.stderr ~= "" then
    cy = cy + 6
    cy = cy + UI.text("STDERR", cx, cy, 9, Theme.withAlpha(Theme.cream, 0.7)) + 6
    local font = Assets.mono(16)
    love.graphics.setFont(font)
    UI.setColor(Theme.withAlpha(Theme.cream, 0.85))
    for line in (a.stderr .. "\n"):gmatch("(.-)\n") do
      love.graphics.print(line, cx, cy)
      cy = cy + font:getHeight()
    end
    love.graphics.setColor(1, 1, 1, 1)
  end

  self.content_height = cy - (y + 12 - self.scroll)
  love.graphics.setScissor()

  UI.text(a.id or "", x + 10, vh - 48, 7, Theme.withAlpha(Theme.cream, 0.4))
  self.app:footer("ENTER retry   ESC map   ARROWS scroll")
end

function Result:keypressed(key)
  if key == "return" or key == "kpenter" then
    self.app:go("quest", { quest_id = self.attempt and self.attempt.quest_id or self.app.quest_id })
    return true
  end
  if key == "up" then self.scroll = math.max(0, self.scroll - 30); return true end
  if key == "down" then self.scroll = self.scroll + 30; return true end
  if key == "pageup" then self.scroll = math.max(0, self.scroll - 200); return true end
  if key == "pagedown" then self.scroll = self.scroll + 200; return true end
  return false
end

function Result:wheelmoved(_, dy)
  self.scroll = math.max(0, self.scroll - dy * 30)
end

return Result
