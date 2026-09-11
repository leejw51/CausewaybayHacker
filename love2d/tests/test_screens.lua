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

  T.case("the FTS5 snippet markup is stripped rather than shown", function()
    local _, code = strings_of("src/scenes/search.lua")
    if not code then return end
    -- §5.5's snippet "may contain <b>…</b>". Showing a player raw markup is
    -- showing them the plumbing.
    T.ok(code:find("</?b>", 1, true) ~= nil, "the tags are removed")
  end)
end
