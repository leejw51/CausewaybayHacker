-- The playground, CODE and the coder, upright (§4.9c, docs/agent.md).
--
--   make -C love2d drive SCRIPT=tests/drive/agentportrait.lua ARGS="--home $(mktemp -d)"
--
-- A phone held upright is the shape this client is hardest to lay out for:
-- the playground is five things in one window and the coder's room is a
-- sixth. This walks the three screens somebody writes on and photographs
-- each, and asserts the two things a photograph would show — that the panel
-- is inside the screen and clear of the footer, and that the editor still has
-- lines to read.
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
local function coder(app) local s = pg(app); return s and s.coder or nil end

add({ orient = "portrait" })
add({ until_ = function(app) return app.scene_name == "login" or app.session.authed end, timeout = 20 })
add({ text = "legal winner thank year wave sausage worth useful legal winner thank yellow",
      when = function(app) return app.scene_name == "login" end })
add({ key = "return", when = function(app) return app.scene_name == "login" end })
add({ until_ = function(app) return app.scene_name == "lands" end, timeout = 30 })
add({ wait = 0.4 })
add({ shot = "P0-lands-portrait.png" })
add({ until_ = function(app) app:go("playground"); return true end, timeout = 5 })
add({ until_ = function(app) return pg(app) ~= nil end, timeout = 10 })
add({ wait = 0.6 })
add({ shot = "P1-playground-portrait.png" })

-- The room, in the framed view.
add({ click = function(app) local r = pg(app).agent_button_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return coder(app).panel.open end, timeout = 5 })
add({ wait = 1.2 })
add({ shot = "P2-agent-portrait.png" })
add({ until_ = function(app)
      local Layout = require("src.layout")
      local UI = require("src.ui")
      local r = pg(app).agent_rect
      check(r ~= nil, "no room on the screen in portrait")
      if r then
        check(r.x >= 0 and r.x + r.w <= Layout.vw, "the room runs off the side")
        check(r.y + r.h <= Layout.vh - UI.footerHeight(),
          ("the room runs under the footer: %d of %d"):format(r.y + r.h,
            Layout.vh - UI.footerHeight()))
        print(("framed portrait: room %dx%d at %d,%d"):format(r.w, r.h, r.x, r.y))
      end
      return true
    end, timeout = 5 })

-- SETUP, where the fields are.
add({ click = function(app) local r = coder(app).panel.rects["setup"]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return coder(app).panel.view == "setup" end, timeout = 5 })
add({ wait = 0.4 })
add({ shot = "P3-agent-setup-portrait.png" })
add({ until_ = function(app)
      local p = coder(app).panel
      for _, id in ipairs({ "key", "model", "fetch", "auto", "shown" }) do
        check(p.rects[id] ~= nil, id .. " is not on the setup page in portrait")
      end
      return true
    end, timeout = 5 })
add({ click = function(app) local r = coder(app).panel.rects["setup"]
      return { r.x + r.w / 2, r.y + r.h / 2 } end })

-- CODE, upright.
add({ click = function(app) local r = pg(app).code_button_rect
      return { r.x + r.w / 2, r.y + r.h / 2 } end })
add({ until_ = function(app) return pg(app).big == true end, timeout = 5 })
add({ wait = 0.6 })
add({ shot = "P4-code-portrait.png" })
add({ until_ = function(app)
      local Layout = require("src.layout")
      local UI = require("src.ui")
      local s = pg(app)
      local r = s.agent_rect
      check((s.visible_rows or 0) >= 4,
        ("CODE upright left the editor %d lines"):format(s.visible_rows or 0))
      check(r ~= nil, "no room in CODE upright")
      if r then
        check(r.y + r.h <= Layout.vh - UI.footerHeight() + 1,
          ("the room runs under the footer: %d of %d"):format(r.y + r.h,
            Layout.vh - UI.footerHeight()))
        print(("CODE portrait: room %dx%d, editor %d rows"):format(r.w, r.h, s.visible_rows))
      end
      return true
    end, timeout = 5 })

add({ until_ = function() print(fail and "DRIVE FAILED" or "drive ok") return true end, timeout = 2 })
add({ quit = true })
return steps
