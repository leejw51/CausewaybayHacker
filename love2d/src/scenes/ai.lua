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
-- ## The look (`docs/love2d-ui.md`)
--
-- Three mode cards, full width, each with DESIGN's emblem at the right at
-- its own aspect, the name in title-32 and what the plan selects in the
-- reading face, two lines ending in "…". The chosen one lifts, wears the
-- gold edge and sways under the pointer; the others sit. Under them one
-- content-sized card: READY, the step with its reason as the headline, or
-- the summary. Nothing here moves with F12 but the paragraphs.
--
-- ## While it does not exist
--
-- A server built without the drills answers `unavailable` with
-- `detail.milestone`. §3.3: that is **not** `internal` — the screen says
-- which chapter and offers no retry. The three modes are still drawn and
-- still describe themselves, because "what will this do" is a question
-- somebody can usefully have answered before the thing exists.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Anim = require("src.anim")
local Juice = require("src.juice")
local Fx = require("src.fx")
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
    hover = nil,
    header_h = UI.headerHeight(),
  }, Ai)
end

function Ai:enter()
  Juice.forget("ai:")
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
  UI.press("ai:mode" .. self.cursor, self.mode_rects and self.mode_rects[self.cursor], { sfx = false })
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
      Juice.forget("ai:step")
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
  UI.press("ai:play", self.play_rect, { sfx = false })
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

local function pad()
  return Layout.isPortrait() and Theme.space.lg or Theme.space.xl
end

--- A band of art at its own aspect, as tall as `h`, anchored to `right`,
--- with a short fade on its left edge into `fill`. Returns its left edge.
local function band(name, right, y, h, fill, alpha)
  local image = Assets.image(name)
  if not image then return right end
  local iw, ih = image:getDimensions()
  local s = h / ih
  local ew = iw * s
  local ex = right - ew
  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.draw(image, ex, y, 0, s, s)
  local steps = 14
  local fw = math.min(52, ew * 0.35)
  for k = 0, steps - 1 do
    UI.setColor(fill, alpha * (0.95 - k * (0.95 / steps)))
    love.graphics.rectangle("fill", ex + k * (fw / steps), y, fw / steps + 1, h)
  end
  love.graphics.setColor(1, 1, 1, 1)
  return ex
end

function Ai:draw_header()
  local vw = Layout.vw
  local h = self.header_h
  local g = Layout.gutter()
  UI.card(0, 0, vw, h, { variant = "bar", pad = 0 })
  UI.setColor(Theme.edge, 0.6)
  love.graphics.rectangle("fill", 0, h - 2, vw, 2)
  love.graphics.setColor(1, 1, 1, 1)
  local back = "‹ " .. I18n.t("BACK")
  local bw, bh = UI.buttonSize(back)
  bh = math.max(Theme.control.buttonM, bh)
  self.back_rect = { x = g, y = math.floor((h - bh) / 2), w = bw, h = bh }
  UI.button(self.back_rect.x, self.back_rect.y, bw, bh, back,
    self.hover == "back" and "hot" or "normal", nil, { variant = "ghost", id = "ai:back" })
  local x = g + bw + Theme.space.lg
  local title = I18n.t("AI MODE")
  UI.label(title, x, math.floor((h - UI.lead("title")) / 2), "title")
  x = x + UI.labelWidth(title, "title") + Theme.space.lg
  -- Measured rather than guessed at: the caption is drawn only where it fits
  -- after the title.
  local note = I18n.t("built from your own record, not from a language model")
  if x + UI.labelWidth(note, "label") <= vw - g then
    UI.label(note, x, math.floor((h - UI.lead("label")) / 2), "label", { color = Theme.mute })
  end
end

function Ai:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_datacentre", "bg_flat"), 0, 0, vw, vh)
  UI.setColor(Theme.felt, Layout.isPortrait() and 0.8 or 0.72)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)
  Fx.ambient("neon", vw, vh)
  Fx.drawAmbient()

  local x, y, w, h = UI.bounded(nil, self.header_h + Theme.space.lg, vh - UI.footerHeight() - Theme.space.lg)
  local after = self:draw_modes(x, y, w, h) + Theme.gap
  local room = y + h - after
  -- The card under the modes measures itself as it draws; the modes read
  -- that height next frame and give way to it (a step's reason can be
  -- three lines of title). One frame late, which is within the deal-in.
  if self.drill and self.quest then
    self.panel_h = self:draw_step(x, after, w, room)
  elseif self.summary then
    self.panel_h = self:draw_summary(x, after, w, room)
  else
    self.panel_h = self:draw_idle(x, after, w, room)
  end

  self:draw_header()
  self.app:footer(I18n.t("ARROWS mode   ENTER start   N next   F finish   ESC back"))
