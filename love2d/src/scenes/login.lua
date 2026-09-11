-- LOGIN. A mnemonic (or a private key) goes in; a signature goes out.
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
-- And the failure this screen has to handle well: **the FFI library is not
-- built.** That is the most likely first-run state in a fresh checkout, and
-- the answer is a sentence with a command in it, not a crash.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local SFX = require("src.sfx")
local Wallet = require("src.wallet")

local Login = {}
Login.__index = Login

local FIELDS = { "secret", "name" }

function Login.new(app)
  return setmetatable({
    app = app,
    secret = "",
    name = "",
    focus = 1,
    reveal = false,
    status = nil,
    error = nil,
    busy = false,
    t = 0,
  }, Login)
end

function Login:enter()
  local remembered = self.app.session.remembered
  if remembered and remembered.name then
    self.name = remembered.name
  end
  if self.app.session.last_error then
    self.error = self.app.session.last_error
  end
end

function Login:leave()
  -- Nothing typed here outlives the screen.
  self.secret = ""
end

function Login:field()
  return FIELDS[self.focus]
end

function Login:value(name)
  return self[name] or ""
end

--- What the secret field shows. `reveal` is off by default.
function Login:masked()
  if self.reveal then return self.secret end
  if self.secret == "" then return "" end
  -- Word boundaries stay visible: a player counting to twelve should be able
  -- to, without reading the words.
  return (self.secret:gsub("%S", "*"))
end

function Login:can_submit()
  return self.app.wallet_lib ~= nil
    and self.secret ~= ""
    and self.app.client.state == "open"
    and not self.busy
end

function Login:submit()
  if not self:can_submit() then
    if not self.app.wallet_lib then
      self.error = "the key library is not built"
    elseif self.app.client.state ~= "open" then
      self.error = "not connected to " .. self.app.server
    end
    SFX.play("locked")
    return
  end
  self.busy = true
  self.error = nil
  self.status = "deriving and signing locally"
  SFX.play("select")

  local secret = self.secret
  -- Cleared before the call so the only remaining reference is the local,
  -- which `Session:login` drops as soon as the signature exists.
  self.secret = ""

  self.app.session:login(secret, 0, self.name ~= "" and self.name or nil, function(ok, message)
    self.busy = false
    self.status = nil
    if ok then
      SFX.play("accepted")
      return
    end
    SFX.play("rejected")
    self.error = message or "login failed"
  end)
  secret = nil
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

function Login:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Layout.isPortrait() and "title_bg_p" or "title_bg", 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.72)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local s = Layout.uiScale()
  local portrait = Layout.isPortrait()
  local pw = math.min(vw - 40, portrait and (vw - 40) or 720)
  local px = (vw - pw) / 2
  local ph = math.min(vh - 60, portrait and 520 or 380)
  local py = (vh - ph) / 2 - (portrait and 40 or 0)

  UI.panel(px, py, pw, ph, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.land.rust })

  love.graphics.push()
  love.graphics.translate(px + 20, py + 18)
  local inner = pw - 40

  UI.text("SIGN IN", 0, 0, math.floor(16 * s), Theme.coin)
  UI.text("your wallet is your account", 0, 22, 8, Theme.withAlpha(Theme.cream, 0.7))

  if not self.app.wallet_lib then
    -- The graceful path. This is what a fresh checkout sees.
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
    local first = detail:match("^[^\n]*") or ""
    UI.text(first:sub(1, math.floor(inner / 4.4)), 10, ph - 96, 7,
      Theme.withAlpha(Theme.cream, 0.6))
  else
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

    local bh = 34
    local by = 190
    UI.button(0, by, inner, bh, self.busy and "SIGNING…" or "SIGN IN  [ENTER]",
      self:can_submit() and "hot" or "disabled")

    UI.text("nothing typed here is ever sent. only a signature leaves this machine.",
      0, by + bh + 12, 7, Theme.withAlpha(Theme.cream, 0.55))
  end

  local message = self.error or self.status
  if message then
    local color = self.error and Theme.red or Theme.coin
    for i, line in ipairs(UI.wrap(message, inner, 8)) do
      if i <= 3 then
        UI.text(line, 0, ph - 62 + (i - 1) * 11, 8, color)
      end
    end
  end

  love.graphics.pop()

  Assets.fit("sprite_ferris", px + pw - 96, py + ph - 96, 80, 80, 1)

  self.app:footer("TAB field   F2 reveal   F1 orientation   ENTER sign in")
end

-- -------------------------------------------------------------------- input

function Login:textinput(text)
  if self.busy or not self.app.wallet_lib then return end
  local name = self:field()
  self[name] = self[name] .. text
end

function Login:keypressed(key, mods)
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
    if mods and (mods.alt or mods.ctrl) then
      self[name] = self[name]:gsub("%s*%S+%s*$", "")
    else
      self[name] = self[name]:sub(1, -2)
    end
    return true
  end
  if key == "v" and mods and (mods.ctrl or mods.gui) then
    local text = love.system.getClipboardText() or ""
    -- A pasted phrase arrives with whatever the source wrapped it in.
    self[self:field()] = self[self:field()] .. text:gsub("%s+", " "):gsub("^%s", "")
    return true
  end
  if key == "return" or key == "kpenter" then
    self:submit()
    return true
  end
  if key == "escape" then
    -- Nothing to go back to, but clearing the field is the useful action.
    self.secret = ""
    return true
  end
  return false
end

function Login:mousepressed(x, y)
  -- The two fields, in the panel's coordinates. Close enough to click into.
  local vw = Layout.vw
  local portrait = Layout.isPortrait()
  local pw = math.min(vw - 40, portrait and (vw - 40) or 720)
  local px = (vw - pw) / 2
  local ph = math.min(Layout.vh - 60, portrait and 520 or 380)
  local py = (Layout.vh - ph) / 2 - (portrait and 40 or 0)
  local lx, ly = x - px - 20, y - py - 18
  if lx < 0 or lx > pw - 40 then return end
  if ly >= 70 and ly <= 104 then self.focus = 1 end
  if ly >= 132 and ly <= 162 then self.focus = 2 end
  if ly >= 190 and ly <= 224 then self:submit() end
end

return Login
