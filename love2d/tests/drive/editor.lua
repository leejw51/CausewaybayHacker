-- Type a twenty-line Rust program into the real editor, in the real UI.
--
-- `tests/test_editor.lua` asserts the model's bytes; this drives the actual
-- widget — scrolling, the caret, the selection band, the syntax colours, the
-- byte counter — and leaves screenshots a person can look at.
--
--   make -C love2d drive SCRIPT=tests/drive/editor.lua

local function scene(name)
  return function(app) return app.scene_name == name end
end

local function on_login(app) return app.scene_name == "login" end

local PROGRAM = {
  "use std::collections::HashMap;",
  "",
  "fn tally(words: &[&str]) -> HashMap<String, usize> {",
  "let mut counts = HashMap::new();",
  "for w in words {",
  "*counts.entry(w.to_string()).or_insert(0) += 1;",
}

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

-- Clear the starter and type the program, letting auto-indent do the work.
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
for _, line in ipairs(PROGRAM) do
  add({ text = line })
  add({ key = "return" })
end
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ key = "return" })
add({ text = "counts" })
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ key = "return" })
add({ key = "return" })
add({ text = "fn main() {" })
add({ key = "return" })
add({ text = 'let words = ["a", "b", "a"];' })
add({ key = "return" })
add({ text = "let counts = tally(&words);" })
add({ key = "return" })
add({ text = "let mut keys: Vec<&String> = counts.keys().collect();" })
add({ key = "return" })
add({ text = "keys.sort();" })
add({ key = "return" })
add({ text = "for k in keys {" })
add({ key = "return" })
add({ text = 'println!("{} {}", k, counts[k]);' })
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ wait = 0.4 })

add({ until_ = function(app)
    local text = app.scene.editor:text()
    print("editor: " .. select(2, text:gsub("\n", "\n")) + 1 .. " lines, " .. #text .. " bytes")
    for _, line in ipairs({
      "    let mut counts = HashMap::new();",
      "        *counts.entry(w.to_string()).or_insert(0) += 1;",
      '        println!("{} {}", k, counts[k]);',
    }) do
      if not text:find(line, 1, true) then
        print("editor: MISSING the auto-indented line: " .. line)
        return false
      end
    end
    return true
  end, note = "auto-indent put every line where a Rust programmer expects", timeout = 5 })
add({ shot = "E1-typed.png" })

-- Selection, and the scrollbar with the cursor near the end.
add({ key = "home" })
add({ key = "up" })
for _ = 1, 6 do add({ key = "up", mods = { shift = true } }) end
add({ wait = 0.3 })
add({ shot = "E2-selection.png" })

-- Undo the whole burst.
for _ = 1, 40 do add({ key = "z", mods = { ctrl = true } }) end
add({ wait = 0.3 })
add({ shot = "E3-undone.png" })
add({ until_ = function(app)
    print("editor: after 40 undos -> " .. #app.scene.editor:text() .. " bytes")
    return true
  end, timeout = 3 })

add({ orient = "portrait" })
add({ resize = { 720, 1000 } })
add({ wait = 0.8 })
add({ shot = "E4-portrait.png" })
add({ quit = true })

return steps
