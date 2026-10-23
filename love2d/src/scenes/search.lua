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
-- this screen can do that a plain list cannot: each hit wears its fused score
-- as a chip and two small bars for `bm25` and `cosine`, so a result that came
-- from the word matching reads differently from one that came from the
-- meaning matching. A `null` component means the quest was absent from that
-- ranking entirely (§5.5), and that is drawn as absence rather than as zero —
-- they are different facts.
--
-- ## The look (`docs/love2d-ui.md`)
--
-- A 56 px code well for the box, the three modes as chips under it, and the
-- hits as cards — each laid out from the type it holds (a title, a line of
-- metadata, a line of snippet), never from a fixed row height, so the rows
-- cannot print through one another at any type step. The list scrolls under
-- the cursor with a fade at the clipped edge. Before the first query the
-- screen is an illustration and three suggestions, not an empty panel.
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
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Anim = require("src.anim")
local Juice = require("src.juice")
local Fx = require("src.fx")
local errors = require("src.net.errors")

local Search = {}
Search.__index = Search

local MODES = { "unified", "bm25", "semantic" }
local MODE_BLURB = {
  unified = "both rankings, fused",
  bm25 = "the words you typed",
  semantic = "what you meant",
}

--- Three things worth asking for, offered before the first query. Queries
--- into the English content, so they are not translated.
Search.SUGGESTIONS = { "borrow checker", "goroutines", "lifetimes" }

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
    scroll = 0,
    scrolled_at = -10,
    hover = nil,
    header_h = UI.headerHeight(),
  }, Search)
end

function Search:enter()
  Juice.forget("search:")
end

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
    self.scroll = 0
    Juice.forget("search:hit")
  end)
end

function Search:set_mode(mode)
  if mode == self.mode then return end
  self.mode = mode
  SFX.play("move")
  if self.asked and self.asked ~= "" then self:submit() end
end

