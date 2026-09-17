-- LAND SELECT. `world.lands` (PROTOCOL §4.6), drawn as a card per land.
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
local I18n = require("src.i18n")
local Land = require("src.land")

local Lands = {}
Lands.__index = Lands

local LAND_ORDER = Land.ORDER
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
local BLURB = {
  rust = "ownership, borrows, lifetimes",
  go = "goroutines, channels, interfaces",
  cpp = "threads, mutexes, the STL",
  python = "dicts, generators, the GIL",
}

function Lands.new(app)
  return setmetatable({
    app = app, lands = nil, cursor = 1, error = nil, t = 0,
    -- When the cursor last landed here, so the chosen card can lift, and
    -- when it was pressed, so it can push in.
    picked_at = 0,
    pressed_at = nil,
    -- Which of the two buttons under the cards the pointer is over.
    hover = nil,
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
  local out = {}
  for i, land in ipairs(lands or {}) do
    out[i] = land
  end
  table.sort(out, function(a, b)
    local ra, rb = Land.rank(a.land), Land.rank(b.land)
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

--- Where the cards go — **one function, read by the draw and by the click.**
---
--- These were two copies of the same eight lines, and the copies had already
--- started to matter: the hit test knew the card was capped at 300 px and the
--- draw knew it too, so changing one would have moved the cards without
--- moving what you could press.
---
--- **Portrait stacks and uses the height it is given.** That is the other
--- half of the "type is too small" report: on a 1080×1920 the stack was two
--- 300 px cards at the top of a 1920 px frame and two thirds of the screen
--- was bare backdrop, which reads as small however big the letters are. The
--- cap is gone; in portrait the cards divide the column, and the card draws
--- itself into whatever height it is handed.
function Lands:card_rects()
  local vw, vh = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  local n = math.max(1, self.lands and #self.lands or #LAND_ORDER)
  -- Measured from the type, not fixed: the title above the cards and the
  -- footer below them both grow when the player asks for bigger type.
  local pad = 16
  local top = math.floor(24 + UI.lineHeight(Lands.title_size(Layout.vw)) + 18)
  local bottom = Lands.band_top() - 10
  local out = {}
  if portrait then
    local gap = 14
    local cw = vw - pad * 2
    local ch = (bottom - top - gap * (n - 1)) / n
    for i = 1, n do
      out[i] = { x = pad, y = top + (i - 1) * (ch + gap), w = cw, h = ch }
    end
  else
    local gap = 18
    local cw = math.min(460, (vw - pad * 2 - gap * (n - 1)) / n)
    local ch = bottom - top
    local total = n * cw + (n - 1) * gap
    for i = 1, n do
      out[i] = { x = (vw - total) / 2 + (i - 1) * (cw + gap),
                 y = top + (bottom - top - ch) / 2, w = cw, h = ch }
    end
  end
  return out, n
end

--- The band under the cards: two buttons, WEAKEST and PLAYGROUND — the
--- browser's AUTO SELECT and PLAYGROUND row. Both are "somewhere other than
--- a land to go", and they are the same size because neither is the primary
--- action here. `W` and `P` still work; the buttons are an addition, because
--- a key nobody can see is not a feature.
function Lands.band_height()
  return math.max(36, UI.lineHeight(10) + 18)
end

--- Where the band starts: above the note line, which is above the footer.
function Lands.band_top()
  return Layout.vh - UI.footerHeight() - math.floor(UI.lineHeight(9) * 1.6) - Lands.band_height()
end

--- The two buttons — **one function, read by the draw and by the click.**
function Lands:button_rects()
  local vw = Layout.vw
  local pad, gap = 16, 12
  local bh = Lands.band_height()
  local y = Lands.band_top()
  local labels = {
    weakest = I18n.t("WEAKEST") .. "  W",
    playground = I18n.t("PLAYGROUND") .. "  P",
  }
  local want = math.max(200, UI.textWidth(labels.weakest, 10) + 40,
    UI.textWidth(labels.playground, 10) + 40)
  local bw = math.min(math.floor((vw - pad * 2 - gap) / 2), want)
  local x = math.floor((vw - bw * 2 - gap) / 2)
  return {
    weakest = { x = x, y = y, w = bw, h = bh, label = labels.weakest },
    playground = { x = x + bw + gap, y = y, w = bw, h = bh, label = labels.playground },
  }
end

--- The largest size on the ladder at which the title still fits across the
--- canvas on one line. At step 4 in portrait, 18 is wider than 720 px and
--- the title wrapped into the first card; the cards start under whatever
--- size this returns, so the two can never meet.
function Lands.title_size(vw)
  local label = I18n.t("PICK A LAND")
  for _, size in ipairs({ 18, 16, 14, 12, 10, 8 }) do
    if UI.textWidth(label, size) <= vw - 40 then return size end
  end
  return 8
end

function Lands:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_street", "bg_flat"), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.6)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  UI.text(I18n.t("PICK A LAND"), 0, 24, Lands.title_size(vw), Theme.coin, "center", vw)

  local rects, n = self:card_rects()
  for i = 1, n do
    local r = rects[i]
    self:draw_card(r.x, r.y, r.w, r.h, self:land_at(i), LAND_ORDER[i], i == self.cursor)
  end

  local buttons = self:button_rects()
  for _, id in ipairs({ "weakest", "playground" }) do
    local b = buttons[id]
    local state = (id == "weakest" and self.auto_busy) and "disabled"
      or (self.hover == id and "hot" or "normal")
    UI.button(b.x, b.y, b.w, b.h, b.label, state, 10)
  end

  local note = self.error or (not self.lands and I18n.t("asking the server…")) or nil
  if note then
    UI.text(note, 0, vh - UI.footerHeight() - UI.lineHeight(9) - 6, 9,
      self.error and Theme.red or Theme.withAlpha(Theme.cream, 0.7), "center", vw)
  end

  self.app:footer(self.auto_note
    or I18n.t("ARROWS choose   ENTER go   W weakest   P playground"))
end

--- One card, drawn into whatever rectangle it is handed.
---
--- Every offset in here used to be a constant calibrated against 8 px type —
--- the mascot at `y + 118`, the title at `y + 124`, the blurb at `y + 144`,
--- the rows from `y + 168` at 32 px each. Doubling the type ladder put the
--- title through the mascot and the blurb through the title, which is the
--- predictable half of a typography change and the reason this is now
--- measured: the head block is as tall as the type in it, the rows are as
--- tall as the type in them, and the mascot takes whatever is left.
function Lands:draw_card(x, y, w, h, land, fallback, selected)
  local key = land and land.land or fallback
  local tint = Theme.land[key] or Theme.dim
  local t = Anim.now()

  local lift = selected and Anim.lift(self:selected_age()) * 4 or 0
  local push = (selected and self.pressed_at) and Anim.press(t - self.pressed_at) * 3 or 0
  y = y - lift + push

  if selected then
    UI.setColor(Theme.ink, 0.30)
    love.graphics.rectangle("fill", x + 4, y + h + 2, w - 8, 3 + lift)
    love.graphics.setColor(1, 1, 1, 1)
  end

  UI.panel(x, y, w, h, {
    fill = Theme.withAlpha(Theme.navy, selected and 0.95 or 0.88),
    tint = selected and Theme.coin or tint,
  })

  local pad = 12
  -- The title at 14, or the first size under it that fits the card: in a
  -- landscape quarter of a 1080-wide canvas "PYTHON 랜드" is wider than the
  -- card, and `printf` then wraps the suffix onto a second line that the
  -- blurb is printed through.
  local title = I18n.t("%s LAND", Land.name(key))
  local title_size = UI.fitSize(title, w - pad * 2, 14, 5)
  -- Two lines when even the smallest title is wider than the card, and the
  -- head is measured for both: a wrapped title was printed through the
  -- rows under it.
  local title_lines = UI.wrap(title, w - pad * 2, title_size)
  local title_h = UI.lineHeight(title_size) * math.max(1, #title_lines)
  local rows = land and #land.categories or 3
  -- The row's type: 9, or the first size under it at which the widest
  -- category name and its count share the row. At the largest type step
  -- in a landscape card `ADVANCED 0/17` is twice the card's width at 9.
  local sprite_size = 34
  local row_room = w - pad * 2 - sprite_size - 8 - 26 - 8
  local row_size = 9
  local show_count = true
  for _, cat in ipairs(land and land.categories or {}) do
    local probe = I18n.t(cat.category:upper()) .. "  " .. ("%d/%d"):format(cat.cleared, cat.total)
    row_size = math.min(row_size, UI.fitSize(probe, row_room, 9, 5))
    -- When the floor still cannot hold both, the count goes and the bar
    -- under the name carries the progress on its own.
    if UI.textWidth(probe, row_size) > row_room then show_count = false end
  end
  if not show_count then
    row_size = 9
    for _, cat in ipairs(land and land.categories or {}) do
      row_size = math.min(row_size, UI.fitSize(I18n.t(cat.category:upper()), row_room, 9, 5))
    end
  end
  -- A row is its own type plus a bar and air, never less than the sprite.
  local row_h = math.max(UI.lineHeight(row_size) + 20, 32)
  local rows_h = rows * row_h

  -- **The blurb is measured, not assumed to be one line.** In landscape the
  -- card is narrow and "ownership, borrows, lifetimes" wraps to two; reserving
  -- one line's height for it put the second line through the category rows.
  -- It will wrap again, and differently, in six languages.
  local blurb = I18n.t(BLURB[key] or "")
  local blurb_lines = blurb ~= "" and UI.wrap(blurb, w - pad * 2, 8) or {}
  local blurb_h = #blurb_lines * UI.lineHeight(8)

  local head_h = title_h + 2 + blurb_h
  local free = h - pad * 2 - rows_h - head_h - 6
  -- The blurb is the first thing to go when the card cannot hold the
  -- mascot, the title, the blurb and the rows: at the largest type step
  -- in a 720-tall landscape window it cannot, and the rows were printed
  -- through the blurb and the title through the rows.
  if free < 48 and #blurb_lines > 0 then
    blurb_lines = {}
    blurb_h = 0
    head_h = title_h + 2
    free = h - pad * 2 - rows_h - head_h - 6
  end
  -- The mascot takes the slack, and the block sits a little above centre in
  -- what is left — a portrait card is tall enough that a bottom-anchored
  -- stack leaves a hole in the middle of it.
  -- And when even that leaves no room, the mascot gives way before the
  -- rows do: a 48 px floor under it pushed the title into the first row.
  local mascot = free >= 48 and math.max(48, math.min(h * 0.42, free)) or math.max(0, free)
  local top = y + pad + math.max(0, (free - mascot) * 0.45)

  local bob = Anim.bob(t, { amount = selected and 3 or 1.5, phase = Land.phase(key) })
  Assets.sprite(Land.mascot(key), x + w / 2, top + mascot + bob, mascot)

  local ty = top + mascot + 6
  for i, line in ipairs(title_lines) do
    UI.text(line, x, ty + (i - 1) * UI.lineHeight(title_size), title_size, tint, "center", w)
  end
  for i, line in ipairs(blurb_lines) do
    UI.text(line, x, ty + title_h + 2 + (i - 1) * UI.lineHeight(8), 8,
      Theme.withAlpha(Theme.cream, 0.7), "center", w)
  end

  local row = y + h - pad - rows_h
  if land then
    sprite_size = math.min(row_h - 6, 34)
    for i, cat in ipairs(land.categories) do
      local color = cat.open and Theme.cream or Theme.dim
      local sprite = ("mascot_%s_%s"):format(key, cat.category)
      local rbob = Anim.bob(t, { amount = 1.4, period = 1.9, phase = 0.17 * i })
      Assets.sprite(sprite, x + pad + sprite_size / 2,
        row + (row_h + sprite_size) / 2 - 3 + rbob, sprite_size,
        { alpha = cat.open and 1 or 0.4 })

      local label_x = x + pad + sprite_size + 8
      local count = ("%d/%d"):format(cat.cleared, cat.total)
      local count_w = UI.textWidth(count, row_size)
      local badge = 26
      UI.text(I18n.t(cat.category:upper()), label_x, row + 3, row_size, color)
      if show_count then
        UI.text(count, x + w - pad - badge - count_w, row + 3, row_size, color)
      end

      local bar_y = row + 6 + UI.lineHeight(row_size)
      UI.bar(label_x, bar_y, x + w - pad - badge - 6 - label_x, 5,
        cat.total > 0 and cat.cleared / cat.total or 0,
        cat.open and Theme.admit or Theme.dim)

      if cat.total > 0 and cat.cleared >= cat.total then
        Assets.marker("badge_cleared", x + w - pad - 10, row + row_h / 2 + 8, 22)
      elseif not cat.open then
        Assets.marker("badge_locked", x + w - pad - 10, row + row_h / 2 + 8, 20, { alpha = 0.85 })
      end
      row = row + row_h
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

-- Go straight to the stage this player fails most (§4.14c).
--
-- An empty answer is the normal one for somebody who has failed nothing: it
-- says so and stays put, rather than sending them somewhere arbitrary or
-- reporting an error for having done well.
function Lands:auto_select()
  if self.auto_busy then return end
  self.auto_busy = true
  self.auto_note = I18n.t("looking for the stage beating you most…")
  SFX.play("select")
  self.app.session:request("stats.weakest", { limit = 1 }, function(ok, payload)
    self.auto_busy = false
    local pick = ok and payload.weakest and payload.weakest[1]
    if not pick then
      self.auto_note = I18n.t("nothing has beaten you yet — pick a land")
      return
    end
    self.auto_note = nil
    self.app:go("quest", {
      quest_id = pick.quest_id,
      land = pick.land,
      category = pick.category,
    })
  end)
end

--- The wheel moves the cursor, because on a desktop that is what a wheel is
--- for. Every screen in this client that has a list has one of these now: a
--- mouse that scrolled on four screens and did nothing on five reads as five
--- screens that are broken, not as four that are special.
function Lands:wheelmoved(_, dy)
  if not self.lands or #self.lands == 0 then return end
  local n = #self.lands
  self.cursor = ((self.cursor - 1 + (dy > 0 and -1 or 1)) % n) + 1
  self.picked_at = Anim.now()
  SFX.play("move")
end

function Lands:keypressed(key)
  local n = math.max(1, self.lands and #self.lands or #LAND_ORDER)
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
  -- W for the stage that is winning. The ranking is the server's (§4.14c), the
  -- same one users/<address>/progress.json carries: a client that worked it
  -- out itself would disagree with the file the player can read.
  if key == "w" then self:auto_select(); return true end
  if key == "r" then self:refresh(); return true end
  return false
end

--- Inside `r`?
local function inside(r, x, y)
  return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

function Lands:mousemoved(x, y)
  local buttons = self:button_rects()
  local over = nil
  for _, id in ipairs({ "weakest", "playground" }) do
    if inside(buttons[id], x, y) then over = id end
  end
  self.hover = over
end

function Lands:mousepressed(x, y)
  local buttons = self:button_rects()
  if inside(buttons.playground, x, y) then
    SFX.play("select")
    self.app:go("playground")
    return
  end
  if inside(buttons.weakest, x, y) then
    self:auto_select()
    return
  end
  local rects, n = self:card_rects()
  for i = 1, n do
    local r = rects[i]
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
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
