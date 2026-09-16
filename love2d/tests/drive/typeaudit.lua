-- Every string this client draws, measured against the box it was drawn into.
--
--   make -C love2d drive SCRIPT=tests/drive/typeaudit.lua
--   make -C love2d drive SCRIPT=tests/drive/typeaudit.lua ARGS="--home $(mktemp -d)"
--   LANG_CODE=ja make -C love2d drive SCRIPT=tests/drive/typeaudit.lua
--
-- `typesize.lua` already watches the **canvas** edge, and that is the loudest
-- fault and not the common one. Type that is too big for its panel does not
-- leave the canvas: it is cut off by the scissor the panel set, and a watcher
-- looking at the canvas edge sees nothing at all. The web client had exactly
-- that fault in its scratchpad list — the rule under the title bar was drawn
-- larger than the title bar, and the clip swallowed the evidence.
--
-- So this wraps `UI.text` from the test side (no production change) and
-- compares every draw against **`love.graphics.getScissor()`** — the box the
-- client itself said that draw belonged in — as well as against the canvas.
-- Three things get reported:
--
--   * **cut** — the draw is wider or taller than the scissor it was made
--     under, so a player sees a sentence end in the middle of a word.
--   * **off** — the draw left the canvas, which is `typesize.lua`'s question,
--     asked here at the default type step in six languages instead of at four
--     type steps in one.
--   * **over** — a wrapped draw whose *limit* is wider than its scissor. That
--     one is a latent cut: the string fits today because it is short, and the
--     first translation that is not gets sliced.
--
-- One language per run, because a drive is one session; `LANG_CODE` picks it
-- and the loop over all six belongs in the caller. It signs in with BIP-39's
-- published test vector, so it needs the server.

local WANT = os.getenv("LANG_CODE") or "ko"

local MNEMONIC = "legal winner thank year wave sausage worth useful legal winner "
  .. "thank yellow"

