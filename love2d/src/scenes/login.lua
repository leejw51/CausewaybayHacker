-- LOGIN. A mnemonic (or a private key) goes in; a signature goes out.
--
-- Two modes, because a first-time player owns neither:
--
--   signin   — type a phrase you already have
--   new_show — twelve freshly generated words, on screen, to write down
--
-- SPEC §3.1 and PROTOCOL §4.3, restated as a screen:
--
--   * what is typed here is derived locally and never sent;
--   * the field is masked by default, because a mnemonic on a screen is a
--     mnemonic on a screen-share — F2 reveals it when the player wants to
--     check a word;
--   * the moment a signature exists, `Session:login` drops the phrase and
--     this scene clears its own buffer too;
--   * nothing about the phrase is ever printed, toasted or logged. The
--     status line says "deriving" and "signing", not what it is signing.
--
-- ## There is no confirmation step, and that is deliberate
--
-- An earlier version hid the list and made the player type three of the
-- twelve words back before the wallet could be used. The argument for it was
-- that the phrase *is* the account (SPEC §3), so a phrase never actually
-- written down is an account that ends with the machine.
--
-- The user looked at the screen and decided the friction was not worth it:
-- **`I HAVE WRITTEN IT DOWN` derives, signs and logs straight in.** It is
-- their wallet and their call.
--
-- A softer gate — a checkbox, one word instead of three — is deliberately
-- *not* here. A half-gate costs the interruption without buying the check,
-- which is the worst of both. What does the work instead is the copy and the
-- address: the words are on screen, the line says in as many words that this
-- is the only copy and there is no reset, and the account the phrase derives
-- is shown so it can be checked against the paper later.
--
-- And the failure this screen has to handle well: **the FFI library is not
-- built.** That is the most likely first-run state in a fresh checkout, and
-- the answer is a sentence with a command in it, not a crash.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local SFX = require("src.sfx")
local Wallet = require("src.wallet")
local App = require("src.app")

local Login = {}
Login.__index = Login

local FIELDS = { "secret", "name", "server" }

function Login.new(app)
  return setmetatable({
    app = app,
    mode = "signin",
    secret = "",
    name = "",
    focus = 1,
    reveal = false,
    status = nil,
    error = nil,
    busy = false,
    t = 0,
    -- new_show
    words = nil,       -- the generated phrase, split; dropped on leaving
    new_address = nil,
    -- The **saved** server, editable. Not necessarily the effective one: a
    -- launch-time override wins for the run and the panel says so rather
    -- than overwriting what the player typed.
    server = "",
    server_error = nil,
  }, Login)
end

function Login:enter()
  local remembered = self.app.session.remembered
  if remembered and remembered.name then
    self.name = remembered.name
  end
  -- The saved value, not the effective one — see `draw_signin`.
  self.server = require("src.store").saved_server() or self.app.server or ""
  if self.app.session.last_error then
    self.error = self.app.session.last_error
  end
end

function Login:leave()
  self:discard()
end

--- Drop every copy of a phrase this scene is holding.
function Login:discard()
  self.secret = ""
  if self.words then
    for i = 1, #self.words do self.words[i] = nil end
  end
  Wallet.forget(self, "words")
  self.words = nil
  self.new_address = nil
end

function Login:field()
  return FIELDS[self.focus]
end

--- What the secret field shows. `reveal` is off by default.
function Login:masked()
  if self.reveal then return self.secret end
  if self.secret == "" then return "" end
  -- Word boundaries stay visible: a player counting to twelve should be able
  -- to, without reading the words.
  return (self.secret:gsub("%S", "*"))
end

--- Apply and persist whatever is in the server field.
---
--- `App:set_server` validates, persists, rebinds the session to that server's
--- own token (SPEC §1.1) and drops the connection. A refusal comes back as a
--- sentence and is shown under the field, because "failing to connect for
--- unexplained reasons" is the thing this control exists to avoid.
function Login:apply_server()
  local ok, why = self.app:set_server(self.server)
  if not ok then
    self.server_error = why
    SFX.play("locked")
    return
  end
  self.server_error = nil
  SFX.play("select")
  self.app:toast(type(why) == "string" and why or ("server: " .. self.server))
end

