-- The code editor, driven the way a player drives it.
--
-- The headline case types a twenty-line Rust program one keystroke at a time
-- — every character through `textinput`, every Enter and Tab through
-- `keypressed` — and then asserts the exact bytes that would be sent as
-- `quest.submit.source`. If auto-indent, tab stops or the brace handling are
-- wrong, that string is wrong, and no amount of "the editor feels fine"
-- covers for it.

local T = require("tests.framework")
local editor = require("src.editor")

local function clock()
  local t = 0
  return {
    now = function() return t end,
    advance = function(dt) t = t + dt end,
  }
end

--- Type a string as a person would: printable characters through textinput,
--- newlines through the Enter key.
local function type_text(ed, text)
  for i = 1, #text do
    local c = text:sub(i, i)
    if c == "\n" then
      ed:keypressed("return", {})
    else
      ed:textinput(c)
    end
  end
end

return function()
  T.section("editor — typing a real program")

  T.case("a twenty-line Rust program comes out byte-exact", function()
    local c = clock()
    local ed = editor.new({ now = c.now })

    -- Typed the way a person types it: no leading spaces are ever pressed,
    -- because the editor is supposed to put them there.
    type_text(ed, "use std::collections::HashMap;\n")
    ed:keypressed("return", {})
    type_text(ed, "fn tally(words: &[&str]) -> HashMap<String, usize> {\n")
    type_text(ed, "let mut counts = HashMap::new();\n")
    type_text(ed, "for w in words {\n")
    type_text(ed, "*counts.entry(w.to_string()).or_insert(0) += 1;")
    ed:keypressed("return", {})
    -- Close the inner block: shift-tab back a level, then the brace.
    ed:keypressed("tab", { shift = true })
    type_text(ed, "}\n")
    type_text(ed, "counts")
    ed:keypressed("return", {})
    ed:keypressed("tab", { shift = true })
    type_text(ed, "}\n")
    ed:keypressed("return", {})
    type_text(ed, "fn main() {\n")
    type_text(ed, 'let words = ["a", "b", "a"];\n')
    type_text(ed, "let counts = tally(&words);\n")
    type_text(ed, "let mut keys: Vec<&String> = counts.keys().collect();\n")
    type_text(ed, "keys.sort();\n")
    type_text(ed, "for k in keys {\n")
    type_text(ed, 'println!("{} {}", k, counts[k]);')
    ed:keypressed("return", {})
    ed:keypressed("tab", { shift = true })
    type_text(ed, "}")
    ed:keypressed("return", {})
    ed:keypressed("tab", { shift = true })
    type_text(ed, "}")

    local want = table.concat({
      "use std::collections::HashMap;",
      "",
      "fn tally(words: &[&str]) -> HashMap<String, usize> {",
      "    let mut counts = HashMap::new();",
      "    for w in words {",
      "        *counts.entry(w.to_string()).or_insert(0) += 1;",
      "    }",
      "    counts",
      "}",
      "",
      "fn main() {",
      '    let words = ["a", "b", "a"];',
      "    let counts = tally(&words);",
      "    let mut keys: Vec<&String> = counts.keys().collect();",
      "    keys.sort();",
      "    for k in keys {",
      '        println!("{} {}", k, counts[k]);',
      "    }",
      "}",
    }, "\n")

    T.eq(ed:text(), want)
    T.eq(ed:line_count(), 19)
    T.ok(ed.dirty)
  end)

  T.section("editor — motion and selection")

  T.case("arrows step by code point, not by byte", function()
    local ed = editor.new({ text = 'let s = "銅鑼灣";' })
    ed:move("doc_end")
    local presses = 0
    while not (ed.line == 1 and ed.col == 1) do
      ed:move("left")
      presses = presses + 1
      T.ok(presses < 100, "the cursor must actually reach the start")
    end
    -- 14 code points — l e t _ s _ = _ " 銅 鑼 灣 " ; — of which three are
    -- three bytes each, so a byte-stepping cursor would need 20 presses.
    T.eq(presses, editor.char_count('let s = "銅鑼灣";'))
    T.eq(presses, 14)
    T.eq(#'let s = "銅鑼灣";', 20, "and the line really is 20 bytes")
  end)

  T.case("home goes to the first non-space, then to column one", function()
    local ed = editor.new({ text = "    let x = 1;" })
    ed:move("end")
    ed:move("home")
    T.eq(ed.col, 5, "first press: the first non-space")
    ed:move("home")
    T.eq(ed.col, 1, "second press: the margin")
    ed:move("home")
    T.eq(ed.col, 5, "and back")
  end)

  T.case("the goal column survives a short line", function()
    local ed = editor.new({ text = "aaaaaaaaaa\nbb\ncccccccccc" })
    ed:goto_position(1, 9)
    ed:move("down")
    T.eq(ed.line, 2)
    T.eq(ed.col, 3, "clamped to the short line")
    ed:move("down")
    T.eq(ed.line, 3)
    T.eq(ed.col, 9, "and back out to where it started")
  end)

  T.case("word motion crosses punctuation", function()
    local ed = editor.new({ text = "let mut counts = HashMap::new();" })
    ed:goto_position(1, 1)
    ed:move("right", { word = true })
    T.eq(ed.col, 4, "past `let`")
    ed:move("right", { word = true })
    T.eq(ed.col, 8, "past ` mut`")
    ed:move("end")
    ed:move("left", { word = true })
    T.ok(ed.col < 30)
  end)

  T.case("shift extends a selection and a plain arrow drops it", function()
    local ed = editor.new({ text = "fn main() {}\nlet x = 1;" })
    ed:goto_position(1, 1)
    for _ = 1, 9 do ed:move("right", { extend = true }) end
    T.ok(ed:has_selection())
    T.eq(ed:selected_text(), "fn main()")
    ed:move("right")
    T.nope(ed:has_selection())
    -- And a backwards selection reads the same.
    ed:goto_position(2, 11)
    for _ = 1, 10 do ed:move("left", { extend = true }) end
    T.eq(ed:selected_text(), "let x = 1;")
  end)

  T.case("a multi-line selection reads and deletes correctly", function()
    local ed = editor.new({ text = "one\ntwo\nthree\nfour" })
    ed:goto_position(1, 2)
    ed:goto_position(3, 3, true)
    T.eq(ed:selected_text(), "ne\ntwo\nth")
    ed:delete_forward()
    T.eq(ed:text(), "oree\nfour")
    T.eq(ed.line, 1)
    T.eq(ed.col, 2)
  end)

  T.case("select all covers the buffer", function()
    local ed = editor.new({ text = "a\nb\nc" })
    ed:select_all()
    T.eq(ed:selected_text(), "a\nb\nc")
    ed:textinput("x")
    T.eq(ed:text(), "x")
  end)

  T.section("editor — indentation")

  T.case("tab lands on the next tab stop", function()
    local ed = editor.new({})
    ed:keypressed("tab", {})
    T.eq(ed:text(), "    ")
    ed:textinput("ab")
    ed:keypressed("tab", {})
    T.eq(ed:text(), "    ab  ", "two spaces, not four: column 7 -> column 9")
  end)

  T.case("tab and shift-tab move a whole selected block", function()
    local ed = editor.new({ text = "a\nb\nc\nd" })
    ed:goto_position(2, 1)
    ed:goto_position(3, 2, true)
    ed:keypressed("tab", {})
    T.eq(ed:text(), "a\n    b\n    c\nd")
    T.ok(ed:has_selection(), "the block stays selected so tab can repeat")
    ed:keypressed("tab", {})
    T.eq(ed:text(), "a\n        b\n        c\nd")
    ed:keypressed("tab", { shift = true })
    T.eq(ed:text(), "a\n    b\n    c\nd")
    ed:keypressed("tab", { shift = true })
    T.eq(ed:text(), "a\nb\nc\nd")
  end)

  T.case("backspace inside leading whitespace eats a level", function()
    local ed = editor.new({ text = "        let x = 1;" })
    ed:goto_position(1, 9)
    ed:keypressed("backspace", {})
    T.eq(ed:text(), "    let x = 1;")
    ed:keypressed("backspace", {})
    T.eq(ed:text(), "let x = 1;")
    -- But inside a word it eats one character.
    ed:move("end")
    ed:keypressed("backspace", {})
    T.eq(ed:text(), "let x = 1")
  end)

  T.case("Enter between braces opens a block", function()
    local ed = editor.new({ text = "fn main() {}" })
    ed:goto_position(1, 12) -- between { and }
    ed:keypressed("return", {})
    T.eq(ed:text(), "fn main() {\n    \n}")
    T.eq(ed.line, 2)
    T.eq(ed.col, 5)
  end)

  T.case("ctrl-/ comments and uncomments a block", function()
    local ed = editor.new({ text = "let a = 1;\nlet b = 2;\n" })
    ed:goto_position(1, 1)
    ed:goto_position(2, 3, true)
    ed:keypressed("/", { ctrl = true })
    T.eq(ed:text(), "// let a = 1;\n// let b = 2;\n")
    ed:goto_position(1, 1)
    ed:goto_position(2, 3, true)
    ed:keypressed("/", { ctrl = true })
    T.eq(ed:text(), "let a = 1;\nlet b = 2;\n")
  end)

  T.section("editor — undo, redo and the clipboard")

  T.case("typing coalesces into one undo, and structure does not", function()
    local c = clock()
    local ed = editor.new({ text = "", now = c.now })
    type_text(ed, "hello")
    T.eq(ed:text(), "hello")
    ed:undo()
    T.eq(ed:text(), "", "a burst of typing is one undo")

    ed:redo()
    T.eq(ed:text(), "hello")

    -- A pause starts a new entry.
    c.advance(2)
    type_text(ed, " world")
    T.eq(ed:text(), "hello world")
    ed:undo()
    T.eq(ed:text(), "hello")
    ed:undo()
    T.eq(ed:text(), "")
    T.eq(ed:undo(), false, "the stack bottoms out rather than erroring")
  end)

  T.case("undo restores the cursor, not just the text", function()
    local c = clock()
    local ed = editor.new({ text = "fn main() {}", now = c.now })
    ed:goto_position(1, 12)
    c.advance(2)
    ed:keypressed("return", {})
    T.eq(ed.line, 2)
    ed:undo()
    T.eq(ed:text(), "fn main() {}")
    T.eq(ed.line, 1)
    T.eq(ed.col, 12)
  end)

  T.case("an edit after an undo drops the redo stack", function()
    local c = clock()
    local ed = editor.new({ text = "", now = c.now })
    type_text(ed, "abc")
    ed:undo()
    c.advance(2)
    type_text(ed, "xyz")
    T.eq(ed:text(), "xyz")
    T.eq(ed:redo(), false)
  end)

  T.case("copy, cut and paste go through the injected clipboard", function()
    local board = editor.memory_clipboard()
    local c = clock()
    local ed = editor.new({ text = "let x = 1;\nlet y = 2;", clipboard = board, now = c.now })
    ed:goto_position(1, 1)
    ed:goto_position(1, 11, true)
    ed:keypressed("c", { ctrl = true })
    T.eq(board.get(), "let x = 1;")
    ed:move("doc_end")
    ed:textinput("\n")
    ed:keypressed("v", { ctrl = true })
    T.eq(ed:text(), "let x = 1;\nlet y = 2;\nlet x = 1;")

    -- Cut removes the selection.
    ed:goto_position(3, 1)
    ed:goto_position(3, 11, true)
    ed:keypressed("x", { ctrl = true })
    T.eq(ed:text(), "let x = 1;\nlet y = 2;\n")
    T.eq(board.get(), "let x = 1;")

    -- Command on macOS is the same binding.
    ed:keypressed("v", { gui = true })
    T.eq(ed:text(), "let x = 1;\nlet y = 2;\nlet x = 1;")
  end)

  T.case("copy with no selection takes the whole line", function()
    local board = editor.memory_clipboard()
    local ed = editor.new({ text = "fn main() {}", clipboard = board })
    ed:copy()
    T.eq(board.get(), "fn main() {}")
  end)

  T.case("a multi-line paste keeps its shape and CRLF is normalised", function()
    local board = editor.memory_clipboard()
    board.set("fn a() {}\r\nfn b() {}\r\n")
    local ed = editor.new({ text = "", clipboard = board })
    ed:paste()
    T.eq(ed:text(), "fn a() {}\nfn b() {}\n")
    T.eq(ed.line, 3)
    T.eq(ed.col, 1)
  end)

  T.section("editor — replace_all keeps the caret (PROTOCOL §4.9d)")

  T.case("re-indentation does not move the caret off its character", function()
    -- What `rustfmt` actually does to a line: change its leading whitespace.
    local c = clock()
    local ed = editor.new({ text = "fn main() {\nlet x=1;\n}", now = c.now })
    ed:goto_position(2, 6)                         -- between "let x" and "=1;"
    T.eq(ed:current_line():sub(1, 5), "let x")
    ed:replace_all("fn main() {\n    let x = 1;\n}\n")
    T.eq(ed.line, 2, "still on the same line of code")
    -- Four non-whitespace characters preceded the caret (l, e, t, x — the
    -- space between them is whitespace); four still do.
    local before = ed:current_line():sub(1, ed.col - 1)
    T.eq(#(before:gsub("%s", "")), 4, "the caret is after the same four characters")
    T.eq(ed:current_line():sub(ed.col, ed.col + 1), " =", "and between the same two")
  end)

  T.case("a line that moved is found by its text, nearest first", function()
    local c = clock()
    local ed = editor.new({ text = "a();\nb();\nc();", now = c.now })
    ed:goto_position(3, 2)
    -- The formatter inserted two lines above.
    ed:replace_all("use std::io;\n\na();\nb();\nc();\n")
    T.eq(ed:current_line(), "c();", "followed its own line down the file")
    T.eq(ed.col, 2)
  end)

  T.case("with twenty identical lines it picks the nearest", function()
    local lines = {}
    for i = 1, 20 do lines[i] = "}" end
    local ed = editor.new({ text = table.concat(lines, "\n") })
    ed:goto_position(15, 1)
    ed:replace_all(table.concat(lines, "\n"))
    T.eq(ed.line, 15, "not the first `}` in the file")
  end)

  T.case("a line the formatter destroyed falls back to the line number", function()
    local ed = editor.new({ text = "one\ntwo\nthree\nfour" })
    ed:goto_position(3, 2)
    ed:replace_all("completely\ndifferent\ntext\nhere")
    T.eq(ed.line, 3, "the line is much better than nothing")
    T.ok(ed.col >= 1 and ed.col <= #ed:current_line() + 1)
  end)

  T.case("a caret in the indent lands at the first real character", function()
    local ed = editor.new({ text = "fn main() {\nlet x = 1;\n}" })
    ed:goto_position(2, 1)
    ed:replace_all("fn main() {\n        let x = 1;\n}\n")
    T.eq(ed.line, 2)
    T.eq(ed.col, 9, "after the new indent, not buried inside it")
  end)

  T.case("a format is ONE undo step", function()
    local c = clock()
    local ed = editor.new({ text = "fn main(){let x=1;}", now = c.now })
    local before = ed:text()
    c.advance(2)
    ed:replace_all("fn main() {\n    let x = 1;\n}\n")
    T.ne(ed:text(), before)
    T.eq(ed:undo(), true)
    T.eq(ed:text(), before, "one ctrl-Z puts it back")
  end)

  T.case("undo after a format restores the caret too", function()
    local c = clock()
    local ed = editor.new({ text = "fn main(){\nlet x=1;\n}", now = c.now })
    ed:goto_position(2, 4)
    c.advance(2)
    ed:replace_all("fn main() {\n    let x = 1;\n}\n")
    ed:undo()
    T.eq(ed.line, 2)
    T.eq(ed.col, 4)
  end)

  T.case("read-only refuses a replacement", function()
    local ed = editor.new({ text = "fn main() {}", read_only = true })
    T.eq(ed:replace_all("something else"), false)
    T.eq(ed:text(), "fn main() {}")
  end)

  T.case("UTF-8 in the line does not shift the caret", function()
    local ed = editor.new({ text = 'let s="銅鑼灣";' })
    ed:goto_position(1, 1)
    ed:move("right"); ed:move("right"); ed:move("right")   -- after "let"
    local ink = #(ed:current_line():sub(1, ed.col - 1):gsub("%s", ""))
    ed:replace_all('let s = "銅鑼灣";\n')
    T.eq(#(ed:current_line():sub(1, ed.col - 1):gsub("%s", "")), ink)
  end)

  T.section("editor — the view")

  T.case("the cursor stays inside the viewport", function()
    local lines = {}
    for i = 1, 100 do lines[i] = "line " .. i end
    local ed = editor.new({ text = table.concat(lines, "\n") })
    ed:ensure_visible(20)
    T.eq(ed.scroll, 0)
    ed:goto_position(50, 1)
    ed:ensure_visible(20)
    T.ok(ed.scroll <= 49 and ed.scroll >= 30)
    T.ok(ed.line > ed.scroll and ed.line <= ed.scroll + 20)
    ed:goto_position(1, 1)
    ed:ensure_visible(20)
    T.eq(ed.scroll, 0)
    ed:move("doc_end")
    ed:ensure_visible(20)
    T.eq(ed.scroll, 80)
    -- Scrolling past the end is clamped.
    ed:scroll_by(500, 20)
    T.eq(ed.scroll, 80)
    ed:scroll_by(-500, 20)
    T.eq(ed.scroll, 0)
  end)

  T.case("read-only refuses edits but allows motion", function()
    local ed = editor.new({ text = "fn main() {}", read_only = true })
    ed:textinput("x")
    ed:keypressed("return", {})
    ed:keypressed("backspace", {})
    T.eq(ed:text(), "fn main() {}")
    ed:move("end")
    T.eq(ed.col, 13)
  end)

  T.section("editor — syntax colouring")

  T.case("keywords, strings, macros, numbers and comments are separated", function()
    local spans = editor.highlight('    let x = 42; // println!("no")')
    local kinds = {}
    for _, s in ipairs(spans) do kinds[s.kind] = (kinds[s.kind] or 0) + 1 end
    T.ok(kinds.keyword and kinds.keyword >= 1, "`let` is a keyword")
    T.ok(kinds.number and kinds.number >= 1, "42 is a number")
    T.ok(kinds.comment and kinds.comment >= 1)
    -- The macro inside the comment must stay a comment.
    local last = spans[#spans]
    T.eq(last.kind, "comment")
    T.ok(last.text:find("println"))
  end)

  T.case("a string with an escaped quote does not end early", function()
    local spans = editor.highlight('println!("a \\" b", x);')
    local text = ""
    for _, s in ipairs(spans) do
      if s.kind == "string" then text = s.text end
    end
    T.eq(text, '"a \\" b"')
    T.eq(spans[1].kind, "macro")
    T.eq(spans[1].text, "println!")
  end)

  T.case("a block comment carries across lines", function()
    local _, state = editor.highlight("/* the borrow checker", "code")
    T.eq(state, "block_comment")
    local spans, state2 = editor.highlight("   is not your enemy */ let x = 1;", state)
    T.eq(state2, "code")
    T.eq(spans[1].kind, "comment")
    local saw_keyword = false
    for _, s in ipairs(spans) do
      if s.kind == "keyword" then saw_keyword = true end
    end
    T.ok(saw_keyword, "code after the close is code again")
  end)

  T.case("highlighting never loses or reorders a byte", function()
    for _, line in ipairs({
      'fn main() { println!("hello, causewaybay"); }',
      "    let mut v: Vec<u8> = Vec::new();",
      "// a comment",
      "/* open",
      "let s = \"銅鑼灣\";",
      "",
      "x += 1; // 0x1F",
    }) do
      local spans = editor.highlight(line)
      local joined = {}
      for i, s in ipairs(spans) do joined[i] = s.text end
      T.eq(table.concat(joined), line, "spans must rebuild the line exactly")
    end
  end)

  T.section("editor — no love in the model")

  T.case("src/editor.lua does not reference love", function()
    T.no_love("src/editor.lua")
  end)
end
