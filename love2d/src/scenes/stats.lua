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
local SFX = require("src.sfx")
local Anim = require("src.anim")
local Ease = require("src.ease")

local Stats = {}
Stats.__index = Stats

--- §7.3: a kind with this many clean submits behind it has been learned and
--- leaves the drill.
Stats.LEARNED_AT = 5

--- How many sockets the shelf shows. Enough to read as a collection with room
--- in it, not so many that a new player sees a wall of absence.
Stats.SHELF_SLOTS = 8

local KIND_BADGE = { badge = "badge_star", level = "badge_chevron", streak = "badge_flame" }

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

  local s = Layout.uiScale()
  UI.setColor(Theme.ink, 0.9)
  love.graphics.rectangle("fill", 0, 0, vw, 44)
  love.graphics.setColor(1, 1, 1, 1)
  UI.text("STATS", 12, 12, math.floor(15 * s), Theme.coin)

  local pad = Layout.isPortrait() and 12 or 46
  local w = vw - pad * 2
  local y = 52

  y = self:draw_summary(pad, y, w, s) + 10
  y = self:draw_shelf(pad, y, w) + 10
  self:draw_mistakes(pad, y, w, vh - y - 44)

  self.app:footer("R refresh   H history   ARROWS scroll   ESC back")
end

function Stats:draw_summary(x, y, w, s)
  local h = 92
  UI.panel(x, y, w, h, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.coin })
  local sm = self.summary
  if not sm then
    UI.text(self.errors["stats.summary"] and self.errors["stats.summary"].player
      or "asking the server…", x, y + 32, 9,
      self.errors["stats.summary"] and Theme.red or Theme.withAlpha(Theme.cream, 0.7),
      "center", w)
    return y + h
  end

  local cells = {
    { "CLEARED", ("%d / %d"):format(sm.cleared or 0, sm.total or 0) },
    { "SUBMITS", tostring(sm.attempts or 0) },
    { "ACCURACY", ("%d%%"):format(math.floor((sm.accuracy or 0) * 100 + 0.5)) },
    { "STARS", tostring(sm.stars or 0) },
    { "STREAK", ("%d day%s"):format(sm.streak_days or 0,
      (sm.streak_days or 0) == 1 and "" or "s") },
  }
  local cw = w / #cells
  for i, cell in ipairs(cells) do
    local cx = x + (i - 1) * cw
    UI.text(cell[1], cx, y + 12, 7, Theme.withAlpha(Theme.cream, 0.55), "center", cw)
    UI.text(cell[2], cx, y + 26, math.floor(14 * s), Theme.cream, "center", cw)
  end
  UI.bar(x + 14, y + 58, w - 28, 9, 
    (sm.total or 0) > 0 and (sm.cleared or 0) / sm.total or 0, Theme.admit)

  -- Per land, under the bar and on its own line: sharing a row with the
  -- STREAK tile put two different numbers in the same place.
  local parts = {}
  for _, land in ipairs(sm.by_land or {}) do
    parts[#parts + 1] = ("%s %d/%d"):format(land.land:upper(), land.cleared, land.total)
  end
  if #parts > 0 then
    UI.text(table.concat(parts, "     "), x + 14, y + 72, 7,
      Theme.withAlpha(Theme.cream, 0.55))
  end
  return y + h
end

--- The shelf: what the player has, and sockets for what they do not.
function Stats:draw_shelf(x, y, w)
  local h = 62
  UI.panel(x, y, w, h, { fill = Theme.withAlpha(Theme.ink, 0.85), tint = Theme.withAlpha(Theme.coin, 0.5) })
  UI.text("SHELF", x + 12, y + 8, 7, Theme.withAlpha(Theme.cream, 0.5))

  local awards = self.awards
  if not awards then
    UI.text("…", x + 12, y + 26, 8, Theme.dim)
    return y + h
  end

  local size = 34
  local gap = 8
  local slots = math.max(Stats.SHELF_SLOTS, #awards)
  local total = slots * (size + gap) - gap
  local sx = x + math.max(12, (w - total) / 2)
  local sy = y + 22 + size / 2

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
    UI.text("nothing on it yet — clear a street and the first one lands",
      x + 12, y + h - 16, 7, Theme.withAlpha(Theme.cream, 0.45))
  else
    local newest = awards[1]
    UI.text(tostring(newest.title or newest.id), x + 12, y + h - 16, 7, Theme.coin)
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

  cy = cy + UI.text("YOUR MISTAKES — THIS IS THE CURRICULUM", x + 14, cy, 9, Theme.brick) + 4
  cy = cy + UI.text("a kind leaves the drill after five clean submits", x + 14, cy, 7,
    Theme.withAlpha(Theme.cream, 0.5)) + 12

  if not self.mistakes then
    UI.text(self.errors["stats.mistakes"] and self.errors["stats.mistakes"].player
      or "asking the server…", x + 14, cy, 8, Theme.withAlpha(Theme.cream, 0.6))
    love.graphics.setScissor()
    return
  end

  if #self.mistakes == 0 then
    -- Not an apology. Nothing has gone wrong; there is simply nothing here
    -- yet, and saying what would put something here is more use than silence.
    for _, line in ipairs(UI.wrap(
      "Nothing yet. Every compiler error you make gets classified and lands "
        .. "here, and the drills are built from it — so this fills up by "
        .. "playing, not by trying to fill it up.", w - 40, 8)) do
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

  UI.text(tostring(m.kind), x + 14, y, 9, learned and Theme.admit or Theme.brick)
  local count = ("×%d"):format(m.count or 0)
  UI.text(count, x + w - 14 - UI.textWidth(count, 9), y, 9,
    Theme.withAlpha(Theme.cream, 0.7))
  y = y + 16

  if m.label and m.label ~= "" and m.label ~= m.kind then
    for _, line in ipairs(UI.wrap(m.label, w - 44, 8)) do
      y = y + UI.text(line, x + 22, y, 8, Theme.cream) + 2
    end
  end

  -- **The track.** Five steps, the ones behind you filled. The shape says how
  -- far there is to go, which a bare number cannot.
  local step, gap = 14, 5
  local tx = x + 22
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
    said = "learned — out of the drill"
  elseif since == 0 then
    said = "you did this on your last submit"
  elseif since == 1 then
    said = "one clean submit since"
  else
    said = ("%d clean submits since — %d to go"):format(since, Stats.LEARNED_AT - since)
  end
  UI.text(said, tx + Stats.LEARNED_AT * (step + gap) + 10, y + 3, 7,
    learned and Theme.admit or Theme.coin)
  y = y + 18

  if m.concepts and #m.concepts > 0 then
    y = y + UI.text("drill: " .. table.concat(m.concepts, ", "), x + 22, y, 7,
      Theme.withAlpha(Theme.cyan, 0.85)) + 2
  end
  if m.example_quest_id then
    y = y + UI.text("last seen on " .. tostring(m.example_quest_id), x + 22, y, 7,
      Theme.withAlpha(Theme.cream, 0.4)) + 2
  end
  return y
end

function Stats:draw_history_rows(x, y, w)
  y = y + UI.text("RECENT SUBMITS AND RUNS", x + 14, y, 9, Theme.cyan) + 12
  if not self.history then
    UI.text("asking the server…", x + 14, y, 8, Theme.withAlpha(Theme.cream, 0.6))
    return
  end
  if #self.history == 0 then
    for _, line in ipairs(UI.wrap(
      "Nothing here yet. Every run and every submit is kept — including the "
        .. "ones that did not work, which are the ones worth keeping.",
      w - 40, 8)) do
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
    y = y + 11
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
