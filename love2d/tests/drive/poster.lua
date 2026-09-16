-- POSTER and DISK READER, played rather than asserted.
--
--   make -C love2d drive SCRIPT=tests/drive/poster.lua ARGS="--home $(mktemp -d)"
--
-- Sign in, open the playground, type a program, press POSTER: the client has
-- forgotten the phrase by then, so the key field opens and the phrase is
-- typed again; a signed PNG and a JPEG land in `<home>/posters/`. Then the
-- PNG goes back through DISK READER and the program has to come back
-- verified, as a new pad. The server must be up (`make start` in the repo).

local MNEMONIC = "february dial color toward gas rough divorce crack beauty opera vote never"
local SOURCE = 'fn main() {\n    let city = "Causeway Bay";\n    println!("hello from {city}");\n}\n'

local function scene(name)
  return function(app)
    return app.scene_name == name
  end
end
local function on_login(app)
  return app.scene_name == "login"
end

local steps = {}
local function add(t)
  steps[#steps + 1] = t
end
local saved_path

add({ orient = "landscape" })
add({ wait = 0.6 })
add({
  until_ = function(app)
    return app.scene_name == "login" or app.session.authed
  end,
  timeout = 15,
})
add({ text = MNEMONIC, when = on_login })
add({ key = "return", when = on_login })
add({ until_ = scene("lands"), note = "signed in", timeout = 25 })
add({ wait = 0.5 })
add({ key = "p" })
add({
  until_ = function(app)
    return app.scene_name == "playground" and app.scene.editor ~= nil
  end,
  note = "the playground",
  timeout = 10,
})
add({
  until_ = function(app)
    app.scene.editor:set_text(SOURCE)
    app.scene.editor.dirty = true
    return true
  end,
  timeout = 3,
})
add({ wait = 0.3 })
-- POSTER with no key held: the field opens.
add({
  until_ = function(app)
    app.scene:poster()
    return app.scene.focus == "stamp"
  end,
  note = "POSTER asks for the key",
  timeout = 3,
})
add({ shot = "poster-01-key-field.png" })
add({ text = MNEMONIC })
add({ key = "return" })
add({
  until_ = function(app)
    local note = tostring(app.scene.note or "")
    saved_path = note:match("(/[^ ]+%.png)")
    return saved_path ~= nil
  end,
  note = "poster saved",
  timeout = 60,
})
add({
  until_ = function(app)
    local fh = io.open(saved_path, "rb")
    assert(fh, "the PNG is on disk: " .. saved_path)
    local head = fh:read(8)
    fh:close()
    assert(head == "\137PNG\r\n\26\n", "it is a PNG")
    local jh = io.open((saved_path:gsub("%.png$", ".jpg")), "rb")
    assert(jh, "the JPEG is beside it")
    jh:close()
    print("poster: " .. saved_path)
    return true
  end,
  timeout = 3,
})
add({ shot = "poster-02-saved.png" })
-- Something else in the editor, then the poster back in.
add({
  until_ = function(app)
    app.scene.editor:set_text('fn main() { println!("something else"); }\n')
    app.scene:read_disk_path(saved_path)
    return true
  end,
  timeout = 3,
})
add({
  until_ = function(app)
    return tostring(app.scene.note or ""):find("verified", 1, true) ~= nil
  end,
  note = "the disk read back verified",
  timeout = 20,
})
add({
  until_ = function(app)
    assert(app.scene.editor:text() == SOURCE, "the program is back, byte for byte")
    assert(app.scene.lang == "rust", "in its language")
    print("disk read: " .. tostring(app.scene.note))
    return true
  end,
  timeout = 3,
})
add({ shot = "poster-03-read-back.png" })
add({ quit = true })

return steps
