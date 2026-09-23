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

  T.case("a line SPLIT by the formatter still carries the caret", function()
    -- The case that actually happens, and the one the first version of this
    -- got wrong: `rustfmt` takes a long one-liner and breaks it into several.
    -- No line survives, so matching lines by content finds nothing — and the
    -- old fallback put the caret at the end of line 1.
    local ed = editor.new({ text = "fn main(){let a=1;let b=2;println!(\"{}\",a+b);}" })
    local at = ed.lines[1]:find("b=2", 1, true)
    ed:goto_position(1, at + 1)                  -- between "b" and "=2"

    ed:replace_all(table.concat({
      "fn main() {",
      "    let a = 1;",
      "    let b = 2;",
      '    println!("{}", a + b);',
      "}",
      "",
    }, "\n"))

    T.eq(ed.line, 3, "it followed `let b` onto its own new line")
    T.eq(ed:current_line(), "    let b = 2;")
    -- The only question that matters: is the caret still between the same two
    -- characters of the program? It was between `b` and `=`.
    T.eq(ed:current_line():sub(1, ed.col - 1):gsub("%s", ""), "letb")
    T.eq(ed:current_line():sub(ed.col, ed.col + 1), "= ",
      "still immediately before the `=`, across a line split")
  end)

  T.case("a line JOINED by the formatter still carries the caret", function()
    local ed = editor.new({ text = "let x =\n    1\n    + 2;" })
    ed:goto_position(3, 8)                       -- after the "2", before the ";"
    ed:replace_all("let x = 1 + 2;\n")
    T.eq(ed.line, 1, "three lines became one and the caret came with them")
    T.eq(ed:current_line(), "let x = 1 + 2;")
    T.eq(ed:current_line():sub(1, ed.col - 1):gsub("%s", ""), "letx=1+2",
      "the same eight characters of program are still behind it")
    T.eq(ed:current_line():sub(ed.col, ed.col), ";")
  end)

  T.case("a completely rewritten buffer still lands somewhere sane", function()
    local ed = editor.new({ text = "one\ntwo\nthree\nfour" })
    ed:goto_position(3, 2)
    ed:replace_all("completely\ndifferent\ntext\nhere")
    -- Following the ink puts it at the same offset through the document,
    -- which is the best available answer when nothing matches at all.
    T.ok(ed.line >= 1 and ed.line <= 4)
    T.ok(ed.col >= 1 and ed.col <= #ed:current_line() + 1)
    local ink = #(ed:text():sub(1, 0):gsub("%s", ""))
    T.eq(ink, 0)
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

  T.case("TypeScript is coloured as TypeScript, not as Rust", function()
    local function kind_of(spans, word)
      for _, s in ipairs(spans) do
        if s.text == word then return s.kind end
      end
    end
    local spans = editor.highlight("const n: number = xs!.length; // fn", "code", "typescript")
    T.eq(kind_of(spans, "const"), "keyword")
    T.eq(kind_of(spans, "number"), "type")
    T.eq(kind_of(spans, "xs"), "text", "`xs!` is a non-null assertion, not a macro")
    T.eq(spans[#spans].kind, "comment")
    -- Single quotes and backticks are strings in TypeScript.
    local q = editor.highlight("const s = 'a(b' + `c)d`;", "code", "typescript")
    local strings = {}
    for _, sp in ipairs(q) do
      if sp.kind == "string" then strings[#strings + 1] = sp.text end
    end
    T.same(strings, { "'a(b'", "`c)d`" })
    -- Rust's words are plain words there, and TypeScript's are plain in Rust.
    T.eq(kind_of(editor.highlight("fn impl", "code", "typescript"), "impl"), "text")
    T.eq(kind_of(editor.highlight("interface X", "code"), "interface"), "text")
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

  -- ------------------------------------------------------------- the mouse

  T.section("editor — the pixel that was clicked")

  --- A fixed-width font, which is the only kind this editor is ever drawn
  --- in: eight pixels a character, so a width is a character count times 8.
  local function mono(w)
    w = w or 8
    return function(s) return editor.char_count(s) * w end
  end

  T.case("a click lands on the nearest boundary, not the last one passed", function()
    local line = "let x = 1;"
    local m = mono(8)
    T.eq(editor.column_at(line, 0, m), 1, "the far left is column 1")
    T.eq(editor.column_at(line, -40, m), 1, "left of the text is still column 1")
    T.eq(editor.column_at(line, 8, m), 2, "exactly one character in")
    -- The half that matters: clicking the right-hand side of a character
    -- puts the caret after it. A hit test that rounded down would make a
    -- drag started mid-character drop that character.
    T.eq(editor.column_at(line, 11, m), 2, "the left half of character 2")
    T.eq(editor.column_at(line, 13, m), 3, "the right half of character 2")
    T.eq(editor.column_at(line, 4000, m), #line + 1, "past the end is the end")
  end)

  T.case("clicking the empty space right of a short line lands at its end", function()
    -- Every click in the blank half of the pane is this case, and the first
    -- version of the early exit could bail on the first boundary and answer
    -- column 1 — which would put the caret at the *start* of the line the
    -- player clicked past the end of.
    local m = mono(8)
    T.eq(editor.column_at("ab", 600, m), 3, "two characters, clicked far right")
    T.eq(editor.column_at("", 600, m), 1, "an empty line has only one column")
    T.eq(editor.column_at("x", 9, m), 2, "and one just past the only character")
    T.eq(editor.column_at("x", 3, m), 1, "but the left third of it is still before")
  end)

  T.case("a click counts code points, not bytes", function()
    local line = 'let s = "銅鑼灣";'
    local m = mono(8)
    -- Each of the three CJK characters is three bytes and one cell.
    -- `let s = "` is nine cells and nine bytes; the CJK that follows is one
    -- cell and three bytes each.
    T.eq(editor.column_at(line, 8 * 9, m), 10, "nine cells in is byte 10")
    T.eq(editor.column_at(line, 8 * 10, m), 13, "one cell later is three bytes later")
    T.eq(editor.column_at(line, 8 * 11, m), 16, "and again")
  end)

  T.section("editor — what a double click takes")

  T.case("word_span takes a run of one kind at a time", function()
    local line = "let mut counts = HashMap::new();"
    local from, to = editor.word_span(line, 9)
    T.eq(line:sub(from, to - 1), "counts", "an identifier")
    from, to = editor.word_span(line, 8)
    T.eq(line:sub(from, to - 1), " ", "the space between two words")
    from, to = editor.word_span(line, 25)
    T.eq(line:sub(from, to - 1), "::", "a run of punctuation")
    from, to = editor.word_span(line, #line + 1)
    T.eq(line:sub(from, to - 1), "();", "past the end takes the last run")
    from, to = editor.word_span("", 1)
    T.eq(from, 1, "an empty line has an empty span")
    T.eq(to, 1, "an empty line has an empty span")
  end)

  T.case("word_span does not split a multi-byte character", function()
    local line = "let 銅鑼灣 = 1;"
    local from, to = editor.word_span(line, 5)
    T.eq(line:sub(from, to - 1), "銅鑼灣", "three code points, nine bytes, one word")
  end)

  T.section("editor — dragging with the mouse")

  local function drag_fixture()
    return editor.new({ text = "alpha beta\ngamma delta\nepsilon zeta" })
  end

  T.case("press, move, release selects the range dragged over", function()
    local ed = drag_fixture()
    ed:begin_select(1, 1, "char")
    T.nope(ed:has_selection(), "a press alone selects nothing")
    ed:drag_to(2, 6)
    T.eq(ed:selected_text(), "alpha beta\ngamma", "the drag selected forwards")
    T.ok(ed:dragging(), "the button is still down")
    ed:end_select()
    T.nope(ed:dragging(), "and now it is not")
    T.eq(ed:selected_text(), "alpha beta\ngamma", "the release keeps the selection")
  end)

  T.case("a backwards drag selects the same range", function()
    local ed = drag_fixture()
    ed:begin_select(2, 6, "char")
    ed:drag_to(1, 1)
    T.eq(ed:selected_text(), "alpha beta\ngamma", "dragged up, same text")
    T.eq(ed.line, 1, "the caret is at the end the pointer is at")
    T.eq(ed.col, 1, "the caret is at the end the pointer is at")
  end)

  T.case("a move with no button down does nothing", function()
    local ed = drag_fixture()
    ed:goto_position(1, 3)
    T.nope(ed:drag_to(3, 1), "a stray mousemoved is refused")
    T.eq(ed.line, 1, "the caret did not move")
    T.eq(ed.col, 3, "the caret did not move")
  end)

  T.case("a double click takes the word, and the drag then grows by words", function()
    local ed = drag_fixture()
    ed:begin_select(1, 8, "word")
    T.eq(ed:selected_text(), "beta", "the word under the pointer")
    ed:drag_to(2, 3)
    T.eq(ed:selected_text(), "beta\ngamma", "grown to whole words, not characters")
  end)

  T.case("a word drag backwards keeps the origin word whole", function()
    local ed = drag_fixture()
    ed:begin_select(2, 8, "word")
    T.eq(ed:selected_text(), "delta", "the origin word")
    ed:drag_to(1, 2)
    T.eq(ed:selected_text(), "alpha beta\ngamma delta",
      "the origin word survived being dragged away from")
  end)

  T.case("a triple click takes the line, including its newline", function()
    local ed = drag_fixture()
    ed:begin_select(2, 4, "line")
    T.eq(ed:selected_text(), "gamma delta\n", "the whole line and the break after it")
    ed:drag_to(3, 1)
    T.eq(ed:selected_text(), "gamma delta\nepsilon zeta", "two whole lines")
  end)

  T.case("a triple click on the last line has no newline to take", function()
    local ed = drag_fixture()
    ed:begin_select(3, 2, "line")
    T.eq(ed:selected_text(), "epsilon zeta", "the last line, and nothing after it")
  end)

  T.case("shift-click extends from the caret, and again from the anchor", function()
    local ed = drag_fixture()
    ed:goto_position(1, 1)
    ed:begin_select(1, 6, "char", true)
    ed:end_select()
    T.eq(ed:selected_text(), "alpha", "the first shift-click extended from the caret")
    ed:begin_select(2, 6, "char", true)
    ed:end_select()
    T.eq(ed:selected_text(), "alpha beta\ngamma",
      "the second grew the same selection rather than starting a new one")
  end)

  T.case("a drag off the top of the pane clamps rather than breaking", function()
    local ed = drag_fixture()
    ed:begin_select(3, 5, "char")
    ed:drag_to(-40, 1)
    T.eq(ed.line, 1, "clamped to the first line")
    T.eq(ed:selected_text(), "alpha beta\ngamma delta\nepsi", "and the selection is honest")
  end)

  -- --------------------------------------------------------------- brackets

  T.section("editor — brackets, and the ones that never closed")

  local function unmatched_of(text)
    local at, unmatched = editor.brackets(editor.new({ text = text }).lines)
    local said = {}
    for i, e in ipairs(unmatched) do
      said[i] = ("%s@%d:%d"):format(e.char, e.line, e.col)
    end
    return table.concat(said, " "), at
  end

  T.case("a balanced program has nothing unmatched", function()
    local said = unmatched_of("fn main() {\n    let v = vec![1, 2];\n}\n")
    T.eq(said, "", "every bracket found its partner")
  end)

  T.case("an unclosed brace is named, with its line", function()
    local said = unmatched_of("fn main() {\n    let x = 1;\n")
    T.eq(said, "{@1:11", "the opener that never closed")
  end)

  T.case("a closer with nothing open is named too", function()
    local said = unmatched_of("let x = 1;\n}\n")
    T.eq(said, "}@2:1", "a stray closing brace")
  end)

  T.case("a mismatched pair reports both ends", function()
    local said = unmatched_of("fn f(x: i32] {}\n")
    T.eq(said, "(@1:5 ]@1:12", "the paren that stayed open and the wrong closer")
  end)

  T.case("brackets inside a string are text, not structure", function()
    local said = unmatched_of('println!("}} not a brace {");\n')
    T.eq(said, "", "the braces in the literal were not counted")
  end)

  T.case("brackets inside comments are text too", function()
    T.eq(unmatched_of("fn main() {\n    // }\n}\n"), "", "a line comment")
    T.eq(unmatched_of("/* {\n   still open }\n*/\nfn main() {}\n"), "",
      "a block comment across three lines")
  end)

  T.case("angle brackets are deliberately not matched", function()
    -- `<` and `>` are comparison, `->`, `=>` and generics in Rust. A matcher
    -- that guessed would be wrong more often than right, so it does not
    -- guess — and `a < b` must not be reported as an unclosed anything.
    T.eq(unmatched_of("let v: Vec<u8> = Vec::new();\n"), "", "generics are quiet")
    T.eq(unmatched_of("if a < b { println!(\"y\"); }\n"), "", "so is a comparison")
  end)

  T.case("the pair is found from either side of the caret", function()
    local ed = editor.new({ text = "fn main() {\n    ok();\n}\n" })
    ed:goto_position(1, 12) -- just after the `{`
    local here = ed:bracket_at_caret()
    T.eq(here and here.char, "{", "the bracket before the caret wins")
    T.eq(here.partner and here.partner.line, 3, "and it knows where it closes")
    ed:goto_position(1, 11) -- just before the `{`
    here = ed:bracket_at_caret()
    T.eq(here and here.char, "{", "the bracket at the caret is found too")
    ed:goto_position(2, 5)
    T.eq(ed:bracket_at_caret(), nil, "and nowhere near one, nothing")
  end)

  T.case("an unmatched bracket at the caret has no partner", function()
    local ed = editor.new({ text = "fn main() {\n" })
    ed:goto_position(1, 12)
    local here = ed:bracket_at_caret()
    T.eq(here and here.char, "{", "it is still a bracket")
    T.eq(here.partner, nil, "it simply never closed")
  end)

  T.case("ctrl-] jumps to the partner, and back", function()
    local ed = editor.new({ text = "fn main() {\n    ok();\n}\n" })
    ed:goto_position(1, 12)
    T.ok(ed:keypressed("]", { ctrl = true }), "the key is consumed")
    T.eq(ed.line, 3, "landed on the closing brace")
    T.eq(ed.col, 1, "landed on the closing brace")
    ed:keypressed("]", { ctrl = true })
    T.eq(ed.line, 1, "and back to the opening one")
    T.eq(ed.col, 11, "and back to the opening one")
  end)

  T.case("ctrl-shift-] selects to the partner", function()
    local ed = editor.new({ text = "fn main() {\n    ok();\n}\n" })
    ed:goto_position(1, 12)
    ed:keypressed("]", { ctrl = true, shift = true })
    T.eq(ed:selected_text(), "\n    ok();\n", "the block between the braces")
  end)

  T.case("with no bracket at the caret the jump is refused", function()
    local ed = editor.new({ text = "let x = 1;\n" })
    ed:goto_position(1, 4)
    T.nope(ed:goto_match(), "nothing to jump to")
    T.eq(ed.col, 4, "and the caret did not move")
  end)

  T.case("the analysis follows the buffer as it is typed", function()
    local c = clock()
    local ed = editor.new({ now = c.now, text = "fn main() {\n" })
    T.eq(#ed:unmatched_brackets(), 1, "one brace open")
    T.ok(ed:unmatched_lines()[1], "line 1 is the one to look at")
    ed:goto_position(2, 1)
    type_text(ed, "}")
    T.eq(#ed:unmatched_brackets(), 0, "closing it clears the report")
    T.nope(ed:unmatched_lines()[1], "and line 1 is quiet again")
    ed:undo()
    T.eq(#ed:unmatched_brackets(), 1, "undo puts the problem back")
  end)

  T.case("FORMAT's whole-buffer replace re-reads the brackets", function()
    local ed = editor.new({ text = "fn main() {\n" })
    T.eq(#ed:unmatched_brackets(), 1, "before")
    ed:replace_all("fn main() {}\n")
    T.eq(#ed:unmatched_brackets(), 0, "after")
  end)

  -- Pairing is a stack, so the last `}` closes the *innermost* `{` and the
  -- one left over is the outermost. That is not an accident and it is what
  -- `rustc` points at too: the brace that was opened and never closed is the
  -- function's, whatever the player thought they were forgetting.
  T.case("a forty-line answer with one missing brace names the line left open", function()
    local lines = {}
    for i = 1, 40 do
      lines[i] = ("    let v%d = compute(%d);"):format(i, i)
    end
    table.insert(lines, 1, "fn main() {")
    table.insert(lines, 12, "    if v11 > 0 {")
    lines[#lines + 1] = "}"
    local ed = editor.new({ text = table.concat(lines, "\n") })
    local unmatched = ed:unmatched_brackets()
    T.eq(#unmatched, 1, "exactly one thing is wrong")
    T.eq(unmatched[1].line, 1, "and it is the `fn main() {` that never closed")
    T.eq(unmatched[1].char, "{", "an opener with no closer")
  end)

  T.section("editor — what a quest screen opens on (PROTOCOL §4.8)")

  -- `draft ?? starter`, and the whole of the autosave feature on this side of
  -- the wire. There is no save call to test because there is no save call:
  -- the server kept the source of every run and submit already (SPEC §2.2),
  -- and this function is the read.
  T.case("a draft is what the editor opens on", function()
    T.eq(editor.opening_text({ starter = "fn main() {}", draft = "fn main() { mine() }" }),
      "fn main() { mine() }",
      "the player's own most recent run or submit wins")
  end)

  T.case("a quest nobody has touched opens on the starter", function()
    T.eq(editor.opening_text({ starter = "fn main() {}" }), "fn main() {}",
      "`draft` is absent on a first visit")
    T.eq(editor.opening_text({ starter = "fn main() {}", draft = nil }), "fn main() {}")
  end)

  T.case("an empty draft is still a draft", function()
    -- Somebody who cleared the buffer and pressed RUN gets an empty buffer
    -- back: that is what they left. The browser client spells this
    -- `draft ?? starter`, where `""` survives too — the two clients must not
    -- disagree about the same quest.
    T.eq(editor.opening_text({ starter = "fn main() {}", draft = "" }), "",
      "empty is a value, not an absence")
  end)

  T.case("`null` is absence, not a table", function()
    -- §5.3 sends `null` (not omitted) under an interview, and `src/json.lua`
    -- decodes JSON null to a sentinel **table**, which is truthy in Lua.
    -- `draft or starter` on the raw payload would hand the editor a table and
    -- the failure would be inside a draw call. `net/client.lua` denulls
    -- payloads before a scene sees them; this is the belt to that braces,
    -- exactly as `Clock.parse` takes it.
    local json = require("src.json")
    T.eq(editor.opening_text({ starter = "fn main() {}", draft = json.null }),
      "fn main() {}", "an interview starts from the starter")
    T.eq(editor.opening_text({ starter = json.null, draft = json.null }), "",
      "and neither sentinel reaches the buffer")
  end)

  T.case("nothing at all is the empty buffer, never nil", function()
    T.eq(editor.opening_text(nil), "")
    T.eq(editor.opening_text({}), "")
    -- `Editor:set_text` is the consumer, and it must never be handed a table.
    local ed = editor.new({})
    ed:set_text(editor.opening_text({ draft = "one\ntwo" }))
    T.eq(ed:line_count(), 2)
    T.eq(ed:text(), "one\ntwo")
  end)

  T.section("editor — the coder's answer, put in above the caret")

  T.case("goes in above the caret's line, indented like it, in one undo", function()
    local ed = editor.new({})
    ed:set_text("func main() {\n    fmt.Println(a)\n}")
    ed.line, ed.col = 2, 5
    ed:note_above({ "// AI: a is a slice", "//     of five ints" })
    local lines = {}
    for line in (ed:text() .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    T.eq(lines[2], "    // AI: a is a slice", "the first line takes the caret line's indent")
    T.eq(lines[3], "    //     of five ints")
    T.eq(lines[4], "    fmt.Println(a)", "the code it was about is still under it")
    T.eq(ed.line, 4, "and the caret is still on that code")
    -- One press takes the whole block out again, not one line of it.
    T.ok(ed:undo(), "there is something to undo")
    T.eq(ed:text(), "func main() {\n    fmt.Println(a)\n}", "all of it, in one step")
  end)

  T.case("goes after the program when the caret was never put anywhere", function()
    local ed = editor.new({})
    ed:set_text("package main\n\nfunc main() {}")
    T.eq(ed.line, 1)
    T.eq(ed.col, 1)
    ed:note_above({ "// AI: it prints nothing yet" })
    local text = ed:text()
    T.ok(text:sub(1, 12) == "package main", "the top of the file is untouched")
    T.ok(text:find("// AI: it prints nothing yet", 1, true) > #"package main",
      "and the answer is after the program")
  end)

  T.case("nothing to say is nothing written", function()
    local ed = editor.new({})
    ed:set_text("x")
    ed:note_above({})
    T.eq(ed:text(), "x")
  end)

  T.section("editor — no love in the model")

  T.case("src/editor.lua does not reference love", function()
    T.no_love("src/editor.lua")
  end)
end