local steps = {}
local function add(t) steps[#steps + 1] = t end
local function scene(name)
  return function(app) return app.scene_name == name end
end

--- Every draw that did not fit, keyed so one string reported on forty frames
--- is one line of output and not forty.
---
--- Keyed by the *string* rather than by the screen: the same label drawn in
--- the same place on every frame is one fault, and the worst overflow it ever
--- reached is the number worth having.
local bad = {}
local drawn = 0
local function note(kind, tag, text, size, by, box)
  local key = kind .. "\0" .. tag .. "\0" .. tostring(text):sub(1, 32)
  local row = bad[key]
  if not row or by > row.by then
    bad[key] = { kind = kind, tag = tag, text = tostring(text):sub(1, 32),
                 size = size, by = by, box = box }
  end
end

--- What is on screen right now, for whatever the next draw reports.
local where = "?"

local function watch_text()
  local UI = require("src.ui")
  local Layout = require("src.layout")
  local Assets = require("src.assets")
  if UI.__audited then return end
  UI.__audited = true
  local real = UI.text
  UI.text = function(text, x, y, size, color, align, width, ...)
    if type(text) == "string" and #text > 0 then
      drawn = drawn + 1
      local tag = ("%s/%s%s"):format(where, Layout.mode,
        Layout.fullscreen and "+full" or "")
      local sx, sy, sw, sh = love.graphics.getScissor()
      local box = sx and { x = sx, y = sy, w = sw, h = sh } or nil
      local lh = UI.lineHeight(size)
      if width then
        -- A wrapped draw cannot run past its own limit, so the question is
        -- whether the limit itself is honest about the box.
        if box and (x or 0) + width > box.x + box.w + 1 then
          note("over", tag, text, size,
            (x or 0) + width - (box.x + box.w), box)
        end
        -- Height still can: `printf` wraps as far down as it needs to.
        local _, lines = Assets.font(Layout.ui(size or 12)):getWrap(text, width)
        local tall = #lines * lh
        if box and (y or 0) + tall > box.y + box.h + 1 then
          note("cut", tag, text, size, (y or 0) + tall - (box.y + box.h), box)
        end
        if (y or 0) + tall > Layout.vh + 1 then
          note("off", tag, text, size, (y or 0) + tall - Layout.vh, box)
        end
      else
        local w = UI.textWidth(text, size)
        if box then
          if (x or 0) + w > box.x + box.w + 1 then
            note("cut", tag, text, size, (x or 0) + w - (box.x + box.w), box)
          end
          if (y or 0) + lh > box.y + box.h + 1 then
            note("cut", tag, text, size, (y or 0) + lh - (box.y + box.h), box)
          end
        end
        if (x or 0) + w > Layout.vw + 1 then
          note("off", tag, text, size, (x or 0) + w - Layout.vw, box)
        end
      end
    end
    return real(text, x, y, size, color, align, width, ...)
  end
end

--- Stand on a screen and let every frame after this draw under its name.
---
--- Only the **screen** is recorded here; the shape is read at draw time. A
--- sweep changes orientation after this step runs, so a tag that baked the
--- shape in labelled every portrait draw "landscape" — which is worse than no
--- label, because it is a label that looks right.
local function here(tag)
  return function()
    where = tag
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

--- One screen in both orientations and in fullscreen, the same three shapes
--- `language.lua` walks, because those are the three a player can produce.
local function sweep(tag)
  add({ until_ = here(tag), timeout = 5 })
  add({ wait = 0.5 })
  add({ click = chip("orient") })                 -- landscape -> portrait
  add({ wait = 1.1 })
  add({ until_ = here(tag), timeout = 5 })
  add({ wait = 0.5 })
  add({ click = chip("fullscreen") })
  add({ wait = 1.8 })
  add({ until_ = here(tag), timeout = 5 })
  add({ wait = 0.5 })
  add({ click = chip("fullscreen") })
  add({ wait = 1.8 })
  add({ click = chip("orient") })                 -- portrait -> automatic
  add({ wait = 0.8 })
  add({ click = chip("orient") })                 -- automatic -> landscape
  add({ wait = 1.1 })
end

add({ until_ = function() watch_text(); return true end, timeout = 3 })
add({ orient = "landscape" })
add({ wait = 0.8 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      timeout = 15 })

-- Switched before signing in, because the login card is one of the screens
-- and it is the one a new player sees first.
add({ until_ = function(app)
      app:set_lang(WANT)
      print("language: " .. require("src.i18n").name())
      return true
    end, timeout = 5 })
add({ until_ = here("login"), when = scene("login"), timeout = 5 })
add({ wait = 0.6 })
add({ text = MNEMONIC, when = scene("login") })
add({ key = "return", when = scene("login") })
add({ until_ = scene("lands"), note = "signed in", timeout = 25 })
add({ wait = 0.6 })

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

-- The verdict screen, which every submit ends on and which no walk reaches
-- without submitting something. A wrong answer is the cheapest way there.
add({ note = "a wrong answer, to reach the verdict screen in " .. WANT })
add({ key = "a", mods = { ctrl = true } })
add({ key = "backspace" })
add({ text = 'fn main() {\n    println!("nope")\n}\n' })
add({ wait = 0.4 })
-- **F10 is SUBMIT.** F5 is RUN, and RUN is an endpoint this server answers
-- "not on this server yet" to, so a drive that waits for the verdict screen
-- after F5 waits out its timeout on the quest screen. `language.lua` records
-- the same lesson; this hit it on its first run.
add({ key = "f10" })
add({ until_ = scene("result"), note = "the verdict came back", timeout = 120 })
add({ wait = 0.8 })
sweep("result")

add({ until_ = function()
      local rows = {}
      for _, r in pairs(bad) do rows[#rows + 1] = r end
      table.sort(rows, function(a, b) return a.by > b.by end)
      print("")
      print(("== %s: %d draws measured, %d that did not fit =="):format(WANT, drawn, #rows))
      for _, r in ipairs(rows) do
        print(("  %-4s %-22s %3dpx  by %5.1fpx  %s"):format(
          r.kind, r.tag, r.size or 0, r.by, r.text))
      end
      if #rows == 0 then
        print("  nothing: every string fits the box it was drawn into")
      end
      return true
    end, timeout = 5 })
add({ quit = true })

return steps
