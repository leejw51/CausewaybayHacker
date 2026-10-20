-- Every type step, both orientations, through the flow a player actually
-- takes — and the geometry asserted, not eyeballed.
--
--   make -C love2d drive SCRIPT=tests/drive/typesweep.lua ARGS="--home $(mktemp -d)"
--
-- Two reports drove this. In portrait at step 4 the category names wrapped
-- one letter to a line ("Bgrama…" down the left edge), because the label
-- gutter was a number rather than a measurement. In portrait at step 2 the
-- run console — a panel pinned to the bottom of the screen — sat on top of
-- the button band, so "does not compile" was printed through RUN and SUBMIT
-- and the compiler's own line was under the FORMAT button. Both screens are
-- laid out from the type now, and this script is what keeps them that way:
--
--   for each step in 1, 2, 4 and each orientation:
--     lands → categories (gutter fits the widest name)
--           → map → quest: every quest is picked, so the four choices
--             are on the screen and none of them overlaps another
--
-- It signs in with BIP-39's published test vector, so it needs the server
-- and a Go toolchain on the machine the server runs on. A `--home` of its
-- own, so the store it writes is not somebody's.

local Layout = require("src.layout")

local MNEMONIC = "abandon abandon abandon abandon abandon abandon abandon abandon "
  .. "abandon abandon abandon about"


local function scene(name)
  return function(app) return app.scene_name == name end
end
local function on_login(app) return app.scene_name == "login" end

local steps = {}
local function add(t) steps[#steps + 1] = t end

local failed = 0
local function check(ok, why)
  if ok then return true end
  print("FAIL: " .. why)
  failed = failed + 1
  return false
end

local function inside(inner, outer, slack)
  slack = slack or 0
  return inner.x >= outer.x - slack and inner.y >= outer.y - slack
    and inner.x + inner.w <= outer.x + outer.w + slack
    and inner.y + inner.h <= outer.y + outer.h + slack
end

local function disjoint(a, b)
  return a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y
end

local function rect_s(r)
  return r and ("[%d,%d %dx%d]"):format(r.x, r.y, r.w, r.h) or "nil"
end

add({ wait = 0.6 })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end,
      note = "login or an already-live session", timeout = 15 })
add({ text = MNEMONIC, when = on_login, note = "typing the mnemonic" })
add({ key = "return", when = on_login })
add({ until_ = scene("lands"), note = "signed in", timeout = 20 })
add({ until_ = function(app) return app.scene.lands ~= nil end, timeout = 10 })

for _, step in ipairs({ 1, 2, 4 }) do
  for _, mode in ipairs({ "landscape", "portrait" }) do
    local tag = ("s%d-%s"):format(step, mode)
    add({ note = ("---- type step %d, %s ----"):format(step, mode) })
    add({ until_ = function()
          Layout.setFont(step)
          return Layout.font == step
        end, timeout = 2 })
    add({ orient = mode })
    add({ resize = mode == "portrait" and { 720, 1000 } or { 1280, 720 } })
    add({ wait = 0.6 })
    add({ until_ = scene("lands"), timeout = 5 })

    -- The Go land, by name rather than by position.
    add({ until_ = function(app)
          for i, land in ipairs(app.scene.lands or {}) do
            if land.land == "go" then app.scene.cursor = i return true end
          end
          return false
        end, note = "the go land", timeout = 10 })
    add({ shot = ("T-%s-lands.png"):format(tag) })
    add({ key = "return" })
    add({ until_ = function(app) return app.scene_name == "categories" and app.scene.categories end,
          note = "categories " .. tag, timeout = 10 })
    add({ wait = 0.4 })
    add({ until_ = function(app)
          local Categories = require("src.scenes.categories")
          local m = Categories.metrics(Layout.vw, Layout.vh, app.scene.categories)
          print(("categories %s: gutter=%d widest=%d label_w=%d rh=%d blurb_lines=%d"):format(
            tag, m.gutter, m.widest, m.label_w, m.rh, m.blurb_lines))
          check(m.label_w >= m.widest,
            ("categories %s: the widest name (%d px) does not fit the label column (%d px)")
              :format(tag, m.widest, m.label_w))
          check(m.y0 + #app.scene.categories * (m.rh + 12) - 12 <= Layout.vh - 40,
            ("categories %s: the rows run under the footer"):format(tag))
          return true
        end, timeout = 3 })
    add({ shot = ("T-%s-categories.png"):format(tag) })

    add({ until_ = function(app) app.scene.cursor = 1 return true end, timeout = 2 })
    add({ key = "return" })
    add({ until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
          note = "map " .. tag, timeout = 10 })
    add({ wait = 0.5 })
    add({ shot = ("T-%s-map.png"):format(tag) })

    add({ until_ = function(app)
          app.scene.cursor = 1
          app.scene.at = 1
          app.scene.walk = nil
          return true
        end, timeout = 2 })
    add({ key = "return" })
    add({ until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
          note = "quest " .. tag, timeout = 10 })
    -- Every quest is picked, not typed (SPEC §0): no editor, no RUN. What
    -- the type step can break here is the four choices — wrapped off the
    -- screen, or drawn on top of each other.
    add({ wait = 0.6 })
    -- At the largest step the question can fill the panel: scroll the
    -- brief, as a player would, until a choice comes into view.
    add({ until_ = function(app)
          local q = app.scene
          if q.choice_hits and next(q.choice_hits) then return true end
          q.brief_scroll = q.brief_scroll + 40
          return false
        end, note = "a choice in view " .. tag, timeout = 10 })
    add({ wait = 0.2 })
    add({ until_ = function(app)
          local q = app.scene
          check(q.quest.quiz ~= nil, ("quest %s: the quest has no quiz"):format(tag))
          check(q:cheatsheet(), ("quest %s: a quest with a quiz still offers an editor"):format(tag))
          local hits = {}
          for i = 1, 4 do
            if q.choice_hits and q.choice_hits[i] then hits[#hits + 1] = q.choice_hits[i] end
          end
          print(("quest %s: %d of 4 choices on screen"):format(tag, #hits))
          check(#hits >= 1, ("quest %s: no choice is on screen"):format(tag))
          local screen = { x = 0, y = 0, w = Layout.vw, h = Layout.vh }
          for i, r in ipairs(hits) do
            check(inside(r, screen, 1), ("quest %s: choice %d %s is off the screen"):format(tag, i, rect_s(r)))
            for j = i + 1, #hits do
              check(disjoint(r, hits[j]),
                ("quest %s: choices %d and %d overlap"):format(tag, i, j))
            end
          end
          return true
        end, timeout = 3 })
    add({ shot = ("T-%s-quest.png"):format(tag) })

    add({ key = "escape" })
    add({ until_ = scene("map"), timeout = 10 })
    add({ key = "escape" })
    add({ until_ = scene("categories"), timeout = 10 })
    add({ key = "escape" })
    add({ until_ = scene("lands"), timeout = 10 })
  end
end

add({ until_ = function()
      Layout.setFont(2)
      if failed > 0 then
        print(("drive: FAILED — %d check(s)"):format(failed))
        love.event.quit(1)
        return true
      end
      print("PASS: every type step in both orientations — names fit their column, "
        .. "and a quest's four choices are on the screen, apart")
      return true
    end, timeout = 3 })
add({ quit = true })

return steps
