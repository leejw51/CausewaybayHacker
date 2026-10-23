-- LOGIN. A mnemonic (or a private key) goes in; a signature goes out.
--
-- Two modes, because a first-time player owns neither:
--
--   signin   — type a phrase you already have
--   new_show — twelve freshly generated words, on a sheet, to write down
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
--
-- ## The look (`docs/love2d-ui.md` §login)
--
-- One hero card, centred in the bounded content box: the title, the phrase
-- as a **well** with the words on a grid in the code face, the account and
-- the name on one row, SIGN IN as the one primary, NEW WALLET beside it, and
-- a row of ghosts under them — the server behind a chip that opens, the kept
-- key as a chip, WATCH STORY. A refusal is a red-ruled card under the well,
-- never a toast. The new wallet is a sheet (`UI.modal`) over the card: the
-- words as keycaps, the address as a chip with COPY, one primary, ESC.
--
-- **Measured, never fixed.** Every row is as tall as the face it is drawn
-- in says — the interface roles never move with F12, the code face does —
-- so the card fits in COMIC and DOS as it does in Neo둥근모, and when the
-- stack is taller than the room (a 24-word phrase at step 4 in a short
-- window) it scrolls behind a fade rather than drawing rows through each
-- other.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Anim = require("src.anim")
local Juice = require("src.juice")
local Fx = require("src.fx")
local Wallet = require("src.wallet")
local Username = require("src.username")
local Store = require("src.store")
local App = require("src.app")

local Login = {}
Login.__index = Login

--- The last account index `m/44'/60'/0'/0/i` can hold: the element is a
--- non-hardened child, so it runs to 2^31 - 1.
local MAX_INDEX = 2147483647

-- The rows TAB walks, in the order they are drawn. `index` sits directly
-- under the phrase because it changes what the phrase *means*: one phrase
-- is many accounts, and `m/44'/60'/0'/0/i` decides which one you are about
-- to be. `server` is behind the SERVER chip; TAB on to it opens the chip.
local FIELDS = { "secret", "index", "name", "server" }

function Login.new(app)
  return setmetatable({
    app = app,
    mode = "signin",
    secret = "",
    -- A string rather than a number, because it is a text field: what is on
    -- screen is what a person is midway through typing, and `""` between
    -- clearing the box and typing the new number is a state the parser has to
    -- accept rather than a state to prevent.
    index = "0",
    name = "",
    -- Set the moment somebody types in the name box. Until then the name
    -- follows the address; after it, it is theirs and nothing rewrites it.
    name_touched = false,
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
    -- Whether the SERVER chip is open, showing the field under it.
    server_open = false,
    -- Pixels the card is scrolled by, when its stack is taller than it.
    scroll = 0,
    -- What the pointer is over: a hit id from `hits`, or nil.
    hover = nil,
    -- The rects drawn last frame, in card coordinates, keyed by id.
    hits = {},
    -- No header band: the toast dock sits at the top edge.
    header_h = 0,
  }, Login)
end

function Login:enter()
  self.scroll = 0
  self.hover = nil
  Juice.forget("login:")
  self:read_kept()
  local remembered = self.app.session.remembered
  if remembered and remembered.name then
    self.name = remembered.name
  end
  -- The saved value, not the effective one — see the server note.
  self.server = Store.saved_server() or self.app.server or ""
  if self.app.session.last_error then
    self.error = self.app.session.last_error
  end
  -- Sent here by LOGOUT: say so, in the status colour, not the failure one.
  -- Read once and cleared, so a later visit to this screen does not repeat
  -- news about a session that is long gone.
  if self.app.logged_out_notice then
    self.status = self.app.logged_out_notice
    self.app.logged_out_notice = nil
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
  -- `refresh_preview` keeps the phrase (with the index) as its change key;
  -- it is a copy like any other and goes with them.
  Wallet.forget(self, "preview_key")
  self.preview_key = nil
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

--- The address of the key kept on this machine, when there is one and
--- nobody is signed in with it: the chip that says so. Read from the store
--- on `enter` and after a kept-key login fails (a revocation clears it),
--- not every frame — the store opens a file to answer. `pcall`, because
--- the scene tests draw this screen over a stub store.
function Login:read_kept()
  self.kept = nil
  if self.app.session and self.app.session.authed then return end
  local ok, address = pcall(Store.last_key_address)
  if ok and type(address) == "string" and address ~= "" then self.kept = address end
end

function Login:kept_address()
  return self.kept
end

--- `0x31c0…a99F`: the middle of an address, dropped.
local function short_address(a)
  a = tostring(a or "")
  if #a < 14 then return a end
  return a:sub(1, 6) .. "…" .. a:sub(-4)
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
  self.sheet_hits = {}
  UI.modalReset("newwallet")
  SFX.play("select")
end

--- ESC on the sheet: nothing created, nothing kept.
function Login:cancel_new()
  self:discard()
  self.mode = "signin"
  SFX.play("back")
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

--- C on the sheet: the phrase to the clipboard. A real convenience and a
--- real risk; saying so out loud is the honest middle.
function Login:copy_phrase()
  if not self.words then return end
  love.system.setClipboardText(table.concat(self.words, " "))
  self.app:toast(I18n.t("copied — paste it somewhere safe, then clear the clipboard"))
end

--- COPY beside the address chip: the address, which is public.
function Login:copy_address()
  if not self.new_address then return end
  love.system.setClipboardText(tostring(self.new_address))
  self.app:toast(I18n.t("address copied"), nil, "good")
end

-- ------------------------------------------------------------------ signing

--- The account index in the box, as a number the derivation will take.
---
--- Every way a text box fails to be a number resolves to **an index**, never
--- to an error: an empty box is somebody midway through typing and a login
--- screen that refused it would be shouting at them for pressing backspace.
--- Past the end of the path it clamps rather than wraps — a pasted twenty
--- digits lands on the last real account instead of quietly becoming a
--- different one.
function Login:account_index()
  local n = tonumber(self.index)
  if not n or n ~= n or n < 0 then return 0 end
  return math.min(math.floor(n), MAX_INDEX)
end

--- Throw away the derived address, so the next `update` works it out again.
---
--- Called from every edit to the phrase or the index. The derivation itself
--- is not done here: it is PBKDF2 and it belongs on a frame that is not also
--- handling a keystroke.
function Login:forget_preview()
  self.preview = nil
  self.preview_key = nil
end

