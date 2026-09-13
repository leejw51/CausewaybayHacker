-- The 16-bit furniture: panels, buttons, labels, stars, the toast line.
--
-- The chrome is `CausewaybayGolang`'s — a hard two-pixel border in `ink` over
-- a `panel` fill, no bevel and no shadow, per `docs/art.md` §1. Everything
-- takes virtual coordinates and nothing here knows which scene it is in.

local Theme = require("src.theme")
local Assets = require("src.assets")
local Layout = require("src.layout")
-- For the language button's candidate labels: it is measured from every code
-- it can ever wear (`YUE` is half again as wide as `EN`), not from the one it
-- happens to be showing.
local I18n = require("src.i18n")

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
---
--- `size` is an **authored size**, not a pixel size: `Layout.ui` doubles it
--- and `Assets.snap8` rounds it onto the 8-pixel grid the faces are drawn on.
--- Every entry point in this file goes through the same pair — a paragraph
--- measured at one size and drawn at another wraps wrong in a way nobody
--- notices until a sentence is cut in half.
function UI.text(text, x, y, size, color, align, width)
  local font = Assets.font(Layout.ui(size or 12))
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
  return UI.lineHeight(size)
end

function UI.textWidth(text, size)
  return Assets.font(Layout.ui(size or 12)):getWidth(text)
end

--- The pixel height of a line at an authored size — the number a layout
--- needs when it is deciding how far apart two rows go.
---
--- **An eighth taller in a CJK language.** Measured, not guessed: at every
--- size the faces are drawn at, Press Start 2P inks rows 0 to ⅞ of the line
--- and GNU Unifont — which LÖVE aligns to it by baseline — inks rows ¼ to
--- 1⅛. A Korean title at 64 px reaches eight pixels under its own line box,
--- and a layout that advanced by the box printed the next line through it.
--- The room is given here, once, so every stack that measures its rows from
--- this gets it without knowing why.
function UI.lineHeight(size)
  local h = Assets.font(Layout.ui(size or 12)):getHeight()
  if I18n.is_cjk() then h = h + math.floor(h / 8) end
  return h
end

