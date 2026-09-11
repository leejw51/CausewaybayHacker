-- BOOT. The handshake, and nothing else.
--
-- It leaves on its own: the session resumes or `need_login` fires, and
-- either way the **title card** takes over. If
-- neither happens — the server is not running — it gives up after two
-- seconds and goes to the card anyway, because a player with a mnemonic and
-- no server should see a screen they can act on, not a spinner.
--
-- This used to *be* the title card: the name over the plate for a fixed two
-- seconds, then the login screen, whether anybody was there or not. The name
-- is on `src/scenes/title.lua` now, which waits. What is left here is the one
-- job this screen is actually for — saying where the socket has got to — and
-- it holds the screen for as little time as that takes.

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
  -- **A refused connection is an answer.** This screen exists to say where
  -- the socket has got to, and once the socket has stopped there is nothing
  -- left for it to say — so a client with no server reaches the title card in
  -- a third of a second rather than sitting here for two, which is two
  -- seconds back for `tests/drive/offline.lua`, whose whole subject is the
  -- offline path. The floor keeps the screen from flashing past on a machine
  -- that refuses instantly.
  local state = self.app.client and self.app.client.state or "idle"
  if state == "closed" and self.t > 0.35 then
    self.app:go("title")
    return
  end
  -- Otherwise two seconds, which is long enough for a loopback handshake and
  -- a resume, and is only reached when a server is answering slowly: with one
  -- that answers, `need_login` fires about a third of a second in and takes
  -- this screen off well before here.
  if self.t > 2.0 then
    self.app:go("title")
  end
end

function Boot:draw()
  local w, h = Layout.vw, Layout.vh
  Assets.cover(Layout.isPortrait() and "title_bg_p" or "title_bg", 0, 0, w, h)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.55)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(1, 1, 1, 1)

  local title = 16
  local y = h * 0.40
  UI.text(I18n.t("CAUSEWAYBAY"), 0, y, title, Theme.coin, "center", w)
  UI.text(I18n.t("HACKER"), 0, y + UI.lineHeight(title) * 1.4, title,
    Theme.land.rust, "center", w)

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

  self.app:footer(I18n.t("ENTER continue"))
end

function Boot:keypressed(key)
  if key == "return" or key == "space" then
    -- Past the handshake, not past the card: somebody who presses a key here
    -- is impatient with the socket, not asking to skip the game's own title.
    self.app:go("title")
    return true
  end
  return false
end

return Boot
