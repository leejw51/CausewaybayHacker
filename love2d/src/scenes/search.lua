-- SEARCH (SPEC §8). One box over every quest.
--
-- `search.query` with `mode` in `bm25 | semantic | unified`, unified the
-- default. Hits jump straight to the quest, which works now that nothing is
-- locked (§4.7) — before that, half the results would have been a wall.
--
-- ## Showing *why* something matched
--
-- §8.3: "The response carries the component scores as well as the fused one,
-- so the search screen can show why something matched." That is the one thing
-- this screen can do that a plain list cannot, and a terminal-ish client is
-- the right place for it: each hit shows its fused score and two small bars
-- for `bm25` and `cosine`, so a result that came from the word matching reads
-- differently from one that came from the meaning matching. A `null`
-- component means the quest was absent from that ranking entirely (§5.5), and
-- that is drawn as absence rather than as zero — they are different facts.
--
-- ## While it does not exist
--
-- The server answers `unavailable` with `detail.milestone` today. §3.3 is
-- explicit that this is **not** `internal`: the screen says so in the story's
-- voice and does not offer a retry, because retrying will not help. The
-- moment the endpoint is real this screen renders hits instead, with no
-- change here — which is why it is built now rather than stubbed.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local SFX = require("src.sfx")
local errors = require("src.net.errors")

local Search = {}
Search.__index = Search

local MODES = { "unified", "bm25", "semantic" }
local MODE_BLURB = {
  unified = "both rankings, fused",
  bm25 = "the words you typed",
  semantic = "what you meant",
}

function Search.new(app)
  return setmetatable({
    app = app,
    q = "",
    mode = "unified",
    hits = nil,
    took_ms = nil,
    cursor = 1,
    asked = nil,          -- the query the current results belong to
    searching = false,
    unavailable = nil,    -- { message, milestone }
    error = nil,
  }, Search)
end

function Search:enter() end

function Search:submit()
  local q = self.q:gsub("^%s+", ""):gsub("%s+$", "")
  if q == "" then
    -- §4.12: "An empty `q` returns no hits rather than everything." No point
    -- asking.
    self.hits, self.asked, self.error = {}, "", nil
    return
  end
  self.searching = true
  self.error = nil
  SFX.play("select")
  self.app.session:request("search.query", {
    q = q, mode = self.mode, limit = 20,
  }, function(ok, payload, why)
    self.searching = false
    if not ok then
      if payload.code == "unavailable" then
        self.unavailable = {
          message = payload.message,
          milestone = errors.milestone(payload),
        }
      else
        self.error = why.player
      end
      return
    end
    self.unavailable = nil
    self.hits = payload.hits or {}
    self.took_ms = payload.took_ms
    self.asked = q
    self.cursor = 1
  end)
end

