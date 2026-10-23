-- The motion engine, asserted without a window (`src/juice.lua`), and the
-- footer's pure fitting rule (`UI.fitHints`).
--
-- Both are functions of the `dt`s and the widths they are handed, which is
-- what lets a hover be run to rest, a card dealt in, a number counted up and
-- a footer planned under a bare luajit.

local T = require("tests.framework")
local Juice = require("src.juice")
local Anim = require("src.anim")

local function run(seconds, step)
  step = step or 1 / 60
  local t = 0
  while t < seconds do
    Juice.update(step)
    t = t + step
  end
end

return function()
  T.section("juice — the module is pure")

  T.case("juice never touches love", function()
    T.no_love("src/juice.lua")
  end)

  T.section("juice — tweens")

  T.case("a tween lands exactly on its target and fires `after` once", function()
    Juice.clear()
    local obj = { x = 0, y = 10 }
    local landed = 0
    Juice.to(obj, { x = 100, y = 0 }, 0.2, "outExpo", { after = function() landed = landed + 1 end })
    run(0.1)
    T.ok(obj.x > 0 and obj.x < 100, "half way: moving")
    T.ok(obj.x > 50, "ease-out: more than half the distance in half the time")
    run(0.3)
    T.eq(obj.x, 100)
    T.eq(obj.y, 0)
    T.eq(landed, 1, "after fired once")
    T.eq((Juice.active()), 0, "and the tween is gone")
  end)

  T.case("a second tween on the same field replaces the first", function()
    Juice.clear()
    local obj = { x = 0 }
    Juice.to(obj, { x = 100 }, 0.5)
    run(0.1)
    Juice.to(obj, { x = 0 }, 0.1)
    run(0.3)
    T.eq(obj.x, 0, "the reversal won; the old tween did not drag it back")
  end)

  T.case("a delay holds it and :chain strings them", function()
    Juice.clear()
    local obj = { x = 0 }
    local order = {}
    Juice.to(obj, { x = 10 }, 0.1, "linear", { delay = 0.1, after = function() order[#order + 1] = "a" end })
      :chain({ x = 20 }, 0.1, "linear"):after(function() order[#order + 1] = "b" end)
    -- Counted in frames, not seconds: twelve sixtieths is 0.2 s exactly,
    -- where a float sum of 1/60s may or may not be.
    local function frames(n) for _ = 1, n do Juice.update(1 / 60) end end
    frames(3)
    T.eq(obj.x, 0, "held by the delay")
    frames(6)
    T.ok(obj.x > 0 and obj.x < 10, "the first leg is under way")
    frames(3)
    T.near(obj.x, 10, 0.5, "the first leg lands at 0.2 s and the chained one has only just begun")
    frames(12)
    T.near(obj.x, 20, 1e-6)
    T.same(order, { "a", "b" })
  end)

  T.case("every named curve starts at 0 and ends at 1", function()
    for name, fn in pairs(Juice.ease) do
      T.near(fn(0), 0, 1e-9, name .. " at 0")
      T.near(fn(1), 1, 1e-9, name .. " at 1")
    end
    T.ok(Juice.ease.outBack(0.6) > 1, "outBack overshoots")
    T.ok(Juice.ease.outExpo(0.5) > 0.9, "outExpo is nearly there at half time")
  end)

  T.section("juice — springs")

  T.case("a critically damped spring settles on its target without crossing it", function()
    Juice.clear()
    local obj = { y = 0 }
    Juice.spring(obj, "y", 50)
    local max = 0
    for _ = 1, 120 do
      Juice.update(1 / 60)
      max = math.max(max, obj.y)
    end
    T.eq(obj.y, 50)
    T.ok(max <= 50 + 1e-6, "never overshoots when critically damped")
  end)

  T.case("an underdamped spring overshoots and still settles", function()
    Juice.clear()
    local obj = { y = 0 }
    Juice.spring(obj, "y", 50, { k = 300, d = 8 })
    local max = 0
    for _ = 1, 240 do
      Juice.update(1 / 60)
      max = math.max(max, obj.y)
    end
    T.ok(max > 50, "it went past")
    T.eq(obj.y, 50, "and came to rest")
  end)

  T.section("juice — keyed, immediate-mode state")

  T.case("follow starts on its target and then eases toward a new one", function()
    Juice.clear()
    T.eq(Juice.follow("btn:A", 0), 0)
    run(0.05)
    local mid = Juice.follow("btn:A", 1)
    T.eq(mid, 0, "the frame it is asked, it has not moved yet")
    run(0.05)
    local later = Juice.follow("btn:A", 1)
    T.ok(later > 0 and later < 1, "on its way")
    run(0.6)
    T.eq(Juice.follow("btn:A", 1), 1, "at rest on the target")
  end)

  T.case("enter runs 0 → 1 once, honours its delay, and can be forgotten", function()
    Juice.clear()
    T.eq(Juice.enter("lands:card1", { dur = 0.2 }), 0)
    T.eq(Juice.enter("lands:card2", { dur = 0.2, delay = 0.1 }), 0)
    run(0.1)
    local a, b = Juice.enter("lands:card1"), Juice.enter("lands:card2")
    T.ok(a > 0, "the first is moving")
    T.ok(b <= a, "the delayed one is behind it")
    run(0.4)
    T.eq(Juice.enter("lands:card1"), 1)
    T.eq(Juice.enter("lands:card2"), 1)
    T.ok(Juice.entered("lands:card2"))
    Juice.forget("lands:")
    T.eq(Juice.enter("lands:card1", { dur = 0.2 }), 0, "forgotten, so it deals in again")
  end)

  T.case("a counter shows the first value at once and counts to the next", function()
    Juice.clear()
    local shown, moving = Juice.counter("xp", 0)
    T.eq(shown, 0)
    T.nope(moving)
    run(0.02)
    shown, moving = Juice.counter("xp", 450, { dur = 0.6 })
    T.eq(shown, 0, "it starts where it was")
    T.ok(moving)
    run(0.3)
    shown = Juice.counter("xp", 450)
    T.ok(shown > 0 and shown < 450, "half way through, part of the way there: " .. shown)
    T.ok(shown > 225, "and fast first")
    run(0.5)
    shown, moving = Juice.counter("xp", 450)
    T.eq(shown, 450)
    T.nope(moving)
    T.eq(Juice.count(0, 100, 1), 100)
    T.eq(Juice.count(0, 100, 0), 0)
  end)

  T.case("trigger / since / pressed are a moment and its push", function()
    Juice.clear()
    T.eq(Juice.since("press:go"), nil)
    T.eq(Juice.pressed("press:go"), 0)
    Juice.trigger("press:go")
    T.eq(Juice.since("press:go"), 0)
    run(0.03)
    T.ok(Juice.pressed("press:go") > 0, "pushed in")
    run(0.3)
    T.eq(Juice.pressed("press:go"), 0, "and back")
  end)

  T.case("tilt is stable per key and scales with the amount", function()
    T.eq(Juice.tilt("RUN", 0), 0)
    local a = Juice.tilt("RUN", 1)
    T.ok(math.abs(a) == 2, "±2° at full")
    T.eq(Juice.tilt("RUN", 1), a, "the same way every time")
    T.near(Juice.tilt("RUN", 0.5), a / 2, 1e-9)
    T.near(Juice.scale(1), 1.05, 1e-9)
    T.near(Juice.scale(0), 1, 1e-9)
    T.near(Juice.stagger(3, 0.04), 0.08, 1e-9)
  end)

  T.section("juice — a pinned clock pins the motion")

  T.case("under Anim.freeze everything lands at once", function()
    Juice.clear()
    local obj = { x = 0 }
    Juice.to(obj, { x = 100 }, 10)
    Juice.spring(obj, "s", 5)
    Juice.follow("hover", 0)
    Juice.counter("n", 0)
    Juice.enter("card", { dur = 10 })
    Anim.freeze(1)
    T.eq(Juice.follow("hover", 1), 1, "a frozen follow answers its target")
    T.eq(Juice.enter("card"), 1, "a frozen entrance is complete")
    T.eq((Juice.counter("n", 99)), 99, "a frozen counter shows the value")
    Juice.update(0.016)
    T.eq(obj.x, 100, "the tween landed")
    T.eq(obj.s, 5, "the spring landed")
    Anim.freeze(nil)
    Juice.clear()
  end)

  T.section("toasts — a slip with an id is replaced, not stacked")

  T.case("four presses of a setting key leave one slip with the latest text", function()
    local UI = require("src.ui")
    UI.clearToasts()
    UI.pushToast("type size 1/4", { id = "type-size" })
    UI.pushToast("type size 2/4", { id = "type-size" })
    UI.pushToast("sound off", { id = "sound" })
    UI.pushToast("type size 3/4", { id = "type-size" })
    local list = UI.toasts()
    T.eq(#list, 2, "one per id")
    T.eq(list[1].text, "sound off", "the replaced slip gives up its place in the stack")
    T.eq(list[2].text, "type size 3/4")
    -- Slips without an id still stack (up to the dock's cap).
    UI.clearToasts()
    UI.pushToast("saved")
    UI.pushToast("saved")
    T.eq(#UI.toasts(), math.min(2, UI.TOAST_MAX))
    UI.clearToasts()
  end)

  T.section("footer — the hints that fit, in priority order")

  T.case("fitHints keeps the longest prefix that fits, never a later one", function()
    local UI = require("src.ui")
    -- A ruler: every character is 8 px, as Neo둥근모 at 16 is.
    local measure = function(s) return #s * 8 end
    local items = UI.parseHint("1-4 pick   F7 hint   ESC map   T stats")
    T.eq(#items, 4)
    T.eq(items[1].key, "1-4"); T.eq(items[1].verb, "pick")
    T.eq(items[4].key, "T"); T.eq(items[4].verb, "stats")
    local function keys(list)
      local out = {}
      for i, it in ipairs(list) do out[i] = it.key end
      return out
    end
    T.same(keys(UI.fitHints(items, 10000, 4, measure)), { "1-4", "F7", "ESC", "T" }, "all four in a wide footer")
    T.same(keys(UI.fitHints(items, 10000, 2, measure)), { "1-4", "F7" }, "the cap holds the count down")
    local one = UI.hintWidth({ items[1] }, measure)
    local two = UI.hintWidth({ items[1], items[2] }, measure)
    T.same(keys(UI.fitHints(items, two, 4, measure)), { "1-4", "F7" }, "exactly two fit")
    T.same(keys(UI.fitHints(items, two - 1, 4, measure)), { "1-4" }, "a pixel short drops the second, not the first")
    T.same(keys(UI.fitHints(items, one - 1, 4, measure)), {}, "no room: nothing, and nothing from later")
    -- The drop order: the last hint goes first, the first survives longest.
    local widths = { UI.hintWidth(items, measure) }
    for n = 3, 1, -1 do
      local kept = {}
      for i = 1, n do kept[i] = items[i] end
      widths[#widths + 1] = UI.hintWidth(kept, measure)
    end
    for i = 2, #widths do
      T.ok(widths[i] < widths[i - 1], "each dropped hint frees room")
    end
  end)

  T.case("parseHint survives odd spacing and a translated key", function()
    local UI = require("src.ui")
    local items = UI.parseHint("  방향키 선택   ENTER 이동  ")
    T.eq(#items, 2)
    T.eq(items[1].key, "방향키"); T.eq(items[1].verb, "선택")
    T.eq(items[2].key, "ENTER"); T.eq(items[2].verb, "이동")
    T.eq(#UI.parseHint(""), 0)
    T.eq(#UI.parseHint(nil), 0)
    local lone = UI.parseHint("ESC")
    T.eq(lone[1].key, "ESC"); T.eq(lone[1].verb, "")
  end)

  T.case("the footer is one line: the strip formula has no second row", function()
    local UI = require("src.ui")
    T.eq(UI.hint_rows, 1)
    T.eq(UI.controlRow(), 0, "the display controls moved into the settings sheet")
    local fh = io.open("src/ui.lua", "r")
    if fh then
      local body = fh:read("*a")
      fh:close()
      T.ok(body:find("UI.footerRow() * UI.hint_rows + UI.controlRow()", 1, true) ~= nil)
      T.nope(body:find("UI.wrap(text, beside, UI.FOOTER_SIZE)", 1, true), "no wrapped hint rows")
    end
  end)

  T.case("the XP bar fraction follows the triangular curve", function()
    local App = require("src.app")
    T.near(App.xp_fraction({ xp = 0, level = 1 }), 0, 1e-9)
    T.near(App.xp_fraction({ xp = 50, level = 1 }), 0.5, 1e-9, "level 1 spans 100")
    T.near(App.xp_fraction({ xp = 100, level = 2 }), 0, 1e-9, "level 2 starts at 100")
    T.near(App.xp_fraction({ xp = 200, level = 2 }), 0.5, 1e-9, "and spans 200")
    T.near(App.xp_fraction({ xp = 999, level = 3, xp_into_level = 150 }), 0.5, 1e-9, "the server's own number wins")
    T.eq(App.xp_fraction(nil), 0)
    T.eq(App.xp_fraction({ name = "mei" }), 0, "no xp, no bar")
  end)
end
