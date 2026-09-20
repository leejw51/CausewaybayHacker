-- The lands the client knows, in one place.
--
-- Each screen used to carry its own `{ rust = …, go = … }` pair, and with
-- two lands that was cheap. Four lands made it a list to keep in step by
-- hand across five files — the order the cards come in, the sprite beside
-- the title, the name over it — so it is one table here that the scenes
-- read. The server still decides which lands *exist* (`world.lands`,
-- PROTOCOL §4.6); this is only how the client draws the ones it has heard
-- of, and a land it has not heard of is still drawn, with its id for a name.

local Assets = require("src.assets")

local Land = {}

-- SPEC §0's order: the two lands the game shipped with, then the two that
-- joined them.
Land.ORDER = { "rust", "go", "cpp", "python" }

-- The name on the card. `("cpp"):upper()` is "CPP", which nobody calls the
-- language; the other three happen to upper-case into themselves.
Land.NAME = { rust = "RUST", go = "GO", cpp = "C++", python = "PYTHON" }

-- The land's mascot, and what stands in while the art is being drawn: the
-- platypus is a hue-shifted Ferris until it is not, and the coiled python a
-- hue-shifted Gogo. `Assets.pick` takes whichever is on disk, so a checkout
-- without the new files still shows a creature on the card.
Land.MASCOT = {
  rust = "sprite_ferris",
  go = "sprite_gogo",
  cpp = "sprite_cpp",
  python = "sprite_python",
}
local STANDIN = { cpp = "sprite_ferris", python = "sprite_gogo" }

function Land.name(land)
  return Land.NAME[land] or tostring(land or "?"):upper()
end

--- SPEC §0's four roads, in the order they are walked. `verybasic` is the
--- quiz road (PROTOCOL §5.3): the grammar asked before it is typed.
Land.CATEGORIES = { "verybasic", "basic", "advanced", "hacker" }

--- The English label a category is translated from. `verybasic` is two
--- words on screen; every other road is its id in capitals, as before.
function Land.category_label(category)
  if category == "verybasic" then return "VERY BASIC" end
  return tostring(category or "?"):upper()
end

function Land.mascot(land)
  return Assets.pick(Land.MASCOT[land], STANDIN[land])
end

--- Where `land` sits in `ORDER`, or one past the end for a land the client
--- has not heard of — so the unknown sorts last rather than nowhere.
function Land.rank(land)
  for i, name in ipairs(Land.ORDER) do
    if name == land then return i end
  end
  return #Land.ORDER + 1
end

--- The idle bob's phase for a land's mascot, spread evenly round the cycle
--- so four cards in a row never nod in unison.
function Land.phase(land)
  return ((Land.rank(land) - 1) % #Land.ORDER) / #Land.ORDER
end

return Land
