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

--- 0..3 stars, SPEC §6.3.
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

--- The status strip every screen carries along its bottom edge.
function UI.footer(lines, connection)
  local h = 22
  local y = Layout.vh - h
  UI.setColor(Theme.ink, 0.8)
  love.graphics.rectangle("fill", 0, y, Layout.vw, h)
  UI.text(lines or "", 10, y + 7, 8, Theme.withAlpha(Theme.cream, 0.85))
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
