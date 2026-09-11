-- AI MODE (SPEC §7.3). A drill built from your own mistakes.
--
-- `ai.plan` with `repeat | weakness | spaced`, then `ai.next` walking a fixed
-- ordered plan, then `ai.finish`. No external model is involved in any of it:
-- every plan is a query against the tables SPEC §7 builds from the player's
-- own record.
--
-- ## `why` is the whole screen
--
-- §4.16: `ai.next` returns a one-line explanation of why this quest is next —
-- "you hit borrow-after-move 6 times" — generated from the mistake tables and
-- not from a language model. That sentence is the difference between a coach
-- and a shuffle, so it is drawn as the largest thing on the screen and the
-- quest is drawn under it. A drill that showed the quest and hid the reason
-- would be a playlist.
--
-- ## While it does not exist
--
-- The server answers `unavailable` with `detail.milestone`. §3.3: that is
-- **not** `internal` — the screen says which chapter and offers no retry. The
-- three modes are still drawn and still describe themselves, because "what
-- will this do" is a question somebody can usefully have answered before the
-- thing exists.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local SFX = require("src.sfx")
local errors = require("src.net.errors")

local Ai = {}
Ai.__index = Ai

local MODES = { "weakness", "repeat", "spaced" }

--- What each plan actually does, in SPEC §7.3's own terms. Shown whether or
--- not the endpoint exists: a player choosing a drill deserves to know what
--- it will pick before it picks it.
local MODE_TEXT = {
  weakness = {
    title = "WEAKNESS",
    blurb = "Groups your mistakes by kind, takes the ones you keep making, "
      .. "and finds five different shapes of the same problem — including "
      .. "quests you have already cleared. This is the one that teaches.",
  },
  ["repeat"] = {
    title = "REPEAT",
    blurb = "The quests you failed most, hardest first. The plain 'do it "
      .. "again until it sticks'.",
  },
  spaced = {
    title = "SPACED",
    blurb = "Cleared quests due for review. Three stars comes back in two "
      .. "weeks, one star in two days.",
  },
}

function Ai.new(app)
  return setmetatable({
    app = app,
    cursor = 1,
    drill = nil,
    quest = nil,
    why = nil,
    position = nil,
    total = nil,
    summary = nil,
    busy = false,
    unavailable = nil,
    error = nil,
    -- Whether the player has any history for a drill to be built from.
    mistakes = nil,
  }, Ai)
end

function Ai:enter()
  -- A drill over an empty record is an empty drill, and saying so before the
  -- player picks a mode is better than after.
  self.app.session:request("stats.mistakes", { limit = 5 }, function(ok, payload)
    if ok then self.mistakes = payload.mistakes or {} end
  end)
end

function Ai:mode()
  return MODES[self.cursor]
end

function Ai:plan()
  if self.busy then return end
  self.busy = true
  self.error = nil
  SFX.play("select")
  self.app.session:request("ai.plan", {
    mode = self:mode(), land = self.app.land or "rust", size = 5,
  }, function(ok, payload, why)
    self.busy = false
    if not ok then
      if payload.code == "unavailable" then
        self.unavailable = { message = payload.message, milestone = errors.milestone(payload) }
      else
        self.error = why.player
      end
      return
    end
    self.unavailable = nil
    self.drill = payload.drill
    self.summary = nil
    self:next()
  end)
end

function Ai:next()
  if not self.drill or self.busy then return end
  self.busy = true
  self.app.session:request("ai.next", { drill_id = self.drill.id },
    function(ok, payload, why)
      self.busy = false
      if not ok then
        if payload.code == "not_found" then
          -- §4.16: past the end. That is not a failure, it is the end.
          self:finish()
        else
          self.error = why.player
        end
        return
      end
      self.quest = payload.quest
      self.why = payload.why
      self.position = payload.position
      self.total = payload.total
    end)
end

function Ai:finish()
  if not self.drill then return end
  self.app.session:request("ai.finish", { drill_id = self.drill.id },
    function(ok, payload)
      if ok then self.summary = payload.summary end
      self.drill = nil
      self.quest = nil
      self.why = nil
    end)
end

function Ai:play()
  if not self.quest then return end
  SFX.play("select")
  self.app.quest_id = self.quest.id
  self.app.land = self.quest.land or self.app.land
  self.app.category = self.quest.category or self.app.category
  self.app:go("quest", {
    quest_id = self.quest.id,
    land = self.app.land,
    category = self.app.category,
  })
