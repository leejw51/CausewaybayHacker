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
local I18n = require("src.i18n")
local Ease = require("src.ease")
local Anim = require("src.anim")
local Clock = require("src.clock")

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
  self.started = Anim.now()
  self.next_id = nil
  self:find_next()
end

--- Which node comes after this one, so NEXT has somewhere to go.
---
--- Asked of the server rather than remembered from the map: `world.map` is
--- what the map screen itself draws from, and the node after this one is a
--- fact about the pack, not about which screen the player came through. The
--- next node by number; the last node of a map has no NEXT and the button
--- says so by not being there.
function Result:find_next()
  local id = self.attempt and self.attempt.quest_id or self.app.quest_id
  local land, category = self.app.land, self.app.category
  if not id or not land or not category or not self.app.session then return end
  self.app.session:request("world.map",
    { land = land, category = category, locale = I18n.lang },
    function(ok, payload)
      if not ok or not payload or not payload.nodes then return end
      local nodes = {}
      for _, node in ipairs(payload.nodes) do nodes[#nodes + 1] = node end
      table.sort(nodes, function(a, b) return (a.node or 0) < (b.node or 0) end)
      for i, node in ipairs(nodes) do
        if node.quest_id == id then
          self.next_id = nodes[i + 1] and nodes[i + 1].quest_id or nil
          return
        end
      end
    end)
end

--- RETRY, NEXT and MAP — the three ways off this screen, each with its key
--- printed on it. NEXT is lit after an acceptance, RETRY after anything
--- else, and NEXT is absent on the last node of a map.
---
--- Laid into rows of `width`: at the largest type step three labels are
--- wider than a portrait panel, and a button that did not fit used to be a
--- button that was not drawn. The label size steps down to 7 first; what
--- still does not fit on one row starts another.
function Result:button_rows(width, accepted)
  local wanted = {
    { id = "retry", label = "RETRY  [ENTER]", state = accepted and "normal" or "hot",
      act = function() self:retry() end },
  }
  if self.next_id then
    wanted[#wanted + 1] = { id = "next", label = "NEXT  [N]",
      state = accepted and "hot" or "normal", act = function() self:next_quest() end }
  end
  wanted[#wanted + 1] = { id = "map", label = "MAP  [ESC]", state = "normal",
    act = function() self.app:back() end }

  local size = UI.CHIP_SIZE
  while size > 7 do
    local total = -10
    for _, b in ipairs(wanted) do total = total + UI.textWidth(b.label, size) + 28 + 10 end
    if total <= width then break end
    size = size - 1
  end
  local rows, row, used = {}, {}, 0
  for _, b in ipairs(wanted) do
    b.size = size
    b.w = math.min(width, UI.textWidth(b.label, size) + 28)
    if #row > 0 and used + 10 + b.w > width then
      rows[#rows + 1] = row
      row, used = {}, 0
    end
    row[#row + 1] = b
    used = used + (#row > 1 and 10 or 0) + b.w
  end
  if #row > 0 then rows[#rows + 1] = row end
  return rows
end

--- RETRY: the same quest again.
function Result:retry()
  self.app:go("quest", { quest_id = self.attempt and self.attempt.quest_id or self.app.quest_id })
end

--- NEXT: the node after this one, straight into its editor.
function Result:next_quest()
  if not self.next_id then return end
  self.app:go("quest", { quest_id = self.next_id })
end

--- Seconds since this verdict arrived.
function Result:age()
  return Anim.now() - (self.started or Anim.now())
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
    UI.text(I18n.t("no attempt"), 0, vh / 2, 12, Theme.dim, "center", vw)
    self.app:footer(I18n.t("ESC map"))
    return
  end

    local accepted = a.verdict == "accepted"
  -- A run should never reach this screen — `src/scenes/quest.lua` keeps them
  -- in place — but if one ever did, it must not be dressed as a verdict.
  -- §4.9b: a run is for the player, a submit is for the record.
  local is_run = a.mode == "run"
  local color = is_run and Theme.cyan or (Theme.verdict[a.verdict] or Theme.dim)

  -- The banner drops in (docs/art.md §7's clear sequence, in miniature), and
  -- a verdict that is not an acceptance shakes as it lands. Small: this is
  -- punctuation on a rejection, not a punishment, and the panel below it
  -- holds still so the compiler's words stay readable.
  local drop = Ease.expOut(math.min(1, self.t / 0.45))
  -- The banner is as tall as its own word plus air: a hard 56 held an 18 px
  -- label at the first type step and cut it at every step above.
  local banner_h = math.max(56, UI.lineHeight(18) + 20)
  -- It lands 16 px under the top edge, from fully above it.
  local by = -banner_h + drop * (banner_h + 16)
  local sx, sy = 0, 0
  if not accepted and not is_run then
    sx, sy = Anim.shake(self:age(), { duration = 0.34, amount = 5 })
  end
  love.graphics.push()
  love.graphics.translate(sx, sy)
  UI.setColor(color, 0.92)
  love.graphics.rectangle("fill", 0, by, vw, banner_h)
  UI.setColor(Theme.ink)
  love.graphics.setLineWidth(3)
  love.graphics.rectangle("line", 0, by, vw, banner_h)
  love.graphics.setColor(1, 1, 1, 1)
  UI.text(is_run and "SAMPLE RUN" or (VERDICT_LABEL[a.verdict] or a.verdict:upper()),
    0, by + math.floor((banner_h - UI.lineHeight(18)) / 2), 18, Theme.cream, "center", vw)
  love.graphics.pop()

  local pad = Layout.isPortrait() and 14 or 60
  local x = pad
  local y = by + banner_h + 20
  local w = vw - pad * 2
  -- Down to the footer, whatever the type step has made of its height, with
  -- one caption's worth of room under the panel for the attempt id.
  local foot = UI.footerHeight() + UI.lineHeight(7) + 12
  UI.panel(x, y, w, vh - y - foot, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = color })
  -- The buttons' rows, at the display controls' height, kept clear at the
  -- bottom of the panel: the verdict scrolls, the way on does not. Laid out
  -- first, because how many rows they need decides where the verdict ends.
  local bh = UI.chipHeight()
  local rows = self:button_rows(w - 24, accepted)
  local row_h = #rows * (bh + 8) + 12
  love.graphics.setScissor(x + 4, y + 4, w - 8, vh - y - foot - 8 - row_h)
  local cx = x + 16
  local cy = y + 12 - self.scroll
  local column = w - 32
  local indent = column - 16

  if self.quest then
    cy = cy + UI.text(self.quest.title or "", cx, cy, 12, Theme.coin) + 6
  end

  cy = cy + UI.text(("TESTS  %d / %d"):format(a.tests_passed or 0, a.tests_total or 0),
    cx, cy, 10, Theme.cream) + 6
  -- §4.8b: whether the submit beat the clock. Recorded, never enforced —
  -- the quest stayed open and a late clear still counts.
  local timing = Clock.verdict_note(a)
  if timing then
    cy = cy + UI.text(timing, cx, cy, 9,
      a.within_limit and Theme.admit or Theme.coin) + 6
  end

  cy = cy + UI.text(I18n.t("COMPILE %dms   RUN %dms   EXIT %s",
    a.compile_ms or 0, a.run_ms or 0,
    a.exit_code == nil and "-" or tostring(a.exit_code)), cx, cy, 8,
    Theme.withAlpha(Theme.cream, 0.75)) + 10

  -- SPEC §0: the node is stamped CLEARED, for good.
  if is_run then
    cy = cy + UI.text(I18n.t("a run never clears a node — SUBMIT does"), cx, cy, 8,
      Theme.withAlpha(Theme.cyan, 0.9)) + 10
  elseif a.cleared then
    UI.setColor(Theme.admit, 0.25)
    love.graphics.rectangle("fill", cx, cy, w - 32, 34)
    -- **The beat.** `Anim.stamp` returns nil for the first fifth of a second
    -- and then lands the word oversize and settles it. An instant stamp
    -- reads as a state change; a held one reads as a verdict, which is what
    -- it is.
    local stamp_scale, stamp_alpha = Anim.stamp(self:age(), { hold = 0.26 })
    if stamp_scale then
      local label = "CLEARED"
      local font_size = 12
      local lw = UI.textWidth(label, font_size)
      love.graphics.push()
      love.graphics.translate(cx + 10 + lw / 2, cy + 17)
      love.graphics.scale(stamp_scale, stamp_scale)
      UI.text(label, -lw / 2, -7, font_size, Theme.withAlpha(Theme.admit, stamp_alpha))
      love.graphics.pop()
      if stamp_scale <= 1.2 then
        UI.stars(cx + w - 32 - 3 * 15, cy + 9, a.stars or 0, 12)
      end
    end
    cy = cy + 42
  elseif accepted then
    cy = cy + UI.text(I18n.t("already cleared — stars keep the best run"), cx, cy, 8,
      Theme.withAlpha(Theme.cream, 0.7)) + 10
  end

  if a.mistakes and #a.mistakes > 0 then
    cy = cy + UI.text(I18n.t("WHAT WENT WRONG"), cx, cy, 9, Theme.red) + 6
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
    cy = cy + UI.text(I18n.t("CASES"), cx, cy, 9, Theme.withAlpha(Theme.cream, 0.7)) + 6
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
    cy = cy + UI.text(I18n.t("STDERR"), cx, cy, 9, Theme.withAlpha(Theme.cream, 0.7)) + 6
    local font = Assets.mono(Layout.codeSize(16))
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

  self.buttons = {}
  local by = vh - foot - 10 - #rows * (bh + 8) + 8
  for _, row in ipairs(rows) do
    local bx = x + 12
    for _, b in ipairs(row) do
      UI.button(bx, by, b.w, bh, b.label, b.state, b.size)
      self.buttons[#self.buttons + 1] =
        { id = b.id, x = bx, y = by, w = b.w, h = bh, act = b.act }
      bx = bx + b.w + 10
    end
    by = by + bh + 8
  end

  UI.text(a.id or "", x + 10, vh - foot + 6, 7, Theme.withAlpha(Theme.cream, 0.4))
  self.app:footer(I18n.t("ENTER retry   N next   ESC map   ARROWS scroll"))
end

function Result:keypressed(key)
  if key == "return" or key == "kpenter" then
    self:retry()
    return true
  end
  if key == "n" then
    self:next_quest()
    return true
  end
  if key == "m" then
    self.app:back()
    return true
  end
  if key == "up" then self.scroll = math.max(0, self.scroll - 30); return true end
  if key == "down" then self.scroll = self.scroll + 30; return true end
  if key == "pageup" then self.scroll = math.max(0, self.scroll - 200); return true end
  if key == "pagedown" then self.scroll = self.scroll + 200; return true end
  return false
end

function Result:mousepressed(x, y)
  for _, b in ipairs(self.buttons or {}) do
    if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
      b.act()
      return
    end
  end
end

function Result:wheelmoved(_, dy)
  self.scroll = math.max(0, self.scroll - dy * 30)
end

return Result
