-- The type-size control, at its largest, everywhere it has to survive.
--
--   make -C love2d drive SCRIPT=tests/drive/typesize.lua
--
-- Bigger type in a fixed pane is where wrapping, the line-number gutter and
-- `ensure_visible` are all tested at once, so this takes the largest step
-- through both code panes — the quest editor and the playground — in both
-- orientations and in fullscreen, and asserts the three things that would
-- actually break:
--
--   * **the pane still has rows.** A line height that outgrew the pane would
--     give `rows = 0`, and `math.max(1, …)` would hide it as one row of a
--     forty-line program.
--   * **the caret is still on screen.** `ensure_visible` is handed the new
--     row count every draw; if it were handed a stale one, making the type
--     bigger would scroll the line you are typing off the bottom.
--   * **nothing was dropped.** Same bytes, same cursor, same scene — the
--     rule every display change in this client has had since F11.

local SOURCE = table.concat({
  "fn main() {",
  "let mut total = 0;",
  "for n in 1..=10 {",
  "total += n * n;",
  "}",
  'println!("{}", total);',
}, "\n")

local steps = {}
local function add(t) steps[#steps + 1] = t end
local function scene(name)
  return function(app) return app.scene_name == name end
end
local function on_login(app) return app.scene_name == "login" end

local seen = {}

--- Anything drawn wider than the canvas it is drawn on, at the size it was
--- actually drawn at.
---
--- The probes below are all about the **code panes**, because that is what
--- the control is for. But the same control now scales every label in the
--- client, and at step 4 a heading authored at 18 asks for 88 px — which is
--- `PICK A LAND` at 968 px on a 720-wide portrait canvas. Nothing was
--- watching that, so this wraps `UI.text` from the test side (no production
--- change) and records every unwrapped draw that ran off the edge.
-- Keyed by type step, because the question is not "does anything ever clip"
-- but "does it clip at a size a player did not ask for". Step 1 is the
-- default and step 2 is one press; those must be clean. Steps 3 and 4 are a
-- deliberate request for type this big on a canvas this small, and prose that
-- runs past the edge there is reported rather than failed.
local overflow = {}
local function watch_text()
  local UI = require("src.ui")
  local Layout = require("src.layout")
  if UI.__watched then return end
  UI.__watched = true
  local real = UI.text
  UI.text = function(text, x, y, size, colour, align, limit, ...)
    -- A draw with a limit is a draw that wraps; only the unwrapped ones can
    -- run off the edge.
    if limit == nil and type(text) == "string" and #text > 0 then
      local w = UI.textWidth(text, size)
      if (x or 0) + w > Layout.vw + 1 then
        local step = Layout.font
        overflow[step] = overflow[step] or {}
        local key = tostring(text):sub(1, 28)
        overflow[step][key] =
          math.max(overflow[step][key] or 0, (x or 0) + w - Layout.vw)
      end
    end
    return real(text, x, y, size, colour, align, limit, ...)
  end
end

--- Everything a bigger font could have broken, in one line of output.
local function probe(tag)
  return function(app)
    local L = require("src.layout")
    local ed = app.scene and app.scene.editor
    local rows = app.scene and app.scene.visible_rows
    local row_of_caret = ed and (ed.line - ed.scroll) or nil
    seen[tag] = {
      scene = app.scene_name, font = L.font, code = L.codeSize(18),
      mode = L.mode, full = L.fullscreen, vw = L.vw, vh = L.vh,
      rows = rows, text = ed and ed:text() or nil,
      line = ed and ed.line, col = ed and ed.col,
      caret_visible = row_of_caret and row_of_caret >= 1 and rows
        and row_of_caret <= rows or false,
      gutter = app.scene and app.scene.gutter,
      pane_w = app.scene and (app.scene.editor_rect or app.scene.code_rect)
        and (app.scene.editor_rect or app.scene.code_rect).w or nil,
    }
    local s = seen[tag]
    print(("%-22s %-10s step=%d code=%2dpx %-9s full=%-5s canvas=%dx%d rows=%-3s "
      .. "caret=%-5s gutter=%-4s pane=%-4s bytes=%s")
      :format(tag, tostring(s.scene), s.font, s.code, s.mode, tostring(s.full),
        s.vw, s.vh, tostring(s.rows), tostring(s.caret_visible),
        tostring(s.gutter and math.floor(s.gutter)), tostring(s.pane_w and math.floor(s.pane_w)),
        tostring(s.text and #s.text)))
    return true
  end
end

--- The middle of one of the three footer chips, as the draw recorded it.
local function chip(name)
  return function(app)
    local r = app.display_rects and app.display_rects[name]
    assert(r, "no display rect for " .. name)
    return { r.x + r.w / 2, r.y + r.h / 2 }
  end
end

--- Click the type chip until it reaches `want`, however many steps that is.
local function set_step(want)
  local out = {}
  for _ = 1, 4 do
    out[#out + 1] = { click = chip("font"),
      when = function() return require("src.layout").font ~= want end }
    out[#out + 1] = { wait = 0.25 }
  end
  return out
end

local function add_all(list)
  for _, step in ipairs(list) do add(step) end
end

add({ until_ = function() watch_text(); return true end })
add({ orient = "landscape" })
add({ wait = 0.6 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      timeout = 15 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = on_login })
add({ key = "return", when = on_login })
add({ until_ = scene("lands"), note = "signed in", timeout = 25 })

-- ------------------------------------------------------------ the playground

add({ note = "the playground — a scratchpad with the same code pane" })
add({ key = "p" })
add({ until_ = scene("playground"), timeout = 15 })
add({ wait = 0.6 })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = SOURCE })
add({ wait = 0.3 })
add({ until_ = probe("playground/1 land"), timeout = 5 })

add_all(set_step(4))
add({ until_ = probe("playground/4 land"), timeout = 5 })
add({ shot = "T1-playground-big-landscape.png" })

add({ click = chip("orient") })
add({ wait = 1.0 })
add({ until_ = probe("playground/4 port"), timeout = 5 })
add({ shot = "T2-playground-big-portrait.png" })

add({ click = chip("fullscreen") })
add({ wait = 1.8 })
add({ until_ = probe("playground/4 port full"), timeout = 5 })
add({ shot = "T3-playground-big-portrait-full.png" })

add({ click = chip("fullscreen") })
add({ wait = 1.8 })
add({ orient = "landscape" })
add({ wait = 1.0 })
add({ until_ = probe("playground/4 land again"), timeout = 5 })

add_all(set_step(1))
add({ until_ = probe("playground/1 land again"), timeout = 5 })

-- ----------------------------------------------------------------- the quest

add({ key = "escape" })
add({ until_ = function(app)
      if app.scene_name == "map" then return true end
      app.land, app.category = "rust", "basic"
      app:go("map", { land = "rust", category = "basic" })
      return true
    end, timeout = 10 })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
      timeout = 15 })
add({ until_ = function(app)
      for i, n in ipairs(app.scene.nodes) do
        if n.state ~= "locked" then app.scene.cursor = i; return true end
      end
      return true
    end, timeout = 3 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
      timeout = 20 })
add({ wait = 0.5 })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = SOURCE })
add({ key = "end" })
add({ wait = 0.3 })
add({ until_ = probe("quest/1 land"), timeout = 5 })

