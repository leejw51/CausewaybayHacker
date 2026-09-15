-- Every screen, in a script the Latin faces cannot draw.
--
--   make -C love2d drive SCRIPT=tests/drive/language.lua
--   make -C love2d drive SCRIPT=tests/drive/language.lua LANG=ja
--
-- CJK glyphs are **double width** and Czech words are longer than English
-- ones, so anything that was measured in characters rather than pixels breaks
-- here and nowhere else. This walks every screen in Korean, in both
-- orientations and in fullscreen, and prints the measured width of each
-- screen's own footer hint against the room it has — the one number that says
-- whether a translated string fits.
--
-- It also prints the **cap height in screen pixels** at each shape, because
-- that is the number the "the type is too small" report was actually about.

local WANT = os.getenv("LANG_CODE") or "ko"

local steps = {}
local function add(t) steps[#steps + 1] = t end
local function scene(name)
  return function(app) return app.scene_name == name end
end

local seen = {}

--- Every English string the interface actually asked to translate, and
--- whether this language had one.
---
--- `tests/test_i18n.lua` reads the sources, which cannot see
--- `I18n.t(BLURB[cat.category])` — the key is in a module-level table and
--- only exists at run time. That indirection is how the land blurbs, the
--- category blurbs, the three AI mode blurbs, the search mode labels and the
--- playground's five outcome words all stayed English through a pass that
--- believed it had translated everything. A static scan structurally cannot
--- catch it; walking the screens and recording what was asked for can.
local untranslated = {}
local function watch_i18n()
  local I18n = require("src.i18n")
  if I18n.__watched then return end
  I18n.__watched = true
  local real = I18n.t
  -- English on purpose: proper nouns and a key name.
  --
  -- **The land names come from `Land.NAME` rather than being listed here.**
  -- `RUST` and `GO` were written out when there were two lands, and `C++` and
  -- `PYTHON` arriving later were reported as English on a Korean screen by a
  -- check that was right about every other string. A fifth land would have
  -- done it again.
  local english = { CAUSEWAYBAY = true, HACKER = true, TAB = true }
  for _, land in ipairs(require("src.land").ORDER) do
    english[require("src.land").NAME[land]] = true
  end
  I18n.t = function(english_key, ...)
    -- Only once the switch has happened. The login screen draws several
    -- frames in English before the drive sets the language, and counting
    -- those would report every string on it as missing.
    if I18n.lang ~= "en" and type(english_key) == "string" and english_key ~= ""
      and not english[english_key] then
      local tr = I18n.TR[I18n.lang]
      if not (tr and tr[english_key]) then untranslated[english_key] = true end
    end
    return real(english_key, ...)
  end
end

--- What the type actually measures, on screen, right now.
local function measure(tag)
  return function(app)
    local Layout = require("src.layout")
    local Assets = require("src.assets")
    local UI = require("src.ui")
    local I18n = require("src.i18n")
    -- A capital letter's ink height is what a reader reacts to; the font's
    -- reported height includes leading. Press Start 2P has no descenders, so
    -- for it the two are the same — measured rather than assumed all the same.
    local body = Assets.font(Layout.ui(10))
    local cap = body:getHeight()
    local on_screen = cap * Layout.scale
    local row = {
      tag = tag, scene = app.scene_name, lang = I18n.lang,
      vw = Layout.vw, vh = Layout.vh, scale = Layout.scale,
      full = Layout.fullscreen, mode = Layout.mode,
      cap = cap, screen_cap = on_screen,
      pct = 100 * on_screen / math.max(1, Layout.vh * Layout.scale),
      -- Does this screen's own hint fit the room the footer gives it?
      hint_w = UI.textWidth(app.last_hint or "", 8),
      -- The room the footer actually gave it, which the footer now reports
      -- rather than this script re-deriving: the display buttons have a row
      -- of their own, so the hint is no longer measured against what is left
      -- beside them — it gets the width beside the connection badge, once per
      -- row. `app.last_reserve` is still the cluster's width and is no longer
      -- subtracted from any of this.
      room = (app.last_room or 0) * UI.hint_rows,
      rows = UI.hint_rows,
      clipped = UI.hint_clipped,
    }
    seen[#seen + 1] = row
    print(("%-22s %-11s %-3s %5dx%-5d s=%.2f full=%-5s cap=%2dpx on-screen=%3dpx (%.2f%%)  hint %4d/%4d %s")
      :format(tag, tostring(row.scene), row.lang, row.vw, row.vh, row.scale,
        tostring(row.full), row.cap, row.screen_cap, row.pct,
        row.hint_w, row.room, row.clipped and "CLIPPED" or "fits"))
    return true
  end
end

local function chip(name)
  return function(app)
    local r = app.display_rects and app.display_rects[name]
    assert(r, "no display rect for " .. name)
    return { r.x + r.w / 2, r.y + r.h / 2 }
  end
end

add({ until_ = function() watch_i18n(); return true end, timeout = 3 })
add({ orient = "landscape" })
add({ wait = 0.8 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      timeout = 15 })

-- Switch before signing in: the login screen is one of the screens.
add({ until_ = function(app)
      app:set_lang(WANT)
      print("language set to " .. require("src.i18n").name())
      return true
    end, timeout = 5 })
add({ until_ = measure("login/land"), when = scene("login"), timeout = 5 })
add({ shot = "L-login.png", when = scene("login") })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = scene("login") })
add({ key = "return", when = scene("login") })
add({ until_ = scene("lands"), note = "signed in", timeout = 25 })
add({ wait = 0.6 })