function Search:cycle_mode()
  for i, mode in ipairs(MODES) do
    if mode == self.mode then
      self:set_mode(MODES[i % #MODES + 1])
      return
    end
  end
end

function Search:open()
  local hit = self.hits and self.hits[self.cursor]
  if not hit then return end
  UI.press("search:hit" .. self.cursor, self.hit_rects and self.hit_rects[self.cursor], { sfx = false })
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

--- Move the cursor and keep its row in view.
function Search:move(delta)
  if not self.hits or #self.hits == 0 then return end
  self.cursor = math.max(1, math.min(#self.hits, self.cursor + delta))
  SFX.play("move")
  self.follow = true
end

-- ------------------------------------------------------------------ layout

--- The hit card's height: a title, a line of metadata and one line of
--- snippet, each at its role's lead, with the card padding round them.
function Search.hit_height()
  local pad = Theme.space.lg
  local _, read_lead = UI.readHeight("x", 100)
  return pad + UI.lead("title") + Theme.space.xs + UI.lead("label") + Theme.space.xs + read_lead + pad
end

--- Everything above the list: the box and the mode chips. Returns the rects
--- the hit test needs and where the list starts.
function Search:layout()
  local x, y, w, h = UI.bounded(nil, self.header_h + Theme.space.lg, Layout.vh - UI.footerHeight() - Theme.space.lg)
  local font = Assets.mono(Layout.codeSize(18))
  local box_h = math.max(Theme.control.buttonL, font:getHeight() + Theme.space.lg)
  local box = { x = x, y = y, w = w, h = box_h, font = font }
  local cy = y + box_h + Theme.space.md
  local chips = {}
  local cx = x
  for _, mode in ipairs(MODES) do
    local cw = UI.chipWidth(mode)
    chips[mode] = { x = cx, y = cy, w = cw, h = Theme.control.chip }
    cx = cx + cw + Theme.space.sm
  end
  local blurb = I18n.t(MODE_BLURB[self.mode] or "")
  local blurb_beside = cx + Theme.space.sm + UI.labelWidth(blurb, "label") <= x + w
  local list_y = cy + Theme.control.chip + (blurb_beside and 0 or UI.lead("label")) + Theme.space.lg
  return {
    x = x, y = y, w = w, h = h, box = box, chips = chips, chips_end = cx,
    blurb = blurb, blurb_beside = blurb_beside,
    list = { x = x, y = list_y, w = w, h = math.max(0, y + h - list_y) },
  }
end

-- ------------------------------------------------------------------ drawing

local function header(self)
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
    self.hover == "back" and "hot" or "normal", nil, { variant = "ghost", id = "search:back" })
  local x = g + bw + Theme.space.lg
  local right = ""
  if self.hits and #self.hits > 0 and self.took_ms then
    right = I18n.t("%d hits · %dms", #self.hits, self.took_ms)
  end
  local rw = UI.labelWidth(right, "label")
  UI.label(right, vw - g - rw, math.floor((h - UI.lead("label")) / 2), "label", { color = Theme.mute })
  UI.label(I18n.t("SEARCH"), x, math.floor((h - UI.lead("title")) / 2), "title",
    { width = vw - g - rw - Theme.space.lg - x, ellipsis = true })
end

function Search:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_datacentre", "bg_flat"), 0, 0, vw, vh)
  UI.setColor(Theme.felt, Layout.isPortrait() and 0.8 or 0.72)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)
  Fx.ambient("neon", vw, vh)
  Fx.drawAmbient()

  local L = self:layout()
  self.mode_rects = L.chips

  -- The box: a code well, the query in the code face, a caret on the beat
  -- clock (never `os.time()`, so a captured frame is the same every run).
  local b = L.box
  local k = Juice.enter("search:box", { dur = Theme.motion.enter })
  UI.card(b.x, b.y, b.w, b.h, { variant = "well", pad = 0, alpha = math.min(1, k * 1.5),
    edge = self.q ~= "" and Theme.gold or nil })
  love.graphics.setFont(b.font)
  local tx = b.x + Theme.space.lg
  local ty = b.y + math.floor((b.h - b.font:getHeight()) / 2)
  local room = b.w - Theme.space.lg * 2
  if self.q == "" then
    UI.setColor(Theme.mute, 0.7)
    love.graphics.print(UI.ellipsizeWith("borrow checker, goroutines, lifetimes…", room, b.font), tx, ty)
  else
    -- The tail of a query longer than the box, so the caret is always seen.
    local shown = self.q
    while b.font:getWidth(shown) > room and #shown > 1 do shown = shown:sub(2) end
    UI.setColor(Theme.text)
    love.graphics.print(shown, tx, ty)
    if math.floor(Anim.now() * 2) % 2 == 0 then
      UI.setColor(Theme.gold)
      love.graphics.rectangle("fill", tx + b.font:getWidth(shown) + 1, ty, 2, b.font:getHeight())
    end
  end
  love.graphics.setColor(1, 1, 1, 1)

  -- The three modes, as chips, because §8 gives them equal standing.
  for _, mode in ipairs(MODES) do
    local r = L.chips[mode]
    UI.chip(r.x, r.y, mode, { selected = mode == self.mode, hot = self.hover == mode, w = r.w })
  end
  if L.blurb_beside then
    UI.label(L.blurb, L.chips_end + Theme.space.sm, L.chips.unified.y + math.floor((Theme.control.chip - UI.lead("label")) / 2),
      "label", { color = Theme.mute })
  else
    UI.label(L.blurb, L.x, L.chips.unified.y + Theme.control.chip + Theme.space.xs, "label",
      { color = Theme.mute, width = L.w, ellipsis = true })
  end

  self:draw_results(L.list)

  self.app:footer(I18n.t("TYPE to search   ENTER go   TAB mode   ARROWS pick   ESC back"))
end

--- A card with a heading and a paragraph or two, content-sized.
local function note_card(x, y, w, title, color, paras)
  local pad = Layout.isPortrait() and Theme.space.lg or Theme.space.xl
  local inner = w - pad * 2
  local h = pad + UI.lead("title") + Theme.space.sm
  for _, p in ipairs(paras) do h = h + UI.readHeight(p.text, inner) + Theme.space.sm end
  h = h + pad - Theme.space.sm
  UI.card(x, y, w, h, { strip = color, pad = 0 })
  local cy = y + pad
  UI.label(title, x + pad, cy, "title", { color = color, width = inner, ellipsis = true })
  cy = cy + UI.lead("title") + Theme.space.sm
  for _, p in ipairs(paras) do
    cy = cy + UI.read(p.text, x + pad, cy, inner, { color = p.color }) + Theme.space.sm
  end
  return h
end

function Search:draw_results(area)
  local x, y, w, h = area.x, area.y, area.w, area.h
  if h <= 0 then return end
  self.hit_rects = {}
  self.chip_rects = {}

  if self.unavailable then
    -- §3.3: real, but not built yet. Said in the story's voice, with no retry
    -- offered — retrying something that does not exist is the thing this code
    -- exists to avoid.
    local said = self.unavailable.milestone
      and I18n.t("One box over every quest, in three rankings at once. It "
        .. "opens in chapter %s.", tostring(self.unavailable.milestone))
      or I18n.t("One box over every quest, in three rankings at once. Not in "
        .. "this build.")
    local paras = {
      { text = said },
      { text = I18n.t("When it lands, each hit will show why it matched — the fused "
        .. "score and the two rankings behind it, so a match on the words "
        .. "reads differently from a match on the meaning."), color = Theme.mute },
    }
    if self.unavailable.message then paras[#paras + 1] = { text = self.unavailable.message, color = Theme.mute } end
    note_card(x, y, w, I18n.t("NOT BUILT YET"), Theme.gold, paras)
    return
  end
  if self.searching then
    UI.label(I18n.t("searching…"), x, y + Theme.space.sm, "label", { color = Theme.mute, width = w, align = "center" })
    return
  end
  if self.error then
    UI.label(self.error, x, y + Theme.space.sm, "label", { color = Theme.redA, width = w, align = "center" })
    return
  end
  if not self.hits then
    self:draw_empty(x, y, w, h)
    return
  end
  if #self.hits == 0 then
    UI.label(I18n.t("nothing matched %q", self.asked or ""), x, y + Theme.space.sm, "label",
      { color = Theme.mute, width = w, align = "center" })
    return
  end

  -- The list: as tall as its cards, scrolled so the cursor's row is in view.
  local rh = Search.hit_height()
  local gap = Theme.rowGap
  local total = #self.hits * (rh + gap) - gap
  local max_scroll = math.max(0, total - h)
  if self.follow then
    local top = (self.cursor - 1) * (rh + gap)
    if top < self.scroll then self.scroll = top
    elseif top + rh > self.scroll + h then self.scroll = top + rh - h end
    self.follow = false
  end
  local target = math.max(0, math.min(max_scroll, self.scroll))
  self.scroll = target
  local shown = Juice.follow("search:scroll", target, { speed = 18 })

  love.graphics.setScissor(x - Theme.space.sm, y, w + Theme.space.lg, h)
  for i, hit in ipairs(self.hits) do
    local ry = y + (i - 1) * (rh + gap) - shown
    local r = { x = x, y = ry, w = w, h = rh }
    self.hit_rects[i] = r
    if ry + rh >= y and ry <= y + h then
      self:draw_hit(i, r, hit)
    end
  end
  love.graphics.setScissor()
  if shown > 0 then UI.scrollFade(x, y, w, Theme.felt, "top") end
  if shown < max_scroll then UI.scrollFade(x, y + h - Theme.space.xl, w, Theme.felt, "bottom") end
  if max_scroll > 0 then
    local fade = math.max(0, math.min(1, 1 - (Anim.now() - self.scrolled_at - 0.8) / 0.4))
    UI.scrollbar(x + w + Theme.space.sm - 6, y, h, h / total, shown / max_scroll, { alpha = fade })
  end
end

--- Before the first query: an illustration, the sentence, and three things
--- worth asking for.
function Search:draw_empty(x, y, w, h)
  local k = Juice.enter("search:empty", { dur = Theme.motion.enter, delay = 0.1 })
  local alpha = math.min(1, k * 1.5)
  local box = math.min(128, math.floor(h * 0.3))
  local cy = y + Theme.space.lg + (1 - k) * 16
  local who = Assets.pick("agent_coder", "sprite_mei")
  if who and box >= 48 then
    local bob = Anim.bob(Anim.now(), { amount = 3, period = 2.4 })
    Assets.sprite(who, x + w / 2, cy + box + bob, box, { alpha = alpha })
    cy = cy + box + Theme.space.lg
  end
  local text = I18n.t("Type and press ENTER. It searches every quest in every land — "
    .. "titles, briefs, concepts and the story text.")
  local tw = math.min(w, 640)
  cy = cy + UI.read(text, x + math.floor((w - tw) / 2), cy, tw, { color = Theme.mute, align = "center", alpha = alpha, maxLines = 3 })
  cy = cy + Theme.space.lg
  local total = -Theme.space.sm
  for _, s in ipairs(Search.SUGGESTIONS) do total = total + UI.chipWidth(s) + Theme.space.sm end
  local cx = x + math.floor((w - total) / 2)
  for i, s in ipairs(Search.SUGGESTIONS) do
    local cw = UI.chipWidth(s)
    self.chip_rects[i] = { x = cx, y = cy, w = cw, h = Theme.control.chip, q = s }
    UI.chip(cx, cy, s, { hot = self.hover == "suggest" .. i, alpha = alpha })
    cx = cx + cw + Theme.space.sm
  end
end

--- One hit: the title, where it is, a line of the snippet, and why it
--- matched — the fused score as a chip, the two components as bars.
function Search:draw_hit(i, r, hit)
  local selected = i == self.cursor
  local k = Juice.enter("search:hit" .. i, { dur = Theme.motion.enter, delay = Juice.stagger(math.min(i, 8), Theme.motion.stagger) })
  local hot = (selected or self.hover == i) and 1 or 0
  local a = Juice.follow("search:hot" .. i, hot, { speed = 18 })
  local press = Juice.pressed("press:search:hit" .. i)
  local y = r.y + (1 - k) * 16 - 2 * a + 4 * press
  local alpha = math.min(1, k * 1.5)
  local pad = Theme.space.lg
  UI.card(r.x, y, r.w, r.h, { hot = a, selected = selected, alpha = alpha, pad = 0,
    shadowDy = Theme.shadowDy - 5 * press })

  local x = r.x + pad
  local right = r.x + r.w - pad
  local cy = y + pad

  -- The right end of the title row: the score chip, and CLEARED.
  local score = ("%.3f"):format(tonumber(hit.score) or 0)
  local sw = UI.chipWidth(score)
  local chip_y = cy + math.floor((UI.lead("title") - Theme.control.chip) / 2)
  UI.chip(right - sw, chip_y, score, { selected = selected, alpha = alpha, w = sw })
  local title_right = right - sw - Theme.space.md
  if hit.state == "cleared" then
    local cw = UI.chipWidth(I18n.t("CLEARED"))
    UI.chip(title_right - cw, chip_y, I18n.t("CLEARED"), { color = Theme.green, alpha = alpha, w = cw })
    title_right = title_right - cw - Theme.space.md
  end
  UI.label(tostring(hit.title or hit.quest_id), x, cy, "title",
    { width = title_right - x, ellipsis = true, alpha = alpha })
  cy = cy + UI.lead("title") + Theme.space.xs

  -- **Why it matched**, right-aligned on the metadata line. A `null`
  -- component is drawn as absence, not as zero: §5.5 says null means the
  -- quest was not in that ranking at all, which is a different fact.
  local bar_w = 48
  local bx = right
  local ly = cy + math.floor((UI.lead("label") - 8) / 2)
  for _, pair in ipairs({ { "cos", hit.cosine }, { "bm25", hit.bm25 } }) do
    local label, value = pair[1], tonumber(pair[2])
    if value then
      -- Normalised only for the bar's length; the number is the truth.
      local fraction = math.max(0, math.min(1, math.abs(value) / 20))
      bx = bx - bar_w
      UI.bar(bx, ly, bar_w, 8, fraction, Theme.blue)
    else
      bx = bx - UI.labelWidth("—", "label")
      UI.label("—", bx, cy, "label", { color = Theme.mute, alpha = alpha })
    end
    bx = bx - Theme.space.xs - UI.labelWidth(label, "label")
    UI.label(label, bx, cy, "label", { color = Theme.mute, alpha = alpha })
    bx = bx - Theme.space.md
  end
  local meta = ("%s / %s · %s"):format(tostring(hit.land):upper(), tostring(hit.category):upper(), tostring(hit.quest_id))
  UI.label(meta, x, cy, "label", { color = Theme.mute, width = bx - Theme.space.md - x, ellipsis = true, alpha = alpha })
  cy = cy + UI.lead("label") + Theme.space.xs

  -- The snippet. FTS5's `snippet()` marks the match with <b>…</b> (§5.5); the
  -- tags are stripped, because showing a player raw markup is showing them
  -- the plumbing.
  local text = tostring(hit.snippet or ""):gsub("\n", " ")
  local plain = text:gsub("</?b>", "")
  UI.read(plain, x, cy, right - x, { maxLines = 1, color = Theme.text, alpha = alpha * 0.9 })
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
  if key == "down" and self.hits then self:move(1); return true end
  if key == "up" and self.hits then self:move(-1); return true end
  if key == "v" and mods and (mods.ctrl or mods.gui) then
    self.q = self.q .. (love.system.getClipboardText() or ""):gsub("%s+", " ")
    return true
  end
  return false
end

--- The wheel moves the cursor, because on a desktop that is what a wheel is
--- for; the list follows it.
function Search:wheelmoved(_, dy)
  if not self.hits or #self.hits == 0 then return end
  self.scrolled_at = Anim.now()
  self:move(dy > 0 and -1 or 1)
end

local function inside(r, x, y)
  return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

function Search:mousemoved(x, y)
  self.hover = nil
  if inside(self.back_rect, x, y) then self.hover = "back"; return end
  for mode, rect in pairs(self.mode_rects or {}) do
    if inside(rect, x, y) then self.hover = mode; return end
  end
  for i, rect in ipairs(self.chip_rects or {}) do
    if inside(rect, x, y) then self.hover = "suggest" .. i; return end
  end
  for i, rect in ipairs(self.hit_rects or {}) do
    if inside(rect, x, y) then self.hover = i; return end
  end
end

function Search:mousepressed(x, y)
  if inside(self.back_rect, x, y) then
    UI.press("search:back", self.back_rect, { sfx = false })
    self.app:back()
    return
  end
  for mode, rect in pairs(self.mode_rects or {}) do
    if inside(rect, x, y) then self:set_mode(mode); return end
  end
  for _, rect in ipairs(self.chip_rects or {}) do
    if inside(rect, x, y) then
      self.q = rect.q
      self:submit()
      return
    end
  end
  for i, rect in ipairs(self.hit_rects or {}) do
    if inside(rect, x, y) then
      -- First click selects, second opens.
      if self.cursor ~= i then
        self.cursor = i
        self.follow = true
        SFX.play("move")
      else
        self:open()
      end
      return
    end
  end
end

return Search
