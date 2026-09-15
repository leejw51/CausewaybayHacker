-- The three screens that render whatever the server answers: `search`,
-- `stats` and `ai`.
--
-- What is asserted here is the part that survives without a window: the
-- vocabulary, the thresholds, and the empty states. A screen that renders
-- zero rows silently is worse than one that says why it is empty, so "does it
-- say something" is a real property and it is checked rather than trusted.

local T = require("tests.framework")
local errors = require("src.net.errors")
local UI = require("src.ui")
local Assets = require("src.assets")

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

  T.section("screens — laid out from the type, at every step")

  T.case("the categories row fits its widest name at every type step and shape", function()
    if not (love and love.graphics) then
      T.skip("categories metrics", "needs fonts, so needs LÖVE")
      return
    end
    local Layout = require("src.layout")
    local Categories = require("src.scenes.categories")
    local rows = {
      { category = "basic", cleared = 0, total = 18, open = true },
      { category = "advanced", cleared = 0, total = 17, open = true },
      { category = "hacker", cleared = 0, total = 34, open = true },
    }
    local was_font, was_mode = Layout.font, Layout.mode
    for _, step in ipairs({ 1, 2, 3, 4 }) do
      Layout.font = step
      for _, shape in ipairs({ { "landscape", 1280, 720 }, { "portrait", 720, 1280 }, { "portrait", 1080, 1920 } }) do
        Layout.mode = shape[1]
        local m = Categories.metrics(shape[2], shape[3], rows)
        local tag = ("step %d %s %dx%d"):format(step, shape[1], shape[2], shape[3])
        -- The report: "Bgrama…" down the left edge — a name wrapped one
        -- letter to a line because the gutter was a number.
        T.ok(m.label_w >= m.widest, tag .. ": the label column holds the widest name")
        T.ok(m.rh >= 12 + UI.lineHeight(13) + 4 + UI.lineHeight(7) + 14,
          tag .. ": the row is at least the name and a line of blurb")
        T.ok(m.y0 + #rows * (m.rh + 12) - 12 <= shape[3] - UI.footerHeight(),
          tag .. ": three rows end above the footer")
        T.ok(m.count_w >= UI.textWidth("00 / 00", 10), tag .. ": the counts plate holds NN / NN")
        T.ok(m.y0 > m.title_y + m.title_h, tag .. ": the first row starts under the title")
      end
    end
    Layout.font, Layout.mode = was_font, was_mode
  end)

  T.case("the quest console is inside the well and clear of the buttons at every step", function()
    if not (love and love.graphics) then
      T.skip("quest console", "needs fonts, so needs LÖVE")
      return
    end
    local Layout = require("src.layout")
    local Quest = require("src.scenes.quest")
    local was_font, was_mode, was_vw, was_vh = Layout.font, Layout.mode, Layout.vw, Layout.vh
    local app = { session = { authed = true }, land = "go", category = "basic" }
    for _, step in ipairs({ 1, 2, 4 }) do
      Layout.font = step
      for _, shape in ipairs({ { "landscape", 1280, 720 }, { "portrait", 720, 1280 }, { "portrait", 720, 1000 } }) do
        Layout.mode, Layout.vw, Layout.vh = shape[1], shape[2], shape[3]
        local q = Quest.new(app)
        q.quest = { id = "x", land = "go", tests = { visible = {}, hidden_count = 2 } }
        -- A finished run that failed to compile: the outcome strip is up.
        q.run_attempt = { verdict = "compile_error", tests_passed = 0, tests_total = 1 }
        q.show_log = true
        local _, well = q:panes()
        local band = q:button_band(well)
        local c = q:console_rect(well, band)
        local tag = ("step %d %s %dx%d"):format(step, shape[1], shape[2], shape[3])
        T.ok(c.open, tag .. ": a run that came back opens the console")
        T.ok(c.x >= well.x and c.x + c.w <= well.x + well.w, tag .. ": the console is inside the well, across")
        T.ok(c.y >= well.y, tag .. ": the console starts inside the well")
        T.ok(c.y + c.h <= math.min(band.by, band.ly) - band.cap - 6,
          tag .. ": the console ends above the caption row and the buttons")
        T.ok(c.log_rows >= 1,
          tag .. ": under the outcome strip there is at least one log row")
        T.ok(c.reserve == c.h + 10, tag .. ": the code rows give up exactly the console")
        -- No run at all: nothing is reserved, and the screen is what it was.
        q.run_attempt, q.log, q.running_mode = nil, nil, nil
        local none = q:console_rect(well, band)
        T.ok(not none.open and none.reserve == 0, tag .. ": with nothing to show, no console")
      end
    end
    Layout.font, Layout.mode, Layout.vw, Layout.vh = was_font, was_mode, was_vw, was_vh
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
    -- The title card and the opening are in the list on purpose: a player who
    -- wants to play in portrait should not have to sign in first to be
    -- allowed to ask, and somebody watching a minute of story should be able
    -- to change the language it is told in.
    local scenes = {
      "boot", "title", "story", "login", "lands", "categories", "map",
      "quest", "result", "search", "stats", "ai", "playground",
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

  T.case("the display buttons are a real target, measured from their own labels", function()
    local _, code = strings_of("src/ui.lua")
    if not code then return end
    -- The numbers the user asked to be reported, asserted rather than
    -- described: a floor at least as high as `CausewaybayGolang`'s 36 px, and
    -- a label at the size this client draws RUN and SUBMIT at rather than the
    -- size it draws the smallest caption under a node card at.
    local floor_h = tonumber(code:match("UI%.CHIP_MIN_H = (%d+)"))
    T.ok(floor_h ~= nil and floor_h >= 32,
      "a display button is at least 32 px tall, got " .. tostring(floor_h))
    local chip_size = tonumber(code:match("UI%.CHIP_SIZE = (%d+)"))
    local _, quest = strings_of("src/scenes/quest.lua")
    -- SUBMIT's size is a variable now — the band shrinks a step at a time
    -- when it would otherwise take more of the editor pane than it leaves —
    -- so this reads the size it starts at rather than a literal at the call.
    local button_size = quest and tonumber(quest:match("local b9 = math%.max%(5, (%d+) %- drop%)"))
    T.eq(chip_size, button_size,
      "the chips are set in the same face SUBMIT starts in, not the caption face")
    -- `btnBox`: every label the button can ever wear, not the one it happens
    -- to be showing. A fixed width clips `WINDOW` or leaves `EN` ragged, and
    -- `YUE` is half again as wide as `EN`.
    T.ok(code:find("for _, label in ipairs(chip.every) do", 1, true) ~= nil,
      "each chip is measured across every label it can wear")
    T.ok(code:find("I18n.CODES[code]", 1, true) ~= nil,
      "including all six language codes")
    -- Their own row. A design that puts four controls on one 22 px line
    -- beside a wallet address is the thing this replaced.
    T.ok(code:find("function UI.controlRow()", 1, true) ~= nil,
      "the buttons have a row of their own")
    T.ok(code:find("UI.footerRow() * UI.hint_rows + UI.controlRow()", 1, true) ~= nil,
      "and the strip is the hint's rows plus that one")
    -- The feedback loop this file already paid for: a chip measured from the
    -- whole strip is measured from a number its own result changes.
    T.nope(code:find("chipHeight()\n  return math.max(UI.CHIP_MIN_H, UI.footerHeight", 1, true),
      "the chip height is never derived from the strip height")
  end)

  T.section("the title card, and the opening it guards")

  T.case("the card waits for a person; only a drive script gets the idle hand-over", function()
    local _, code = strings_of("src/scenes/title.lua")
    if not code then
      T.skip("src/scenes/title.lua", "not readable from this working directory")
      return
    end
    local idle = tonumber(code:match("Title%.IDLE_OUT = (%d+)"))
    T.ok(idle ~= nil and idle > 0, "the card gives up eventually — under a script")
    -- The report: "after a while the title goes on by itself". The clock
    -- runs only when CWBH_DRIVE names a script, and the update gates on it.
    local update = code:match("function Title:update%(dt%)(.-)\nend")
    T.ok(update ~= nil and update:find("Title.driven()", 1, true) ~= nil,
      "a player in front of the card is waited for, however long")
    T.ok(code:find('os.getenv("CWBH_DRIVE")', 1, true) ~= nil,
      "and `driven` is the drive harness's own switch, not a second flag")
    -- Every script under tests/drive waits for the login screen with
    -- `timeout = 15`, which is also `src/drive.lua`'s default. The card plus
    -- the boot screen's handshake has to land well inside that.
    T.ok(idle <= 10,
      "the idle-out (" .. tostring(idle) .. "s) fits the drive harness's 15 s budget")
    -- `main.lua` caps dt at 0.05 and macOS throttles an occluded window, so a
    -- deadline summed from dt runs twenty times slow — an 8 second card
    -- becomes an 80 second one behind another window, and the budget above is
    -- blown by the very thing it was measured against.
    T.ok(code:find("love.timer.getTime()", 1, true) ~= nil,
      "the deadline is wall time, the same rule src/drive.lua states")
    T.nope(code:find("self.idle = self.idle + dt", 1, true),
      "and not a counter fed by dt")
  end)

  T.case("with a person at the card, no amount of time moves it on", function()
    if not (love and love.timer and love.timer.getTime) then
      T.skip("title idle", "needs love.timer")
      return
    end
    local Title = require("src.scenes.title")
    local went = {}
    local app = { session = { authed = false }, go = function(_, name) went[#went + 1] = name end }
    local driven = Title.driven
    -- A player, not a script: the clock must not exist for them.
    Title.driven = function() return false end
    local card = Title.new(app)
    card:enter()
    card.since = love.timer.getTime() - (Title.IDLE_OUT * 10)
    card:update(0.016)
    T.eq(#went, 0, "eighty seconds of nobody is still the title card")
    T.nope(card.leaving)
    -- Every key but SPACE is ignored too.
    for _, key in ipairs({ "return", "escape", "x", "kpenter", "up" }) do
      card:keypressed(key)
    end
    T.eq(#went, 0, "no key but SPACE starts")
    card:keypressed("space")
    T.eq(#went, 1, "SPACE is the one way on")
    T.ok(went[1] == "story" or went[1] == "login",
      "to the opening on a fresh store, the login screen otherwise")
    -- A script at the keyboard still gets the hand-over the suite relies on.
    Title.driven = function() return true end
    went = {}
    local scripted = Title.new(app)
    scripted:enter()
    scripted.since = love.timer.getTime() - (Title.IDLE_OUT + 1)
    scripted:update(0.016)
    T.same(went, { "login" }, "under CWBH_DRIVE the card hands over on the clock, to login")
    Title.driven = driven
  end)

  T.case("the opening is offered once and remembered, skipped or not", function()
    local _, title = strings_of("src/scenes/title.lua")
    local _, story = strings_of("src/scenes/story.lua")
    if not (title and story) then return end
    -- The one question the card asks the store.
    T.ok(title:find("Store.story_seen()", 1, true) ~= nil,
      "a returning player is never shown it again unasked")
    -- And the one place the answer is written — in `out`, which is both the
    -- skip and the end, because they mean the same thing to the player.
    local out = story:match("function Story:out%(%).-\nend")
    T.ok(out ~= nil and out:find("Store.set_story_seen()", 1, true) ~= nil,
      "skipping counts: it is the same exit the ending uses")
    T.ok(story:find("function Story:keypressed", 1, true) ~= nil
      and story:find("function Story:mousepressed", 1, true) ~= nil,
      "any key, any click")
    -- The idle hand-over never marks it seen: nobody was there to see it.
    local start = title:match("function Title:start%(idle%)(.-)function Title:update")
    T.ok(start ~= nil, "the card has one way out and it is `start`")
    T.nope(start and start:find("set_story_seen", 1, true),
      "a card that timed out has not shown anybody anything")
  end)

  T.case("the opening does not spoil the map", function()
    local strings = strings_of("src/scenes/story.lua")
    if not strings then return end
    local all = table.concat(strings, "\n")
    -- docs/story.md §2 is the loss and the reason. The two lands, the
    -- mascots, the bosses and the ending are §3 and later, and an opening
    -- that names them has spent the game's own reveals in its first minute.
    for _, banned in ipairs({
      "RUST LAND", "GO LAND", "Ferris", "Gogo", "DEADLOCK", "NULLPTR",
      "THE AUTOCOMPLETE", "bg_datacentre", "HKU",
    }) do
      T.nope(all:find(banned, 1, true),
        ("the opening names %q, which belongs to a later chapter"):format(banned))
    end
    -- And it uses the seven paintings that were generated for it.
    for _, name in ipairs({
      "open_flat", "open_cursor", "open_ghost", "open_face", "open_tills",
      "open_stairs", "open_lands",
    }) do
      T.ok(all:find(name, 1, true) ~= nil, "the opening uses " .. name)
    end
  end)

  T.case("there is a way back into it, with a key and a button", function()
    local _, code = strings_of("src/scenes/login.lua")
    if not code then return end
    -- The house rule: a control nobody can see is not a feature, and a key
    -- nobody can find is not a control.
    T.ok(code:find("self.story_button", 1, true) ~= nil, "a button with a hit test")
    T.ok(code:find('key == "f10"', 1, true) ~= nil, "and a key, printed on it")
    -- Watching it again on purpose must not make it play unasked next launch.
    local watch = code:match("function Login:watch_story%(%).-\nend")
    T.nope(watch and watch:find("clear", 1, true),
      "a replay does not reset the flag")
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

  T.section("quest text in the player's language (SPEC §12.1, PROTOCOL §4.7/§4.8/§4.10)")

  T.case("every request that returns quest prose carries the interface language", function()
    -- The server substitutes a translation only when asked; a scene that
    -- forgets `locale` gets English forever and nothing looks broken.
    local _, quest = strings_of("src/scenes/quest.lua")
    local _, map = strings_of("src/scenes/map.lua")
    local _, ai = strings_of("src/scenes/ai.lua")
    T.ok(quest ~= nil and map ~= nil and ai ~= nil)
    T.ok(quest:find('"quest.get", { quest_id = self.quest_id, locale = I18n.lang }', 1, true) ~= nil,
      "quest.get asks in I18n.lang")
    T.ok(quest:find("index = index, locale = I18n.lang", 1, true) ~= nil,
      "quest.hint asks in I18n.lang — the same index into an array of the same length")
    T.ok(map:find("category = self.category, locale = I18n.lang", 1, true) ~= nil,
      "world.map asks in I18n.lang")
    T.ok(ai:find("drill_id = self.drill.id, locale = I18n.lang", 1, true) ~= nil,
      "ai.next opens the same screen and asks the same way")
  end)

  T.case("a language change under an open quest or map asks again", function()
    -- The interface re-reads its own strings for free; the prose came from
    -- the server in the old language. Both scenes record the language they
    -- asked in and compare it every frame.
    for _, path in ipairs({ "src/scenes/quest.lua", "src/scenes/map.lua" }) do
      local _, code = strings_of(path)
      T.ok(code ~= nil)
      T.ok(code:find("self.asked_lang = I18n.lang", 1, true) ~= nil, path .. " records what it asked")
      T.ok(code:find("self.asked_lang ~= I18n.lang", 1, true) ~= nil, path .. " notices the change")
    end
  end)
end