local function sweep(tag)
  add({ until_ = measure(tag .. "/land"), timeout = 5 })
  add({ shot = "L-" .. tag .. "-land.png" })
  add({ click = chip("orient") })                 -- landscape -> portrait
  add({ wait = 1.1 })
  add({ until_ = measure(tag .. "/port"), timeout = 5 })
  add({ shot = "L-" .. tag .. "-port.png" })
  add({ click = chip("fullscreen") })
  add({ wait = 1.8 })
  add({ until_ = measure(tag .. "/port+full"), timeout = 5 })
  add({ shot = "L-" .. tag .. "-port-full.png" })
  add({ click = chip("fullscreen") })
  add({ wait = 1.8 })
  add({ click = chip("orient") })                 -- portrait -> automatic
  add({ wait = 0.8 })
  add({ click = chip("orient") })                 -- automatic -> landscape
  add({ wait = 1.1 })
end

sweep("lands")

add({ key = "return" })
add({ until_ = scene("categories"), timeout = 15 })
add({ wait = 0.5 })
sweep("categories")

add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
      timeout = 15 })
add({ wait = 0.5 })
sweep("map")

add({ key = "t" })
add({ until_ = scene("stats"), timeout = 15 })
add({ wait = 0.8 })
sweep("stats")
add({ key = "escape" })
add({ until_ = scene("map"), timeout = 10 })

add({ key = "a" })
add({ until_ = scene("ai"), timeout = 15 })
add({ wait = 0.6 })
sweep("ai")
add({ key = "escape" })
add({ until_ = scene("map"), timeout = 10 })

add({ key = "s" })
add({ until_ = scene("search"), timeout = 15 })
add({ wait = 0.6 })
sweep("search")
add({ key = "escape" })
add({ until_ = scene("map"), timeout = 10 })

add({ key = "p" })
add({ until_ = scene("playground"), timeout = 15 })
add({ wait = 0.6 })
sweep("playground")
add({ key = "escape" })
add({ until_ = scene("map"), timeout = 10 })

add({ until_ = function(app)
      for i, n in ipairs(app.scene.nodes) do
        if n.state ~= "locked" then app.scene.cursor = i; return true end
      end
      return true
    end, timeout = 3 })
add({ key = "return" })
add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
      timeout = 20 })
add({ wait = 0.6 })
sweep("quest")

-- The result screen. It is the screen a player sees after **every** submit,
-- and it was the one screen this sweep did not reach — so a wrong answer is
-- submitted on purpose to get there. Its offsets were the last in the client
-- still mixing measured heights with constants tuned against 18 px type.
add({ note = "a wrong answer, to reach the verdict screen in " .. WANT })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = 'fn main() {\n    println!("nope")\n}\n' })
add({ wait = 0.4 })
-- **SUBMIT, not RUN.** `F5` is RUN, and RUN is the endpoint this server does
-- not have — it answers "not on this server yet" and stays on the quest
-- screen, so a drive that waited for the result screen after `F5` waited for
-- ninety seconds and then failed. `tests/drive/slice.lua` predates that.
add({ key = "f10" })
add({ until_ = scene("result"), note = "the verdict came back", timeout = 120 })
add({ wait = 0.8 })
sweep("result")

add({ until_ = function()
    local ok = true
    local screens, clipped = {}, {}
    for _, row in ipairs(seen) do
      screens[row.scene] = true
      -- The footer's own answer, not a width comparison this script makes:
      -- `UI.wrap` collapses the runs of spaces a key list is spelled with, so
      -- the drawn line is narrower than the string it was measured from and a
      -- comparison here disagrees with what is on the screen.
      if row.clipped then
        clipped[#clipped + 1] = row.tag
      end
      if row.cap < 12 then
        print(("FAIL: %s draws body type at %d px — that is the bug this round is about")
          :format(row.tag, row.cap))
        ok = false
      end
      if row.lang ~= WANT then
        print("FAIL: " .. row.tag .. " lost the language")
        ok = false
      end
    end
    local n = 0
    for _ in pairs(screens) do n = n + 1 end
    if n < 9 then
      print("FAIL: only " .. n .. " screens were visited")
      ok = false
    end
    -- A clipped hint is reported, not failed: the footer clips on purpose and
    -- says so, and a language whose hint is longer than the strip is a fact
    -- about the language rather than a broken screen. It is the list that
    -- matters, so it is printed either way.
    print(("hints that clip in %s: %s"):format(WANT,
      #clipped > 0 and table.concat(clipped, ", ") or "none"))

    -- The keys that only exist at run time. This is a **failure**, not a
    -- report: an English sentence in the middle of a translated screen is
    -- the defect the round was asked to fix.
    local left = {}
    for key in pairs(untranslated) do left[#left + 1] = key end
    table.sort(left)
    if #left > 0 then
      print(("FAIL: %d strings were drawn in English on a %s screen:")
        :format(#left, WANT))
      for _, key in ipairs(left) do print("    " .. key) end
      ok = false
    else
      print(("every string the walk asked for exists in %s"):format(WANT))
    end
    if ok then
      print(("PASS: %d screens in %s, both orientations and fullscreen, "
        .. "body type 16 px and up"):format(n, WANT))
    end
    return ok
  end, note = "every screen drew the language", timeout = 5 })

add({ quit = true })

return steps
