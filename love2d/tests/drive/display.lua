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

local SOURCE = 'fn main() {\nlet n = 42;\nprintln!("{}", n);'

local function scene(name)
  return function(app) return app.scene_name == name end
end
local function on_login(app) return app.scene_name == "login" end

local steps = {}
local function add(t) steps[#steps + 1] = t end

--- Print and remember what the layout looks like right now.
local seen = {}
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
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      timeout = 15 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = on_login })
add({ key = "return", when = on_login })
add({ until_ = scene("lands"), note = "signed in", timeout = 25 })
add({ key = "return" })
add({ until_ = scene("categories"), timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end, timeout = 10 })
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
    if not (seen["f1-once"].pinned and seen["f1-twice"].pinned) then
      print("FAIL: F1 did not pin the orientation")
      ok = false
    end
    if seen["f1-twice"].mode ~= "portrait" then
      print("FAIL: the second F1 should be a pinned portrait, got " .. seen["f1-twice"].mode)
      ok = false
    end
    if seen["f1-thrice"].pinned then
      print("FAIL: the third F1 should hand the orientation back to automatic")
      ok = false
    end
    if ok then
      print(("PASS: %d bytes and the cursor survived two fullscreen transitions "
        .. "and three orientation changes"):format(#(text or "")))
    end
    return ok
  end, note = "the buffer, the cursor and the scene all survived", timeout = 5 })

add({ quit = true })

return steps
