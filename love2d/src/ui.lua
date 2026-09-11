-- The 16-bit furniture: panels, buttons, labels, stars, the toast line.
--
-- The chrome is `CausewaybayGolang`'s — a hard two-pixel border in `ink` over
-- a `panel` fill, no bevel and no shadow, per `docs/art.md` §1. Everything
-- takes virtual coordinates and nothing here knows which scene it is in.

local Theme = require("src.theme")
local Assets = require("src.assets")
local Layout = require("src.layout")

local UI = {}

function UI.setColor(c, alpha)
  if alpha then
    love.graphics.setColor(c[1], c[2], c[3], alpha)
  else
    love.graphics.setColor(c[1], c[2], c[3], c[4] or 1)
  end
end

--- A panel: fill, a hard border, and an optional land-tinted inner rule.
function UI.panel(x, y, w, h, opts)
  opts = opts or {}
  UI.setColor(opts.fill or Theme.panel, opts.alpha)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setLineWidth(2)
  UI.setColor(opts.border or Theme.ink)
  love.graphics.rectangle("line", x + 1, y + 1, w - 2, h - 2)
  if opts.tint then
    UI.setColor(opts.tint, 0.9)
    love.graphics.rectangle("line", x + 4, y + 4, w - 8, h - 8)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

--- A dark panel, for the code editor and the log.
function UI.well(x, y, w, h, tint)
  UI.setColor(Theme.void, 0.94)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setLineWidth(2)
  UI.setColor(tint or Theme.ink)
  love.graphics.rectangle("line", x + 1, y + 1, w - 2, h - 2)
  love.graphics.setColor(1, 1, 1, 1)
end

--- One line of Press Start 2P, with a one-pixel ink drop so it reads over art.
function UI.text(text, x, y, size, color, align, width)
  local font = Assets.font(size or 12)
  love.graphics.setFont(font)
  if align and width then
    UI.setColor(Theme.ink, 0.65)
    love.graphics.printf(text, x + 1, y + 1, width, align)
    UI.setColor(color or Theme.cream)
    love.graphics.printf(text, x, y, width, align)
  else
    UI.setColor(Theme.ink, 0.65)
    love.graphics.print(text, x + 1, y + 1)
    UI.setColor(color or Theme.cream)
    love.graphics.print(text, x, y)
  end
  love.graphics.setColor(1, 1, 1, 1)
  return font:getHeight()
end

function UI.textWidth(text, size)
  return Assets.font(size or 12):getWidth(text)
end

