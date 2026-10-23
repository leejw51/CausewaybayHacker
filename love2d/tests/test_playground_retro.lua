-- The playground's old computers, its switches and its toolbar filter.
--
-- Headless: `src/computer.lua` is tables, the tube's clock is arithmetic, and
-- the filter is string matching, so all three are checked without a window.
-- What they look like is `tests/drive/computer.lua`'s job.

local T = require("tests.framework")

return function()
  local Computer = require("src.computer")
  local Retro = require("src.retroscreen")
  local Playground = require("src.scenes.playground")
  local Theme = require("src.theme")

  T.section("playground — the old computers")

  T.case("retro compile failures show actual compiler output on every machine", function()
    for _, machine in ipairs({ "msx", "apple2", "amiga" }) do
      T.same(Computer.says(machine, "compile_error", { stderr = "error: unknown foo\nmain.rs:3:5\n" }),
        { "error: unknown foo", "main.rs:3:5" })
      T.same(Computer.says(machine, "compile_error", { stderr = "error: missing semicolon" }),
        { "error: missing semicolon" })
      T.same(Computer.says(machine, "compile_error", { stderr = "", diagnostics = {
        { kind = "error", code = "E0425", message = "cannot find foo", line = 3, col = 5 },
      } }), { "error E0425 (3:5): cannot find foo" })
      T.same(Computer.says(machine, "compile_error", { stderr = "" }),
        { "Compilation failed (no compiler message returned)." })
    end
  end)

  T.case("the COMPUTER button walks NORMAL, APPLE ][, MSX, AMIGA and round", function()
    local was = Computer.get()
    Computer.set("normal")
    local seen = {}
    for _ = 1, 4 do
      local n = Computer.next()
      Computer.set(n)
      seen[#seen + 1] = n
    end
    T.same(seen, { "apple2", "msx", "amiga", "normal" })
    T.nope(Computer.set("c64"), "a machine with no palette is refused")
    T.eq(Computer.get(), "normal")
    Computer.set(was)
  end)

  T.case("every machine paints every kind of code and every part of the pane", function()
    for _, machine in ipairs(Computer.COMPUTERS) do
      if machine ~= "normal" then
        local p = Computer.PALETTE[machine]
        T.ok(p ~= nil, machine .. " has a palette")
        for kind in pairs(Theme.code) do
          T.ok(p.code[kind] ~= nil, machine .. " colours " .. kind)
        end
        for part in pairs(Theme.pane) do
          T.ok(p.pane[part] ~= nil, machine .. " has a pane " .. part)
        end
        T.ok(p.pane.paper ~= nil, machine .. " brings its own paper")
        T.ok(Computer.TUBE[machine] and Computer.CASING[machine] and Computer.NAME[machine],
          machine .. " has a tube, a casing and a name")
        for _, outcome in ipairs({ "compile_error", "runtime_error", "timeout", "output_limit" }) do
          local said = Computer.says(machine, outcome)
          T.ok(type(said) == "table" and #said >= 1, machine .. " has words for " .. outcome)
        end
        T.eq(Computer.says(machine, "ok"), nil, machine .. " says nothing about a run that went fine")
      end
    end
    T.eq(Computer.says("normal", "compile_error"), nil)
  end)

  T.case("a machine never writes into the theme the quest screen reads", function()
    local was = Computer.get()
    local code, pane = Theme.code, Theme.pane
    Computer.set("amiga")
    local c, p = Playground.palette()
    T.ok(c ~= Theme.code and p ~= Theme.pane, "the machine's own tables")
    T.ok(Theme.code == code and Theme.pane == pane, "the theme's untouched")
    Computer.set("normal")
    c, p = Playground.palette()
    T.ok(c == Theme.code and p == Theme.pane, "NORMAL is the theme again")
    Computer.set(was)
  end)

  T.case("the room is the machine's own, upright or not, and the usual on NORMAL", function()
    T.eq(Computer.room("normal", false), nil)
    local tall, wide = Computer.room("msx", true)
    T.eq(tall, "bg_playground_msx_p")
    T.eq(wide, "bg_playground_msx")
    T.eq((Computer.room("amiga", false)), "bg_playground_amiga")
  end)

  T.case("the tube warms, boots, reveals, holds an error and cools", function()
    local r = Retro.new()
    r:power("apple2", true)
    T.eq(r.phase, "warming")
    local power = r:levels()
    T.ok(power < 0.01, "it starts as a line")
    r:update(Retro.WARM + 0.01)
    T.eq(r.phase, "booting", "a picked machine plays its banner")
    r:update(Retro.BOOTS.apple2.secs + 0.01)
    T.eq(r.phase, "revealing")
    r:update(Retro.REVEAL + 0.01)
    T.eq(r.phase, "on")
    local _, screen = r:levels()
    T.eq(screen, 0, "settled, the code shows through")
    r:say(Computer.says("apple2", "compile_error"))
    r:update(0.5)
    _, screen = r:levels()
    T.ok(screen > 0.9, "an error is up over the code")
    r:update(Retro.ALERT_SECS)
    T.eq(r.alert, nil, "and gone after its few seconds")
    r:power("normal", true)
    T.eq(r.phase, "cooling")
    r:update(Retro.COOL + 0.01)
    T.eq(r.phase, "off")
    T.eq(r.machine, nil)
    -- Arriving with a machine already picked skips the banner.
    local again = Retro.new()
    again:power("msx", false)
    again:update(Retro.WARM + 0.01)
    T.eq(again.phase, "revealing")
  end)

  T.section("playground — AUTO-RUN, STDERR and the toolbar filter")

  T.case("AUTO-RUN is on and STDERR off until somebody says otherwise", function()
    -- The browser's defaults: `autoRun = pref !== "off"`, `showStderr = pref === "on"`.
    T.eq(Playground.PREFS.auto_run, true)
    T.eq(Playground.PREFS.stderr, false)
  end)

  T.case("ENTER with AUTO-RUN runs, and an ENTER mid-run queues exactly one more", function()
    local was = Playground.PREFS.auto_run
    Playground.PREFS.auto_run = true
    local runs = 0
    local scene = setmetatable({ running = false }, { __index = Playground })
    scene.run = function(self) runs = runs + 1; self.running = true end
    scene:auto_enter()
    T.eq(runs, 1)
    scene:auto_enter()
    scene:auto_enter()
    T.eq(runs, 1, "a run already out is not interrupted")
    T.eq(scene.run_again, true)
    scene.running = false
    scene:drain_run_again()
    T.eq(runs, 2, "one more, for the code as it is by then")
    scene:drain_run_again()
    T.eq(runs, 2)
    Playground.PREFS.auto_run = false
    scene.running = false
    scene:auto_enter()
    T.eq(runs, 2, "off means ENTER is only a newline")
    Playground.PREFS.auto_run = was
  end)

  T.case("the filter keeps by label, id, concept, initials and abbreviation", function()
    local keeps = Playground.filter_keeps
    local copy = { id = "copycode", label = "COPY CODE" }
    local fontup = { id = "fontup", label = "A+" }
    local run = { id = "run", label = "RUN  F5" }
    local auto = { id = "autorun", label = "AUTO-RUN ON" }
    local computer = { id = "computer", label = "AMIGA" }
    T.ok(keeps("", copy), "nothing typed keeps everything")
    T.ok(keeps("copy", copy))
    T.nope(keeps("copy", run))
    T.ok(keeps("run copy", copy) and keeps("run copy", run), "words are OR'd")
    T.ok(keeps("font", fontup), "a concept keeps A+")
    T.ok(keeps("글꼴", fontup), "in Korean too")
    T.ok(keeps("복사", copy), "복사 is copy")
    T.ok(keeps("ㅂㅅ", { id = "copycode", label = "코드 복사" }), "Hangul initials")
    T.ok(keeps("cpcd", copy), "an abbreviation of the id")
    T.ok(keeps("run", auto), "run keeps AUTO-RUN")
    T.nope(keeps("-font", fontup), "a leading - hides")
    T.ok(keeps("-font", copy), "and only - words start from everything")
    T.ok(keeps("retro", computer), "the old computers have a word")
    T.ok(keeps("RUN", run), "case does not matter")
  end)

  T.case("output wraps to the pane, at spaces and through a path", function()
    local measure = function(s) return #s end
    T.same(Playground.wrap_mono("one two three", 7, measure), { "one two", "three" })
    T.same(Playground.wrap_mono("abcdefghij", 4, measure), { "abcd", "efgh", "ij" })
    T.same(Playground.wrap_mono("", 4, measure), { "" })
  end)

  -- A scene with a real editor and a session that keeps each request's
  -- callback, so a run can be answered when the test says so.
  local function bench()
    local Editor = require("src.editor")
    local sent = {}
    local app = {
      session = {
        request = function(_, type_name, payload, cb)
          sent[#sent + 1] = { type = type_name, payload = payload, cb = cb }
          return true
        end,
        on = function() return {} end,
        off_all = function() end,
      },
      toast = function() end,
    }
    local pg = Playground.new(app)
    pg.editor = Editor.new({})
    pg.lang = "rust"
    pg.focus = "editor"
    pg.editor:set_text("fn main() {}")
    local function runs()
      local out = {}
      for _, r in ipairs(sent) do
        if r.type == "playground.run" then out[#out + 1] = r end
      end
      return out
    end
    return pg, runs
  end

  T.case("AUTO-RUN through the real run: ENTERs mid-run are one more run, not three", function()
    local was = Playground.PREFS.auto_run
    Playground.PREFS.auto_run = true
    local pg, runs = bench()
    pg:auto_enter()
    T.eq(#runs(), 1, "the first ENTER runs")
    T.eq(pg.running, true)
    pg.editor:set_text("fn main() { println!(\"later\"); }")
    pg:auto_enter()
    pg:auto_enter()
    pg:auto_enter()
    T.eq(#runs(), 1, "nothing more goes out while one is out")
    -- The answer to the first comes back: exactly one more follows, with the
    -- code as it is now.
    runs()[1].cb(true, { run = { outcome = "ok", stdout = "", stderr = "" } })
    T.eq(#runs(), 2, "one more run, not three")
    T.ok(runs()[2].payload.source:find("later", 1, true), "for the code on screen by then")
    runs()[2].cb(true, { run = { outcome = "ok", stdout = "later\n", stderr = "" } })
    T.eq(#runs(), 2, "and that is the end of it")
    T.eq(pg.run_again, false)
    T.eq(pg.running, false)
    Playground.PREFS.auto_run = was
  end)

  T.case("a refused run still drains the one queued behind it", function()
    local was = Playground.PREFS.auto_run
    Playground.PREFS.auto_run = true
    local pg, runs = bench()
    pg:auto_enter()
    pg:auto_enter()
    runs()[1].cb(false, nil, { player = "busy" })
    T.eq(#runs(), 2, "the queued run goes out anyway")
    T.eq(pg.running, true, "and is the one on screen now")
    Playground.PREFS.auto_run = was
  end)

  T.case("a queued run waits out a save from another device", function()
    local was = Playground.PREFS.auto_run
    Playground.PREFS.auto_run = true
    local pg, runs = bench()
    pg:auto_enter()
    pg:auto_enter()
    pg.conflict = { source = "theirs" }
    runs()[1].cb(true, { run = { outcome = "ok" } })
    T.eq(#runs(), 1, "no run while the question is open")
    T.eq(pg.run_again, false, "and the queue is dropped, not kept for later")
    pg.conflict = nil
    Playground.PREFS.auto_run = was
  end)

  T.case("ENTER typed into the editor is what AUTO-RUN hears; a chord is not", function()
    local was = Playground.PREFS.auto_run
    Playground.PREFS.auto_run = true
    local pg, runs = bench()
    pg.editor:set_text("fn main() {}")
    pg:keypressed("return", {})
    T.eq(#runs(), 1, "a bare ENTER in the code runs it")
    T.ok(pg.editor:text():find("\n", 1, true), "after the newline went in")
    runs()[1].cb(true, { run = { outcome = "ok" } })
    pg:keypressed("return", { shift = true })
    T.eq(#runs(), 1, "SHIFT-ENTER is somebody else's")
    Playground.PREFS.auto_run = false
    pg:keypressed("return", {})
    T.eq(#runs(), 1, "with AUTO-RUN off, ENTER is a newline and nothing more")
    Playground.PREFS.auto_run = was
  end)

  T.case("STDERR off shows stderr only for a build that failed", function()
    local was = Playground.PREFS.stderr
    Playground.PREFS.stderr = false
    T.eq(Playground.loud({ outcome = "ok", stderr = "warning: unused" }), false,
      "a warning on a run that worked stays out of the answer")
    T.eq(Playground.loud({ outcome = "runtime_error", stderr = "panicked" }), false,
      "a panic too: off is off")
    T.eq(Playground.loud({ outcome = "compile_error", stderr = "E0425" }), true,
      "a failed build is all compiler, so the compiler is shown")
    T.eq(Playground.loud(nil), false, "streaming, before the reply: stdout only")
    Playground.PREFS.stderr = true
    T.eq(Playground.loud({ outcome = "ok" }), true, "on is on, whatever happened")
    T.eq(Playground.loud(nil), true, "the chatter streams in while it runs")
    Playground.PREFS.stderr = was
  end)
end
