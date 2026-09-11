-- The code editor's model: a buffer, a cursor, a selection and an undo stack.
--
-- A player has to write real Rust in this, so it is not a text field with
-- newlines in it. Everything a person reaches for without thinking is here:
-- selection with shift, word motion with alt/ctrl, home/end, page up and
-- down, tab and shift-tab over a whole selected block, auto-indent after `{`,
-- undo and redo, and the system clipboard.
--
-- **No drawing and no `love` in this file.** The model is a pure data
-- structure with `textinput` and `keypressed` entry points, so the whole of
-- it is tested headlessly by typing a twenty-line program into it and
-- asserting the bytes — `tests/test_editor.lua`. `src/scenes/quest.lua` draws
-- it and hands it LÖVE's keyboard events; the clipboard is injected so this
-- file never names `love.system`.
--
-- Positions are `(line, col)` with `col` a **byte** index, 1 = before the
-- first byte. Motion steps by UTF-8 code point, so an emoji in a string
-- literal is one press of the left arrow and not four.

local M = {}

local Editor = {}
Editor.__index = Editor
M.Editor = Editor

M.TAB_WIDTH = 4
--- Typing within this many seconds folds into the previous undo entry, so
--- ctrl-Z takes back a word rather than a letter.
M.UNDO_COALESCE_S = 0.6
M.MAX_UNDO = 400

-- ------------------------------------------------------------------ utf-8

--- Length in bytes of the UTF-8 sequence starting with byte `b`.
local function seq_len(b)
  if not b then return 1 end
  if b < 0x80 then return 1 end
  if b < 0xC0 then return 1 end -- a stray continuation byte; treat as one
  if b < 0xE0 then return 2 end
  if b < 0xF0 then return 3 end
  return 4
end

--- The byte index of the code point before `col` in `s`.
function M.prev_boundary(s, col)
  if col <= 1 then return 1 end
  local i = col - 1
  while i > 1 and s:byte(i) and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do
    i = i - 1
  end
  return i
end

--- The byte index just past the code point at `col`.
function M.next_boundary(s, col)
  if col > #s then return #s + 1 end
  return math.min(#s + 1, col + seq_len(s:byte(col)))
end

--- How many code points `s` holds, for column arithmetic in the view.
function M.char_count(s)
  local n, i = 0, 1
  while i <= #s do
    i = i + seq_len(s:byte(i))
    n = n + 1
  end
  return n
end

--- The byte index of the `n`-th code point (1-based); `#s + 1` past the end.
function M.byte_at_char(s, n)
  local i, c = 1, 1
  while i <= #s and c < n do
    i = i + seq_len(s:byte(i))
    c = c + 1
  end
  return i
end

-- ------------------------------------------------------------------ construct

--- `opts`:
---   text       initial contents
---   clipboard  { get = function() -> string, set = function(string) }
---   now        function() -> seconds, for undo coalescing
---   tab_width  default 4
---   read_only  render but refuse edits
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    lines = { "" },
    line = 1,
    col = 1,
    -- Where a shift-selection started; nil when there is no selection.
    anchor = nil,
    -- The column a vertical motion is trying to keep, in code points.
    goal_char = nil,
    scroll = 0,
    scroll_x = 0,
    undo_stack = {},
    redo_stack = {},
    last_edit_at = -1e9,
    dirty = false,
    clipboard = opts.clipboard or M.memory_clipboard(),
    now = opts.now or function() return 0 end,
    tab_width = opts.tab_width or M.TAB_WIDTH,
    read_only = opts.read_only or false,
  }, Editor)
  self:set_text(opts.text or "")
  self.undo_stack = {}
  self.dirty = false
  return self
end

--- A clipboard that is just a variable. The game passes LÖVE's.
function M.memory_clipboard()
  local held = ""
  return {
    get = function() return held end,
    set = function(v) held = v or "" end,
  }
end

-- --------------------------------------------------------------------- text

