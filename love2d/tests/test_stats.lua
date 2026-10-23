-- The record card's per-land grid.
--
-- This exists because of a bug that only appears with more than two lands and
-- is invisible in a screenshot of the first two: the per-land record was one
-- joined string drawn through `UI.text` with no width, which goes to
-- `love.graphics.print` — a call that neither wraps nor clips. With `rust` and
-- `go` the line fitted and nobody noticed the missing width. With `cpp` and
-- `python` beside them it ran off the panel and off the window, and the land
-- you could not see was the one you had been playing.
--
-- The record is a grid of tiles now, in real columns rather than a text
-- block padded with spaces, and the grid is its own pure function. These are
-- the cases the drawing code cannot be trusted to get right on its own.

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

--- Every cell of a grid, in reading order.
local function cells(grid)
  local out = {}
  for _, row in ipairs(grid) do
    for _, cell in ipairs(row) do out[#out + 1] = cell end
  end
  return out
end

return function()
  T.section("stats — the record's per-land grid")

  T.case("nothing at all is no rows, not a row saying nothing", function()
    T.eq(#Stats.land_grid(nil, 3), 0, "nil is empty")
    T.eq(#Stats.land_grid({}, 3), 0, "an empty list is empty")
  end)

  T.case("two lands share one row of three", function()
    local grid = Stats.land_grid(by_land({ { "rust", 4, 69 }, { "go", 0, 69 } }), 3)
    T.eq(#grid, 1, "one row")
    T.eq(#grid[1], 2, "two cells on it")
    T.eq(grid[1][1].name, "RUST")
    T.eq(grid[1][1].cleared, 4)
    T.eq(grid[1][1].total, 69)
    T.eq(grid[1][2].name, "GO", "and go beside it")
  end)

  T.case("four lands take two rows of three — none runs off the card", function()
    local grid = Stats.land_grid(by_land({
      { "rust", 4, 69 }, { "go", 0, 69 }, { "cpp", 1, 69 }, { "python", 1, 69 },
    }), 3)
    T.eq(#grid, 2, "two rows")
    T.eq(#grid[1], 3, "the first is full")
    T.eq(#grid[2], 1, "the second holds what is left")
    T.eq(grid[2][1].name, "PYTHON", "python is on the second row")
  end)

  T.case("the column count is the caller's: two upright, three across", function()
    local record = by_land({
      { "rust", 1, 2 }, { "go", 1, 2 }, { "cpp", 1, 2 }, { "python", 1, 2 }, { "zig", 1, 2 },
    })
    T.eq(#Stats.land_grid(record, 2), 3, "five lands in two columns are three rows")
    T.eq(#Stats.land_grid(record, 3), 2, "and in three columns, two")
    T.eq(#Stats.land_grid(record, 0), 5, "a column count under one is one column")
    for _, row in ipairs(Stats.land_grid(record, 2)) do
      T.ok(#row <= 2, "no row is wider than its columns")
    end
  end)

  T.case("every land the server names reaches a cell — none is dropped", function()
    -- The failure this replaces dropped lands silently, so the count is the
    -- assertion that matters: a player who cleared a C++ street must see C++.
    for n = 1, 9 do
      local rows = {}
      for i = 1, n do rows[i] = { "rust", i, 10 } end
      local grid = Stats.land_grid(by_land(rows), 3)
      T.eq(#grid, math.ceil(n / 3), ("%d lands take %d rows"):format(n, math.ceil(n / 3)))
      local drawn = cells(grid)
      T.eq(#drawn, n, ("all %d lands are drawn"):format(n))
      for i, cell in ipairs(drawn) do
        T.eq(cell.cleared, i, "in the order the server sent them")
      end
    end
  end)

  T.case("C++ is written C++, not CPP", function()
    -- `("cpp"):upper()` is "CPP", which nobody calls the language. The name
    -- comes from the shared catalogue so the card and the land card agree.
    local grid = Stats.land_grid(by_land({ { "cpp", 0, 69 } }), 3)
    T.eq(grid[1][1].name, "C++", "the name is C++")
    T.eq(grid[1][1].land, "cpp", "and the key is kept for the mascot and the stripe")
  end)

  T.case("a land with no counts reads as zero rather than crashing", function()
    -- `by_land` comes off the wire; a row missing a field must not take the
    -- whole record card down with it.
    local ok, grid = pcall(Stats.land_grid, { { land = "rust" } }, 3)
    T.ok(ok, "a partial row does not throw")
    if ok then
      T.eq(grid[1][1].cleared, 0, "an absent count is zero")
      T.eq(grid[1][1].total, 0)
    end
  end)

  T.case("a land the client has never heard of still gets a cell", function()
    -- The server owns the land list. A client one release behind must show the
    -- new land's record rather than silently omit it.
    local grid = Stats.land_grid(by_land({ { "cobol", 3, 7 } }), 3)
    T.eq(#grid, 1, "it is drawn")
    T.eq(grid[1][1].cleared, 3, "with its numbers")
    T.eq(grid[1][1].total, 7)
    T.ok(type(grid[1][1].name) == "string" and grid[1][1].name ~= "", "and a name of some kind")
  end)
end
