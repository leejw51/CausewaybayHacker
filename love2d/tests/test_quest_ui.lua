-- The quiz card and the verdict card, laid out at every type step and both
-- design sizes — the geometry asserted, not eyeballed.
--
-- The review's blocker (design-review.md #8): at type step 3 the quest's
-- clock printed through its title and the four choices fell off the screen.
-- The card is built on roles now, which F12 never moves, and what F12 does
-- move (the code, the reading face) steps down and then scrolls. This holds
-- that: every choice that takes a tap is on the canvas, inside the card,
-- apart from the others; the header's buttons are on the canvas and clear
-- of the title's start; and the result's buttons are on the canvas too.
--
-- Needs fonts, so it runs under `make test` and is skipped headless.

local T = require("tests.framework")

local function at(mode, ww, wh)
  local Layout = require("src.layout")
  Layout.mode = mode
  local real = love.graphics.getDimensions
  love.graphics.getDimensions = function() return ww, wh end
  Layout.updateViewport()
  love.graphics.getDimensions = real
end

local function inside(inner, outer, slack)
  slack = slack or 0
  return inner.x >= outer.x - slack and inner.y >= outer.y - slack
    and inner.x + inner.w <= outer.x + outer.w + slack
    and inner.y + inner.h <= outer.y + outer.h + slack
end

local function disjoint(a, b)
  return a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y
end

local function rect_s(r)
  return r and ("[%d,%d %dx%d]"):format(r.x, r.y, r.w, r.h) or "nil"
end

--- A long program with one hole, the shape of a HACKER quest's.
local function long_program()
  local body = {}
  for i = 1, 60 do
    body[i] = i == 40 and "        ____" or ("    let value_" .. i .. " = compute(input, " .. i .. ");")
  end
  return table.concat(body, "\n")
end

local SHEET = {
  id = "rust.cheatsheet.01.read-all", land = "rust", category = "cheatsheet", node = 1,
  title = "THE WHOLE TAPE", difficulty = 1, state = "open", stars = 0,
  story = "06:30, Jardine's Bazaar. The kiosk's input arrives all at once, and it wants all of it.",
  brief = "Read **all** of stdin into `s` in one call.\n\n```\nuse std::io::{self, Read};\nlet mut s = String::new();\n// ____\n```\n\nWhich line is it?\n",
  concepts = { "io", "strings" }, hints_total = 1, hints_used = 0,
  quiz = { answer = 1, choices = {
    "io::stdin().read_line(s);",
    "io::stdin().read_to_string(&mut s).unwrap();",
    "let s = io::stdin().read_all();",
    "io::stdin().read_to_string(s).unwrap();",
  } },
  tests = { visible = {}, hidden_count = 0 },
}

local PROGRAM = {
  id = "rust.hacker.01.two-sum", land = "rust", category = "hacker", node = 1,
  title = "TWO FARES — A LONGER TITLE THAN THE HEADER WANTS", difficulty = 3, state = "open", stars = 0,
  story = "Room 7-32. The first question is the one everybody gets, and the clock starts on the way in.",
  brief = "Line one is n target. Line two is n integers.\n\nPrint the 1-based indices.\n\n```\ninput:  4 9\n        2 7 11 15\noutput: 1 2\n```\n",
  concepts = { "hashing", "complexity", "slices" }, hints_total = 3, hints_used = 0,
  quiz = { answer = 1, program = long_program(), choices = {
    "if let Some(&i) = seen.get(&(x - target)) { println!(\"{} {}\", i + 1, j + 1); return; }",
    "if let Some(&i) = seen.get(&(target - x)) {",
    "if let Some(&i) = seen.get(&target - x) {",
    "if let Some(&i) = seen.get(&x) {",
  } },
  tests = { visible = { { name = "sample", stdin = "4 9\n2 7 11 15\n", expect = "1 2\n" } }, hidden_count = 3 },
}

