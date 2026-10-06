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
-- joined them, then the one the ending was always about, then TypeScript,
-- then ZIG (the toll plaza at dawn: everything explicit, every allocation
-- paid for) and LUA (Tai Hang on Mid-Autumn night, on the very interpreter
-- this client runs on), and last REMIX — the one land that is not a
-- language: the same program in Go, Rust and Python, whose quests each
-- carry a `lang` of their own. REMIX stays last whatever joins before it.
Land.ORDER = { "rust", "go", "cpp", "python", "pytorch", "typescript", "zig", "lua", "remix" }

-- The languages: every land but REMIX, in the same order. A scratchpad, an
-- attempt and a formatter are in a language, never in a land (PROTOCOL
-- §5.9), so the playground's TAB walks this list and not `ORDER`.
Land.LANGS = { "rust", "go", "cpp", "python", "pytorch", "typescript", "zig", "lua" }

-- The name on the card. `("cpp"):upper()` is "CPP", which nobody calls the
-- language; the other three happen to upper-case into themselves.
Land.NAME = {
  rust = "RUST", go = "GO", cpp = "C++", python = "PYTHON", pytorch = "PYTORCH",
  typescript = "TYPESCRIPT", zig = "ZIG", lua = "LUA", remix = "REMIX",
}

-- The land's mascot, and what stands in while the art is being drawn: the
-- platypus is a hue-shifted Ferris until it is not, and the coiled python a
-- hue-shifted Gogo; the gecko in the hi-vis vest is an amber crab until the
-- art is there, and the moon rabbit a Gogo. `Assets.pick` takes whichever
-- is on disk, so a checkout without the new files still shows a creature
-- on the card.
Land.MASCOT = {
  rust = "sprite_ferris",
  go = "sprite_gogo",
  cpp = "sprite_cpp",
  python = "sprite_python",
  pytorch = "sprite_pytorch",
  typescript = "sprite_typescript",
  zig = "sprite_zig",
  lua = "sprite_lua",
  remix = "sprite_remix",
}
local STANDIN = {
  cpp = "sprite_ferris", python = "sprite_gogo", pytorch = "sprite_python",
  typescript = "sprite_cpp", zig = "sprite_ferris", lua = "sprite_gogo",
  remix = "sprite_python",
}

function Land.name(land)
  return Land.NAME[land] or tostring(land or "?"):upper()
end

--- SPEC §0's roads, in the order they are walked. `verybasic` is the quiz
--- road (PROTOCOL §5.3): the grammar asked before it is typed. `frameworks`
--- is the crates road — the job after the interview — and RUST LAND's alone.
Land.CATEGORIES = { "verybasic", "basic", "advanced", "hacker", "frameworks" }

--- The roads `land` has (SPEC §0): every language land has the four, RUST
--- has FRAMEWORKS as a fifth, and REMIX LAND the two grammar roads only.
--- What the map's switcher offers and what Q cycles through, so no key
--- leads to a map the server answers `not_found` for.
Land.LANGUAGE_ROADS = { "verybasic", "basic", "advanced", "hacker" }
Land.REMIX_ROADS = { "verybasic", "basic" }
function Land.roads(land)
  if land == "remix" then return Land.REMIX_ROADS end
  if land == "rust" then return Land.CATEGORIES end
  return Land.LANGUAGE_ROADS
end

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

--- The language a quest is judged in (PROTOCOL §5.3): its own `lang` when
--- the server sent one, else its land — which is the language everywhere
--- but REMIX LAND. The editor, the formatter, the scratch file and the
--- submit all key on this; the backdrop and the tint key on the land.
function Land.lang_of(quest, fallback)
  if quest and quest.lang then return quest.lang end
  if quest and quest.land and quest.land ~= "remix" then return quest.land end
  return fallback or "rust"
end

--- The lands to offer, from the ids `world.lands` reported (PROTOCOL §4.6),
--- in `ORDER`'s order with any land the client has not heard of after them
--- (by id). `nil` — the client has not heard `world.lands` yet — is every
--- land the client knows. The map's switcher walks this rather than `ORDER`
--- so no key asks a server for a map of a land it does not have.
function Land.known(ids)
  if ids == nil then return Land.ORDER end
  local out = {}
  for i, id in ipairs(ids) do out[i] = id end
  table.sort(out, function(a, b)
    local ra, rb = Land.rank(a), Land.rank(b)
    if ra ~= rb then return ra < rb end
    return tostring(a) < tostring(b)
  end)
  return out
end

--- The idle bob's phase for a land's mascot, spread evenly round the cycle
--- so four cards in a row never nod in unison.
function Land.phase(land)
  return ((Land.rank(land) - 1) % #Land.ORDER) / #Land.ORDER
end

return Land
