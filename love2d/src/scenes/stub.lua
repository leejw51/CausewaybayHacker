-- A screen that is not built yet, and says so.
--
-- `search` and `ai` are milestone 2 on both sides: the backend answers them
-- `not_found` with `detail: {"milestone": 2}` (docs/decisions.md, BE's entry),
-- and this client would have nothing to draw if it did not.
--
-- The choice made here is to **ask the server anyway** and render what comes
-- back. That way the screen turns real the day the endpoint does, without a
-- change to this file, and in the meantime the player is told "milestone 2"
-- by the thing that actually knows rather than by a hard-coded label.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")

local Stub = {}
Stub.__index = Stub

function Stub.make(spec)
  local Scene = {}
  Scene.__index = Scene
  function Scene.new(app)
    return setmetatable({ app = app, spec = spec, state = "asking" }, Scene)
  end
  Scene.enter = Stub.enter
  Scene.draw = Stub.draw
  Scene.keypressed = Stub.keypressed
  return Scene
end

function Stub:enter()
  self.state = "asking"
  self.app.session:request(self.spec.probe, self.spec.payload or {}, function(ok, payload, why)
    if ok then
      self.state = "live"
      self.reply = payload
      return
    end
    self.state = "stub"
    self.code = payload.code
    self.milestone = (payload.detail or {}).milestone
    self.message = why.player
  end)
end

function Stub:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick("bg_datacentre", "bg_flat"), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.82)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local s = Layout.uiScale()
  local pad = Layout.isPortrait() and 14 or 90
  local w = vw - pad * 2
  local h = math.min(260, vh - 140)
  local y = (vh - h) / 2

  UI.panel(pad, y, w, h, { fill = Theme.withAlpha(Theme.navy, 0.95), tint = Theme.cyan })
  UI.text(self.spec.title, pad, y + 20, math.floor(16 * s), Theme.cyan, "center", w)

  local body
  if self.state == "asking" then
    body = "asking the server…"
  elseif self.state == "live" then
    body = "the server answered. this screen is the next thing to build."
  elseif self.milestone then
    body = ("the server says: milestone %d. %s"):format(self.milestone, self.spec.blurb)
  else
    body = self.message or self.spec.blurb
  end

  local cy = y + 62
  for _, line in ipairs(UI.wrap(body, w - 40, 9)) do
    cy = cy + UI.text(line, pad, cy, 9, Theme.cream, "center", w) + 5
  end

  cy = cy + 14
  for _, line in ipairs(self.spec.plan or {}) do
    cy = cy + UI.text("· " .. line, pad + 24, cy, 8, Theme.withAlpha(Theme.cream, 0.7)) + 4
  end

  UI.text(("probe: %s → %s"):format(self.spec.probe, tostring(self.code or self.state)),
    pad, y + h - 24, 7, Theme.withAlpha(Theme.cream, 0.45), "center", w)

  self.app:footer("ESC map")
end

function Stub:keypressed(key)
  if key == "return" or key == "kpenter" then
    self.app:back()
    return true
  end
  return false
end

return Stub