end

--- The least the card under the mode cards is ever given; past that the
--- modes go compact (their names alone).
Ai.MIN_PANEL = 160

--- The three plans, each with DESIGN's emblem for it, as cards.
function Ai:draw_modes(x, y, w, room)
  local portrait = Layout.isPortrait()
  local p = pad()
  local gap = Theme.rowGap
  local _, read_lead = UI.readHeight("x", 100)
  -- Two lines of blurb; one when the three would not leave the card under
  -- them room; the names alone when even that would not.
  local need = math.max(Ai.MIN_PANEL, self.panel_h or 0)
  local function fits(h) return #MODES * (h + gap) - gap + Theme.gap + need <= room end
  local lines = 2
  local h = Theme.space.lg + UI.lead("title") + Theme.space.xs + read_lead * 2 + Theme.space.lg
  if portrait then h = math.max(120, h) else h = math.max(96, h) end
  if not fits(h) then
    lines = 1
    h = Theme.space.lg + UI.lead("title") + Theme.space.xs + read_lead + Theme.space.lg
  end
  local compact = not fits(h)
  if compact then h = Theme.space.sm + UI.lead("title") + Theme.space.sm end
  self.mode_rects = {}
  local t = Anim.now()
  for i, mode in ipairs(MODES) do
    local my = y + (i - 1) * (h + gap)
    local r = { x = x, y = my, w = w, h = h }
    self.mode_rects[i] = r
    local on = i == self.cursor
    local k = Juice.enter("ai:mode" .. i, { dur = Theme.motion.enter, delay = Juice.stagger(i, Theme.motion.stagger) })
    local a = Juice.follow("ai:hot" .. i, (on or self.hover == i) and 1 or 0, { speed = 18 })
    local press = Juice.pressed("press:ai:mode" .. i)
    local alpha = math.min(1, k * 1.5)
    local cy = my + (1 - k) * 24 - 6 * a + 4 * press
    local cx, cyc = x + w / 2, cy + h / 2
    local sway = (on and a > 0.01) and math.sin(t * math.pi * 2 * Theme.motion.sway + i) * 0.6 * a * math.pi / 180 or 0
    love.graphics.push()
    love.graphics.translate(cx, cyc)
    love.graphics.rotate(sway)
    love.graphics.scale(1 + 0.01 * a, 1 + 0.01 * a)
    love.graphics.translate(-cx, -cyc)
    UI.card(x, cy, w, h, { hot = a, selected = on, alpha = alpha, pad = 0, shadowDy = Theme.shadowDy - 5 * press })
    local fill = Theme.mix(Theme.card, Theme.cardHi, a)

    -- The band first, so the words land on top of its fade and not under it.
    -- Only when the words and the picture both fit: a band squeezed into
    -- whatever is left over is not the picture DESIGN drew.
    local art_left = x + w - Theme.space.xs
    local image = Assets.image("emblem_ai_" .. mode)
    if image and not compact then
      local iw, ih = image:getDimensions()
      local ew = iw * ((h - Theme.space.sm) / ih)
      if w - ew >= 360 then
        art_left = band("emblem_ai_" .. mode, x + w - Theme.space.xs, cy + Theme.space.xs, h - Theme.space.sm, fill, alpha * (on and 1 or 0.8))
      end
    end
    local tx = x + p
    local tw = art_left - Theme.space.md - tx
    local ty = compact and (cy + Theme.space.sm) or (cy + Theme.space.lg)
    UI.label(I18n.t(MODE_TEXT[mode].title), tx, ty, "title", { color = on and Theme.gold or Theme.text, width = tw, ellipsis = true, alpha = alpha })
    if not compact then
      UI.read(I18n.t(MODE_TEXT[mode].blurb), tx, ty + UI.lead("title") + Theme.space.xs, tw,
        { maxLines = lines, color = on and Theme.text or Theme.mute, alpha = alpha })
    end
    love.graphics.pop()
  end
  return y + #MODES * (h + gap) - gap
end

