-- STATS. Where the premise becomes visible: your mistakes are the curriculum.
--
-- `stats.summary` (§4.13), `stats.mistakes` (§4.14), `stats.awards` (§4.14b)
-- and `stats.history` (§4.15). All four are live.
--
-- ## `cleared_since` gets the weight
--
-- §5.6: consecutive clean submits since the player last made that mistake. At
-- 5 the kind is considered learned and drops out of the drill (SPEC §7.3's
-- `weakness` takes kinds with `cleared_since < 5`).
--
-- That number is the most motivating thing in the product, because it is the
-- only one that says *you are getting better at this specific thing*. "You
-- have not done this in four submits" is a sentence about a person; "count:
-- 6" is a row in a table. So it is drawn as a five-step track with the
-- remaining steps visible — the shape says how far there is to go — and it is
-- said in words beside it.
--
-- ## The shelf
--
-- DESIGN made `badge_slot`, an empty recessed socket, precisely so an
-- unearned badge reads as *something you can go and get* rather than as
-- nothing. Earned awards come from `stats.awards`; the rest of the shelf is
-- sockets. **No award is invented** — the socket is furniture, not a name for
-- a badge this client guessed at.
--
-- ## And what it says to somebody with no history
--
-- A new player has no mistakes, and a mistakes list that renders zero rows
-- silently is worse than one that says why it is empty. Every card here has
-- a written empty state, and the one for mistakes is deliberately not an
-- apology: having made no mistakes yet is the correct state for somebody who
-- has just arrived.
--
-- ## The look (`docs/love2d-ui.md`)
--
-- A row of stat tiles (caption 16 over a value 48, counting up on first
-- show); the LANDS card as a grid of tiles — mascot, name, bar, count — in
-- real columns rather than a text block padded with spaces; the SHELF with
-- its badges; the MISTAKES card with the drill list, or the history behind
-- the H chip. One scrolling column, with a fade at the clipped edge, in both
-- orientations. Nothing here moves with F12 except the reading face.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Anim = require("src.anim")
local Ease = require("src.ease")
local Juice = require("src.juice")
local Fx = require("src.fx")
local Land = require("src.land")

local Stats = {}
Stats.__index = Stats

--- §7.3: a kind with this many clean submits behind it has been learned and
--- leaves the drill.
Stats.LEARNED_AT = 5

--- How many sockets the shelf shows. Enough to read as a collection with room
--- in it, not so many that a new player sees a wall of absence.
Stats.SHELF_SLOTS = 8

local KIND_BADGE = { badge = "badge_star", level = "badge_chevron", streak = "badge_flame" }

