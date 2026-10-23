-- The quiz, the part with no canvas in it (PROTOCOL §5.3 `quiz`).
--
-- The web client's `frontend/src/ui/quiz.ts`, for LÖVE, and a little more:
-- what the quest scene needs to decide without a window. Every road is
-- picked, not typed (SPEC §0): a quest is a program with a hole and four
-- choices for it, one right, and the pick is the submission's `source`. The
-- server judges it; this only says what a pick *means* on this screen, how
-- the program around the hole is cut, and where a choice may take a tap.
--
-- Choices here are **1-based**, the way a Lua table and a keyboard both count
-- them. The wire's `quiz.answer` is 0-based, and the one place the two meet
-- is `pick`.
--
-- Pure: no `love`, no fonts. A function that has to measure text is handed a
-- `measure(s) -> px`, so `tests/test_quiz.lua` runs under a bare luajit.

local Quiz = {}

-- Defined further down, used above it.
local split_lines

--- What stands in a quiz's program where the right choice was cut out.
Quiz.HOLE = "____"

--- The longest program shown whole; past it, a window around the hole.
Quiz.PROGRAM_WHOLE = 40

--- Seconds the right pick's fireworks get before the verdict screen takes
--- over. The web waits 1100 ms; a client that went straight to the result
--- played its celebration on a screen nobody was looking at any more.
Quiz.HOLD = 1.1

--- How long a wrong pick's row shakes, in seconds. The row itself stays red,
--- struck through and dead for the rest of the attempt (spec §4).
Quiz.WRONG_LIFE = 0.3

--- How long the card's heading reads "NOT THAT ONE — n LEFT" after a miss.
Quiz.NOT_THAT_LIFE = 1.5

--- Seconds per character while the right line is typed into the hole.
Quiz.TYPE_RATE = 0.015

--- What choosing `i` means, given whether the quiz was already answered and
--- which choices were already ruled out: "right", "wrong" or "ignored".
--- Anything out of range, anything that is not a whole number, anything
--- after the unlock, and a line already struck through is ignored.
function Quiz.pick(quiz, i, already_right, wrong)
  if not quiz or already_right then return "ignored" end
  local choices = quiz.choices
  if type(choices) ~= "table" or type(i) ~= "number" or i ~= math.floor(i)
    or i < 1 or i > #choices then
    return "ignored"
  end
  if wrong and wrong[i] then return "ignored" end
  return (i - 1) == quiz.answer and "right" or "wrong"
end

--- How many of `n` choices are still open, given the set of wrong ones.
function Quiz.remaining(n, wrong)
  local left = n or 0
  for i = 1, n or 0 do
    if wrong and wrong[i] then left = left - 1 end
  end
  return math.max(0, left)
end

--- The stars a clear would earn now (SPEC §6.3, the server's
--- `progress::stars_for`): 3 with no miss and no hint; 2 with a hint or up
--- to two misses; 1 otherwise. "Misses" are this visit's, because the wire
--- carries no count of earlier ones; a cleared quest shows its real stars.
function Quiz.stars_potential(misses, hints_used)
  misses = misses or 0
  hints_used = hints_used or 0
  if misses == 0 and hints_used == 0 then return 3 end
  if hints_used > 0 or misses <= 2 then return 2 end
  return 1
end

