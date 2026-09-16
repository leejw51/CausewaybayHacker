-- The typing effects, the half of them that is arithmetic.
--
-- `src/codefx.lua` paints; these are the decisions it paints from. Two things
-- are pinned. The plans (`src/fxplan.lua`): every gesture throws *something*,
-- scaled to the type size, in the palette's colours and in shapes the painter
-- knows, and a particle's position is a closed-form function of its age. And
-- the editor's reading of a keystroke (`src/editor.lua` "events"): what it
-- reports, which colour a character is, when a bracket closes itself, and —
-- the one that matters most — when a loop counts as finished, per land,
-- because a celebration that fires on every brace is noise and one that never
-- fires is a feature nobody finds.

local T = require("tests.framework")
local Plan = require("src.fxplan")
local editor = require("src.editor")
local Theme = require("src.theme")

--- A generator that is the same every run, so a plan is a fixed picture.
local function seeded(seed)
  local r = seed or 7
  return function()
    r = (r * 1103515245 + 12345) % 2147483648
    return r / 2147483648
  end
end

local CELL = { 10, 22 }

local function finite(plan)
  for _, p in ipairs(plan.particles) do
    for _, k in ipairs({ "x", "y", "dx", "dy", "tox", "toy", "liftx", "lifty", "life", "size" }) do
      local v = p[k]
      T.ok(type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge, k .. " is finite")
    end
    T.ok(p.life > 0, "a particle lives")
    T.ok(p.size > 0, "a particle has a size")
    T.ok(p.delay >= 0, "no negative delay")
    T.ok(({ [0] = 1, [1] = 1, [2] = 1, [4] = 1, [5] = 1, [6] = 1 })[p.shape], "a shape the painter knows")
  end
  for _, r in ipairs(plan.rings) do
    T.ok(r.radius > 0 and r.life > 0, "a ring has size and life")
  end
end

local function count(plan, shape)
  local n = 0
  for _, p in ipairs(plan.particles) do
    if p.shape == shape then
      n = n + 1
    end
  end
  return n
end

--- Type a string as a person would.
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

