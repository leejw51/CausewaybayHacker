-- The edit stack: the three rules that decide whether a button is live, the
-- one rule that decides what text an undo puts in the editor, and the five
-- messages that carry all of it.
--
-- Headless, because `src/net/edits.lua` and `src/editor.lua` are both
-- LÖVE-free — which is the whole reason the decisions live there rather than
-- in the scene. What cannot be asserted without a window is the geometry of
-- the three buttons, and that case is guarded and runs under `make test`.

local T = require("tests.framework")
local Edits = require("src.net.edits")
local Editor = require("src.editor")

--- A session that answers whatever the test tells it to and remembers every
--- request it was given. The real one is `src/session.lua`; all this half of
--- the client needs from it is `request(type, payload, cb)`.
local function fake_session(answer)
  local self = { sent = {} }
  function self:request(type_name, payload, cb)
    self.sent[#self.sent + 1] = { type = type_name, payload = payload }
    local ok, reply, why = answer(type_name, payload)
    if cb then cb(ok, reply, why) end
    return "c-" .. #self.sent
  end
  return self
end

--- An `EditState` as the server sends it, for the cases that only care about
--- the two numbers.
local function state(cursor, depth, source)
  return { quest_id = "q", cursor = cursor, depth = depth, source = source }
end

return function()
  T.section("the edit stack — what each button is allowed to do")

  T.case("the module never touches love", function()
    -- `src/net/*` is in the Makefile's LAYERED list, which is what lets this
    -- whole suite run without a window.
    T.no_love("src/net/edits.lua")
  end)

  T.case("UNDO, REDO and CLEAR are decided by the cursor and the depth", function()
    -- PROTOCOL: `can_undo` is `cursor > 0` and `can_redo` is `cursor < depth`.
    -- Derived here rather than read off the payload so that the caption
    -- `stack 3/5` and the greyness of the button beside it cannot come to
    -- different conclusions about the same two numbers.
    local rows = {
      -- cursor depth  undo   redo   clear
      { 0, 0, false, false, false },  -- nothing has happened yet
      { 1, 1, true,  false, true  },  -- one edit, nothing to redo
      { 0, 3, false, true,  true  },  -- undone all the way to the starter
      { 2, 3, true,  true,  true  },  -- in the middle of the history
      { 3, 3, true,  false, true  },  -- at the top
    }
    for _, r in ipairs(rows) do
      local s = state(r[1], r[2])
      local tag = ("cursor %d of %d"):format(r[1], r[2])
      T.eq(Edits.can_undo(s), r[3], tag .. ": undo")
      T.eq(Edits.can_redo(s), r[4], tag .. ": redo")
      T.eq(Edits.can_clear(s), r[5], tag .. ": clear")
    end
  end)

  T.case("no state at all greys all three, which is the degradation", function()
    -- A server that has never heard of `edit.*` answers an error, the scene
    -- keeps `nil`, and the quest screen goes on working. Every predicate has
    -- to say `false` for that, and for anything else that is not a state.
    for _, nothing in ipairs({ "nil", "a string", 7, true }) do
      local s = nothing ~= "nil" and nothing or nil
      T.eq(Edits.can_undo(s), false)
      T.eq(Edits.can_redo(s), false)
      T.eq(Edits.can_clear(s), false)
    end
    T.eq(Edits.can_undo(nil), false)
    T.eq(Edits.can_redo(nil), false)
    T.eq(Edits.can_clear(nil), false)
  end)

  T.case("a reply is clamped rather than believed", function()
    local s = Edits.normalize({ quest_id = "q", cursor = 9, depth = 3, source = "x" })
    T.eq(s.cursor, 3, "a cursor past the top of the stack is the top")
    T.eq(s.depth, 3)
    T.eq(s.source, "x")
    local empty = Edits.normalize({})
    T.eq(empty.cursor, 0)
    T.eq(empty.depth, 0)
    T.eq(empty.source, nil)
    T.eq(empty.quest_id, nil)
    -- Not a table is not a state: "the server has not answered" and "the
    -- stack is empty" must stay distinguishable, because the first greys
    -- three buttons and the second greys two.
    T.eq(Edits.normalize(nil), nil)
    T.eq(Edits.normalize("{}"), nil)
  end)

  T.section("the edit stack — what an undo puts in the editor")

  T.case("undo and redo replace the editor's text with what came back", function()
    local ed = Editor.new({ text = "fn main() { the player's own code }" })
    -- Undo: the entry the cursor moved back to.
    ed:replace_all(Edits.text_for(state(1, 2, "fn main() { an earlier draft }"), "STARTER"))
    T.eq(ed:text(), "fn main() { an earlier draft }")
    -- Redo: forward again, to the entry the tail still holds.
    ed:replace_all(Edits.text_for(state(2, 2, "fn main() { the player's own code }"), "STARTER"))
    T.eq(ed:text(), "fn main() { the player's own code }")
    -- And `replace_all` is one undo step, which is what makes the editor's
    -- own ctrl-Z enough protection for a button that rewrites the buffer.
    ed:undo()
    T.eq(ed:text(), "fn main() { an earlier draft }")
  end)

  T.case("the bottom of the stack is the starter, not an empty buffer", function()
    -- `source: null` on the wire — already `nil` by the time a scene sees it,
    -- because `src/net/client.lua` strips the sentinel — means the cursor is
    -- at the bottom and nothing has been applied.
    local ed = Editor.new({ text = "whatever was typed" })
    ed:replace_all(Edits.text_for(state(0, 2, nil), "fn main() {}"))
    T.eq(ed:text(), "fn main() {}")
    -- An **empty** entry is still an entry: somebody who cleared the buffer
    -- and pressed RUN gets an empty buffer back, not the starter.
    T.eq(Edits.text_for(state(1, 1, ""), "fn main() {}"), "")
    -- And a quest with no starter either is an empty buffer rather than a
    -- crash inside a draw call.
    T.eq(Edits.text_for(state(0, 0, nil), nil), "")
    T.eq(Edits.text_for(nil, "fn main() {}"), "fn main() {}")
  end)

  T.section("the edit stack — the five messages")

  T.case("each call sends its own type, with the quest id", function()
    local reply = { quest_id = "q1", cursor = 2, depth = 2, source = "s" }
    local session = fake_session(function() return true, reply end)
    local seen = {}
    local function keep(ok, st) seen[#seen + 1] = { ok = ok, state = st } end

    Edits.state(session, "q1", keep)
    Edits.undo(session, "q1", keep)
    Edits.redo(session, "q1", keep)
    Edits.clear(session, "q1", keep)
    Edits.push(session, "q1", "fn main() {}", keep)

    local types = {}
    for i, entry in ipairs(session.sent) do
      types[i] = entry.type
      T.eq(entry.payload.quest_id, "q1", entry.type .. " carries the quest id")
    end
    T.same(types, { "edit.state", "edit.undo", "edit.redo", "edit.clear", "edit.push" })
    -- Only the push carries a source; the other four are a quest id and
    -- nothing else, and every one of the five answers the whole state.
    T.eq(session.sent[5].payload.source, "fn main() {}")
    T.eq(session.sent[1].payload.source, nil)
    T.eq(#seen, 5)
    for _, entry in ipairs(seen) do
      T.eq(entry.ok, true)
      T.eq(entry.state.cursor, 2)
      T.eq(entry.state.depth, 2)
    end
  end)

  T.case("a failure hands back no state, and says whether the feature exists", function()
    local session = fake_session(function()
      return false, { code = "not_found" }, { player = "Not here yet." }
    end)
    local got
    Edits.undo(session, "q1", function(ok, st, payload, why)
      got = { ok = ok, state = st, payload = payload, why = why }
    end)
    T.eq(got.ok, false)
    T.eq(got.state, nil, "nothing to draw, so the buttons stay grey")
    T.eq(Edits.unsupported(got.payload), true)
    T.eq(got.why.player, "Not here yet.")
    -- A server that is there but broke is **not** a server without the
    -- feature: greying the buttons for the rest of the visit would be the
    -- wrong answer to a hiccup.
    T.eq(Edits.unsupported({ code = "internal" }), false)
    T.eq(Edits.unsupported({ code = "rate_limited" }), false)
    T.eq(Edits.unsupported(nil), false)
  end)

  T.case("no session at all is an error, not a crash", function()
    -- The scene calls these from a callback that may outlive the screen.
    local got
    Edits.state(nil, "q1", function(ok, st, payload) got = { ok, st, payload } end)
    T.eq(got[1], false)
    T.eq(got[2], nil)
    T.eq(got[3].code, "internal")
  end)

  T.section("the edit stack — how the quest screen is wired to it")

  --- The house's own pattern for asserting a scene it cannot load headlessly:
  --- read the source, with comments stripped so a sentence about a rule is
  --- never mistaken for the rule.
  local function code_of(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local body = fh:read("*a")
    fh:close()
    body = body:gsub("%-%-%[%[.-%]%]", " ")
    local out = {}
    for line in (body .. "\n"):gmatch("(.-)\n") do
      out[#out + 1] = line:gsub("%-%-.*$", "")
    end
    return table.concat(out, "\n")
  end

  T.case("the screen asks once on open, and pushes at the moments that mean something", function()
    local code = code_of("src/scenes/quest.lua")
    if not code then
      T.skip("src/scenes/quest.lua", "not readable from this working directory")
      return
    end
    -- `true` is `adopt`: the stack wins over the draft on open (PROTOCOL
    -- §4.11c), because the idle push puts typing on the stack that a draft —
    -- a read of the last attempt — never sees. Asserted with the argument, so
    -- dropping it silently cannot pass.
    T.ok(code:find("self:edit_ask(Edits.state, true)", 1, true) ~= nil,
      "the stack is asked for when the quest screen opens, and adopted")
    -- In `enter` and not in `refresh`: `refresh` fires again on every
    -- language change, and the stack is the same bytes in every language.
    local enter = code:match("function Quest:enter%(params%).-\nend")
    T.ok(enter ~= nil and enter:find("edit_ask(Edits.state, true)", 1, true) ~= nil,
      "asked from `enter`")
    local refresh = code:match("function Quest:refresh%(%).-\nend")
    T.ok(refresh ~= nil and refresh:find("edit_ask", 1, true) == nil,
      "and not from `refresh`, which re-fires on every language change")
    -- RUN and SUBMIT are the two moments the buffer already leaves the
    -- machine, so they are the two moments a stack step is unambiguous.
    local execute = code:match("function Quest:execute%(mode%).-\nend")
    T.ok(execute ~= nil and execute:find("self:edit_push()", 1, true) ~= nil,
      "a run and a submit each put the buffer on the stack")
  end)

  T.case("a reply can never provoke a push of its own text", function()
    local code = code_of("src/scenes/quest.lua")
    if not code then return end
    -- The bug this guards: undo replaces the buffer, which bumps the
    -- editor's revision, which the idle timer reads as typing — and a push
    -- truncates the redo tail. One undo, a pause, and redo is gone for good.
    local tick = code:match("function Quest:tick_stack%(dt%).-\nend")
    T.ok(tick ~= nil, "the idle push is one function")
    tick = tick or ""
    T.ok(tick:find("rev == self.edit_rev", 1, true) ~= nil,
      "the timer compares against the revision the last reply left behind")
    T.ok(tick:find("Quest.PUSH_IDLE_S", 1, true) ~= nil,
      "and only fires once the typing has actually stopped")
    for _, fn in ipairs({ "edit_reply", "adopt_stack_text" }) do
      local body = code:match("function Quest:" .. fn .. "%b().-\nend")
      T.ok(body ~= nil and body:find("self.edit_rev = ", 1, true) ~= nil,
        fn .. " records the revision it leaves behind")
    end
  end)

  T.case("undo and redo go through replace_all, and the starter rule is shared", function()
    local code = code_of("src/scenes/quest.lua")
    if not code then return end
    T.ok(code:find("editor:replace_all(Edits.text_for(state, starter))", 1, true) ~= nil,
      "one undo step, and the null-means-starter rule is `src/net/edits.lua`'s")
    local adopt = code:match("function Quest:adopt_stack_text%(state%).-\nend") or ""
    T.nope(adopt:find("editor:set_text", 1, true),
      "set_text would drop the entry that makes the editor's own ctrl-Z enough")
    T.ok(code:find("self:edit_ask(Edits.undo, true)", 1, true) ~= nil, "UNDO adopts the text")
    T.ok(code:find("self:edit_ask(Edits.redo, true)", 1, true) ~= nil, "REDO adopts the text")
    -- Clearing a history is not an edit, so it leaves the buffer alone.
    T.ok(code:find("self:edit_ask(Edits.clear, false,", 1, true) ~= nil,
      "CLEAR keeps whatever text the editor is showing")
    -- And says so only once the server has agreed, the way SOLVE takes its
    -- hint counter from the payload rather than guessing it.
    local clear = code:match("function Quest:stack_clear%(%).-\nend") or ""
    T.ok(clear:find('function() self.stack_note = "cleared" end', 1, true) ~= nil,
      "the note is set from the reply, not before it")
  end)

  T.case("the buttons and their captions read the same two numbers", function()
    local code = code_of("src/scenes/quest.lua")
    if not code then return end
    for _, call in ipairs({ "Edits.can_undo(stack)", "Edits.can_redo(stack)",
                            "Edits.can_clear(stack)" }) do
      T.ok(code:find(call, 1, true) ~= nil, call .. " decides the button")
    end
    -- A missing stack greys them without touching `self.error`, which is the
    -- brief pane's red band: a node whose history is unavailable is not a
    -- node that failed to load.
    local reply = code:match("function Quest:edit_reply%b().-\nend") or ""
    T.ok(reply:find("Edits.unsupported(payload)", 1, true) ~= nil,
      "an unbuilt feature is branched on, not lumped in with errors")
    T.nope(reply:find("self.error", 1, true),
      "and never lands in the brief pane's failure register")
  end)

  T.case("the stack's keys do not take the editor's own ctrl-Z away", function()
    local code = code_of("src/scenes/quest.lua")
    if not code then return end
    -- `src/editor.lua` keeps the fine-grained history — one keystroke — and
    -- the server keeps the coarse one. Inside the editor the chord stays the
    -- editor's; on the brief, where the editor has no claim on it, it drives
    -- the server's stack. The browser client draws the same line around
    -- CodeMirror.
    T.ok(code:find('key == "z" and self.focus ~= "editor"', 1, true) ~= nil,
      "ctrl-Z drives the server's stack only where the editor does not want it")
    -- SHIFT-F6 beside F6's reset, and the chord tested first so the bare key
    -- still restores the starter.
    local chord = code:find('key == "f6" and mods.shift', 1, true)
    local reset = code:find('key == "f6" then self:reset', 1, true)
    T.ok(chord ~= nil and reset ~= nil and chord < reset,
      "SHIFT-F6 clears the stack; plain F6 still restores the starter")
  end)

  T.case("one dropped frame does not take the feature away for the visit", function()
    -- The whole point of this test: `edit.state` is asked exactly once, when
    -- the screen opens. A socket caught mid-reconnect answers
    -- `internal: not connected` the instant it is asked, and a screen that
    -- threw its state away on that would grey three working buttons for the
    -- rest of the visit — and never push again, because the idle timer bails
    -- when there is no state. Only `not_found` and `unavailable` are
    -- permanent, because only they mean the feature is not there.
    local Quest = require("src.scenes.quest")
    local scene = setmetatable({ editor = Editor.new({ text = "x" }) },
      { __index = Quest })
    scene.edit = Edits.normalize({ quest_id = "q", cursor = 2, depth = 3 })

    scene:edit_reply(false, nil, { code = "internal" }, { player = "Something broke." })
    T.nope(scene.edit_unsupported, "a hiccup is not a missing feature")
    T.ok(Edits.can_undo(scene.edit), "and the buttons the server said were live stay live")
    T.eq(scene.edit_busy, false, "the slot is free for the next press")
    T.eq(scene.stack_note, "Something broke.", "with the reason on screen")

    scene:edit_reply(false, nil, { code = "not_found" }, { player = "Not here yet." })
    T.eq(scene.edit_unsupported, true, "a server without the feature is permanent")
    T.eq(scene.edit, nil)
    T.eq(Edits.can_undo(scene.edit), false, "and all three go grey")
  end)

  T.section("the edit stack — the three buttons on the screen")

  T.case("the stack's cluster stands inside the well, clear of everything else", function()
    if not (love and love.graphics) then
      T.skip("the stack's buttons", "needs fonts, so needs LÖVE")
      return
    end
    local Layout = require("src.layout")
    local Quest = require("src.scenes.quest")
    local was_font, was_mode, was_vw, was_vh = Layout.font, Layout.mode, Layout.vw, Layout.vh
    local app = { session = { authed = true }, land = "go", category = "basic" }
    local I18n = require("src.i18n")
    local was_lang = I18n.lang
    for _, lang in ipairs(I18n.LANGS) do
      I18n.set(lang)
      for _, step in ipairs({ 1, 2, 4 }) do
        Layout.font = step
        for _, shape in ipairs({ { "landscape", 1280, 720 }, { "portrait", 720, 1280 },
                                 { "portrait", 720, 1000 } }) do
          Layout.mode, Layout.vw, Layout.vh = shape[1], shape[2], shape[3]
          local q = Quest.new(app)
          q.quest = { id = "x", land = "go", tests = { visible = {}, hidden_count = 2 } }
          local _, well = q:panes()
          local b = q:button_band(well)
          local tag = ("%s step %d %s %dx%d"):format(lang, step, shape[1], shape[2], shape[3])
          -- Inside the well, across and down.
          T.ok(b.ux >= well.x, tag .. ": the cluster starts inside the well")
          T.ok(b.clx + b.cw <= well.x + well.w, tag .. ": and ends inside it")
          T.ok(b.uy >= well.y and b.uy + b.bh <= well.y + well.h,
            tag .. ": and stands on a row of the well")
          -- The three do not overlap each other.
          T.ok(b.rdx >= b.ux + b.uw, tag .. ": REDO is clear of UNDO")
          T.ok(b.clx >= b.rdx + b.rw, tag .. ": CLEAR is clear of REDO")
          -- Nor the buffer pair, on whichever row each of them ended up on.
          if b.uy == b.ly then
            T.ok(b.ux >= b.fx + b.fw, tag .. ": sharing a row, it starts past FORMAT")
          end
          -- **Never over RUN or SUBMIT.** Reaching for the reflex button must
          -- not land on a control that rewrites the buffer.
          if b.uy == b.by then
            T.ok(b.clx + b.cw <= b.rx, tag .. ": on the button row, it stops short of RUN")
          end
          -- And the band never takes more of the well than the code has.
          T.ok(b.reserve <= well.h * 0.6 + b.bh,
            tag .. ": the band leaves the well to the code, reserve " .. b.reserve)
          -- The console, with the note plate up over it. Both are laid out
          -- from the same `band_top`, so a note is the one thing that can
          -- squeeze the log — and **this screen already has that limit**: at
          -- the largest type step in a 720 px window, SOLVE's four-line
          -- aftermath leaves the console no row either. That is a pre-existing
          -- property of the note plate and not this round's to fix, so what is
          -- asserted is the thing that is actually in this round's gift: the
          -- confirmation must cost the log **no more** than the sentence that
          -- was already here, and the console must stay in the well whatever
          -- is on the plate.
          q.run_attempt = { verdict = "compile_error", tests_passed = 0, tests_total = 1 }
          q.show_log = true
          q.edit = { quest_id = "x", cursor = 1, depth = 1 }
          q.solve_note = "solved"
          local was = q:console_rect(well, b)
          q.solve_note, q.stack_note = nil, "confirm"
          local c = q:console_rect(well, b)
          T.ok(c.log_rows >= was.log_rows,
            tag .. ": the confirmation costs the log no more than SOLVE's note ("
              .. c.log_rows .. " vs " .. was.log_rows .. ")")
          T.ok(c.open and c.y >= well.y and c.y + c.h <= Quest.band_top(b),
            tag .. ": and the console stays inside the well, above the band")
        end
      end
    end
    I18n.set(was_lang)
    Layout.font, Layout.mode, Layout.vw, Layout.vh = was_font, was_mode, was_vw, was_vh
  end)

  T.section("quest — ANSWER (the type-along target)")

  T.case("the progress is a prefix, and it says where the two part company", function()
    local Quest = require("src.scenes.quest")
    local answer = 'fn main() {\n    println!("hi");\n}\n'

    local empty = Quest.answer_progress("", answer)
    T.eq(empty.matched, 0, "nothing typed is nothing matched")
    T.eq(empty.wrong, 0, "and nothing wrong")
    T.eq(empty.total, #answer, "out of the whole answer")
    T.nope(empty.done, "and it is not done")

    T.eq(Quest.answer_progress("fn main", answer).matched, 7, "a prefix counts")
    local bad = Quest.answer_progress("fn maim() {", answer)
    T.eq(bad.matched, 6, "the count stops at the divergence")
    T.eq(bad.wrong, 5, "and the rest is the divergence")

    T.ok(Quest.answer_progress(answer, answer).done, "every character, exactly")
    T.nope(Quest.answer_progress(answer .. " ", answer).done, "one past it is not done")
    T.eq(Quest.answer_progress(answer .. " ", answer).wrong, 1, "it is one wrong")
  end)

  T.case("+LINE takes a line, and refuses to take one past a mistake", function()
    local Quest = require("src.scenes.quest")
    local answer = 'fn main() {\n    println!("hi");\n}\n'

    T.eq(Quest.answer_completion("", answer), "fn main() {", "the line you are on")
    T.eq(Quest.answer_completion("fn ma", answer), "in() {", "from where you are in it")
    T.eq(Quest.answer_completion("fn main() {", answer), "\n    ",
      "at a line's end, the newline and the next line's indent")
    T.eq(Quest.answer_completion("fn maim", answer), nil, "never past a divergence")
    T.eq(Quest.answer_completion(answer, answer), nil, "and nothing once it is typed")

    -- Pressed until it stops giving, it lands exactly on the answer.
    local typed = ""
    for _ = 1, 200 do
      local next_ = Quest.answer_completion(typed, answer)
      if not next_ then break end
      typed = typed .. next_
    end
    T.eq(typed, answer, "the button alone types the answer out, exactly")
  end)

  T.case("indentation is filled in, because it cannot be typed", function()
    local Quest = require("src.scenes.quest")
    -- Go, as gofmt writes it: tabs. This editor's newline guesses spaces, so
    -- against this answer the space bar never matched and the quest could not
    -- be finished. Reported exactly that way.
    local tabs = "func main() {\n\tswitch {\n\tcase 1:\n\t}\n}\n"
    local spaces = 'fn main() {\n    println!("hi");\n}\n'

    T.eq(Quest.answer_indent("func main() {\n", tabs), "\t", "the answer's own tab")
    T.eq(Quest.answer_indent("fn main() {\n", spaces), "    ", "or its own spaces")
    T.eq(Quest.answer_indent("func main() {", tabs), nil, "only at the start of a line")
    T.eq(Quest.answer_indent("func main() {\n\tswi", tabs), nil, "and only the run itself")
    T.eq(Quest.answer_indent("", spaces), nil, "nothing when a line starts with code")
    T.eq(Quest.answer_indent("func maim() {\n", tabs), nil, "never past a divergence")

    -- The property that was broken: the answer can be typed out without the
    -- player ever typing a tab.
    local typed, by_hand = "", {}
    for _ = 1, 400 do
      local indent = Quest.answer_indent(typed, tabs)
      if indent then
        typed = typed .. indent
      elseif #typed < #tabs then
        local ch = tabs:sub(#typed + 1, #typed + 1)
        by_hand[#by_hand + 1] = ch
        typed = typed .. ch
      else
        break
      end
    end
    T.eq(typed, tabs, "typed out, it is the answer")
    for _, ch in ipairs(by_hand) do
      T.nope(ch == "\t", "the player never has to type a tab")
    end
  end)

  T.case("ANSWER ONLY holes what the quest did not give you", function()
    local Quest = require("src.scenes.quest")
    local starter = "package main\n\nfunc main() {\n\t// your code here\n}\n"
    local answer = 'package main\n\nfunc main() {\n\tfmt.Println("hi")\n}\n'

    local holes = Quest.solution_blanks(answer, starter)
    T.eq(#holes, 1, "one line differs, so one hole")
    T.eq(answer:sub(holes[1].from + 1, holes[1].to), 'fmt.Println("hi")',
      "and the hole is exactly the line the starter does not have")
    T.eq(answer:sub(holes[1].from, holes[1].from), "\t",
      "a line's indentation is left out of the hole — the mode fills that")

    -- A solution in two places leaves the untouched middle alone.
    local s2 = "import a\n\nfunc main() {\n}\n"
    local a2 = "import a\nimport b\n\nfunc main() {\n\tgo()\n}\n"
    local two = Quest.solution_blanks(a2, s2)
    T.eq(#two, 2, "two places, two holes")
    T.eq(a2:sub(two[1].from + 1, two[1].to), "import b", "the first")
    T.eq(a2:sub(two[2].from + 1, two[2].to), "go()", "and the second")

    -- A "delete the bug" quest -- the answer is the starter minus a line --
    -- shares every line it has. There is no scaffold to skip, so the whole
    -- answer is the player's, which is the one thing better than nothing.
    local del_s = "func f() {\n\tbad()\n\tgood()\n}\n"
    local del_a = "func f() {\n\tgood()\n}\n"
    local del = Quest.solution_blanks(del_a, del_s)
    T.eq(#del, 3, "every line of it is the drill")
    T.eq(del_a:sub(del[2].from + 1, del[2].to), "good()", "including the line it kept")

    T.ok(#Quest.solution_blanks(starter, starter) > 0, "the same text is a whole drill, not an empty one")
    T.ok(#Quest.solution_blanks(answer, nil) > 0, "a quest with no starter holes everything")

    -- Played out, the drill is the answer.
    local typed = ""
    for _ = 1, 500 do
      local add = Quest.blanks_fill(typed, answer, holes)
      if not add then add = Quest.answer_indent(typed, answer) end
      if add then
        typed = typed .. add
      elseif #typed < #answer then
        typed = typed .. answer:sub(#typed + 1, #typed + 1)
      else
        break
      end
    end
    T.eq(typed, answer, "the drill, played out, is the answer")
  end)

  T.case("the boilerplate goes, a draft never does", function()
    local Quest = require("src.scenes.quest")
    local starter = "fn main() {\n    // your code here\n}\n"
    T.ok(Quest.clears_for_answer(starter, starter), "the starter the quest shipped")
    T.ok(Quest.clears_for_answer("\n" .. starter .. "  ", starter),
      "whitespace nobody decided on is not a difference")
    T.nope(Quest.clears_for_answer(starter .. "// mine\n", starter), "a draft stays")
    T.nope(Quest.clears_for_answer("", starter), "and an empty buffer is not the starter")
    T.nope(Quest.clears_for_answer("", ""), "a quest with no starter clears nothing")
  end)

  T.case("BLANKS cuts holes at words, and the fill keeps the prefix true", function()
    local Quest = require("src.scenes.quest")
    local answer = 'fn main() {\n    println!("hi");\n}\n'

    -- Every hole is a whole word of the answer, never part of one.
    local words = {}
    local at = 1
    while true do
      local from, to = answer:find("[%a_][%w_]*", at)
      if not from then break end
      words[(from - 1) .. ":" .. to] = true
      at = to + 1
    end
    for _, b in ipairs(Quest.answer_blanks(answer, 7)) do
      T.ok(words[b.from .. ":" .. b.to], "a hole is a word, not a slice of one")
    end

    -- The same seed is the same drill, and there is always something to do.
    local a = Quest.answer_blanks(answer, 3)
    local b = Quest.answer_blanks(answer, 3)
    T.eq(#a, #b, "the same seed gives the same number of holes")
    for i = 1, #a do T.eq(a[i].from, b[i].from, "and the same holes") end
    for _, seed in ipairs({ 1, 2, 3, 99, 12345 }) do
      T.ok(#Quest.answer_blanks(answer, seed) > 0, "a drill always has a hole in it")
    end

    -- The mask hides the holes and nothing else, at the same width.
    local blanks = { { from = 3, to = 7 } } -- `main`
    local masked = Quest.mask_blanks(answer, blanks)
    T.eq(#masked, #answer, "the mask does not change the shape of the program")
    T.eq(masked:sub(4, 7), "____", "the hole is hidden")
    T.eq(masked:sub(1, 3), "fn ", "and the rest of the line is not")

    -- The fill types everything that is not the drill, and stops at a hole.
    T.eq(Quest.blanks_fill("", answer, blanks), "fn ", "up to the hole")
    T.eq(Quest.blanks_fill("fn ", answer, blanks), nil, "the hole is the player's")
    T.eq(Quest.blanks_fill("fn ma", answer, blanks), nil, "mid-hole, still theirs")
    T.eq(Quest.blanks_fill("fn main", answer, blanks), answer:sub(8), "then it carries on")
    T.eq(Quest.blanks_fill("fn maim", answer, blanks), nil, "never past a divergence")

    -- What the player does, in miniature: the gaps between the holes arrive
    -- on their own and the holes themselves are typed.
    local typed = ""
    for _ = 1, 500 do
      local add = Quest.blanks_fill(typed, answer, blanks)
      if add then
        typed = typed .. add
      elseif #typed < #answer then
        typed = typed .. answer:sub(#typed + 1, #typed + 1)
      else
        break
      end
    end
    T.eq(typed, answer, "the drill, played out, is the answer")
  end)
end