--- The program cut to a window of at most `rows` lines with the hole in the
--- middle of it — for the well beside the four, which has a height, not a
--- line count. A program that fits is whole. Each `⋮` for lines left out
--- takes one of the rows. `rows` is never under 3: a cut, the hole, a cut.
function Quiz.window_lines(program, rows)
  rows = math.max(3, math.floor(rows or 5))
  local text = tostring(program or ""):gsub("^\n+", ""):gsub("\n+$", "")
  local lines = split_lines(text)
  local hole
  for i, line in ipairs(lines) do
    if hole == nil and Quiz.is_hole(line) then hole = i end
  end
  if #lines <= rows or not hole then
    return Quiz.program_lines(program, nil, nil, math.max(#lines, rows))
  end
  local from = math.max(1, hole - math.floor((rows - 1) / 2))
  local to = from + rows - 1
  if to > #lines then
    to = #lines
    from = math.max(1, to - rows + 1)
  end
  if from > 1 then from = from + 1 end
  if to < #lines then to = to - 1 end
  from = math.min(from, hole)
  to = math.max(to, hole)
  return Quiz.program_lines(program, hole - from, to - hole, 0)
end

--- The lines of a program window that are code (not a `⋮`), and which of
--- them is the hole — so a caller can size a well from the count.
function Quiz.hole_index(lines)
  for i, line in ipairs(lines or {}) do
    if line.kind == "hole" then return i end
  end
  return nil
end

--- The answer typed into the hole so far: `text` cut to the characters
--- `Quiz.TYPE_RATE` allows `elapsed` seconds after the pick. Whole once the
--- typing is done; nil before it starts.
function Quiz.typed(text, elapsed)
  if elapsed == nil or elapsed < 0 then return nil end
  local n = math.floor(elapsed / Quiz.TYPE_RATE)
  local out, k = {}, 0
  for ch in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if k >= n then break end
    out[#out + 1] = ch
    k = k + 1
  end
  return table.concat(out)
end

--- The story's first sentence, when it is short enough to stand as a lead
--- ("06:30, Jardine's Bazaar."), and the rest. A story with no such lead is
--- all rest.
function Quiz.story_lead(story, max)
  story = tostring(story or ""):gsub("^%s+", ""):gsub("%s+$", "")
  max = max or 40
  local lead, rest = story:match("^(.-[%.!?。！？])%s+(.+)$")
  if lead and #lead <= max then return lead, rest end
  return nil, story
end

--- A sheet brief's blocks with the trailing "Which line is it?" dropped: the
--- card's own heading says PICK THE RIGHT LINE, and the question would say
--- it twice. Only a short last prose block that ends in a question mark.
function Quiz.question_blocks(blocks)
  local out = {}
  for i, b in ipairs(blocks or {}) do out[i] = b end
  local last = out[#out]
  if last and last.kind == "prose" and #last.text <= 40
    and (last.text:match("%?%s*$") or last.text:match("？%s*$")) then
    out[#out] = nil
  end
  return out
end

--- A choice row's height: its lines of code with `pad` above and below,
--- never under `min` (64 landscape, 72 upright per the spec).
function Quiz.row_height(lines, lh, pad, min)
  return math.max(min or 64, (lines or 1) * lh + 2 * (pad or 12))
end

--- Whether a quest opens with its editor locked behind the quiz. A cleared
--- quest is past its quiz.
function Quiz.starts_locked(quiz, state)
  return quiz ~= nil and state ~= "cleared"
end

--- The part of a choice's box that is inside the scrolling panel, or nil
--- when none of it is: the brief scrolls, and a choice scrolled out of the
--- panel must not take a tap meant for whatever is drawn there.
function Quiz.visible_box(box, clip)
  local top = math.max(box.y, clip.y)
  local bottom = math.min(box.y + box.h, clip.y + clip.h)
  if bottom <= top then return nil end
  return { x = box.x, y = top, w = box.w, h = bottom - top }
end

--- The four wells, stacked from `y` in a column `w` wide: one rectangle per
--- choice, each as tall as its wrapped text needs.
function Quiz.boxes(x, y, w, heights, gap)
  local out = {}
  for i, h in ipairs(heights) do
    out[i] = { x = x, y = y, w = w, h = h }
    y = y + h + (gap or 6)
  end
  return out
end

--- The wells laid out `cols` across, row by row: each row as tall as its
--- tallest choice, each cell `(w - gap) / cols` wide. One column is
--- `boxes` exactly. Two is the landscape card for short choices — four
--- one-liners stacked down a 1200-pixel panel were four bars of mostly
--- nothing, and a 2×2 grid puts all four under the eye at once.
function Quiz.grid(x, y, w, heights, cols, gap)
  gap = gap or 6
  cols = math.max(1, cols or 1)
  if cols == 1 then return Quiz.boxes(x, y, w, heights, gap) end
  local cell = math.floor((w - gap * (cols - 1)) / cols)
  local out = {}
  local n = #heights
  for row = 0, math.ceil(n / cols) - 1 do
    local h = 0
    for c = 1, cols do
      local i = row * cols + c
      if heights[i] then h = math.max(h, heights[i]) end
    end
    for c = 1, cols do
      local i = row * cols + c
      if i <= n then
        out[i] = { x = x + (c - 1) * (cell + gap), y = y, w = cell, h = h }
      end
    end
    y = y + h + gap
  end
  return out
end

--- How many columns the four go in: two only in landscape, and only when
--- every choice is one line at half the width (`lines_at_half[i]` is how
--- many lines choice `i` wraps to in a half-width cell) and a half is at
--- least `min` wide. Anything that would wrap stays one full-width bar, so a
--- long line of code is never squeezed into a column it has to fold in.
function Quiz.choice_cols(portrait, width, lines_at_half, min)
  if portrait or width < (min or 0) * 2 then return 1 end
  for _, n in ipairs(lines_at_half) do
    if n > 1 then return 1 end
  end
  return 2
end

--- Whether a line of code is the hole: `____` and nothing else but space.
function Quiz.is_hole(line)
  return tostring(line):match("^%s*(.-)%s*$") == Quiz.HOLE
end

--- Whether a line of a brief's snippet carries the hole anywhere in it — a
--- sheet question's fence has `// ____` where the answer goes.
function Quiz.has_hole(line)
  return tostring(line):find(Quiz.HOLE, 1, true) ~= nil
end

split_lines = function(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end

--- The program around a quiz's hole, as the brief draws it (SPEC §0: every
--- road is picked). A short one is shown whole. A long one — a HACKER
--- solution runs to eighty lines — is cut to `before` lines above the hole
--- and `after` below it, with a `⋮` where lines were left out: the four
--- choices sit under it, and a program the player must scroll past to reach
--- them is a quiz nobody answers. Each line is
--- `{ kind = "code"|"hole"|"cut", text = … }`.
function Quiz.program_lines(program, before, after, whole)
  before, after, whole = before or 22, after or 14, whole or Quiz.PROGRAM_WHOLE
  local text = tostring(program or ""):gsub("^\n+", ""):gsub("\n+$", "")
  local lines = split_lines(text)
  local hole
  for i, line in ipairs(lines) do
    if hole == nil and Quiz.is_hole(line) then hole = i end
  end
  local function as(i)
    return { kind = i == hole and "hole" or "code", text = lines[i] }
  end
  local out = {}
  if #lines <= whole or not hole then
    for i = 1, #lines do out[#out + 1] = as(i) end
    return out
  end
  local from = math.max(1, hole - before)
  local to = math.min(#lines, hole + after)
  if from > 1 then out[#out + 1] = { kind = "cut", text = "⋮" } end
  for i = from, to do out[#out + 1] = as(i) end
  if to < #lines then out[#out + 1] = { kind = "cut", text = "⋮" } end
  return out
end

--- Strip the inline markers that would otherwise be read aloud as
--- punctuation: `**`, `*`, backticks, heading hashes, list bullets.
function Quiz.inline(text)
  text = tostring(text)
  text = text:gsub("%*%*(.-)%*%*", "%1")
  text = text:gsub("%*([^%*\n]+)%*", "%1")
  text = text:gsub("`([^`]+)`", "%1")
  local out = {}
  for _, line in ipairs(split_lines(text)) do
    line = line:gsub("^%s?%s?%s?#+%s+", "")
    line = line:gsub("^%s?%s?%s?[%-%*%+]%s+", "· ")
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

--- Just enough markdown to draw a quest brief: the web's `blocks`
--- (`frontend/src/ui/markdown.ts`). A brief is markdown (SPEC §2.1) and the
--- canvas has no renderer; showing the source put ```` ``` ```` and `**` on
--- the screen around the very snippet the question is about. Fenced blocks
--- become `{ kind = "code" }`, everything else `{ kind = "prose" }` with the
--- inline markers taken out. A fence with nothing in it is dropped; an
--- unterminated one is still content.
function Quiz.blocks(markdown)
  local out = {}
  local prose, code = {}, nil
  local function flush()
    if #prose == 0 then return end
    local text = Quiz.inline(table.concat(prose, "\n"))
      :gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if text ~= "" then out[#out + 1] = { kind = "prose", text = text } end
    prose = {}
  end
  for _, line in ipairs(split_lines(tostring(markdown or ""))) do
    if line:match("^%s*```") then
      if code == nil then
        flush()
        code = {}
      else
        local body = table.concat(code, "\n")
        if body:match("%S") then out[#out + 1] = { kind = "code", text = body } end
        code = nil
      end
    elseif code then
      code[#code + 1] = line
    else
      prose[#prose + 1] = line
    end
  end
  if code and table.concat(code, "\n"):match("%S") then
    out[#out + 1] = { kind = "code", text = table.concat(code, "\n") }
  end
  flush()
  return out
end

--- A prose block as the lines to wrap: markdown's soft breaks joined, so a
--- sentence the pack broke at column 72 is not drawn broken at column 72
--- *and* at the panel's edge; a blank line between paragraphs kept as "";
--- a bullet starting its own line.
function Quiz.blocks_lines(text)
  local out, para = {}, nil
  local function flush()
    if para then out[#out + 1] = para; para = nil end
  end
  for _, line in ipairs(split_lines(tostring(text or ""))) do
    local body = line:match("^%s*(.-)%s*$")
    if body == "" then
      flush()
      if #out > 0 and out[#out] ~= "" then out[#out + 1] = "" end
    elseif body:sub(1, #"· ") == "· " then
      flush()
      para = body
    else
      para = para and (para .. " " .. body) or body
    end
  end
  flush()
  if out[#out] == "" then out[#out] = nil end
  return out
end

--- Wrap code to a pixel `width`, measured by `measure(s) -> px` in the face
--- it will be drawn in. Each line keeps its indentation, and a piece that
--- wraps keeps it too, so a long line of a nested block still reads as part
--- of the block. Go's tabs go in as four spaces because the face draws a tab
--- as nothing. A run with no space in it (a long chain of calls) is broken
--- where it meets the edge rather than allowed through it.
function Quiz.code_wrap(text, width, measure)
  local out = {}
  local text_s = tostring(text):gsub("\t", "    "):gsub("^\n+", ""):gsub("\n+$", "")
  for _, raw in ipairs(split_lines(text_s)) do
    local lead, rest = raw:match("^( *)(.-)%s*$")
    if rest == "" then
      out[#out + 1] = ""
    else
      local room = math.max(measure("MMM"), width - measure(lead))
      local line = ""
      local function emit()
        out[#out + 1] = lead .. line
        line = ""
      end
      -- Words, each with the spaces before it, so a run of spaces inside a
      -- line (an aligned comment) survives.
      for gap, word in rest:gmatch("( *)([^ ]+)") do
        local try = line == "" and word or (line .. gap .. word)
        if measure(try) <= room then
          line = try
        else
          if line ~= "" then emit() end
          -- A word wider than the line: cut it by characters.
          while measure(word) > room do
            local cut = 1
            local chars = {}
            for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
            local acc = ""
            for k, ch in ipairs(chars) do
              if measure(acc .. ch) > room and k > 1 then break end
              acc = acc .. ch
              cut = k
            end
            line = acc
            emit()
            word = table.concat(chars, "", cut + 1)
            if word == "" then break end
          end
          line = word
        end
      end
      if line ~= "" then emit() end
    end
  end
  if #out == 0 then out[1] = "" end
  return out
end

--- The label beside choice `i`: the key that picks it.
function Quiz.key_label(i)
  return tostring(i)
end

--- Whether the brief goes in two columns — the program and the question on
--- the left, the four choices at the top of the right — rather than one.
--- Only with a program to show, only in landscape, and only when the panel
--- is wide enough for both halves to hold a line of code: one column put the
--- fourth choice under the fold on a ten-line program, and a HACKER program
--- is eighty. `min` is the width the caller measured that needs.
function Quiz.two_columns(has_program, portrait, width, min)
  return has_program and not portrait and width >= (min or 620)
end

--- How brightly the hole is lit at `t` seconds: a breath while it is a
--- question, steady once it is answered.
function Quiz.hole_alpha(t, right)
  if right then return 0.45 end
  return 0.25 + 0.12 * math.sin((t or 0) * 4)
end

-- ------------------------------------------------------------------ streak
--
-- First-try picks in a row on one road, this session — the web's
-- `SHEET_STREAK`. Kept here, at module level, because it outlives the quest
-- scene: the next node is a new scene and the streak is the same streak.

local streaks = {}

function Quiz.streak_key(land, category)
  return tostring(land or "?") .. "/" .. tostring(category or "?")
end

function Quiz.streak(key)
  return streaks[key] or 0
end

--- Record a pick on `key`'s road and return the streak after it: a right
--- pick on the first try adds one, a right pick after a miss starts again at
--- nothing, and a wrong pick breaks it.
function Quiz.record(key, verdict, first_try)
  local n = 0
  if verdict == "right" and first_try then n = Quiz.streak(key) + 1 end
  streaks[key] = n
  return n
end

--- Forget every streak (the tests, and a sign-out).
function Quiz.reset_streaks()
  streaks = {}
end

return Quiz