return function()
  T.section("quest card — the four on the screen at every type step and shape")

  if not (love and love.graphics) then
    T.skip("quest card metrics", "needs fonts, so needs LÖVE")
    return
  end

  local App = require("src.app")
  local Layout = require("src.layout")
  local Anim = require("src.anim")
  local Juice = require("src.juice")
  local app = App.new()
  app.session = {
    authed = true,
    user = { xp = 50, level = 1 },
    request = function() return nil end,
    on = function() return {} end,
    off = function() end,
    off_all = function() end,
    display_name = function() return "tester" end,
    short_address = function() return "0x0000…0000" end,
    apply_xp = function() end,
  }
  app.client = { state = "open", url = "ws://127.0.0.1:5390/ws" }
  app.wallet_lib = nil

  local was_font, was_mode, was_vw, was_vh = Layout.font, Layout.mode, Layout.vw, Layout.vh
  -- Every entrance lands at once, so the rects are where things rest.
  Anim.freeze(10)

  local function draw()
    love.graphics.setCanvas(Layout.canvas)
    app:draw()
    love.graphics.setCanvas()
  end

  for _, quest in ipairs({ SHEET, PROGRAM }) do
    T.case(("the %s quiz: choices on the canvas, apart, under the header"):format(quest.category), function()
      for _, step in ipairs({ 1, 2, 3, 4 }) do
        Layout.font = step
        for _, shape in ipairs({ { "landscape", 1280, 720 }, { "landscape", 1920, 1080 }, { "portrait", 720, 1280 }, { "portrait", 720, 958 } }) do
          at(shape[1], shape[2], shape[3])
          Juice.forget("quest:")
          app:go("quest", { quest_id = quest.id, land = quest.land, category = quest.category })
          local scene = app.scene
          scene.quest = quest
          scene.quiz_right = false
          scene.dealt_id = quest.id
          local tag = ("%s step %d %s %dx%d"):format(quest.category, step, shape[1], shape[2], shape[3])
          -- Two frames: the first lays out, the second has the clamped scroll.
          draw(); draw()
          local screen = { x = 0, y = 0, w = Layout.vw, h = Layout.vh }
          local header = { x = 0, y = 0, w = Layout.vw, h = scene:header_h() }
          T.ok(scene.hits.map ~= nil and inside(scene.hits.map, header, 2), tag .. ": MAP is on the header " .. rect_s(scene.hits.map))
          T.ok(scene.hits.hint ~= nil and inside(scene.hits.hint, header, 2), tag .. ": HINT is on the header " .. rect_s(scene.hits.hint))
          T.ok(scene.hits.hint == nil or disjoint(scene.hits.hint, scene.hits.map), tag .. ": HINT and MAP are apart")
          T.ok(scene.hits.map.x > Layout.gutter() + 120, tag .. ": the title has at least 120 px before the buttons")
          local hits = {}
          for i = 1, 4 do if scene.choice_hits[i] then hits[#hits + 1] = scene.choice_hits[i] end end
          T.ok(#hits >= 1, tag .. ": at least one choice takes a tap at the top of the card")
          for i, r in ipairs(hits) do
            T.ok(inside(r, screen), tag .. (": choice %d %s is on the canvas"):format(i, rect_s(r)))
            T.ok(r.y >= header.h, tag .. (": choice %d is under the header"):format(i))
            T.ok(r.y + r.h <= Layout.vh - require("src.ui").footerHeight(), tag .. (": choice %d is above the footer"):format(i))
            for j = i + 1, #hits do
              T.ok(disjoint(r, hits[j]), tag .. (": choices %d and %d are apart"):format(i, j))
            end
          end
          -- Scrolled down a wheel-notch at a time, as a player would, the
          -- last choice comes into view (upright, the brief under the card
          -- can be taller than the screen, so "the end" is not the place).
          for _ = 1, 200 do
            if scene.choice_hits[4] then break end
            scene.brief_scroll = scene.brief_scroll + 40
            draw()
          end
          T.ok(scene.choice_hits[4] ~= nil, tag .. ": scrolled down, the fourth choice comes into view")
          T.ok(scene.choice_hits[4] == nil or inside(scene.choice_hits[4], screen), tag .. ": and it is on the canvas")
          -- The hole is in the well beside the four (a program quiz).
          if quest.quiz.program then
            local px, rows = scene:left_fit(400, shape[1] == "landscape" and 500 or nil)
            T.ok(rows >= 3, tag .. ": the program window keeps at least three lines round the hole")
            T.ok(px >= 12, tag .. ": the code never goes under 12 px")
          end
        end
      end
    end)
  end

  T.section("quest card — a wrong pick stays, the right one unlocks")

  T.case("a struck row takes no tap and the heading says what is left", function()
    Layout.font = 2
    at("landscape", 1280, 720)
    app:go("quest", { quest_id = SHEET.id, land = SHEET.land, category = SHEET.category })
    local scene = app.scene
    scene.quest = SHEET
    scene.quiz_right = false
    scene.dealt_id = SHEET.id
    draw()
    scene:pick(3)
    T.eq(scene.wrong_picks[3], true, "the third is struck")
    T.eq(scene.quiz_wrong, 3, "and is the latest miss")
    T.eq(scene:misses(), 1)
    draw()
    T.eq(scene.choice_hits[3], nil, "a struck row takes no tap")
    T.ok(scene.choice_hits[1] ~= nil, "the others still do")
    scene:pick(3)
    T.eq(scene:misses(), 1, "a second press on it is nothing")
    T.ok(scene.not_that_at ~= nil, "the heading says NOT THAT ONE")
    T.eq(scene.running_mode, "quest.submit", "the miss went to the server")
    -- The server answers nothing in this test; the pick is still in flight,
    -- so the second (right) pick waits. Let it go and pick the answer.
    scene.running_mode = nil
    scene:pick(2)
    T.eq(scene.quiz_right, true, "the second is the answer")
    T.ok(scene.fill_at ~= nil, "the hole starts typing")
    draw()
    T.eq(next(scene.choice_hits), nil, "nothing takes a tap once it is right")
  end)

  T.section("result card — on the canvas at every type step and shape")

  T.case("ACCEPTED: the card, its buttons and the stars are on the canvas", function()
    for _, step in ipairs({ 1, 2, 4 }) do
      Layout.font = step
      for _, shape in ipairs({ { "landscape", 1280, 720 }, { "landscape", 1920, 1080 }, { "portrait", 720, 1280 }, { "portrait", 720, 958 } }) do
        at(shape[1], shape[2], shape[3])
        Juice.forget("result:")
        app.land, app.category = "rust", "cheatsheet"
        app:go("result", {
          attempt = { id = "att_0123456789abcdef", quest_id = SHEET.id, verdict = "accepted", cleared = true,
            stars = 2, tests_passed = 1, tests_total = 1, compile_ms = 0, run_ms = 0,
            cases = { { name = "sample", passed = true, visible = true } }, mistakes = {}, stderr = "" },
          xp = { gained = 50, total = 50, level = 1, level_up = false },
          quest = SHEET, source = SHEET.quiz.choices[2],
        })
        local scene = app.scene
        scene.next_id = "rust.cheatsheet.02.x"
        local tag = ("result step %d %s %dx%d"):format(step, shape[1], shape[2], shape[3])
        draw(); draw()
        local screen = { x = 0, y = 0, w = Layout.vw, h = Layout.vh - require("src.ui").footerHeight() }
        T.ok(scene.card ~= nil and inside(scene.card, screen), tag .. ": the card is on the canvas " .. rect_s(scene.card))
        local ids = {}
        for _, b in ipairs(scene.buttons) do
          ids[b.id] = true
          T.ok(inside(b, scene.card, 2), tag .. (": %s is on the card %s"):format(b.id, rect_s(b)))
        end
        T.ok(ids.next and ids.retry and ids.map and ids.details, tag .. ": NEXT, RETRY, MAP and DETAILS are there")
        for i, a in ipairs(scene.buttons) do
          for j = i + 1, #scene.buttons do
            T.ok(disjoint(a, scene.buttons[j]), tag .. (": %s and %s are apart"):format(a.id, scene.buttons[j].id))
          end
        end
        -- The fold opens and the buttons stay on the card.
        scene.details = true
        draw(); draw()
        for _, b in ipairs(scene.buttons) do
          T.ok(inside(b, scene.card, 2), tag .. (": %s is on the card with DETAILS open"):format(b.id))
        end
      end
    end
  end)

  T.case("WRONG ANSWER: RETRY is the primary, and the failing case is shown", function()
    Layout.font = 2
    at("landscape", 1280, 720)
    local Result = require("src.scenes.result")
    local specs = Result.button_specs(false, true)
    T.eq(specs[1].id, "retry")
    T.eq(specs[1].variant, "primary")
    T.eq(specs[2].id, "map")
    T.eq(specs[2].variant, "secondary")
    T.eq(specs[3].id, "next")
    T.eq(specs[3].variant, "ghost")
    local won = Result.button_specs(true, true)
    T.eq(won[1].id, "next")
    T.eq(won[1].variant, "primary", "after a win the next quest is the forward action")
    T.eq(won[2].id, "map")
    T.eq(won[3].variant, "ghost", "RETRY is the ghost after a win")
    T.eq(#Result.button_specs(true, false), 2, "no NEXT on the last node")
    app:go("result", {
      attempt = { id = "att_x", quest_id = SHEET.id, verdict = "wrong_answer", cleared = false,
        stars = 0, tests_passed = 0, tests_total = 1, compile_ms = 12, run_ms = 3,
        cases = { { name = "sample", passed = false, visible = true, expect = "1 2\n", got = "2 1\n" } },
        mistakes = { { kind = "wrong_answer", code = "WA", message = "the pair is printed the wrong way round", line = 3 } },
        stderr = "" },
      xp = { gained = 0 }, quest = SHEET, source = SHEET.quiz.choices[1],
    })
    draw(); draw()
    local scene = app.scene
    T.ok(scene.card ~= nil, "the card is drawn")
    T.ok(scene.buttons[1] ~= nil, "the buttons are drawn")
  end)

  T.section("quest — the editor screen still draws for a quest without a quiz")

  T.case("a program quest with no quiz draws its brief and editor", function()
    Layout.font = 2
    for _, shape in ipairs({ { "landscape", 1280, 720 }, { "portrait", 720, 1280 } }) do
      at(shape[1], shape[2], shape[3])
      app:go("quest", { quest_id = "go.basic.01.x", land = "go", category = "basic" })
      local scene = app.scene
      scene.quest = { id = "go.basic.01.x", land = "go", category = "basic", title = "HELLO", brief = "Print hello.",
        story = "A street.", concepts = { "io" }, hints_total = 1, hints_used = 0, difficulty = 1, state = "open",
        tests = { visible = {}, hidden_count = 1 }, starter = "package main\n" }
      scene.editor:set_text("package main\n")
      local ok, err = pcall(function() draw() end)
      T.ok(ok, shape[1] .. ": " .. tostring(err))
    end
  end)

  Anim.freeze(nil)
  Juice.forget("quest:")
  Juice.forget("result:")
  Layout.font, Layout.mode, Layout.vw, Layout.vh = was_font, was_mode, was_vw, was_vh
  at(was_mode, was_vw, was_vh)
end