function Login:can_submit()
  return self.app.wallet_lib ~= nil
    and self.secret ~= ""
    and self.app.client.state == "open"
    and not self.busy
end

-- ------------------------------------------------------------- new wallet

function Login:new_wallet()
  if not self.app.wallet_lib then
    self.error = "the key library is not built"
    SFX.play("locked")
    return
  end
  local out, err = Wallet.generate(self.app.wallet_lib, 12)
  if not out then
    self.error = err or "could not generate a wallet"
    SFX.play("rejected")
    return
  end

  local words = {}
  for word in out.mnemonic:gmatch("%S+") do words[#words + 1] = word end
  -- Belt and braces on the one call that hands key material back: if the
  -- library ever returns something that is not a phrase, this screen must not
  -- show it and call it a wallet.
  if #words ~= 12 then
    self.error = ("the key library returned %d words, not 12"):format(#words)
    return
  end
  self.words = words
  self.new_address = out.address
  self.mode = "new_show"
  self.error = nil
  self.status = nil
  SFX.play("select")
end

--- `I HAVE WRITTEN IT DOWN`: derive, sign, log in, straight to the map.
---
--- Safe on a double press. The first call takes the phrase; `submit` sets
--- `busy` and calls `discard`, so every later call finds `words` already nil.
--- Two presses a frame apart create one account and send one
--- `auth.challenge`, not two racing each other.
function Login:create_wallet()
  if self.busy or not self.words then return end
  local phrase = table.concat(self.words, " ")
  self:submit(phrase)
  phrase = nil
end

-- ------------------------------------------------------------------ signing

--- `phrase` defaults to whatever is in the sign-in field.
function Login:submit(phrase)
  phrase = phrase or self.secret
  if not self.app.wallet_lib then
    self.error = "the key library is not built"
    SFX.play("locked")
    return
  end
  if self.app.client.state ~= "open" then
    self.error = "not connected to " .. self.app.server
    SFX.play("locked")
    return
  end
  if phrase == "" or self.busy then
    SFX.play("locked")
    return
  end

  self.busy = true
  self.error = nil
  self.status = "deriving and signing locally"
  SFX.play("select")

  -- Back to the sign-in panel *before* the phrase is dropped. `discard`
  -- clears `words`, and the WRITE THIS DOWN panel draws from it — leaving the
  -- mode set would raise inside `draw` on the very next frame, which is a
  -- blank error screen at the exact moment the player's brand-new wallet is
  -- being created. (It did, once.)
  self.mode = "signin"
  -- Every copy this scene holds goes now; the only one left is the local
  -- argument, which `Session:login` drops as soon as a signature exists.
  self.secret = ""
  self:discard()

  self.app.session:login(phrase, 0, self.name ~= "" and self.name or nil, function(ok, message)
    self.busy = false
    self.status = nil
    if ok then
      SFX.play("accepted")
      return
    end
    SFX.play("rejected")
    self.mode = "signin"
    self.error = message or "login failed"
  end)
  phrase = nil
end

function Login:update(dt)
  self.t = self.t + dt
end

-- ------------------------------------------------------------------ drawing

local function field_box(y, w, h, label, shown, focused, hint)
  UI.text(label, 0, y - 14, 8, Theme.withAlpha(Theme.cream, 0.75))
  UI.setColor(Theme.void, 0.85)
  love.graphics.rectangle("fill", 0, y, w, h)
  love.graphics.setLineWidth(2)
  UI.setColor(focused and Theme.coin or Theme.withAlpha(Theme.cream, 0.35))
  love.graphics.rectangle("line", 1, y + 1, w - 2, h - 2)
  love.graphics.setColor(1, 1, 1, 1)
  local font = Assets.mono(math.floor(h * 0.62))
  love.graphics.setFont(font)
  if shown == "" then
    UI.setColor(Theme.withAlpha(Theme.cream, 0.35))
    love.graphics.print(hint or "", 8, y + (h - font:getHeight()) / 2)
  else
    UI.setColor(Theme.cream)
    -- Scroll so the tail is visible while typing a twelve-word phrase.
    local text = shown
    while font:getWidth(text) > w - 20 and #text > 1 do
      text = text:sub(2)
    end
    love.graphics.print(text, 8, y + (h - font:getHeight()) / 2)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

--- The panel this screen lives in. Both orientations, one function.
function Login:panel_rect()
  local vw, vh = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  local tall = self.mode == "new_show"
  local pw = math.min(vw - 40, portrait and (vw - 32) or (tall and 760 or 720))
  -- The word grid is three columns of four in landscape and two of six in
  -- portrait, so the panel is shorter in the orientation with more room
  -- across. Sized to the content rather than to the screen.
  -- Sized to the content. The word grid is three columns of four in
  -- landscape and two of six in portrait, so the panel is shorter in the
  -- orientation with more room across; the confirmation step that used to
  -- need the extra height is gone.
  local ph = math.min(vh - 48, portrait and (tall and 560 or 560) or (tall and 330 or 460))
  return (vw - pw) / 2, (vh - ph) / 2 - (portrait and 30 or 0), pw, ph
end

function Login:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Layout.isPortrait() and "title_bg_p" or "title_bg", 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.72)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local px, py, pw, ph = self:panel_rect()
  UI.panel(px, py, pw, ph, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.land.rust })

  love.graphics.push()
  love.graphics.translate(px + 20, py + 18)
  local inner = pw - 40

  if not self.app.wallet_lib then
    self:draw_no_library(inner, ph)
  elseif self.mode == "new_show" then
    self:draw_new_show(inner, ph)
  else
    self:draw_signin(inner, ph)
  end

  local message = self.error or self.status
  if message then
    local color = self.error and Theme.red or Theme.coin
    for i, line in ipairs(UI.wrap(message, inner, 8)) do
      if i <= 2 then
        UI.text(line, 0, ph - 54 + (i - 1) * 11, 8, color)
      end
    end
  end

  love.graphics.pop()

  if self.mode == "signin" then
    Assets.sprite("sprite_ferris", px + pw - 56, py + ph - 16, 72)
  end

  local hints = {
    -- No "F11 fullscreen" any more: that control is a button in the corner
    -- of this very strip now, with its state written on it, so listing its
    -- key here spent the room that the four keys with no button need.
    signin = "TAB field   F2 reveal   N new wallet   ENTER apply/sign in",
    new_show = "ENTER create and sign in   C copy   ESC cancel",
  }
  self.app:footer(hints[self.mode] or "")
