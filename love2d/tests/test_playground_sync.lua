-- A pad saved on another device (PROTOCOL §4.22), through the real scene.
--
-- The scene is made with `Playground.new` and given a real `src/editor.lua`
-- and a stand-in session that records what would have gone to the server.
-- Nothing here draws, so it runs under a bare luajit: what is asserted is the
-- behaviour the question exists for -- a clean pad takes the save, a dirty
-- one asks and saves nothing until it is answered, and each answer does what
-- it says. The drawing is exercised by `tests/drive/pgsync.lua` against a
-- real server.

local T = require("tests.framework")

local function scene()
  local Playground = require("src.scenes.playground")
  local Editor = require("src.editor")
  local sent = {}
  local app = {
    session = {
      request = function(_, type_name, payload, cb)
        sent[#sent + 1] = { type = type_name, payload = payload, cb = cb }
        return true
      end,
      off_all = function() end,
      on = function() return {} end,
    },
  }
  local pg = Playground.new(app)
  pg.editor = Editor.new({})
  pg.snippet_id = "pg_a"
  pg.name = "SIEVE"
  pg.lang = "rust"
  pg.editor:set_text("fn main() {}\n")
  pg.editor.dirty = false
  return pg, sent
end

local function saves(sent)
  local n = 0
  for _, r in ipairs(sent) do
    if r.type == "playground.save" then n = n + 1 end
  end
  return n
end

local function theirs(source)
  return { id = "pg_a", name = "SIEVE", lang = "rust", source = source, stdin = "" }
end

return function()
  T.section("playground — a save from another device")

  T.case("a clean pad takes it, and nothing is asked", function()
    local pg = scene()
    pg:remote_saved(theirs("fn main() { println!(\"laptop\"); }\n"))
    T.eq(pg.editor:text(), "fn main() { println!(\"laptop\"); }\n")
    T.eq(pg.conflict, nil)
    T.nope(pg.editor.dirty, "and the pad is clean")
  end)

  T.case("another pad's save is not this pad's business", function()
    local pg = scene()
    pg.editor:set_text("mine\n")
    pg.editor.dirty = true
    pg:remote_saved({ id = "pg_b", name = "OTHER", lang = "rust", source = "x", stdin = "" })
    T.eq(pg.conflict, nil)
    T.eq(pg.editor:text(), "mine\n")
  end)

  T.case("a dirty pad asks, keeps its text, and saves nothing until answered", function()
    local pg, sent = scene()
    pg.editor:set_text("fn main() { /* ipad */ }\n")
    pg.editor.dirty = true
    pg:remote_saved(theirs("fn main() { /* laptop */ }\n"))
    T.ok(pg.conflict ~= nil, "the question is open")
    T.eq(pg.editor:text(), "fn main() { /* ipad */ }\n", "the buffer is left alone")
    -- Everything that would otherwise save: the key, the autosave, leaving.
    pg:save()
    pg.dirty_at = -1e9
    pg:update(0.016)
    pg:leave()
    T.eq(saves(sent), 0, "no save was sent while the question was open")
  end)

  T.case("while it is open, nothing reaches the program", function()
    local pg = scene()
    pg.editor:set_text("abc\n")
    pg.editor.dirty = true
    pg:remote_saved(theirs("xyz\n"))
    pg:textinput("q")
    T.eq(pg.editor:text(), "abc\n", "typing is not typed")
    T.eq(pg:keypressed("f5", {}), true, "RUN is swallowed")
    T.ok(pg.conflict ~= nil, "and the question is still open")
  end)

  T.case("T takes theirs, and the T is not typed into it", function()
    local pg, sent = scene()
    pg.editor:set_text("mine\n")
    pg.editor.dirty = true
    pg:remote_saved(theirs("theirs\n"))
    pg:keypressed("t", {})
    pg:textinput("t") -- LÖVE sends the letter again, after the key
    T.eq(pg.conflict, nil, "answered")
    T.eq(pg.editor:text(), "theirs\n", "the other device's text")
    T.nope(pg.editor.dirty, "clean: it is the server's copy")
    T.eq(saves(sent), 0, "and taking it saves nothing")
    pg:textinput("x")
    T.ok(pg.editor:text():find("x", 1, true) ~= nil, "the next character is typed as usual")
  end)

  T.case("K keeps mine and saves it over theirs", function()
    local pg, sent = scene()
    pg.editor:set_text("mine\n")
    pg.editor.dirty = true
    pg:remote_saved(theirs("theirs\n"))
    pg:keypressed("k", {})
    pg:textinput("k")
    T.eq(pg.conflict, nil, "answered")
    T.eq(pg.editor:text(), "mine\n", "the text here stays, with no K in it")
    T.eq(saves(sent), 1, "and is saved")
    local save = sent[#sent]
    T.eq(save.payload.source, "mine\n")
    T.eq(save.payload.id, "pg_a", "over the same pad")
  end)

  T.case("the buttons answer the same way as the keys", function()
    local pg, sent = scene()
    pg.editor:set_text("mine\n")
    pg.editor.dirty = true
    pg:remote_saved(theirs("theirs\n"))
    -- Where `draw_conflict` put them; set by hand because nothing draws here.
    pg.conflict_rects = {
      theirs = { x = 10, y = 10, w = 100, h = 30 },
      mine = { x = 120, y = 10, w = 100, h = 30 },
    }
    pg:mousepressed(500, 500, 1)
    T.ok(pg.conflict ~= nil, "a press anywhere else answers nothing")
    pg:mousepressed(150, 20, 1)
    T.eq(pg.conflict, nil)
    T.eq(saves(sent), 1, "KEEP MINE saved")

    local pg2 = scene()
    pg2.editor:set_text("mine\n")
    pg2.editor.dirty = true
    pg2:remote_saved(theirs("theirs\n"))
    pg2.conflict_rects = {
      theirs = { x = 10, y = 10, w = 100, h = 30 },
      mine = { x = 120, y = 10, w = 100, h = 30 },
    }
    pg2:mousepressed(20, 20, 1)
    T.eq(pg2.editor:text(), "theirs\n", "TAKE THEIRS took it")
  end)

  T.case("a second save from over there replaces the first in the question", function()
    local pg = scene()
    pg.editor:set_text("mine\n")
    pg.editor.dirty = true
    pg:remote_saved(theirs("first\n"))
    pg:remote_saved(theirs("second\n"))
    pg:keypressed("t", {})
    T.eq(pg.editor:text(), "second\n", "theirs is their latest")
  end)

  T.case("a save of exactly what is here closes the question without one", function()
    local pg = scene()
    pg.editor:set_text("same\n")
    pg.editor.dirty = true
    pg:remote_saved(theirs("same\n"))
    T.eq(pg.conflict, nil)
    T.nope(pg.editor.dirty, "and the pad is as saved as theirs")
  end)
end
