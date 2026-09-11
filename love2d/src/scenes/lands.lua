-- LAND SELECT. `world.lands` (PROTOCOL §4.6), drawn as two cards.
--
-- The counts, the `open` flags and the star totals are all the server's. This
-- screen adds nothing to them: if `go` comes back with every category shut,
-- that is what it draws.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local SFX = require("src.sfx")
local Anim = require("src.anim")

local Lands = {}
Lands.__index = Lands

local LAND_ORDER = { "rust", "go" }
local CATEGORY_ORDER = { basic = 1, advanced = 2, hacker = 3 }

--- SPEC §0's order. `world.lands` does not promise one, and the rows were
--- arriving alphabetical — ADVANCED, BASIC, HACKER — which reads as a list of
--- words rather than a path through a subject. `src/scenes/categories.lua`
--- already sorted; this screen had been left out of that change.
local function ordered_categories(categories)
  local out = {}
  for i, cat in ipairs(categories or {}) do out[i] = cat end
  table.sort(out, function(a, b)
    local ra = CATEGORY_ORDER[a.category] or 99
    local rb = CATEGORY_ORDER[b.category] or 99
    if ra ~= rb then return ra < rb end
    return tostring(a.category) < tostring(b.category)
  end)
  return out
end
local MASCOT = { rust = "sprite_ferris", go = "sprite_gogo" }
local BLURB = {
  rust = "ownership, borrows, lifetimes",
  go = "goroutines, channels, interfaces",
}

function Lands.new(app)
  return setmetatable({
    app = app, lands = nil, cursor = 1, error = nil, t = 0,
    -- When the cursor last landed here, so the chosen card can lift, and
    -- when it was pressed, so it can push in.
    picked_at = 0,
    pressed_at = nil,
  }, Lands)
end

function Lands:enter()
  self:refresh()
end