function Editor:set_text(text)
  text = tostring(text or "")
  -- Normalise line endings on the way in: a quest's `starter` comes off the
  -- wire and a paste comes off the system, and neither is guaranteed to be
  -- \n-only. The buffer is \n-only from here on, which is what gets sent.
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  local start = 1
  while true do
    local nl = text:find("\n", start, true)
    if not nl then
      lines[#lines + 1] = text:sub(start)
      break
    end
    lines[#lines + 1] = text:sub(start, nl - 1)
    start = nl + 1
  end
  if #lines == 0 then lines = { "" } end
  self.lines = lines
  self.line = math.min(self.line, #lines)
  self.col = math.min(self.col, #lines[self.line] + 1)
  self.anchor = nil
  self.goal_char = nil
end

function Editor:text()
  return table.concat(self.lines, "\n")
end

function Editor:line_count()
  return #self.lines
end

function Editor:current_line()
  return self.lines[self.line] or ""
end

-- ---------------------------------------------------------------- selection

--- The selection as `l1, c1, l2, c2` in document order, or nil.
function Editor:selection()
  if not self.anchor then return nil end
  local al, ac = self.anchor.line, self.anchor.col
  if al == self.line and ac == self.col then return nil end
  if al < self.line or (al == self.line and ac < self.col) then
    return al, ac, self.line, self.col
  end
  return self.line, self.col, al, ac
end

function Editor:has_selection()
  return self:selection() ~= nil
end

function Editor:selected_text()
  local l1, c1, l2, c2 = self:selection()
  if not l1 then return "" end
  if l1 == l2 then
    return self.lines[l1]:sub(c1, c2 - 1)
  end
  local parts = { self.lines[l1]:sub(c1) }
  for l = l1 + 1, l2 - 1 do
    parts[#parts + 1] = self.lines[l]
  end
  parts[#parts + 1] = self.lines[l2]:sub(1, c2 - 1)
  return table.concat(parts, "\n")
end

function Editor:select_all()
  self.anchor = { line = 1, col = 1 }
  self.line = #self.lines
  self.col = #self.lines[self.line] + 1
end

function Editor:clear_selection()
  self.anchor = nil
end

--- Start or extend a selection before a motion, or drop it.
function Editor:prepare_motion(extend)
  if extend then
    if not self.anchor then
      self.anchor = { line = self.line, col = self.col }
    end
  else
    self.anchor = nil
  end
end

-- --------------------------------------------------------------------- undo

function Editor:snapshot()
  local copy = {}
  for i, l in ipairs(self.lines) do copy[i] = l end
  return {
    lines = copy,
    line = self.line,
    col = self.col,
    anchor = self.anchor and { line = self.anchor.line, col = self.anchor.col } or nil,
  }
end

function Editor:restore(state)
  local copy = {}
  for i, l in ipairs(state.lines) do copy[i] = l end
  self.lines = copy
  self.line = math.min(state.line, #copy)
  self.col = math.min(state.col, #(copy[self.line] or "") + 1)
  self.anchor = state.anchor and { line = state.anchor.line, col = state.anchor.col } or nil
  self.goal_char = nil
end

--- Record the state before an edit.
---
--- `coalesce` is true for ordinary typing: consecutive keystrokes inside
--- `UNDO_COALESCE_S` share one entry, so ctrl-Z takes back a word and not a
--- letter. Structural edits (paste, indent, newline, delete of a selection)
--- always start a fresh entry.
function Editor:push_undo(coalesce)
  local now = self.now()
  if coalesce and #self.undo_stack > 0 and (now - self.last_edit_at) < M.UNDO_COALESCE_S then
    self.last_edit_at = now
    self.redo_stack = {}
    return
  end
  self.undo_stack[#self.undo_stack + 1] = self:snapshot()
  if #self.undo_stack > M.MAX_UNDO then
    table.remove(self.undo_stack, 1)
  end
  self.redo_stack = {}
  self.last_edit_at = now
end

function Editor:undo()
  local state = table.remove(self.undo_stack)
  if not state then return false end
  self.redo_stack[#self.redo_stack + 1] = self:snapshot()
  self:restore(state)
  self.last_edit_at = -1e9
  self.dirty = true
  return true
end

function Editor:redo()
  local state = table.remove(self.redo_stack)
  if not state then return false end
  self.undo_stack[#self.undo_stack + 1] = self:snapshot()
  self:restore(state)
  self.last_edit_at = -1e9
  self.dirty = true
  return true
end

-- -------------------------------------------------------------------- edits

function Editor:delete_selection()
  local l1, c1, l2, c2 = self:selection()
  if not l1 then return false end
  local head = self.lines[l1]:sub(1, c1 - 1)
  local tail = self.lines[l2]:sub(c2)
  for _ = l1, l2 - 1 do
    table.remove(self.lines, l1 + 1)
  end
  self.lines[l1] = head .. tail
  self.line, self.col = l1, c1
  self.anchor = nil
  self.goal_char = nil
  return true
end

--- Insert `text` at the cursor, replacing any selection.
function Editor:insert(text, coalesce)
  if self.read_only then return end
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  if text == "" then return end
  self:push_undo(coalesce and not self:has_selection())
  self:delete_selection()

  local current = self.lines[self.line]
  local head, tail = current:sub(1, self.col - 1), current:sub(self.col)
  if not text:find("\n", 1, true) then
    self.lines[self.line] = head .. text .. tail
    self.col = self.col + #text
  else
    local pieces = {}
    local start = 1
    while true do
      local nl = text:find("\n", start, true)
      if not nl then pieces[#pieces + 1] = text:sub(start); break end
      pieces[#pieces + 1] = text:sub(start, nl - 1)
      start = nl + 1
    end
    self.lines[self.line] = head .. pieces[1]
    for i = 2, #pieces do
      table.insert(self.lines, self.line + i - 1, pieces[i])
    end
    self.line = self.line + #pieces - 1
    self.col = #pieces[#pieces] + 1
    self.lines[self.line] = self.lines[self.line] .. tail
  end
  self.dirty = true
  self.goal_char = nil
end

--- The leading whitespace of a line, as a string.
local function indent_of(line)
  return line:match("^[ \t]*") or ""
end

--- Count the non-whitespace characters in `text` before byte `stop`.
local function ink_before(text, stop)
  return #(text:sub(1, stop - 1):gsub("%s", ""))
end

--- Turn "the Nth non-whitespace character of the document" back into a
--- (line, col) pair.
local function position_at_ink(lines, target)
  local seen = 0
  for index, line in ipairs(lines) do
    local col = 1
    while col <= #line do
      if not line:sub(col, col):match("%s") then
        if seen == target then return index, col end
        seen = seen + 1
      end
      col = M.next_boundary(line, col)
    end
    if seen == target then
      -- The caret belongs at the end of this line rather than at the start of
      -- the next: a formatter that moved a `{` down should not drag the caret
      -- with it.
      return index, #line + 1
    end
  end
  local last = #lines
  return last, #(lines[last] or "") + 1
end

--- Replace the whole buffer, keeping the caret where the player left it, as
--- **one undo step**.
---
--- This is what a FORMAT button does (PROTOCOL §4.9d), and it is the one
--- operation in this editor that can throw somebody to line 1 while they were
--- thinking.
---
--- **The anchor is the ink stream, not a coordinate and not a line.** A
--- formatter changes whitespace: it re-indents, it puts spaces around
--- operators, and — the case that matters — it *splits one long line into
--- several*. So the caret's position is recorded as "after the Nth
--- non-whitespace character of the whole document", and restored by counting
--- to the same N in the new text. Indentation, spacing and line breaks can
--- all change and the caret still lands between the same two characters.
---
--- The first version of this matched the caret's *line* by its stripped
--- content and fell back to the line number when nothing matched. Against a
--- fixture that only re-indented, it was perfect. Against real `rustfmt` on a
--- long one-liner — which is exactly when somebody reaches for FORMAT — no
--- line matched, the fallback fired, and the caret went to the end of line 1.
--- The exact-line pass is kept as a fast path because it is exact when a line
--- does survive; the ink stream is what catches everything else.
---
--- One `push_undo` and no other, so ctrl-Z puts the buffer back in one press.
function Editor:replace_all(text)
  if self.read_only then return false end
  local old_text = self:text()
  local old_line = self.lines[self.line] or ""
  local anchor = old_line:gsub("%s", "")
  local old_index = self.line
  local line_ink = ink_before(old_line, self.col)

  -- Where the caret is in the document's ink stream.
  local document_ink = 0
  for i = 1, self.line - 1 do
    document_ink = document_ink + #(self.lines[i]:gsub("%s", ""))
  end
  document_ink = document_ink + line_ink

  self:push_undo(false)
  self:set_text(text)

  local target, col
  -- Fast path: the same line still exists, so land on it exactly.
  if anchor ~= "" then
    local best
    for i, line in ipairs(self.lines) do
      if line:gsub("%s", "") == anchor then
        local distance = math.abs(i - old_index)
        if not best or distance < best then best, target = distance, i end
      end
    end
  end

  if target then
    local line = self.lines[target]
    local seen
    col, seen = 1, 0
    while col <= #line and seen < line_ink do
      local nextb = M.next_boundary(line, col)
      if not line:sub(col, nextb - 1):match("^%s") then seen = seen + 1 end
      col = nextb
    end
    if line_ink == 0 then col = (#(line:match("^[ \t]*") or "")) + 1 end
  else
    -- The line was split, joined or rewritten. Follow the ink.
    target, col = position_at_ink(self.lines, document_ink)
  end

  self.line = math.max(1, math.min(#self.lines, target))
  local line = self.lines[self.line] or ""
  self.col = math.max(1, math.min(#line + 1, col))
  self.anchor = nil
  self.goal_char = nil
  self.dirty = old_text ~= text
  return true
end

--- Enter: keep the indentation, and add a level after an opening brace.
---
--- The closing brace on the new line is matched back out, so typing
--- `fn main() {` + Enter + `}` lands the `}` where a Rust programmer expects
--- rather than four spaces in.
function Editor:newline()
  if self.read_only then return end
  self:push_undo(false)
  self:delete_selection()
  local current = self.lines[self.line]
  local head, tail = current:sub(1, self.col - 1), current:sub(self.col)
  local indent = indent_of(current)
  local opened = head:match("[{%(%[]%s*$") ~= nil
  if opened then
    indent = indent .. string.rep(" ", self.tab_width)
  end
  -- A closing brace that was already sitting after the cursor gets its own
  -- line at the outer indent: `{|}` + Enter is the shape everybody types.
  local closes = tail:match("^%s*[}%)%]]") ~= nil
  self.lines[self.line] = head
  if opened and closes then
    table.insert(self.lines, self.line + 1, indent)
    table.insert(self.lines, self.line + 2, indent_of(current) .. tail)
    self.line = self.line + 1
    self.col = #indent + 1
  else
    table.insert(self.lines, self.line + 1, indent .. tail)
    self.line = self.line + 1
    self.col = #indent + 1
  end
  self.dirty = true
  self.goal_char = nil
end

function Editor:backspace()
  if self.read_only then return end
  if self:has_selection() then
    self:push_undo(false)
    self:delete_selection()
    self.dirty = true
    return
  end
  if self.col > 1 then
    self:push_undo(true)
    local line = self.lines[self.line]
    -- Inside leading whitespace, one backspace eats a whole indent level.
    local before = line:sub(1, self.col - 1)
    if before:match("^ +$") and #before % self.tab_width == 0 then
      local back = self.tab_width
      self.lines[self.line] = line:sub(1, self.col - 1 - back) .. line:sub(self.col)
      self.col = self.col - back
    else
      local prev = M.prev_boundary(line, self.col)
      self.lines[self.line] = line:sub(1, prev - 1) .. line:sub(self.col)
      self.col = prev
    end
    self.dirty = true
  elseif self.line > 1 then
    self:push_undo(false)
    local above = self.lines[self.line - 1]
    local here = table.remove(self.lines, self.line)
    self.line = self.line - 1
    self.col = #above + 1
    self.lines[self.line] = above .. here
    self.dirty = true
  end
  self.goal_char = nil
end

function Editor:delete_forward()
  if self.read_only then return end
  if self:has_selection() then
    self:push_undo(false)
    self:delete_selection()
    self.dirty = true
    return
  end
  local line = self.lines[self.line]
  if self.col <= #line then
    self:push_undo(true)
    local nextb = M.next_boundary(line, self.col)
    self.lines[self.line] = line:sub(1, self.col - 1) .. line:sub(nextb)
    self.dirty = true
  elseif self.line < #self.lines then
    self:push_undo(false)
    local below = table.remove(self.lines, self.line + 1)
    self.lines[self.line] = line .. below
    self.dirty = true
  end
  self.goal_char = nil
end

--- Tab. With a selection, indent every touched line; without one, insert
--- spaces up to the next tab stop.
function Editor:indent(outdent)
  if self.read_only then return end
  local l1, _, l2 = self:selection()
  if l1 then
    self:push_undo(false)
    for l = l1, l2 do
      if outdent then
        local removed = self.lines[l]:match("^ ?" .. string.rep(" ?", self.tab_width - 1))
        removed = removed or ""
        self.lines[l] = self.lines[l]:sub(#removed + 1)
      else
        self.lines[l] = string.rep(" ", self.tab_width) .. self.lines[l]
      end
    end
    -- Keep the whole block selected so tab-tab-tab works.
    self.anchor = { line = l1, col = 1 }
    self.line = l2
    self.col = #self.lines[l2] + 1
    self.dirty = true
    return
  end
  self:push_undo(false)
  if outdent then
    local line = self.lines[self.line]
    local lead = indent_of(line)
    local drop = math.min(#lead, self.tab_width)
    if drop > 0 then
      self.lines[self.line] = line:sub(drop + 1)
      self.col = math.max(1, self.col - drop)
      self.dirty = true
    end
    return
  end
  -- Land on the next tab stop rather than always inserting four.
  local col_chars = M.char_count(self.lines[self.line]:sub(1, self.col - 1))
  local spaces = self.tab_width - (col_chars % self.tab_width)
  local line = self.lines[self.line]
  self.lines[self.line] = line:sub(1, self.col - 1) .. string.rep(" ", spaces) .. line:sub(self.col)
  self.col = self.col + spaces
  self.dirty = true
end

--- Toggle `// ` on every selected line, the way every editor's ctrl-/ does.
function Editor:toggle_comment()
  if self.read_only then return end
  local l1, _, l2 = self:selection()
  l1 = l1 or self.line
  l2 = l2 or self.line
  self:push_undo(false)
  local all_commented = true
  for l = l1, l2 do
    if self.lines[l]:match("%S") and not self.lines[l]:match("^%s*//") then
      all_commented = false
    end
  end
  for l = l1, l2 do
    if all_commented then
      self.lines[l] = self.lines[l]:gsub("^(%s*)// ?", "%1")
    elseif self.lines[l]:match("%S") then
      self.lines[l] = self.lines[l]:gsub("^(%s*)", "%1// ")
    end
  end
  self.col = math.min(self.col, #self.lines[self.line] + 1)
  self.dirty = true
end

-- ------------------------------------------------------------------- motion

local function is_word_byte(c)
  return c ~= nil and (c:match("[%w_]") ~= nil or c:byte() >= 0x80)
end

--- The start of the word to the left of `col`.
function M.word_left(line, col)
  local i = col
  while i > 1 and not is_word_byte(line:sub(i - 1, i - 1)) do i = i - 1 end
  while i > 1 and is_word_byte(line:sub(i - 1, i - 1)) do i = i - 1 end
  return i
end

--- The end of the word to the right of `col`.
function M.word_right(line, col)
  local n = #line
  local i = col
  while i <= n and not is_word_byte(line:sub(i, i)) do i = i + 1 end
  while i <= n and is_word_byte(line:sub(i, i)) do i = i + 1 end
  return i
end

function Editor:move(where, opts)
  opts = opts or {}
  self:prepare_motion(opts.extend)
  local line = self.lines[self.line]

  if where == "left" then
    if opts.word then
      self.col = M.word_left(line, self.col)
    elseif self.col > 1 then
      self.col = M.prev_boundary(line, self.col)
    elseif self.line > 1 then
      self.line = self.line - 1
      self.col = #self.lines[self.line] + 1
    end
    self.goal_char = nil
  elseif where == "right" then
    if opts.word then
      self.col = M.word_right(line, self.col)
    elseif self.col <= #line then
      self.col = M.next_boundary(line, self.col)
    elseif self.line < #self.lines then
      self.line = self.line + 1
      self.col = 1
    end
    self.goal_char = nil
  elseif where == "up" or where == "down" then
    -- The goal column survives a short line in between, which is what makes
    -- holding the up arrow through a block feel right.
    self.goal_char = self.goal_char or M.char_count(line:sub(1, self.col - 1))
    local step = (where == "up") and -1 or 1
    local target = self.line + step * (opts.page or 1)
    target = math.max(1, math.min(#self.lines, target))
    self.line = target
    local dest = self.lines[self.line]
    self.col = M.byte_at_char(dest, self.goal_char + 1)
  elseif where == "home" then
    -- First press goes to the first non-space; a second goes to column 1.
    local first = (#indent_of(line)) + 1
    self.col = (self.col == first) and 1 or first
    self.goal_char = nil
  elseif where == "end" then
    self.col = #line + 1
    self.goal_char = nil
  elseif where == "doc_start" then
    self.line, self.col = 1, 1
    self.goal_char = nil
  elseif where == "doc_end" then
    self.line = #self.lines
    self.col = #self.lines[self.line] + 1
    self.goal_char = nil
  end

  self.line = math.max(1, math.min(#self.lines, self.line))
  self.col = math.max(1, math.min(#(self.lines[self.line] or "") + 1, self.col))
end

--- Put the cursor at a document position, clamped.
function Editor:goto_position(line, col, extend)
  self:prepare_motion(extend)
  self.line = math.max(1, math.min(#self.lines, math.floor(line)))
  self.col = math.max(1, math.min(#self.lines[self.line] + 1, math.floor(col)))
  self.goal_char = nil
end

--- Keep the cursor inside a viewport `rows` lines tall.
function Editor:ensure_visible(rows)
  rows = math.max(1, rows or 20)
  if self.line - 1 < self.scroll then
    self.scroll = self.line - 1
  elseif self.line > self.scroll + rows then
    self.scroll = self.line - rows
  end
  local max_scroll = math.max(0, #self.lines - rows)
  self.scroll = math.max(0, math.min(max_scroll, self.scroll))
end

function Editor:scroll_by(lines, rows)
  self.scroll = self.scroll + lines
  local max_scroll = math.max(0, #self.lines - math.max(1, rows or 20))
  self.scroll = math.max(0, math.min(max_scroll, self.scroll))
end

-- --------------------------------------------------------------- clipboard

function Editor:copy()
  local text = self:selected_text()
  if text == "" then
    -- Nothing selected: copy the line, which is what every editor does.
    text = self:current_line()
  end
  self.clipboard.set(text)
  return text
end

function Editor:cut()
  local text = self:copy()
  if self:has_selection() then
    self:push_undo(false)
    self:delete_selection()
    self.dirty = true
  end
  return text
end

function Editor:paste()
  local text = self.clipboard.get()
  if text and text ~= "" then
    self:insert(text, false)
  end
  return text
end

-- ------------------------------------------------------------------- input

--- A printable character from `love.textinput`.
function Editor:textinput(text)
  if self.read_only then return end
  self:insert(text, true)
end

--- A key from `love.keypressed`.
---
--- `mods` is `{ ctrl =, shift =, alt =, gui = }`. `gui` is command on macOS,
--- where ⌘C is the copy everybody's fingers know; both are accepted.
--- Returns true when the key was consumed.
function Editor:keypressed(key, mods)
  mods = mods or {}
  local cmd = mods.ctrl or mods.gui
  local shift = mods.shift
  local word = mods.alt or mods.ctrl

  if cmd and key == "a" then self:select_all(); return true end
  if cmd and key == "c" then self:copy(); return true end
  if cmd and key == "x" then self:cut(); return true end
  if cmd and key == "v" then self:paste(); return true end
  if cmd and key == "z" then
    if shift then self:redo() else self:undo() end
    return true
  end
  if cmd and key == "y" then self:redo(); return true end
  if cmd and (key == "/" or key == "slash") then self:toggle_comment(); return true end
  if cmd and key == "home" then self:move("doc_start", { extend = shift }); return true end
  if cmd and key == "end" then self:move("doc_end", { extend = shift }); return true end

  if key == "left" then self:move("left", { extend = shift, word = word }); return true end
  if key == "right" then self:move("right", { extend = shift, word = word }); return true end
  if key == "up" then self:move("up", { extend = shift }); return true end
  if key == "down" then self:move("down", { extend = shift }); return true end
  if key == "home" then self:move("home", { extend = shift }); return true end
  if key == "end" then self:move("end", { extend = shift }); return true end
  if key == "pageup" then self:move("up", { extend = shift, page = 18 }); return true end
  if key == "pagedown" then self:move("down", { extend = shift, page = 18 }); return true end

  if key == "backspace" then self:backspace(); return true end
  if key == "delete" then self:delete_forward(); return true end
  if key == "return" or key == "kpenter" then self:newline(); return true end
  if key == "tab" then self:indent(shift); return true end

  return false
end

-- ------------------------------------------------------- syntax colouring

--- A tiny Rust tokenizer, for colour and nothing else.
---
--- It is line-at-a-time and deliberately not a parser: it has to be right
--- enough that keywords and strings stand out, and cheap enough to run on
--- every visible line every frame. Block comments carry their state across
--- lines through `state`, because `/* … */` around a hint is common.
---
--- Returns `spans, next_state` where each span is `{ text, kind }` and kind
--- is one of: text, keyword, type, string, number, comment, macro, punct.
M.KEYWORDS = {}
for w in ([[as async await break const continue crate dyn else enum extern false fn for if impl in
let loop match mod move mut pub ref return self Self static struct super trait true type union
unsafe use where while]]):gmatch("%S+") do
  M.KEYWORDS[w] = true
end

M.TYPES = {}
for w in ([[bool char str String Vec Option Result Box Rc Arc Mutex RwLock HashMap HashSet BTreeMap
i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 Some None Ok Err]]):gmatch("%S+") do
  M.TYPES[w] = true
end

function M.highlight(line, state)
  local spans = {}
  local i, n = 1, #line
  local start = 1
  state = state or "code"

  local function push(text, kind)
    if text ~= "" then spans[#spans + 1] = { text = text, kind = kind } end
  end

  while i <= n do
    if state == "block_comment" then
      local close = line:find("*/", i, true)
      if close then
        push(line:sub(i, close + 1), "comment")
        i = close + 2
        state = "code"
      else
        push(line:sub(i), "comment")
        i = n + 1
      end
      start = i
    else
      local c = line:sub(i, i)
      local two = line:sub(i, i + 1)
      if two == "//" then
        push(line:sub(i), "comment")
        i = n + 1
      elseif two == "/*" then
        state = "block_comment"
      elseif c == '"' then
        local j = i + 1
        while j <= n do
          local cj = line:sub(j, j)
          if cj == "\\" then
            j = j + 2
          elseif cj == '"' then
            j = j + 1
            break
          else
            j = j + 1
          end
        end
        push(line:sub(i, j - 1), "string")
        i = j
      elseif c:match("%d") and not line:sub(i - 1, i - 1):match("[%w_]") then
        local j = i
        while j <= n and line:sub(j, j):match("[%w_%.]") do j = j + 1 end
        push(line:sub(i, j - 1), "number")
        i = j
      elseif c:match("[%a_]") then
        local j = i
        while j <= n and line:sub(j, j):match("[%w_]") do j = j + 1 end
        local word = line:sub(i, j - 1)
        if line:sub(j, j) == "!" then
          push(word .. "!", "macro")
          j = j + 1
        elseif M.KEYWORDS[word] then
          push(word, "keyword")
        elseif M.TYPES[word] then
          push(word, "type")
        else
          push(word, "text")
        end
        i = j
      elseif c:match("[%p]") then
        push(c, "punct")
        i = i + 1
      else
        local j = i
        while j <= n and line:sub(j, j):match("%s") do j = j + 1 end
        push(line:sub(i, j - 1), "text")
        i = j
      end
      start = i
    end
  end
  if start <= n and state == "block_comment" then
    push(line:sub(start), "comment")
  end
  return spans, state
end

return M
