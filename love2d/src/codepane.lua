-- The mouse half of a code pane, and the bracket overlay drawn on it.
--
-- Two screens draw an `Editor`: the quest screen and the playground. Before
-- this file they each carried their own copy of the pixel → (line, col) hit
-- test, character for character, and a change to one was a change somebody
-- had to remember to make to the other. Drag-select would have been a third
-- and a fourth copy.
--
-- **The geometry is recorded by the draw, not guessed at by the handler.**
-- `frame()` is called once per draw with the numbers the draw actually used,
-- so a click is tested against the pane that was on screen rather than
-- against a re-derivation of it that can drift. A press before the first
-- draw simply does not land, which is correct: there was nothing there.
--
-- Everything with real logic in it is in `src/editor.lua` and is pure. What
-- is here is the part that needs a font, a clock and a canvas.

local Editor = require("src.editor")
local Theme = require("src.theme")
local UI = require("src.ui")

local M = {}

local Pane = {}
Pane.__index = Pane
M.Pane = Pane

--- Two clicks closer together than this, and within `CLICK_SLOP` pixels,
--- are a double click. The third is a triple.
M.CLICK_S = 0.42
M.CLICK_SLOP = 6

function M.new(editor)
  return setmetatable({
    editor = editor,
    geom = nil,
    last_click_at = -1e9,
    last_click_x = -1e9,
    last_click_y = -1e9,
    clicks = 0,
    -- True between a press that landed in the pane and its release. A press
    -- that started on a button must not become a drag in the text, and a
    -- drag that started in the text must not become a button press when it
    -- is released over one.
    active = false,
  }, Pane)
end

--- Record the geometry this frame's draw used.
---
--- `x0, y0` is where the gutter starts; the text itself starts at
--- `x0 + gutter`. `rect` is the well, used only to decide whether a click is
--- inside the pane at all.
function Pane:frame(rect, font, gutter, x0, y0, line_h, rows)
  self.geom = {
    rect = rect, font = font, gutter = gutter,
    x0 = x0, y0 = y0, line_h = line_h, rows = rows,
  }
end

function Pane:contains(x, y)
  local g = self.geom
  if not g then return false end
  local r = g.rect
  return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

--- Where `(x, y)` is in the document.
---
--- Deliberately **unclamped in the row direction on the way out** only in the
--- sense that `Editor:clamp` does it: dragging above the pane gives a
--- negative row, which clamps to line 1, and the editor's own
--- `ensure_visible` on the next draw scrolls to follow. That is the whole of
--- drag-scrolling, and it needs no timer.
function Pane:position(x, y)
  local g = self.geom
  if not g then return nil end
  local row = math.floor((y - g.y0) / g.line_h) + 1
  local index = self.editor.scroll + row
  index = math.max(1, math.min(#self.editor.lines, index))
  local line = self.editor.lines[index] or ""
  local font = g.font
  local col = Editor.column_at(line, x - g.x0 - g.gutter,
    function(s) return font:getWidth(s) end)
  return index, col
end

--- How many clicks in a row this press is: 1, 2 or 3, wrapping back to 1.
function Pane:click_count(x, y, now)
  local near = math.abs(x - self.last_click_x) <= M.CLICK_SLOP
    and math.abs(y - self.last_click_y) <= M.CLICK_SLOP
  if near and (now - self.last_click_at) <= M.CLICK_S then
    self.clicks = (self.clicks % 3) + 1
  else
    self.clicks = 1
  end
  self.last_click_at, self.last_click_x, self.last_click_y = now, x, y
  return self.clicks
end

local MODES = { "char", "word", "line" }

--- A press inside the pane. Returns true when it was taken.
function Pane:mousepressed(x, y, button, shift)
  if button ~= 1 then return false end
  if not self:contains(x, y) then return false end
  local line, col = self:position(x, y)
  if not line then return false end
  -- A shift-click extends, and is never a double click. Clicking and then
  -- shift-clicking a few characters away is one gesture people make in one
  -- second; counted as a double click it selected the word under the pointer
  -- instead of extending, which is the opposite of what was asked for.
  local mode = "char"
  if shift then
    self.clicks, self.last_click_at = 0, -1e9
  else
    mode = MODES[self:click_count(x, y, love.timer.getTime())] or "char"
  end
  self.editor:begin_select(line, col, mode, shift)
  self.active = true
  return true
end

--- A move. Only ever extends a selection this pane started.
function Pane:mousemoved(x, y)
  if not (self.active and self.editor:dragging()) then return false end
  local line, col = self:position(x, y)
  if not line then return false end
  self.editor:drag_to(line, col)
  return true
end

--- A release. Returns true when this pane was mid-drag, which is the signal
--- the scene uses to *not* treat the release as a click on whatever is under
--- the pointer.
function Pane:mousereleased()
  local was = self.active
  self.editor:end_select()
  self.active = false
  return was
end

-- --------------------------------------------------------------- the overlay

--- The pixel box of the character at `(index, col)`, or nil when that line is
--- not on screen.
function Pane:cell(index, col)
  local g = self.geom
  if not g then return nil end
  local row = index - self.editor.scroll
  if row < 1 or row > g.rows then return nil end
  local line = self.editor.lines[index]
  if not line then return nil end
  local to = Editor.next_boundary(line, col)
  local x = g.x0 + g.gutter + g.font:getWidth(line:sub(1, col - 1))
  local w = math.max(3, g.font:getWidth(line:sub(col, to - 1)))
  return x, g.y0 + (row - 1) * g.line_h, w, g.line_h
end

local function outline(x, y, w, h, colour, alpha)
  UI.setColor(colour, alpha or 1)
  love.graphics.rectangle("line", x + 0.5, y + 1.5, w - 1, h - 3)
  love.graphics.setColor(1, 1, 1, 1)
end

--- Brackets, drawn steady.
---
--- Nothing here moves. The rule that the editor pane never animates is not
--- negotiable — it is the surface somebody is reading their own program on —
--- so a matched pair is an outline and an unmatched bracket is an outline in
--- another colour, and neither pulses, blinks or fades.
---
--- The **unmatched** marking is the one that earns the feature its space. A
--- matched pair is a small convenience; an unclosed brace is the single most
--- common reason a submission does not compile, and until the compiler says
--- so it is invisible.
function Pane:draw_brackets()
  local g = self.geom
  if not g then return end
  local editor = self.editor

  local _, unmatched = editor:brackets()
  for _, entry in ipairs(unmatched) do
    local x, y, w, h = self:cell(entry.line, entry.col)
    if x then outline(x, y, w, h, Theme.brick, 0.95) end
  end

  local here = editor:bracket_at_caret()
  if here and here.partner then
    for _, entry in ipairs({ here, here.partner }) do
      local x, y, w, h = self:cell(entry.line, entry.col)
      if x then outline(x, y, w, h, Theme.cyan, 0.9) end
    end
  end
end

--- The colour the line number should be drawn in, so a line holding an
--- unmatched bracket says so even when the bracket itself has scrolled off
--- to the right.
function Pane:gutter_color(index)
  if self.editor:unmatched_lines()[index] then
    return Theme.brick, 1
  end
  return Theme.dim, 0.9
end

return M