--- Wrap a paragraph to a **pixel** width, measured with the font it will be
--- drawn in.
---
--- The first version of this counted characters against a guessed
--- characters-per-pixel ratio, and the guess was wrong: the quest brief ran
--- off the right edge of its panel in portrait, where the panel is wider and
--- the error is larger. Press Start 2P is close enough to monospace that the
--- guess *nearly* worked, which is the worst kind of nearly.
---
--- A single word longer than the line (a quest id, a long identifier in a
--- test's expected output) is broken rather than allowed to overflow.
function UI.wrap(text, width, size)
  size = size or 8
  local font = Assets.font(size)
  local space = font:getWidth(" ")
  local lines = {}

  local function break_long(word)
    local pieces, current = {}, ""
    for i = 1, #word do
      local ch = word:sub(i, i)
      if current ~= "" and font:getWidth(current .. ch) > width then
        pieces[#pieces + 1] = current
        current = ch
      else
        current = current .. ch
      end
    end
    if current ~= "" then pieces[#pieces + 1] = current end
    return pieces
  end

  for raw in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    if raw == "" then
      lines[#lines + 1] = ""
    else
      local line, line_w = "", 0
      for word in raw:gmatch("%S+") do
        local ww = font:getWidth(word)
        if ww > width then
          if line ~= "" then lines[#lines + 1] = line; line, line_w = "", 0 end
          for _, piece in ipairs(break_long(word)) do
            lines[#lines + 1] = piece
          end
        elseif line == "" then
          line, line_w = word, ww
        elseif line_w + space + ww <= width then
          line = line .. " " .. word
          line_w = line_w + space + ww
        else
          lines[#lines + 1] = line
          line, line_w = word, ww
        end
      end
      if line ~= "" then lines[#lines + 1] = line end
    end
  end
  return lines
end

--- A button. `state` is "normal" | "hot" | "disabled".
function UI.button(x, y, w, h, label, state, size)
  local fill = Theme.panel
  local ink = Theme.ink
  if state == "hot" then
    fill = Theme.coin
  elseif state == "disabled" then
    fill = Theme.dim
    ink = Theme.withAlpha(Theme.ink, 0.6)
  end
  UI.setColor(fill)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setLineWidth(2)
  UI.setColor(Theme.ink)
  love.graphics.rectangle("line", x + 1, y + 1, w - 2, h - 2)
  size = size or math.max(8, math.floor(h * 0.34))
  local font = Assets.font(size)
  love.graphics.setFont(font)
  UI.setColor(ink)
  love.graphics.printf(label, x, y + (h - font:getHeight()) / 2, w, "center")
  love.graphics.setColor(1, 1, 1, 1)
end

--- Difficulty, 1..5 — as **pips, not stars**.
---
--- `docs/design-review.md` §4 is the reason this function exists separately:
--- difficulty (1..5, authored in the content pack) and stars (0..3, earned,
--- SPEC §6.3) are two different scales, and drawing both with the same gold
--- star glyph a few centimetres apart makes a player read their difficulty as
--- their score. The star belongs exclusively to earned stars. Difficulty is a
--- segmented bar in `brick` over `dim`, read by position and by length, and
--- it cannot be mistaken for a score because nothing else in the game is
--- shaped like it.
function UI.pips(x, y, level, size, total)
  total = total or 5
  size = size or 6
  local gap = 2
  for i = 1, total do
    local filled = i <= (level or 0)
    UI.setColor(filled and Theme.brick or Theme.withAlpha(Theme.dim, 0.55))
    love.graphics.rectangle("fill", x + (i - 1) * (size + gap), y, size, size * 2)
  end
  love.graphics.setColor(1, 1, 1, 1)
  return total * (size + gap) - gap
end

function UI.pipsWidth(size, total)
  return (total or 5) * ((size or 6) + 2) - 2
end

--- 0..3 **earned** stars, SPEC §6.3. Never used for difficulty — see
--- `UI.pips` above.
function UI.stars(x, y, count, size, total)
  total = total or 3
  size = size or 10
  for i = 1, total do
    local filled = i <= (count or 0)
    UI.setColor(filled and Theme.coin or Theme.withAlpha(Theme.dim, 0.7))
    local cx, cy = x + (i - 1) * (size + 3) + size / 2, y + size / 2
    -- A four-point star: two triangles, which at this size reads better than
    -- a five-point one and costs nothing.
    love.graphics.polygon("fill",
      cx, cy - size / 2, cx + size / 4, cy, cx, cy + size / 2, cx - size / 4, cy)
    love.graphics.polygon("fill",
      cx - size / 2, cy, cx, cy - size / 4, cx + size / 2, cy, cx, cy + size / 4)
  end
  love.graphics.setColor(1, 1, 1, 1)
  return total * (size + 3)
end

--- A progress bar, for the run stages.
function UI.bar(x, y, w, h, fraction, color)
  UI.setColor(Theme.void, 0.8)
  love.graphics.rectangle("fill", x, y, w, h)
  UI.setColor(color or Theme.admit)
  love.graphics.rectangle("fill", x + 2, y + 2, math.max(0, (w - 4) * math.min(1, fraction or 0)), h - 4)
  love.graphics.setLineWidth(2)
  UI.setColor(Theme.ink)
  love.graphics.rectangle("line", x + 1, y + 1, w - 2, h - 2)
  love.graphics.setColor(1, 1, 1, 1)
end

-- ------------------------------------------------------ the display controls

--- The footer strip's height, and the controls that live in its right end.
UI.FOOTER_H = 22

--- Space kept clear for the connection badge, measured against the *longest*
--- state rather than the current one.
---
--- A reserve that tracked the live string would move the three display
--- buttons sideways every time the socket went from `open` to `connecting`,
--- and a control that walks away from the pointer is worse than one that is
--- slightly further from the edge than it needs to be.
local function badge_reserve()
  return UI.textWidth("CONNECTING", 8) + 16
end

local CHIP_H = 18
local GLYPH_W = 13
local CHIP_PAD = 6
local CHIP_GAP = 5
local LABEL = 7

--- The three chips, in order, with their labels already decided.
---
--- **Each one says the state it is in, not the state it would move to.** A
--- toggle whose current value is invisible gets pressed twice: once to find
--- out, once to put it back. So the window button says WINDOW when it is a
--- window, the orientation button says LAND, PORT or AUTO, and the type-size
--- button says which of its four steps is live.
---
--- AUTO is the one that needs two things said at once — it is a *state* the
--- player chose, and it has *resolved* to a shape they should be able to see
--- — so the word says AUTO and the glyph draws the shape it landed on,
--- hollow rather than filled to say that nothing is pinned.
local function chips(state)
  return {
    {
      id = "fullscreen",
      label = state.fullscreen and "FULL" or "WINDOW",
      glyph = "screen",
    },
    {
      id = "orient",
      label = (state.orientation == "auto") and "AUTO"
        or (state.orientation == "portrait" and "PORT" or "LAND"),
      glyph = "orient",
    },
    {
      id = "font",
      label = state.font_label or "1/4",
      glyph = "type",
    },
  }
end

local function chip_width(chip)
  return CHIP_PAD + GLYPH_W + 4 + UI.textWidth(chip.label, LABEL) + CHIP_PAD
end

--- How wide the cluster is, so the footer can keep the hint out of it.
function UI.displayReserve(state)
  local total = 0
  for i, chip in ipairs(chips(state)) do
    total = total + chip_width(chip) + (i > 1 and CHIP_GAP or 0)
  end
  return total + badge_reserve() + 10
end

--- A small screen, filled when the game owns the whole one.
local function glyph_screen(x, y, full, ink)
  UI.setColor(ink)
  if full then
    love.graphics.rectangle("fill", x, y + 2, GLYPH_W, 9)
  else
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x + 0.5, y + 2.5, GLYPH_W - 1, 8)
    love.graphics.rectangle("fill", x + 3, y + 5, GLYPH_W - 7, 4)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

--- A wide box or a tall one — the shape you are actually in. Filled when it
--- is pinned, hollow when the window is deciding.
local function glyph_orient(x, y, portrait, pinned, ink)
  local w, h = 12, 9
  if portrait then w, h = 8, 13 end
  local gx = x + (GLYPH_W - w) / 2
  local gy = y + (CHIP_H - 4 - h) / 2
  UI.setColor(ink)
  if pinned then
    love.graphics.rectangle("fill", gx, gy, w, h)
  else
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", gx + 0.5, gy + 0.5, w - 1, h - 1)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

--- An `A`, drawn at the step it selects. The control shows its own effect.
local function glyph_type(x, y, step, ink)
  local size = 6 + 2 * math.max(1, math.min(4, step or 1))
  local font = Assets.font(size)
  love.graphics.setFont(font)
  UI.setColor(ink)
  love.graphics.print("A", x + (GLYPH_W - font:getWidth("A")) / 2,
    y + (CHIP_H - 4 - font:getHeight()) / 2)
  love.graphics.setColor(1, 1, 1, 1)
end

--- Where the pointer is, in virtual coordinates, or nil.
---
--- Nil under a drive script and in any frame where the pointer is outside
--- the letterbox, which is why every caller treats nil as "not hot" rather
--- than as an error.
local function pointer()
  if not (love.mouse and love.mouse.getPosition) then return nil end
  local ok, mx, my = pcall(love.mouse.getPosition)
  if not ok then return nil end
  return Layout.toVirtual(mx, my)
end

--- Draw the cluster and return the rectangles it drew, for the hit test.
---
--- **The same three controls, in the same corner, on every screen** — the
--- title card included. They are drawn from `App:footer`, which every scene
--- already calls, so a new scene gets them without knowing they exist and
--- cannot forget them. The keys still work; these are the visible half.
function UI.displayControls(state)
  local list = chips(state)
  local total = 0
  for i, chip in ipairs(list) do
    chip.w = chip_width(chip)
    total = total + chip.w + (i > 1 and CHIP_GAP or 0)
  end

  local y = Layout.vh - UI.FOOTER_H + (UI.FOOTER_H - CHIP_H) / 2
  local x = Layout.vw - 10 - badge_reserve() - total
  local px, py = pointer()

  local rects = {}
  for _, chip in ipairs(list) do
    local hot = px and px >= x and px <= x + chip.w and py >= y and py <= y + CHIP_H
    local ink = hot and Theme.ink or Theme.cream
    UI.setColor(hot and Theme.coin or Theme.withAlpha(Theme.panel, 0.9))
    love.graphics.rectangle("fill", x, y, chip.w, CHIP_H)
    love.graphics.setLineWidth(1)
    UI.setColor(Theme.withAlpha(hot and Theme.ink or Theme.cream, hot and 0.9 or 0.35))
    love.graphics.rectangle("line", x + 0.5, y + 0.5, chip.w - 1, CHIP_H - 1)
    love.graphics.setColor(1, 1, 1, 1)

    local gx = x + CHIP_PAD
    if chip.glyph == "screen" then
      glyph_screen(gx, y, state.fullscreen, ink)
    elseif chip.glyph == "orient" then
      glyph_orient(gx, y, state.shape == "portrait", state.orientation ~= "auto", ink)
    else
      glyph_type(gx, y, state.font, ink)
    end

    UI.text(chip.label, gx + GLYPH_W + 4, y + (CHIP_H - LABEL) / 2 - 1, LABEL, ink)
    rects[chip.id] = { x = x, y = y, w = chip.w, h = CHIP_H }
    x = x + chip.w + CHIP_GAP
  end
  return rects
end

--- The status strip every screen carries along its bottom edge.
---
--- Three zones: the scene's own hint on the left, the connection on the
--- right, and between them the display controls (`UI.displayControls`).
--- Those live here rather than in each scene because they are global — they
--- work on every screen, so they should be reachable on every screen without
--- each scene having to remember to draw them.
---
--- `reserve` is how much of the right-hand end is spoken for. It is taken out
--- **before** the hint is measured, not after: the controls are the feature
--- and cannot be conditional on there being room, so it is the hint that
--- gives way. (It already had to once — see below.)
function UI.footer(lines, connection, reserve)
  local h = UI.FOOTER_H
  local y = Layout.vh - h
  UI.setColor(Theme.ink, 0.8)
  love.graphics.rectangle("fill", 0, y, Layout.vw, h)

  -- The hint was drawn at x = 10 and never measured, so on the quest screen
  -- in portrait — seven keys and an address, on a 720-wide canvas — it ran
  -- straight through the connection badge and the two strings were printed
  -- on top of each other. Two steps, in order: try a size smaller, then clip.
  -- A hint that is cut off mid-word still reads; one with `OPEN` printed
  -- through it does not.
  local keep = math.max(reserve or 0, connection and badge_reserve() or 0)
  local room = Layout.vw - 20 - keep
  local text = lines or ""
  local size = (UI.textWidth(text, 8) > room) and 7 or 8
  love.graphics.setScissor(0, y, math.max(0, Layout.vw - keep - 8), h)
  UI.text(text, 10, y + 7 + (8 - size), size, Theme.withAlpha(Theme.cream, 0.85))
  love.graphics.setScissor()

  if connection then
    local color = Theme.dim
    if connection == "open" then color = Theme.admit
    elseif connection == "closed" then color = Theme.red
    elseif connection == "connecting" or connection == "handshaking" then color = Theme.coin end
    local label = connection:upper()
    local w = UI.textWidth(label, 8)
    UI.text(label, Layout.vw - w - 10, y + 7, 8, color)
  end
end

--- A one-line notice that fades. Owned by the app, drawn here.
function UI.toast(text, alpha)
  if not text or alpha <= 0 then return end
  local size = 10
  local w = math.min(Layout.vw - 40, UI.textWidth(text, size) + 24)
  local x = (Layout.vw - w) / 2
  local y = Layout.vh - 64
  UI.setColor(Theme.ink, 0.85 * alpha)
  love.graphics.rectangle("fill", x, y, w, 24)
  UI.setColor(Theme.coin, alpha)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", x + 1, y + 1, w - 2, 22)
  local font = Assets.font(size)
  love.graphics.setFont(font)
  UI.setColor(Theme.cream, alpha)
  love.graphics.printf(text, x, y + (24 - font:getHeight()) / 2, w, "center")
  love.graphics.setColor(1, 1, 1, 1)
end

return UI
