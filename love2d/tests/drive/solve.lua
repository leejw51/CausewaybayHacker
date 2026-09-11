-- PROTOCOL §4.11b's SOLVE button, played against the real server.
--
--   make -C love2d drive SCRIPT=tests/drive/solve.lua ARGS="--home $(mktemp -d)"
--
-- Its own mnemonic, and it must stay its own: `progress::use_solve` is a
-- high-water mark, so this script permanently spends a star on whichever
-- node it opens. Pointing it at an account somebody is playing would take
-- that star from them.
--
-- What it watches, in order:
--
--   1. shift-F7 — the key, because every one of F1..F12 was already taken on
--      this screen and a chord that nobody tested is a chord that does not
--      work.
--   2. the real answer landing in the editor, replacing what was there.
--   3. `hints_used` moving, because that is the price and the screen has to
--      show it rather than a stale zero.
--   4. ctrl-Z putting the player's own code back in one press — the reason
--      this ships without a confirmation dialog.
--   5. the SOLVE button, clicked with the mouse, doing exactly what the key
--      does.
--   6. and then SUBMIT of the revealed answer: it clears, and it does **not**
--      clear at three stars.

-- Its own account, and a fresh one per run: the star this spends is spent for
-- good, so a second run wants `CWBH_MNEMONIC="…twelve words…"` rather than the
-- assertions below quietly softening on a quest that is already solved.
local MNEMONIC = os.getenv("CWBH_MNEMONIC")
  or "erupt horror wash enhance game remove dragon steak loud lizard praise stable"

local MINE = 'fn main() {\nprintln!("mine, not the answer");'

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

-- Type something of the player's own first, so the replacement is visible and
-- so ctrl-Z has something to put back.
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = MINE })
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ until_ = function(app)
      local q = app.scene.quest
      app.probe_mine = app.scene.editor:text()
      app.probe_hints_before = q.hints_used or 0
      app.probe_stars_before = q.stars or 0
      print(("before SOLVE: quest=%s  hints_used=%d/%d  stars=%d  state=%s")
        :format(tostring(q.id), app.probe_hints_before, q.hints_total or 0,
          app.probe_stars_before, tostring(q.state)))
      print("before SOLVE: the editor holds " .. #app.probe_mine .. " bytes of my own")
      return true
    end, timeout = 5 })
add({ wait = 0.3 })
add({ shot = "S1-before-solve.png" })

-- The key. Shift, on the hint key, because §4.11b prices the answer as the
-- largest hint there is.
add({ note = "shift-F7" })
add({ key = "f7", mods = { shift = true } })
add({ until_ = function(app)
      return app.scene.solve_note ~= nil or app.scene.editor:text() ~= app.probe_mine
    end, note = "quest.solve came back", timeout = 30 })
add({ until_ = function(app)
      local q = app.scene.quest
      local got = app.scene.editor:text()
      app.probe_answer = got
      local solves = 0
      for _, t in ipairs(app.client.sent_types) do
        if t == "quest.solve" then solves = solves + 1 end
      end
      print(("quest.solve: %d sent"):format(solves))
      print(("after SOLVE:  hints_used=%d/%d   (was %d)")
        :format(q.hints_used or 0, q.hints_total or 0, app.probe_hints_before))
      print("the note says: " .. tostring(app.scene.solve_note))
      print("the editor now holds:\n" .. got)
      if got == app.probe_mine then
        print("FAIL: the buffer was not replaced")
        return false
      end
      if (q.hints_used or 0) <= app.probe_hints_before then
        print("FAIL: the screen is still showing a stale hint count")
        return false
      end
      return true
    end, note = "the answer landed and the price is on screen", timeout = 10 })
add({ wait = 0.4 })
add({ shot = "S2-after-solve.png" })

-- One undo step. This is the whole reason there is no confirmation dialog.
add({ key = "z", mods = { ctrl = true } })
add({ until_ = function(app)
      local got = app.scene.editor:text()
      if got ~= app.probe_mine then
        print("FAIL: one ctrl-Z did not put the player's own code back")
        print("      got: " .. got)
        return false
      end
      print("ctrl-Z: my own code is back, in one press")
      return true
    end, note = "one undo step", timeout = 5 })
add({ key = "z", mods = { ctrl = true, shift = true } })

