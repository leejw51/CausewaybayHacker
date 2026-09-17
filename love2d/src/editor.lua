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
--
-- ## The mouse, without a window
--
-- Drag-selection lives here too, and it has to, because the alternative is a
-- second selection mechanism in each of the two scenes that draw an editor.
-- The only thing the model cannot know is how wide a glyph is, so the pixel →
-- column step (`M.column_at`) takes a `measure` callback and the scenes hand
-- it `font:getWidth`. A fake `measure` in the suite is a fixed-width font,
-- which is exactly what the real one is.
--
-- ## Brackets
--
-- `M.brackets` pairs `()`, `[]` and `{}` across the whole buffer and — the
-- part that earns its place — names the ones that never found a partner. An
-- unbalanced brace is the most common reason a submission does not compile,
-- and it is invisible until the compiler says so.

local M = {}

local Editor = {}
Editor.__index = Editor
M.Editor = Editor

M.TAB_WIDTH = 4
--- The brackets that close themselves when `auto_close` is on, and what
--- closes them. `"` is in the list because a string is the other thing a
--- person opens and forgets.
M.PAIRS = { ["("] = ")", ["["] = "]", ["{"] = "}", ['"'] = '"' }
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

-- Filled in under "events" below; forward-declared because the edits that
-- report through them are defined first.
local emit, pending_erase

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
    --- Set while somebody else is writing into this editor, so the view keeps
    --- room under the caret rather than pinning it to the last row.
    follow = false,
    -- Bumped by every edit. The bracket analysis is a whole-buffer walk, so
    -- it is computed once per change and not once per frame.
    rev = 0,
    bracket_cache = nil,
    -- What the effects layer listens to: `function(ev)`, or nil. Every
    -- user-driven edit — `textinput`, `newline`, `backspace`,
    -- `delete_forward` — reports what it was (see `emit` below); the
    -- programmatic ones (`set_text`, `replace_all`, `insert` called by a
    -- scene) say nothing, so FORMAT is not a wall of bricks.
    on_event = nil,
    -- Whether `(`, `[`, `{` and `"` close themselves. Off by default so a
    -- test that types a program byte for byte still gets exactly its bytes;
    -- the scenes turn it on, and the ANSWER drill turns it back off.
    auto_close = opts.auto_close or false,
    -- Which land's loop keywords `loop_closed` reads: "rust", "go", "cpp"
    -- or "python". Nil reads like Rust.
    lang = opts.lang,
    -- The origin span of a mouse drag: nil when no button is down.
    drag = nil,
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

--- Mark the buffer as changed, so anything derived from it is recomputed.
---
--- Deliberately called at the *top* of every mutator rather than only where
--- an edit really happened: a spurious bump costs one re-analysis and a
--- missed one shows the player a bracket outline around text that has moved.
function Editor:bump()
  self.rev = self.rev + 1
end

function Editor:set_text(text)
  self:bump()
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

--- What a quest screen opens the buffer on: PROTOCOL §4.8's `draft ?? starter`.
---
--- `Quest.draft` is the source of the player's own most recent run or submit,
--- kept by the server because it already kept every attempt's source (SPEC
--- §2.2). There is no client-side save behind it and there must not be one:
--- the buffer is written to the server as a side effect of RUN and SUBMIT,
--- and this is the read.
---
--- Three cases, and the third is the one that would otherwise be a crash:
---
---   * a string — the player's own text, whatever it is. An **empty** draft
---     is still a draft: somebody who cleared the buffer and pressed RUN gets
---     an empty buffer back, which is what they left. The browser client
---     spells the same rule `draft ?? starter`, where `""` also survives.
---   * `nil` — a quest nobody has touched, so the starter.
---   * `json.null` — the sentinel `src/json.lua` decodes `null` to. In
---     practice `net/client.lua`'s `denull` has already turned it into `nil`
---     by the time a scene sees a payload, but a *table* is truthy in Lua, so
---     `draft or starter` on the raw thing would hand the editor a table.
---     Checked by type here for the same reason `Clock.parse` does.
function M.opening_text(quest)
  if type(quest) ~= "table" then return "" end
  if type(quest.draft) == "string" then return quest.draft end
  if type(quest.starter) == "string" then return quest.starter end
  return ""
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
  self:bump()
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
  self:bump()
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
  self:bump()
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
  self:bump()
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
  self:bump()
  self:push_undo(false)
  local erased = pending_erase(self)
  self:delete_selection()
  local ol, oc = M.loop_closed_by_newline(self.lines, self.line, self.col, self.lang)
  local left_line, left_col = self.line, self.col - 1
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
  if erased then emit(self, erased) end
  emit(self, { kind = "enter", line = self.line, col = self.col })
  if ol then
    emit(self, { kind = "loop", open = { ol, oc }, close = { left_line, math.max(1, left_col) } })
  end