--- Split a string into UTF-8 characters.
---
--- `src/drive.lua` has the same four lines and `src/editor.lua` has a richer
--- version; this one is here because `src/ui.lua` must not depend on either,
--- and because the alternative — iterating bytes — is how a Japanese sentence
--- becomes mojibake.
function UI.chars(text)
  local out = {}
  local i, n = 1, #text
  while i <= n do
    local b = text:byte(i)
    local width = 1
    if b >= 0xF0 then width = 4
    elseif b >= 0xE0 then width = 3
    elseif b >= 0xC0 then width = 2 end
    out[#out + 1] = text:sub(i, i + width - 1)
    i = i + width
  end
  return out
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
  local font = Assets.font(Layout.ui(size))
  local space = font:getWidth(" ")
  local lines = {}

  local function break_long(word)
    local pieces, current = {}, ""
    -- **By character, not by byte.** This loop was `for i = 1, #word`, which
    -- is fine for the ASCII this client used to contain and wrong the moment
    -- it says anything in Korean or Japanese: those sentences have no spaces,
    -- so the whole sentence arrives here as one "word", and splitting it at
    -- byte 40 cuts a three-byte character in half. What comes out is mojibake,
    -- and `getWidth` on a truncated sequence is not obliged to return at all.
    --
    -- Splitting a space-less script by character is also the *correct*
    -- wrapping rule for it, so this is the same loop with the right stride.
    for _, ch in ipairs(UI.chars(word)) do
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
  local font = Assets.font(Layout.ui(size))
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

--- The size the hint and the connection badge are set in.
UI.FOOTER_SIZE = 8

--- The size the display buttons are set in — **the button face, not the
--- caption face.**
---
--- 9 is what `src/scenes/quest.lua` draws RUN, SUBMIT, FORMAT and SOLVE at,
--- and these four are buttons of exactly that kind: things a player aims at
--- and presses. They were drawn at 7, which is the size this client uses for
--- the smallest caption under a node card, and the result was a row of chips
--- that read as footer chrome rather than as controls. At the authored size
--- ladder's first step both snap to the same 16 px cell; at the steps above
--- it they do not, and the caption face stayed 32 px while every real button
--- on the screen went to 48.
UI.CHIP_SIZE = 9

--- The floor under a display button's height.
---
--- `CausewaybayGolang/love2d/src/game.lua` puts its HUD buttons on a 36 px
--- floor (`btnBox(…, 112, 32, 36)`) and gives them a strip of their own,
--- `TOP = btnH + 20`. This is the same number for the same reason: 36 px is
--- about 9 mm on a laptop panel and is the smallest thing a finger hits
--- without aiming. What was here before was `footerRow() - 4` — **22 px** —
--- which is a caption with a box drawn round it.
UI.CHIP_MIN_H = 36

--- One row of hint, or two. **Set by the last `UI.footer`, read by scenes and
--- by `tests/drive/language.lua`.**
---
--- A Korean hint at the readable type ladder is 700 to 1600 pixels of text
--- and a 720-wide portrait canvas cannot hold it on one line at any size, so
--- the hint is allowed a second row. Two is the cap: a strip taller than that
--- stops being chrome, and what is past it is clipped (a hint cut off
--- mid-word still reads; one printed through the connection badge does not).
UI.hint_rows = 1

--- True when the last hint did not fit in the rows it was given, so a drive
--- script can say which screen in which language is losing the end of its
--- own sentence instead of leaving it to somebody's eye.
UI.hint_clipped = false

--- The height of one row of hint.
function UI.footerRow()
  return math.max(22, UI.lineHeight(UI.FOOTER_SIZE) + 10)
end

--- How tall one display button is: its own ink plus air, never under the
--- floor. Measured, so it grows with the player's type-size step the way
--- every other button in this client does.
function UI.chipHeight()
  return math.max(UI.CHIP_MIN_H, UI.lineHeight(UI.CHIP_SIZE) + 14)
end

--- The display buttons' **own row**, which is the other half of the fix.
---
--- They used to share the hint's row: four controls, a wallet address, a
--- scene hint and the connection state, on one 22 px line. Golang gives the
--- same cluster a reserved strip (`TOP`, sized from `btnH + 20`) and that is
--- what this is — 10 px of air around a 36 px button, at the bottom rather
--- than the top because that is where this client's chrome already lives and
--- where every scene already subtracts `UI.footerHeight()`. Nothing else had
--- to learn about a new band.
function UI.controlRow()
  return UI.chipHeight() + 10
end

--- The whole strip: the hint's rows, plus the controls' row.
function UI.footerHeight()
  return UI.footerRow() * UI.hint_rows + UI.controlRow()
end

--- Space kept clear for the connection badge, measured against the *longest*
--- state rather than the current one.
---
--- A reserve that tracked the live string would move whatever sits beside it
--- every time the socket went from `open` to `connecting`, and a control that
--- walks away from the pointer is worse than one that is slightly further
--- from the edge than it needs to be.
local function badge_reserve()
  return UI.textWidth("CONNECTING", UI.FOOTER_SIZE) + 16
end

UI.badgeReserve = badge_reserve

--- The chips are measured from the type in them, so they grow with it.
local CHIP_PAD = 12      -- between the frame and what is inside it
local CHIP_INNER = 8     -- between the glyph and the label
local CHIP_GAP = 8       -- between one button and the next

--- The `A` the type-size button draws, at the step it selects.
---
--- The control shows its own effect, and the four steps have to be four
--- visibly different glyphs rather than four roundings of one — so the size
--- is taken off `Layout.FONT_STEPS` directly and snapped onto the 8-pixel
--- grid, then capped so it cannot outgrow the button it is drawn in.
local function type_font(step)
  local want = Assets.snap8(16 * (Layout.FONT_STEPS[step or 1] or 1))
  return Assets.font(math.min(want, Assets.snap8(UI.chipHeight() - 10)))
end

--- The glyph cell: a square the size of the label's own ink, except on the
--- type button, where the glyph is the point and is measured from itself.
local function glyph_w(chip, state)
  if chip and chip.glyph == "type" then
    return math.max(UI.lineHeight(UI.CHIP_SIZE), type_font(state.font):getWidth("A"))
  end
  return UI.lineHeight(UI.CHIP_SIZE)
end

--- The four chips, in order, with their labels already decided.
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
---
--- `every` is every label this button can ever wear, which is what its width
--- is measured from: `btnBox` in `CausewaybayGolang/love2d/src/game.lua`
--- sizes a button from the widest of its candidates rather than from the one
--- it happens to be showing, so a button does not change width — or clip —
--- when its own state changes. The language button's candidates are all six
--- codes, which is where `YUE` comes in: it is half again as wide as `EN` and
--- it is the reason a fixed width was wrong.
local function chips(state)
  local steps = {}
  for i = 1, #Layout.FONT_STEPS do steps[i] = ("%d/%d"):format(i, #Layout.FONT_STEPS) end
  local codes = {}
  for _, code in ipairs(I18n.LANGS) do codes[#codes + 1] = I18n.CODES[code] or "EN" end
  return {
    {
      id = "fullscreen",
      label = state.fullscreen and "FULL" or "WINDOW",
      every = { "FULL", "WINDOW" },
      short = "",
      glyph = "screen",
    },
    {
      id = "orient",
      label = (state.orientation == "auto") and "AUTO"
        or (state.orientation == "portrait" and "PORT" or "LAND"),
      every = { "AUTO", "PORT", "LAND" },
      -- `A` for automatic even when compact: hollow-versus-filled says
      -- "nothing is pinned" only to somebody who already knows it does.
      short = (state.orientation == "auto") and "A" or "",
      glyph = "orient",
    },
    {
      id = "font",
      -- **`A 1/4` is the glyph plus the fraction, and the glyph is the `A`.**
      -- Spelling the letter into the label as well gave `A A 1/4`, which is
      -- how you find out that the control the user calls "A 1/4" was already
      -- saying the right thing — it was saying it 22 px tall in a caption
      -- face, which is a different problem and is the one this pass fixes.
      label = state.font_label or "1/4",
      every = steps,
      short = tostring(state.font or 1),
      glyph = "type",
    },
    {
      id = "lang",
      -- **The code, not the name.** `한국어` is three double-width cells where
      -- `KO` is two single ones, and the name in full is what the toast says
      -- when the button is pressed, which is the moment it is needed.
      label = state.lang_code or "EN",
      every = codes,
      short = state.lang_code or "EN",
      glyph = "lang",
    },
  }
end

--- True when the row is too narrow to carry four labelled buttons.
---
--- The glyphs say the state on their own — the screen is inset or filled, the
--- box is wide or tall and hollow or solid, the `A` is drawn at its own step
--- — so the word is the part that can go. The type button keeps its digit,
--- because "which of four" is the one state no glyph shows.
local compact = false

--- `btnBox`, in this client's furniture: a button is as wide as the widest
--- label it can ever wear, plus a glyph, plus real padding — never a number
--- somebody typed in.
local function chip_width(chip, state)
  local text = 0
  if compact then
    if (chip.short or "") ~= "" then
      text = CHIP_INNER + UI.textWidth(chip.short, UI.CHIP_SIZE)
    end
  else
    for _, label in ipairs(chip.every) do
      text = math.max(text, CHIP_INNER + UI.textWidth(label, UI.CHIP_SIZE))
    end
  end
  return CHIP_PAD + glyph_w(chip, state) + text + CHIP_PAD
end

--- How wide the cluster is, and — the other half of the job — whether the
--- buttons can wear their labels at this canvas width.
---
--- The controls have a row to themselves now, so what they are measured
--- against is the whole width rather than what is left after a hint and a
--- badge. That is what buys the labels back in portrait: the full cluster is
--- about 500 px at the first type step and a 720-wide portrait canvas has all
--- of it to spend.
function UI.displayReserve(state)
  local function total()
    local sum = 0
    for i, chip in ipairs(chips(state)) do
      sum = sum + chip_width(chip, state) + (i > 1 and CHIP_GAP or 0)
    end
    return sum
  end
  compact = false
  if total() > Layout.vw - 20 then compact = true end
  return total()
end

--- A small screen, filled when the game owns the whole one.
local function glyph_screen(x, y, cell, full, ink)
  local h = math.max(6, math.floor(cell * 0.72))
  local top = y + (UI.chipHeight() - h) / 2
  local inset = math.max(2, math.floor(cell / 6))
  UI.setColor(ink)
  if full then
    love.graphics.rectangle("fill", x, top, cell, h)
  else
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x + 0.5, top + 0.5, cell - 1, h - 1)
    love.graphics.rectangle("fill", x + inset, top + inset, cell - inset * 2, h - inset * 2)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

--- A wide box or a tall one — the shape you are actually in. Filled when it
--- is pinned, hollow when the window is deciding.
local function glyph_orient(x, y, cell, portrait, pinned, ink)
  local w, h = cell, math.max(5, math.floor(cell * 0.72))
  if portrait then w, h = math.max(5, math.floor(cell * 0.62)), cell end
  local gx = x + (cell - w) / 2
  local gy = y + (UI.chipHeight() - h) / 2
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
local function glyph_type(x, y, cell, step, ink)
  local font = type_font(step)
  love.graphics.setFont(font)
  UI.setColor(ink)
  love.graphics.print("A", x + (cell - font:getWidth("A")) / 2,
    y + (UI.chipHeight() - font:getHeight()) / 2)
  love.graphics.setColor(1, 1, 1, 1)
end

--- A globe: a circle with a meridian and two parallels. Three strokes is as
--- much globe as this cell will hold, and it is the one symbol for "language"
--- that does not belong to a particular country's flag.
local function glyph_globe(x, y, cell, ink)
  local r = cell / 2
  local cx, cy = x + r, y + UI.chipHeight() / 2
  UI.setColor(ink)
  love.graphics.setLineWidth(1)
  love.graphics.circle("line", cx, cy, r - 0.5, 16)
  love.graphics.line(cx, cy - r + 1, cx, cy + r - 1)
  love.graphics.line(cx - r + 1.5, cy, cx + r - 1.5, cy)
  love.graphics.line(cx - r + r * 0.3, cy - r * 0.5, cx + r - r * 0.3, cy - r * 0.5)
  love.graphics.line(cx - r + r * 0.3, cy + r * 0.5, cx + r - r * 0.3, cy + r * 0.5)
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
--- **The same four controls, in the same corner, on every screen** — the
--- title card and the opening included. They are drawn from `App:footer`,
--- which every scene already calls, so a new scene gets them without knowing
--- they exist and cannot forget them. The keys still work; these are the
--- visible half.
function UI.displayControls(state)
  local list = chips(state)
  local total = 0
  for i, chip in ipairs(list) do
    chip.w = chip_width(chip, state)
    total = total + chip.w + (i > 1 and CHIP_GAP or 0)
  end

  local ch = UI.chipHeight()
  local row = UI.controlRow()
  local y = math.floor(Layout.vh - row + (row - ch) / 2)
  -- Never off the left edge, whatever the language and the type step do to
  -- the labels: a control that has left the canvas cannot be pressed, and
  -- nothing else in this client would have said so. (It had, once: four
  -- chips measured from a three-row strip came to more than a portrait
  -- canvas and the whole cluster sat off the left edge, visible as a sliver
  -- and clickable nowhere.)
  local x = math.max(6, Layout.vw - 10 - total)
  local px, py = pointer()

  local rects = {}
  for _, chip in ipairs(list) do
    local hot = px and px >= x and px <= x + chip.w and py >= y and py <= y + ch
    local ink = hot and Theme.ink or Theme.cream
    UI.setColor(hot and Theme.coin or Theme.withAlpha(Theme.panel, 0.16))
    love.graphics.rectangle("fill", x, y, chip.w, ch)
    -- A hard two-pixel border, the same frame `UI.button` and `UI.panel`
    -- wear. At one pixel and a third of an alpha these read as boxes drawn
    -- round some text; the point of this pass is that they read as buttons.
    love.graphics.setLineWidth(2)
    UI.setColor(Theme.withAlpha(hot and Theme.ink or Theme.cream, hot and 0.9 or 0.55))
    love.graphics.rectangle("line", x + 1, y + 1, chip.w - 2, ch - 2)
    love.graphics.setColor(1, 1, 1, 1)

    local cell = glyph_w(chip, state)
    local gx = x + CHIP_PAD
    if chip.glyph == "screen" then
      glyph_screen(gx, y, cell, state.fullscreen, ink)
    elseif chip.glyph == "orient" then
      glyph_orient(gx, y, cell, state.shape == "portrait", state.orientation ~= "auto", ink)
    elseif chip.glyph == "lang" then
      glyph_globe(gx, y, cell, ink)
    else
      glyph_type(gx, y, cell, state.font, ink)
    end

    local label = compact and (chip.short or "") or chip.label
    if label ~= "" then
      UI.text(label, gx + cell + CHIP_INNER,
        y + (ch - UI.lineHeight(UI.CHIP_SIZE)) / 2, UI.CHIP_SIZE, ink)
    end
    rects[chip.id] = { x = x, y = y, w = chip.w, h = ch }
    x = x + chip.w + CHIP_GAP
  end
  return rects
end

--- The status strip every screen carries along its bottom edge.
---
--- Two bands, not three zones:
---
---   * the **hint row** — the scene's own line of keys on the left, the
---     connection state on the right;
---   * the **control row** under it, which belongs to the display buttons
---     (`UI.displayControls`) and to nothing else.
---
--- It was one row with all five things on it, and the four buttons were 22 px
--- tall at a caption size because that is all the room a row shared with a
--- wallet address has. Splitting it is what makes them buttons: the hint gets
--- the whole width back, and the controls get a height they were never going
--- to be given while they were sharing.
---
--- The controls live here rather than in each scene because they are global —
--- they work on every screen, so they should be reachable on every screen
--- without each scene having to remember to draw them.
---
--- Returns the room the hint was given, which is the number
--- `tests/drive/language.lua` prints a translated string against.
function UI.footer(lines, connection)
  local row = UI.footerRow()
  local text = lines or ""
  local beside = Layout.vw - 20 - (connection and badge_reserve() or 0)

  local hint_rows = {}
  UI.hint_clipped = false
  if UI.textWidth(text, UI.FOOTER_SIZE) <= beside then
    hint_rows = { text }
    UI.hint_rows = 1
  else
    -- **Wrapped to the room it is actually given**, which is the width beside
    -- the connection badge — not to the whole canvas. Wrapping to the canvas
    -- and then drawing inside a narrower scissor is how a hint that reports
    -- "one row, wrapped, fine" loses its last two words: `UI.wrap` collapses
    -- the runs of spaces a key list is spelled with, so a 704 px Korean hint
    -- comes back as one 600 px line, which is still 76 px wider than the row
    -- it is drawn in.
    local wrapped = UI.wrap(text, beside, UI.FOOTER_SIZE)
    for i = 1, math.min(2, #wrapped) do hint_rows[i] = wrapped[i] end
    UI.hint_rows = math.max(1, #hint_rows)
    UI.hint_clipped = #wrapped > 2
  end

  local h = UI.footerHeight()
  local y = Layout.vh - h
  UI.setColor(Theme.ink, 0.8)
  love.graphics.rectangle("fill", 0, y, Layout.vw, h)
  -- A rule between the two bands, so the control row reads as a place the
  -- buttons live rather than as more of the same strip.
  UI.setColor(Theme.cream, 0.12)
  love.graphics.rectangle("fill", 0, Layout.vh - UI.controlRow(), Layout.vw, 1)
  love.graphics.setColor(1, 1, 1, 1)

  -- The hint was drawn at x = 10 and never measured, once, so on the quest
  -- screen in portrait it ran straight through the connection badge and the
  -- two strings were printed on top of each other. What is left of that fix
  -- is the clip: a hint cut off mid-word still reads; one with `OPEN`
  -- printed through it does not.
  local room = beside
  love.graphics.setScissor(0, y, math.max(0, room + 10), row * UI.hint_rows)
  for i, line in ipairs(hint_rows) do
    UI.text(line, 10, y + (i - 1) * row + (row - UI.lineHeight(UI.FOOTER_SIZE)) / 2,
      UI.FOOTER_SIZE, Theme.withAlpha(Theme.cream, 0.85))
  end
  love.graphics.setScissor()

  if connection then
    local color = Theme.dim
    if connection == "open" then color = Theme.admit
    elseif connection == "closed" then color = Theme.red
    elseif connection == "connecting" or connection == "handshaking" then color = Theme.coin end
    local label = connection:upper()
    local w = UI.textWidth(label, UI.FOOTER_SIZE)
    -- On the hint's first row, at the right-hand end: it is a status line,
    -- and it belongs with the other status line rather than in the middle of
    -- a row of buttons.
    UI.text(label, Layout.vw - w - 10,
      y + (row - UI.lineHeight(UI.FOOTER_SIZE)) / 2, UI.FOOTER_SIZE, color)
  end
  return room
end

--- A one-line notice that fades. Owned by the app, drawn here.
function UI.toast(text, alpha)
  if not text or alpha <= 0 then return end
  local size = 10
  local font = Assets.font(Layout.ui(size))
  -- The box is measured from the type rather than fixed at 24 px: the type
  -- size is now a player setting, and a toast that kept a hard height would
  -- clip its own message at the larger steps.
  local h = font:getHeight() + 12
  local w = math.min(Layout.vw - 40, font:getWidth(text) + 24)
  local x = (Layout.vw - w) / 2
  local y = Layout.vh - UI.footerHeight() - h - 20
  UI.setColor(Theme.ink, 0.85 * alpha)
  love.graphics.rectangle("fill", x, y, w, h)
  UI.setColor(Theme.coin, alpha)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", x + 1, y + 1, w - 2, h - 2)
  love.graphics.setFont(font)
  UI.setColor(Theme.cream, alpha)
  love.graphics.printf(text, x, y + (h - font:getHeight()) / 2, w, "center")
  love.graphics.setColor(1, 1, 1, 1)
end

return UI