--- An editor with `text` typed in and every event it reported.
local function typed(text, opts)
  opts = opts or {}
  local ed = editor.new({
    now = function()
      return 0
    end,
    lang = opts.lang,
    auto_close = opts.auto_close,
  })
  local events = {}
  ed.on_event = function(ev)
    events[#events + 1] = ev
  end
  type_text(ed, text)
  return ed, events
end

local function kinds(events)
  local out = {}
  for _, ev in ipairs(events) do
    out[#out + 1] = ev.kind
  end
  return table.concat(out, " ")
end

local function loops(events)
  local out = {}
  for _, ev in ipairs(events) do
    if ev.kind == "loop" then
      out[#out + 1] = ev
    end
  end
  return out
end

return function()
  T.section("fxplan — the motion")

  T.case("a particle is where its age says, and nowhere before or after", function()
    local p =
      { x = 10, y = 20, dx = 100, dy = 0, tox = 0, toy = 0, liftx = 0, lifty = 0, life = 1, gravity = 0 }
    T.nope(Plan.at(p, -0.1), "not born yet")
    T.nope(Plan.at(p, 1.1), "dead")
    local x, y, t = Plan.at(p, 0)
    T.near(x, 10, 1e-9)
    T.near(y, 20, 1e-9)
    T.near(t, 0, 1e-9)
    x = Plan.at(p, 1)
    T.near(x, 110, 1e-6, "the throw eases out to its full reach")
    -- Most of the reach is covered early: the shape of a thing thrown hard.
    x = Plan.at(p, 0.3)
    T.ok(x > 10 + 100 * 0.85, "ease-out: most of the way by a third of the life")
    -- Gravity adds half g t squared and nothing else.
    p.gravity = 100
    local _, y1 = Plan.at(p, 1)
    T.near(y1, 20 + 50, 1e-6)
  end)

  T.case("alpha pops up, holds, and fades away", function()
    local p = {}
    T.near(Plan.alpha(p, 0), 0, 1e-9)
    T.near(Plan.alpha(p, 0.1), 1, 1e-9)
    T.near(Plan.alpha(p, 0.5), 1, 1e-9)
    T.ok(Plan.alpha(p, 0.8) < 1 and Plan.alpha(p, 0.8) > 0, "fading")
    T.near(Plan.alpha(p, 1), 0, 1e-9)
  end)

  T.section("fxplan — the plans")

  T.case("a keystroke throws sparks in the token's colour, and a paste throws more", function()
    local one = Plan.key(100, 100, CELL, Theme.grass, 1, seeded())
    local many = Plan.key(100, 100, CELL, Theme.grass, 40, seeded())
    finite(one)
    T.ok(#one.particles > 0)
    T.ok(#many.particles > #one.particles, "a paste is a bigger pop")
    local green = 0
    for _, p in ipairs(one.particles) do
      if p.color == Theme.grass then
        green = green + 1
      end
    end
    T.ok(green > #one.particles / 2, "mostly the token's colour")
    T.eq(#one.rings, 1)
    T.ok(one.rings[1].glow)
  end)

  T.case("a keystroke's reach scales with the type size", function()
    local function reach(plan)
      local best = 0
      for _, p in ipairs(plan.particles) do
        best = math.max(best, math.sqrt(p.dx * p.dx + p.dy * p.dy))
      end
      return best
    end
    local small = Plan.key(0, 0, { 6, 12 }, Theme.cream, 1, seeded())
    local big = Plan.key(0, 0, { 12, 24 }, Theme.cream, 1, seeded())
    T.near(reach(big), reach(small) * 2, 1e-6)
  end)

  T.case("ENTER is dust: puffs that rise, mostly along the new line", function()
    local plan = Plan.dust(50, 200, CELL, seeded())
    finite(plan)
    local puffs, right = 0, 0
    for _, p in ipairs(plan.particles) do
      if p.shape == 5 then
        puffs = puffs + 1
        T.ok(p.gravity < 0 and p.dy < 0, "dust rises")
        if p.dx > 0 then
          right = right + 1
        end
      end
    end
    T.ok(puffs >= 9)
    T.ok(right > puffs / 2, "mostly to the right — where the line is")
  end)

  T.case("deleted characters break into bricks, each in its own colour, left to right", function()
    local one = Plan.rubble({ { x = 300, y = 120, color = Theme.pink } }, CELL, seeded())
    finite(one)
    T.eq(count(one, 4), 3)
    for _, b in ipairs(one.particles) do
      if b.shape == 4 then
        T.ok(b.gravity > 500 and not b.trail)
        T.ok(b.color[1] > b.color[2], "a shade of pink")
        T.ok(b.x >= 300 and b.x <= 310, "thrown from its own cell")
      end
    end
    local cells = {}
    for i = 1, 12 do
      cells[i] = { x = 100 + (i - 1) * CELL[1], y = 50, color = i <= 3 and Theme.pink or Theme.grass }
    end
    local line = Plan.rubble(cells, CELL, seeded())
    finite(line)
    T.eq(count(line, 4), 36)
    local bricks = {}
    for _, p in ipairs(line.particles) do
      if p.shape == 4 then
        bricks[#bricks + 1] = p
      end
    end
    T.ok(bricks[#bricks].delay > bricks[1].delay, "the last cell goes after the first")
    T.ok(bricks[1].color[1] > bricks[1].color[2], "pink where the keyword was")
    T.ok(bricks[#bricks].color[2] > bricks[#bricks].color[1], "green where the string was")
    T.eq(#line.rings, 1)
  end)

  T.case("a landslide is capped", function()
    local many = {}
    for i = 1, 1000 do
      many[i] = { x = i * 10, y = 0, color = Theme.cream }
    end
    local plan = Plan.rubble(many, CELL, seeded())
    T.eq(count(plan, 4), Plan.RUBBLE_MAX * 2)
    T.eq(#Plan.rubble({}, CELL, seeded()).particles, 0)
  end)

  T.case("the pointer's trail is one ember on the path, drifting against the motion", function()
    local plan = Plan.trail(100, 100, 800, 0, 0.1, seeded())
    finite(plan)
    T.eq(#plan.particles, 1)
    local p = plan.particles[1]
    T.eq(p.x, 100)
    T.eq(p.y, 100)
    T.ok(p.dx < 0, "against the motion")
    T.near(p.dy, 0, 1e-9)
    T.eq(p.gravity, 0)
    T.eq(p.shape, 6)
    local still = Plan.trail(100, 100, 0, 0, 0, seeded())
    T.near(still.particles[1].dx, 0, 1e-9, "a still pointer's mote goes nowhere")
  end)

  T.case("the ribbon's colour moves smoothly round its cycle and comes back", function()
    local c0, c1 = Plan.ribbon(0), Plan.ribbon(1)
    for i = 1, 3 do
      T.near(c0[i], Theme.cyan[i], 1e-9)
      T.near(c1[i], c0[i], 1e-9)
    end
    local mid = Plan.ribbon(0.125)
    for i = 1, 3 do
      T.near(mid[i], (Theme.cyan[i] + Theme.pink[i]) / 2, 1e-6)
    end
    local a, b = Plan.ribbon(0.3), Plan.ribbon(0.31)
    for i = 1, 3 do
      T.ok(math.abs(a[i] - b[i]) < 0.05, "neighbours are neighbours in colour")
    end
  end)

  T.case("a bracket link runs from one bracket to the other and lights both", function()
    local plan = Plan.link({ 100, 100 }, { 300, 160 }, CELL, seeded())
    finite(plan)
    for _, p in ipairs(plan.particles) do
      T.eq(p.tox, 200)
      T.eq(p.toy, 60)
      T.eq(p.color, Theme.cyan)
    end
    T.eq(#plan.rings, 2)
    T.eq(plan.rings[1].x, 100)
    T.eq(plan.rings[2].x, 300)
  end)

  T.case("a closed loop runs stars up one side and down the other, then bursts", function()
    local plan = Plan.loop({ 200, 100 }, { 220, 300 }, CELL, seeded())
    finite(plan)
    local up, down, finale = 0, 0, 0
    local up_lift, down_lift
    for _, p in ipairs(plan.particles) do
      if p.shape == 1 and p.gravity == 0 then
        if p.toy < 0 then
          up = up + 1
          up_lift = up_lift or p.liftx
        end
        if p.toy > 0 then
          down = down + 1
          down_lift = down_lift or p.liftx
        end
      end
      if p.shape == 2 then
        finale = finale + 1
        T.ok(p.delay >= 1.35, "the finale comes after both legs")
      end
    end
    T.eq(up, 12)
    T.eq(down, 12)
    T.ok((up_lift > 0) ~= (down_lift > 0), "opposite sides: a loop, not a there-and-back")
    T.ok(finale > 0)
  end)

  T.case("a burst is the browser's: sparks, gold stars, paper, a flash and a wave", function()
    local plan = Plan.burst(0, 0, 36, seeded())
    finite(plan)
    T.eq(count(plan, 0), 36)
    T.eq(count(plan, 1), 12)
    T.eq(count(plan, 2), 18)
    T.eq(#plan.rings, 2)
  end)

  T.section("editor events — what a keystroke was")

  T.case("typing reports each character with its tone, ENTER as enter", function()
    local _, events = typed("fn main() {\n", { lang = "rust" })
    T.eq(events[1].kind, "type")
    T.eq(events[1].text, "f")
    -- `fn` is a keyword once both letters are down.
    T.eq(events[2].tone, "keyword")
    T.eq(events[4].tone, "text", "`m` of main is a name")
    T.eq(events[8].tone, "bracket", "`(`")
    T.eq(events[#events].kind, "enter")
    T.eq(events[#events].line, 2, "the caret is on the new line")
  end)

  T.case("a string types green and a number gold", function()
    local _, events = typed('let s = "hi"; let n = 42;', { lang = "rust" })
    local tones = {}
    for _, ev in ipairs(events) do
      tones[#tones + 1] = ev.tone
    end
    T.eq(tones[11], "string", "inside the quotes")
    T.eq(tones[#tones - 1], "number", "the 2 of 42")
  end)

  T.case("backspace and delete report what went, with its tone", function()
    local ed, events = typed("abc", {})
    ed:keypressed("backspace", {})
    T.eq(events[#events].kind, "erase")
    T.eq(events[#events].text, "c")
    T.eq(events[#events].col, 3)
    ed:move("home", {})
    ed:keypressed("delete", {})
    T.eq(events[#events].text, "a")
    T.eq(events[#events].col, 1)
    T.eq(ed:text(), "b")
  end)

  T.case("a selection deleted is one erase, one tone per byte, from where it started", function()
    local ed, events = typed('x = "hi" + 4', {})
    ed:select_all()
    ed:keypressed("backspace", {})
    local ev = events[#events]
    T.eq(ev.kind, "erase")
    T.eq(ev.text, 'x = "hi" + 4')
    T.eq(ev.line, 1)
    T.eq(ev.col, 1)
    T.eq(#ev.tones, #ev.text)
    T.eq(ev.tones[6], "string")
    T.eq(ev.tones[#ev.tones], "number")
  end)

  T.case("programmatic edits say nothing", function()
    local ed, events = typed("", {})
    ed:set_text("fn main() {}")
    ed:insert("more")
    ed:replace_all("other")
    T.eq(#events, 0, "FORMAT is not a wall of bricks")
  end)

  T.section("editor — brackets that close themselves")

  T.case("off by default: what you type is what you get", function()
    local ed = typed("f(x", {})
    T.eq(ed:text(), "f(x")
  end)

  T.case("on: an opener brings its closer, typing the closer steps over it", function()
    local ed = typed("f(x)", { auto_close = true })
    T.eq(ed:text(), "f(x)")
    T.eq(ed.col, 5, "the caret is past the closer, not before a second one")
    ed = typed('s = "hi"', { auto_close = true })
    T.eq(ed:text(), 's = "hi"')
  end)

  T.case("on: `{` ENTER opens the block with the brace below", function()
    local ed = typed("fn main() {\nx", { auto_close = true })
    T.eq(ed:text(), "fn main() {\n    x\n}")
  end)

  T.case("on: an opener pressed against a word is the person's own", function()
    local ed = typed("ab", { auto_close = true })
    ed:move("home", {})
    ed:textinput("(")
    T.eq(ed:text(), "(ab", "no closer wedged into the word")
    ed = typed("it", { auto_close = true })
    ed:textinput('"')
    T.eq(ed:text(), 'it"', "a quote after a letter is not a string opening")
  end)

  T.case("on: backspace inside a fresh pair takes both halves", function()
    local ed = typed("(", { auto_close = true })
    T.eq(ed:text(), "()")
    ed:keypressed("backspace", {})
    T.eq(ed:text(), "")
  end)

  T.section("editor — when a loop counts as finished")

  T.case("rust: the brace that closes a for, while or loop — and not a fn or an if", function()
    -- Typed the way a person types it: the editor indents after `{` itself.
    local ed, events = typed('fn main() {\nfor i in 0..3 {\nprintln!("{i}");\n', { lang = "rust" })
    ed:keypressed("backspace", {})
    ed:textinput("}")
    T.eq(ed:text(), 'fn main() {\n    for i in 0..3 {\n        println!("{i}");\n    }')
    local found = loops(events)
    T.eq(#found, 1, "one loop closed")
    T.eq(found[1].open[1], 2)
    T.eq(found[1].open[2], 5, "the `for`")
    T.eq(found[1].close[1], 4, "the `}` on line 4")
    _, events =
      typed("fn main() {\nwhile x { y; }\nloop { break; }\n'a: loop { break 'a; }\n}", { lang = "rust" })
    T.eq(#loops(events), 3, "while, loop, and a labelled loop")
    _, events = typed("fn main() {\nif x { y; }\n}", { lang = "rust" })
    T.eq(#loops(events), 0)
  end)

  T.case("a brace inside a string is a character, not a closer", function()
    local _, events = typed('fn main() {\nfor i in 0..3 {\nprintln!("{i}")', { lang = "rust" })
    T.eq(#loops(events), 0, "the `}` in `{i}` closed nothing")
  end)

  T.case("go: for; cpp: for, while, range-for on their brace and do-while on its semicolon", function()
    local _, events = typed("func main() {\nfor i := 0; i < 3; i++ {\nprintln(i)\n}\n}", { lang = "go" })
    T.eq(#loops(events), 1)
    _, events = typed(
      "int main() {\nfor (int i = 0; i < 3; i++) { x++; }\nwhile (x) { x--; }\nfor (auto v : xs) { }\n}",
      { lang = "cpp" }
    )
    T.eq(#loops(events), 3)
    _, events = typed("int main() {\ndo { x++; } while (x < 3);\n}", { lang = "cpp" })
    local found = loops(events)
    T.eq(#found, 1, "do-while, on its semicolon")
    T.eq(found and found[1] and found[1].open[1], 2)
    _, events = typed("int main() {\ndo {\nx++;\n} while (x < 3);\n}", { lang = "cpp" })
    T.eq(#loops(events), 1, "and across three lines")
    _, events = typed("int main() {\nint x = 1;\n}", { lang = "cpp" })
    T.eq(#loops(events), 0, "a plain semicolon is not a loop")
  end)

  T.case("python: ENTER at the end of the first body line, and only that line", function()
    local _, events = typed("for i in range(3):\n", { lang = "python" })
    T.eq(#loops(events), 0, "no body yet")
    local ed
    ed, events = typed("for i in range(3):\n    print(i)\n", { lang = "python" })
    local found = loops(events)
    T.eq(#found, 1)
    T.eq(found[1].open[1], 1)
    T.eq(found[1].open[2], 1)
    T.eq(found[1].close[1], 2)
    type_text(ed, "    print(i * 2)\n")
    T.eq(#loops(events), 1, "the second body line is not a second celebration")
    _, events = typed("while x:\n    x -= 1\n", { lang = "python" })
    T.eq(#loops(events), 1)
    -- A brace language's rules do not apply to Python's braces.
    _, events = typed("d = {\n    1: 2}", { lang = "python" })
    T.eq(#loops(events), 0)
  end)
end