end

-- ------------------------------------------------------------------ drawing

function Ai:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_datacentre", "bg_flat"), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.8)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local s = Layout.uiScale()
  local pad = Layout.isPortrait() and 12 or 46
  local w = vw - pad * 2

  UI.setColor(Theme.ink, 0.9)
  love.graphics.rectangle("fill", 0, 0, vw, 44)
  love.graphics.setColor(1, 1, 1, 1)
  UI.text("AI MODE", 12, 10, math.floor(15 * s), Theme.cyan)
  -- Measured rather than guessed at: the title's width changes with
  -- `uiScale`, and a fixed offset had the subtitle sitting on top of it.
  local caption = "built from your own record, not from a language model"
  local cx = 12 + UI.textWidth("AI MODE", math.floor(15 * s)) + 16
  if cx + UI.textWidth(caption, 7) < vw - 12 then
    UI.text(caption, cx, 18, 7, Theme.withAlpha(Theme.cream, 0.45))
  end

  local y = 54
  y = self:draw_modes(pad, y, w) + 10

  if self.drill and self.quest then
    self:draw_step(pad, y, w, vh - y - 40)
  elseif self.summary then
    self:draw_summary(pad, y, w, vh - y - 40)
  else
    self:draw_idle(pad, y, w, vh - y - 40)
  end

  self.app:footer("ARROWS mode   ENTER start   N next   F finish   ESC back")
end

function Ai:draw_modes(x, y, w)
  local h = 74
  local cw = (w - 16) / #MODES
  self.mode_rects = {}
  for i, mode in ipairs(MODES) do
    local mx = x + (i - 1) * (cw + 8)
    local on = i == self.cursor
    UI.panel(mx, y, cw, h, {
      fill = Theme.withAlpha(on and Theme.navy or Theme.ink, 0.92),
      tint = on and Theme.coin or Theme.cyan,
    })
    local text = MODE_TEXT[mode]
    UI.text(text.title, mx + 10, y + 8, 11, on and Theme.coin or Theme.cream)
    local lines = UI.wrap(text.blurb, cw - 20, 7)
    for j = 1, math.min(4, #lines) do
      UI.text(lines[j], mx + 10, y + 26 + (j - 1) * 10, 7,
        Theme.withAlpha(Theme.cream, on and 0.85 or 0.5))
    end
    self.mode_rects[i] = { x = mx, y = y, w = cw, h = h }
  end
  return y + h
end

function Ai:draw_idle(x, y, w, h)
  UI.panel(x, y, w, h, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.cyan })
  local cy = y + 16

  if self.unavailable then
    UI.text("NOT BUILT YET", x + 16, cy, 10, Theme.coin)
    cy = cy + 18
    local said = self.unavailable.milestone
      and ("A drill picked from your own mistakes, and a line saying why. It "
        .. "opens in chapter " .. self.unavailable.milestone .. ".")
      or "A drill picked from your own mistakes. Not in this build."
    for _, line in ipairs(UI.wrap(said, w - 40, 8)) do
      cy = cy + UI.text(line, x + 16, cy, 8, Theme.cream) + 4
    end
    cy = cy + 8
    for _, line in ipairs(UI.wrap(
      "The plan will be a fixed ordered list, so a reconnect resumes the same "
        .. "session rather than reshuffling it — and every step will say why "
        .. "it was chosen.", w - 40, 7)) do
      cy = cy + UI.text(line, x + 16, cy, 7, Theme.withAlpha(Theme.cream, 0.55)) + 3
    end
    if self.unavailable.message then
      UI.text(self.unavailable.message, x + 16, y + h - 18, 7,
        Theme.withAlpha(Theme.cream, 0.35))
    end
    return
  end

  if self.error then
    UI.text(self.error, x + 16, cy, 9, Theme.red)
    return
  end

  -- Somebody with no history. A drill over an empty record is an empty drill,
  -- and the useful thing is to say what fills it.
  if self.mistakes and #self.mistakes == 0 then
    UI.text("NOTHING TO DRILL YET", x + 16, cy, 10, Theme.withAlpha(Theme.cream, 0.8))
    cy = cy + 18
    for _, line in ipairs(UI.wrap(
      "This builds a session out of the mistakes you have actually made, so "
        .. "it needs you to have made some. Play a few streets — the errors "
        .. "get classified as they happen — and come back.", w - 40, 8)) do
      cy = cy + UI.text(line, x + 16, cy, 8, Theme.withAlpha(Theme.cream, 0.7)) + 4
    end
    return
  end

  if self.mistakes and #self.mistakes > 0 then
    UI.text("READY", x + 16, cy, 10, Theme.admit)
    cy = cy + 18
    local top = self.mistakes[1]
    for _, line in ipairs(UI.wrap(
      ("Your most frequent is %s, %d times. Press ENTER and this will find "
        .. "different shapes of it."):format(tostring(top.kind), top.count or 0),
      w - 40, 8)) do
      cy = cy + UI.text(line, x + 16, cy, 8, Theme.cream) + 4
    end
    return
  end

  UI.text("asking the server…", x + 16, cy, 8, Theme.withAlpha(Theme.cream, 0.6))