--- The per-land record, as the grid it is drawn as: rows of `cols` cells,
--- each `{ land, name, cleared, total }`, in the order the server sent.
---
--- A pure function so a headless test can check what the drawing code
--- cannot be trusted to get right on its own: that every land the server
--- names reaches a cell (the bug this replaces dropped the ones past the
--- panel's edge), that C++ is written C++, and that a row off the wire with
--- a field missing reads as zero rather than taking the card down.
---
--- Returns an array of rows, and never `nil`; an empty record is no rows.
function Stats.land_grid(by_land, cols)
  cols = math.max(1, math.floor(tonumber(cols) or 3))
  local rows = {}
  for i, land in ipairs(by_land or {}) do
    local r = math.floor((i - 1) / cols) + 1
    rows[r] = rows[r] or {}
    rows[r][#rows[r] + 1] = {
      land = land.land,
      name = Land.name(land.land),
      cleared = tonumber(land.cleared) or 0,
      total = tonumber(land.total) or 0,
    }
  end
  return rows
end

function Stats.new(app)
  return setmetatable({
    app = app,
    summary = nil, mistakes = nil, awards = nil, history = nil,
    errors = {},
    scroll = 0,
    scrolled_at = -10,
    tab = "mistakes",          -- "mistakes" | "history"
    t = 0,
    arrived = nil,
    hover = nil,
    header_h = UI.headerHeight(),
  }, Stats)
end

function Stats:enter()
  self.arrived = Anim.now()
  Juice.forget("stats:")
  self:refresh()
end

function Stats:refresh()
  self.errors = {}
  local function ask(type_name, payload, apply)
    self.app.session:request(type_name, payload, function(ok, reply, why)
      if ok then apply(reply) else self.errors[type_name] = why end
    end)
  end
  ask("stats.summary", {}, function(p) self.summary = p end)
  ask("stats.mistakes", { limit = 12 }, function(p) self.mistakes = p.mistakes or {} end)
  ask("stats.awards", {}, function(p) self.awards = p.awards or {} end)
  ask("stats.history", { limit = 12 }, function(p) self.history = p.attempts or {} end)
end

function Stats:update(dt)
  self.t = self.t + dt
end

function Stats:set_tab(tab)
  if tab == self.tab then return end
  self.tab = tab
  SFX.play("move")
end

-- ------------------------------------------------------------------ drawing

local function pad()
  return Layout.isPortrait() and Theme.space.lg or Theme.space.xl
end

--- A caption in the label role, mute, in caps.
local function caption(text, x, y, w, alpha)
  return UI.label(text, x, y, "label", { color = Theme.mute, caps = true, width = w, ellipsis = true, alpha = alpha })
end

function Stats:draw_header()
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
    self.hover == "back" and "hot" or "normal", nil, { variant = "ghost", id = "stats:back" })
  local x = g + bw + Theme.space.lg
  local title = I18n.t("STATS")
  UI.label(title, x, math.floor((h - UI.lead("title")) / 2), "title")
  x = x + UI.labelWidth(title, "title") + Theme.space.sm
  -- A trophy after the word, and the night-shift clerk who keeps the tally
  -- waving from the right of the band. Decoration only: nothing if missing.
  local ink = h - 16
  Assets.marker("fx_trophy", x + ink / 2, h / 2, ink)
  local right = vw - g
  if Assets.image("sprite_clerk") then
    Assets.sprite("sprite_clerk", right - ink * 0.4, h - 4, ink)
    right = right - ink * 0.9 - Theme.space.md
  end
  -- The name moved here from the footer (the address is in the settings).
  local session = self.app.session
  if session and session.authed and session.display_name then
    local who = session:display_name()
    local ww = math.min(UI.labelWidth(who, "label"), right - x - ink - Theme.space.lg)
    if ww > 40 then
      UI.label(UI.ellipsizeWith(who, ww, UI.font("label")), right - ww,
        math.floor((h - UI.lead("label")) / 2), "label", { color = Theme.mute })
    end
  end
end

function Stats:draw()
  local vw, vh = Layout.vw, Layout.vh
  -- Mei's own wall of pinned cards and trophies (`art/bg_stats`), which this
  -- screen is; the data centre and the flat plate are the fallbacks.
  local wall = Assets.pick(Layout.isPortrait() and "bg_stats_p" or "bg_stats", "bg_stats")
  Assets.cover(wall or Assets.pick("bg_datacentre", "bg_flat"), 0, 0, vw, vh)
  UI.setColor(Theme.felt, Layout.isPortrait() and 0.8 or 0.72)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)
  Fx.ambient("dust", vw, vh)
  Fx.drawAmbient()

  local x, y, w, h = UI.bounded(nil, self.header_h + Theme.space.lg, vh - UI.footerHeight() - Theme.space.lg)
  self.view = { x = x, y = y, w = w, h = h }

  -- One column, scrolled. The column's height is what the last draw
  -- measured; the first frame draws at 0 and measures.
  local total = self.column_h or h
  local max_scroll = math.max(0, total - h)
  self.scroll = math.max(0, math.min(max_scroll, self.scroll))
  local shown = Juice.follow("stats:scroll", self.scroll, { speed = 18 })

  love.graphics.setScissor(0, y, vw, h)
  local cy = y - shown
  local bottom = self:draw_column(x, cy, w)
  love.graphics.setScissor()
  self.column_h = bottom - cy
  if shown > 0 then UI.scrollFade(x, y, w, Theme.felt, "top") end
  if shown < max_scroll then UI.scrollFade(x, y + h - Theme.space.xl, w, Theme.felt, "bottom") end
  if max_scroll > 0 then
    local fade = math.max(0, math.min(1, 1 - (Anim.now() - self.scrolled_at - 0.8) / 0.4))
    UI.scrollbar(x + w + Theme.space.sm - 6, y, h, h / total, shown / max_scroll, { alpha = fade })
  end

  self:draw_header()
  self.app:footer(I18n.t("R refresh   H history   ARROWS scroll   ESC back"))
end

