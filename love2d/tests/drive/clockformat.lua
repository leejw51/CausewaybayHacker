-- The clock and FORMAT, from the wire.
--
--   make -C love2d drive SCRIPT=tests/drive/clockformat.lua
--
-- The clock: `opened_at` and `deadline_at` are the **server's**, exactly as
-- `quest.get` returned them. Only the client's view of *now* is moved, by
-- re-pinning `Clock.set_source` — which is the one honest way to see all four
-- registers of a ten-minute limit inside one run. Nothing about the pair is
-- invented, and `calm` is captured with no shift at all.
--
-- FORMAT: real `rustfmt`, on deliberately untidy source, with the caret
-- checked across the replacement.

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
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "categories" and app.scene.categories end, timeout = 10 })
add({ key = "down" })
add({ key = "down" })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end, timeout = 12 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
      note = "a timed hacker quest", timeout = 18 })
add({ wait = 1.0 })

add({ until_ = function(app)
      local q = app.scene.quest
      print(("wire: %s  opened_at=%s  deadline_at=%s  time_limit_s=%s"):format(
        q.id, tostring(q.opened_at), tostring(q.deadline_at), tostring(q.time_limit_s)))
      return q.deadline_at ~= nil and q.opened_at ~= nil
    end, note = "the server stamped the pair", timeout = 10 })

--- `want` is the remaining time to photograph. The shift is worked out from
--- what the server's deadline actually leaves, because this quest may have
--- been opened minutes ago by an earlier run — the pair is stamped once and
--- never re-stamped (§4.8b), which is the whole point of it.
local function register(want, tag)
  add({ until_ = function(app)
        local Clock = require("src.clock")
        -- Move only *now*. The deadline is the server's, untouched.
        Clock.shift(0)
        local live = Clock.read(app.scene.quest)
        Clock.shift(live.remaining - want)
        app.scene.clock_arrived = nil
        app.scene.clock_phase = nil
        app.scene:tick_clock()
        local st = Clock.read(app.scene.quest)
        print(("%-9s %-7s phase=%-9s remaining=%.0fs   (now shifted %+ds)"):format(
          tag, Clock.format(st), st.phase, st.remaining, Clock.shifted()))
        return true
      end, timeout = 5 })
  add({ wait = 0.45 })
  add({ shot = "W-" .. tag .. ".png" })
end

register(540, "calm")        -- nine minutes left
register(100, "warning")     -- inside 25% of a ten-minute limit
register(30, "urgent")       -- inside 8%
register(-95, "overtime")    -- a minute and a half past

-- Put the clock back where it belongs before touching anything else.
add({ until_ = function(app)
      require("src.clock").shift(0)
      app.scene.clock_phase = nil
      return true
    end, timeout = 3 })

add({ note = "FORMAT, against the real rustfmt" })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = "fn main(){let nums=vec![2,7,11,15];let target=9;for i in 0..nums.len(){" })
add({ key = "return" })
add({ text = "for j in i+1..nums.len(){if nums[i]+nums[j]==target{println!(\"{} {}\",i,j);}}" })
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })
add({ key = "return" })
add({ key = "tab", mods = { shift = true } })
add({ text = "}" })

add({ until_ = function(app)
      local ed = app.scene.editor
      -- Park the caret inside a line the formatter is certain to re-indent,
      -- just after `target` on the `let target=9;` part of line 1.
      local line = ed.lines[1] or ""
      local at = line:find("target=9", 1, true)
      ed:goto_position(1, at + 6)          -- between "target" and "=9"
      -- **Document** ink, not line ink: the whole point of the anchor is that
      -- it survives a line being split, so counting within one line would be
      -- measuring the wrong thing and reporting a false alarm.
      local document = 0
      for i = 1, ed.line - 1 do document = document + #(ed.lines[i]:gsub("%s", "")) end
      document = document + #(line:sub(1, ed.col - 1):gsub("%s", ""))
      app.caret = {
        line = ed.line, col = ed.col, ink = document,
        after = line:sub(ed.col, ed.col + 1),
      }
      print(("before: line %d col %d, %d document ink before, next two [%s]"):format(
        app.caret.line, app.caret.col, app.caret.ink, app.caret.after))
      print("source before:\n" .. ed:text())
      return true
    end, timeout = 5 })
add({ shot = "W-format-before.png" })

add({ key = "f2" })
add({ until_ = function(app)
      local q = app.scene
      if q.formatting then return false end
      return q.format_note ~= nil or q.format_problem ~= nil
    end, note = "code.format answered", timeout = 40 })
add({ until_ = function(app)
      local q = app.scene
      local ed = q.editor
      print(("format: note=%s problem=%s unsupported=%s"):format(
        tostring(q.format_note), tostring(q.format_problem), tostring(q.format_unsupported)))
      print("source after:\n" .. ed:text())
      local line = ed:current_line()
      local document = 0
      for i = 1, ed.line - 1 do document = document + #(ed.lines[i]:gsub("%s", "")) end
      document = document + #(line:sub(1, ed.col - 1):gsub("%s", ""))
      local ink = document
      local after = line:sub(ed.col, ed.col + 1)
      print(("after:  line %d col %d, %d document ink before, next two [%s]"):format(
        ed.line, ed.col, ink, after))
      if q.format_unsupported then print("FAIL: FORMAT greyed itself against a server that has it") end
      if ink ~= app.caret.ink then
        print(("NOTE: ink before the caret moved %d -> %d"):format(app.caret.ink, ink))
      end
      -- The only question that matters: is it still before the same `=`?
      if after:sub(1, 1) ~= app.caret.after:sub(1, 1) then
        print(("FAIL: the caret is now before [%s], was [%s]"):format(after, app.caret.after))
      else
        print("caret: still immediately before the same character")
      end
      return true
    end, timeout = 5 })
add({ wait = 0.4 })
add({ shot = "W-format-after.png" })

add({ note = "and one undo puts it back" })
add({ key = "z", mods = { ctrl = true } })
add({ until_ = function(app)
      print("after undo:\n" .. app.scene.editor:text())
      return true
    end, timeout = 3 })

add({ note = "half-written source is not an error" })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = "fn main() { let x = ;" })
add({ until_ = function(app)
      app.scene.format_note = nil
      app.scene.format_problem = nil
      return true
    end, timeout = 3 })
add({ key = "f2" })
add({ until_ = function(app)
      local q = app.scene
      if q.formatting then return false end
      if not (q.format_note or q.format_problem) then return false end
      print(("unparseable: note=%s problem=%s"):format(
        tostring(q.format_note), tostring(q.format_problem)))
      print("buffer still: [" .. q.editor:text() .. "]")
      return true
    end, note = "the formatter complained and the buffer was left alone", timeout = 40 })
add({ wait = 0.4 })
add({ shot = "W-format-problem.png" })
add({ quit = true })
return steps