add_all(set_step(4))
add({ until_ = probe("quest/4 land"), timeout = 5 })
add({ shot = "T4-quest-big-landscape.png" })

add({ click = chip("orient") })
add({ wait = 1.0 })
add({ until_ = probe("quest/4 port"), timeout = 5 })
add({ shot = "T5-quest-big-portrait.png" })

add({ click = chip("fullscreen") })
add({ wait = 1.8 })
add({ until_ = probe("quest/4 port full"), timeout = 5 })
add({ shot = "T6-quest-big-portrait-full.png" })

add({ click = chip("fullscreen") })
add({ wait = 1.8 })
add({ orient = "landscape" })
add({ wait = 1.0 })
add_all(set_step(1))
add({ until_ = probe("quest/1 land again"), timeout = 5 })

-- ------------------------------------------------- the screens made of labels

-- `lands` and `map` are not code panes; they are headings, cards and chips,
-- and step 4 is three presses away from the default. Portrait is the hard
-- shape because it is the narrow one.
add({ key = "escape" })
add({ until_ = scene("map"), timeout = 15 })
add_all(set_step(4))
add({ orient = "portrait" })
add({ wait = 1.2 })
add({ until_ = probe("map/4 port"), timeout = 5 })
add({ shot = "T7-map-big-portrait.png" })

add({ key = "t" })
add({ until_ = scene("stats"), timeout = 15 })
add({ wait = 1.0 })
add({ until_ = probe("stats/4 port"), timeout = 5 })
add({ shot = "T8-stats-big-portrait.png" })
add({ key = "escape" })
add({ until_ = scene("map"), timeout = 10 })

add({ key = "escape" })
add({ until_ = scene("categories"), timeout = 15 })
add({ wait = 0.8 })
add({ until_ = probe("categories/4 port"), timeout = 5 })
add({ shot = "T9-categories-big-portrait.png" })

add({ key = "escape" })
add({ until_ = scene("lands"), timeout = 15 })
add({ wait = 0.8 })
add({ until_ = probe("lands/4 port"), timeout = 5 })
add({ shot = "TA-lands-big-portrait.png" })