end

function Editor:backspace()
  if self.read_only then return end
  self:bump()
  if self:has_selection() then
    self:push_undo(false)
    local erased = pending_erase(self)
    self:delete_selection()
    self.dirty = true
    emit(self, erased)
    return
  end
  if self.col > 1 then
    self:push_undo(true)
    local line = self.lines[self.line]
    -- Inside leading whitespace, one backspace eats a whole indent level.
    local before = line:sub(1, self.col - 1)
    local prev = M.prev_boundary(line, self.col)
    local gone = line:sub(prev, self.col - 1)
    if before:match("^ +$") and #before % self.tab_width == 0 then
      local back = self.tab_width
      self.lines[self.line] = line:sub(1, self.col - 1 - back) .. line:sub(self.col)
      self.col = self.col - back
      gone = string.rep(" ", back)
    elseif self.auto_close and M.PAIRS[gone] and line:sub(self.col, self.col) == M.PAIRS[gone] then
      -- Backspace inside a pair the editor made takes both halves.
      self.lines[self.line] = line:sub(1, prev - 1) .. line:sub(self.col + 1)
      self.col = prev
    else
      self.lines[self.line] = line:sub(1, prev - 1) .. line:sub(self.col)
      self.col = prev
    end
    self.dirty = true
    emit(self, { kind = "erase", line = self.line, col = self.col, text = gone,
      tones = { M.tone_at(line, prev) } })
  elseif self.line > 1 then
    self:push_undo(false)
    local above = self.lines[self.line - 1]
    local here = table.remove(self.lines, self.line)
    self.line = self.line - 1
    self.col = #above + 1
    self.lines[self.line] = above .. here
    self.dirty = true
    emit(self, { kind = "erase", line = self.line, col = self.col, text = "\n", tones = { "text" } })
  end
  self.goal_char = nil
end

function Editor:delete_forward()
  if self.read_only then return end
  self:bump()
  if self:has_selection() then
    self:push_undo(false)
    local erased = pending_erase(self)
    self:delete_selection()
    self.dirty = true
    emit(self, erased)
    return
  end
  local line = self.lines[self.line]
  if self.col <= #line then
    self:push_undo(true)
    local nextb = M.next_boundary(line, self.col)
    local gone = line:sub(self.col, nextb - 1)
    local tone = M.tone_at(line, self.col)
    self.lines[self.line] = line:sub(1, self.col - 1) .. line:sub(nextb)
    self.dirty = true
    emit(self, { kind = "erase", line = self.line, col = self.col, text = gone, tones = { tone } })
  elseif self.line < #self.lines then
    self:push_undo(false)
    local below = table.remove(self.lines, self.line + 1)
    self.lines[self.line] = line .. below
    self.dirty = true
    emit(self, { kind = "erase", line = self.line, col = self.col, text = "\n", tones = { "text" } })
  end
  self.goal_char = nil
end

