-- The playground's old computers: NORMAL, APPLE ][, MSX and AMIGA.
--
--   make -C love2d drive SCRIPT=tests/drive/computer.lua ARGS="--home $(mktemp -d)"
--
-- Walks the COMPUTER button round the cycle on the framed bench and in CODE,
-- landscape and then upright, with a picture of each machine booting and of
-- each one settled; puts a program that does not compile through the Amiga
-- to see the Guru; and checks the things a picture cannot: that the quest
-- palette was never touched, that THEME is dim under a machine, that the tube
-- compiled, and that the glass sits inside the window in both orientations.

local Theme = require("src.theme")
local Computer = require("src.computer")
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
local function centre(r) return { r.x + r.w / 2, r.y + r.h / 2 } end
local function press(id)
  return function(app)
    local s = pg(app)
    local rects = s.big and s.big_rects or s.bench_rects or {}
    local r = rects[id]
    if not r then error("no " .. id .. " button on screen", 0) end
    return centre(r)
  end
end
local theme_code = Theme.code

local function inside_window(app, what)
  local s = pg(app)
  local g = s.glass_rect
  local L = require("src.layout")
  check(g and g.x >= 0 and g.y >= 0 and g.x + g.w <= L.vw and g.y + g.h <= L.vh,
    what .. ": the glass leaves the window")
  check(g and g.h > 60, what .. ": the glass is " .. tostring(g and g.h) .. " px tall")
  for id, r in pairs((s.big and s.big_rects) or s.bench_rects or {}) do
    check(r.x >= 0 and r.x + r.w <= L.vw + 1 and r.y + r.h <= L.vh,
      what .. ": " .. id .. " is off the window")
  end
end

--- The cycle, from NORMAL, taking a picture of each machine.
local function walk(prefix, orient)
  for _, machine in ipairs({ "apple2", "msx", "amiga" }) do
    add({ click = press("computer") })
    add({ until_ = function() return Computer.get() == machine end,
          note = machine, timeout = 5 })
    add({ wait = 1.3 })
    add({ shot = ("%s-%s-%s-boot.png"):format(prefix, orient, machine) })
    add({ wait = 2.8 })
    add({ until_ = function(app)
          local s = pg(app)
          check(Theme.code == theme_code, "the theme's code palette was replaced")
          check(s.retro and s.retro.ok == true, "no tube on " .. machine)
          local rects = s.big and s.big_rects or s.bench_rects
          check(rects.theme ~= nil, "no THEME button")
          inside_window(app, prefix .. " " .. orient .. " " .. machine)
          return true
        end, timeout = 3 })
    add({ shot = ("%s-%s-%s.png"):format(prefix, orient, machine) })
  end
  -- And back to NORMAL: the tube powers off.
  add({ click = press("computer") })
  add({ until_ = function() return Computer.get() == "normal" end, timeout = 5 })
  add({ wait = 0.7 })
end

add({ orient = "landscape" }) add({ resize = { 1280, 720 } }) add({ wait = 0.6 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      note = "login, or already resumed", timeout = 20 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = function(app) return app.scene_name == "login" end })
add({ key = "return", when = function(app) return app.scene_name == "login" end })
add({ until_ = function(app) return app.scene_name == "lands" end, note = "signed in", timeout = 30 })
add({ until_ = function(app) app:go("playground"); return true end, timeout = 5 })
add({ until_ = function(app) return pg(app) ~= nil end, note = "the playground", timeout = 10 })
add({ wait = 0.8 })
add({ until_ = function()
      Computer.set("normal")
      return true end, timeout = 3 })
add({ shot = "C0-landscape-normal.png" })

walk("C1", "landscape")

-- The Guru: a program that does not compile, on the Amiga, in CODE.
add({ click = function(app) return centre(pg(app).code_button_rect) end })
add({ until_ = function(app) return pg(app).big end, note = "CODE", timeout = 5 })
walk("C2", "landscape")
add({ click = press("computer") }) add({ click = press("computer") })
add({ click = press("computer") })
add({ until_ = function() return Computer.get() == "amiga" end, timeout = 5 })
add({ wait = 3.5 })
add({ until_ = function(app)
      local s = pg(app)
      s.editor:set_text("fn main() {\n    let x: i32 = \"no\";\n}\n")
      s:run()
      return true end, timeout = 3 })
add({ until_ = function(app) return pg(app).result ~= nil end, note = "the run", timeout = 60 })
add({ wait = 0.6 })
add({ until_ = function(app)
      local s = pg(app)
      check(s.result.outcome ~= "compile_error" or s.retro.alert ~= nil,
        "a program that did not compile put nothing on the Amiga's tube")
      return true end, timeout = 3 })
add({ shot = "C3-landscape-amiga-guru.png" })
add({ wait = 3.4 })
add({ shot = "C3-landscape-amiga-output.png" })

-- Upright: the same walk, CODE and then the bench.
add({ until_ = function() Computer.set("normal"); return true end, timeout = 3 })
add({ orient = "portrait" }) add({ resize = { 720, 1280 } }) add({ wait = 1 })
add({ shot = "C4-portrait-code-normal.png" })
walk("C4", "portrait")
add({ key = "escape" })
add({ until_ = function(app) return not pg(app).big end, note = "the bench", timeout = 5 })
add({ wait = 0.5 })
add({ shot = "C5-portrait-bench-normal.png" })
walk("C5", "portrait")

add({ until_ = function()
      Computer.set("normal")
      print("computer: " .. (fail and "FAILED" or "0 failures"))
      if fail then error("computer drive failed", 0) end
      return true
    end, timeout = 3 })
add({ quit = true })
return steps