--- A stable order for the cards, and a stable starting cursor.
---
--- `world.lands` does not promise an order and does not need to: which land
--- is drawn first is presentation, not a rule. Sorting here means the cards
--- do not swap places between two calls, and it means "press enter" lands on
--- the same thing every time — which a player relies on and a drive script
--- depends on. Anything the server sends that is not in `LAND_ORDER` is kept
--- and shown after the ones that are, rather than dropped.
local function ordered(lands)
  local rank = {}
  for i, name in ipairs(LAND_ORDER) do rank[name] = i end
  local out = {}
  for i, land in ipairs(lands or {}) do
    out[i] = land
  end
  table.sort(out, function(a, b)
    local ra = rank[a.land] or (#LAND_ORDER + 1)
    local rb = rank[b.land] or (#LAND_ORDER + 1)
    if ra ~= rb then return ra < rb end
    return tostring(a.land) < tostring(b.land)
  end)
  return out
end

function Lands:refresh()
  self.error = nil
  self.app.session:request("world.lands", {}, function(ok, payload, why)
    if not ok then
      self.error = why.player
      return
    end
    self.lands = ordered(payload.lands)
    for _, land in ipairs(self.lands) do
      land.categories = ordered_categories(land.categories)
    end
    -- Come back to the land the player was last in.
    for i, land in ipairs(self.lands) do
      if land.land == self.app.land then self.cursor = i end
    end
    self.cursor = math.max(1, math.min(#self.lands, self.cursor))
  end)
end

function Lands:land_at(index)
  if not self.lands then return nil end
  return self.lands[index]
end

function Lands:choose()
  local land = self:land_at(self.cursor)
  if not land then return end
  self.pressed_at = Anim.now()
  SFX.play("select")
  self.app.land = land.land
  self.app:go("categories", { land = land.land, categories = land.categories })
end

function Lands:update(dt)
  self.t = self.t + dt
end

--- Seconds since this card became the selected one.
function Lands:selected_age()
  return Anim.now() - self.picked_at
end

function Lands:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_street", "bg_flat"), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.6)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local s = Layout.uiScale()
  UI.text("PICK A LAND", 0, 24, math.floor(18 * s), Theme.coin, "center", vw)

  local portrait = Layout.isPortrait()
  local n = math.max(1, self.lands and #self.lands or 2)
  local pad = 16
  local top = 70
  local bottom = vh - 60
  local cw, ch, gap
  if portrait then
    gap = 14
    cw = vw - pad * 2
    ch = math.min(300, (bottom - top - gap * (n - 1)) / n)
  else
    gap = 18
    cw = math.min(420, (vw - pad * 2 - gap * (n - 1)) / n)
    ch = math.min(292, bottom - top)
  end

  for i = 1, n do
    local land = self:land_at(i)
    local x, y
    if portrait then
      x = pad
      y = top + (i - 1) * (ch + gap)
    else
      local total = n * cw + (n - 1) * gap
      x = (vw - total) / 2 + (i - 1) * (cw + gap)
      y = top + (bottom - top - ch) / 2
    end
    self:draw_card(x, y, cw, ch, land, LAND_ORDER[i], i == self.cursor, s)
  end

  if self.error then
    UI.text(self.error, 0, vh - 52, 9, Theme.red, "center", vw)
  elseif not self.lands then
    UI.text("asking the server…", 0, vh - 52, 9,
      Theme.withAlpha(Theme.cream, 0.7), "center", vw)
  end

  self.app:footer("ARROWS choose   ENTER go   P playground")
end

--- One land, as a card.
---
--- The user's note was "add more sprites in each button — not fun", and this
--- is the answer: the land's own mascot on top, and every category row
--- carrying the little action sprite for that land *and* that category
--- (`art/mascot_<land>_<category>.png` — Ferris up a crate, Ferris working
--- two tills, Ferris stuck at a blank board). A column of identical text was
--- the problem; eight drawn characters and a progress rule are not.
function Lands:draw_card(x, y, w, h, land, fallback, selected, s)
  local key = land and land.land or fallback
  local tint = Theme.land[key] or Theme.dim
  local t = Anim.now()

  -- The selected card lifts. Physical rather than merely outlined: the eye
  -- reads height before it reads a border colour.
  local lift = selected and Anim.lift(self:selected_age()) * 4 or 0
  local push = (selected and self.pressed_at) and Anim.press(t - self.pressed_at) * 3 or 0
  y = y - lift + push

  if selected then
    -- A shadow under the raised card, so a lift is a lift and not a jump.
    UI.setColor(Theme.ink, 0.30)
    love.graphics.rectangle("fill", x + 4, y + h + 2, w - 8, 3 + lift)
    love.graphics.setColor(1, 1, 1, 1)
  end

  UI.panel(x, y, w, h, {
    fill = Theme.withAlpha(Theme.navy, selected and 0.95 or 0.88),
    tint = selected and Theme.coin or tint,
  })

  -- The land mascot, idling on her feet with the measured `box`.
  local bob = Anim.bob(t, { amount = selected and 3 or 1.5, phase = key == "go" and 0.5 or 0 })
  Assets.sprite(MASCOT[key], x + w / 2, y + 118 + bob, 88)

  UI.text((key or "?"):upper() .. " LAND", x, y + 124, math.floor(14 * s), tint, "center", w)
  UI.text(BLURB[key] or "", x, y + 144, 8, Theme.withAlpha(Theme.cream, 0.7), "center", w)

  local row = y + 168
  local rh = 32
  if land then
    for i, cat in ipairs(land.categories) do
      local color = cat.open and Theme.cream or Theme.dim
      -- Each row's own action sprite, on its own phase so the three do not
      -- bob in lockstep — a row of synchronised sprites reads as mechanical.
      local sprite = ("mascot_%s_%s"):format(key, cat.category)
      local rbob = Anim.bob(t, { amount = 1.4, period = 1.9, phase = 0.17 * i })
      Assets.sprite(sprite, x + 28, row + 26 + rbob, 28,
        { alpha = cat.open and 1 or 0.4 })

      UI.text(cat.category:upper(), x + 48, row + 2, 9, color)
      local count = ("%d/%d"):format(cat.cleared, cat.total)
      UI.text(count, x + w - 20 - UI.textWidth(count, 9), row + 2, 9, color)

      UI.bar(x + 48, row + 17, w - 72, 5,
        cat.total > 0 and cat.cleared / cat.total or 0,
        cat.open and Theme.admit or Theme.dim)

      -- The badges. `badge_cleared` when a whole category is done;
      -- `badge_locked` **only** when it genuinely cannot be entered — nothing
      -- on the map is locked any more (§4.7), and a decorative padlock is the
      -- exact lie that change existed to remove.
      if cat.total > 0 and cat.cleared >= cat.total then
        Assets.marker("badge_cleared", x + w - 24, row + 14, 22)
      elseif not cat.open then
        Assets.marker("badge_locked", x + w - 24, row + 14, 20, { alpha = 0.85 })
      end
      row = row + rh
    end
  else
    UI.text("…", x, row, 10, Theme.dim, "center", w)
  end

  if selected then
    love.graphics.setLineWidth(3)
    UI.setColor(Theme.coin)
    love.graphics.rectangle("line", x - 3, y - 3, w + 6, h + 6)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

function Lands:keypressed(key)
  local n = math.max(1, self.lands and #self.lands or 2)
  if key == "left" or key == "up" then
    self.cursor = ((self.cursor - 2) % n) + 1
    self.picked_at = Anim.now()
    SFX.play("move")
    return true
  end
  if key == "right" or key == "down" then
    self.cursor = (self.cursor % n) + 1
    self.picked_at = Anim.now()
    SFX.play("move")
    return true
  end
  if key == "return" or key == "kpenter" or key == "space" then
    self:choose()
    return true
  end
  -- Mei's own desk, reachable without picking a land first: it belongs to
  -- nobody's curriculum (§4.9c).
  if key == "p" then self.app:go("playground"); return true end
  if key == "r" then self:refresh(); return true end
  return false
end

function Lands:mousepressed(x, y)
  local vw, vh = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  local n = math.max(1, self.lands and #self.lands or 2)
  local pad, top, bottom = 16, 70, vh - 60
  local cw, ch, gap
  if portrait then
    gap = 14; cw = vw - pad * 2; ch = math.min(300, (bottom - top - gap * (n - 1)) / n)
  else
    gap = 18
    cw = math.min(420, (vw - pad * 2 - gap * (n - 1)) / n)
    ch = math.min(292, bottom - top)
  end
  for i = 1, n do
    local cx, cy
    if portrait then
      cx, cy = pad, top + (i - 1) * (ch + gap)
    else
      local total = n * cw + (n - 1) * gap
      cx = (vw - total) / 2 + (i - 1) * (cw + gap)
      cy = top + (bottom - top - ch) / 2
    end
    if x >= cx and x <= cx + cw and y >= cy and y <= cy + ch then
      -- First click selects, second opens: on a card that lifts, the lift is
      -- the feedback that says which one the next click will take.
      if self.cursor ~= i then
        self.cursor = i
        self.picked_at = Anim.now()
        SFX.play("move")
        return
      end
      self:choose()
      return
    end
  end
end

return Lands
