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
-- said in words underneath.
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
-- silently is worse than one that says why it is empty. Every panel here has
-- a written empty state, and the one for mistakes is deliberately not an
-- apology: having made no mistakes yet is the correct state for somebody who
-- has just arrived.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Anim = require("src.anim")
local Ease = require("src.ease")
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

--- The per-land record, broken into the lines it will actually be drawn as.
---
--- Two lands to a line. `UI.text` without a width goes through
--- `love.graphics.print`, which neither wraps nor clips, so a single joined
--- line of four lands runs off the panel and out of the window — which is
--- exactly what happened when `cpp` and `python` arrived. Breaking it here,
--- rather than in the draw call, is what lets a headless test check it.
---
--- Returns an array of strings, one per line, and never `nil`.
function Stats.land_lines(by_land)
  local parts = {}
  for _, land in ipairs(by_land or {}) do
    parts[#parts + 1] = ("%s %d/%d"):format(
      Land.name(land.land), land.cleared or 0, land.total or 0)
  end
  local lines = {}
  for i = 1, #parts, 2 do
    lines[#lines + 1] = parts[i] .. (parts[i + 1] and ("     " .. parts[i + 1]) or "")
  end
  return lines
end

function Stats.new(app)
  return setmetatable({
    app = app,
    summary = nil, mistakes = nil, awards = nil, history = nil,
    errors = {},
    scroll = 0,
    tab = "mistakes",          -- "mistakes" | "history"
    t = 0,
    arrived = nil,
  }, Stats)
end

function Stats:enter()
  self.arrived = Anim.now()
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

-- ------------------------------------------------------------------ drawing

function Stats:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_datacentre", "bg_flat"), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.78)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

    UI.setColor(Theme.ink, 0.9)
  love.graphics.rectangle("fill", 0, 0, vw, 44)
  love.graphics.setColor(1, 1, 1, 1)
  UI.text(I18n.t("STATS"), 12, 12, 15, Theme.coin)

  local pad = Layout.isPortrait() and 12 or 46
  local w = vw - pad * 2
  local y = 52

  y = self:draw_summary(pad, y, w) + 10
  y = self:draw_shelf(pad, y, w) + 10
  self:draw_mistakes(pad, y, w, vh - y - UI.footerHeight() - 8)

  self.app:footer(I18n.t("R refresh   H history   ARROWS scroll   ESC back"))
end

function Stats:draw_summary(x, y, w)
  -- Measured from the type it holds. Every offset in this panel used to be a
  -- constant tuned against 7 px captions and 14 px figures; at twice that the
  -- caption sat on the figure and the figure sat on the bar.
  local cap_h, fig_h, land_h = UI.lineHeight(7), UI.lineHeight(14), UI.lineHeight(7)
  -- The lands take as many lines as they need, two to a line. One line was
  -- right while there were two lands and silently wrong at four: the row is
  -- drawn with `print`, which does not wrap, so the last land ran off the
  -- panel and out of the window.
  local land_lines = math.max(1, #Stats.land_lines(self.summary and self.summary.by_land))
  local h = 10 + cap_h + 2 + fig_h + 10 + 9 + 6 + land_h * land_lines + 8
  UI.panel(x, y, w, h, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.coin })
  local sm = self.summary
  if not sm then
    UI.text(self.errors["stats.summary"] and self.errors["stats.summary"].player
      or I18n.t("asking the server…"), x, y + 32, 9,
      self.errors["stats.summary"] and Theme.red or Theme.withAlpha(Theme.cream, 0.7),
      "center", w)
    return y + h
  end

  local cells = {
    { I18n.t("CLEARED"), ("%d / %d"):format(sm.cleared or 0, sm.total or 0) },
    { I18n.t("SUBMITS"), tostring(sm.attempts or 0) },
    { I18n.t("ACCURACY"), ("%d%%"):format(math.floor((sm.accuracy or 0) * 100 + 0.5)) },
    { I18n.t("STARS"), tostring(sm.stars or 0) },
    -- Two forms, chosen at the call site and each translatable on its own.
    -- Routing both through one "%d days" made English read "1 days", which is
    -- the one language that must never be the casualty of adding five more.
    { I18n.t("STREAK"), (sm.streak_days or 0) == 1
      and I18n.t("%d day", 1) or I18n.t("%d days", sm.streak_days or 0) },
  }
  local cw = w / #cells
  -- The figure at 14, unless a tile cannot hold it — "0 / 279" in a
  -- portrait fifth at the doubled ladder — where it steps down rather than
  -- wraps: `printf` breaks a figure that is wider than its column into two
  -- lines, and the second line was printed through the lands underneath.
  local fig = 14
  for _, cell in ipairs(cells) do
    while fig > 8 and UI.textWidth(cell[2], fig) > cw - 8 do fig = fig - 2 end
  end
  local fig_top = y + 10 + cap_h + 2 + (fig_h - UI.lineHeight(fig)) / 2
  for i, cell in ipairs(cells) do
    local cx = x + (i - 1) * cw
    UI.text(cell[1], cx, y + 10, 7, Theme.withAlpha(Theme.cream, 0.55), "center", cw)
    UI.text(cell[2], cx, fig_top, fig, Theme.cream, "center", cw)
  end
  UI.bar(x + 14, y + 10 + cap_h + 2 + fig_h + 10, w - 28, 9,
    (sm.total or 0) > 0 and (sm.cleared or 0) / sm.total or 0, Theme.admit)

  -- Per land, under the bar and on its own line: sharing a row with the
  -- STREAK tile put two different numbers in the same place.
  -- Two to a line. `UI.text` without a width uses `print`, which neither
  -- wraps nor clips, so the line is broken here rather than left to run past
  -- the panel edge — and the pairs keep the columns under each other.
  local land_y = y + 10 + cap_h + 2 + fig_h + 10 + 9 + 6
  for i, line in ipairs(Stats.land_lines(sm.by_land)) do
    UI.text(line, x + 14, land_y + (i - 1) * land_h, 7,
      Theme.withAlpha(Theme.cream, 0.55))
  end
  return y + h
end

--- The shelf: what the player has, and sockets for what they do not.
function Stats:draw_shelf(x, y, w)
  local cap_h = UI.lineHeight(7)
  local size = math.max(34, cap_h * 2)
  -- Room for the caption, the row of sockets, and the line underneath that
  -- says what the newest one is — which used to be drawn at `y + h - 16`
  -- into space the panel did not have.
  local h = 8 + cap_h + 6 + size + 6 + cap_h + 8
  UI.panel(x, y, w, h, { fill = Theme.withAlpha(Theme.ink, 0.85), tint = Theme.withAlpha(Theme.coin, 0.5) })
  UI.text(I18n.t("SHELF"), x + 12, y + 8, 7, Theme.withAlpha(Theme.cream, 0.5))

  local awards = self.awards
  if not awards then
    UI.text("…", x + 12, y + 8 + cap_h + 4, 8, Theme.dim)
    return y + h
  end

  local gap = 8
  local slots = math.max(Stats.SHELF_SLOTS, #awards)
  local total = slots * (size + gap) - gap
  local sx = x + math.max(12, (w - total) / 2)
  local sy = y + 8 + cap_h + 6 + size / 2

  for i = 1, slots do
    local award = awards[i]
    local cx = sx + (i - 1) * (size + gap) + size / 2
    if award then
      -- The art for a specific award if it exists, otherwise the one for its
      -- kind. Nothing is invented: `stats.awards` said this was earned.
      local named = "badge_" .. tostring(award.id):gsub("%-", "_")
      local art = Assets.pick(named, KIND_BADGE[award.kind] or "badge_star", "badge_cleared")
      -- A small arrival lift on the newest one.
      local lift = (i == 1 and self.arrived) and Ease.pulse(Anim.now() - self.arrived, 0.9) * 4 or 0
      Assets.marker(art, cx, sy - lift, size)
    else
      -- The socket. DESIGN's point exactly: an empty recess reads as
      -- something to go and get, where a blank space reads as nothing.
      Assets.marker("badge_slot", cx, sy, size, { alpha = 0.55 })
    end
  end

  if #awards == 0 then
    -- Given the panel's width. It is a sentence, and a sentence drawn with
    -- no width is a sentence that leaves the screen — at the **default** type
    -- step, not just at the largest.
    UI.text(I18n.t("nothing on it yet — clear a street and the first one lands"),
      x + 12, y + h - 8 - cap_h, 7, Theme.withAlpha(Theme.cream, 0.45),
      "left", w - 24)
  else
    local newest = awards[1]
    UI.text(tostring(newest.title or newest.id), x + 12, y + h - 8 - cap_h, 7,
      Theme.coin, "left", w - 24)
  end
  return y + h
end

function Stats:draw_mistakes(x, y, w, h)
  local red = self.tab == "mistakes"
  UI.panel(x, y, w, h, {
    fill = Theme.withAlpha(Theme.navy, 0.94),
    tint = red and Theme.brick or Theme.cyan,
  })
  love.graphics.setScissor(x + 4, y + 4, w - 8, h - 8)
  local cy = y + 10 - self.scroll

  if self.tab == "history" then
    self:draw_history_rows(x, cy, w)
    love.graphics.setScissor()
    return
  end

  cy = cy + UI.text(I18n.t("YOUR MISTAKES — THIS IS THE CURRICULUM"), x + 14, cy, 9,
    Theme.brick, "left", w - 28) + 4
  cy = cy + UI.text(I18n.t("a kind leaves the drill after five clean submits"),
    x + 14, cy, 7, Theme.withAlpha(Theme.cream, 0.5), "left", w - 28) + 12

  if not self.mistakes then
    UI.text(self.errors["stats.mistakes"] and self.errors["stats.mistakes"].player
      or I18n.t("asking the server…"), x + 14, cy, 8,
      Theme.withAlpha(Theme.cream, 0.6), "left", w - 28)
    love.graphics.setScissor()
    return
  end

  if #self.mistakes == 0 then
    -- Not an apology. Nothing has gone wrong; there is simply nothing here
    -- yet, and saying what would put something here is more use than silence.
    for _, line in ipairs(UI.wrap(
      I18n.t("Nothing yet. Every compiler error you make gets classified and "
        .. "lands here, and the drills are built from it — so this fills up by "
        .. "playing, not by trying to fill it up."), w - 40, 8)) do
      cy = cy + UI.text(line, x + 14, cy, 8, Theme.withAlpha(Theme.cream, 0.7)) + 4
    end
    love.graphics.setScissor()
    return
  end

  for _, m in ipairs(self.mistakes) do
    cy = self:draw_mistake(x, cy, w, m) + 14
  end
  love.graphics.setScissor()
end

--- One mistake kind, with `cleared_since` given the weight it deserves.
function Stats:draw_mistake(x, y, w, m)
  local since = math.max(0, math.floor(tonumber(m.cleared_since) or 0))
  local learned = since >= Stats.LEARNED_AT

  local kind_h, note_h = UI.lineHeight(9), UI.lineHeight(8)
  local count = ("×%d"):format(m.count or 0)
  UI.text(tostring(m.kind), x + 14, y, 9, learned and Theme.admit or Theme.brick,
    "left", w - 28 - UI.textWidth(count, 9) - 8)
  UI.text(count, x + w - 14 - UI.textWidth(count, 9), y, 9,
    Theme.withAlpha(Theme.cream, 0.7))
  y = y + kind_h + 4

  if m.label and m.label ~= "" and m.label ~= m.kind then
    for _, line in ipairs(UI.wrap(m.label, w - 44, 8)) do
      y = y + UI.text(line, x + 22, y, 8, Theme.cream) + 2
    end
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
  local shackle = x + 34
  Assets.frame("shackle_break", math.min(since, Stats.LEARNED_AT) + 1,
    shackle, y + 20, 19)
  if learned then
    -- What is left of it. Static, on a row that is already in this state —
    -- the stats screen renders what the server says and has no moment of
    -- breaking to animate, and an effect with no event behind it would be
    -- decoration pretending to be feedback.
    Assets.marker("fx_shards", shackle + 16, y + 8, 20, { alpha = 0.85 })
  end

  local step, gap = 14, 5
  local tx = x + 58
  for i = 1, Stats.LEARNED_AT do
    local done = i <= since
    UI.setColor(done and (learned and Theme.admit or Theme.coin)
      or Theme.withAlpha(Theme.dim, 0.5))
    love.graphics.rectangle("fill", tx + (i - 1) * (step + gap), y + 3, step, 8)
  end
  love.graphics.setColor(1, 1, 1, 1)

  y = y + 2
  -- And in words, because the sentence is the motivating part.
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
  -- Beside the five-step track, in whatever is left of the row.
  local said_x = tx + Stats.LEARNED_AT * (step + gap) + 10
  UI.text(said, said_x, y + 3, 7, learned and Theme.admit or Theme.coin,
    "left", math.max(40, x + w - 14 - said_x))
  -- The shackle is taller than the track, and the sentence beside it is a
  -- line of type that grows with the ladder — so this clears whichever of the
  -- three is tallest rather than a number that was right for one of them.
  y = y + math.max(22, UI.lineHeight(7) + 10, note_h + 8)

  if m.concepts and #m.concepts > 0 then
    y = y + UI.text(I18n.t("drill: %s", table.concat(m.concepts, ", ")), x + 22, y, 7,
      Theme.withAlpha(Theme.cyan, 0.85), "left", w - 44) + 3
  end
  if m.example_quest_id then
    y = y + UI.text(I18n.t("last seen on %s", tostring(m.example_quest_id)), x + 22, y, 7,
      Theme.withAlpha(Theme.cream, 0.4), "left", w - 44) + 2
  end
  return y
end

function Stats:draw_history_rows(x, y, w)
  y = y + UI.text(I18n.t("RECENT SUBMITS AND RUNS"), x + 14, y, 9, Theme.cyan,
    "left", w - 28) + 12
  if not self.history then
    UI.text(I18n.t("asking the server…"), x + 14, y, 8,
      Theme.withAlpha(Theme.cream, 0.6), "left", w - 28)
    return
  end
  if #self.history == 0 then
    for _, line in ipairs(UI.wrap(
      I18n.t("Nothing here yet. Every run and every submit is kept — "
        .. "including the ones that did not work, which are the ones worth "
        .. "keeping."), w - 40, 8)) do
      y = y + UI.text(line, x + 14, y, 8, Theme.withAlpha(Theme.cream, 0.7)) + 4
    end
    return
  end
  for _, a in ipairs(self.history) do
    local colour = a.verdict == "accepted" and Theme.admit
      or Theme.withAlpha(Theme.cream, 0.8)
    -- §4.9b: a run is not an attempt at the record, and the row says which.
    local tag = a.mode == "run" and "run" or "submit"
    UI.text(("%-6s %s"):format(tag, tostring(a.quest_id)), x + 14, y, 7, colour)
    local right = ("%s  %d/%d"):format(tostring(a.verdict),
      a.tests_passed or 0, a.tests_total or 0)
    UI.text(right, x + w - 14 - UI.textWidth(right, 7), y, 7,
      Theme.withAlpha(colour, 0.8))
    y = y + UI.lineHeight(7) + 3
    if a.kinds and #a.kinds > 0 then
      y = y + UI.text("  " .. table.concat(a.kinds, ", "), x + 14, y, 7,
        Theme.withAlpha(Theme.brick, 0.8)) + 2
    end
    y = y + 4
  end
end

-- -------------------------------------------------------------------- input

function Stats:keypressed(key)
  if key == "r" then self:refresh(); SFX.play("move"); return true end
  if key == "h" then
    self.tab = self.tab == "mistakes" and "history" or "mistakes"
    self.scroll = 0
    SFX.play("move")
    return true
  end
  if key == "up" then self.scroll = math.max(0, self.scroll - 28); return true end
  if key == "down" then self.scroll = self.scroll + 28; return true end
  if key == "pageup" then self.scroll = math.max(0, self.scroll - 180); return true end
  if key == "pagedown" then self.scroll = self.scroll + 180; return true end
  return false
end

function Stats:wheelmoved(_, dy)
  self.scroll = math.max(0, self.scroll - dy * 28)
end

return Stats
