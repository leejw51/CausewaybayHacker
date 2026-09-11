-- PROTOCOL §4.8's `draft`, played rather than asserted.
--
--   make -C love2d drive SCRIPT=tests/drive/draft.lua
--
-- Type into a quest, press RUN, walk back to the map, walk back in — the text
-- must be there. Then run this **again**: the second launch types nothing and
-- still finds it, which is the half that proves the draft lives on the server
-- and not in this process. `tests/drive/solve.lua` is its other half.
--
-- One account for both launches, or the check proves nothing: a draft is per
-- player, and a different mnemonic is a different player. Run it with its own
-- client home each time —
--
--   make -C love2d drive SCRIPT=tests/drive/draft.lua ARGS="--home $(mktemp -d)"
--
-- — so the client resumes nothing, types the phrase, and carries no local
-- state whatsoever between the two launches. Whatever comes back came back
-- from the server.

local MNEMONIC = "february dial color toward gas rough divorce crack beauty opera vote never"

-- Deterministic on purpose: the second launch has to know what to look for
-- without having typed it.
local MARKER = "draft marker 4711"
local SOURCE = 'fn main() {\nprintln!("' .. MARKER .. '");'

local function scene(name)
  return function(app) return app.scene_name == name end
end
local function on_login(app) return app.scene_name == "login" end

local steps = {}
local function add(t) steps[#steps + 1] = t end

add({ orient = "landscape" })
add({ wait = 0.6 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      timeout = 15 })
add({ text = MNEMONIC, when = on_login })
add({ key = "return", when = on_login })
add({ until_ = scene("lands"), note = "signed in", timeout = 25 })
add({ until_ = function(app)
      print("signed in as " .. tostring(app.session:short_address()))
      return true
    end, timeout = 5 })
add({ until_ = function(app) return app.scene.lands ~= nil end, timeout = 10 })
add({ key = "return" })
add({ until_ = scene("categories"), timeout = 10 })
add({ until_ = function(app) return app.scene.categories ~= nil end, timeout = 10 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
      note = "the map", timeout = 10 })

add({ until_ = function(app)
      app.scene.cursor = 1
      app.scene.at = 1
      app.scene.walk = nil
      return true
    end, timeout = 3 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
      note = "in the editor", timeout = 15 })

-- What the server said before anything on this run touched it.
add({ until_ = function(app)
      local q = app.scene.quest
      app.probe_quest_id = q.id
      local draft = q.draft
      print(("quest.get %s: draft=%s (%d bytes)   starter=%d bytes")
        :format(tostring(q.id),
          draft == nil and "null" or "present",
          draft and #tostring(draft) or 0,
          #tostring(q.starter or "")))
      local opened = app.scene.editor:text()
      if draft then
        if opened ~= draft then
          print("FAIL: the editor did not open on the draft")
          return false
        end
        print("client: the editor opened on the DRAFT — this is a returning visit"
          .. (opened:find(MARKER, 1, true) and ", and it is the one this script left"
            or ""))
        app.probe_returning = true
      else
        print("client: no draft yet — the editor opened on the starter (first visit)")
      end
      return true
    end, note = "draft ?? starter", timeout = 10 })
add({ wait = 0.4 })
add({ shot = "D1-quest-opened.png" })

-- Type something that is unmistakably the player's, and RUN. There is no save
-- button and there is not supposed to be one: the run is the save.
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = SOURCE })
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ until_ = function(app)
      app.probe_typed = app.scene.editor:text()
      print("client: typed " .. #app.probe_typed .. " bytes, pressing RUN")
      return true
    end, timeout = 3 })
add({ key = "f5" })
add({ until_ = function(app)
      if app.scene.run_attempt or app.scene.error then return true end
      return false
    end, note = "RUN came back", timeout = 120 })
add({ until_ = function(app)
      local a = app.scene.run_attempt
      print(("RUN: %s"):format(a and ("mode=" .. tostring(a.mode)
        .. " verdict=" .. tostring(a.verdict)
        .. " attempt=" .. tostring(a.id))
        or ("no attempt — " .. tostring(app.scene.error))))
      print("client: nothing was saved by this client. The run WAS the save.")
      return true
    end, timeout = 5 })
add({ wait = 0.4 })
add({ shot = "D2-after-run.png" })

-- Out to the map and back in. The scene is rebuilt, so the editor it comes
-- back with is whatever `quest.get` says — nothing is carried in memory.
add({ key = "escape" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
      note = "back on the map", timeout = 10 })
add({ wait = 0.5 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
      note = "back in the quest", timeout = 15 })
add({ until_ = function(app)
      local got = app.scene.editor:text()
      local draft = app.scene.quest.draft
      print(("came back: draft=%s  editor=%d bytes  marker=%s")
        :format(draft and (#tostring(draft) .. " bytes") or "null",
          #got, tostring(got:find(MARKER, 1, true) ~= nil)))
      if got ~= app.probe_typed then
        print("FAIL: the text that came back is not the text that was typed")
        print("      wanted: " .. tostring(app.probe_typed))
        print("      got:    " .. got)
        return false
      end
      print("PASS: the quest reopened on what the player left, with no save button")
      return true
    end, note = "the draft came back", timeout = 10 })
add({ wait = 0.4 })
add({ shot = "D3-draft-restored.png" })

-- A long program, and the last line of it. The button band is two rows deep
-- in English now; the editor has to know that, or the caret goes behind
-- SOLVE on line 60 and the player types where they cannot see.
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = function()
      local out = {}
      for i = 1, 60 do out[#out + 1] = ("let v%d = %d;"):format(i, i) end
      return table.concat(out, "\n")
    end })
add({ until_ = function(app)
      local sc = app.scene
      if not sc.editor_rect or not sc.solve_rect then return false end
      local top = math.min(sc.solve_rect.y, sc.run_rect.y)
      local caret_y = sc.editor_rect.y + 6
        + (sc.editor.line - sc.editor.scroll - 1) * sc.line_h
      print(("long program: %d lines, caret on %d, scroll %d, %d rows visible")
        :format(sc.editor:line_count(), sc.editor.line, sc.editor.scroll,
          sc.visible_rows or -1))
      print(("caret row %d..%d   the button band starts at %d")
        :format(caret_y, caret_y + sc.line_h, top))
      if caret_y + sc.line_h > top then
        print("FAIL: the caret line is behind the buttons")
        return false
      end
      print("PASS: the last line of a long program clears the button band")
      return true
    end, note = "the caret is not behind a button", timeout = 20 })
add({ wait = 0.3 })
add({ shot = "D4-long-program.png" })

add({ until_ = function(app)
      print(("\nsummary: quest=%s  this launch was a %s visit")
        :format(tostring(app.probe_quest_id),
          app.probe_returning and "RETURNING" or "first"))
      print("run this script a second time: the second launch types nothing"
        .. " before the first check and must report a DRAFT.\n")
      return true
    end, timeout = 3 })
add({ quit = true })

return steps
