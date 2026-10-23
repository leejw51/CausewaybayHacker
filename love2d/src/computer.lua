-- Which old computer the playground is pretending to be.
--
-- Ported from the browser client's `ui/computer.ts`. A second axis beside the
-- light/dark paper (`Theme.CODE_THEMES`), and a playground-only one: the quest
-- screen is where somebody is being tested, and a Guru Meditation over a
-- failed quest would be a joke at their expense. The scratchpad is where
-- breaking things is the point, so the machine gets to have opinions about it.
--
-- Each machine is four things at once:
--
--   * **the paper** -- `PALETTE`, the code pane's colours, read by the
--     playground in place of `Theme.code` / `Theme.pane` and by nothing else,
--     so the quest screen never sees a machine;
--   * **the face** -- `FACE`, the home-computer face the code is set in, when
--     `src/assets.lua` has it;
--   * **the tube** -- `src/retroscreen.lua`, a shader over the editor in the
--     spirit of cool-retro-term, and `src/retromonitor.lua`, the plastic round
--     it;
--   * **the room** -- `bg_playground_<machine>`, Grok-drawn.
--
-- "normal" is the game as it was: no palette, no tube, the face left alone.
--
-- **LÖVE-free.** Everything here is tables and one variable, so the suite can
-- walk the cycle and check every palette without a window.

local M = {}

M.COMPUTERS = { "normal", "apple2", "msx", "amiga" }

--- Its own name on the button, like the code faces. "normal" is translated by
--- the scene, because it is a word and these are names.
M.NAME = { apple2 = "APPLE ][", msx = "MSX", amiga = "AMIGA" }

--- The face each machine sets the code in: the three home-computer faces the
--- browser ships (PR Number 3, MSX1, Topaz). Only applied when
--- `Assets.CODE_FACE_NAME` knows the face -- this client may not carry it yet.
M.FACE = { apple2 = "apple2", msx = "msx", amiga = "amiga" }

local computer = "normal"

function M.get() return computer end

--- Set the machine. Anything that is not one of `COMPUTERS` is ignored, so a
--- stale value read back from somewhere cannot leave the screen on a machine
--- that has no palette.
function M.set(next_computer)
  for _, name in ipairs(M.COMPUTERS) do
    if name == next_computer then
      computer = next_computer
      return true
    end
  end
  return false
end

