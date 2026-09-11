-- The three screens that render whatever the server answers: `search`,
-- `stats` and `ai`.
--
-- What is asserted here is the part that survives without a window: the
-- vocabulary, the thresholds, and the empty states. A screen that renders
-- zero rows silently is worse than one that says why it is empty, so "does it
-- say something" is a real property and it is checked rather than trusted.

local T = require("tests.framework")
local errors = require("src.net.errors")

local function source_of(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  return body
end

--- Every string literal a scene can put on screen, with comments stripped.
local function strings_of(path)
  local body = source_of(path)
  if not body then return nil end
  body = body:gsub("%-%-%[%[.-%]%]", " ")
  local code = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do
    code[#code + 1] = line:gsub("%-%-.*$", "")
  end
  local joined = table.concat(code, "\n")
  local out = {}
  for literal in joined:gmatch('"([^"]*)"') do out[#out + 1] = literal end
  for literal in joined:gmatch("'([^']*)'") do out[#out + 1] = literal end
  return out, joined
end

return function()
  T.section("screens — §3.3's `unavailable` is not `internal`")

  T.case("an unbuilt feature is classified apart from a broken server", function()
    local unavailable = errors.classify("unavailable")
    local internal = errors.classify("internal")
    T.eq(unavailable.known, true)
    T.ne(unavailable.action, internal.action,
      "telling a player their machine is broken invites a retry that never works")
    T.eq(unavailable.action, "unavailable")
    -- And §3.3's milestone is readable, so a screen can name the chapter.
    T.eq(errors.milestone({ detail = { milestone = 2 } }), 2)
    T.eq(errors.milestone({ detail = {} }), nil)
    T.eq(errors.milestone({}), nil)
  end)

  T.case("search and ai both handle `unavailable` specifically", function()
    for _, path in ipairs({ "src/scenes/search.lua", "src/scenes/ai.lua" }) do
      local _, code = strings_of(path)
      if code then
        T.ok(code:find('payload.code == "unavailable"', 1, true) ~= nil,
          path .. " branches on the code rather than lumping it in with errors")
        T.ok(code:find("errors.milestone", 1, true) ~= nil,
          path .. " reads detail.milestone so it can name the chapter")
      else
        T.skip(path, "not readable from this working directory")
      end
    end
  end)

  T.section("screens — what they say to somebody with no history")

  T.case("every empty state is written, not blank", function()
    -- A new player has no mistakes, no history and no awards. Each of those
    -- is a screen someone will see on their first evening.
    local checks = {
      { "src/scenes/stats.lua", {
        "Nothing yet.",                      -- no mistakes
        "Nothing here yet.",                 -- no history
        "nothing on it yet",                 -- no awards
      } },
      { "src/scenes/ai.lua", {
        "NOTHING TO DRILL YET",
      } },
      { "src/scenes/search.lua", {
        "Type and press ENTER",              -- before the first query
      } },
    }
    for _, entry in ipairs(checks) do
      local _, code = strings_of(entry[1])
      if code then
        for _, phrase in ipairs(entry[2]) do
          T.ok(code:find(phrase, 1, true) ~= nil,
            ("%s says something when empty: %q"):format(entry[1], phrase))
        end
      else
        T.skip(entry[1], "not readable")
      end
    end
  end)

  T.case("nothing on these screens apologises", function()
    -- Having made no mistakes yet is the correct state for somebody who has
    -- just arrived, and a screen that treats it as a deficiency is wrong
    -- about the player.
    --
    -- The ban is on **apology**, not on the word "failed". SPEC §7.3 names
    -- the `repeat` plan as "the quests the user failed most", and describing
    -- what a drill selects is a statement of fact — the thing to keep out is
    -- the register that makes a blank screen feel like the player's fault.
    for _, path in ipairs({
      "src/scenes/stats.lua", "src/scenes/ai.lua", "src/scenes/search.lua",
    }) do
      local strings = strings_of(path)
      if strings then
        for _, literal in ipairs(strings) do
          local lowered = literal:lower()
          for _, banned in ipairs({
            "sorry", "oops", "unfortunately", "afraid", "you should have",
          }) do
            T.nope(lowered:find(banned, 1, true),
              ("%s: %q should not appear in %q"):format(path, banned, literal))
          end
        end
      end
    end
  end)

  T.section("screens — stats gives `cleared_since` its weight")

  T.case("five is the threshold, and it comes from SPEC §7.3", function()
    local Stats = require("src.scenes.stats")
    -- §7.3's `weakness` takes kinds with `cleared_since < 5`, so 5 is where a
    -- kind is learned and leaves the drill.
    T.eq(Stats.LEARNED_AT, 5)
  end)

  T.case("the track is said in words as well as drawn", function()
    local _, code = strings_of("src/scenes/stats.lua")
    if not code then return end
    -- The sentence is the motivating part: "count: 6" is a row in a table,
    -- "you have not done this in four submits" is about a person.
    T.ok(code:find("clean submits since", 1, true) ~= nil)
    T.ok(code:find("to go", 1, true) ~= nil)
    T.ok(code:find("learned", 1, true) ~= nil)
    T.ok(code:find("you did this on your last submit", 1, true) ~= nil)
  end)

  T.case("the shelf never invents an award", function()
    local _, code = strings_of("src/scenes/stats.lua")
    if not code then return end
    -- Earned badges come from `stats.awards`; the empty sockets are
    -- furniture. If this file ever grows a hard-coded list of award ids it is
    -- claiming something the server did not say.
    T.ok(code:find("badge_slot", 1, true) ~= nil, "the socket is drawn")
    T.ok(code:find("stats.awards", 1, true) ~= nil, "and the earned ones are asked for")
    T.nope(code:find("first%-clear"), "no invented award id")
  end)

  T.case("the shackle is the track's state, not a replacement for it", function()
    local _, code = strings_of("src/scenes/stats.lua")
    if not code then return end
    -- `art/shackle_break` is six frames and `cleared_since` runs 0..5, so
    -- frame `since + 1` is the state of the kind exactly. It stands beside
    -- the five-step track: the shackle says where you are and only the steps
    -- say how far there is to go, so the picture must not have cost the
    -- more useful half.
    T.ok(code:find("shackle_break", 1, true) ~= nil, "the strip is drawn")
    T.ok(code:find("math.min(since, Stats.LEARNED_AT) + 1", 1, true) ~= nil,
      "the frame is clamped to the strip rather than trusting the server's number")
    T.ok(code:find("for i = 1, Stats.LEARNED_AT do", 1, true) ~= nil,
      "and the five steps are still there")
  end)

  T.section("screens — one code pane, not two that look alike")

  T.case("the quest screen and the playground share the editor's mouse", function()
    -- Both screens draw an `Editor`. Before `src/codepane.lua` they each
    -- carried their own copy of the pixel → (line, col) hit test, character
    -- for character, and drag-select would have been a third and a fourth.
    -- This asserts the duplication does not come back.
    for _, path in ipairs({ "src/scenes/quest.lua", "src/scenes/playground.lua" }) do
      local _, code = strings_of(path)
      if code then
        T.ok(code:find('require("src.codepane")', 1, true) ~= nil,
          path .. " uses the shared pane")
        T.nope(code:find("Editor.next_boundary", 1, true),
          path .. " does not walk the glyphs itself any more")
        T.ok(code:find("pane:mousemoved", 1, true) ~= nil,
          path .. " is wired for a drag, not only a click")
        T.ok(code:find('isDown("lshift", "rshift")', 1, true) ~= nil,
          path .. " extends on either shift, not only the left one")
      else
        T.skip(path, "not readable from this working directory")
      end
    end
  end)

  T.case("the app dispatches the two callbacks a drag needs", function()
    local _, code = strings_of("src/app.lua")
    if not code then return end
    T.ok(code:find("function App:mousemoved", 1, true) ~= nil)
    T.ok(code:find("function App:mousereleased", 1, true) ~= nil)
    local _, main = strings_of("main.lua")
    if not main then return end
    T.ok(main:find("function love.mousemoved", 1, true) ~= nil,
      "LÖVE's callback exists, or the app's is never called")
    T.ok(main:find("function love.mousereleased", 1, true) ~= nil)
  end)

  T.section("screens — search shows why something matched")

  T.case("a null component is absence, not zero", function()
    -- §5.5: `bm25` and `cosine` are null when the quest was not in that
    -- ranking at all. Drawing that as a zero-length bar would say "it scored
    -- nothing there", which is a different and untrue fact.
    local _, code = strings_of("src/scenes/search.lua")
    if not code then return end
    T.ok(code:find("hit.bm25", 1, true) ~= nil)
    T.ok(code:find("hit.cosine", 1, true) ~= nil)
    T.ok(code:find("—", 1, true) ~= nil, "absence has its own mark")
  end)

  T.section("screens — the display controls are on every one of them")

  T.case("every scene draws the footer, which is what carries them", function()
    -- The three display buttons — window/fullscreen, orientation, type size —
    -- are drawn by `App:footer` and nowhere else, so "on every screen" is
    -- exactly "every scene calls `app:footer`". A scene added tomorrow gets
    -- them for free and this case is what notices if one does not.
    --
    -- The title card is in the list on purpose: a player who wants to play in
    -- portrait should not have to sign in first to be allowed to ask.
    local scenes = {
      "boot", "login", "lands", "categories", "map", "quest", "result",
      "search", "stats", "ai", "playground",
    }
    for _, name in ipairs(scenes) do
      local path = "src/scenes/" .. name .. ".lua"
      local _, code = strings_of(path)
      if code then
        T.ok(code:find("app:footer(", 1, true) ~= nil,
          path .. " draws the footer, so it has the display controls")
      else
        T.skip(path, "not readable from this working directory")
      end
    end
  end)

  T.case("the app draws the cluster and tests it before the scene", function()
    local _, code = strings_of("src/app.lua")
    if not code then return end
    T.ok(code:find("UI.displayControls", 1, true) ~= nil,
      "the buttons are drawn from the one place every screen already calls")
    T.ok(code:find("UI.displayReserve", 1, true) ~= nil,
      "and the footer hint is measured against what is left, not clipped after")
    -- A press on global chrome that also reached the scene underneath would
    -- open a quest while the player was changing the type size.
    local order = code:find("self:display_pressed", 1, true)
    local scene = code:find("self.scene:mousepressed", 1, true)
    T.ok(order ~= nil and scene ~= nil and order < scene,
      "the display rects are tested before the scene sees the click")
  end)

  T.case("each control says the state it is in, not the one it moves to", function()
    local _, code = strings_of("src/ui.lua")
    if not code then return end
    -- A toggle whose current value is invisible gets pressed twice: once to
    -- find out, once to put it back.
    for _, label in ipairs({ "FULL", "WINDOW", "AUTO", "PORT", "LAND" }) do
      T.ok(code:find('"' .. label .. '"', 1, true) ~= nil,
        "the cluster can say " .. label)
    end
    -- AUTO is a state *and* a resolved shape, and the glyph says the second.
    T.ok(code:find("state.shape", 1, true) ~= nil,
      "automatic still shows which shape it landed on")
    T.ok(code:find("font_label", 1, true) ~= nil,
      "and the type size says which of its steps is live")
  end)

  T.case("the keys still work, and are still the ones the README names", function()
    local _, main = strings_of("main.lua")
    if not main then return end
    T.ok(main:find('key == "f11"', 1, true) ~= nil)
    T.ok(main:find('key == "f1"', 1, true) ~= nil)
    T.ok(main:find('key == "f12"', 1, true) ~= nil, "the type size has a key too")
    T.ok(main:find("Layout.toggleFullscreen", 1, true) ~= nil)
    T.ok(main:find("Layout.cycleOrientation", 1, true) ~= nil)
    T.ok(main:find("Layout.cycleFont", 1, true) ~= nil)
  end)

  T.section("quest — the draft (§4.8) and the answer key (§4.11b)")

  T.case("the editor opens on `draft ?? starter`, through one function", function()
    local _, code = strings_of("src/scenes/quest.lua")
    if not code then
      T.skip("src/scenes/quest.lua", "not readable from this working directory")
      return
    end
    T.ok(code:find("Editor.opening_text(self.quest)", 1, true) ~= nil,
      "the fallback is `src/editor.lua`'s, so the rule is asserted headlessly")
    T.nope(code:find("self.quest.starter or", 1, true),
      "the old starter-only load is gone, or a draft would never be seen")
    -- The whole feature is a read. A client-side save would be a second home
    -- for the same bytes and the two would drift, which is the thing this
    -- project decided against in its first entry.
    T.nope(code:find("Store.set_draft", 1, true), "no client-side save path")
    T.nope(code:find("save_draft", 1, true), "no client-side save path")
  end)

  T.case("SOLVE asks the server and replaces the buffer in one undo step", function()
    local _, code = strings_of("src/scenes/quest.lua")
    if not code then return end
    T.ok(code:find('request("quest.solve"', 1, true) ~= nil,
      "§4.11b, with the quest id")
    local solve = code:match("function Quest:solve%(%).-\nend")
    T.ok(solve ~= nil, "the handler is one function")
    solve = solve or ""
    -- `replace_all` is what makes ctrl-Z enough protection to skip a
    -- confirmation dialog; `set_text` would drop the undo entry and the
    -- player's own code with it.
    T.ok(solve:find("editor:replace_all(payload.source", 1, true) ~= nil,
      "one undo step, the same guarantee FORMAT gives")
    T.nope(solve:find("editor:set_text", 1, true),
      "set_text would lose the player's code for good")
    -- The server just moved the high-water mark; the screen reads it back
    -- rather than incrementing a local guess.
    T.ok(solve:find("payload.hints_used", 1, true) ~= nil,
      "the hint counter comes from the reply")
    T.ok(solve:find('payload.code == "not_found"', 1, true) ~= nil,
      "§4.11b's one error case is branched on, not lumped in")
  end)

  T.case("what SOLVE costs is on screen, and what it does not cost is too", function()
    local strings = strings_of("src/scenes/quest.lua")
    if not strings then return end
    local all = table.concat(strings, "\n")
    -- Priced, so it cannot read as free.
    T.ok(all:find("costs a star", 1, true) ~= nil,
      "the price is under the button, before anybody presses it")
    -- And bounded, so it cannot read as scarier than it is: nothing fails,
    -- nothing locks, the node still clears — just not at three stars.
    T.ok(all:find("It can still clear", 1, true) ~= nil,
      "the node is not lost, and the screen says so")
    T.ok(all:find("not an attempt", 1, true) ~= nil,
      "asking records nothing — only SUBMIT does (§4.11b)")
    -- The same trap the RUN copy documents: "not saved" must not be said of
    -- anything here, because everything a player runs *is* kept.
    for _, banned in ipairs({ "erases", "cannot clear", "locked out", "forfeit" }) do
      for _, literal in ipairs(strings) do
        T.nope(literal:lower():find(banned, 1, true),
          ("%q overstates §4.11b (found in %q)"):format(banned, literal))
      end
    end
  end)

  T.case("SOLVE has a key as well as a button, and it is not next to RUN", function()
    local _, code = strings_of("src/scenes/quest.lua")
    if not code then return end
    -- The house rule: a control nobody can see is not a feature, and a key
    -- nobody can find is not a control. Both exist, and the key is printed on
    -- the button itself the way RUN's, SUBMIT's and FORMAT's are.
    T.ok(code:find("self.solve_rect", 1, true) ~= nil, "a button with a hit test")
    T.ok(code:find('key == "f7" and mods.shift', 1, true) ~= nil,
      "shift-F7: every one of F1..F12 was already taken on this screen")
    -- Plain F7 must still take an ordinary hint, so the chord is tested first.
    local chord = code:find('key == "f7" and mods.shift', 1, true)
    local hint = code:find('key == "f7" then self:take_hint', 1, true)
    T.ok(chord ~= nil and hint ~= nil and chord < hint,
      "the bare key still takes a hint")
    -- And the buffer-only pair sits at the far left, with FORMAT between
    -- SOLVE and RUN: reaching for RUN must never land on the answer.
    local solve_btn = code:find("self.solve_rect = {", 1, true)
    local format_btn = code:find("self.format_rect = {", 1, true)
    local run_btn = code:find("self.run_rect = {", 1, true)
    T.ok(solve_btn < format_btn and format_btn < run_btn,
      "SOLVE, FORMAT, then the gap, then RUN and SUBMIT")
  end)

  T.case("the FTS5 snippet markup is stripped rather than shown", function()
    local _, code = strings_of("src/scenes/search.lua")
    if not code then return end
    -- §5.5's snippet "may contain <b>…</b>". Showing a player raw markup is
    -- showing them the plumbing.
    T.ok(code:find("</?b>", 1, true) ~= nil, "the tags are removed")
  end)
end