--- A content-sized card: a strip, a heading in the title role, paragraphs
--- in the reading face. Returns its height.
local function note_card(x, y, w, title, color, paras, opts)
  opts = opts or {}
  local p = pad()
  local inner = w - p * 2
  local h = Theme.stripH + p + UI.lead("title") + Theme.space.sm
  for _, para in ipairs(paras) do h = h + UI.readHeight(para.text, inner) + Theme.space.sm end
  h = h + p - Theme.space.sm
  local k = Juice.enter("ai:panel", { dur = Theme.motion.enter, delay = 0.16 })
  local alpha = math.min(1, k * 1.5)
  local cy = y + (1 - k) * 24
  UI.card(x, cy, w, h, { strip = color, pad = 0, alpha = alpha })
  local ty = cy + Theme.stripH + p
  UI.label(title, x + p, ty, "title", { color = color, width = inner, ellipsis = true, alpha = alpha })
  ty = ty + UI.lead("title") + Theme.space.sm
  for _, para in ipairs(paras) do
    ty = ty + UI.read(para.text, x + p, ty, inner, { color = para.color, alpha = alpha }) + Theme.space.sm
  end
  return h
end

function Ai:draw_idle(x, y, w, h)
  if self.unavailable then
    -- §3.3: real, but not built yet. Said in the story's voice, with no retry
    -- offered.
    local said = self.unavailable.milestone
      and I18n.t("A drill picked from your own mistakes, and a line saying "
        .. "why. It opens in chapter %s.", tostring(self.unavailable.milestone))
      or I18n.t("A drill picked from your own mistakes. Not in this build.")
    local paras = {
      { text = said },
      { text = I18n.t("The plan will be a fixed ordered list, so a reconnect resumes "
        .. "the same session rather than reshuffling it — and every step will "
        .. "say why it was chosen."), color = Theme.mute },
    }
    if self.unavailable.message then paras[#paras + 1] = { text = self.unavailable.message, color = Theme.mute } end
    return note_card(x, y, w, I18n.t("NOT BUILT YET"), Theme.gold, paras)
  end
  if self.error then
    return note_card(x, y, w, "!", Theme.redA, { { text = self.error } })
  end
  -- Somebody with no history. A drill over an empty record is an empty drill,
  -- and the useful thing is to say what fills it.
  if self.mistakes and #self.mistakes == 0 then
    return note_card(x, y, w, I18n.t("NOTHING TO DRILL YET"), Theme.gold, {
      { text = I18n.t("This builds a session out of the mistakes you have actually "
        .. "made, so it needs you to have made some. Play a few streets — the "
        .. "errors get classified as they happen — and come back.") },
    })
  end
  if self.mistakes and #self.mistakes > 0 then
    local top = self.mistakes[1]
    return note_card(x, y, w, I18n.t("READY"), Theme.green, {
      { text = I18n.t("Your most frequent is %s, %d times. Press ENTER and this will "
        .. "find different shapes of it.", tostring(top.kind), top.count or 0) },
    })
  end
  return UI.label(I18n.t("asking the server…"), x, y, "label", { color = Theme.mute, width = w, align = "center" })
end

--- One step of a drill. The **reason** is the headline; the quest is under it.
function Ai:draw_step(x, y, w, h)
  local p = pad()
  local inner = w - p * 2
  local k = Juice.enter("ai:step", { dur = Theme.motion.enter })
  local alpha = math.min(1, k * 1.5)
  local font = UI.font("title")
  local why_lines = {}
  if self.why and self.why ~= "" then
    why_lines = UI.wrapWith(self.why, inner, font)
    if #why_lines > 3 then
      why_lines[3] = UI.ellipsizeWith(why_lines[3] .. "…", inner, font)
      while #why_lines > 3 do why_lines[#why_lines] = nil end
    end
  end
  local q = self.quest
  local concepts = (q.concepts and #q.concepts > 0) and table.concat(q.concepts, " · ") or nil
  local _, bh = UI.buttonSize(I18n.t("PLAY"), { key = "ENTER" })
  bh = math.max(Theme.control.buttonM, bh)
  local ch = Theme.stripH + p + UI.lead("label") + Theme.space.xs + #why_lines * UI.lead("title") + Theme.space.md
    + UI.readHeight(tostring(q.title or q.id), inner) + UI.lead("label") + (concepts and UI.lead("label") or 0)
    + Theme.space.lg + bh + Theme.space.lg + 8 + p
  local cy0 = y + (1 - k) * 24
  UI.card(x, cy0, w, ch, { strip = Theme.gold, pad = 0, alpha = alpha })
  local cy = cy0 + Theme.stripH + p

  -- §4.16: `position` is 0-based (quests already behind you), so the label
  -- and the bar are `position + 1`.
  local at = (self.position or 0) + 1
  UI.label(("%d / %d"):format(at, self.total or 1), x + p, cy, "label", { color = Theme.mute, width = inner, align = "right", alpha = alpha })
  UI.label(I18n.t(MODE_TEXT[self:mode()].title), x + p, cy, "label", { color = Theme.mute, alpha = alpha })
  cy = cy + UI.lead("label") + Theme.space.xs

  -- The line that makes this a coach rather than a shuffle (§4.16). Largest
  -- thing on the screen, on purpose.
  for _, line in ipairs(why_lines) do
    cy = cy + UI.label(line, x + p, cy, "title", { color = Theme.gold, alpha = alpha })
  end
  cy = cy + Theme.space.md
  cy = cy + UI.read(tostring(q.title or q.id), x + p, cy, inner, { alpha = alpha })
  cy = cy + UI.label(tostring(q.id), x + p, cy, "label", { color = Theme.mute, width = inner, ellipsis = true, alpha = alpha })
  if concepts then
    cy = cy + UI.label(concepts, x + p, cy, "label", { color = Theme.blue, width = inner, ellipsis = true, alpha = alpha })
  end
  cy = cy + Theme.space.lg

  -- PLAY and SKIP, sized from their labels.
  local pw = UI.buttonSize(I18n.t("PLAY"), { key = "ENTER" })
  local sw = UI.buttonSize(I18n.t("SKIP"), { key = "N" })
  pw = math.max(pw, 160)
  self.play_rect = { x = x + p, y = cy, w = pw, h = bh }
  self.next_rect = { x = x + p + pw + Theme.space.md, y = cy, w = sw, h = bh }
  UI.button(self.play_rect.x, cy, pw, bh, I18n.t("PLAY"), self.hover == "play" and "hot" or "normal", nil,
    { variant = "primary", id = "ai:play", key = "ENTER", alpha = alpha })
  UI.button(self.next_rect.x, cy, sw, bh, I18n.t("SKIP"), self.hover == "next" and "hot" or "normal", nil,
    { variant = "secondary", id = "ai:next", key = "N", alpha = alpha })
  cy = cy + bh + Theme.space.lg
  UI.bar(x + p, cy, inner, 8, (self.total or 1) > 0 and at / self.total or 0, Theme.gold)
  return ch
end

function Ai:draw_summary(x, y, w, h)
  local sm = self.summary
  local paras = { { text = I18n.t("attempted %d   cleared %d", sm.attempted or 0, sm.cleared or 0) } }
  if sm.kinds_improved and #sm.kinds_improved > 0 then
    paras[#paras + 1] = { text = I18n.t("improved: ") .. table.concat(sm.kinds_improved, ", "), color = Theme.mute }
  end
  return note_card(x, y, w, I18n.t("DRILL FINISHED"), Theme.green, paras)
end

-- -------------------------------------------------------------------- input

--- The wheel moves the cursor, because on a desktop that is what a wheel is
--- for.
function Ai:wheelmoved(_, dy)
  if self.drill then return end
  self.cursor = ((self.cursor - 1 + (dy > 0 and -1 or 1)) % #MODES) + 1
  SFX.play("move")
end

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
  if key == "n" and self.drill then
    UI.press("ai:next", self.next_rect, { sfx = false })
    self:next()
    return true
  end
  if key == "f" and self.drill then self:finish(); return true end
  return false
end

local function inside(r, x, y)
  return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

function Ai:mousemoved(x, y)
  self.hover = nil
  if inside(self.back_rect, x, y) then self.hover = "back"; return end
  if inside(self.play_rect, x, y) then self.hover = "play"; return end
  if inside(self.next_rect, x, y) then self.hover = "next"; return end
  for i, rect in ipairs(self.mode_rects or {}) do
    if inside(rect, x, y) then self.hover = i; return end
  end
end

function Ai:mousepressed(x, y)
  if inside(self.back_rect, x, y) then
    UI.press("ai:back", self.back_rect, { sfx = false })
    self.app:back()
    return
  end
  if inside(self.play_rect, x, y) then self:play(); return end
  if inside(self.next_rect, x, y) then
    UI.press("ai:next", self.next_rect, { sfx = false })
    self:next()
    return
  end
  for i, rect in ipairs(self.mode_rects or {}) do
    if inside(rect, x, y) then
      if self.cursor ~= i then self.cursor = i; SFX.play("move") else self:plan() end
      return
    end
  end
end

return Ai