--- The one after `from` (or after the current one), wrapping to "normal".
function M.next(from)
  from = from or computer
  for i, name in ipairs(M.COMPUTERS) do
    if name == from then return M.COMPUTERS[i % #M.COMPUTERS + 1] end
  end
  return "normal"
end

local function hex(h, a)
  return {
    tonumber(h:sub(2, 3), 16) / 255,
    tonumber(h:sub(4, 5), 16) / 255,
    tonumber(h:sub(6, 7), 16) / 255,
    a or 1,
  }
end
M.hex = hex

--- The code pane on each machine, keyed exactly as `Theme.code` and
--- `Theme.pane` are, so `draw_code` reads one table or the other and never
--- asks which.
---
--- From the browser's `style.css` blocks under `:root[data-computer]`: the
--- Apple ][ is one green phosphor, every colour a brightness of it; the MSX
--- is SCREEN 0, white on the TMS9918's blue with the VDP's colours for the
--- rest; the Amiga is Workbench 1.3's four colours -- blue, white, black,
--- orange. Two keys the themes do not have: `gutter_ink` (the line numbers,
--- which `CodePane` otherwise draws in `Theme.dim`) and `glow`, the colour
--- the glyphs bleed into the glass, which the browser does with a CSS
--- `text-shadow`.
M.PALETTE = {
  apple2 = {
    code = {
      text = hex("#48ff78"),
      keyword = hex("#c8ffc8"),
      type = hex("#78ff98"),
      string = hex("#30d860"),
      number = hex("#b0ffc0"),
      comment = hex("#1f8c40"),
      macro = hex("#98ffb0"),
      punct = hex("#38c860"),
    },
    pane = {
      paper = hex("#050c07"),
      gutter = hex("#040a06"),
      gutter_ink = hex("#1f8c40"),
      active = hex("#48ff78", 0.06),
      select = hex("#48ff78", 0.3),
      caret = hex("#48ff78"),
      match = hex("#48ff78"),
      ghost = hex("#48ff78", 0.4),
      hole = hex("#ffffff"),
      scroll = hex("#48ff78", 0.3),
      glow = hex("#48ff78", 0.3),
    },
  },
  msx = {
    code = {
      text = hex("#ffffff"),
      keyword = hex("#ffe680"),
      type = hex("#8cf098"),
      string = hex("#ffb0b0"),
      number = hex("#ffcf6a"),
      comment = hex("#b4b4ff"),
      macro = hex("#42ebf5"),
      punct = hex("#dcdcdc"),
    },
    pane = {
      paper = hex("#5455ed"),
      gutter = hex("#4646c8"),
      gutter_ink = hex("#c8c8ff"),
      active = hex("#ffffff", 0.08),
      select = hex("#c95bba", 0.6),
      caret = hex("#ffffff"),
      match = hex("#ffffff"),
      ghost = hex("#ffffff", 0.45),
      hole = hex("#ff5554"),
      scroll = hex("#ffffff", 0.3),
      glow = hex("#c8d2ff", 0.22),
    },
  },
  amiga = {
    code = {
      text = hex("#ffffff"),
      keyword = hex("#ff8800"),
      type = hex("#ffd060"),
      string = hex("#a8ffb0"),
      number = hex("#ffd060"),
      comment = hex("#80a8d8"),
      macro = hex("#aee8ff"),
      punct = hex("#e0e0e0"),
    },
    pane = {
      paper = hex("#0055aa"),
      gutter = hex("#ffffff"),
      gutter_ink = hex("#0055aa"),
      -- The orange rule Workbench drew down the gutter's edge.
      gutter_rule = hex("#ff8800"),
      active = hex("#ff8800", 0.12),
      select = hex("#ff8800", 0.45),
      caret = hex("#ff8800"),
      match = hex("#ff8800"),
      ghost = hex("#ffffff", 0.45),
      hole = hex("#ff2200"),
      scroll = hex("#ffffff", 0.3),
      glow = hex("#ffa03c", 0.18),
    },
  },
}

--- How each tube looks. Colours are 0..1 RGB; the rest are strengths the
--- shader multiplies by, tuned by eye against cool-retro-term's presets
--- ("Apple ][", "IBM VGA 8x16", "Commodore PET" and friends). The browser's
--- numbers, unchanged, so the two clients' tubes are the same tube.
M.TUBE = {
  -- A green P1 phosphor monochrome monitor: heavy lines, lots of glow, no mask.
  apple2 = {
    paper = { 0.02, 0.05, 0.03 }, ink = { 0.25, 1.0, 0.45 }, cols = 40,
    scan = 0.32, scan_px = 3, mask = 0, bloom = 1.1, curve = 0.18,
    noise = 0.06, roll = 0.07, fringe = 0,
  },
  -- A colour television on the RF lead: softer lines, a shadow mask, fringing.
  msx = {
    paper = { 84 / 255, 85 / 255, 237 / 255 }, ink = { 1, 1, 1 }, cols = 40,
    scan = 0.2, scan_px = 3, mask = 0.12, bloom = 0.55, curve = 0.14,
    noise = 0.08, roll = 0.05, fringe = 0.6,
  },
  -- A 1084S: sharp, interlaced PAL, Workbench blue.
  amiga = {
    paper = { 0, 85 / 255, 170 / 255 }, ink = { 1, 1, 1 }, cols = 64,
    scan = 0.22, scan_px = 2, mask = 0.08, bloom = 0.45, curve = 0.1,
    noise = 0.04, roll = 0.04, fringe = 0.3,
  },
}

--- How a run ended, as each machine would have said so. Kept here and not in
--- the scene: these are the machines' words, in the machines' register, and
--- the playground's own strings are pinned to a gentler one
--- (`tests/test_playground.lua`).
M.SAYS = {
  apple2 = {
    compile_error = { "?SYNTAX ERROR" },
    runtime_error = { "?ILLEGAL QUANTITY ERROR" },
    timeout = { "BREAK IN 10" },
    output_limit = { "?OUT OF MEMORY ERROR" },
  },
  msx = {
    compile_error = { "Syntax error in 10" },
    runtime_error = { "Illegal function call in 10" },
    timeout = { "Break in 10" },
    output_limit = { "Out of memory" },
  },
  amiga = {
    compile_error = {
      "Software Failure.    Press left mouse button to continue.",
      "Guru Meditation #00000004.0000AAC0",
    },
    runtime_error = {
      "Software Failure.    Press left mouse button to continue.",
      "Guru Meditation #00000003.00C0FFEE",
    },
    timeout = {
      "Software Failure.    Press left mouse button to continue.",
      "Guru Meditation #00000009.0000DEAD",
    },
    output_limit = {
      "Not enough memory.    Press left mouse button to continue.",
      "Guru Meditation #81000005.0000BEEF",
    },
  },
}

--- What `machine` says about a run that ended with `outcome`, or nil -- for
--- "normal", for a run that went fine, and for an outcome it has no words for.
function M.says(machine, outcome, run)
  if M.SAYS[machine] and outcome == "compile_error" and run then
    local message = run.stderr or ""
    if not message:find("%S") then
      local diagnostics = {}
      for _, d in ipairs(run.diagnostics or {}) do
        local where = type(d.line) == "number" and (" (" .. d.line ..
          (type(d.col) == "number" and (":" .. d.col) or "") .. ")") or ""
        diagnostics[#diagnostics + 1] = (d.kind or "error") ..
          (type(d.code) == "string" and (" " .. d.code) or "") .. where .. ": " .. d.message
      end
      message = table.concat(diagnostics, "\n")
    end
    if not message:find("%S") then message = "Compilation failed (no compiler message returned)." end
    message = message:gsub("\27%[[0-9;]*m", ""):gsub("\r", ""):gsub("\t", "    "):gsub("\n+$", "")
    local lines = {}
    for line in (message .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    return lines
  end
  local says = M.SAYS[machine]
  return says and says[outcome] or nil
end

--- The monitor each machine sat in: the plastic, its lit and shadowed edges,
--- the bezel sloping down to the glass, the nameplate's ink and the LED.
--- From the browser's `ui/monitor.ts`.
M.CASING = {
  -- The Monitor II: Apple beige, a green LED.
  apple2 = {
    body = hex("#d6cba6"), light = hex("#efe7cb"), dark = hex("#9c916e"),
    bezel = hex("#4a4434"), plate = hex("#5b5340"), led = hex("#4dff6a"),
  },
  -- A black portable colour television.
  msx = {
    body = hex("#232328"), light = hex("#4a4a54"), dark = hex("#0c0c10"),
    bezel = hex("#111114"), plate = hex("#c8c8d8"), led = hex("#ff3a2a"),
  },
  -- A 1084S: cream, with a green power light.
  amiga = {
    body = hex("#e4dfcd"), light = hex("#fbf8ec"), dark = hex("#a8a290"),
    bezel = hex("#56524a"), plate = hex("#3c3a34"), led = hex("#58e858"),
  },
}

--- How thick the casing is round a screen of this size, in virtual pixels.
function M.frame(w, h)
  local side = math.max(8, math.floor(math.min(w, h) * 0.035 + 0.5))
  return side, math.floor(side * 2.2 + 0.5)
end

--- The art the room is drawn from on this machine: its own, upright or not,
--- before the usual chain. Nil on "normal", which keeps the usual room.
function M.room(machine, portrait)
  if not M.NAME[machine] then return nil end
  local name = "bg_playground_" .. machine
  return portrait and (name .. "_p") or name, name
end

return M
