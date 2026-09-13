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
local I18n = require("src.i18n")
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
    -- Pixels the panel is scrolled by, when it is taller than the window.
    scroll = 0,
    field_rects = {},
  }, Login)
end

function Login:enter()
  self.scroll = 0
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
    self.error = I18n.t("the key library is not built")
    SFX.play("locked")
    return
  end
  local out, err = Wallet.generate(self.app.wallet_lib, 12)
  if not out then
    self.error = err or I18n.t("could not generate a wallet")
    SFX.play("rejected")
    return
  end

  local words = {}
  for word in out.mnemonic:gmatch("%S+") do words[#words + 1] = word end
  -- Belt and braces on the one call that hands key material back: if the
  -- library ever returns something that is not a phrase, this screen must not
  -- show it and call it a wallet.
  if #words ~= 12 then
    self.error = I18n.t("the key library returned %d words, not 12", #words)
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
    self.error = I18n.t("the key library is not built")
    SFX.play("locked")
    return
  end
  if self.app.client.state ~= "open" then
    self.error = I18n.t("not connected to %s", self.app.server)
    SFX.play("locked")
    return
  end
  if phrase == "" or self.busy then
    SFX.play("locked")
    return
  end

  self.busy = true
  self.error = nil
  self.status = I18n.t("deriving and signing locally")
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

--- Play the opening, on purpose.
---
--- It does **not** clear `story.seen`: watching it again deliberately is not
--- the same as never having been offered it, and a replay that reset the flag
--- would show it unasked at the next launch. The scene comes back here when
--- it ends or is skipped.
function Login:watch_story()
  if self.busy then return end
  SFX.play("select")
  self.app:go("story", { replay = true })
end

-- ------------------------------------------------------------------ drawing
--
-- ## Laid out from the type, not from numbers
--
-- The first version of this screen put every row at a fixed y — the phrase
-- field at 70, the name at 132, the server at 196, the buttons at 248 — and
-- those numbers were written against the 8 px type ladder. `Layout.ui` then
-- doubled the ladder and gave the player four steps of it, and the numbers
-- did not move: every label printed through the field above it, the field
-- text was a 16 px face rattling around a box sized for 24, and at the
-- larger steps the whole panel collapsed into one band of overprinted
-- lines. (The report was "font broken, text out of text box", and it was.)
--
-- Now each panel is a list of rows, each measured from the face it is drawn
-- in, stacked with a cursor. The panel is sized to the stack and, when the
-- stack is taller than the room above the footer — the largest type step in
-- a short landscape window — it scrolls behind a scissor and keeps the
-- focused row in view rather than drawing rows through each other.

--- The panel's inset, all four sides.
local PAD = 20
--- Air between rows.
local GAP = 10
--- Room kept clear for Ferris in the corner of the sign-in panel.
local FERRIS_H = 72

--- The face a field is typed in: VT323, following the type step like every
--- label does. Half again the label size, because VT323 is a narrow face and
--- at the same pixel height it reads a step smaller than Press Start 2P.
local function field_font()
  return Assets.mono(math.floor(Layout.ui(8) * 1.5))
end

local function field_height()
  return field_font():getHeight() + 14
end

--- A row: `h` pixels tall, drawn by `draw(y)` with `y` the row's top in
--- panel coordinates. `focus` marks the row `draw` keeps in view when the
--- panel scrolls.
local function stack()
  local rows, cursor = {}, 0
  local function put(h, draw, extra)
    local row = { y = cursor, h = h, draw = draw }
    if extra then for k, v in pairs(extra) do row[k] = v end end
    rows[#rows + 1] = row
    cursor = cursor + h + (extra and extra.gap or GAP)
    return row
  end
  local function height()
    local last = rows[#rows]
    return last and (last.y + last.h) or 0
  end
  return put, rows, height
end

--- One line of label at `size`, as a row.
local function text_row(put, text, size, color, gap, width)
  -- At the size that fits the panel when a width is given: `your wallet
  -- is your account` ran off the panel's edge at the largest type step.
  if width then size = UI.fitSize(text, width, size, 5) end
  return put(UI.lineHeight(size), function(y)
    UI.text(text, 0, y, size, color)
  end, { gap = gap })
end

--- A wrapped paragraph at `size`, as one row. `max_lines` clips it.
local function lines_row(put, text, width, size, color, gap, max_lines)
  local lines = UI.wrap(text, width, size)
  if max_lines and #lines > max_lines then
    for i = #lines, max_lines + 1, -1 do lines[i] = nil end
  end
  local step = UI.lineHeight(size) + 2
  return put(math.max(0, #lines * step - 2), function(y)
    for i, line in ipairs(lines) do
      UI.text(line, 0, y + (i - 1) * step, size, color)
    end
  end, { gap = gap })
end

local function field_box(y, w, h, label, shown, focused, hint)
  local lh = UI.lineHeight(8)
  UI.text(label, 0, y, UI.fitSize(label, w, 8, 5), Theme.withAlpha(Theme.cream, 0.75))
  local by = y + lh + 4
  UI.setColor(Theme.void, 0.85)
  love.graphics.rectangle("fill", 0, by, w, h)
  love.graphics.setLineWidth(2)
  UI.setColor(focused and Theme.coin or Theme.withAlpha(Theme.cream, 0.35))
  love.graphics.rectangle("line", 1, by + 1, w - 2, h - 2)
  love.graphics.setColor(1, 1, 1, 1)
  local font = field_font()
  love.graphics.setFont(font)
  local ty = by + (h - font:getHeight()) / 2
  if shown == "" then
    UI.setColor(Theme.withAlpha(Theme.cream, 0.35))
    love.graphics.print(hint or "", 8, ty)
  else
    UI.setColor(Theme.cream)
    -- Scroll so the tail is visible while typing a twelve-word phrase.
    -- **By character, not by byte**: a name typed in Korean is three bytes a
    -- glyph, and `sub(2)` on it prints the broken tail as mojibake.
    local chars = UI.chars(shown)
    local first = 1
    local function tail() return table.concat(chars, "", first) end
    local text = tail()
    while font:getWidth(text) > w - 20 and first < #chars do
      first = first + 1
      text = tail()
    end
    love.graphics.print(text, 8, ty)
  end
  love.graphics.setColor(1, 1, 1, 1)
  return { y = by, h = h }
end

--- The panel this screen lives in. Both orientations, one function.
---
--- Sized to the rows: `ph` is the stack plus the inset, capped at the room
--- above the footer. The cap is what makes `draw` scroll.
function Login:panel_rect()
  local vw, vh = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  -- Landscape: 720 at the default type step, and a wider panel at the steps
  -- above it, because the same labels are half again as wide there and a
  -- panel that stayed 720 would wrap `CWBH_SERVER=…` three deep.
  local want_w = portrait and (vw - 32)
    or math.floor(720 * math.max(1, Layout.fontScale() / 1.5))
  local pw = math.min(vw - 40, want_w)
  local room = vh - UI.footerHeight() - 24
  local content = self.content_h or 0
  local ph = math.min(room, content + PAD * 2)
  return math.floor((vw - pw) / 2), math.floor((room + 24 - ph) / 2), pw, ph
end

function Login:draw()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Layout.isPortrait() and "title_bg_p" or "title_bg", 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.72)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  -- Measure first, so the panel is the size of what goes in it.
  local _, _, pw0 = self:panel_rect()
  local inner = pw0 - PAD * 2
  local rows, content_h
  if not self.app.wallet_lib then
    rows, content_h = self:rows_no_library(inner)
  elseif self.mode == "new_show" then
    rows, content_h = self:rows_new_show(inner)
  else
    rows, content_h = self:rows_signin(inner)
  end
  self.content_h = content_h

  local px, py, pw, ph = self:panel_rect()
  UI.panel(px, py, pw, ph, { fill = Theme.withAlpha(Theme.navy, 0.94), tint = Theme.land.rust })

  -- Scroll: nothing, unless the stack is taller than the panel. Then clamp,
  -- and keep the focused row inside the window whatever the wheel did.
  local view_h = ph - PAD * 2
  local max_scroll = math.max(0, content_h - view_h)
  self.scroll = math.max(0, math.min(self.scroll or 0, max_scroll))
  for _, row in ipairs(rows) do
    if row.focus then
      if row.y < self.scroll then self.scroll = row.y end
      if row.y + row.h > self.scroll + view_h then self.scroll = row.y + row.h - view_h end
    end
  end
  self.view = { x = px + PAD, y = py + PAD, w = inner, h = view_h }

  love.graphics.push()
  love.graphics.translate(px + PAD, py + PAD - self.scroll)
  local sx, sy, sw, sh = love.graphics.getScissor()
  love.graphics.setScissor(px + 2, py + PAD - 2, pw - 4, view_h + 4)
  for _, row in ipairs(rows) do
    row.draw(row.y)
  end
  love.graphics.setScissor(sx, sy, sw, sh)
  love.graphics.pop()

  if max_scroll > 0 then
    -- A thin track, so a panel that is taller than it looks says so.
    local track_h = view_h
    local knob_h = math.max(24, track_h * view_h / content_h)
    local knob_y = (track_h - knob_h) * (self.scroll / max_scroll)
    UI.setColor(Theme.withAlpha(Theme.cream, 0.15))
    love.graphics.rectangle("fill", px + pw - 8, py + PAD, 3, track_h)
    UI.setColor(Theme.withAlpha(Theme.coin, 0.8))
    love.graphics.rectangle("fill", px + pw - 8, py + PAD + knob_y, 3, knob_h)
    love.graphics.setColor(1, 1, 1, 1)
  end

  -- Ferris stands in the corner only while the panel holds still: over a
  -- scrolling stack he would be standing on whichever row went past.
  if self.mode == "signin" and self.app.wallet_lib and max_scroll == 0 then
    Assets.sprite("sprite_ferris", px + pw - 56, py + ph - 16, FERRIS_H)
  end

  local hints = {
    -- No "F11 fullscreen" any more: that control is a button in the corner
    -- of this very strip now, with its state written on it, so listing its
    -- key here spent the room that the four keys with no button need.
    signin = I18n.t("TAB field   F2 reveal   N new wallet   F10 story   ENTER apply/sign in"),
    new_show = I18n.t("ENTER create and sign in   C copy   ESC cancel"),
  }
  self.app:footer(hints[self.mode] or "")
end

--- The error or status line, two lines at most, always reserved so the
--- panel does not grow the moment something goes wrong.
function Login:message_row(put, width)
  local step = UI.lineHeight(8) + 2
  put(step * 2 - 2, function(y)
    local message = self.error or self.status
    if not message then return end
    local color = self.error and Theme.red or Theme.coin
    for i, line in ipairs(UI.wrap(message, width, 8)) do
      if i <= 2 then UI.text(line, 0, y + (i - 1) * step, 8, color) end
    end
  end, { gap = 0 })
end

function Login:rows_signin(inner)
  local put, rows, height = stack()
  local lh8, lh7 = UI.lineHeight(8), UI.lineHeight(7)
  local fh = field_height()
  local dim = Theme.withAlpha(Theme.cream, 0.55)

  text_row(put, I18n.t("SIGN IN"), 16, Theme.coin, 4)
  text_row(put, I18n.t("your wallet is your account"), 8, Theme.withAlpha(Theme.cream, 0.7), 14,
    inner)

  self.field_rects = self.field_rects or {}
  local function field(index, label, shown, hint, gap)
    put(lh8 + 4 + fh, function(y)
      self.field_rects[index] = field_box(y, inner, fh, label, shown, self.focus == index, hint)
    end, { focus = self.focus == index, gap = gap })
  end

  field(1, I18n.t("MNEMONIC OR PRIVATE KEY  (F2 SHOWS IT)"), self:masked(),
    I18n.t("twelve words, or 0x + 64 hex"), 4)

  -- What the phrase looks like so far, and the derivation path it will go
  -- through, on one row under the field.
  put(lh8, function(y)
    local words = 0
    for _ in self.secret:gmatch("%S+") do words = words + 1 end
    local shape = ""
    if Wallet.looks_like_private_key(self.secret) then
      shape = I18n.t("private key")
    elseif words > 0 then
      -- Singular and plural as two strings; see the streak on the stats
      -- screen for why "%d word(s)" is not an option in the source language.
      shape = words == 1 and I18n.t("%d word", 1) or I18n.t("%d words", words)
    end
    UI.text(shape, 0, y, 8, Theme.withAlpha(Theme.cream, 0.6))
    local path = "m/44'/60'/0'/0/0"
    UI.text(path, inner - UI.textWidth(path, 8), y, 8, Theme.withAlpha(Theme.cream, 0.5))
  end)

  field(2, I18n.t("DISPLAY NAME  (OPTIONAL)"), self.name, "hacker")

  -- The server. On this screen because `CWBH_SERVER` is not discoverable
  -- from inside the game, and the backend now runs on `0.0.0.0` so a phone
  -- on the same tailnet is a real thing somebody wants to point at.
  field(3, I18n.t("SERVER  (ENTER APPLIES)"), self.server, App.DEFAULT_SERVER, 4)

  -- The line under it: a refusal, the override, or the live state. Two lines
  -- reserved, because the override sentence is two lines in most languages.
  local note_step = lh7 + 2
  put(note_step * 2 - 2, function(y)
    local override = self.app.server_override
    if self.server_error then
      for i, line in ipairs(UI.wrap(self.server_error, inner, 7)) do
        if i <= 2 then UI.text(line, 0, y + (i - 1) * note_step, 7, Theme.red) end
      end
    elseif override then
      -- Precedence, said out loud. The field still saves; it just does not
      -- win this run, and pretending otherwise would make the control a lie.
      for i, line in ipairs(UI.wrap(
        I18n.t("CWBH_SERVER=%s is overriding this run — the field is saved for next launch",
          override), inner, 7)) do
        if i <= 2 then UI.text(line, 0, y + (i - 1) * note_step, 7, Theme.coin) end
      end
    else
      local live = self.app.client and self.app.client.state or "idle"
      UI.text(I18n.t("in use: %s  [%s]", self.app.server, live), 0, y, 7,
        Theme.withAlpha(Theme.cream, 0.5))
    end
  end)

  -- The buttons, at the display controls' height: a thing a finger hits.
  local bh = UI.chipHeight()
  put(bh, function(y)
    UI.button(0, y, inner, bh, self.busy and "SIGNING…" or "SIGN IN  [ENTER]",
      self:can_submit() and "hot" or "disabled", UI.CHIP_SIZE)
    self.signin_button = { y = y, h = bh }
  end)

  -- The way in for somebody who has never had a wallet. Given equal weight
  -- to the sign-in button rather than tucked in a corner: on a first run it
  -- is the only button that can do anything.
  put(bh, function(y)
    UI.button(0, y, inner, bh, "NEW WALLET  [N]", self.busy and "disabled" or "normal",
      UI.CHIP_SIZE)
    self.new_button = { y = y, h = bh }
  end, { gap = GAP + 2 })

  -- The way back into the opening, which is the browser client's `STORY`
  -- button in this client's furniture. It is on the login screen for the
  -- same reason it is there: the opening plays once, on the first launch,
  -- and after that the only place anybody would think to look for it is the
  -- screen they arrive at. Narrower than the two buttons above it and set to
  -- one side, because it is the one control here that is not the way in.
  local story = I18n.t("STORY  [F10]")
  local swide = math.min(inner, math.max(140, UI.textWidth(story, 8) + 28))
  local caption = UI.wrap(I18n.t("watch the opening again"), math.max(40, inner - swide - 12), 7)
  local sh = math.max(bh - 4, math.min(#caption, 2) * note_step - 2)
  put(sh, function(y)
    UI.button(0, y, swide, bh - 4, story, "normal", 8)
    self.story_button = { y = y, h = bh - 4, w = swide }
    local cy = y + (bh - 4 - math.min(#caption, 2) * note_step + 2) / 2
    for i, line in ipairs(caption) do
      if i <= 2 then UI.text(line, swide + 12, cy + (i - 1) * note_step, 7, dim) end
    end
  end)

  -- Wrapped, and wrapped short of Ferris, who stands in the corner under it.
  lines_row(put, I18n.t("nothing typed here is ever sent. only a signature leaves this machine."),
    inner - 84, 7, dim, 6)
  self:message_row(put, inner - 84)

  return rows, height()
end

function Login:rows_new_show(inner)
  local put, rows, height = stack()
  if not self.words then return rows, 0 end
  local lh8 = UI.lineHeight(8)

  text_row(put, I18n.t("WRITE THIS DOWN"), 16, Theme.coin, 4)
  -- The copy is doing the work now that nothing gates the button.
  text_row(put, I18n.t("this is the only copy. there is no reset."), 8, Theme.red, 12)

  -- The grid: three columns of four in landscape, two of six in portrait, so
  -- the numbers stay in reading order either way. The words are set in the
  -- editor face at a step above the labels: they are the one thing on this
  -- screen a player copies letter by letter.
  local portrait = Layout.isPortrait()
  local cols = portrait and 2 or 3
  local rows_n = math.ceil(#self.words / cols)
  local cw = inner / cols
  local font = Assets.mono(math.floor(Layout.ui(8) * 1.5))
  local rh = math.max(font:getHeight() + 8, lh8 + 10)
  local num_w = UI.textWidth("12", 8) + 10
  put(rows_n * rh + 12, function(top)
    UI.setColor(Theme.void, 0.8)
    love.graphics.rectangle("fill", 0, top, inner, rows_n * rh + 12)
    love.graphics.setLineWidth(2)
    UI.setColor(Theme.coin)
    love.graphics.rectangle("line", 1, top + 1, inner - 2, rows_n * rh + 10)
    love.graphics.setColor(1, 1, 1, 1)
    for i, word in ipairs(self.words) do
      local col = math.floor((i - 1) / rows_n)
      local row = (i - 1) % rows_n
      local x = col * cw + 10
      local y = top + 6 + row * rh
      UI.text(("%2d"):format(i), x, y + (rh - lh8) / 2, 8, Theme.withAlpha(Theme.cream, 0.45))
      love.graphics.setFont(font)
      UI.setColor(Theme.cream)
      love.graphics.print(word, x + num_w, y + (rh - font:getHeight()) / 2)
      love.graphics.setColor(1, 1, 1, 1)
    end
  end, { gap = 12 })

  -- Kept on screen on purpose: it is how a player checks later that the
  -- paper in the drawer is the account they are signed in to.
  -- Uncapped: a 42-character address is one "word" to `UI.wrap`, and in a
  -- narrow panel it breaks into as many pieces as it needs. All of them are
  -- the address.
  lines_row(put, I18n.t("this wallet:  ") .. tostring(self.new_address), inner, 7,
    Theme.withAlpha(Theme.coin, 0.85), 8)

  lines_row(put, I18n.t("Write them on paper, in order. Anyone who reads them owns the account, "
    .. "and nobody — not this game, not the server — can recover them for you."),
    inner, 8, Theme.cream, 12)

  -- **Size 8, said out loud.** `UI.button`'s default is a third of its own
  -- height, which at this ladder is 24 px a character: thirty-one characters
  -- of `I HAVE WRITTEN IT DOWN  [ENTER]` then wrap to a second line inside a
  -- thirty-pixel button and the `[ENTER]` half is drawn through the bottom
  -- edge. This is the longest label in the client and it is the one button
  -- that has to be read before it is pressed.
  -- And the first size at or under 8 the label fits the panel at: in a
  -- landscape panel one type step up, 8 is still a character too wide and
  -- `[ENTER]` wraps under the button's bottom edge.
  local label = "I HAVE WRITTEN IT DOWN  [ENTER]"
  local label_size = 8
  while label_size > 5 and UI.textWidth(label, label_size) > inner - 16 do
    label_size = label_size - 1
  end
  local bh = math.max(UI.chipHeight(), lh8 + 14)
  put(bh, function(y)
    UI.button(0, y, inner, bh, self.busy and "SIGNING…" or label,
      self.busy and "disabled" or "hot", label_size)
    self.show_button = { y = y, h = bh }
  end, { focus = true, gap = 8 })
  text_row(put, I18n.t("this signs in and takes you to the map."), 7,
    Theme.withAlpha(Theme.cream, 0.55), 8)
  self:message_row(put, inner)

  return rows, height()
end

function Login:rows_no_library(inner)
  local put, rows, height = stack()
  local lh8, lh7 = UI.lineHeight(8), UI.lineHeight(7)

  text_row(put, I18n.t("SIGN IN"), 16, Theme.coin, 4)
  text_row(put, I18n.t("your wallet is your account"), 8, Theme.withAlpha(Theme.cream, 0.7), 12,
    inner)

  -- The red box, measured from what goes in it.
  local body = UI.wrap(
    I18n.t("Deriving an address needs the small Rust library in love2d/ffi. "
      .. "Build it once and restart:"), inner - 20, 8)
  local detail = tostring(self.app.wallet_error or Wallet.last_error() or "")
  local detail_lines = UI.wrap(detail:match("^[^\n]*") or "", inner - 20, 7)
  local box_h = 10 + UI.lineHeight(10) + 8
    + #body * (lh8 + 3) + 6 + UI.lineHeight(12) + 10
    + math.min(#detail_lines, 2) * (lh7 + 2) + 10
  put(box_h, function(box_y)
    UI.setColor(Theme.red, 0.18)
    love.graphics.rectangle("fill", 0, box_y, inner, box_h)
    love.graphics.setLineWidth(2)
    UI.setColor(Theme.red)
    love.graphics.rectangle("line", 1, box_y + 1, inner - 2, box_h - 2)
    love.graphics.setColor(1, 1, 1, 1)
    local y = box_y + 10
    y = y + UI.text(I18n.t("KEY LIBRARY NOT BUILT"), 10, y, 10, Theme.red) + 8
    for _, line in ipairs(body) do
      y = y + UI.text(line, 10, y, 8, Theme.cream) + 3
    end
    y = y + 6
    y = y + UI.text("make -C love2d ffi", 10, y, 12, Theme.coin) + 10
    for i, line in ipairs(detail_lines) do
      if i <= 2 then
        y = y + UI.text(line, 10, y, 7, Theme.withAlpha(Theme.cream, 0.6)) + 2
      end
    end
  end, { gap = 12 })
  self:message_row(put, inner)

  return rows, height()
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
      self.app:toast(I18n.t("copied — paste it somewhere safe, then clear the clipboard"))
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
  if key == "f10" then
    self:watch_story()
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

--- A click, in panel coordinates: inside the inset and past the scroll.
function Login:panel_point(x, y)
  local v = self.view
  if not v then return nil end
  if x < v.x or x > v.x + v.w or y < v.y or y > v.y + v.h then return nil end
  return x - v.x, y - v.y + (self.scroll or 0)
end

function Login:mousepressed(x, y)
  if not self.app.wallet_lib then return end
  local lx, ly = self:panel_point(x, y)
  if not lx then return end

  local function hit(rect)
    return rect and ly >= rect.y and ly <= rect.y + rect.h
  end

  if self.mode == "new_show" then
    if hit(self.show_button) then self:create_wallet() end
    return
  end

  if hit(self.story_button) and lx <= self.story_button.w then
    self:watch_story()
    return
  end
  for i = 1, #FIELDS do
    if hit(self.field_rects and self.field_rects[i]) then self.focus = i end
  end
  if hit(self.signin_button) then self:submit() end
  if hit(self.new_button) then self:new_wallet() end
end

--- The wheel scrolls the panel when there is more panel than window; `draw`
--- clamps whatever this leaves.
function Login:wheelmoved(_, dy)
  self.scroll = (self.scroll or 0) - dy * 40
end

return Login
