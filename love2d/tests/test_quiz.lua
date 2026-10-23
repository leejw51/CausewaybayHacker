-- The quiz's pure parts (`src/quiz.lua`), against the web's
-- `frontend/src/ui/quiz.ts`: what a pick means, where a scrolled choice may
-- take a tap, how a long program is cut around its hole, how a brief's
-- fences come apart from its prose, and how a choice's code wraps.

local T = require("tests.framework")
local Quiz = require("src.quiz")

-- One pixel per byte: enough to pin the wrapping without a font.
local function bytes(s) return #s end

return function()
  T.section("quiz — what a pick means")

  local quiz = { choices = { "a", "b", "c", "d" }, answer = 2 }

  T.case("right only at the wire's 0-based answer", function()
    T.eq(Quiz.pick(quiz, 3, false), "right", "the third choice is index 2")
    T.eq(Quiz.pick(quiz, 1, false), "wrong")
    T.eq(Quiz.pick(quiz, 4, false), "wrong")
  end)

  T.case("out of range, fractional, after the unlock, or no quiz: ignored", function()
    T.eq(Quiz.pick(quiz, 0, false), "ignored")
    T.eq(Quiz.pick(quiz, 5, false), "ignored", "no fifth choice")
    T.eq(Quiz.pick(quiz, 1.5, false), "ignored")
    T.eq(Quiz.pick(quiz, "1", false), "ignored", "a key is turned into a number first")
    T.eq(Quiz.pick(quiz, 3, true), "ignored", "an answered quiz takes no more picks")
    T.eq(Quiz.pick(nil, 1, false), "ignored")
    T.eq(Quiz.pick({ answer = 0 }, 1, false), "ignored", "no choices, nothing to pick")
  end)

  T.case("a quest opens locked unless it is cleared", function()
    T.eq(Quiz.starts_locked(quiz, "open"), true)
    T.eq(Quiz.starts_locked(quiz, "cleared"), false)
    T.eq(Quiz.starts_locked(nil, "open"), false)
  end)

  T.section("quiz — a scrolled choice")

  T.case("the hit box is the part inside the panel", function()
    local clip = { x = 0, y = 100, w = 300, h = 200 }
    T.same(Quiz.visible_box({ x = 10, y = 150, w = 100, h = 40 }, clip),
      { x = 10, y = 150, w = 100, h = 40 }, "wholly inside")
    T.same(Quiz.visible_box({ x = 10, y = 80, w = 100, h = 40 }, clip),
      { x = 10, y = 100, w = 100, h = 20 }, "cut at the top")
    T.same(Quiz.visible_box({ x = 10, y = 280, w = 100, h = 40 }, clip),
      { x = 10, y = 280, w = 100, h = 20 }, "cut at the bottom")
    T.eq(Quiz.visible_box({ x = 10, y = 20, w = 100, h = 40 }, clip), nil, "scrolled out above")
    T.eq(Quiz.visible_box({ x = 10, y = 300, w = 100, h = 40 }, clip), nil,
      "touching the bottom edge is not inside it")
  end)

  T.case("the wells stack without overlapping", function()
    local boxes = Quiz.boxes(12, 100, 300, { 36, 50, 36, 36 }, 6)
    T.eq(#boxes, 4)
    for i = 2, 4 do
      T.ok(boxes[i].y >= boxes[i - 1].y + boxes[i - 1].h + 6, "well " .. i .. " is under the last")
    end
  end)

  T.case("two across: rows as tall as their tallest, cells side by side", function()
    local b = Quiz.grid(0, 0, 206, { 30, 40, 30, 30 }, 2, 6)
    T.same(b[1], { x = 0, y = 0, w = 100, h = 40 })
    T.same(b[2], { x = 106, y = 0, w = 100, h = 40 }, "the row takes the taller one")
    T.same(b[3], { x = 0, y = 46, w = 100, h = 30 })
    T.same(b[4], { x = 106, y = 46, w = 100, h = 30 })
    T.same(Quiz.grid(0, 0, 100, { 30, 30 }, 1, 6), Quiz.boxes(0, 0, 100, { 30, 30 }, 6),
      "one column is the stack")
  end)

  T.case("two columns only for short choices, wide, in landscape", function()
    T.eq(Quiz.choice_cols(false, 900, { 1, 1, 1, 1 }, 200), 2)
    T.eq(Quiz.choice_cols(true, 900, { 1, 1, 1, 1 }, 200), 1, "portrait: full-width bars")
    T.eq(Quiz.choice_cols(false, 900, { 1, 2, 1, 1 }, 200), 1, "one that wraps keeps them whole")
    T.eq(Quiz.choice_cols(false, 300, { 1, 1, 1, 1 }, 200), 1, "too narrow to halve")
  end)

  T.section("quiz — the program and its hole")

  T.case("the hole is `____` alone on its line, indented or not", function()
    T.eq(Quiz.is_hole("____"), true)
    T.eq(Quiz.is_hole("\t    ____  "), true)
    T.eq(Quiz.is_hole("x = ____"), false)
    T.eq(Quiz.has_hole("// ____"), true, "a sheet's snippet marks it in a comment")
  end)

  T.case("a short program is whole, a program with no hole is whole", function()
    local lines = Quiz.program_lines("\n\nfn main() {\n    ____\n}\n\n")
    T.eq(#lines, 3, "the blank lines round it are trimmed")
    T.eq(lines[2].kind, "hole")
    local body = {}
    for i = 1, 60 do body[i] = "line " .. i end
    T.eq(#Quiz.program_lines(table.concat(body, "\n")), 60, "no hole, no cut")
  end)

  T.case("forty lines is the most shown whole", function()
    local body = {}
    for i = 1, 40 do body[i] = i == 39 and "____" or ("line " .. i) end
    local lines = Quiz.program_lines(table.concat(body, "\n"))
    T.eq(#lines, 40)
    for _, l in ipairs(lines) do T.ok(l.kind ~= "cut", "nothing cut at forty") end
  end)

  T.case("a long program is cut to 22 above the hole and 14 below", function()
    local body = {}
    for i = 1, 80 do body[i] = i == 50 and "  ____" or ("line " .. i) end
    local lines = Quiz.program_lines(table.concat(body, "\n"))
    T.eq(lines[1].kind, "cut")
    T.eq(lines[1].text, "⋮")
    T.eq(lines[2].text, "line 28", "22 lines above the hole")
    T.eq(lines[24].kind, "hole")
    T.eq(lines[#lines - 1].text, "line 64", "14 lines below it")
    T.eq(lines[#lines].kind, "cut")
    T.eq(#lines, 1 + 22 + 1 + 14 + 1)
  end)

  T.case("a hole near an end cuts only the other end", function()
    local body = {}
    for i = 1, 80 do body[i] = i == 3 and "____" or ("line " .. i) end
    local lines = Quiz.program_lines(table.concat(body, "\n"))
    T.eq(lines[1].text, "line 1", "nothing above to cut")
    T.eq(lines[#lines].kind, "cut")
    body[3] = "line 3"; body[79] = "____"
    lines = Quiz.program_lines(table.concat(body, "\n"))
    T.eq(lines[1].kind, "cut")
    T.eq(lines[#lines].text, "line 80", "nothing below to cut")
  end)

  T.case("the hole breathes until it is answered", function()
    T.eq(Quiz.hole_alpha(0, true), 0.45)
    T.near(Quiz.hole_alpha(0, false), 0.25, 1e-9)
    T.ok(Quiz.hole_alpha(0.4, false) > Quiz.hole_alpha(0, false), "brighter on the in-breath")
  end)

  T.section("quiz — the brief's markdown")

  T.case("fences come apart from the prose, and the markers go", function()
    local b = Quiz.blocks("Read **all** of stdin into `s`.\n\n```\nlet mut s = String::new();\n// ____\n```\n\nWhich line is it?\n")
    T.eq(#b, 3)
    T.eq(b[1].kind, "prose")
    T.eq(b[1].text, "Read all of stdin into s.")
    T.eq(b[2].kind, "code")
    T.eq(b[2].text, "let mut s = String::new();\n// ____")
    T.eq(b[3].text, "Which line is it?")
  end)

  T.case("an empty fence is dropped, an open one is kept", function()
    local b = Quiz.blocks("a\n```\n```\nb\n```rust\nfn x() {}")
    T.eq(#b, 3)
    T.eq(b[1].text, "a")
    T.eq(b[2].text, "b")
    T.eq(b[3].kind, "code")
    T.eq(b[3].text, "fn x() {}")
  end)

  T.case("headings and bullets lose their markers", function()
    local b = Quiz.blocks("## Input\n- one\n* two")
    T.eq(b[1].text, "Input\n· one\n· two")
  end)

  T.case("soft breaks join, paragraphs and bullets stay apart", function()
    T.same(Quiz.blocks_lines("the answer the question\nis asking for,\nnot the one\n\nnext"),
      { "the answer the question is asking for, not the one", "", "next" })
    T.same(Quiz.blocks_lines("Input\n· one\n· two"), { "Input", "· one", "· two" })
  end)

  T.section("quiz — code in a choice")

  T.case("a line that fits is one line, indentation kept, tabs as spaces", function()
    T.same(Quiz.code_wrap("\tx := 1", 40, bytes), { "    x := 1" })
    T.same(Quiz.code_wrap("a\n\n  b", 40, bytes), { "a", "", "  b" })
  end)

  T.case("a long line wraps at a space and keeps its indent", function()
    local out = Quiz.code_wrap("    let total = items.iter().sum();", 24, bytes)
    T.ok(#out >= 2, "it wrapped")
    for _, l in ipairs(out) do
      T.ok(#l <= 24, ("%q fits"):format(l))
      T.eq(l:sub(1, 4), "    ", "every piece keeps the indent")
    end
    T.eq(table.concat(out, " "):gsub("%s+", " "):gsub("^ ", ""),
      "let total = items.iter().sum();", "nothing lost")
  end)

  T.case("a run with no space in it is cut, not let through", function()
    local out = Quiz.code_wrap(("x"):rep(30), 10, bytes)
    T.eq(#out, 3)
    for _, l in ipairs(out) do T.ok(#l <= 10) end
  end)

  T.section("quiz — the streak")

  T.case("first-try rights count up; a miss or a late right breaks it", function()
    Quiz.reset_streaks()
    local k = Quiz.streak_key("rust", "cheatsheet")
    T.eq(Quiz.record(k, "right", true), 1)
    T.eq(Quiz.record(k, "right", true), 2)
    T.eq(Quiz.streak(Quiz.streak_key("go", "cheatsheet")), 0, "another road is another streak")
    T.eq(Quiz.record(k, "wrong", true), 0)
    T.eq(Quiz.record(k, "right", false), 0, "right after a miss is not a streak")
    Quiz.reset_streaks()
  end)

  T.case("the layout goes two columns only for a program, wide, in landscape", function()
    T.eq(Quiz.two_columns(true, false, 900, 620), true)
    T.eq(Quiz.two_columns(true, true, 900, 620), false, "portrait is one column")
    T.eq(Quiz.two_columns(false, false, 900, 620), false, "a sheet question has no program")
    T.eq(Quiz.two_columns(true, false, 500, 620), false, "too narrow")
  end)

  T.section("quiz — the card's own rules (docs/love2d-ui.md, the quest spec)")

  T.case("a struck line takes no second pick; the rest stay open", function()
    local wrong = { [1] = true }
    T.eq(Quiz.pick(quiz, 1, false, wrong), "ignored", "already ruled out")
    T.eq(Quiz.pick(quiz, 3, false, wrong), "right")
    T.eq(Quiz.pick(quiz, 4, false, wrong), "wrong")
    T.eq(Quiz.remaining(4, wrong), 3)
    T.eq(Quiz.remaining(4, { [1] = true, [2] = true, [4] = true }), 1)
    T.eq(Quiz.remaining(4, nil), 4)
  end)

  T.case("the stars a clear is still worth: SPEC §6.3's cascade", function()
    T.eq(Quiz.stars_potential(0, 0), 3)
    T.eq(Quiz.stars_potential(1, 0), 2, "one miss")
    T.eq(Quiz.stars_potential(2, 0), 2, "two misses")
    T.eq(Quiz.stars_potential(0, 1), 2, "a hint")
    T.eq(Quiz.stars_potential(3, 0), 1, "three misses")
    T.eq(Quiz.stars_potential(3, 1), 2, "a hint keeps the second rung, as the server does")
  end)

  T.case("the window round the hole is as many rows as the well has", function()
    local body = {}
    for i = 1, 30 do body[i] = i == 15 and "    ____" or ("line " .. i) end
    local program = table.concat(body, "\n")
    for _, rows in ipairs({ 3, 5, 7, 8, 12 }) do
      local lines = Quiz.window_lines(program, rows)
      T.ok(#lines <= rows, ("%d rows asked, %d given"):format(rows, #lines))
      T.ok(Quiz.hole_index(lines) ~= nil, rows .. " rows: the hole is in the window")
      T.eq(lines[1].kind, "cut", rows .. " rows: cut above")
      T.eq(lines[#lines].kind, "cut", rows .. " rows: cut below")
    end
    local five = Quiz.window_lines(program, 5)
    T.eq(five[2].text, "line 14")
    T.eq(five[3].kind, "hole")
    T.eq(five[4].text, "line 16")
  end)

  T.case("a short program is whole, and a hole near an end cuts one side", function()
    T.eq(#Quiz.window_lines("a\n____\nb", 5), 3, "three lines in a five-row well")
    T.eq(#Quiz.window_lines("a\n____\nb", 2), 3, "the floor is three rows")
    local body = {}
    for i = 1, 30 do body[i] = i == 2 and "____" or ("line " .. i) end
    local top = Quiz.window_lines(table.concat(body, "\n"), 6)
    T.eq(top[1].text, "line 1", "nothing above to cut")
    T.eq(top[2].kind, "hole")
    T.eq(#top, 6)
    T.eq(top[6].kind, "cut")
    body[2] = "line 2"; body[29] = "____"
    local bottom = Quiz.window_lines(table.concat(body, "\n"), 6)
    T.eq(bottom[1].kind, "cut")
    T.eq(bottom[#bottom].text, "line 30", "nothing below to cut")
    T.eq(#bottom, 6)
  end)

  T.case("the answer is typed into the hole at 15 ms a character", function()
    T.eq(Quiz.typed("abcdef", nil), nil, "not started")
    T.eq(Quiz.typed("abcdef", 0), "")
    T.eq(Quiz.typed("abcdef", 0.031), "ab")
    T.eq(Quiz.typed("abcdef", 10), "abcdef", "whole once the time is up")
    T.eq(Quiz.typed("héllo", 0.046), "hél", "characters, not bytes")
  end)

  T.case("the story's short first sentence is the lead", function()
    local lead, rest = Quiz.story_lead("06:30, Jardine's Bazaar. The kiosk's input arrives all at once.")
    T.eq(lead, "06:30, Jardine's Bazaar.")
    T.eq(rest, "The kiosk's input arrives all at once.")
    local none, all = Quiz.story_lead("Room 7-32. The first question is the one everybody gets, and the clock starts on the way in.")
    T.eq(none, "Room 7-32.")
    T.eq(all, "The first question is the one everybody gets, and the clock starts on the way in.")
    local long, whole = Quiz.story_lead("A sentence that is far too long to be a lead on a card of its own, really.")
    T.eq(long, nil)
    T.eq(whole, "A sentence that is far too long to be a lead on a card of its own, really.")
    T.eq(select(2, Quiz.story_lead(nil)), "")
  end)

  T.case("\"Which line is it?\" is dropped from the question; the rest stays", function()
    local blocks = Quiz.blocks("Read all of stdin.\n\n```\n// ____\n```\n\nWhich line is it?\n")
    local q = Quiz.question_blocks(blocks)
    T.eq(#q, 2)
    T.eq(q[2].kind, "code")
    local keep = Quiz.question_blocks(Quiz.blocks("A long question that happens to end with a mark, which is the brief itself?"))
    T.eq(#keep, 1, "a long question is the question")
    T.eq(#Quiz.question_blocks({}), 0)
  end)

  T.case("a row is as tall as its code, never under the spec's floor", function()
    T.eq(Quiz.row_height(1, 20, 12, 64), 64)
    T.eq(Quiz.row_height(2, 20, 12, 64), 64, "two short lines still fit the floor")
    T.eq(Quiz.row_height(3, 20, 12, 64), 84)
    T.eq(Quiz.row_height(1, 20, 12, 72), 72, "upright floor")
  end)

  T.section("quiz — the edges the web's `quiz.ts` decides")

  T.case("only the first hole is the hole", function()
    -- `lines.findIndex(...)`: the first match and no other.
    local lines = Quiz.program_lines("a\n____\nb\n  ____\nc")
    T.eq(lines[2].kind, "hole")
    T.eq(lines[4].kind, "code", "a second ____ is drawn as code")
  end)

  T.case("forty-one lines is past whole, and the cut takes its own arguments", function()
    local body = {}
    for i = 1, 41 do body[i] = i == 20 and "____" or ("line " .. i) end
    local lines = Quiz.program_lines(table.concat(body, "\n"))
    T.eq(lines[#lines].kind, "cut", "one past PROGRAM_WHOLE is cut below")
    T.eq(#lines, 19 + 1 + 14 + 1, "nothing to cut above a hole 19 lines down")
    lines = Quiz.program_lines(table.concat(body, "\n"), 2, 3, 10)
    T.eq(#lines, 1 + 2 + 1 + 3 + 1, "before = 2, after = 3, whole = 10")
    T.eq(lines[2].text, "line 18")
    T.eq(lines[#lines - 1].text, "line 23")
  end)

  T.case("an empty program is one empty line, not none", function()
    -- `"".split("\n")` is `[""]`.
    T.same(Quiz.program_lines(""), { { kind = "code", text = "" } })
    T.same(Quiz.program_lines(nil), { { kind = "code", text = "" } })
  end)

  T.case("a pick that is not a whole number in range is ignored, NaN and infinity too", function()
    local q = { choices = { "a", "b", "c", "d" }, answer = 0 }
    T.eq(Quiz.pick(q, 0 / 0, false), "ignored", "NaN")
    T.eq(Quiz.pick(q, math.huge, false), "ignored", "infinity")
    T.eq(Quiz.pick(q, -1, false), "ignored")
    T.eq(Quiz.pick(q, 1, true), "ignored", "already right takes nothing, even the answer")
  end)

  T.case("the constants and the cut are the web's, read out of quiz.ts", function()
    local vectors = os.getenv("CWBH_VECTORS")
    local root = vectors and vectors:match("^(.*)/tests/vectors/?$") or ".."
    local fh = io.open(root .. "/frontend/src/ui/quiz.ts", "r")
    if not fh then
      T.skip("quiz.ts", "no frontend checkout beside this one")
      return
    end
    local ts = fh:read("*a")
    fh:close()
    T.eq(Quiz.HOLE, ts:match('export const HOLE%s*=%s*"([^"]*)"'), "HOLE")
    T.eq(Quiz.PROGRAM_WHOLE, tonumber(ts:match("export const PROGRAM_WHOLE%s*=%s*(%d+)")),
      "PROGRAM_WHOLE")
    local before = tonumber(ts:match("function programLines%b()"):match("before%s*=%s*(%d+)"))
    local after = tonumber(ts:match("function programLines%b()"):match("after%s*=%s*(%d+)"))
    T.ok(before and after, "programLines' defaults parsed")
    -- The cut with no arguments has to be the cut with the web's.
    local body = {}
    for i = 1, 100 do body[i] = i == 50 and "____" or ("l" .. i) end
    local mine = Quiz.program_lines(table.concat(body, "\n"))
    local theirs = Quiz.program_lines(table.concat(body, "\n"), before, after, Quiz.PROGRAM_WHOLE)
    T.same(mine, theirs, "the default window is before = " .. tostring(before)
      .. ", after = " .. tostring(after))
  end)
end