end

--- One step of a drill. The **reason** is the headline; the quest is under it.
function Ai:draw_step(x, y, w, h)
  UI.panel(x, y, w, h, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.coin })
  local cy = y + 14

  local position = ("%d of %d"):format(self.position or 1, self.total or 1)
  UI.text(position, x + w - 16 - UI.textWidth(position, 8), cy, 8,
    Theme.withAlpha(Theme.cream, 0.6))
  UI.bar(x + 16, y + h - 22, w - 32, 7,
    (self.total or 1) > 0 and (self.position or 1) / self.total or 0, Theme.coin)

  -- The line that makes this a coach rather than a shuffle (§4.16). Largest
  -- thing on the screen, on purpose.
  if self.why and self.why ~= "" then
    for _, line in ipairs(UI.wrap(self.why, w - 40, 11)) do
      cy = cy + UI.text(line, x + 16, cy, 11, Theme.coin) + 6
    end
    cy = cy + 8
  end

  UI.text(tostring(self.quest.title or self.quest.id), x + 16, cy, 10, Theme.cream)
  cy = cy + 16
  UI.text(tostring(self.quest.id), x + 16, cy, 7, Theme.withAlpha(Theme.cream, 0.45))
  cy = cy + 14
  if self.quest.concepts and #self.quest.concepts > 0 then
    UI.text(table.concat(self.quest.concepts, ", "), x + 16, cy, 7,
      Theme.withAlpha(Theme.cyan, 0.85))
    cy = cy + 16
  end

  UI.button(x + 16, y + h - 60, 150, 28, "PLAY  [ENTER]", "hot", 9)
  self.play_rect = { x = x + 16, y = y + h - 60, w = 150, h = 28 }
  UI.button(x + 176, y + h - 60, 110, 28, "SKIP  [N]", "normal", 9)
  self.next_rect = { x = x + 176, y = y + h - 60, w = 110, h = 28 }
end

function Ai:draw_summary(x, y, w, h)
  UI.panel(x, y, w, h, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.admit })
  local cy = y + 16
  UI.text("DRILL FINISHED", x + 16, cy, 11, Theme.admit)
  cy = cy + 22
  local sm = self.summary
  UI.text(("attempted %d   cleared %d"):format(sm.attempted or 0, sm.cleared or 0),
    x + 16, cy, 9, Theme.cream)
  cy = cy + 18
  if sm.kinds_improved and #sm.kinds_improved > 0 then
    UI.text("improved: " .. table.concat(sm.kinds_improved, ", "), x + 16, cy, 8,
      Theme.withAlpha(Theme.cyan, 0.9))
  end
end

-- -------------------------------------------------------------------- input

function Ai:keypressed(key)
  if key == "left" or key == "up" then
    self.cursor = ((self.cursor - 2) % #MODES) + 1; SFX.play("move"); return true
  end
  if key == "right" or key == "down" then
    self.cursor = (self.cursor % #MODES) + 1; SFX.play("move"); return true
  end
  if key == "return" or key == "kpenter" then
    if self.quest then self:play() else self:plan() end
    return true
  end
  if key == "n" and self.drill then self:next(); return true end
  if key == "f" and self.drill then self:finish(); return true end
  return false
end

function Ai:mousepressed(x, y)
  local function inside(r)
    return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
  end
  for i, rect in pairs(self.mode_rects or {}) do
    if inside(rect) then
      if self.cursor ~= i then self.cursor = i; SFX.play("move") else self:plan() end
      return
    end
  end
  if inside(self.play_rect) then self:play(); return end
  if inside(self.next_rect) then self:next(); return end
end

return Ai