--- Derive the address the current phrase and index produce, at most once per
--- change, and put the name it implies in the name box.
---
--- Deliberately lazy. A phrase is turned into a seed by PBKDF2 with 2048
--- rounds; doing that on the keystroke would drop frames in the middle of
--- somebody typing twelve words. Doing it here means the address and the name
--- appear a frame after the typing stops, which is what they are for.
function Login:refresh_preview()
  if not self.app.wallet_lib then return end
  local key = self.secret .. "\0" .. self.index
  if self.preview_key == key then return end
  self.preview_key = key
  self.preview = nil
  if self.secret == "" then
    if not self.name_touched then self.name = "" end
    return
  end
  local ok, reply = pcall(Wallet.derive, self.app.wallet_lib, self.secret, self:account_index())
  if not ok or type(reply) ~= "table" or not reply.address then
    -- Half a phrase is not an error worth showing; it is just not an address
    -- yet. The box keeps whatever it had.
    return
  end
  self.preview = reply.address
  if not self.name_touched then
    self.name = Username.of(self.app.wallet_lib, reply.address) or self.name
  end
end

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

  -- Back to the sign-in card *before* the phrase is dropped. `discard`
  -- clears `words`, and the WRITE THIS DOWN sheet draws from it — leaving the
  -- mode set would raise inside `draw` on the very next frame, which is a
  -- blank error screen at the exact moment the player's brand-new wallet is
  -- being created. (It did, once.)
  self.mode = "signin"
  -- Every copy this scene holds goes now; the only one left is the local
  -- argument, which `Session:login` drops as soon as a signature exists.
  self.secret = ""
  self:discard()

  -- The index the box was showing when ENTER was pressed. `self.index` is
  -- about to survive this call — it is a preference, not key material — but
  -- the number is read *now*, beside the phrase it belongs to.
  local index = self:account_index()
  self.app.session:login(phrase, index, self.name ~= "" and self.name or nil, function(ok, message)
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

--- The KEPT KEY chip: sign in with the key this machine already holds,
--- nobody typing. `Session:login_with_kept` is the launch-time path, reached
--- here by hand when that path did not run — the server was not answering
--- when the client came up, say.
function Login:use_kept()
  if self.busy then return end
  if self.app.client.state ~= "open" then
    self.error = I18n.t("not connected to %s", self.app.server)
    SFX.play("locked")
    return
  end
  self.busy = true
  self.error = nil
  self.status = I18n.t("signing in with the kept key")
  SFX.play("select")
  local started = self.app.session:login_with_kept(function(ok, message)
    self.busy = false
    self.status = nil
    if ok then
      SFX.play("accepted")
      return
    end
    SFX.play("rejected")
    self.error = message or "login failed"
    self:read_kept()
  end)
  if not started then
    self.busy = false
    self.status = nil
    self:read_kept()
  end
end

function Login:update(dt)
  self.t = self.t + dt
  if self.mode == "signin" and not self.busy then self:refresh_preview() end
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

--- The code face for the words and the fields, **never under 16 rasterised
--- pixels**. `Layout.codeSize` follows the type step down to 12 at step 1,
--- and Iosevka's measured scale takes that to 8 — a phrase a player copies
--- letter by letter is not drawn at 8. The step still moves it up.
local function code_font()
  local size = Layout.codeSize(Theme.type.code)
  local guard = 0
  while Assets.mono_px(size) < Theme.type.code and guard < 64 do
    size = size + 1
    guard = guard + 1
  end
  return Assets.mono(size)
end

--- A text field's height: the spec's 48, or the code face plus air.
local function field_height(font)
  return math.max(Theme.control.buttonL - Theme.space.sm, font:getHeight() + Theme.space.lg)
end

--- A row: `h` pixels tall, drawn by `draw(y)` with `y` the row's top in
--- card coordinates. `focus` marks the row `draw` keeps in view when the
--- card scrolls; `message` marks the refusal.
local function stack()
  local rows, cursor = {}, 0
  local function put(h, draw, extra)
    local row = { y = cursor, h = h, draw = draw }
    if extra then for k, v in pairs(extra) do row[k] = v end end
    rows[#rows + 1] = row
    cursor = cursor + h + ((extra and extra.gap) or Theme.rowGap)
    return row
  end
  local function height()
    local last = rows[#rows]
    return last and (last.y + last.h) or 0
  end
  return put, rows, height
end

--- A blinking caret after the text, while the field has the focus.
local function caret(self, x, y, h)
  if self.t % 1 < 0.6 or Anim.frozen() then
    UI.setColor(Theme.gold)
    love.graphics.rectangle("fill", x, y, 2, h)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

--- A one-line text field as a well: the tail of `shown` (by character, not
--- by byte — a name typed in Korean is three bytes a glyph), a hint when it
--- is empty, a gold edge and a caret while focused.
local function field_box(self, x, y, w, h, shown, focused, hint, font)
  UI.card(x, y, w, h, { variant = "well", pad = 0 })
  if focused then UI.stroke(x, y, w, h, Theme.radiusInner, Theme.gold) end
  love.graphics.setFont(font)
  local ty = y + math.floor((h - font:getHeight()) / 2)
  local tx = x + Theme.space.md
  if shown == "" then
    UI.setColor(Theme.mute, 0.6)
    love.graphics.print(UI.ellipsizeWith(hint or "", w - Theme.space.md * 2, font), tx, ty)
    if focused then caret(self, tx, ty, font:getHeight()) end
  else
    local chars = UI.chars(shown)
    local first = 1
    local function tail() return table.concat(chars, "", first) end
    local text = tail()
    while font:getWidth(text) > w - Theme.space.md * 2 - 4 and first < #chars do
      first = first + 1
      text = tail()
    end
    UI.setColor(Theme.text)
    love.graphics.print(text, tx, ty)
    if focused then caret(self, tx + font:getWidth(text) + 2, ty, font:getHeight()) end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

--- A chip that is not upper-cased: a caption in the label role and a
--- fragment in the code face (an EIP-55 address keeps its case). Returns
--- the width; `measure = true` only measures.
local function code_chip(x, y, caption, code, font, opts, measure)
  opts = opts or {}
  local h = opts.h or Theme.control.chip
  local lf = UI.font("label")
  local cw = caption and caption ~= "" and (lf:getWidth(caption) + Theme.space.sm) or 0
  local w = Theme.space.md * 2 + cw + font:getWidth(code)
  if measure then return w end
  local fill = opts.selected and Theme.gold or (opts.hot and Theme.cardHi or Theme.bar)
  if opts.selected then
    UI.setColor(Theme.goldD)
    UI.rrect("fill", x, y + Theme.chipShadowDy, w, h, Theme.radiusInner)
  end
  UI.setColor(fill)
  UI.rrect("fill", x, y, w, h, Theme.radiusInner)
  UI.stroke(x, y, w, h, Theme.radiusInner, opts.selected and Theme.goldD or Theme.edge)
  local ink = opts.selected and Theme.edge or (opts.hot and Theme.text or Theme.mute)
  local tx = x + Theme.space.md
  if cw > 0 then
    love.graphics.setFont(lf)
    UI.setColor(ink)
    love.graphics.print(caption, tx, y + math.floor((h - lf:getHeight()) / 2))
    tx = tx + cw
  end
  love.graphics.setFont(font)
  UI.setColor(opts.selected and Theme.edge or Theme.text)
  love.graphics.print(code, tx, y + math.floor((h - font:getHeight()) / 2))
  love.graphics.setColor(1, 1, 1, 1)
  return w
end

--- The host and port of a server URL: what the chip has room to say.
local function host_of(url)
  return (tostring(url or ""):gsub("^%w+://", ""):gsub("/.*$", ""))
end

--- The card's box: the bounded content rect (720 wide in landscape, the
--- gutters in portrait), and the card's padding.
function Login:frame()
  local portrait = Layout.isPortrait()
  local pad = portrait and Theme.space.lg or Theme.space.xl
  local x, y, w, h = UI.bounded(portrait and nil or 720, Theme.space.xl,
    Layout.vh - UI.footerHeight() - Theme.space.lg)
  return x, y, w, h, pad
end

function Login:draw()
  local vw, vh = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  Assets.cover(portrait and "title_bg_p" or "title_bg", 0, 0, vw, vh)
  UI.setColor(Theme.felt, portrait and 0.8 or 0.72)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)
  Fx.ambient("dust", vw, vh)
  Fx.drawAmbient()

  -- Measure first, so the card is the size of what goes in it.
  local bx, by, bw, bh, pad = self:frame()
  local inner = bw - pad * 2
  self.hits = {}
  local rows, content_h
  if not self.app.wallet_lib then
    rows, content_h = self:rows_no_library(inner)
  else
    rows, content_h = self:rows_signin(inner)
  end
  -- Kept for the drives: where each row landed is the only way a test can
  -- ask whether the player could actually see one.
  self.last_rows = rows

  local card_h = math.min(bh, content_h + pad * 2)
  local k = Juice.enter("login:card", { dur = Theme.motion.enter })
  local card_y = by + math.floor((bh - card_h) / 2) + math.floor((1 - k) * 24)
  local alpha = math.min(1, k * 1.5)
  -- The hero frame: this screen's one.
  UI.card(bx, card_y, bw, card_h, { variant = "hero", art = "ui_quiz_card", pad = pad, alpha = alpha })

  -- Scroll: nothing, unless the stack is taller than the card. Then clamp,
  -- and keep the focused row inside the window whatever the wheel did.
  local view_h = card_h - pad * 2
  local max_scroll = math.max(0, content_h - view_h)
  self.scroll = math.max(0, math.min(self.scroll or 0, max_scroll))
  -- Follow the focus when it **moves**, and only then. Doing it every frame
  -- pins the card to whichever field has the caret: the wheel turns, the
  -- next draw drags it straight back, and everything under that row — the
  -- buttons included — is unreachable by mouse.
  local function bring_into_view(row)
    if row.y < self.scroll then self.scroll = row.y end
    if row.y + row.h > self.scroll + view_h then self.scroll = row.y + row.h - view_h end
  end
  if self.focus ~= self.followed_focus then
    self.followed_focus = self.focus
    for _, row in ipairs(rows) do
      if row.focus then bring_into_view(row) end
    end
  end
  -- A refusal the player cannot see is a screen that did not answer: carry
  -- the card to it the once, when the words change.
  local said = self.error or self.status
  if said and said ~= self.followed_said then
    for _, row in ipairs(rows) do
      if row.message then bring_into_view(row) end
    end
  end
  self.followed_said = said
  self.view = { x = bx + pad, y = card_y + pad, w = inner, h = view_h }

  love.graphics.push()
  love.graphics.translate(self.view.x, self.view.y - self.scroll)
  local sx, sy, sw, sh = love.graphics.getScissor()
  -- The scene draws onto the virtual canvas, so the scissor is in its units.
  love.graphics.setScissor(bx + 2, card_y + pad - 2, bw - 4, view_h + 4)
  for _, row in ipairs(rows) do
    row.draw(row.y)
  end
  love.graphics.setScissor(sx, sy, sw, sh)
  love.graphics.pop()

  if max_scroll > 0 then
    if self.scroll > 1 then UI.scrollFade(self.view.x, self.view.y, inner, Theme.card, "top") end
    if max_scroll - self.scroll > 1 then
      UI.scrollFade(self.view.x, self.view.y + view_h - Theme.space.xl, inner, Theme.card, "bottom")
    end
    UI.scrollbar(bx + bw - pad + Theme.space.xs, self.view.y, view_h, view_h / content_h, self.scroll / max_scroll)
  end

  -- Ferris stands beside the title, top right, only while the card holds
  -- still: over a scrolling stack he would be standing on whichever row
  -- went past.
  if self.app.wallet_lib and max_scroll == 0 then
    local bob = Anim.bob(Anim.now(), { amount = 2, period = 2.6 })
    Assets.sprite("sprite_ferris", bx + bw - pad - 36, self.view.y + UI.lead("display") + UI.lead("label") + bob,
      64, { alpha = alpha })
  end

  local hints
  if self.mode == "new_show" then
    hints = {
      { key = "ENTER", verb = I18n.t("create") },
      { key = "C", verb = I18n.t("copy") },
      { key = "ESC", verb = I18n.t("cancel") },
    }
  else
    hints = {
      { key = "TAB", verb = I18n.t("field") },
      { key = "ENTER", verb = I18n.t("sign in") },
      { key = "N", verb = I18n.t("new wallet") },
      { key = "F2", verb = I18n.t("reveal") },
      { key = "F10", verb = I18n.t("story") },
    }
  end
  self.app:footer(hints)

  if self.mode == "new_show" and self.words then self:draw_new_show() end
end

--- The refusal or the status, as a card with a rule in the role's colour
--- under the field — never a toast, which would be gone before it was read.
--- Three lines at most. Only put when there is something to say.
function Login:message_row(put, width)
  local message = self.error or self.status
  if not message then return end
  local font = UI.font("label")
  local lines = UI.wrapWith(message, width - Theme.space.md * 2, font)
  local n = math.min(#lines, 3)
  local lead = UI.lead("label")
  local h = Theme.stripH + Theme.space.md * 2 + n * lead
  local bad = self.error ~= nil
  put(h, function(y)
    UI.card(0, y, width, h, { strip = bad and Theme.redA or Theme.blue, pad = 0, shadowDy = 4 })
    for i = 1, n do
      local line = lines[i]
      if i == n and #lines > n then line = UI.ellipsizeWith(line .. "…", width - Theme.space.md * 2, font) end
      UI.label(line, Theme.space.md, y + Theme.stripH + Theme.space.md + (i - 1) * lead, "label",
        { color = bad and Theme.text or Theme.text, shadow = false })
    end
  end, { message = true })
end

--- The phrase well: the words on a grid in the code face, numbered, the
--- empty slots counted out to twelve; a private key as wrapped hex. The
--- grid is 6×2 when the widest word fits six across, else 4×3, measured
--- from the face — and it grows for a longer phrase.
function Login:well_shape(inner, font)
  local w0 = inner - Theme.space.md * 2
  local numw = UI.labelWidth("12", "label") + Theme.space.sm
  local widest = font:getWidth("umbrella")
  for word in self:masked():gmatch("%S+") do widest = math.max(widest, font:getWidth(word)) end
  local cell_need = numw + widest + Theme.space.sm
  local cols = 2
  for _, c in ipairs({ 6, 4, 3 }) do
    if w0 / c >= cell_need then cols = c; break end
  end
  local n = 0
  for _ in self.secret:gmatch("%S+") do n = n + 1 end
  local rows_n = math.ceil(math.max(12, n) / cols)
  local cell_h = font:getHeight() + Theme.space.sm
  local key = Wallet.looks_like_private_key(self.secret)
    or (not self.secret:find("%s") and #self.secret > 24)
  if key then rows_n = math.max(2, #UI.wrapWith(self:masked(), w0, font)) end
  return { cols = cols, rows = rows_n, cell_h = cell_h, numw = numw, w0 = w0, key = key,
    h = rows_n * cell_h + Theme.space.md * 2, words = n }
end

function Login:draw_well(y, inner, shape, font)
  local focused = self.focus == 1
  UI.card(0, y, inner, shape.h, { variant = "well", pad = 0 })
  if focused then UI.stroke(0, y, inner, shape.h, Theme.radiusInner, Theme.gold) end
  local shown = self:masked()
  local x0, y0 = Theme.space.md, y + Theme.space.md
  local fh = font:getHeight()
  local cell_h = shape.cell_h
  love.graphics.setFont(font)
  if shown == "" then
    UI.setColor(Theme.mute, 0.6)
    love.graphics.print(UI.ellipsizeWith(I18n.t("twelve words, or 0x + 64 hex"), shape.w0, font),
      x0, y0 + math.floor((cell_h - fh) / 2))
    if focused then caret(self, x0, y0 + math.floor((cell_h - fh) / 2), fh) end
  elseif shape.key then
    local lines = UI.wrapWith(shown, shape.w0, font)
    local last_w = 0
    for i, line in ipairs(lines) do
      UI.setColor(Theme.text)
      love.graphics.print(line, x0, y0 + (i - 1) * cell_h + math.floor((cell_h - fh) / 2))
      last_w = font:getWidth(line)
    end
    if focused then
      local row = math.max(1, #lines)
      caret(self, x0 + last_w + 2, y0 + (row - 1) * cell_h + math.floor((cell_h - fh) / 2), fh)
    end
  else
    local words = {}
    for word in shown:gmatch("%S+") do words[#words + 1] = word end
    local cw = shape.w0 / shape.cols
    local lead = UI.lead("label")
    local n = math.max(12, #words)
    for i = 1, n do
      local col, row = (i - 1) % shape.cols, math.floor((i - 1) / shape.cols)
      local x, yy = x0 + col * cw, y0 + row * cell_h
      UI.label(tostring(i), x, yy + math.floor((cell_h - lead) / 2), "label",
        { color = Theme.mute, alpha = words[i] and 0.9 or 0.4, shadow = false })
      if words[i] then
        love.graphics.setFont(font)
        UI.setColor(Theme.text)
        love.graphics.print(words[i], x + shape.numw, yy + math.floor((cell_h - fh) / 2))
      end
    end
    if focused then
      -- After the last word, or in the next slot once a space was typed.
      local at = #words
      local trailing = self.secret:sub(-1):match("%s") ~= nil
      local slot = trailing and (at + 1) or math.max(1, at)
      local col, row = (slot - 1) % shape.cols, math.floor((slot - 1) / shape.cols)
      local cx = x0 + col * cw + shape.numw
      if not trailing and words[at] then cx = cx + font:getWidth(words[at]) + 2 end
      caret(self, cx, y0 + row * cell_h + math.floor((cell_h - fh) / 2), fh)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

--- A button inside the card, with the rect it actually drew kept for the
--- hit test (a label never shrinks: a box too small for it grows).
function Login:button(id, x, y, w, h, label, state, opts)
  opts.id = "login:" .. id
  self.hits[id] = UI.button(x, y, w, h, label, state, nil, opts)
end

--- The width a button `h` tall needs for `label` and its keycap: the title
--- face in a 56-tall button, the label face in a 44-tall one.
local function need(label, key, h)
  return (UI.buttonSize(label, { h = h, key = key }))
end

--- The height a button `w` wide can set `label` at: the L button (56, the
--- title face) when that fits, else the M button (44, the label face) —
--- a double-width face like ARCADE steps the row down rather than growing
--- the box past the card. Measured with `UI.buttonSize`, so the box never
--- has to grow.
local function fit_h(label, key, w)
  if need(label, key, Theme.control.buttonL) <= w then return Theme.control.buttonL end
  return Theme.control.buttonM
end

function Login:rows_signin(inner)
  local put, rows, height = stack()
  local portrait = Layout.isPortrait()
  local font = code_font()
  local lead = UI.lead("label")
  local fh = field_height(font)
  local lf = UI.font("label")

  -- The title and its line.
  put(UI.lead("display"), function(y)
    UI.label(I18n.t("SIGN IN"), 0, y, "display", { color = Theme.gold, width = inner, ellipsis = true })
  end, { gap = 0 })
  put(lead, function(y)
    UI.label(I18n.t("your wallet is your account"), 0, y, "label",
      { color = Theme.mute, width = inner, ellipsis = true })
  end)

  -- The phrase: its label, F2 at the right, then the well.
  local reveal = { { key = "F2", verb = I18n.t("reveal") } }
  put(Theme.control.keycap, function(y)
    local hw = UI.hintWidth(reveal)
    UI.label(I18n.t("MNEMONIC OR PRIVATE KEY"), 0, y + 2, "label",
      { color = Theme.mute, caps = true, width = inner - hw - Theme.space.md, ellipsis = true })
    UI.hint(0, y, reveal, { w = inner, align = "right" })
  end, { gap = Theme.space.xs })
  local shape = self:well_shape(inner, font)
  put(shape.h, function(y)
    self:draw_well(y, inner, shape, font)
    self.hits.field1 = { x = 0, y = y, w = inner, h = shape.h }
  end, { focus = self.focus == 1, gap = Theme.space.xs })

  -- The refusal, right under the field it refuses.
  self:message_row(put, inner)

  -- What the phrase looks like so far, the account it derives, and the
  -- path it goes through — one row under the well.
  put(lead, function(y)
    local shown
    if shape.key then
      shown = I18n.t("private key")
    elseif shape.words > 0 then
      shown = shape.words == 1 and I18n.t("%d word", 1) or I18n.t("%d words", shape.words)
    else
      shown = ""
    end
    -- The real path, not a picture of one: the account index is in it.
    local path = ("m/44'/60'/0'/0/%d"):format(self:account_index())
    local pw = lf:getWidth(path)
    UI.label(path, inner - pw, y, "label", { color = Theme.mute })
    local x = 0
    if shown ~= "" then
      UI.label(shown, 0, y, "label", { color = Theme.mute })
      x = lf:getWidth(shown) + Theme.space.md
    end
    if self.preview then
      -- The address all of it produces, so somebody can see which of their
      -- wallets they are about to become before pressing ENTER rather than
      -- finding out by arriving as somebody else. Fitted, never wrapped: an
      -- address across two lines reads as two addresses.
      local room = inner - pw - Theme.space.md - x
      local a = tostring(self.preview)
      if lf:getWidth(a) > room then a = short_address(a) end
      UI.label(UI.ellipsizeWith(a, room, lf), x, y, "label", { color = Theme.gold })
    end
  end)

  -- ACCOUNT and DISPLAY NAME on one row: the index is a short box, the
  -- name takes the rest.
  local idx_w = math.max(120, lf:getWidth(I18n.t("ACCOUNT")) + Theme.space.lg)
  local name_x = idx_w + Theme.space.md
  put(lead, function(y)
    UI.label(I18n.t("ACCOUNT"), 0, y, "label", { color = Theme.mute, caps = true, width = idx_w, ellipsis = true })
    UI.label(I18n.t("DISPLAY NAME"), name_x, y, "label",
      { color = Theme.mute, caps = true, width = inner - name_x, ellipsis = true })
  end, { gap = Theme.space.xs })
  put(fh, function(y)
    field_box(self, 0, y, idx_w, fh, self.index, self.focus == 2, "0", font)
    self.hits.field2 = { x = 0, y = y, w = idx_w, h = fh }
    field_box(self, name_x, y, inner - name_x, fh, self.name, self.focus == 3,
      I18n.t("filled in from the address"), font)
    self.hits.field3 = { x = name_x, y = y, w = inner - name_x, h = fh }
  end, { focus = self.focus == 2 or self.focus == 3, gap = Theme.space.lg })

  -- SIGN IN, the one primary, and NEW WALLET beside it — stacked upright.
  -- Given equal weight rather than tucked in a corner: on a first run it is
  -- the only button that can do anything.
  local bl, bm = Theme.control.buttonL, Theme.control.buttonM
  local signin_label = self.busy and I18n.t("SIGNING…") or I18n.t("SIGN IN")
  local new_label = I18n.t("NEW WALLET")
  local signin_state = self:can_submit() and (self.hover == "signin" and "hot" or "normal") or "disabled"
  local new_state = self.busy and "disabled" or (self.hover == "new" and "hot" or "normal")
  -- Side by side when both fit a half as L buttons, or both as M buttons;
  -- stacked otherwise (and always upright).
  local half = math.floor((inner - Theme.space.lg) / 2)
  local stacked, bh = portrait, bl
  if not stacked and math.max(need(signin_label, "ENTER", bl), need(new_label, "N", bl)) > half then
    if math.max(need(signin_label, "ENTER", bm), need(new_label, "N", bm)) <= half then bh = bm else stacked = true end
  end
  if stacked then
    local sh, nh = fit_h(signin_label, "ENTER", inner), fit_h(new_label, "N", inner)
    put(sh, function(y)
      self:button("signin", 0, y, inner, sh, signin_label, signin_state, { variant = "primary", key = "ENTER" })
    end)
    put(nh, function(y)
      self:button("new", 0, y, inner, nh, new_label, new_state, { variant = "secondary", key = "N" })
    end, { gap = Theme.space.lg })
  else
    put(bh, function(y)
      self:button("signin", 0, y, half, bh, signin_label, signin_state, { variant = "primary", key = "ENTER" })
      self:button("new", inner - half, y, half, bh, new_label, new_state, { variant = "secondary", key = "N" })
    end, { gap = Theme.space.lg })
  end

  -- The ghosts: SERVER as a chip that opens, the kept key as a chip, WATCH
  -- STORY. Flowed, so a wide face or a narrow card wraps them rather than
  -- running them off the edge.
  local items = {}
  local chip_h = Theme.control.chip
  local server_label = I18n.t("SERVER · %s", host_of(self.app.server))
  items[#items + 1] = { id = "server", w = UI.chipWidth(server_label), h = chip_h, label = server_label }
  local kept = self:kept_address()
  if kept then
    items[#items + 1] = { id = "kept", w = code_chip(0, 0, I18n.t("KEPT KEY"), short_address(kept), font, nil, true),
      h = chip_h, code = short_address(kept) }
  end
  local story_label = I18n.t("WATCH STORY")
  local story_w, story_h = UI.buttonSize(story_label, { h = Theme.control.buttonM, key = "F10" })
  story_h = math.max(Theme.control.buttonM, story_h)
  items[#items + 1] = { id = "story", w = math.min(inner, story_w), h = story_h }
  local line_h = story_h
  local x, line = 0, 0
  for _, it in ipairs(items) do
    if x > 0 and x + it.w > inner then x, line = 0, line + 1 end
    it.x, it.line = x, line
    x = x + it.w + Theme.space.md
  end
  local story = items[#items]
  if story.line == 0 then story.x = inner - story.w end
  local flow_h = (line + 1) * line_h + line * Theme.space.sm
  put(flow_h, function(y)
    for _, it in ipairs(items) do
      local iy = y + it.line * (line_h + Theme.space.sm) + math.floor((line_h - it.h) / 2)
      if it.id == "server" then
        UI.chip(it.x, iy, it.label, { selected = self.server_open, hot = self.hover == "server" })
      elseif it.id == "kept" then
        code_chip(it.x, iy, I18n.t("KEPT KEY"), it.code, font, { hot = self.hover == "kept" })
      else
        self:button("story", it.x, iy, it.w, it.h, story_label,
          self.hover == "story" and "hot" or "normal", { variant = "ghost", key = "F10" })
        self.story_button = self.hits.story
      end
      if it.id ~= "story" then self.hits[it.id] = { x = it.x, y = iy, w = it.w, h = it.h } end
    end
  end)

  -- The server field, under its chip, when the chip is open. On this
  -- screen because `CWBH_SERVER` is not discoverable from inside the game,
  -- and the backend runs on `0.0.0.0` so a phone on the same tailnet is a
  -- real thing somebody wants to point at.
  if self.server_open then
    put(lead, function(y)
      UI.label(I18n.t("SERVER  (ENTER APPLIES)"), 0, y, "label",
        { color = Theme.mute, caps = true, width = inner, ellipsis = true })
    end, { gap = Theme.space.xs })
    put(fh, function(y)
      field_box(self, 0, y, inner, fh, self.server, self.focus == 4, App.DEFAULT_SERVER, font)
      self.hits.field4 = { x = 0, y = y, w = inner, h = fh }
    end, { focus = self.focus == 4, gap = Theme.space.xs })
    -- The line under it: a refusal, the override, or the live state.
    local note, color
    if self.server_error then
      note, color = self.server_error, Theme.redA
    elseif self.app.server_override then
      -- Precedence, said out loud. The field still saves; it just does not
      -- win this run, and pretending otherwise would make the control a lie.
      note, color = I18n.t("CWBH_SERVER sets the server this run; the field is saved for next launch"), Theme.mute
    else
      local live = self.app.client and self.app.client.state or "idle"
      note, color = I18n.t("in use: %s  [%s]", self.app.server, live), Theme.mute
    end
    local lines = UI.wrapWith(note, inner, lf)
    local n = math.min(#lines, 2)
    put(n * lead, function(y)
      for i = 1, n do
        UI.label(lines[i], 0, y + (i - 1) * lead, "label", { color = color, width = inner, ellipsis = i == n })
      end
    end)
  end

  -- The promise.
  local note = I18n.t("nothing typed here is ever sent. only a signature leaves this machine.")
  local note_lines = UI.wrapWith(note, inner, lf)
  local nn = math.min(#note_lines, 2)
  put(nn * lead, function(y)
    for i = 1, nn do
      UI.label(note_lines[i], 0, y + (i - 1) * lead, "label",
        { color = Theme.mute, width = inner, ellipsis = i == nn })
    end
  end, { gap = 0 })

  return rows, height()
end

--- The first-run failure: the key library is not built. A red-ruled card
--- with the one command that fixes it.
function Login:rows_no_library(inner)
  local put, rows, height = stack()
  local lead = UI.lead("label")
  local lf = UI.font("label")
  local font = code_font()

  put(UI.lead("display"), function(y)
    UI.label(I18n.t("SIGN IN"), 0, y, "display", { color = Theme.gold, width = inner, ellipsis = true })
  end, { gap = 0 })
  put(lead, function(y)
    UI.label(I18n.t("your wallet is your account"), 0, y, "label",
      { color = Theme.mute, width = inner, ellipsis = true })
  end)

  local pad = Theme.space.md
  local body = UI.wrapWith(I18n.t("Deriving an address needs the small Rust library in love2d/ffi. "
    .. "Build it once and restart:"), inner - pad * 2, lf)
  local detail = tostring(self.app.wallet_error or Wallet.last_error() or "")
  local detail_lines = UI.wrapWith(detail:match("^[^\n]*") or "", inner - pad * 2, lf)
  local nd = math.min(#detail_lines, 2)
  local cmd = "make -C love2d ffi"
  local cmd_h = font:getHeight() + Theme.space.lg
  local box_h = Theme.stripH + pad + UI.lead("title") + Theme.space.sm + #body * lead + Theme.space.sm
    + cmd_h + Theme.space.sm + nd * lead + pad
  put(box_h, function(top)
    UI.card(0, top, inner, box_h, { strip = Theme.redA, pad = 0 })
    local y = top + Theme.stripH + pad
    y = y + UI.label(I18n.t("KEY LIBRARY NOT BUILT"), pad, y, "title",
      { color = Theme.redA, width = inner - pad * 2, ellipsis = true }) + Theme.space.sm
    for _, line in ipairs(body) do
      y = y + UI.label(line, pad, y, "label")
    end
    y = y + Theme.space.sm
    UI.card(pad, y, inner - pad * 2, cmd_h, { variant = "well", pad = 0 })
    love.graphics.setFont(font)
    UI.setColor(Theme.gold)
    love.graphics.print(cmd, pad + Theme.space.md, y + math.floor((cmd_h - font:getHeight()) / 2))
    love.graphics.setColor(1, 1, 1, 1)
    y = y + cmd_h + Theme.space.sm
    for i = 1, nd do
      y = y + UI.label(detail_lines[i], pad, y, "label", { color = Theme.mute, width = inner - pad * 2, ellipsis = true })
    end
  end)
  self:message_row(put, inner)

  return rows, height()
end

--- WRITE THIS DOWN: the sheet over the card. The twelve words as keycaps on
--- a grid, the address as a chip with COPY, the warning, one primary and a
--- way out. Measured against the sheet's room, so the body gives up lines
--- before anything is cut.
function Login:draw_new_show()
  local vw, vh = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  local pad = portrait and Theme.space.lg or Theme.space.xl
  local w = portrait and (vw - Theme.space.lg * 2) or math.min(720, vw - pad * 2)
  local inner = w - pad * 2
  local font = code_font()
  local lf = UI.font("label")
  local lead = UI.lead("label")
  local hits = {}
  self.sheet_hits = hits

  -- Measure.
  local warn = UI.wrapWith(I18n.t("this is the only copy. there is no reset."), inner, lf)
  local warn_n = math.min(#warn, 2)
  local gap = Theme.space.sm
  local numw = UI.labelWidth("12", "label") + Theme.space.sm
  local widest = 0
  for _, word in ipairs(self.words) do widest = math.max(widest, font:getWidth(word)) end
  local cell_need = Theme.space.md + numw + widest + Theme.space.md
  local cols = 2
  for _, c in ipairs({ 4, 3 }) do
    if (inner - gap * (c - 1)) / c >= cell_need then cols = c; break end
  end
  local grid_rows = math.ceil(#self.words / cols)
  local cell_h = math.max(Theme.control.buttonM, font:getHeight() + Theme.space.lg)
  local grid_h = grid_rows * cell_h + (grid_rows - 1) * gap
  local addr_h = Theme.control.buttonM
  local body = I18n.t("Write them on paper, in order. Anyone who reads them owns the account, "
    .. "and nobody — not this game, not the server — can recover them for you.")
  local bl, bm = Theme.control.buttonL, Theme.control.buttonM
  local written = self.busy and I18n.t("SIGNING…") or I18n.t("I HAVE WRITTEN IT DOWN")
  local cancel_label = I18n.t("CANCEL")
  -- The primary keeps the title face as long as the sheet is wide enough
  -- for it: beside the way out when both fit as L buttons, else stacked
  -- over an M ghost; only a face too wide for even that (ARCADE) steps the
  -- primary down to M, beside or stacked the same way. Always stacked
  -- upright.
  local side, wh = false, bl
  if not portrait and need(written, "ENTER", bl) + Theme.space.md + need(cancel_label, "ESC", bl) <= inner then
    side = true
  elseif need(written, "ENTER", bl) <= inner then
    wh = bl
  elseif not portrait and need(written, "ENTER", bm) + Theme.space.md + need(cancel_label, "ESC", bm) <= inner then
    side, wh = true, bm
  else
    wh = bm
  end
  local cancel_h = side and wh or bm
  local cancel_w = need(cancel_label, "ESC", cancel_h)
  local buttons_h = side and wh or (wh + Theme.space.md + cancel_h)
  local after = I18n.t("this signs in and takes you to the map.")
  local message = self.error or self.status
  local msg_h = 0
  if message then msg_h = Theme.stripH + Theme.space.md * 2 + lead + Theme.rowGap end
  local fixed = warn_n * lead + Theme.rowGap + grid_h + Theme.rowGap + addr_h + Theme.rowGap
    + Theme.space.lg + buttons_h + Theme.space.sm + lead + msg_h
  -- The sheet's own clamp, as `UI.modal` applies it.
  local room = vh - UI.footerHeight() - pad * 2 - pad * 2 - (UI.lead("title") + Theme.space.md)
  local body_h, body_lead = UI.readHeight(body, inner)
  local body_lines = math.floor(body_h / body_lead)
  -- The warning is the one sentence here that must not end in "…": when
  -- the reading face at this type step cannot give it every line, it is set
  -- in label-16 instead, which never moves with F12.
  local body_small = nil
  if body_lines * body_lead > room - fixed then
    body_small = UI.wrapWith(body, inner, lf)
    body_lead = lead
    body_lines = math.max(1, math.min(#body_small, math.floor((room - fixed) / lead)))
  end
  body_h = body_lines * body_lead
  local content_h = fixed + body_h

  local x, y, cw, ch, close, sheet = UI.modal({ id = "newwallet", title = I18n.t("WRITE THIS DOWN"),
    w = w, h = content_h })
  hits.close = close
  hits.sheet = sheet
  inner = cw
  local cy = y

  -- The copy is doing the work now that nothing gates the button.
  for i = 1, warn_n do
    UI.label(warn[i], x, cy, "label", { color = Theme.redA, width = inner, ellipsis = i == warn_n })
    cy = cy + lead
  end
  cy = cy + Theme.rowGap

  -- The grid: keycaps, numbered, in reading order. The words are set in
  -- the code face: they are the one thing on this screen a player copies
  -- letter by letter.
  local cell_w = math.floor((inner - gap * (cols - 1)) / cols)
  for i, word in ipairs(self.words) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local kx, ky = x + col * (cell_w + gap), cy + row * (cell_h + gap)
    UI.setColor(Theme.edge)
    UI.rrect("fill", kx, ky + 3, cell_w, cell_h - 3, Theme.radiusSm)
    UI.setColor(Theme.cardHi)
    UI.rrect("fill", kx, ky, cell_w, cell_h - 3, Theme.radiusSm)
    UI.stroke(kx, ky, cell_w, cell_h - 3, Theme.radiusSm, Theme.edge)
    UI.label(tostring(i), kx + Theme.space.md, ky + math.floor((cell_h - 3 - lead) / 2), "label",
      { color = Theme.mute, shadow = false })
    love.graphics.setFont(font)
    UI.setColor(Theme.text)
    love.graphics.print(word, kx + Theme.space.md + numw, ky + math.floor((cell_h - 3 - font:getHeight()) / 2))
    love.graphics.setColor(1, 1, 1, 1)
  end
  cy = cy + grid_h + Theme.rowGap

  -- The address as a chip — kept on screen on purpose: it is how a player
  -- checks later that the paper in the drawer is the account they are
  -- signed in to. The whole thing when it fits, the middle dropped when not.
  local copy_label = I18n.t("COPY")
  local copy_w = math.max(88, (UI.buttonSize(copy_label, { h = addr_h })))
  local caption = (I18n.t("this wallet:  "):gsub("%s+$", ""))
  local address = tostring(self.new_address)
  local room_w = inner - copy_w - Theme.space.md
  if code_chip(0, 0, caption, address, font, nil, true) > room_w then address = short_address(address) end
  if code_chip(0, 0, caption, address, font, nil, true) > room_w then caption = "" end
  local chip_w = code_chip(x, cy + math.floor((addr_h - Theme.control.chip) / 2), caption, address, font,
    { hot = self.hover == "address" })
  hits.address = { x = x, y = cy, w = chip_w, h = addr_h }
  local copy_x = x + inner - copy_w
  hits.copy = UI.button(copy_x, cy, copy_w, addr_h, copy_label, self.hover == "copy" and "hot" or "normal", nil,
    { variant = "secondary", id = "login:copy" })
  cy = cy + addr_h + Theme.rowGap

  if body_small then
    for i = 1, body_lines do
      UI.label(body_small[i], x, cy + (i - 1) * lead, "label", { width = inner, ellipsis = i == body_lines })
    end
  else
    UI.read(body, x, cy, inner, { maxLines = body_lines })
  end
  cy = cy + body_h + Theme.space.lg

  -- I HAVE WRITTEN IT DOWN, and the way out beside it.
  local wstate = self.busy and "disabled" or (self.hover == "written" and "hot" or "normal")
  local cstate = self.hover == "cancel" and "hot" or "normal"
  if side then
    hits.written = UI.button(x, cy, inner - cancel_w - Theme.space.md, wh, written, wstate, nil,
      { variant = "primary", id = "login:written", key = "ENTER" })
    hits.cancel = UI.button(x + inner - cancel_w, cy, cancel_w, wh, cancel_label, cstate, nil,
      { variant = "ghost", id = "login:cancel", key = "ESC" })
  else
    hits.written = UI.button(x, cy, inner, wh, written, wstate, nil,
      { variant = "primary", id = "login:written", key = "ENTER" })
    hits.cancel = UI.button(x, cy + wh + Theme.space.md, inner, cancel_h, cancel_label, cstate, nil,
      { variant = "ghost", id = "login:cancel", key = "ESC" })
  end
  cy = cy + buttons_h + Theme.space.sm
  UI.label(after, x, cy, "label", { color = Theme.mute, width = inner, ellipsis = true })
  cy = cy + lead

  if message then
    cy = cy + Theme.rowGap
    local h = Theme.stripH + Theme.space.md * 2 + lead
    UI.card(x, cy, inner, h, { strip = self.error and Theme.redA or Theme.blue, pad = 0, shadowDy = 4 })
    UI.label(UI.ellipsizeWith(message, inner - Theme.space.md * 2, lf), x + Theme.space.md,
      cy + Theme.stripH + Theme.space.md, "label", { shadow = false })
  end
end

-- -------------------------------------------------------------------- input

function Login:textinput(text)
  if self.busy or not self.app.wallet_lib then return end
  if self.mode ~= "signin" then return end
  local name = self:field()
  if name == "index" then
    -- Digits only, in the box itself, so what is on screen is what will be
    -- derived from. Anything else is simply not taken.
    text = text:gsub("%D", "")
    if text == "" then return end
    self[name] = (self[name] .. text):sub(1, 10)
    self:forget_preview()
    return
  end
  self[name] = self[name] .. text
  if name == "name" then self.name_touched = true end
  if name == "secret" then self:forget_preview() end
  if name == "server" then self.server_error = nil end
end

--- Open or close the SERVER chip. Opening puts the caret in the field;
--- closing takes it back to the phrase.
function Login:toggle_server()
  self.server_open = not self.server_open
  if self.server_open then
    self.focus = 4
  elseif self.focus == 4 then
    self.focus = 1
  end
  SFX.play("move")
end

function Login:keypressed(key, mods)
  mods = mods or {}
  local cmd = mods.ctrl or mods.gui

  if not self.app.wallet_lib then return false end

  -- ------------------------------------------------------------ new_show
  if self.mode == "new_show" then
    if key == "return" or key == "kpenter" or key == "space" then
      UI.press("login:written", self.sheet_hits and self.sheet_hits.written, { sfx = false })
      self:create_wallet()
      return true
    end
    if key == "c" then
      self:copy_phrase()
      return true
    end
    if key == "escape" then
      self:cancel_new()
      return true
    end
    return true -- the sheet is modal: nothing else happens while it is up
  end

  -- -------------------------------------------------------------- signin
  if key == "n" and self.secret == "" and self:field() ~= "server" and self:field() ~= "name" then
    UI.press("login:new", nil, { sfx = false })
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
    if self.focus == 4 then self.server_open = true end
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
    if name == "name" then self.name_touched = true end
    if name == "secret" or name == "index" then self:forget_preview() end
    return true
  end
  if key == "v" and cmd then
    local text = love.system.getClipboardText() or ""
    local name = self:field()
    if name == "index" then
      -- A pasted index is digits or it is nothing; a phrase pasted into the
      -- wrong box should not silently become account 0.
      self[name] = (self[name] .. text:gsub("%D", "")):sub(1, 10)
      self:forget_preview()
      return true
    end
    -- A pasted phrase arrives with whatever the source wrapped it in.
    self[name] = self[name] .. text:gsub("%s+", " "):gsub("^%s", "")
    if name == "name" then self.name_touched = true end
    if name == "secret" then self:forget_preview() end
    return true
  end
  if key == "return" or key == "kpenter" then
    if self:field() == "server" then
      self:apply_server()
    else
      UI.press("login:signin", nil, { sfx = false })
      self:submit()
    end
    return true
  end
  if key == "escape" then
    if self.server_open then
      self:toggle_server()
    else
      self.secret = ""
      self:forget_preview()
    end
    return true
  end
  return false
end

--- A point in card coordinates: inside the view and past the scroll, or nil.
function Login:panel_point(x, y)
  local v = self.view
  if not v then return nil end
  if x < v.x or x > v.x + v.w or y < v.y or y > v.y + v.h then return nil end
  return x - v.x, y - v.y + (self.scroll or 0)
end

--- The hit under a card-local point, by id.
function Login:hit_at(lx, ly)
  for id, r in pairs(self.hits or {}) do
    if lx >= r.x and lx <= r.x + r.w and ly >= r.y and ly <= r.y + r.h then return id, r end
  end
  return nil
end

--- A card-local rect, in screen coordinates (for the press's spark).
function Login:screen_rect(r)
  local v = self.view
  if not (r and v) then return nil end
  return { x = v.x + r.x, y = v.y + r.y - (self.scroll or 0), w = r.w, h = r.h }
end

function Login:mousemoved(x, y)
  if self.mode == "new_show" then
    self.hover = nil
    for id, r in pairs(self.sheet_hits or {}) do
      if id ~= "sheet" and UI.inside(r, x, y) then self.hover = id end
    end
    return
  end
  local lx, ly = self:panel_point(x, y)
  self.hover = lx and self:hit_at(lx, ly) or nil
end

function Login:mousepressed(x, y)
  if not self.app.wallet_lib then return end

  if self.mode == "new_show" then
    local h = self.sheet_hits or {}
    if UI.inside(h.written, x, y) then
      UI.press("login:written", h.written, { sfx = false })
      self:create_wallet()
    elseif UI.inside(h.copy, x, y) then
      UI.press("login:copy", h.copy)
      self:copy_address()
    elseif UI.inside(h.address, x, y) then
      self:copy_address()
    elseif UI.inside(h.cancel, x, y) or UI.inside(h.close, x, y) or (h.sheet and not UI.inside(h.sheet, x, y)) then
      self:cancel_new()
    end
    return
  end

  local lx, ly = self:panel_point(x, y)
  if not lx then return end
  local id, r = self:hit_at(lx, ly)
  if not id then return end
  local field = id:match("^field(%d)$")
  if field then
    self.focus = tonumber(field)
    return
  end
  if id == "signin" then
    if self:can_submit() then UI.press("login:signin", self:screen_rect(r), { sfx = false }) end
    self:submit()
  elseif id == "new" then
    if not self.busy then UI.press("login:new", self:screen_rect(r), { sfx = false }) end
    self:new_wallet()
  elseif id == "story" then
    UI.press("login:story", self:screen_rect(r), { sfx = false })
    self:watch_story()
  elseif id == "server" then
    self:toggle_server()
  elseif id == "kept" then
    self:use_kept()
  end
end

--- The wheel scrolls the card when there is more card than window; `draw`
--- clamps whatever this leaves.
function Login:wheelmoved(_, dy)
  self.scroll = (self.scroll or 0) - dy * 40
end

return Login
