-- TITLE. The coin slot: the game's name over the Percival Street plate, and
-- **PRESS SPACE**.
--
-- Ported from the browser client's `frontend/src/scenes/title.ts`, whose
-- argument is already made and is not re-derived here: every cabinet in the
-- era rested on a card and waited. It did not start a cutscene at you the
-- moment the power came on, and it did not need to — the card said what the
-- game was called and told you, in two words, what to do about it.
--
-- Three things it is built to:
--
--   * **It waits.** `src/scenes/story.lua` is forty seconds of somebody
--     else's morning. It is asked for, not played at a cold boot.
--   * **"PRESS SPACE", and it means SPACE.** It used to mean any key, and
--     that was withdrawn: a card that starts the game on whichever key a
--     hand brushes is a card that has been skipped by accident, and the one
--     thing it exists to do is wait. SPACE, or a click on the plate itself.
--     Every other key is ignored here, and `F`, `F1`, `F11`, `F12` and `L`
--     never arrive at all — `main.lua` takes the display and language
--     controls first, so changing the language cannot also start the game.
--   * **It does not stand between a returning player and their work.** The
--     first press plays the opening; every press after that goes straight
--     on, because `Store.story_seen()` is remembered. A player whose session
--     resumed during the handshake still sees the card — it is the front
--     door — but one press takes them to `lands`, not to a login screen.
--
-- ## The idle hand-over, and the eight seconds that are a compromise
--
-- Left alone the card gives up after `IDLE_OUT` seconds and hands over to the
-- login screen. That is not what a cabinet does — a cabinet plays its attract
-- loop — and the reason it does not is worth writing down rather than
-- rediscovering:
--
--   * A screen that waits forever cannot be driven by anything that does not
--     know to press a key, and **every script under `tests/drive/` boots the
--     client and waits for the login screen**, with `timeout = 15` (which is
--     also `src/drive.lua`'s default). A card with no exit is a suite that
--     hangs — `love.event.quit(1)`, loudly, in that case, but still a suite
--     that fails for the one reason that is not a bug.
--   * Going to the *story* on idle instead would be more faithful and costs
--     the whole budget: the opening is ~40 s against a 15 s wait.
--
-- So: the boot screen hands over as soon as the socket has answered (under a
-- second on loopback), the card spends eight of the fifteen, and login lands
-- at about 8.5 s with nearly half the budget unspent. Nobody is watching, so
-- the cabinet does not perform — it puts up the screen a returning player's
-- hands are already on. `STORY` on the login screen plays the opening on
-- purpose, as it always did.
--
-- ## STORY on the card too, because `make gui` never shows the login screen
--
-- `make gui` resumes the stored session every launch, so a returning player
-- goes card → `lands` and never sees the login screen — and the login screen
-- was the only place `STORY` lived. Once `story.seen` was on disk the opening
-- was unreachable from the desktop client: SPACE went past it, and the one
-- button that replays it was on a screen the player could no longer reach.
-- So the card carries the same control. F10, or the small plate under the
-- big one; it plays the opening as a replay (`{ replay = true }`) and does
-- not touch the flag, exactly as the login screen's does. Every other key
-- and every other click still means "start".
--
-- **The idle clock is wall time, not summed `dt`.** `main.lua` caps `dt` at
-- 0.05 and macOS throttles an occluded window to a couple of frames a second,
-- so a timer added up from `dt` runs twenty times slow — an eight-second card
-- behind another window would be an eighty-second one, and the drive budget
-- above would be blown by the very thing it was measured against.
-- `src/drive.lua` has the same paragraph; this is the same rule.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Store = require("src.store")
local Ease = require("src.ease")

local Title = {}
Title.__index = Title

--- Seconds of nobody-at-all before the card hands over. See the header.
Title.IDLE_OUT = 8

function Title.new(app)
  return setmetatable({ app = app, t = 0, leaving = false }, Title)
end

function Title:enter()
  self.t = 0
  self.since = love.timer.getTime()
end

--- Go.
---
--- The opening if it has never been watched on this machine, the login screen
--- if it has. Guarded so a key and a click in the same frame cannot start two
--- scene changes.
---
--- `idle` is true when nothing was pressed and the card simply timed out,
--- which always means the login screen — see the header. It deliberately does
--- **not** mark the opening as seen: nobody was there to see it.
function Title:start(idle)
  if self.leaving then return end
  self.leaving = true
  if not idle then SFX.play("select") end
  if idle or Store.story_seen() then
    self.app:go(self.app.session.authed and "lands" or "login")
  else
    self.app:go("story")
  end
end

--- The opening, asked for by name. See the header: this is the login
--- screen's `STORY` on the card, for the player who never reaches the login
--- screen. A replay, so the flag is left alone.
function Title:watch_story()
  if self.leaving then return end
  self.leaving = true
  SFX.play("select")
  self.app:go("story", { replay = true })
end

function Title:update(dt)
  self.t = self.t + dt
  if not self.leaving and love.timer.getTime() - (self.since or 0) > Title.IDLE_OUT then
    self:start(true)
  end
end

--- The largest size from the ladder at which `text` still fits the canvas.
---
--- The name is the one piece of type on this screen with no wrapping and no
--- clipping to fall back on, and it is drawn at eleven characters of Press
--- Start 2P — 616 px at the authored 28, and 1584 px at the largest type
--- step, which is wider than a portrait canvas. A screen whose own title runs
--- off both edges is the first thing a new player sees.
local function fitting_size(text, width, ladder)
  for _, size in ipairs(ladder) do
    if UI.textWidth(text, size) <= width then return size end
  end
  return ladder[#ladder]
end

function Title:draw()
  local w, h = Layout.vw, Layout.vh
  Assets.cover(Layout.isPortrait() and "title_bg_p" or "title_bg", 0, 0, w, h)
  -- Lighter than the boot screen's veil: this is the establishing shot and
  -- the plate is the art, but the name has to read over a bright morning.
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.5)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(1, 1, 1, 1)

  local title = fitting_size("CAUSEWAYBAY", w - 40, { 28, 24, 20, 16, 12, 10, 8 })
  local line = UI.lineHeight(title)
  local y = h * (Layout.isPortrait() and 0.28 or 0.24)
  UI.text(I18n.t("CAUSEWAYBAY"), 0, y, title, Theme.coin, "center", w)
  UI.text(I18n.t("HACKER"), 0, y + line * 1.4, title, Theme.land.rust, "center", w)

  -- PRESS SPACE — the words a 16-bit game uses, on a plate of their own with
  -- a gold rule that breathes. The line under it is where the screen admits
  -- that it means any of them.
  local label = I18n.t("PRESS SPACE")
  local size = 12
  local bh = math.max(44, UI.lineHeight(size) + 20)
  local bw = math.min(w - 40, math.max(340, UI.textWidth(label, size) + 84))
  local bx = math.floor((w - bw) / 2)
  local by = math.floor(h * (Layout.isPortrait() and 0.60 or 0.62))
  local pulse = 0.45 + 0.55 * Ease.cosine((self.t * 1.2) % 1)

  UI.setColor(Theme.ink, 0.8)
  love.graphics.rectangle("fill", bx, by, bw, bh)
  UI.setColor(Theme.coin, pulse)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", bx + 1, by + 1, bw - 2, bh - 2)
  love.graphics.setColor(1, 1, 1, 1)
  UI.text(label, bx, by + (bh - UI.lineHeight(size)) / 2, size,
    Theme.withAlpha(Theme.cream, 0.6 + 0.4 * pulse), "center", bw)
  self.start_rect = { x = bx, y = by, w = bw, h = bh }

  UI.text(I18n.t("— or click the plate —"), 0, by + bh + 18, 8,
    Theme.withAlpha(Theme.cream, 0.7), "center", w)

  -- The way into the opening for somebody the card would otherwise send
  -- straight past it. Small and below the fold of the plate: it is the one
  -- control here that is not "start".
  local slabel = I18n.t("STORY  [F10]")
  local sw = math.max(140, UI.textWidth(slabel, 8) + 28)
  local sh = math.max(30, UI.lineHeight(8) + 14)
  local sx = math.floor((w - sw) / 2)
  local sy = by + bh + 18 + UI.lineHeight(8) + 22
  UI.button(sx, sy, sw, sh, slabel, "normal", 8)
  self.story_rect = { x = sx, y = sy, w = sw, h = sh }

  -- "any key" is not in the hint: the card says it in full two lines up, and
  -- at the default type step a portrait footer has room for three items.
  self.app:footer(I18n.t("SPACE start   F10 story   L language"))
end

local function inside(r, x, y)
  return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

function Title:keypressed(key)
  -- SPACE starts; F10 asks for the opening by name. Nothing else does
  -- anything, and it returns true so `App:keypressed` does not treat ESC as
  -- "back" from a screen that has nowhere to go back to.
  if key == "space" then
    self:start(false)
    return true
  end
  if key == "f10" then
    self:watch_story()
    return true
  end
  return true
end

function Title:mousepressed(x, y)
  -- The two plates, and nothing else. The rest of the card is a picture; a
  -- press on it is not a decision, and the card's job is to wait for one. A
  -- press on the footer's display controls never gets here: `App:mousepressed`
  -- tests those first and consumes them.
  if inside(self.story_rect, x, y) then
    self:watch_story()
  elseif inside(self.start_rect, x, y) then
    self:start(false)
  end
end

return Title
