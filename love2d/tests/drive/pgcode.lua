-- The playground's CODE mode, and RENAME (§4.9c).
--
--   make -C love2d drive SCRIPT=tests/drive/pgcode.lua
--
-- The scratchpad is five things in one window — a list, an editor, a stdin
-- field, a band of buttons and an output pane — and on a phone held upright
-- that leaves the thing being typed into a few lines tall. CODE is the way
-- out: the editor, one strip of controls, and nothing else. This walks in,
-- checks the editor really did get the window, renames the pad, and comes
-- back out in both orientations.

local steps = {}
local function add(t) steps[#steps + 1] = t end
local fail = false
local function check(ok, why)
  if ok then return true end
  print("FAIL: " .. why)
  fail = true
  return false
end
local function pg(app) return app.scene_name == "playground" and app.scene or nil end

add({ orient = "landscape" })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      note = "login, or already resumed", timeout = 20 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = function(app) return app.scene_name == "login" end })
add({ key = "return", when = function(app) return app.scene_name == "login" end })
add({ until_ = function(app) return app.scene_name == "lands" end,
      note = "signed in", timeout = 30 })
add({ until_ = function(app) app:go("playground"); return true end, timeout = 5 })
add({ until_ = function(app) return pg(app) ~= nil end, note = "the playground", timeout = 10 })
add({ wait = 0.5 })

-- How tall the editor is in the framed screen, for the comparison below.
local framed_rows = 0
add({ until_ = function(app)
      local s = pg(app)
      framed_rows = s.visible_rows or 0
      check(s.code_button_rect ~= nil, "no CODE button on the playground")
      check(s.rename_rect ~= nil, "no RENAME button on the playground")
      print(("framed: %d rows of code"):format(framed_rows))
      return true
    end, timeout = 5 })
add({ shot = "P1-playground-framed.png" })

-- Into CODE, by the button rather than by setting the flag.
add({ click = function(app) local r = pg(app).code_button_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return pg(app).big == true end, note = "CODE is on", timeout = 5 })
add({ wait = 0.4 })
add({ until_ = function(app)
      local s = pg(app)
      print(("CODE: %d rows of code"):format(s.visible_rows or 0))
      check((s.visible_rows or 0) > framed_rows,
        ("CODE gave the editor no more room: %d rows against %d framed")
          :format(s.visible_rows or 0, framed_rows))
      check(s.stdin_rect == nil, "the stdin field's hit box outlived the strip it was in")
      return true
    end, timeout = 5 })
add({ shot = "P2-playground-code.png" })

-- RENAME, from inside CODE.
add({ click = function(app) local r = pg(app).big_rects.rename
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return pg(app).focus == "name" end,
      note = "the name field is open", timeout = 5 })
add({ key = "backspace", repeats = 40 })
add({ text = "kettle" })
add({ shot = "P3-playground-rename.png" })
add({ key = "return" })
add({ until_ = function(app)
      local s = pg(app)
      check(s.name == "kettle", "the rename did not take: " .. tostring(s.name))
      check(s.focus ~= "name", "the name field stayed open after ENTER")
      return true
    end, note = "renamed", timeout = 6 })

-- ESC leaves CODE, not the screen.
add({ key = "escape" })
add({ until_ = function(app)
      local s = pg(app)
      if not s then check(false, "ESC left the playground instead of leaving CODE"); return true end
      return s.big == false
    end, note = "ESC came back to the framed screen", timeout = 5 })

-- And the whole of it again, upright.
add({ orient = "portrait" })
add({ wait = 0.6 })
add({ until_ = function(app)
      local s = pg(app)
      print(("portrait framed: %d rows"):format(s.visible_rows or 0))
      check(s.code_button_rect ~= nil, "no CODE button in portrait")
      return true
    end, timeout = 5 })
add({ shot = "P4-playground-portrait.png" })
add({ click = function(app) local r = pg(app).code_button_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return pg(app).big == true end, note = "CODE, upright", timeout = 5 })
add({ wait = 0.4 })
add({ until_ = function(app)
      local s = pg(app)
      print(("portrait CODE: %d rows"):format(s.visible_rows or 0))
      check((s.visible_rows or 0) >= 12,
        ("CODE upright is still cramped: %d rows"):format(s.visible_rows or 0))
      return true
    end, timeout = 5 })
add({ shot = "P5-playground-code-portrait.png" })

add({ until_ = function()
      print("playground code: " .. (fail and "FAILED" or "0 failures"))
      if fail then error("playground code drive failed", 0) end
      return true
    end, timeout = 3 })
add({ quit = true })
return steps
