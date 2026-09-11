-- The fullscreen toggle, and what it must not break.
--
--   make -C love2d drive SCRIPT=tests/drive/display.lua
--
-- The failure mode worth testing is not "does the window change size" — it
-- is whether a toggle mid-quest, with edited source in the editor, keeps the
-- player exactly where they were. A toggle that resets the scene or drops
-- the buffer is worse than no toggle at all, so this types a program, toggles
-- fullscreen twice, cycles the orientation through all three states, and
-- asserts the bytes are identical to what was typed.
--
-- It then does the whole thing again **through the buttons**, because a key
-- nobody can see is not a feature and a button nobody has driven is not
-- tested. The clicks are aimed at `app.display_rects`, not at coordinates,
-- so the same script works in either orientation and at any scale — and
-- aiming at the rectangle the draw actually recorded is what makes the test
-- about the control rather than about the arithmetic in the test.

local SOURCE = 'fn main() {\nlet n = 42;\nprintln!("{}", n);'

local function scene(name)
  return function(app) return app.scene_name == name end
end
local function on_login(app) return app.scene_name == "login" end

local steps = {}
local function add(t) steps[#steps + 1] = t end

--- Print and remember what the layout looks like right now.
local seen = {}

--- The cluster is drawn by `App:footer`, which every scene calls, so this is
--- the "on every screen" claim proved rather than asserted. Declared up here
--- because the login and land screens are passed through long before the
--- quest screen the buttons are exercised on.
local function has_cluster_early(where)
  return function(app)
    local r = app.display_rects
    if not (r and r.fullscreen and r.orient and r.font) then
      print("FAIL: no display controls on " .. where)
      return false
    end
    seen["cluster-" .. where] = true
    print(("cluster on %-10s x=%d..%d  y=%d"):format(
      where, r.fullscreen.x, r.font.x + r.font.w, r.font.y))
    return true
  end
end
local function snapshot(tag)
  return function(app)
    local L = require("src.layout")
    local ed = app.scene and app.scene.editor
    seen[tag] = {
      full = L.fullscreen, mode = L.mode, pinned = L.pinned,
      vw = L.vw, vh = L.vh, scale = L.scale,
      scene = app.scene_name,
      text = ed and ed:text() or nil,
      line = ed and ed.line, col = ed and ed.col,
    }
    print(("%-14s full=%-5s mode=%-9s pinned=%-5s canvas=%dx%d scale=%.2f scene=%s bytes=%s")
      :format(tag, tostring(L.fullscreen), L.mode, tostring(L.pinned),
        L.vw, L.vh, L.scale, tostring(app.scene_name),
        tostring(seen[tag].text and #seen[tag].text)))
    return true
  end
end

add({ orient = "landscape" })
add({ wait = 0.6 })
-- The title card, before anything has been signed into. A player who wants
-- to play in portrait should not have to sign in first to be allowed to ask.
add({ until_ = has_cluster_early("title"), timeout = 8 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      timeout = 15 })
add({ until_ = has_cluster_early("login"), when = on_login, timeout = 5 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = on_login })
add({ key = "return", when = on_login })
add({ until_ = scene("lands"), note = "signed in", timeout = 25 })
add({ until_ = has_cluster_early("lands"), timeout = 5 })
-- Straight to the map, rather than through the land and category screens.
--
-- Not a shortcut for its own sake: `world.lands` currently disagrees with
-- `world.map` on this server — for `rust` it reports `basic` with
-- `total: 19, open: false` while `world.map` for rust/basic returns 12 nodes
-- with node 1 `open`. The category screen does the right thing with that
-- (§4.6: `open` is the server's word, and a closed category refuses to
-- open), which means the normal route is blocked for any account with
-- progress. The subject of *this* script is the display, so it goes around
-- the disagreement and prints it as evidence instead.
add({ until_ = function(app)
      for _, land in ipairs(app.scene.lands or {}) do
        local parts = { land.land }
        for _, cat in ipairs(land.categories) do
          parts[#parts + 1] = ("%s open=%s %d/%d"):format(
            cat.category, tostring(cat.open), cat.cleared, cat.total)
        end
        print("world.lands: " .. table.concat(parts, "  "))
      end
      app.land, app.category = "rust", "basic"
      app:go("map", { land = "rust", category = "basic" })
      return true
    end, note = "world.lands, as reported", timeout = 10 })
add({ until_ = function(app)
      if not (app.scene_name == "map" and app.scene.nodes) then return false end
      local open, locked, cleared = 0, 0, 0
      for _, n in ipairs(app.scene.nodes) do
        if n.state == "open" then open = open + 1 end
        if n.state == "locked" then locked = locked + 1 end
        if n.state == "cleared" then cleared = cleared + 1 end
      end
      local first = app.scene.nodes[1]
      print(("world.map:   rust/basic %d nodes, %d open, %d locked, %d cleared; "
        .. "node 1 (%s) is %s"):format(#app.scene.nodes, open, locked, cleared,
        tostring(first and first.quest_id), tostring(first and first.state)))
      return true
    end, note = "world.map, for the same land and category", timeout = 10 })
add({ until_ = has_cluster_early("map"), timeout = 5 })
add({ until_ = function(app)
      -- Land on something playable.
      for i, n in ipairs(app.scene.nodes) do
        if n.state ~= "locked" then app.scene.cursor = i; return true end
      end
      return true
    end, timeout = 3 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
      note = "in the editor", timeout = 15 })
add({ wait = 0.5 })

add({ note = "typing something worth not losing" })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = SOURCE })
add({ wait = 0.3 })
add({ until_ = snapshot("typed"), timeout = 5 })
add({ shot = "D1-quest-windowed.png" })

add({ note = "F11 -> fullscreen, mid-quest" })
add({ key = "f11" })
add({ wait = 1.6 })   -- the macOS fullscreen animation
add({ until_ = snapshot("fullscreen"), timeout = 5 })
add({ shot = "D2-quest-fullscreen.png" })

add({ note = "F1 through all three orientation states, still fullscreen" })
add({ key = "f1" })
add({ wait = 0.9 })
add({ until_ = snapshot("f1-once"), timeout = 5 })
add({ key = "f1" })
add({ wait = 0.9 })
add({ until_ = snapshot("f1-twice"), timeout = 5 })
add({ shot = "D3-fullscreen-portrait.png" })
add({ key = "f1" })
add({ wait = 0.9 })
add({ until_ = snapshot("f1-thrice"), timeout = 5 })

add({ note = "F11 -> back to a window" })
add({ key = "f11" })
add({ wait = 1.6 })
add({ until_ = snapshot("windowed"), timeout = 5 })
add({ shot = "D4-quest-windowed-again.png" })

-- ---------------------------------------------------------------- the buttons

--- The centre of one of the three footer chips, as the draw recorded it.
local function chip(name)
  return function(app)
    local rect = app.display_rects and app.display_rects[name]
    assert(rect, "no display rect for " .. name .. " — the cluster was not drawn")
    return { rect.x + rect.w / 2, rect.y + rect.h / 2 }
  end
end

add({ note = "the same three controls, clicked instead of typed" })
add({ until_ = has_cluster_early("quest"), timeout = 5 })
add({ until_ = snapshot("before-clicks"), timeout = 5 })

add({ note = "click WINDOW -> fullscreen" })
add({ click = chip("fullscreen") })
add({ wait = 1.6 })
add({ until_ = snapshot("click-full"), timeout = 5 })
add({ shot = "D5-click-fullscreen.png" })

add({ note = "click the orientation chip three times: LAND -> PORT -> AUTO -> LAND" })
add({ click = chip("orient") })
add({ wait = 0.9 })
add({ until_ = snapshot("click-orient-1"), timeout = 5 })
add({ shot = "D6-click-portrait.png" })
add({ click = chip("orient") })
add({ wait = 0.9 })
add({ until_ = snapshot("click-orient-2"), timeout = 5 })
-- The third state, which is the one a two-way toggle could never reach and
-- the one a label alone could never describe: the word says AUTO and the
-- glyph says which shape the window handed it.
add({ shot = "D6b-click-automatic.png" })
add({ click = chip("orient") })
add({ wait = 0.9 })
add({ until_ = snapshot("click-orient-3"), timeout = 5 })

add({ note = "click the type-size chip through all four steps and back" })
add({ until_ = function(app)
      local L = require("src.layout")
      -- From the first rung, whatever the default is (`Layout.DEFAULT_FONT`
      -- is 2): the assertion below is that the cycle climbs and wraps, and
      -- a cycle started on rung 2 climbs 3, 4, then drops to 1.
      L.setFont(1)
      seen.font_start = L.font
      seen.font_sizes = { L.codeSize(18) }
      return true
    end, timeout = 3 })
for i = 1, 4 do
  add({ click = chip("font") })
  add({ wait = 0.4 })
  add({ until_ = function(app)
        local L = require("src.layout")
        seen.font_sizes[#seen.font_sizes + 1] = L.codeSize(18)
        print(("font step %d/%d -> code %dpx   rows=%s   bytes=%s"):format(
          L.font, #L.FONT_STEPS, L.codeSize(18),
          tostring(app.scene.visible_rows),
          tostring(#(app.scene.editor and app.scene.editor:text() or ""))))
        return true
      end, timeout = 3 })
  if i == 3 then add({ shot = "D7-largest-type.png" }) end
end
add({ until_ = snapshot("click-font"), timeout = 5 })

add({ note = "click FULL -> back to a window" })
add({ click = chip("fullscreen") })
add({ wait = 1.6 })
add({ until_ = snapshot("click-window"), timeout = 5 })
add({ shot = "D8-click-windowed.png" })

-- The whole point.
add({ until_ = function(app)
    local text = app.scene.editor and app.scene.editor:text()
    local ok = true
    if text ~= seen.typed.text then
      print("FAIL: the editor buffer changed across the toggles")
      print(("  before %d bytes, after %d bytes"):format(
        #(seen.typed.text or ""), #(text or "")))
      ok = false
    end
    if app.scene_name ~= "quest" then
      print("FAIL: the scene changed: " .. tostring(app.scene_name))
      ok = false
    end
    if app.scene.editor.line ~= seen.typed.line or app.scene.editor.col ~= seen.typed.col then
      print(("FAIL: the cursor moved: %d,%d -> %d,%d"):format(
        seen.typed.line, seen.typed.col, app.scene.editor.line, app.scene.editor.col))
      ok = false
    end
    if not seen.fullscreen.full then
      print("FAIL: F11 did not enter fullscreen")
      ok = false
    end
    if seen.fullscreen.vw == seen.typed.vw and seen.fullscreen.vh == seen.typed.vh then
      print("FAIL: the virtual canvas was not re-measured on the transition")
      ok = false
    end
    if seen.windowed.full then
      print("FAIL: F11 did not leave fullscreen")
      ok = false
    end
    -- The script pins landscape in its first step, so the cycle runs
    -- pinned-landscape -> pinned-portrait -> automatic -> pinned-landscape.
    if not (seen["f1-once"].pinned and seen["f1-once"].mode == "portrait") then
      print(("FAIL: the first F1 should pin portrait, got mode=%s pinned=%s")
        :format(seen["f1-once"].mode, tostring(seen["f1-once"].pinned)))
      ok = false
    end
    if seen["f1-twice"].pinned then
      print("FAIL: the second F1 should hand the orientation back to automatic")
      ok = false
    end
    if not (seen["f1-thrice"].pinned and seen["f1-thrice"].mode == "landscape") then
      print(("FAIL: the third F1 should pin landscape again, got mode=%s pinned=%s")
        :format(seen["f1-thrice"].mode, tostring(seen["f1-thrice"].pinned)))
      ok = false
    end
    if seen["f1-once"].vw == seen.fullscreen.vw and seen["f1-once"].vh == seen.fullscreen.vh then
      print("FAIL: pinning portrait did not re-measure the canvas")
      ok = false
    end
    -- ---- and now the same claims about the button path ----
    if not seen["click-full"].full then
      print("FAIL: clicking the window chip did not enter fullscreen")
      ok = false
    end
    if seen["click-window"].full then
      print("FAIL: clicking it again did not leave fullscreen")
      ok = false
    end
    if seen["click-full"].vw == seen["before-clicks"].vw
      and seen["click-full"].vh == seen["before-clicks"].vh then
      print("FAIL: the canvas was not re-measured on the clicked transition")
      ok = false
    end
    -- The cycle, clicked: pinned landscape -> pinned portrait -> automatic
    -- -> pinned landscape. A *restored* pin is weaker than a pressed one and
    -- a clicked one is a pressed one.
    if not (seen["click-orient-1"].pinned and seen["click-orient-1"].mode == "portrait") then
      print(("FAIL: the first click should pin portrait, got mode=%s pinned=%s")
        :format(seen["click-orient-1"].mode, tostring(seen["click-orient-1"].pinned)))
      ok = false
    end
    if seen["click-orient-2"].pinned then
      print("FAIL: the second click should hand the orientation back to automatic")
      ok = false
    end
    if not (seen["click-orient-3"].pinned and seen["click-orient-3"].mode == "landscape") then
      print("FAIL: the third click should pin landscape again")
      ok = false
    end
    -- Four steps, each strictly bigger than the last, wrapping to the first.
    local sizes = seen.font_sizes or {}
    for i = 2, 4 do
      if not (sizes[i] and sizes[i] > sizes[i - 1]) then
        print(("FAIL: type step %d (%s) is not larger than step %d (%s)")
          :format(i, tostring(sizes[i]), i - 1, tostring(sizes[i - 1])))
        ok = false
      end
    end
    if sizes[5] ~= sizes[1] then
      print(("FAIL: the type cycle did not wrap: %s then %s")
        :format(tostring(sizes[1]), tostring(sizes[5])))
      ok = false
    end
    -- And the cluster was actually on every screen this run passed through.
    --
    -- The login screen is **conditional on purpose**: a run whose stored
    -- token still resumes never sees it (PROTOCOL §4.4), and demanding it
    -- would make this script fail for the one reason that is not a bug. It
    -- is checked when it is there and reported when it is not.
    for _, where in ipairs({ "title", "lands", "map", "quest" }) do
      if not seen["cluster-" .. where] then
        print("FAIL: no display controls seen on " .. where)
        ok = false
      end
    end
    print(seen["cluster-login"]
      and "cluster on login: yes"
      or "cluster on login: not visited this run (the stored token resumed)")
    if ok then
      print(("PASS: %d bytes and the cursor survived four fullscreen transitions, "
        .. "six orientation changes and four type sizes — by key and by button")
        :format(#(text or "")))
    end
    return ok
  end, note = "the buffer, the cursor and the scene all survived", timeout = 5 })

add({ quit = true })

return steps
