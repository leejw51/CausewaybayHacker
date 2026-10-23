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
-- ## The look (`docs/love2d-ui.md` §title)
--
-- The logo in Press Start 2P — the one place the arcade face is kept — with
-- a solid edge shadow, settling in with a little overshoot; the plaque is
-- the screen's **hero** frame (`ui_plaque`), the one gold art frame this
-- screen is allowed, with a 2 px idle bob and the button's hover and press;
-- WATCH STORY is a ghost under it. No caption, no key hints: the plaque is
-- the hint. The footer is bare — only the ⚙.
--
-- ## The card waits for a person. Only a drive script gets the idle hand-over
--
-- Left alone with a player in front of it, the card waits. It used to give
-- up after `IDLE_OUT` seconds and hand over to the login screen, and the
-- report was exactly that: "after a while the title goes on by itself". A
-- cabinet plays its attract loop; it does not start the game because nobody
-- touched it. So for a player there is no clock at all.
--
-- The clock still exists, and it exists for one reader: **every script under
-- `tests/drive/` boots the client and waits for the login screen**, with
-- `timeout = 15` (which is also `src/drive.lua`'s default), and twenty of
-- them do not know to press SPACE on a card that did not exist when they
-- were written. So when `CWBH_DRIVE` names a script the card hands over
-- after `IDLE_OUT` seconds, as before.
--
-- **The idle clock is wall time, not summed `dt`.** `main.lua` caps `dt` at
-- 0.05 and macOS throttles an occluded window to a couple of frames a second,
-- so a timer added up from `dt` runs twenty times slow. `src/drive.lua` has
-- the same paragraph; this is the same rule.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Store = require("src.store")
local Anim = require("src.anim")
local Juice = require("src.juice")
local Fx = require("src.fx")

local Title = {}
Title.__index = Title

--- Seconds of nobody-at-all before the card hands over — **under a drive
--- script only**. See the header: a player is waited for.
Title.IDLE_OUT = 8

--- Whether this run has a script at the keyboard rather than a person.
function Title.driven()
  return (os.getenv("CWBH_DRIVE") or "") ~= ""
end

function Title.new(app)
  return setmetatable({ app = app, t = 0, leaving = false, hover = nil, header_h = 0 }, Title)
end

function Title:enter()
  self.t = 0
  self.since = love.timer.getTime()
  -- The logo and the plaque deal in again every time the card is shown.
  Juice.forget("title:")
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

--- The opening, asked for by name. A replay, so the flag is left alone.
function Title:watch_story()
  if self.leaving then return end
  self.leaving = true
  SFX.play("select")
  self.app:go("story", { replay = true })
end

function Title:update(dt)
  self.t = self.t + dt
  if not self.leaving and Title.driven()
    and love.timer.getTime() - (self.since or 0) > Title.IDLE_OUT then
    self:start(true)
  end
end

--- Where everything sits — **one function, read by the draw and by the
--- click.** The spec's numbers at the design sizes (plaque L 400,440
--- 480×88; P 140,760 440×88; story under it), as fractions of the canvas so
--- a 1920 fullscreen and a 720×958 window keep the proportions.
function Title:layout()
  local w, h = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  local pw = math.min(portrait and 440 or 480, w - 80)
  local ph = 88
  local px = math.floor((w - pw) / 2)
  local py = math.floor(h * (portrait and 0.594 or 0.611))
  -- WATCH STORY sits in the footer's corner beside the ⚙, on a pill of the
  -- bar colour: under the plaque it stood on the tram, where a ghost and a
  -- keycap over the street art were all but invisible.
  local sw, sh = UI.buttonSize(I18n.t("WATCH STORY"), { key = "F10" })
  sw = math.max(200, sw)
  sh = math.max(Theme.control.buttonM, sh)
  local g = Layout.gutter()
  local fh = UI.footerRow()
  local sx = w - g - Theme.control.gear - Theme.space.lg - sw
  local sy = h - fh + math.floor((fh - sh) / 2)
  return {
    logo_y = math.floor(h * (portrait and 0.28 or 0.36)),
    plaque = { x = px, y = py, w = pw, h = ph },
    story = { x = sx, y = sy, w = sw, h = sh },
  }
end

--- The logo: Press Start 2P, two lines, a solid edge shadow four pixels
--- down and right, settling in from slightly too big. The largest size at
--- which the longer word fits the canvas.
function Title:draw_logo(cy)
  local w = Layout.vw
  local first, second = I18n.t("CAUSEWAYBAY"), I18n.t("HACKER")
  local px = 48
  while px > 16 and UI.logoFont(px):getWidth(first) > w - 48 do px = px - 8 end
  local font = UI.logoFont(px)
  local gap = Theme.space.md
  local block = font:getHeight() * 2 + gap
  local k = Juice.enter("title:logo", { dur = 0.5, ease = "outBack" })
  local scale = 1.25 - 0.25 * k
  local alpha = math.min(1, k * 1.5)
  local bob = Anim.bob(Anim.now(), { amount = 3, period = 3.2 })
  local top = cy - block / 2 + bob
  love.graphics.push()
  love.graphics.translate(w / 2, cy)
  love.graphics.scale(scale, scale)
  love.graphics.translate(-w / 2, -cy)
  love.graphics.setFont(font)
  local function line(text, y, color)
    UI.setColor(Theme.edge, 0.9 * alpha)
    love.graphics.printf(text, 4, y + 4, w, "center")
    UI.setColor(color, alpha)
    love.graphics.printf(text, 0, y, w, "center")
  end
  line(first, top, Theme.gold)
  line(second, top + font:getHeight() + gap, Theme.land.rust)
  love.graphics.pop()
  love.graphics.setColor(1, 1, 1, 1)