--- Tab. With a selection, indent every touched line; without one, insert
--- spaces up to the next tab stop.
function Editor:indent(outdent)
  if self.read_only then return end
  self:bump()
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
  self:bump()
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
---
--- **`follow` is for watching somebody else write.** Left alone, the view
--- moves only when the caret would leave it, which is right for a person
--- typing: they know what they are about to write and they want the screen
--- still. It is wrong for watching the Rust coder, because the line being
--- written is then always the last row of the pane, hard against the border
--- and half-clipped, with nothing under it — the page technically scrolls and
--- reads as though it never does. Following keeps a few lines of daylight
--- under the caret, which means scrolling a little past the end of the file
--- while the end of the file is where the writing is.
function Editor:ensure_visible(rows)
  rows = math.max(1, rows or 20)
  local margin = 0
  if self.follow then margin = math.max(2, math.floor(rows / 4)) end
  margin = math.min(margin, math.floor((rows - 1) / 2))
  if self.line - 1 < self.scroll + margin then
    self.scroll = self.line - 1 - margin
  elseif self.line > self.scroll + rows - margin then
    self.scroll = self.line - rows + margin
  end
  local max_scroll = math.max(0, #self.lines - rows + margin)
  self.scroll = math.max(0, math.min(max_scroll, self.scroll))
end

--- Keep the caret inside a viewport `width` pixels wide, across.
---
--- The long-missing other half of `ensure_visible`. `scroll_x` has been a
--- field on this object since the beginning and nothing ever wrote to it, so
--- a line wider than the pane simply ran off the right edge, taking the caret
--- with it — invisible to a person typing, who stops at the edge, and very
--- visible when the Rust coder writes a long line and the text stops
--- appearing while the sound of typing goes on.
---
--- `measure(s)` is the pane's font, handed in rather than reached for: this
--- file has no `love` in it and cannot know how wide a character is.
--- `width` is the room the text has, gutter already taken off.
---
--- Kept in whole characters' worth of slack on each side, so the caret is
--- never flush against an edge it is about to cross.
function Editor:ensure_visible_across(measure, width)
  if not measure or not width or width <= 0 then return end
  local line = self.lines[self.line] or ""
  local caret = measure(line:sub(1, self.col - 1))
  -- A margin of two characters, so the next few keystrokes are already on
  -- the screen when they land rather than being chased one at a time.
  local slack = math.min(width / 3, measure("MM"))
  if caret - self.scroll_x > width - slack then
    self.scroll_x = caret - width + slack
  elseif caret - self.scroll_x < slack then
    self.scroll_x = caret - slack
  end
  -- Never past the longest line on the screen: scrolling into empty space to
  -- the right of everything is a view of nothing.
  local widest = 0
  local last = math.min(#self.lines, self.scroll + 200)
  for i = self.scroll + 1, last do
    local w = measure(self.lines[i] or "")
    if w > widest then widest = w end
  end
  self.scroll_x = math.max(0, math.min(math.max(0, widest - width + slack), self.scroll_x))
end

function Editor:scroll_by(lines, rows)
  self.scroll = self.scroll + lines
  local max_scroll = math.max(0, #self.lines - math.max(1, rows or 20))
  self.scroll = math.max(0, math.min(max_scroll, self.scroll))
end

-- -------------------------------------------------------------- the mouse

--- Which column a click `target_x` pixels into the text lands on.
---
--- `measure(s)` returns the pixel width of `s` in the pane's font. It is
--- injected because this file must not name `love.graphics`, and because a
--- fixed-width stub in the suite *is* a monospace font — which is the only
--- kind this editor is ever drawn in.
---
--- The **nearest** boundary wins, not the last one that starts before the
--- click. Clicking the right-hand half of a character puts the caret after
--- it, which is what every editor does and what makes a drag that starts in
--- the middle of a character include that character.
function M.column_at(line, target_x, measure)
  if target_x <= 0 or #line == 0 then return 1 end
  local best_col, best_d = 1, math.abs(target_x)
  local col = 1
  while col <= #line do
    local nextb = M.next_boundary(line, col)
    local w = measure(line:sub(1, nextb - 1))
    local d = math.abs(w - target_x)
    if d < best_d then
      best_col, best_d = nextb, d
    elseif w > target_x then
      -- Past the click and no longer improving. Widths only grow, so every
      -- later boundary is further away than this one.
      break
    end
    col = nextb
  end
  return best_col
end

--- What kind of run a byte belongs to, for double-click granularity.
local function class_of(c)
  if c == nil or c == "" then return "none" end
  if c:match("%s") then return "space" end
  if is_word_byte(c) then return "word" end
  return "punct"
end

--- The run of like characters around `col`: an identifier, a stretch of
--- whitespace, or a stretch of punctuation. Returned as `from, to` with `to`
--- one past the end, the same half-open shape as a selection.
function M.word_span(line, col)
  if #line == 0 then return 1, 1 end
  if col > #line then col = M.prev_boundary(line, col) end
  local kind = class_of(line:sub(col, col))
  local from = col
  while from > 1 do
    local p = M.prev_boundary(line, from)
    if class_of(line:sub(p, p)) ~= kind then break end
    from = p
  end
  local to = M.next_boundary(line, col)
  while to <= #line do
    if class_of(line:sub(to, to)) ~= kind then break end
    to = M.next_boundary(line, to)
  end
  return from, to
end

local function before(l1, c1, l2, c2)
  return l1 < l2 or (l1 == l2 and c1 < c2)
end

function Editor:clamp(line, col)
  line = math.max(1, math.min(#self.lines, math.floor(line or 1)))
  col = math.max(1, math.min(#(self.lines[line] or "") + 1, math.floor(col or 1)))
  return line, col
end

--- The span a press at `(line, col)` selects, given the click granularity.
function Editor:span_for(line, col, mode)
  line, col = self:clamp(line, col)
  if mode == "word" then
    local from, to = M.word_span(self.lines[line] or "", col)
    return line, from, line, to
  elseif mode == "line" then
    if line < #self.lines then return line, 1, line + 1, 1 end
    return line, 1, line, #(self.lines[line] or "") + 1
  end
  return line, col, line, col
end

--- Press: start a mouse selection at `(line, col)`.
---
--- `mode` is `"char"` for a click, `"word"` for a double click and `"line"`
--- for a triple. The **origin** of a word or line drag is the whole word or
--- line, so dragging out of a double click grows by words the way it does in
--- every other editor rather than collapsing back to one character.
---
--- `extend` is a shift-click: it keeps the existing anchor and only moves the
--- far end, so shift-clicking twice grows the same selection.
function Editor:begin_select(line, col, mode, extend)
  mode = mode or "char"
  line, col = self:clamp(line, col)
  if extend then
    -- Shift-click with no selection yet extends from where the caret is,
    -- which is what the keyboard's shift-arrow does from the same place.
    local al = self.anchor and self.anchor.line or self.line
    local ac = self.anchor and self.anchor.col or self.col
    self.drag = { mode = "char", l1 = al, c1 = ac, l2 = al, c2 = ac }
    self:drag_to(line, col)
    return
  end
  local l1, c1, l2, c2 = self:span_for(line, col, mode)
  self.drag = { mode = mode, l1 = l1, c1 = c1, l2 = l2, c2 = c2 }
  if mode == "char" then
    self.anchor = nil
    self.line, self.col = l1, c1
  else
    self.anchor = { line = l1, col = c1 }
    self.line, self.col = l2, c2
  end
  self.goal_char = nil
end

--- Move: extend the live selection to `(line, col)`. A no-op with no button
--- down, which is what keeps a stray `mousemoved` from dragging the caret
--- around while somebody is only passing over the pane.
function Editor:drag_to(line, col)
  local drag = self.drag
  if not drag then return false end
  line, col = self:clamp(line, col)
  local tl1, tc1, tl2, tc2 = self:span_for(line, col, drag.mode)

  local al, ac, cl, cc
  if before(tl1, tc1, drag.l1, drag.c1) then
    -- Dragging backwards: the anchor sits at the far end of the origin.
    al, ac = drag.l2, drag.c2
    cl, cc = tl1, tc1
  else
    al, ac = drag.l1, drag.c1
    cl, cc = tl2, tc2
  end

  self.line, self.col = self:clamp(cl, cc)
  if al == self.line and ac == self.col then
    self.anchor = nil
  else
    self.anchor = { line = al, col = ac }
  end
  self.goal_char = nil
  return true
end

--- Release. The drag is over; the selection it made stays.
function Editor:end_select()
  local was = self.drag ~= nil
  self.drag = nil
  return was
end

function Editor:dragging()
  return self.drag ~= nil
end

-- ------------------------------------------------------------------ brackets

--- The three bracket pairs this editor matches, and deliberately no more.
---
--- `<` and `>` are **not** here. In Rust they are comparison, `->`, `=>` and
--- generics in roughly equal measure, and a matcher that guessed at them
--- would be confidently wrong on the screen where being wrong is most
--- expensive. A player writing `Vec<u8>` is better served by no marking than
--- by a marking that disagrees with the compiler.
M.OPENERS = { ["("] = ")", ["["] = "]", ["{"] = "}" }
M.CLOSERS = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

local function bracket_key(line, col)
  return line .. ":" .. col
end
M.bracket_key = bracket_key

--- Pair every bracket in `lines`, and name the ones that never found a
--- partner.
---
--- **Which bytes are code is decided by `M.highlight`**, the same tokenizer
--- that colours the pane — not by a second scanner. Two scanners that
--- disagreed would draw a brace as matched while colouring it as part of a
--- string, and a feature that contradicts the screen it sits on is worse
--- than no feature. So a brace inside a string literal or a comment is text
--- and is not counted, and block comments carry across lines because
--- `highlight` already carries that state.
---
--- Known gap, recorded rather than papered over: `highlight` does not know
--- about `'`, so a `'}'` character literal counts as a brace and a lifetime
--- is punctuation. Neither appears often in a forty-line interview answer,
--- and fixing it means rewriting the tokenizer that the colouring already
--- depends on.
---
--- Returns `at, unmatched`:
---   `at[bracket_key(line, col)]` = `{ line, col, char, open, partner }`
---   `unmatched`                  = those with no partner, in document order
function M.brackets(lines)
  local at, order, stack, unmatched = {}, {}, {}, {}
  local state = "code"
  for index, line in ipairs(lines) do
    local spans
    spans, state = M.highlight(line, state)
    local col = 1
    for _, span in ipairs(spans) do
      if span.kind == "punct" then
        local ch = span.text
        if M.OPENERS[ch] or M.CLOSERS[ch] then
          local entry = { line = index, col = col, char = ch,
            open = M.OPENERS[ch] ~= nil }
          at[bracket_key(index, col)] = entry
          order[#order + 1] = entry
        end
      end
      col = col + #span.text
    end
  end

  for _, entry in ipairs(order) do
    if entry.open then
      stack[#stack + 1] = entry
    else
      local top = stack[#stack]
      if top and M.OPENERS[top.char] == entry.char then
        stack[#stack] = nil
        top.partner = entry
        entry.partner = top
      else
        -- A closer with nothing open, or the wrong kind of closer. The
        -- opener it did not match stays on the stack and is reported too,
        -- because both ends of a mismatch are worth looking at.
        unmatched[#unmatched + 1] = entry
      end
    end
  end
  for _, entry in ipairs(stack) do
    unmatched[#unmatched + 1] = entry
  end
  table.sort(unmatched, function(a, b)
    if a.line ~= b.line then return a.line < b.line end
    return a.col < b.col
  end)
  return at, unmatched
end

--- The analysis of the current buffer, recomputed only when it changes.
function Editor:brackets()
  local cache = self.bracket_cache
  if cache and cache.rev == self.rev then return cache.at, cache.unmatched end
  local at, unmatched = M.brackets(self.lines)
  self.bracket_cache = { rev = self.rev, at = at, unmatched = unmatched }
  return at, unmatched
end

function Editor:unmatched_brackets()
  local _, unmatched = self:brackets()
  return unmatched
end

--- The set of line numbers carrying an unmatched bracket, so the gutter can
--- say so for a line whose bracket has scrolled off the side.
function Editor:unmatched_lines()
  local cache = self.bracket_cache
  if cache and cache.rev == self.rev and cache.lines then return cache.lines end
  local _, unmatched = self:brackets()
  local set = {}
  for _, entry in ipairs(unmatched) do set[entry.line] = true end
  self.bracket_cache.lines = set
  return set
end

--- The bracket the caret is touching, with `.partner` set when it has one.
---
--- The bracket **before** the caret wins over the one after it: that is what
--- makes the pair light up the instant a closing brace is typed, which is the
--- moment the information is worth most.
function Editor:bracket_at_caret()
  local at = self:brackets()
  local line = self.lines[self.line] or ""
  local cols = {}
  if self.col > 1 then cols[#cols + 1] = M.prev_boundary(line, self.col) end
  if self.col <= #line then cols[#cols + 1] = self.col end
  for _, col in ipairs(cols) do
    local entry = at[bracket_key(self.line, col)]
    if entry then return entry end
  end
  return nil
end

--- Jump to the partner of the bracket at the caret. False when there is no
--- bracket there, or when it has no partner — which is itself worth knowing.
function Editor:goto_match(extend)
  local entry = self:bracket_at_caret()
  if not (entry and entry.partner) then return false end
  self:goto_position(entry.partner.line, entry.partner.col, extend)
  return true
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
-- ------------------------------------------------------------------ events
--
-- What typing *does*, for the effects layer (`src/codefx.lua`). The editor is
-- the game's controller on the code screens, and a controller that only says
-- "the buffer changed" is a controller with one button. So each user-driven
-- edit reports what it was, with `(line, col)` positions the pane can turn
-- into pixels:
--
--   { kind = "type",  line, col, text, tone }          -- caret after it
--   { kind = "erase", line, col, text, tones }         -- where it started
--   { kind = "enter", line, col }                      -- caret on the new line
--   { kind = "loop",  open = {line, col}, close = {line, col} }
--
-- `tone` is the highlighter's kind for the character (keyword, string, …)
-- or "bracket"; `tones` is one per byte of `text`. Pure, so the rules are
-- under `tests/test_fxplan.lua`.

emit = function(self, ev)
  if self.on_event then self.on_event(ev) end
end

--- The highlighter's kind for the byte at `col` of `line`, "bracket" for a
--- bracket, "text" for whitespace and anything else.
function M.tone_at(line, col)
  local ch = line:sub(col, col)
  if ch == "" then return "text" end
  if ("()[]{}"):find(ch, 1, true) then return "bracket" end
  local spans = M.highlight(line, "code")
  local at = 1
  for _, span in ipairs(spans) do
    if col < at + #span.text then return span.kind end
    at = at + #span.text
  end
  return "text"
end

--- One tone per byte of `lines[l1]:sub(c1)` … `lines[l2]:sub(1, c2 - 1)`,
--- read before the range is removed. Newlines are "text".
local function tones_for(lines, l1, c1, l2, c2)
  local out = {}
  for index = l1, l2 do
    local line = lines[index] or ""
    local from = (index == l1) and c1 or 1
    local to = (index == l2) and (c2 - 1) or #line
    local spans = M.highlight(line, "code")
    local kinds, at = {}, 1
    for _, span in ipairs(spans) do
      for _ = 1, #span.text do
        kinds[at] = span.kind
        at = at + 1
      end
    end
    for col = from, to do
      local ch = line:sub(col, col)
      if ("()[]{}"):find(ch, 1, true) then
        out[#out + 1] = "bracket"
      else
        out[#out + 1] = kinds[col] or "text"
      end
    end
    if index < l2 then out[#out + 1] = "text" end
  end
  return out
end

--- The loop keywords per land, as the statement a brace closes must start.
local LOOP_HEAD = {
  rust = { "^%s*'?[%w_]*:?%s*for%f[^%w_]", "^%s*'?[%w_]*:?%s*while%f[^%w_]", "^%s*'?[%w_]*:?%s*loop%f[^%w_]" },
  go = { "^%s*for%f[^%w_]" },
  cpp = { "^%s*for%f[^%w_]", "^%s*while%f[^%w_]" },
}
LOOP_HEAD.python = { "^%s*for%f[^%w_]", "^%s*while%f[^%w_]" }

local function loop_head(lang, head)
  for _, pat in ipairs(LOOP_HEAD[lang] or LOOP_HEAD.rust) do
    if head:find(pat) then return true end
  end
  return false
end

--- Whether the `}` at `(line, col)` of `lines` closes a loop, and where the
--- loop's keyword is.
---
--- The brace is looked up in the bracket analysis — so a `}` inside a string
--- or a comment, which the highlighter says is not punctuation, is not a
--- closer — and its partner's line is read up to the opener: a loop is
--- `for …`, `while …` or Rust's `loop`, with an optional label. Returns the
--- keyword's `(line, col)` or nil.
function M.loop_closed_by_brace(lines, line, col, lang)
  local at = M.brackets(lines)
  local entry = at[M.bracket_key(line, col)]
  if not (entry and entry.char == "}" and entry.partner) then return nil end
  local opener = entry.partner
  local head = (lines[opener.line] or ""):sub(1, opener.col - 1)
  if not loop_head(lang, head) then return nil end
  local first = head:find("%S") or 1
  return opener.line, first
end

--- C++'s `do { … } while (cond);` closes on its `;`, not its brace: the `}`
--- the `while (…);` follows is looked up and its opener's line must be `do`.
function M.loop_closed_by_semicolon(lines, line, col, lang)
  if lang ~= "cpp" then return nil end
  local text = lines[line] or ""
  if col ~= #text then return nil end
  -- The `}` that the `while (…);` follows — wherever on the line it is, so
  -- `do { x++; } while (x < 3);` on one line counts as well as three.
  local brace = text:find("}%s*while%s*%b()%s*;$")
  if not brace then return nil end
  local at = M.brackets(lines)
  local entry = at[M.bracket_key(line, brace)]
  if not (entry and entry.partner) then return nil end
  local opener = entry.partner
  local head = (lines[opener.line] or ""):sub(1, opener.col - 1)
  if not head:find("^%s*do%s*$") then return nil end
  return opener.line, head:find("%S") or 1
end

--- Python has no closer, so a loop is done when its body has something in
--- it: ENTER at the end of the *first* body line — the line right under a
--- `for …:` / `while …:` header, indented deeper than it — and only that
--- line, or every line of a long body would be a celebration. `line` is the
--- line being left, before the newline goes in.
function M.loop_closed_by_newline(lines, line, col, lang)
  if lang ~= "python" then return nil end
  local text = lines[line] or ""
  if col ~= #text + 1 or text:find("^%s*$") then return nil end
  local header = lines[line - 1]
  if not header then return nil end
  if not (loop_head("python", header) and header:find(":%s*$")) then return nil end
  local hi = #(header:match("^%s*") or "")
  local ti = #(text:match("^%s*") or "")
  if ti <= hi then return nil end
  return line - 1, hi + 1
end

--- The erase event for the current selection, computed before it goes.
pending_erase = function(self)
  local l1, c1, l2, c2 = self:selection()
  if not l1 then return nil end
  return {
    kind = "erase", line = l1, col = c1,
    text = self:selected_text(),
    tones = tones_for(self.lines, l1, c1, l2, c2),
  }
end

function Editor:textinput(text)
  if self.read_only then return end
  local erased = pending_erase(self)
  local line = self.lines[self.line]
  local after = line:sub(self.col, self.col)
  if self.auto_close and not erased and #text == 1 then
    -- Typing the closer the editor already put there steps over it.
    if M.PAIRS[text] == nil and (")]}"):find(text, 1, true) and after == text then
      self:bump()
      self.col = self.col + 1
      emit(self, { kind = "type", line = self.line, col = self.col, text = text, tone = "bracket" })
      return
    end
    if text == '"' and after == '"' then
      self:bump()
      self.col = self.col + 1
      emit(self, { kind = "type", line = self.line, col = self.col, text = text, tone = "string" })
      return
    end
    local closer = M.PAIRS[text]
    -- An opener closes itself when nothing is pressed up against its right:
    -- end of line, a space, or another closer. Typed against a word it is
    -- the person's own bracket, and a quote after a letter is an apostrophe
    -- in disguise.
    local before = line:sub(self.col - 1, self.col - 1)
    local open_here = closer and (after == "" or after:match("[%s%)%]}]"))
      and not (text == '"' and before:match("[%w_]"))
    if open_here then
      self:insert(text .. closer, true)
      self.col = self.col - #closer
      emit(self, { kind = "type", line = self.line, col = self.col, text = text,
        tone = text == '"' and "string" or "bracket" })
      return
    end
  end
  self:insert(text, true)
  if erased then emit(self, erased) end
  local tone = M.tone_at(self.lines[self.line], self.col - 1)
  emit(self, { kind = "type", line = self.line, col = self.col, text = text, tone = tone })
  local last = text:sub(-1)
  local ol, oc
  if last == "}" then
    ol, oc = M.loop_closed_by_brace(self.lines, self.line, self.col - 1, self.lang)
  elseif last == ";" then
    ol, oc = M.loop_closed_by_semicolon(self.lines, self.line, self.col - 1, self.lang)
  end
  if ol then
    emit(self, { kind = "loop", open = { ol, oc }, close = { self.line, self.col - 1 } })
  end
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
  -- Jump to the other end of the block. `]` is free here — the bare key is a
  -- character the player types, and no global shortcut takes it with ctrl.
  if cmd and (key == "]" or key == "rightbracket") then
    self:goto_match(shift)
    return true
  end
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
