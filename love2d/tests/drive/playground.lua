-- The playground (PROTOCOL §4.9c), against the real server.
--
--   make -C love2d drive SCRIPT=tests/drive/playground.lua
--
-- Mei's own desk: no quest, no tests, no verdict. What this checks is that it
-- behaves like that — a run that does not compile is described, not judged,
-- and nothing about it reaches the curriculum.

local function on_login(app) return app.scene_name == "login" end
local steps = {}
local function add(t) steps[#steps + 1] = t end

add({ orient = "landscape" })
add({ wait = 0.8 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end, timeout = 15 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = on_login })
add({ key = "return", when = on_login })
add({ until_ = function(app) return app.scene_name == "lands" end, note = "signed in", timeout = 25 })
add({ until_ = function(app) return app.scene.lands ~= nil end, timeout = 10 })

add({ note = "P — straight to the desk, without picking a land" })
add({ key = "p" })
add({ until_ = function(app) return app.scene_name == "playground" end,
      note = "the playground", timeout = 10 })
add({ until_ = function(app) return app.scene.snippets ~= nil end,
      note = "playground.list answered", timeout = 15 })
add({ wait = 0.6 })
add({ shot = "G1-playground.png" })

add({ note = "a program that prints, with stdin" })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = 'use std::io::Read;\nfn main() {\nlet mut s = String::new();\nstd::io::stdin().read_to_string(&mut s).unwrap();\nprintln!("read {}", s.trim());' })
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ key = "tab", mods = { ctrl = true } })          -- focus stdin
add({ text = "7" })
add({ key = "tab", mods = { ctrl = true } })
add({ key = "tab", mods = { ctrl = true } })          -- back to the editor
add({ key = "f5" })
add({ until_ = function(app) return app.scene.result ~= nil end,
      note = "playground.run came back", timeout = 90 })
add({ until_ = function(app)
      local r = app.scene.result
      print(("run: outcome=%s exit=%s compile=%dms run=%dms"):format(
        tostring(r.outcome), tostring(r.exit_code), r.compile_ms or 0, r.run_ms or 0))
      print("stdout: [" .. tostring(r.stdout):gsub("\n", "\\n") .. "]")
      return true
    end, timeout = 5 })
add({ wait = 0.5 })
add({ shot = "G2-playground-ran.png" })

add({ note = "now something broken ON PURPOSE — the whole point of a desk" })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = 'fn main() {\nlet s = String::from("x");\nlet t = s;\nprintln!("{}", s);' })
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ key = "f5" })
add({ until_ = function(app) return app.scene.result ~= nil
        and app.scene.result.outcome ~= "ok" end,
      note = "it did not compile", timeout = 90 })
add({ until_ = function(app)
      local r = app.scene.result
      print(("broken: outcome=%s diagnostics=%d"):format(
        tostring(r.outcome), r.diagnostics and #r.diagnostics or 0))
      for _, d in ipairs(r.diagnostics or {}) do
        print(("  %s [%s] %s"):format(tostring(d.kind), tostring(d.code),
          tostring(d.message):sub(1, 60)))
      end
      return true
    end, timeout = 5 })
add({ wait = 0.5 })
add({ shot = "G3-playground-broken.png" })

add({ note = "nothing about that reached the curriculum (§4.9c)" })
-- The claim is "no attempts row, no mistakes row, no effect on accuracy", and
-- the only way to check it is to look before and after. The broken program
-- above produced a real `borrow-after-move` — if a playground run fed the
-- curriculum, that is exactly the diagnostic that would show up.
add({ until_ = function(app)
      if app.stats_before then return true end
      app.session:request("stats.summary", {}, function(ok, p)
        if ok then app.stats_before = p end
      end)
      app.session:request("stats.mistakes", { limit = 20 }, function(ok, p)
        if ok then app.mistakes_before = #(p.mistakes or {}) end
      end)
      return false
    end, note = "stats sampled before", timeout = 15 })
add({ key = "f5" })
add({ until_ = function(app) return app.scene.result ~= nil and not app.scene.running end,
      note = "another broken run", timeout = 90 })
add({ wait = 1.0 })
add({ until_ = function(app)
      if app.stats_after then return true end
      app.session:request("stats.summary", {}, function(ok, p)
        if not ok then return end
        app.stats_after = p
        local before = app.stats_before
        print(("stats before: attempts=%d accuracy=%.3f"):format(
          before.attempts or 0, before.accuracy or 0))
        print(("stats after:  attempts=%d accuracy=%.3f"):format(
          p.attempts or 0, p.accuracy or 0))
        if (p.attempts or 0) ~= (before.attempts or 0) then
          print("FAIL: a playground run was counted as an attempt")
        else
          print("curriculum: untouched — no attempt, no accuracy change (§4.9c)")
        end
      end)
      app.session:request("stats.mistakes", { limit = 20 }, function(ok, p)
        if not ok then return end
        local now = #(p.mistakes or {})
        print(("mistake kinds before=%d after=%d"):format(app.mistakes_before or -1, now))
        if now ~= app.mistakes_before then
          print("FAIL: a playground run added a mistake row")
        end
      end)
      return false
    end, note = "stats compared", timeout = 20 })

add({ note = "save, list, reopen" })
add({ key = "s", mods = { ctrl = true } })
add({ until_ = function(app) return app.scene.snippet_id ~= nil end,
      note = "playground.save minted an id", timeout = 20 })
add({ until_ = function(app)
      print(("saved: id=%s name=%s"):format(
        tostring(app.scene.snippet_id), tostring(app.scene.name)))
      return app.scene.snippets ~= nil and #app.scene.snippets > 0
    end, note = "and it is in the list", timeout = 15 })
add({ wait = 0.5 })
add({ shot = "G4-playground-saved.png" })

add({ orient = "portrait" })
add({ resize = { 720, 1000 } })
add({ wait = 1.0 })
add({ shot = "G5-playground-portrait.png" })
add({ quit = true })
return steps