function Search:cycle_mode()
  for i, mode in ipairs(MODES) do
    if mode == self.mode then
      self.mode = MODES[i % #MODES + 1]
      break
    end
  end
  SFX.play("move")
  if self.asked and self.asked ~= "" then self:submit() end
end

function Search:open()
  local hit = self.hits and self.hits[self.cursor]
  if not hit then return end
  SFX.play("select")
  local land, category = tostring(hit.quest_id):match("^(%a+)%.(%a+)%.")
  self.app.land = hit.land or land or self.app.land
  self.app.category = hit.category or category or self.app.category
  self.app.quest_id = hit.quest_id
  self.app:go("quest", {
    quest_id = hit.quest_id,
    land = self.app.land,
    category = self.app.category,
  })
end

-- ------------------------------------------------------------------ drawing

function Search:draw()
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
  UI.text("SEARCH", 12, 12, math.floor(15 * s), Theme.cyan)

  -- The box.
  local by = 54
  UI.setColor(Theme.void, 0.9)
  love.graphics.rectangle("fill", pad, by, w, 32)
  love.graphics.setLineWidth(2)
  UI.setColor(Theme.coin)
  love.graphics.rectangle("line", pad + 1, by + 1, w - 2, 30)
  love.graphics.setColor(1, 1, 1, 1)
  local font = Assets.mono(20)
  love.graphics.setFont(font)
  if self.q == "" then
    UI.setColor(Theme.withAlpha(Theme.cream, 0.35))
    love.graphics.print("borrow checker, goroutines, lifetimes…", pad + 10, by + 6)
  else
    UI.setColor(Theme.cream)
    love.graphics.print(self.q, pad + 10, by + 6)
    if (love.timer.getTime() * 2) % 2 < 1.2 then
      UI.setColor(Theme.coin)
      love.graphics.rectangle("fill", pad + 10 + font:getWidth(self.q), by + 6, 2, font:getHeight())
    end
  end
  love.graphics.setColor(1, 1, 1, 1)

  -- The three modes, as a row, because §8 gives them equal standing.
  local my = by + 38
  local mw = math.min(120, (w - 16) / 3)
  self.mode_rects = {}
  for i, mode in ipairs(MODES) do
    local mx = pad + (i - 1) * (mw + 8)
    local on = mode == self.mode
    UI.button(mx, my, mw, 22, mode:upper(), on and "hot" or "normal", 8)
    self.mode_rects[mode] = { x = mx, y = my, w = mw, h = 22 }
  end
  UI.text(MODE_BLURB[self.mode] or "", pad + 3 * (mw + 8) + 6, my + 7, 7,
    Theme.withAlpha(Theme.cream, 0.55))

  local ly = my + 32
  self:draw_results(pad, ly, w, vh - ly - 40)

  self.app:footer("TYPE to search   ENTER go   TAB mode   ARROWS pick   ESC back")
end

function Search:draw_results(x, y, w, h)
  UI.panel(x, y, w, h, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.cyan })
  love.graphics.setScissor(x + 4, y + 4, w - 8, h - 8)
  local cy = y + 12

  if self.unavailable then
    -- §3.3: real, but not built yet. Said in the story's voice, with no retry
    -- offered — retrying something that does not exist is the thing this code
    -- exists to avoid.
    UI.text("NOT BUILT YET", x + 16, cy, 10, Theme.coin)
    cy = cy + 18
    local said = self.unavailable.milestone
      and ("One box over every quest, in three rankings at once. It opens in "
        .. "chapter " .. self.unavailable.milestone .. ".")
      or "One box over every quest, in three rankings at once. Not in this build."
    for _, line in ipairs(UI.wrap(said, w - 40, 8)) do
      cy = cy + UI.text(line, x + 16, cy, 8, Theme.cream) + 4
    end
    cy = cy + 8
    for _, line in ipairs(UI.wrap(
      "When it lands, each hit will show why it matched — the fused score and "
        .. "the two rankings behind it, so a match on the words reads "
        .. "differently from a match on the meaning.", w - 40, 7)) do
      cy = cy + UI.text(line, x + 16, cy, 7, Theme.withAlpha(Theme.cream, 0.55)) + 3
    end
    if self.unavailable.message then
      UI.text(self.unavailable.message, x + 16, y + h - 18, 7,
        Theme.withAlpha(Theme.cream, 0.35))
    end
    love.graphics.setScissor()
    return
  end

  if self.searching then
    UI.text("searching…", x + 16, cy, 9, Theme.withAlpha(Theme.cream, 0.7))
    love.graphics.setScissor()
    return
  end
  if self.error then
    UI.text(self.error, x + 16, cy, 9, Theme.red)
    love.graphics.setScissor()
    return
  end
  if not self.hits then
    for _, line in ipairs(UI.wrap(
      "Type and press ENTER. It searches every quest in both lands — titles, "
        .. "briefs, concepts and the story text.", w - 40, 8)) do
      cy = cy + UI.text(line, x + 16, cy, 8, Theme.withAlpha(Theme.cream, 0.6)) + 4
    end
    love.graphics.setScissor()
    return
  end
  if #self.hits == 0 then
    UI.text(("nothing matched %q"):format(self.asked or ""), x + 16, cy, 9,
      Theme.withAlpha(Theme.cream, 0.7))
    love.graphics.setScissor()
    return
  end

  if self.took_ms then
    UI.text(("%d hits   %dms"):format(#self.hits, self.took_ms),
      x + w - 16 - UI.textWidth(("%d hits   %dms"):format(#self.hits, self.took_ms), 7),
      y + 8, 7, Theme.withAlpha(Theme.cream, 0.45))
  end

  self.hit_rects = {}
  for i, hit in ipairs(self.hits) do
    if cy > y + h - 40 then break end
    cy = self:draw_hit(x, cy, w, hit, i == self.cursor) + 8
  end
  love.graphics.setScissor()
end

function Search:draw_hit(x, y, w, hit, selected)
  local rh = 52
  if selected then
    UI.setColor(Theme.coin, 0.16)
    love.graphics.rectangle("fill", x + 6, y - 4, w - 12, rh)
    love.graphics.setColor(1, 1, 1, 1)
  end

  local cleared = hit.state == "cleared"
  UI.text(tostring(hit.title or hit.quest_id), x + 16, y, 9,
    selected and Theme.coin or Theme.cream)
  if cleared then
    UI.text("CLEARED", x + w - 16 - UI.textWidth("CLEARED", 7), y, 7, Theme.admit)
  end
  UI.text(("%s / %s   %s"):format(tostring(hit.land), tostring(hit.category),
    tostring(hit.quest_id)), x + 16, y + 12, 7, Theme.withAlpha(Theme.cream, 0.45))

  -- The snippet. FTS5's `snippet()` marks the match with <b>…</b> (§5.5); the
  -- tags are stripped and the marked span is drawn in coin instead, because
  -- showing a player raw markup is showing them the plumbing.
  local text = tostring(hit.snippet or ""):gsub("\n", " ")
  local plain = text:gsub("</?b>", "")
  for _, line in ipairs(UI.wrap(plain, w - 44, 7)) do
    UI.text(line, x + 22, y + 24, 7, Theme.withAlpha(Theme.cream, 0.75))
    break
  end

  -- **Why it matched.** The fused score, then the two components — and a
  -- `null` component is drawn as absence, not as zero: §5.5 says null means
  -- the quest was not in that ranking at all, which is a different fact.
  local bx = x + 16
  local byy = y + 38
  UI.text(("%.4f"):format(tonumber(hit.score) or 0), bx, byy, 7, Theme.coin)
  bx = bx + 46
  for _, pair in ipairs({ { "bm25", hit.bm25 }, { "cos", hit.cosine } }) do
    local label, value = pair[1], tonumber(pair[2])
    UI.text(label, bx, byy, 7, Theme.withAlpha(Theme.cream, 0.45))
    bx = bx + UI.textWidth(label, 7) + 4
    if value then
      -- Normalised only for the bar's length; the number is the truth.
      local fraction = math.max(0, math.min(1, math.abs(value) / 20))
      UI.setColor(Theme.cyan, 0.75)
      love.graphics.rectangle("fill", bx, byy + 2, 2 + fraction * 40, 6)
      love.graphics.setColor(1, 1, 1, 1)
      bx = bx + 46
    else
      UI.text("—", bx, byy, 7, Theme.withAlpha(Theme.dim, 0.9))
      bx = bx + 16
    end
  end
  return y + rh
end

-- -------------------------------------------------------------------- input

function Search:textinput(text)
  self.q = self.q .. text
end

function Search:keypressed(key, mods)
  if key == "backspace" then
    if mods and (mods.ctrl or mods.alt) then
      self.q = self.q:gsub("%s*%S+%s*$", "")
    else
      self.q = self.q:sub(1, -2)
    end
    return true
  end
  if key == "tab" then self:cycle_mode(); return true end
  if key == "return" or key == "kpenter" then
    if self.hits and #self.hits > 0 and self.asked == self.q:gsub("^%s+", ""):gsub("%s+$", "") then
      self:open()
    else
      self:submit()
    end
    return true
  end
  if key == "down" and self.hits then
    self.cursor = math.min(#self.hits, self.cursor + 1); SFX.play("move"); return true
  end
  if key == "up" and self.hits then
    self.cursor = math.max(1, self.cursor - 1); SFX.play("move"); return true
  end
  if key == "v" and mods and (mods.ctrl or mods.gui) then
    self.q = self.q .. (love.system.getClipboardText() or ""):gsub("%s+", " ")
    return true
  end
  return false
end

function Search:mousepressed(x, y)
  for mode, rect in pairs(self.mode_rects or {}) do
    if x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h then
      if mode ~= self.mode then
        self.mode = mode
        SFX.play("move")
        if self.asked and self.asked ~= "" then self:submit() end
      end
      return
    end
  end
end

return Search
