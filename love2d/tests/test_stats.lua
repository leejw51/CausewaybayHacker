-- The record panel's per-land lines.
--
-- This exists because of a bug that only appears with more than two lands and
-- is invisible in a screenshot of the first two: the per-land record was one
-- joined string drawn through `UI.text` with no width, which goes to
-- `love.graphics.print` — a call that neither wraps nor clips. With `rust` and
-- `go` the line fitted and nobody noticed the missing width. With `cpp` and
-- `python` beside them it ran off the panel and off the window, and the land
-- you could not see was the one you had been playing.
--
-- So the pairing is its own function, and these are the cases the drawing code
-- cannot be trusted to get right on its own.

local T = require("tests.framework")
local Stats = require("src.scenes.stats")

--- `{ land, cleared, total }` triples into the shape `stats.summary` sends.
local function by_land(rows)
  local out = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { land = row[1], cleared = row[2], total = row[3] }
  end
  return out
end

return function()
  T.section("stats — the record's per-land lines")

  T.case("nothing at all is no lines, not a line saying nothing", function()
    T.eq(#Stats.land_lines(nil), 0, "nil is empty")
    T.eq(#Stats.land_lines({}), 0, "an empty list is empty")
  end)

  T.case("two lands share one line, the way they always did", function()
    local lines = Stats.land_lines(by_land({ { "rust", 4, 69 }, { "go", 0, 69 } }))
    T.eq(#lines, 1, "one line")
    T.ok(lines[1]:find("RUST 4/69", 1, true) ~= nil, "rust is on it")
    T.ok(lines[1]:find("GO 0/69", 1, true) ~= nil, "and so is go")
  end)

  T.case("four lands take two lines instead of running off the panel", function()
    local lines = Stats.land_lines(by_land({
      { "rust", 4, 69 }, { "go", 0, 69 }, { "cpp", 1, 69 }, { "python", 1, 69 },
    }))
    T.eq(#lines, 2, "two lines, two lands each")
    T.ok(lines[2]:find("C%+%+ 1/69") ~= nil, "cpp is on the second line")
    T.ok(lines[2]:find("PYTHON 1/69", 1, true) ~= nil, "and python beside it")
  end)

  T.case("an odd count leaves the last line half full rather than dropping it", function()
    local lines = Stats.land_lines(by_land({
      { "rust", 1, 2 }, { "go", 1, 2 }, { "cpp", 1, 2 },
    }))
    T.eq(#lines, 2, "two lines")
    T.ok(lines[2]:find("C%+%+") ~= nil, "the odd one out is still drawn")
    T.ok(lines[2]:find("     ") == nil, "and is not padded with a phantom partner")
  end)

  T.case("every land the server names reaches a line — none is dropped", function()
    -- The failure this replaces dropped lands silently, so the count is the
    -- assertion that matters: a player who cleared a C++ street must see C++.
    for n = 1, 8 do
      local rows = {}
      for i = 1, n do rows[i] = { "rust", i, 10 } end
      local lines = Stats.land_lines(by_land(rows))
      T.eq(#lines, math.ceil(n / 2), ("%d lands take %d lines"):format(n, math.ceil(n / 2)))
      local drawn = 0
      for _, line in ipairs(lines) do
        for _ in line:gmatch("%d+/10") do drawn = drawn + 1 end
      end
      T.eq(drawn, n, ("all %d lands are drawn"):format(n))
    end
  end)

  T.case("C++ is written C++, not CPP", function()
    -- `("cpp"):upper()` is "CPP", which nobody calls the language. The name
    -- comes from the shared catalogue so the panel and the land card agree.
    local lines = Stats.land_lines(by_land({ { "cpp", 0, 69 } }))
    T.ok(lines[1]:find("C%+%+") ~= nil, "the name is C++")
    T.ok(lines[1]:find("CPP", 1, true) == nil, "and never CPP")
  end)

  T.case("a land with no counts reads as zero rather than crashing", function()
    -- `by_land` comes off the wire; a row missing a field must not take the
    -- whole record panel down with it.
    local ok, lines = pcall(Stats.land_lines, { { land = "rust" } })
    T.ok(ok, "a partial row does not throw")
    if ok then
      T.ok(lines[1]:find("0/0", 1, true) ~= nil, "an absent count is zero")
    end
  end)

  T.case("a land the client has never heard of still gets a line", function()
    -- The server owns the land list. A client one release behind must show the
    -- new land's record rather than silently omit it.
    local lines = Stats.land_lines(by_land({ { "zig", 3, 7 } }))
    T.eq(#lines, 1, "it is drawn")
    T.ok(lines[1]:find("3/7", 1, true) ~= nil, "with its numbers")
  end)
end