-- And the controls themselves are still reachable at the far end of the
-- ladder, on the narrow shape. They were not: see `chip_h` in `src/ui.lua`.
add({ until_ = function(app)
    local L = require("src.layout")
    local bad = {}
    for _, name in ipairs({ "fullscreen", "orient", "font", "lang" }) do
      local r = app.display_rects and app.display_rects[name]
      if not r then
        bad[#bad + 1] = name .. " was not drawn"
      elseif r.x < 0 or r.y < 0 or r.x + r.w > L.vw + 0.5 or r.y + r.h > L.vh + 0.5 then
        bad[#bad + 1] = ("%s at %d,%d %dx%d is outside %dx%d")
          :format(name, r.x, r.y, r.w, r.h, L.vw, L.vh)
      end
    end
    if #bad > 0 then
      print("FAIL: display controls off the canvas at step 4: "
        .. table.concat(bad, "; "))
      return false
    end
    print("the four display controls are all on-canvas at step 4, portrait")
    return true
  end, timeout = 5 })

-- The same four screens at the **default** step, which is the size a player
-- who never touches the control sees. A clip here is a defect; a clip at the
-- far end of the ladder is a preference meeting a small canvas.
add_all(set_step(1))
add({ wait = 0.8 })
add({ until_ = probe("lands/1 port"), timeout = 5 })
add({ key = "return" })
add({ until_ = scene("categories"), timeout = 15 })
add({ wait = 0.8 })
add({ until_ = probe("categories/1 port"), timeout = 5 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
      timeout = 15 })
add({ wait = 0.8 })
add({ until_ = probe("map/1 port"), timeout = 5 })
add({ key = "t" })
add({ until_ = scene("stats"), timeout = 15 })
add({ wait = 1.0 })
add({ until_ = probe("stats/1 port"), timeout = 5 })
add({ key = "escape" })
add({ until_ = scene("map"), timeout = 10 })
add({ orient = "landscape" })
add({ wait = 1.0 })
add({ until_ = probe("map/1 land"), timeout = 5 })

-- ------------------------------------------------------------------ the point

add({ until_ = function()
    local ok = true
    for tag, s in pairs(seen) do
      if s.rows and s.rows < 3 then
        print(("FAIL: %s has %s rows — the pane cannot hold a program")
          :format(tag, tostring(s.rows)))
        ok = false
      end
      if s.rows and not s.caret_visible then
        print(("FAIL: %s scrolled the caret off the pane (line %s, scroll shows %s rows)")
          :format(tag, tostring(s.line), tostring(s.rows)))
        ok = false
      end
      -- Against the buffer as the *editor* holds it, not against the string
      -- that was typed: brace auto-indent means those are two different
      -- things, and the claim being made is that a type-size change does not
      -- disturb the buffer — not that the editor types literally.
      local base = seen[tag:match("^(%a+)") .. "/1 land"]
      if base and s.text ~= base.text then
        print(("FAIL: %s lost the buffer: %d bytes, the pane started with %d")
          :format(tag, #(s.text or ""), #(base.text or "")))
        ok = false
      end
      if s.gutter and s.pane_w and s.gutter > s.pane_w * 0.5 then
        print(("FAIL: %s the line-number gutter ate half the pane (%d of %d)")
          :format(tag, s.gutter, s.pane_w))
        ok = false
      end
    end
    -- The step really did change the size, and really did come back.
    for _, pair in ipairs({
      { "playground/1 land", "playground/4 land" },
      { "quest/1 land", "quest/4 land" },
    }) do
      local small, big = seen[pair[1]], seen[pair[2]]
      if not (small and big and big.code > small.code) then
        print(("FAIL: %s did not get bigger than %s"):format(pair[2], pair[1]))
        ok = false
      end
      if small and big and big.rows and small.rows and big.rows >= small.rows then
        print(("FAIL: %s should show fewer rows than %s"):format(pair[2], pair[1]))
        ok = false
      end
    end
    for _, pair in ipairs({
      { "playground/1 land", "playground/1 land again" },
      { "quest/1 land", "quest/1 land again" },
    }) do
      local before, after = seen[pair[1]], seen[pair[2]]
      if not (before and after and before.code == after.code) then
        print(("FAIL: the cycle did not return to the size it started at (%s)")
          :format(pair[1]))
        ok = false
      end
    end
    -- The label screens. A code pane clips on purpose — it scrolls — but a
    -- heading that runs off the canvas is just gone.
    for step = 1, 4 do
      local over = {}
      for text, px in pairs(overflow[step] or {}) do
        over[#over + 1] = ("%s (+%dpx)"):format(text, px)
      end
      table.sort(over)
      if #over == 0 then
        print(("step %d: nothing ran off the canvas"):format(step))
      elseif step <= 2 then
        print(("FAIL: step %d is the default (or one press from it) and %d "
          .. "strings ran off the canvas:"):format(step, #over))
        for _, line in ipairs(over) do print("    " .. line) end
        ok = false
      else
        print(("step %d: %d strings run past the edge — reported, not failed; "
          .. "this step is a request for type this big on a canvas this small")
          :format(step, #over))
        for _, line in ipairs(over) do print("    " .. line) end
      end
    end
    if ok then
      print("PASS: the largest type step holds in both panes, both orientations "
        .. "and fullscreen — rows, caret, gutter and buffer all intact")
    end
    return ok
  end, note = "every probe survived the largest type step", timeout = 5 })

add({ quit = true })

return steps
