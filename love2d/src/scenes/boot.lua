-- BOOT. The title card, while the socket does its handshake.
--
-- It leaves on its own: either the session resumes (the app switches to
-- `lands`) or `need_login` fires and the login screen takes over. If neither
-- happens — the server is not running — it says so and offers the login
-- screen anyway, because a player with a mnemonic and no server should see
-- the reason, not a spinner.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local Ease = require("src.ease")

local Boot = {}
Boot.__index = Boot

function Boot.new(app)
  return setmetatable({ app = app, t = 0 }, Boot)
end

function Boot:enter()
  self.t = 0
end

function Boot:update(dt)
  self.t = self.t + dt
  -- Two seconds is long enough for a loopback handshake and a resume. After
  -- that the player gets a screen they can act on.
  if self.t > 2.0 and not self.app.session.authed then
    self.app:go("login")
  end
end

function Boot:draw()
  local w, h = Layout.vw, Layout.vh
  Assets.cover(Layout.isPortrait() and "title_bg_p" or "title_bg", 0, 0, w, h)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.55)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(1, 1, 1, 1)

    local title = 28
  local y = h * 0.32
  UI.text(I18n.t("CAUSEWAYBAY"), 0, y, title, Theme.coin, "center", w)
  UI.text(I18n.t("HACKER"), 0, y + title * 1.5, title, Theme.land.rust, "center", w)

  local pulse = 0.4 + 0.6 * Ease.cosine((self.t * 1.4) % 1)
  local state = self.app.client and self.app.client.state or "idle"
  local line = ({
    idle = "starting",
    connecting = "connecting",
    handshaking = "shaking hands",
    open = "connected",
    closing = "closing",
    closed = "no server",
  })[state] or state
  UI.text(line:upper() .. "  " .. self.app.server, 0, h * 0.62,
    10, Theme.withAlpha(Theme.cream, pulse), "center", w)

  self.app:footer(I18n.t("ENTER sign in"))
end

function Boot:keypressed(key)
  if key == "return" or key == "space" then
    self.app:go("login")
    return true
  end
  return false
end

return Boot