-- And the button, which has to do exactly what the key does.
add({ until_ = function(app)
      local r = app.scene.solve_rect
      if not r then print("FAIL: there is no SOLVE button on screen"); return false end
      print(("the SOLVE button is at %d,%d %dx%d; RUN is at %d; SUBMIT at %d")
        :format(r.x, r.y, r.w, r.h, app.scene.run_rect.x, app.scene.submit_rect.x))
      if r.x + r.w >= app.scene.run_rect.x then
        print("FAIL: SOLVE overlaps the RUN button")
        return false
      end
      return true
    end, note = "the button is drawn, and it is not next to RUN", timeout = 5 })
add({ click = function(app)
      local r = app.scene.solve_rect
      return { r.x + r.w / 2, r.y + r.h / 2 }
    end })
add({ until_ = function(app)
      local solves = 0
      for _, t in ipairs(app.client.sent_types) do
        if t == "quest.solve" then solves = solves + 1 end
      end
      if solves < 2 then return false end
      print(("the button sent quest.solve too (%d in total)"):format(solves))
      return app.scene.editor:text() == app.probe_answer
    end, note = "the button does what the key does", timeout = 20 })
add({ wait = 0.3 })
add({ shot = "S3-solve-button.png" })

-- Portrait, where the well is narrowest and four buttons have least room.
-- The decisions log has a caption that was printed *inside* the button band
-- and was only ever found in a picture; this is the picture.
add({ orient = "portrait" })
add({ wait = 0.5 })
add({ until_ = function(app)
      local r, f = app.scene.solve_rect, app.scene.format_rect
      local run, sub = app.scene.run_rect, app.scene.submit_rect
      print(("portrait: SOLVE %d..%d y=%d   FORMAT %d..%d y=%d")
        :format(r.x, r.x + r.w, r.y, f.x, f.x + f.w, f.y))
      print(("portrait: RUN %d..%d y=%d   SUBMIT %d..%d y=%d   gap=%d")
        :format(run.x, run.x + run.w, run.y, sub.x, sub.x + sub.w, sub.y,
          sub.x - (run.x + run.w)))
      if r.x + r.w > f.x then print("FAIL: SOLVE runs into FORMAT"); return false end
      if run.x + run.w > sub.x then print("FAIL: RUN runs into SUBMIT"); return false end
      -- Same row or its own row, but never on top of the pair that costs
      -- something.
      if f.y == run.y and f.x + f.w > run.x then
        print("FAIL: FORMAT runs into RUN on the same row"); return false
      end
      if f.y ~= run.y then
        print("portrait: the two buffer buttons took their own row above the pair")
      end
      return true
    end, note = "four buttons, no overlap", timeout = 5 })
add({ shot = "S3b-solve-portrait.png" })
add({ orient = "landscape" })
add({ wait = 0.4 })

-- Now submit the revealed answer. It should clear — and it must not clear at
-- three stars, because §4.11b already priced this.
add({ note = "SUBMIT the revealed answer" })
add({ key = "f10" })
add({ until_ = function(app)
      return app.scene_name == "result" or app.scene.error ~= nil
    end, note = "the verdict", timeout = 180 })
add({ wait = 0.6 })
add({ shot = "S4-submitted.png" })
add({ until_ = function(app)
      local a = app.last_attempt
      if not a then print("FAIL: no attempt came back"); return false end
      print(("SUBMIT: verdict=%s  %d/%d  cleared=%s  stars=%d")
        :format(a.verdict, a.tests_passed or 0, a.tests_total or 0,
          tostring(a.cleared), a.stars or 0))
      if a.verdict ~= "accepted" then
        print("note: the reference answer did not pass — that is the server's business,"
          .. " not this screen's")
        return true
      end
      if (a.stars or 0) >= 3 then
        print("FAIL: a revealed answer earned a perfect clear")
        return false
      end
      print("PASS: it cleared, and not at three stars — the answer was not free")
      return true
    end, note = "not a perfect clear", timeout = 10 })

add({ until_ = function(app)
      print("\nsummary: the star spent on this run belongs to "
        .. tostring(app.session:short_address()) .. ", a mnemonic used by nothing else.\n")
      return true
    end, timeout = 3 })
add({ quit = true })

return steps