end

function Title:draw()
  local w, h = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  Assets.cover(portrait and "title_bg_p" or "title_bg", 0, 0, w, h)
  -- Lighter than the spec's wash over a working screen: this is the
  -- establishing shot and the plate is the art; the felt only has to let
  -- the name read over a bright morning.
  UI.setColor(Theme.felt, portrait and 0.62 or 0.55)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(1, 1, 1, 1)
  Fx.ambient("dust", w, h)
  Fx.drawAmbient()

  local L = self:layout()
  self:draw_logo(L.logo_y)

  -- The plaque: the hero frame with the button's own motion — lift, scale
  -- and sway under the pointer, a push in on the click, a 2 px idle bob.
  local p = L.plaque
  local k = Juice.enter("title:plaque", { dur = 0.3, delay = 0.18, ease = "outBack" })
  local hot = self.hover == "plaque" and 1 or 0
  local a = Juice.follow("title:plaque", hot, { speed = 22 })
  local press = Juice.pressed("press:title:plaque")
  local bob = Anim.bob(Anim.now(), { amount = 2, period = 2 })
  local py = p.y + (1 - k) * 24 - 2 * a + 4 * press + bob
  local cx, cy = p.x + p.w / 2, py + p.h / 2
  local sway = a > 0.01 and math.sin(Anim.now() * math.pi * 2 * Theme.motion.sway) * 1.5 * a * math.pi / 180 or 0
  love.graphics.push()
  love.graphics.translate(cx, cy)
  love.graphics.rotate(sway)
  love.graphics.scale(1 + 0.03 * a, 1 + 0.03 * a)
  love.graphics.translate(-cx, -cy)
  UI.card(p.x, py, p.w, p.h, { variant = "hero", art = "ui_plaque", alpha = math.min(1, k * 1.5),
    shadowDy = Theme.shadowDy - press * 5, artScale = 0.75 })
  local pulse = 0.72 + 0.28 * (0.5 - 0.5 * math.cos(self.t * 2.4))
  UI.label(I18n.t("PRESS SPACE"), p.x, py + math.floor((p.h - UI.lead("title")) / 2), "title",
    { width = p.w, align = "center", color = Theme.text, alpha = math.min(1, k * 1.5) * (hot > 0 and 1 or pulse) })
  love.graphics.pop()
  self.start_rect = { x = p.x, y = p.y, w = p.w, h = p.h }

  -- The way into the opening for somebody the card would otherwise send
  -- straight past it: a ghost, under the plaque.
  local s = L.story
  local ks = Juice.enter("title:story", { dur = 0.3, delay = 0.3, ease = "outCubic" })
  local sy = s.y + (1 - ks) * 16
  -- The pill: the bar colour, so the ghost and its keycap read over the art.
  UI.card(s.x - Theme.space.sm, sy, s.w + Theme.space.sm * 2, s.h,
    { variant = "flat", fill = Theme.bar, radius = s.h / 2, alpha = 0.92 * ks, pad = 0 })
  UI.button(s.x, sy, s.w, s.h, I18n.t("WATCH STORY"),
    self.hover == "story" and "hot" or "normal", nil,
    { variant = "ghost", id = "title:story", key = "F10", alpha = ks })
  self.story_rect = { x = s.x - Theme.space.sm, y = s.y, w = s.w + Theme.space.sm * 2, h = s.h }

  -- No hint line: the plaque says it. Only the ⚙, bottom right.
  self.app:footer("", { bare = true })
end

local function inside(r, x, y)
  return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

function Title:keypressed(key)
  -- SPACE starts; F10 asks for the opening by name. Nothing else does
  -- anything, and it returns true so `App:keypressed` does not treat ESC as
  -- "back" from a screen that has nowhere to go back to.
  if key == "space" then
    UI.press("title:plaque", self.start_rect, { sfx = false })
    self:start(false)
    return true
  end
  if key == "f10" then
    self:watch_story()
    return true
  end
  return true
end

function Title:mousemoved(x, y)
  if inside(self.story_rect, x, y) then self.hover = "story"
  elseif inside(self.start_rect, x, y) then self.hover = "plaque"
  else self.hover = nil end
end

function Title:mousepressed(x, y)
  -- The two plates, and nothing else. The rest of the card is a picture; a
  -- press on it is not a decision, and the card's job is to wait for one. A
  -- press on the footer's ⚙ never gets here: `App:mousepressed` tests it
  -- first and consumes it.
  if inside(self.story_rect, x, y) then
    UI.press("title:story", self.story_rect, { sfx = false })
    self:watch_story()
  elseif inside(self.start_rect, x, y) then
    UI.press("title:plaque", self.start_rect, { sfx = false })
    self:start(false)
  end
end

return Title
