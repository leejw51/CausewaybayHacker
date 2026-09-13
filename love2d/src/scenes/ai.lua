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
local I18n = require("src.i18n")
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
  -- §4.16: the same `locale` as quest.get, since this opens the same screen.
  self.app.session:request("ai.next", { drill_id = self.drill.id, locale = I18n.lang },
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

    local pad = Layout.isPortrait() and 12 or 46
  local w = vw - pad * 2

  UI.setColor(Theme.ink, 0.9)
  love.graphics.rectangle("fill", 0, 0, vw, 44)
  love.graphics.setColor(1, 1, 1, 1)
  UI.text(I18n.t("AI MODE"), 12, 10, 15, Theme.cyan)
  -- Measured rather than guessed at: the title's width changes with
  -- `uiScale`, and a fixed offset had the subtitle sitting on top of it.
  local caption = I18n.t("built from your own record, not from a language model")
  local cx = 12 + UI.textWidth("AI MODE", 15) + 16
  if cx + UI.textWidth(caption, 7) < vw - 12 then
    UI.text(caption, cx, 18, 7, Theme.withAlpha(Theme.cream, 0.45))
  end

  local y = 54
  y = self:draw_modes(pad, y, w) + 10

  if self.drill and self.quest then
    self:draw_step(pad, y, w, vh - y - UI.footerHeight() - 8)
  elseif self.summary then
    self:draw_summary(pad, y, w, vh - y - UI.footerHeight() - 8)
  else
    self:draw_idle(pad, y, w, vh - y - UI.footerHeight() - 8)
  end

  self.app:footer(I18n.t("ARROWS mode   ENTER start   N next   F finish   ESC back"))
end

--- The three plans, each with DESIGN's emblem for it.
---
--- **Stacked, in both orientations.** Three cards side by side left 226
--- pixels each in portrait, and a paragraph saying what a plan actually
--- selects does not fit in 206 of them — it wrapped to four lines and then
--- clipped, so the screen explained two of the three modes and cut the third
--- off mid-sentence. Full-width rows also make this screen look like the
--- lands and category screens, which are the same idea: a row, a picture, a
--- choice.
---
--- The emblems (`emblem_ai_weakness`, `_repeat`, `_spaced`) are 384x128 —
--- the same 3:1 as the category bands — so they are drawn the way
--- `categories.lua` worked out: at their own aspect, as tall as the row,
--- anchored **right** with a short fade on its left edge, and the words kept
--- in their own gutter beside it rather than on top of it.
function Ai:draw_modes(x, y, w)
  -- Measured from the type, and tall enough for two lines of blurb. The
  -- fixed 76 was right for an 11 px title over 7 px body; at twice that the
  -- title sat on the first line of the blurb and the blurb sat on the row
  -- below it.
  local title_h, body_h = UI.lineHeight(11), UI.lineHeight(7)
  local h = 8 + title_h + 6 + body_h * 2 + 8
  local gap = 8
  self.mode_rects = {}
  for i, mode in ipairs(MODES) do
    local my = y + (i - 1) * (h + gap)
    local on = i == self.cursor
    UI.panel(x, my, w, h, {
      fill = Theme.withAlpha(on and Theme.navy or Theme.ink, 0.92),
      tint = on and Theme.coin or Theme.cyan,
    })

    -- The band first, so the words land on top of its fade and not under it.
    local text_w = w - 20
    local image = Assets.image("emblem_ai_" .. mode)
    if image then
      local iw, ih = image:getDimensions()
      local es = (h - 8) / ih
      local ew = iw * es
      -- Only when the words and the picture both fit. A band squeezed into
      -- whatever is left over is not the picture DESIGN drew.
      if w - ew >= 230 then
        local ex = x + w - ew - 4
        love.graphics.setScissor(x + 4, my + 4, w - 8, h - 8)
        love.graphics.setColor(1, 1, 1, on and 1 or 0.7)
        love.graphics.draw(image, ex, my + 4, 0, es, es)
        -- **No left-edge fade here**, unlike `categories.lua`. That fade
        -- exists to hide a hard cut, and these three emblems have 20 to 50
        -- pixels of their own transparent margin before the ink starts
        -- (`minx` 21, 48 and 31 of 384, in the manifest) — so there is no cut
        -- to hide, and a strip of panel colour painted over empty canvas was
        -- a visibly darker bar with a hard edge of its own. Looked at, not
        -- assumed from the sibling screen.
        love.graphics.setScissor()
        love.graphics.setColor(1, 1, 1, 1)
        text_w = w - ew - 30
      end
    end

    UI.text(I18n.t(MODE_TEXT[mode].title), x + 10, my + 8, 11,
      on and Theme.coin or Theme.cream)
    local lines = UI.wrap(I18n.t(MODE_TEXT[mode].blurb), text_w, 7)
    local body_top = my + 8 + title_h + 6
    local room = math.max(1, math.floor((my + h - 8 - body_top) / body_h))
    for j = 1, math.min(room, #lines) do
      UI.text(lines[j], x + 10, body_top + (j - 1) * body_h, 7,
        Theme.withAlpha(Theme.cream, on and 0.85 or 0.5))
    end
    self.mode_rects[i] = { x = x, y = my, w = w, h = h }
  end
  return y + #MODES * (h + gap) - gap
end

function Ai:draw_idle(x, y, w, h)
  UI.panel(x, y, w, h, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.cyan })
  local cy = y + 16

  if self.unavailable then
    -- Advanced by the line's own height: `18` was written against a 10 px
    -- heading, and at the doubled ladder the paragraph printed through it.
    cy = cy + UI.text(I18n.t("NOT BUILT YET"), x + 16, cy, 10, Theme.coin) + 6
    local said = self.unavailable.milestone
      and I18n.t("A drill picked from your own mistakes, and a line saying "
        .. "why. It opens in chapter %s.", tostring(self.unavailable.milestone))
      or I18n.t("A drill picked from your own mistakes. Not in this build.")
    for _, line in ipairs(UI.wrap(said, w - 40, 8)) do
      cy = cy + UI.text(line, x + 16, cy, 8, Theme.cream) + 4
    end
    cy = cy + 8
    for _, line in ipairs(UI.wrap(
      I18n.t("The plan will be a fixed ordered list, so a reconnect resumes "
        .. "the same session rather than reshuffling it — and every step will "
        .. "say why it was chosen."), w - 40, 7)) do
      cy = cy + UI.text(line, x + 16, cy, 7, Theme.withAlpha(Theme.cream, 0.55)) + 3
    end
    if self.unavailable.message then
      UI.text(self.unavailable.message, x + 16, y + h - 10 - UI.lineHeight(7), 7,
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
    cy = cy + UI.text(I18n.t("NOTHING TO DRILL YET"), x + 16, cy, 10,
      Theme.withAlpha(Theme.cream, 0.8)) + 6
    for _, line in ipairs(UI.wrap(
      I18n.t("This builds a session out of the mistakes you have actually "
        .. "made, so it needs you to have made some. Play a few streets — the "
        .. "errors get classified as they happen — and come back."),
      w - 40, 8)) do
      cy = cy + UI.text(line, x + 16, cy, 8, Theme.withAlpha(Theme.cream, 0.7)) + 4
    end
    return
  end

  if self.mistakes and #self.mistakes > 0 then
    cy = cy + UI.text(I18n.t("READY"), x + 16, cy, 10, Theme.admit) + 6
    local top = self.mistakes[1]
    for _, line in ipairs(UI.wrap(
      I18n.t("Your most frequent is %s, %d times. Press ENTER and this will "
        .. "find different shapes of it.", tostring(top.kind), top.count or 0),
      w - 40, 8)) do
      cy = cy + UI.text(line, x + 16, cy, 8, Theme.cream) + 4
    end
    return
  end

  UI.text(I18n.t("asking the server…"), x + 16, cy, 8, Theme.withAlpha(Theme.cream, 0.6))
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

  cy = cy + UI.text(tostring(self.quest.title or self.quest.id), x + 16, cy, 10, Theme.cream) + 4
  cy = cy + UI.text(tostring(self.quest.id), x + 16, cy, 7, Theme.withAlpha(Theme.cream, 0.45)) + 4
  if self.quest.concepts and #self.quest.concepts > 0 then
    cy = cy + UI.text(table.concat(self.quest.concepts, ", "), x + 16, cy, 7,
      Theme.withAlpha(Theme.cyan, 0.85)) + 6
  end

  -- Sized from their labels and set at the display controls' height, so
  -- they are still buttons — and still legible — at every type step.
  local bh = UI.chipHeight()
  local by = y + h - 32 - bh
  local pw = UI.textWidth("PLAY  [ENTER]", UI.CHIP_SIZE) + 28
  local sw = UI.textWidth("SKIP  [N]", UI.CHIP_SIZE) + 28
  UI.button(x + 16, by, pw, bh, "PLAY  [ENTER]", "hot", UI.CHIP_SIZE)
  self.play_rect = { x = x + 16, y = by, w = pw, h = bh }
  UI.button(x + 16 + pw + 10, by, sw, bh, "SKIP  [N]", "normal", UI.CHIP_SIZE)
  self.next_rect = { x = x + 16 + pw + 10, y = by, w = sw, h = bh }
end

function Ai:draw_summary(x, y, w, h)
  UI.panel(x, y, w, h, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.admit })
  local cy = y + 16
  cy = cy + UI.text(I18n.t("DRILL FINISHED"), x + 16, cy, 11, Theme.admit) + 8
  local sm = self.summary
  cy = cy + UI.text(I18n.t("attempted %d   cleared %d", sm.attempted or 0, sm.cleared or 0),
    x + 16, cy, 9, Theme.cream) + 6
  if sm.kinds_improved and #sm.kinds_improved > 0 then
    UI.text(I18n.t("improved: ") .. table.concat(sm.kinds_improved, ", "), x + 16, cy, 8,
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
