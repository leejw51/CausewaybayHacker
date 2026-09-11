-- The display buttons: how big they actually are, in every language and both
-- orientations.
--
--   make -C love2d drive SCRIPT=tests/drive/chips.lua
--
-- The report this exists to produce is three numbers per shape — the button
-- height, the size of the face its label is set in, and the width of the
-- widest chip — because "too small" was measured before it was fixed and has
-- to be measured after. It prints them for all six languages and takes the
-- frame in four of them, including the two whose strings run long.
--
-- It walks the **lands** screen, which is the screen the bug was reported
-- against: four controls, a wallet address, a scene hint and the connection
-- state, all on one strip.

local MNEMONIC =
  "legal winner thank year wave sausage worth useful legal winner thank yellow"

local steps = {}
local function add(t) steps[#steps + 1] = t end
local function scene(name)
  return function(app) return app.scene_name == name end
end

local rows = {}
local fail = false

local function measure(tag)
  return function(app)
    local UI = require("src.ui")
    local Layout = require("src.layout")
    local I18n = require("src.i18n")
    local r = app.display_rects
    if not r then
      print("FAIL: no display controls on " .. tag)
      fail = true
      return true
    end
    local widest, total, left = 0, 0, math.huge
    for _, id in ipairs({ "fullscreen", "orient", "font", "lang" }) do
      local box = r[id]
      if box then
        widest = math.max(widest, box.w)
        total = total + box.w
        left = math.min(left, box.x)
      end
    end
    -- The three properties a control has to have: it is on the canvas, it is
    -- at least as tall as the floor, and it is above the bottom edge.
    if left < 0 then
      print("FAIL: the cluster starts off the left edge at " .. left)
      fail = true
    end
    if r.font.h < UI.CHIP_MIN_H then
      print(("FAIL: a button is %d px tall, under the %d px floor")
        :format(r.font.h, UI.CHIP_MIN_H))
      fail = true
    end
    if r.lang.x + r.lang.w > Layout.vw then
      print("FAIL: the last button runs off the right edge")
      fail = true
    end
    rows[#rows + 1] = { tag = tag, h = r.font.h, widest = widest }
    print(("%-18s %-4s %5dx%-5d  button %2dpx tall, label %2dpx  widest chip %3dpx  "
      .. "cluster %3dpx  strip %2dpx (hint %d row%s)  hint %4d/%4d %s")
      :format(tag, I18n.lang, Layout.vw, Layout.vh, r.font.h,
        UI.lineHeight(UI.CHIP_SIZE), widest, total + 24, UI.footerHeight(),
        UI.hint_rows, UI.hint_rows == 1 and "" or "s",
        UI.textWidth(app.last_hint or "", UI.FOOTER_SIZE),
        (app.last_room or 0) * UI.hint_rows,
        UI.hint_clipped and "CLIPPED" or "fits"))
    return true
  end
end

local function set_lang(code)
  return function(app)
    app:set_lang(code)
    return true
  end
end

add({ orient = "landscape" })
add({ wait = 0.8 })
-- Past the title card, which waits on purpose.
add({ until_ = function(app) return app.scene_name == "title" or app.scene_name == "login"
      or app.session.authed end, timeout = 12 })
add({ key = "space", when = scene("title") })
add({ wait = 0.5 })
add({ key = "space", when = scene("story") })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      timeout = 10 })
add({ text = MNEMONIC, when = scene("login") })
add({ key = "return", when = scene("login") })
add({ until_ = scene("lands"), note = "signed in", timeout = 25 })
add({ wait = 0.8 })

for _, code in ipairs({ "en", "ko", "yue", "zh", "ja", "cs" }) do
  local shoot = (code == "en" or code == "ko" or code == "cs" or code == "yue")
  add({ until_ = set_lang(code), timeout = 5 })
  add({ wait = 0.35 })
  add({ until_ = measure("lands/land"), timeout = 5 })
  add({ shot = "C-" .. code .. "-land.png", when = function() return shoot end })
  add({ orient = "portrait" })
  add({ wait = 1.0 })
  add({ until_ = measure("lands/port"), timeout = 5 })
  add({ shot = "C-" .. code .. "-port.png", when = function() return shoot end })
  add({ orient = "landscape" })
  add({ wait = 1.0 })
end

-- And the same cluster at the largest type step, which is where a control
-- row measured from its own type can run away with the screen.
add({ until_ = set_lang("en"), timeout = 5 })
add({ key = "f12" })
add({ key = "f12" })
add({ key = "f12" })
add({ wait = 0.5 })
add({ until_ = measure("lands/land 4-4"), timeout = 5 })
add({ shot = "C-largest-type.png" })
-- Portrait at the largest step is the shape that broke last time: four chips
-- measured from a three-row strip came to more than a 720-wide canvas, `x`
-- went negative, and the whole cluster sat off the left edge — visible as a
-- sliver, clickable nowhere. `measure` fails on a negative x, so this is the
-- regression case rather than a screenshot.
add({ orient = "portrait" })
add({ wait = 1.2 })
add({ until_ = measure("lands/port 4-4"), timeout = 5 })
add({ shot = "C-largest-type-port.png" })
add({ orient = "landscape" })
add({ wait = 1.0 })
add({ key = "f12" })
add({ wait = 0.4 })

add({ until_ = function()
      if fail then
        print("drive: FAILED")
        love.event.quit(1)
        return true
      end
      local min_h = math.huge
      for _, row in ipairs(rows) do min_h = math.min(min_h, row.h) end
      print(("PASS: %d shapes measured, the shortest display button is %d px")
        :format(#rows, min_h))
      return true
    end, timeout = 3 })
add({ quit = true })

return steps
