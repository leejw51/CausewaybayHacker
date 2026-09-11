-- The mouse in the editor, and the brackets, in the real widget.
--
-- `tests/test_editor.lua` asserts the model: which bytes a drag selects, and
-- which brackets never closed. This drives the actual pane — the hit test
-- against a real VT323 glyph, the selection band, the outlines — and leaves
-- screenshots a person has to look at, because "the caret landed one
-- character to the left of where I clicked" is not a thing a test notices.
--
--   make -C love2d drive SCRIPT=tests/drive/mouse.lua

local function scene(name)
  return function(app) return app.scene_name == name end
end

local function on_login(app) return app.scene_name == "login" end

--- A point in virtual coordinates at (line, col) of the editor, measured from
--- the geometry this frame's draw actually used.
local function at(line, col)
  return function(app)
    local pane = app.scene.pane
    local g = assert(pane.geom, "the pane has not been drawn yet")
    local text = app.scene.editor.lines[line] or ""
    col = math.min(col, #text + 1)
    return {
      g.x0 + g.gutter + g.font:getWidth(text:sub(1, col - 1)),
      g.y0 + (line - app.scene.editor.scroll - 1) * g.line_h + g.line_h / 2,
    }
  end
end

local steps = {}
local function add(t) steps[#steps + 1] = t end

add({ orient = "landscape" })
add({ wait = 0.6 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      timeout = 15 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = on_login })
add({ key = "return", when = on_login })
add({ until_ = scene("lands"), note = "signed in", timeout = 20 })
add({ key = "return" })
add({ until_ = scene("categories"), timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end, timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
      note = "in the editor", timeout = 10 })
add({ wait = 0.4 })
add({ freeze = 12.5 })

-- A short program with one brace missing, which is the state this feature
-- exists for.
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = "fn main() {" })
add({ key = "return" })
add({ text = 'let v = vec![1, 2, 3];' })
add({ key = "return" })
add({ text = "for x in v {" })
add({ key = "return" })
add({ text = 'println!("{} says }", x);' })
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ wait = 0.3 })
add({ note = "one `{` never closed; the `}` inside the string must not count" })
add({ shot = "M1-brackets-unmatched.png" })

-- Close it, and the report should go quiet while the pair at the caret lights.
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ wait = 0.3 })
add({ shot = "M2-brackets-matched.png" })

-- Drag from the middle of line 2 to the middle of line 4.
add({ drag = { at(2, 9), at(4, 14) } })
add({ wait = 0.3 })
add({ note = "dragged a selection across three lines" })
add({ shot = "M3-drag-select.png" })

-- Double click the identifier on line 2.
add({ click = at(2, 11), clicks = 2 })
add({ wait = 0.3 })
add({ shot = "M4-double-click-word.png" })

-- Triple click takes the whole line.
add({ click = at(3, 6), clicks = 3 })
add({ wait = 0.3 })
add({ shot = "M5-triple-click-line.png" })

-- And a drag that runs off the top of the pane, which must scroll and clamp
-- rather than select something surprising.
add({ click = at(5, 1) })
add({ drag = { at(5, 2), function(app)
  local g = app.scene.pane.geom
  return { g.x0 + g.gutter + 40, g.rect.y - 60 }
end } })
add({ wait = 0.3 })
add({ shot = "M6-drag-off-the-top.png" })

add({ note = "portrait, same pane" })
add({ orient = "portrait" })
add({ wait = 0.5 })
add({ drag = { at(2, 5), at(3, 10) } })
add({ wait = 0.3 })
add({ shot = "M7-portrait.png" })

-- The playground has the same pane, and it is the other half of the claim
-- that there is only one implementation.
add({ key = "escape" })
add({ until_ = scene("map"), timeout = 10 })
add({ orient = "landscape" })
add({ key = "p" })
add({ until_ = function(app) return app.scene_name == "playground" and app.scene.editor end,
      timeout = 10 })
add({ wait = 0.6 })
add({ drag = { at(2, 5), at(4, 12) } })
add({ wait = 0.3 })
add({ shot = "M8-playground-drag.png" })

-- The AI screen's new rows, in both orientations.
add({ key = "escape" })
add({ until_ = scene("map"), timeout = 10 })
add({ key = "a" })
add({ until_ = scene("ai"), timeout = 10 })
add({ wait = 0.8 })
add({ shot = "M9-ai-modes.png" })
add({ orient = "portrait" })
add({ wait = 0.5 })
add({ shot = "M10-ai-modes-portrait.png" })

-- And the shackle on the stats screen.
add({ key = "escape" })
add({ until_ = scene("map"), timeout = 10 })
add({ orient = "landscape" })
add({ key = "t" })
add({ until_ = scene("stats"), timeout = 10 })
add({ wait = 1.2 })
add({ shot = "M11-stats-shackle.png" })
add({ orient = "portrait" })
add({ wait = 0.5 })
add({ shot = "M12-stats-portrait.png" })

-- Back to the map for the wires.
add({ key = "escape" })
add({ until_ = scene("map"), timeout = 10 })
add({ orient = "landscape" })
add({ wait = 0.8 })
add({ shot = "M13-map-wires.png" })
add({ orient = "portrait" })
add({ wait = 0.6 })
add({ shot = "M14-map-wires-portrait.png" })

add({ wait = 1.0 })
add({ quit = true })

return steps
