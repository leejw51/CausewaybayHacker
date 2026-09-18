-- The playground's register (PROTOCOL §4.9c).
--
-- DESIGN's note for this screen: nothing there is scored, so compiler output
-- must not speak in the failure register and the word "wrong" must not appear.
-- That is a constraint on *language*, and language is the easiest thing in a
-- program to break by accident six months later — so it is pinned here rather
-- than left to whoever next edits the scene.

local T = require("tests.framework")

--- The scene's own source, with comments stripped: the prose in this file
--- explains the rule and naturally contains the words the rule forbids.
local function scene_source()
  local fh = io.open("src/scenes/playground.lua", "r")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  body = body:gsub("%-%-%[%[.-%]%]", " ")
  local code = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do
    code[#code + 1] = line:gsub("%-%-.*$", "")
  end
  return table.concat(code, "\n")
end

return function()
  T.section("playground — nothing here is scored, and it must not sound like it is")

  local source = scene_source()

  T.case("no verdict vocabulary reaches the screen", function()
    if not source then
      T.skip("src/scenes/playground.lua", "not readable from this working directory")
      return
    end
    -- Every string literal the scene can put on screen.
    local strings = {}
    for literal in source:gmatch('"([^"]*)"') do strings[#strings + 1] = literal:lower() end
    for literal in source:gmatch("'([^']*)'") do strings[#strings + 1] = literal:lower() end

    for _, banned in ipairs({
      "wrong", "fail", "failed", "failure", "incorrect", "invalid",
      "accepted", "rejected", "verdict", "passed", "correct",
    }) do
      for _, literal in ipairs(strings) do
        T.nope(literal:find(banned, 1, true),
          ("%q must not appear in a playground string (found in %q)"):format(banned, literal))
      end
    end
  end)

  T.case("the outcome words describe rather than judge", function()
    -- §5.9's five outcomes, in this client's words. Each says what the
    -- program did; none says whether it was any good, because there is no
    -- question here for it to be an answer to.
    local expected = {
      ok = "ran",
      compile_error = "did not compile",
      runtime_error = "stopped early",
      timeout = "took too long",
      output_limit = "printed too much",
    }
    if not source then return end
    for outcome, phrase in pairs(expected) do
      T.ok(source:find(outcome, 1, true) ~= nil, outcome .. " is handled")
      T.ok(source:find(phrase, 1, true) ~= nil,
        ("%s is described as %q"):format(outcome, phrase))
    end
  end)

  T.case("the failure palette is not used on this screen", function()
    if not source then return end
    -- `Theme.red` and `Theme.verdict` are the game's "this went badly"
    -- colours. A compile error at a desk is information, not a judgement.
    T.nope(source:find("Theme.red", 1, true), "no red")
    T.nope(source:find("Theme.verdict", 1, true), "no verdict colours")
    T.nope(source:find('SFX.play("rejected")', 1, true), "and no rejection chime")
  end)

  T.case("a save from another device is taken when clean, said when dirty, ignored when another pad", function()
    local Playground = require("src.scenes.playground")
    T.eq(Playground.remote_save_action("pg_a", "pg_a", false), "apply")
    T.eq(Playground.remote_save_action("pg_a", "pg_a", true), "notify")
    T.eq(Playground.remote_save_action("pg_a", "pg_b", false), "ignore")
    T.eq(Playground.remote_save_action("pg_a", "pg_b", true), "ignore")
    -- An unsaved pad has no id and can never be the one that was saved.
    T.eq(Playground.remote_save_action(nil, "pg_a", false), "ignore")
  end)

  T.case("TAB offers every land's language, each with a starter that prints", function()
    -- The desk is where a player checks the toolchain is there before a
    -- quest asks anything of it, so the starter for each language is the
    -- smallest program that compiles and prints — and there is one for
    -- every land the map can show, in the order the map shows them.
    local Playground = require("src.scenes.playground")
    local Land = require("src.land")
    T.same(Playground.LANGS, Land.ORDER, "TAB walks the lands' order")
    for _, lang in ipairs(Land.ORDER) do
      local starter = Playground.STARTER[lang]
      T.ok(type(starter) == "string" and #starter > 0, lang .. " has a starter")
      T.ok(starter:find("hello", 1, true) ~= nil, lang .. "'s starter says hello")
      T.eq(starter:sub(-1), "\n", lang .. "'s starter ends in a newline, as a file should")
    end
    T.ok(Playground.STARTER.cpp:find("#include <iostream>", 1, true) ~= nil)
    T.ok(Playground.STARTER.cpp:find('std::cout << "hello\\n";', 1, true) ~= nil,
      "the C++ starter prints an escaped newline, not a literal one")
    T.eq(Playground.STARTER.python, 'print("hello")\n')
  end)

  T.case("the run shares the one execution slot", function()
    -- §4.9c: "the playground is the same runner", and §3.2's one-in-flight is
    -- per connection. Observed on the live server: three concurrent
    -- `playground.run`s came back `busy`.
    local netclient = require("src.net.client")
    T.eq(netclient.EXECUTES["playground.run"], true)
    T.eq(netclient.EXECUTES["quest.run"], true)
    T.eq(netclient.EXECUTES["quest.submit"], true)
    T.eq(netclient.EXECUTES["code.format"], nil,
      "formatting is not a run and must not block one")
  end)
end
