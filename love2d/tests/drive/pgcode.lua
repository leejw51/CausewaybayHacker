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

-- Copy and paste: the only way anything leaves a canvas.
add({ until_ = function(app)
      local s = pg(app)
      love.system.setClipboardText("")
      s.editor:set_text("package main\n// the original\n")
      return true
    end, timeout = 5 })
add({ click = function(app) local r = pg(app).big_rects.copycode
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function()
      local got = love.system.getClipboardText() or ""
      check(got:find("the original", 1, true) ~= nil,
        "COPY CODE did not put the editor on the clipboard: " .. got:sub(1, 40))
      return true
    end, note = "the code is on the clipboard", timeout = 5 })
add({ until_ = function()
      love.system.setClipboardText("package main\n// from the clipboard\n")
      return true
    end, timeout = 3 })
add({ click = function(app) local r = pg(app).big_rects.pastecode
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app)
      local text = pg(app).editor:text()
      check(text:find("from the clipboard", 1, true) ~= nil,
        "PASTE did not replace the editor: " .. text:sub(1, 40))
      return true
    end, note = "the clipboard is in the editor", timeout = 5 })
-- Run something, so there is output to place — and in a landscape window it
-- goes **beside** the code rather than under it. Stacked there it costs a
-- quarter of the few lines a wide-but-short window has.
add({ until_ = function(app)
      pg(app).editor:set_text('fn main() { println!("side by side"); }\n')
      return true
    end, timeout = 5 })
add({ key = "f5", note = "run it" })
add({ until_ = function(app) return pg(app).result ~= nil end,
      note = "the run came back", timeout = 120 })
add({ wait = 0.4 })
add({ until_ = function(app)
      local s = pg(app)
      local code, out = s.code_rect, s.out_rect
      check(code and out, "no code or output rect after a run")
      if code and out then
        print(("landscape: code x=%d w=%d, out x=%d w=%d")
          :format(code.x, code.w, out.x, out.w))
        check(out.x >= code.x + code.w,
          "landscape put the output under the code instead of beside it")
        check(math.abs(out.y - code.y) < 4, "the output is not level with the code")
      end
      return true
    end, note = "output beside the code", timeout = 5 })
add({ shot = "P7-code-output-beside.png" })

-- COPY OUTPUT: the run, not whatever the editor happens to hold. On the web
-- these two looked like separate bugs and were one — a copy that wrote
-- nothing left the clipboard holding the code — so it is asserted here by
-- what lands on the clipboard rather than by the button being pressable.
add({ until_ = function(app)
      check(pg(app).big_rects.copyout ~= nil, "no COPY OUTPUT button after a run")
      love.system.setClipboardText("")
      return true
    end, timeout = 5 })
add({ click = function(app) local r = pg(app).big_rects.copyout
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function()
      local got = love.system.getClipboardText() or ""
      print("copied output: " .. got:gsub("\n", " | "):sub(1, 60))
      check(got ~= "", "COPY OUTPUT put nothing on the clipboard")
      check(got:find("side by side", 1, true) ~= nil,
        "the output does not carry what the program printed: " .. got:sub(1, 60))
      check(got:find("fn main", 1, true) == nil,
        "COPY OUTPUT copied the code instead of the run: " .. got:sub(1, 60))
      return true
    end, note = "the run is on the clipboard", timeout = 5 })

add({ orient = "portrait" })
add({ wait = 0.6 })
add({ until_ = function(app)
      local s = pg(app)
      local code, out = s.code_rect, s.out_rect
      if code and out then
        print(("portrait: code y=%d h=%d, out y=%d h=%d"):format(code.y, code.h, out.y, out.h))
        check(out.y >= code.y + code.h,
          "upright put the output beside the code instead of under it")
      end
      return true
    end, note = "output under the code, upright", timeout = 5 })
add({ shot = "P8-code-output-under.png" })
add({ orient = "landscape" })
add({ wait = 0.5 })

-- ESC leaves CODE, not the screen.
add({ key = "escape" })
add({ until_ = function(app)
      local s = pg(app)
      if not s then check(false, "ESC left the playground instead of leaving CODE"); return true end
      return s.big == false
    end, note = "ESC came back to the framed screen", timeout = 5 })

-- The search box: shown once there are enough pads, and it narrows the list.
add({ until_ = function(app)
      local s = pg(app)
      -- Six pads, without saving six times: the list is what the box reads.
      s.snippets = {}
      for i = 1, 6 do
        s.snippets[i] = { id = "pg_" .. i, name = (i == 3) and "kettle" or ("pad " .. i),
          lang = "rust" }
      end
      return true
    end, timeout = 5 })
add({ wait = 0.3 })
add({ until_ = function(app)
      local s = pg(app)
      check(s.find_rect ~= nil, "no search box with six pads in the list")
      check(#s:visible_snippets() == 6, "an empty query hides pads")
      s.query = "kett"
      return true
    end, note = "the search box is there", timeout = 5 })
add({ wait = 0.3 })
add({ until_ = function(app)
      local hits = pg(app):visible_snippets()
      check(#hits == 1, ("the query matched %d pads, not 1"):format(#hits))
      check(hits[1].brief.name == "kettle", "the wrong pad matched")
      -- And the index is the one `load` wants, not the position in the view.
      check(hits[1].index == 3, "a filtered row would open the wrong pad")
      return true
    end, note = "the query narrows the list", timeout = 5 })
add({ shot = "P6-playground-search.png" })
add({ until_ = function(app) pg(app).query = ""; return true end, timeout = 3 })

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