end

function Login:draw_signin(inner, ph)
  local s = Layout.uiScale()
  UI.text("SIGN IN", 0, 0, math.floor(16 * s), Theme.coin)
  UI.text("your wallet is your account", 0, 22, 8, Theme.withAlpha(Theme.cream, 0.7))

  field_box(70, inner, 34, "MNEMONIC OR PRIVATE KEY  (F2 SHOWS IT)",
    self:masked(), self.focus == 1, "twelve words, or 0x + 64 hex")
  field_box(132, inner, 30, "DISPLAY NAME  (OPTIONAL)",
    self.name, self.focus == 2, "hacker")

  local words = 0
  for _ in self.secret:gmatch("%S+") do words = words + 1 end
  local shape = ""
  if Wallet.looks_like_private_key(self.secret) then
    shape = "private key"
  elseif words > 0 then
    shape = ("%d word%s"):format(words, words == 1 and "" or "s")
  end
  UI.text(shape, 0, 168, 8, Theme.withAlpha(Theme.cream, 0.6))
  UI.text("m/44'/60'/0'/0/0", inner - UI.textWidth("m/44'/60'/0'/0/0", 8), 168, 8,
    Theme.withAlpha(Theme.cream, 0.5))

  -- The server. On this screen because `CWBH_SERVER` is not discoverable
  -- from inside the game, and the backend now runs on `0.0.0.0` so a phone
  -- on the same tailnet is a real thing somebody wants to point at.
  local override = self.app.server_override
  field_box(196, inner, 30, "SERVER  (ENTER APPLIES)",
    self.server, self.focus == 3, App.DEFAULT_SERVER)
  self.server_box = { y = 196, h = 30 }

  if self.server_error then
    UI.text(self.server_error, 0, 230, 7, Theme.red)
  elseif override then
    -- Precedence, said out loud. The field still saves; it just does not win
    -- this run, and pretending otherwise would make the control a lie.
    for i, line in ipairs(UI.wrap(
      ("CWBH_SERVER=%s is overriding this run — the field is saved for next launch")
        :format(override), inner, 7)) do
      if i <= 2 then UI.text(line, 0, 230 + (i - 1) * 9, 7, Theme.coin) end
    end
  else
    local live = self.app.client and self.app.client.state or "idle"
    UI.text(("in use: %s  [%s]"):format(self.app.server, live), 0, 230, 7,
      Theme.withAlpha(Theme.cream, 0.5))
  end

  local bh = 32
  local by = 248
  UI.button(0, by, inner, bh, self.busy and "SIGNING…" or "SIGN IN  [ENTER]",
    self:can_submit() and "hot" or "disabled")
  self.signin_button = { y = by, h = bh }

  -- The way in for somebody who has never had a wallet. Given equal weight to
  -- the sign-in button rather than tucked in a corner: on a first run it is
  -- the only button that can do anything.
  local ny = by + bh + 10
  UI.button(0, ny, inner, bh, "NEW WALLET  [N]", self.busy and "disabled" or "normal")
  self.new_button = { y = ny, h = bh }
  UI.text("nothing typed here is ever sent. only a signature leaves this machine.",
    0, ny + bh + 8, 7, Theme.withAlpha(Theme.cream, 0.55))