--- The cards, top to bottom; returns the bottom edge.
function Stats:draw_column(x, y, w)
  local gap = Theme.gap
  local portrait = Layout.isPortrait()
  y = self:draw_tiles(x, y, w) + gap
  if portrait then
    y = self:draw_lands(x, y, w, 2) + gap
    y = self:draw_shelf(x, y, w) + gap
    y = self:draw_mistakes(x, y, w)
    return y
  end
  -- Landscape: the lands on the left, the shelf and the mistakes on the right.
  local lw = math.floor(w * 0.487)
  local rx, rw = x + lw + gap, w - lw - gap
  local left_bottom = self:draw_lands(x, y, lw, 3)
  local ry = self:draw_shelf(rx, y, rw) + gap
  local right_bottom = self:draw_mistakes(rx, ry, rw)
  return math.max(left_bottom, right_bottom)
end

--- The stat tiles: a caption over a value that counts up on first show.
function Stats:draw_tiles(x, y, w)
  local portrait = Layout.isPortrait()
  local sm = self.summary
  local gap = Theme.gap
  local cells = {
    { "CLEARED", sm and (sm.cleared or 0) or nil, sm and (" / " .. tostring(sm.total or 0)) or nil },
    { "SUBMITS", sm and (sm.attempts or 0) or nil },
    { "ACCURACY", sm and math.floor((sm.accuracy or 0) * 100 + 0.5) or nil, "%" },
    { "STARS", sm and (sm.stars or 0) or nil },
    { "STREAK", sm and (sm.streak_days or 0) or nil, sm and ((sm.streak_days or 0) == 1 and I18n.t("%d day", 1) or I18n.t("%d days", sm.streak_days or 0)):gsub("^%d+%s*", " ") or nil },
  }
  if portrait then
    local user = self.app.session and self.app.session.user
    cells[6] = { "LEVEL", user and tonumber(user.level) or nil }
  end
  local cols = portrait and 2 or #cells
  local tw = math.floor((w - gap * (cols - 1)) / cols)
  local th = portrait and 96 or 104
  local rows = math.ceil(#cells / cols)
  for i, cell in ipairs(cells) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local tx, ty = x + col * (tw + gap), y + row * (th + gap)
    local k = Juice.enter("stats:tile" .. i, { dur = Theme.motion.enter, delay = Juice.stagger(i, Theme.motion.stagger) })
    local alpha = math.min(1, k * 1.5)
    local cy = ty + (1 - k) * 24
    UI.card(tx, cy, tw, th, { pad = 0, alpha = alpha })
    local p = Theme.space.lg
    caption(I18n.t(cell[1]), tx + p, cy + p, tw - p * 2, alpha)
    local vy = cy + p + UI.lead("label") + Theme.space.xs
    if cell[2] == nil then
      UI.label(self.errors["stats.summary"] and "!" or "…", tx + p, vy, "display", { color = Theme.mute, alpha = alpha })
    else
      local shown = Juice.counter("stats:count" .. i, cell[2], { dur = 0.5 })
      local value = tostring(shown)
      local vw_ = UI.labelWidth(value, "display")
      local room = tw - p * 2
      local suffix = cell[3]
      -- The value in display 48 with its unit after it in label 16; a value
      -- too wide for the tile steps down to the title face instead of
      -- running under the next tile.
      local role = "display"
      local suffix_w = suffix and (UI.labelWidth(suffix, "label") + Theme.space.xs) or 0
      if vw_ + suffix_w > room then role = "title"; vw_ = UI.labelWidth(value, role) end
      if vw_ + suffix_w > room then suffix = nil end
      local dy = vy + (UI.lead("display") - UI.lead(role))
      UI.label(value, tx + p, dy, role, { alpha = alpha })
      if suffix then
        UI.label(suffix, tx + p + vw_ + Theme.space.xs, dy + UI.lead(role) - UI.lead("label") - 6, "label",
          { color = Theme.mute, alpha = alpha, width = room - vw_ - Theme.space.xs, ellipsis = true })
      end
    end
  end
  return y + rows * (th + gap) - gap
end

--- A mascot inside a `box` square, standing on `bottom`.
local function mascot(name, x, bottom, box, opts)
  if not name then return false end
  local b = Assets.box[name]
  local image = Assets.image(name)
  if not image then return false end
  local iw, ih = image:getDimensions()
  local ink_w = (b and b.w and b.w > 0) and b.w or iw
  local ink_h = (b and b.h and b.h > 0) and b.h or ih
  local height = box
  if ink_w > ink_h then height = box * ink_h / ink_w end
  return Assets.sprite(name, x, bottom, height, opts)
end

--- The LANDS card: a grid of tiles, one per land the server named.
function Stats:draw_lands(x, y, w, cols)
  local p = pad()
  local k = Juice.enter("stats:lands", { dur = Theme.motion.enter, delay = 0.2 })
  local alpha = math.min(1, k * 1.5)
  local sm = self.summary
  local grid = Stats.land_grid(sm and sm.by_land, cols)
  local inner = w - p * 2
  local gap = Theme.rowGap
  local tile_h = 64
  local n = #grid
  local body = n > 0 and (n * tile_h + (n - 1) * gap) or UI.lead("label")
  local h = p + UI.lead("label") + Theme.space.sm + body + p
  local cy = y + (1 - k) * 24
  UI.card(x, cy, w, h, { pad = 0, alpha = alpha })
  caption(I18n.t("LANDS"), x + p, cy + p, inner, alpha)
  local ty = cy + p + UI.lead("label") + Theme.space.sm
  if n == 0 then
    UI.label(self.errors["stats.summary"] and self.errors["stats.summary"].player or I18n.t("asking the server…"),
      x + p, ty, "label", { color = self.errors["stats.summary"] and Theme.redA or Theme.mute, width = inner, ellipsis = true, alpha = alpha })
    return cy + h
  end
  local tw = math.floor((inner - gap * (cols - 1)) / cols)
  local box = 40
  for r, row in ipairs(grid) do
    for c, cell in ipairs(row) do
      local tx = x + p + (c - 1) * (tw + gap)
      local yy = ty + (r - 1) * (tile_h + gap)
      UI.card(tx, yy, tw, tile_h, { variant = "flat", fill = Theme.bar, pad = 0, alpha = alpha, radius = Theme.radiusInner })
      local tint = Theme.land[cell.land] or Theme.mute
      -- The land's colour as a stripe, never as text.
      UI.setColor(tint, alpha)
      UI.rrect("fill", tx, yy, Theme.landStripeH + Theme.radiusInner, tile_h, Theme.radiusInner)
      UI.setColor(Theme.bar, alpha)
      love.graphics.rectangle("fill", tx + Theme.landStripeH, yy, Theme.radiusInner, tile_h)
      local mx = tx + Theme.landStripeH + Theme.space.sm + box / 2
      if not mascot(Land.mascot(cell.land), mx, yy + tile_h - Theme.space.sm, box, { alpha = alpha }) then
        UI.setColor(tint, 0.9 * alpha)
        love.graphics.circle("fill", mx, yy + tile_h / 2, box * 0.3, 16)
      end
      local nx = tx + Theme.landStripeH + Theme.space.sm + box + Theme.space.sm
      local right = tx + tw - Theme.space.md
      local count = ("%d/%d"):format(cell.cleared, cell.total)
      local cw = UI.labelWidth(count, "label")
      local room = right - nx - cw - Theme.space.sm
      local role = UI.labelWidth(cell.name, "title") <= room and "title" or "label"
      UI.label(cell.name, nx, yy + Theme.space.sm + (role == "label" and 8 or 0), role,
        { width = room, ellipsis = true, alpha = alpha })
      UI.label(count, right - cw, yy + Theme.space.sm + 8, "label", { color = Theme.mute, alpha = alpha })
      UI.bar(nx, yy + tile_h - Theme.space.sm - 6, right - nx, 6,
        cell.total > 0 and cell.cleared / cell.total or 0, Theme.gold)
    end
  end
  return cy + h
end

--- The shelf: what the player has, and sockets for what they do not.
function Stats:draw_shelf(x, y, w)
  local p = pad()
  local k = Juice.enter("stats:shelf", { dur = Theme.motion.enter, delay = 0.24 })
  local alpha = math.min(1, k * 1.5)
  local size, gap = 48, Theme.rowGap
  local inner = w - p * 2
  local awards = self.awards
  local slots = math.max(Stats.SHELF_SLOTS, awards and #awards or 0)
  local per_row = math.max(1, math.floor((inner + gap) / (size + gap)))
  local rows = math.ceil(slots / per_row)
  local h = p + UI.lead("label") + Theme.space.sm + rows * (size + gap) - gap + Theme.space.sm + UI.lead("label") + p
  local cy = y + (1 - k) * 24
  UI.card(x, cy, w, h, { pad = 0, alpha = alpha })
  caption(I18n.t("SHELF"), x + p, cy + p, inner, alpha)
  local sy = cy + p + UI.lead("label") + Theme.space.sm
  if not awards then
    UI.label("…", x + p, sy, "label", { color = Theme.mute, alpha = alpha })
    return cy + h
  end
  for i = 1, slots do
    local award = awards[i]
    local col, row = (i - 1) % per_row, math.floor((i - 1) / per_row)
    local cx = x + p + col * (size + gap) + size / 2
    local yy = sy + row * (size + gap) + size / 2
    if award then
      -- The art for a specific award if it exists, otherwise the one for its
      -- kind. Nothing is invented: `stats.awards` said this was earned.
      local named = "badge_" .. tostring(award.id):gsub("%-", "_")
      local art = Assets.pick(named, KIND_BADGE[award.kind] or "badge_star", "badge_cleared")
      -- A small arrival lift on the newest one.
      local lift = (i == 1 and self.arrived) and Ease.pulse(Anim.now() - self.arrived, 0.9) * 4 or 0
      Assets.marker(art, cx, yy - lift, size, { alpha = alpha })
    else
      -- The socket. DESIGN's point exactly: an empty recess reads as
      -- something to go and get, where a blank space reads as nothing.
      Assets.marker("badge_slot", cx, yy, size, { alpha = 0.55 * alpha })
    end
  end
  local ly = cy + h - p - UI.lead("label")
  if #awards == 0 then
    UI.label(I18n.t("nothing on it yet — clear a street and the first one lands"),
      x + p, ly, "label", { color = Theme.mute, width = inner, ellipsis = true, alpha = alpha })
  else
    local newest = awards[1]
    UI.label(tostring(newest.title or newest.id), x + p, ly, "label",
      { color = Theme.gold, width = inner, ellipsis = true, alpha = alpha })
  end
  return cy + h
end

--- The MISTAKES card, or the history behind its chip. Content-sized: the
--- column scrolls, not the card.
function Stats:draw_mistakes(x, y, w)
  local p = pad()
  local k = Juice.enter("stats:mistakes", { dur = Theme.motion.enter, delay = 0.28 })
  local alpha = math.min(1, k * 1.5)
  local inner = w - p * 2
  local cy0 = y + (1 - k) * 24
  -- Measured by drawing: the rows are drawn once into the card's rect from
  -- the last frame's height, and the height this frame measured is kept
  -- for the next. The first frame of a list is one frame late, which is
  -- within the deal-in.
  local h = self.mistakes_h or 160
  local red = self.tab == "mistakes"
  UI.card(x, cy0, w, h, { pad = 0, alpha = alpha, strip = red and Theme.redA or Theme.blue })
  local cy = cy0 + Theme.stripH + p

  -- The two chips: MISTAKES and HISTORY.
  self.tab_rects = {}
  local cx = x + w - p
  for _, tab in ipairs({ "history", "mistakes" }) do
    local label = I18n.t(tab == "mistakes" and "MISTAKES" or "HISTORY")
    local cw = UI.chipWidth(label)
    cx = cx - cw
    UI.chip(cx, cy, label, { selected = self.tab == tab, hot = self.hover == tab, alpha = alpha })
    self.tab_rects[tab] = { x = cx, y = cy, w = cw, h = Theme.control.chip }
    cx = cx - Theme.space.sm
  end
  local heading_w = cx - Theme.space.sm - (x + p)

  if self.tab == "history" then
    UI.label(I18n.t("RECENT SUBMITS AND RUNS"), x + p, cy + math.floor((Theme.control.chip - UI.lead("label")) / 2), "label",
      { color = Theme.blue, width = heading_w, ellipsis = true, alpha = alpha })
    cy = cy + Theme.control.chip + Theme.space.md
    cy = self:draw_history_rows(x + p, cy, inner, alpha)
  else
    UI.label(I18n.t("YOUR MISTAKES — THIS IS THE CURRICULUM"), x + p, cy + math.floor((Theme.control.chip - UI.lead("label")) / 2),
      "label", { color = Theme.redA, width = heading_w, ellipsis = true, alpha = alpha })
    cy = cy + Theme.control.chip + Theme.space.xs
    cy = cy + UI.label(I18n.t("a kind leaves the drill after five clean submits"), x + p, cy, "label",
      { color = Theme.mute, width = inner, ellipsis = true, alpha = alpha }) + Theme.space.md

    if not self.mistakes then
      local why = self.errors["stats.mistakes"]
      cy = cy + UI.read(why and why.player or I18n.t("asking the server…"), x + p, cy, inner,
        { color = why and Theme.redA or Theme.mute, alpha = alpha })
    elseif #self.mistakes == 0 then
      -- Not an apology. Nothing has gone wrong; there is simply nothing here
      -- yet, and saying what would put something here is more use than silence.
      cy = cy + UI.read(I18n.t("Nothing yet. Every compiler error you make gets classified and "
        .. "lands here, and the drills are built from it — so this fills up by "
        .. "playing, not by trying to fill it up."), x + p, cy, inner, { alpha = alpha })
    else
      for i, m in ipairs(self.mistakes) do
        if i > 1 then
          UI.setColor(Theme.line)
          love.graphics.rectangle("fill", x + p, cy, inner, 1)
          love.graphics.setColor(1, 1, 1, 1)
          cy = cy + Theme.space.md
        end
        cy = self:draw_mistake(x + p, cy, inner, m, alpha) + Theme.space.md
      end
      cy = cy - Theme.space.md
    end
  end
  self.mistakes_h = cy + p - cy0
  return cy0 + self.mistakes_h
end

--- One mistake kind, with `cleared_since` given the weight it deserves.
function Stats:draw_mistake(x, y, w, m, alpha)
  local since = math.max(0, math.floor(tonumber(m.cleared_since) or 0))
  local learned = since >= Stats.LEARNED_AT

  -- The kind, and how often, as a chip.
  local count = ("×%d"):format(m.count or 0)
  local cw = UI.chipWidth(count)
  UI.chip(x + w - cw, y + math.floor((UI.lead("title") - Theme.control.chip) / 2), count,
    { color = learned and Theme.green or Theme.redA, alpha = alpha })
  UI.label(tostring(m.kind), x, y, "title", { width = w - cw - Theme.space.md, ellipsis = true, alpha = alpha })
  y = y + UI.lead("title") + Theme.space.xs

  if m.label and m.label ~= "" and m.label ~= m.kind then
    y = y + UI.read(m.label, x, y, w, { maxLines = 2, alpha = alpha }) + Theme.space.xs
  end

  -- **The shackle, and the track.** `art/shackle_break` is a six-frame
  -- progression and `cleared_since` runs 0..5, so frame `since + 1` is the
  -- state of this kind exactly — intact at zero, in pieces at five. It is the
  -- premise of the whole game in one glyph: the thing that had you is coming
  -- apart because you stopped doing it.
  --
  -- It stands **beside** the track rather than replacing it. The shackle says
  -- where you are; only the five steps say how far there is to go, and
  -- dropping them to make room for the picture would have traded the more
  -- useful half for the prettier one.
  local row_h = Theme.space.xl
  local shackle = x + 12
  Assets.frame("shackle_break", math.min(since, Stats.LEARNED_AT) + 1,
    shackle, y + row_h - 2, 22, { alpha = alpha })
  if learned then
    Assets.marker("fx_shards", shackle + 16, y + 6, 20, { alpha = 0.85 * alpha })
  end

  local step, gap = 14, 5
  local tx = x + 36
  for i = 1, Stats.LEARNED_AT do
    local done = i <= since
    UI.setColor(done and (learned and Theme.green or Theme.gold) or Theme.withAlpha(Theme.mute, 0.45), alpha)
    UI.rrect("fill", tx + (i - 1) * (step + gap), y + math.floor((row_h - 8) / 2), step, 8, 2)
  end
  love.graphics.setColor(1, 1, 1, 1)

  -- And in words, because the sentence is the motivating part: beside the
  -- track when it fits there, under it when it does not.
  local said
  if learned then
    said = I18n.t("learned — out of the drill")
  elseif since == 0 then
    said = I18n.t("you did this on your last submit")
  elseif since == 1 then
    said = I18n.t("one clean submit since")
  else
    said = I18n.t("%d clean submits since — %d to go", since, Stats.LEARNED_AT - since)
  end
  local said_colour = learned and Theme.green or Theme.gold
  local said_x = tx + Stats.LEARNED_AT * (step + gap) + Theme.space.sm
  local beside = x + w - said_x
  if UI.labelWidth(said, "label") <= beside then
    UI.label(said, said_x, y + math.floor((row_h - UI.lead("label")) / 2), "label", { color = said_colour, alpha = alpha })
    y = y + row_h
  else
    y = y + row_h + UI.label(said, x, y + row_h, "label", { color = said_colour, width = w, ellipsis = true, alpha = alpha })
  end
  y = y + Theme.space.xs

  if m.concepts and #m.concepts > 0 then
    y = y + UI.label(I18n.t("drill: %s", table.concat(m.concepts, ", ")), x, y, "label",
      { color = Theme.mute, width = w, ellipsis = true, alpha = alpha })
  end
  if m.example_quest_id then
    y = y + UI.label(I18n.t("last seen on %s", tostring(m.example_quest_id)), x, y, "label",
      { color = Theme.mute, width = w, ellipsis = true, alpha = alpha })
  end
  return y
end

function Stats:draw_history_rows(x, y, w, alpha)
  if not self.history then
    return y + UI.read(I18n.t("asking the server…"), x, y, w, { color = Theme.mute, alpha = alpha })
  end
  if #self.history == 0 then
    return y + UI.read(I18n.t("Nothing here yet. Every run and every submit is kept — "
      .. "including the ones that did not work, which are the ones worth "
      .. "keeping."), x, y, w, { alpha = alpha })
  end
  for i, a in ipairs(self.history) do
    if i > 1 then
      UI.setColor(Theme.line)
      love.graphics.rectangle("fill", x, y, w, 1)
      love.graphics.setColor(1, 1, 1, 1)
      y = y + Theme.space.sm
    end
    local accepted = a.verdict == "accepted"
    -- §4.9b: a run is not an attempt at the record, and the row says which.
    local tag = a.mode == "run" and "run" or "submit"
    local tw = UI.chipWidth(tag)
    UI.chip(x, y, tag, { alpha = alpha, color = a.mode == "run" and nil or Theme.bar })
    local right = ("%s  %d/%d"):format(tostring(a.verdict), a.tests_passed or 0, a.tests_total or 0)
    local rw = UI.labelWidth(right, "label")
    local ly = y + math.floor((Theme.control.chip - UI.lead("label")) / 2)
    UI.label(right, x + w - rw, ly, "label", { color = accepted and Theme.green or Theme.mute, alpha = alpha })
    UI.label(tostring(a.quest_id), x + tw + Theme.space.md, ly, "label",
      { width = w - tw - rw - Theme.space.md * 2, ellipsis = true, alpha = alpha })
    y = y + Theme.control.chip
    if a.kinds and #a.kinds > 0 then
      y = y + UI.label(table.concat(a.kinds, ", "), x + tw + Theme.space.md, y, "label",
        { color = Theme.redA, width = w - tw - Theme.space.md, ellipsis = true, alpha = alpha })
    end
    y = y + Theme.space.sm
  end
  return y - Theme.space.sm
end

-- -------------------------------------------------------------------- input

function Stats:scroll_by(dy)
  self.scroll = math.max(0, self.scroll + dy)
  self.scrolled_at = Anim.now()
end

function Stats:keypressed(key)
  if key == "r" then self:refresh(); SFX.play("move"); return true end
  if key == "h" then
    self:set_tab(self.tab == "mistakes" and "history" or "mistakes")
    return true
  end
  if key == "up" then self:scroll_by(-48); return true end
  if key == "down" then self:scroll_by(48); return true end
  if key == "pageup" then self:scroll_by(-240); return true end
  if key == "pagedown" then self:scroll_by(240); return true end
  return false
end

function Stats:wheelmoved(_, dy)
  self:scroll_by(-dy * 48)
end

local function inside(r, x, y)
  return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

function Stats:mousemoved(x, y)
  self.hover = nil
  if inside(self.back_rect, x, y) then self.hover = "back"; return end
  for tab, r in pairs(self.tab_rects or {}) do
    if inside(r, x, y) then self.hover = tab end
  end
end

function Stats:mousepressed(x, y)
  if inside(self.back_rect, x, y) then
    UI.press("stats:back", self.back_rect, { sfx = false })
    self.app:back()
    return
  end
  for tab, r in pairs(self.tab_rects or {}) do
    if inside(r, x, y) then self:set_tab(tab); return end
  end
end

return Stats