end

function Login:draw_new_show(inner, ph)
  if not self.words then return end
  local s = Layout.uiScale()
  UI.text("WRITE THIS DOWN", 0, 0, math.floor(15 * s), Theme.coin)
  -- The copy is doing the work now that nothing gates the button.
  UI.text("this is the only copy. there is no reset.", 0, 22, 8, Theme.red)

  -- The grid: three columns of four in landscape, two of six in portrait, so
  -- the numbers stay in reading order either way.
  local portrait = Layout.isPortrait()
  local cols = portrait and 2 or 3
  local rows = math.ceil(#self.words / cols)
  local cw = inner / cols
  local top = 46
  local rh = 26

  UI.setColor(Theme.void, 0.8)
  love.graphics.rectangle("fill", 0, top - 6, inner, rows * rh + 12)
  love.graphics.setLineWidth(2)
  UI.setColor(Theme.coin)
  love.graphics.rectangle("line", 1, top - 5, inner - 2, rows * rh + 10)
  love.graphics.setColor(1, 1, 1, 1)

  local font = Assets.mono(20)
  for i, word in ipairs(self.words) do
    local col = math.floor((i - 1) / rows)
    local row = (i - 1) % rows
    local x = col * cw + 10
    local y = top + row * rh
    UI.text(("%2d"):format(i), x, y + 4, 8, Theme.withAlpha(Theme.cream, 0.45))
    love.graphics.setFont(font)
    UI.setColor(Theme.cream)
    love.graphics.print(word, x + 26, y)
    love.graphics.setColor(1, 1, 1, 1)
  end

  local y = top + rows * rh + 16
  -- Kept on screen on purpose: it is how a player checks later that the
  -- paper in the drawer is the account they are signed in to.
  UI.text("this wallet:  " .. tostring(self.new_address), 0, y, 7,
    Theme.withAlpha(Theme.coin, 0.85))
  y = y + 16

  for _, line in ipairs(UI.wrap(
    "Write them on paper, in order. Anyone who reads them owns the account, "
      .. "and nobody — not this game, not the server — can recover them for you.",
    inner, 8)) do
    y = y + UI.text(line, 0, y, 8, Theme.cream) + 3
  end

  local bh = 30
  local by = math.min(ph - 78, y + 12)
  UI.button(0, by, inner, bh,
    self.busy and "SIGNING…" or "I HAVE WRITTEN IT DOWN  [ENTER]",
    self.busy and "disabled" or "hot")
  self.show_button = { y = by, h = bh }
  UI.text("this signs in and takes you to the map.", 0, by + bh + 8, 7,
    Theme.withAlpha(Theme.cream, 0.55))
end

function Login:draw_no_library(inner, ph)
  local s = Layout.uiScale()
  UI.text("SIGN IN", 0, 0, math.floor(16 * s), Theme.coin)
  UI.text("your wallet is your account", 0, 22, 8, Theme.withAlpha(Theme.cream, 0.7))

  local box_y = 48
  UI.setColor(Theme.red, 0.18)
  love.graphics.rectangle("fill", 0, box_y, inner, ph - box_y - 70)
  love.graphics.setLineWidth(2)
  UI.setColor(Theme.red)
  love.graphics.rectangle("line", 1, box_y + 1, inner - 2, ph - box_y - 72)
  love.graphics.setColor(1, 1, 1, 1)
  UI.text("KEY LIBRARY NOT BUILT", 10, box_y + 10, 10, Theme.red)
  local lines = UI.wrap(
    "Deriving an address needs the small Rust library in love2d/ffi. "
      .. "Build it once and restart:", inner - 20, 8)
  local y = box_y + 30
  for _, line in ipairs(lines) do
    y = y + UI.text(line, 10, y, 8, Theme.cream) + 3
  end
  UI.text("make -C love2d ffi", 10, y + 6, 12, Theme.coin)
  local detail = tostring(self.app.wallet_error or Wallet.last_error() or "")
  for i, line in ipairs(UI.wrap(detail:match("^[^\n]*") or "", inner - 20, 7)) do
    if i <= 2 then
      UI.text(line, 10, ph - 100 + (i - 1) * 10, 7, Theme.withAlpha(Theme.cream, 0.6))
    end
  end
end

-- -------------------------------------------------------------------- input

function Login:textinput(text)
  if self.busy or not self.app.wallet_lib then return end
  if self.mode ~= "signin" then return end
  local name = self:field()
  self[name] = self[name] .. text
  if name == "server" then self.server_error = nil end
end

function Login:keypressed(key, mods)
  mods = mods or {}
  local cmd = mods.ctrl or mods.gui

  if not self.app.wallet_lib then return false end

  -- ------------------------------------------------------------ new_show
  if self.mode == "new_show" then
    if key == "return" or key == "kpenter" or key == "space" then
      self:create_wallet()
      return true
    end
    if key == "c" or (cmd and key == "c") then
      -- The clipboard is a real convenience here and a real risk; saying so
      -- out loud is the honest middle.
      love.system.setClipboardText(table.concat(self.words, " "))
      self.app:toast("copied — paste it somewhere safe, then clear the clipboard")
      return true
    end
    if key == "escape" then
      self:discard()
      self.mode = "signin"
      SFX.play("back")
      return true
    end
    return true -- the screen is modal: nothing else happens while it is up
  end

  -- -------------------------------------------------------------- signin
  if key == "n" and self.secret == "" and self:field() ~= "server" then
    self:new_wallet()
    return true
  end
  if key == "f2" then
    self.reveal = not self.reveal
    return true
  end
  if key == "tab" then
    self.focus = (self.focus % #FIELDS) + 1
    SFX.play("move")
    return true
  end
  if key == "backspace" then
    local name = self:field()
    -- Whole words with alt/ctrl, one character otherwise.
    if mods.alt or mods.ctrl then
      self[name] = self[name]:gsub("%s*%S+%s*$", "")
    else
      self[name] = self[name]:sub(1, -2)
    end
    return true
  end
  if key == "v" and cmd then
    local text = love.system.getClipboardText() or ""
    -- A pasted phrase arrives with whatever the source wrapped it in.
    self[self:field()] = self[self:field()] .. text:gsub("%s+", " "):gsub("^%s", "")
    return true
  end
  if key == "return" or key == "kpenter" then
    if self:field() == "server" then
      self:apply_server()
    else
      self:submit()
    end
    return true
  end
  if key == "escape" then
    self.secret = ""
    return true
  end
  return false
end

function Login:mousepressed(x, y)
  if not self.app.wallet_lib then return end
  local px, py, pw = self:panel_rect()
  local lx, ly = x - px - 20, y - py - 18
  if lx < 0 or lx > pw - 40 then return end

  local function hit(rect)
    return rect and ly >= rect.y and ly <= rect.y + rect.h
  end

  if self.mode == "new_show" then
    if hit(self.show_button) then self:create_wallet() end
    return
  end

  if ly >= 70 and ly <= 104 then self.focus = 1 end
  if ly >= 132 and ly <= 162 then self.focus = 2 end
  if ly >= 196 and ly <= 226 then self.focus = 3 end
  if hit(self.signin_button) then self:submit() end
  if hit(self.new_button) then self:new_wallet() end
end

return Login
