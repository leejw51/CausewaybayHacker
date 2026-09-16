-- The shell: one websocket, one session, one scene at a time.
--
-- Screens, per SPEC §10:
--
--   boot → title → (story) → login → lands → categories → map → quest → result
--
-- plus `search`, `stats` and `ai` reachable from the map, and `playground`
-- from either. `stats` is live; `search` and `ai` are built against their
-- contracts and render whatever the server answers — including `unavailable`
-- (§3.3), which is said in the story's voice and offers no retry, because
-- retrying a feature that does not exist yet never helps.
--
-- **Nothing in here decides a game rule.** No scene knows whether an answer
-- is right, which node unlocks next, or what a quest is worth. Those are
-- `quest.submit.ok`, `progress.update` and `world.map`. If a diff to this
-- directory ever adds a rule, it is in the wrong repository — see
-- `docs/decisions.md`, first entry.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local CRT = require("src.crt")
local SFX = require("src.sfx")
local Store = require("src.store")
local I18n = require("src.i18n")
local Anim = require("src.anim")
local Clock = require("src.clock")
local Wallet = require("src.wallet")
local Session = require("src.session")
local netclient = require("src.net.client")
local socket_transport = require("src.net.socket")

local App = {}
App.__index = App

local SCENES = {
  boot = "src.scenes.boot",
  title = "src.scenes.title",
  story = "src.scenes.story",
  login = "src.scenes.login",
  lands = "src.scenes.lands",
  categories = "src.scenes.categories",
  map = "src.scenes.map",
  quest = "src.scenes.quest",
  result = "src.scenes.result",
  search = "src.scenes.search",
  stats = "src.scenes.stats",
  ai = "src.scenes.ai",
  playground = "src.scenes.playground",
}

App.DEFAULT_SERVER = "ws://127.0.0.1:5390/ws"

--- Is a URL one this client can actually open?
---
--- Shape first, then capability, and the message says which — "failing to
--- connect for unexplained reasons" is the thing this exists to prevent.
--- Returns true, or nil and a sentence.
function App.check_server(url)
  url = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if url == "" then return nil, "type a server address" end
  local scheme = url:match("^(%a[%w+.-]*)://")
  if not scheme then
    return nil, "needs a scheme: ws://host:port/ws"
  end
  scheme = scheme:lower()
  if scheme == "http" or scheme == "https" then
    return nil, ("this is a websocket address — try ws%s://…")
      :format(scheme == "https" and "s" or "")
  end
  if scheme == "wss" then
    -- Honest rather than mysterious: LuaSocket has no TLS, so this client
    -- genuinely cannot open one, and a tailnet or an SSH tunnel is the
    -- answer rather than a scheme change.
    return nil, "wss:// needs TLS, which this client does not have — use ws:// over a tailnet"
  end
  if scheme ~= "ws" then
    return nil, ("scheme %q is not ws://"):format(scheme)
  end
  local rest = url:sub(#scheme + 4)
  local hostport = rest:match("^([^/]+)") or ""
  if hostport == "" then return nil, "no host" end
  local host, port = hostport:match("^(.*):(%d+)$")
  if not host then
    return nil, "needs a port: ws://host:5390/ws"
  end
  if host == "" then return nil, "no host before the port" end
  port = tonumber(port)
  if port < 1 or port > 65535 then return nil, "the port is out of range" end
  if not rest:find("/") then
    return nil, "needs a path: ws://host:5390/ws"
  end
  return true
end

--- `opts.home` is `main.lua`'s `--home` flag — SPEC §1.1's first step of
--- precedence, ahead of `CWBH_LOVE2D_HOME` and the default.
function App.new(opts)
  opts = opts or {}
  local self = setmetatable({
    home = opts.home,
    scene = nil,
    scene_name = nil,
    toast_text = nil,
    toast_left = 0,
    log_lines = {},
    -- Resolved in `load`, once the store is open.
    server = App.DEFAULT_SERVER,
    -- `CWBH_SERVER`, if it is set. A launch-time override wins for the run
    -- (see `App:resolve_server`) and the login screen says so rather than
    -- silently ignoring what the player typed.
    server_override = (function()
      local value = os.getenv("CWBH_SERVER")
      if value and value ~= "" then return value end
      return nil
    end)(),
    -- What the player picked on the way down; the map and quest screens read
    -- it, and `back` walks it up again.
    land = nil,
    category = nil,
    quest_id = nil,
    last_attempt = nil,
  }, App)
  return self
end

function App:log(level, message)
  local line = ("[%s] %s"):format(level, message)
  print(line)
  self.log_lines[#self.log_lines + 1] = line
  if #self.log_lines > 200 then table.remove(self.log_lines, 1) end
end

--- Which server this run talks to, and why.
---
--- **Precedence, written down because a control that is silently ignored is
--- a lie:** `CWBH_SERVER` is a launch-time override and wins for this run;
--- otherwise the field the player saved; otherwise the default. Editing the
--- field always persists, and when an override is active the login screen
--- says the saved value takes effect next launch instead of pretending.
function App:resolve_server()
  if self.server_override then return self.server_override, "CWBH_SERVER" end
  local saved = Store.saved_server()
  if saved and App.check_server(saved) then return saved, "saved" end
  return App.DEFAULT_SERVER, "default"
end

function App:load()
  Assets.load()
  SFX.load()

  -- The motion layer's clock. `src/anim.lua` is pure and has no clock of its
  -- own; the game gives it this one, and a drive script can pin it so a
  -- screenshot of a bobbing mascot is the same screenshot every run.
  Anim.set_clock(function() return love.timer.getTime() end)
  -- The quest clock's wall time (§4.8b). `os.time()` alone stutters at one
  -- second; `love.timer.getTime()` alone starts at an arbitrary zero. Pinned
  -- together at startup they give real wall time, smoothly, and — unlike a
  -- counter fed by `dt` — they keep counting while the window is occluded,
  -- which is exactly when somebody has alt-tabbed away to read docs.
  Clock.set_source(function() return love.timer.getTime() end)

  -- The key library first: `src/store.lua` wants its `secure` op for the
  -- `0700`/`0600` SPEC §1.1 asks for, and a store that opened before the
  -- library would create its file behind the umask.
  local lib, why = Wallet.load(love.filesystem.getSource())
  self.wallet_lib = lib
  self.wallet_error = why

  -- Opening the store is also what brings an older one across: if
  -- `~/.causewaybayhackerlove2d` holds a store and the new home does not,
  -- `Store.open` copies it, once, and leaves the old directory alone.
  Store.open({
    home = self.home,
    secure = lib and function(target, is_directory)
      return Wallet.secure(lib, target, is_directory)
    end or nil,
  })
  -- And the migration before that one: LÖVE's own save directory, which is
  -- where this client kept its session for exactly one release.
  --
  -- **Gated on the same question the directory copy is gated on**, and it was
  -- not, which is a bug this round introduced and caught by looking at the
  -- file: a store opened with `--home` or `CWBH_LOVE2D_HOME` was getting a
  -- session token and a display record injected into it out of LÖVE's
  -- sandbox. `--home $(mktemp -d)` is documented as the way to drive a run
  -- from nothing — `tests/drive/slice.lua` depends on it for the login
  -- screen — and it would have meant "a fresh store, plus somebody's old
  -- session", which is the same script passing for the wrong reason.
  --
  -- The question is asked of the store, not re-derived here: one place
  -- decides what the default home is.
  if Store.resolved_default() then
    Store.migrate(function(name)
      if love.filesystem.getInfo(name) then return love.filesystem.read(name) end
      return nil
    end, App.DEFAULT_SERVER)
  end

  self.server, self.server_from = self:resolve_server()
  self:log("info", ("server %s (%s); store %s")
    :format(self.server, self.server_from, tostring(Store.where())))

  Layout.storage = { save = Store.save_display, load = Store.load_display }
  Layout.init(os.getenv("CWBH_ORIENT"))

  -- The language, in the same precedence shape as everything else here:
  -- `CWBH_LANG` for a launch-time override, otherwise what was chosen last,
  -- otherwise English.
  local wanted = os.getenv("CWBH_LANG")
  if not (wanted and I18n.NAMES[wanted]) then wanted = Store.saved_lang() end
  if wanted then I18n.set(wanted) end

  -- The code face, before the first frame: a face chosen last time and
  -- applied on the second is a screen that visibly re-lays itself.
  local face = Store.saved_face()
  if face then Assets.setCodeFace(face) end

  -- A missing key library is *not* fatal: the login screen renders the
  -- reason and the build command, because "run `make -C love2d ffi`" is a
  -- thing a person can act on and a crash is not.
  if lib then
    self:log("info", "key library loaded, ABI " .. Wallet.ABI_VERSION)
  else
    self:log("warn", "key library missing:\n" .. tostring(why))
  end

  self.client = netclient.new({
    url = self.server,
    transport = socket_transport.factory(),
    now = function() return love.timer.getTime() end,
    rand = function(lo, hi) return love.math.random(lo, hi) end,
    log = function(level, message) self:log(level, message) end,
  })

  self.session = Session.new({
    client = self.client,
    lib = lib,
    log = function(level, message) self:log(level, message) end,
  })

  -- A connection that will not open, with no token for this address, is the
  -- login screen's business: the player has just typed a server that is not
  -- answering and needs to see the field they typed it into.
  --- The title card and the opening are exempt alongside `boot` and `login`:
  --- a card that waits for a keypress must not be yanked out from under the
  --- player because the server is not running, and the opening is a minute of
  --- reading that needs no server at all. Both land on the login screen by
  --- themselves, which is where the reason is shown.
  local function on_a_card()
    return self.scene_name == "boot" or self.scene_name == "title"
      or self.scene_name == "story" or self.scene_name == "login"
  end
  self.session:on("state", function(payload)
    if payload.state == "closed" and not self.session.token and not on_a_card() then
      self:go("login")
    end
  end)

  --- `need_login` fires the moment the socket opens with no stored token,
  --- which on loopback is a third of a second after launch. That is what
  --- takes the boot screen off — but it must take it off to the **title
  --- card**, not past it, or the card this client just grew would never be
  --- seen by the one player it exists for: somebody opening the game for the
  --- first time. On the card and in the opening it is ignored; both end at
  --- the login screen on their own.
  self.session:on("need_login", function(payload)
    if payload and payload.message then self:toast(payload.message) end
    if self.scene_name == "boot" then
      self:go("title")
    elseif self.scene_name ~= "login" and self.scene_name ~= "title"
      and self.scene_name ~= "story" then
      self:go("login")
    end
  end)

  self.session:on("auth", function(payload)
    -- §1.3: adopt the place before choosing a screen, so `lands` opens on the
    -- land this player was actually in — including one they were last in from
    -- the web client, since both talk to the same server.
    local at = payload.position
    if at then
      self.land = at.land or self.land
      self.category = at.category
      self.quest_id = at.quest_id
    end
    -- A resumed session still gets the title card: it is the game's front
    -- door, not a login prompt, and `make gui` resumes every launch — so a
    -- boot that skipped it would be a game nobody ever saw the name of. The
    -- card and the opening are not yanked either; they read `session.authed`
    -- on the way out and go to `lands` instead of `login`.
    if self.scene_name == "boot" then
      self:go("title")
    elseif self.scene_name == "login" then
      self:go("lands")
    end
    self:toast(("welcome, %s"):format(payload.user and payload.user.name or "hacker"))
  end)

  -- PROTOCOL §6 rule 5: the map is refetched, never trusted across a drop.
  self.session:on("reconnected", function()
    if self.scene and self.scene.refresh then
      self.scene:refresh()
    end
  end)

  self.session:on("award", function(payload)
    -- §4.20: purely presentational, and an unknown `kind` is ignored.
    if payload.kind == "badge" or payload.kind == "stamp"
      or payload.kind == "level" or payload.kind == "streak" then
      SFX.play("stamp")
      self:toast(tostring(payload.title or payload.id))
    end
  end)

  self:go("boot")
  self.client:connect()
end

--- Point the whole client at a different server.
---
--- Validates, persists, rebinds the session to that server's own token
--- (SPEC §1.1), and drops the connection so the next one goes to the new
--- address. Returns true, or nil and a sentence for the screen.
function App:set_server(url)
  url = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local ok, why = App.check_server(url)
  if not ok then return nil, why end

  Store.set_server(url)

  if self.server_override then
    -- Persisted, and honestly described. Applying it now would contradict
    -- the precedence this program just wrote down.
    return true, ("saved — CWBH_SERVER is overriding this run (%s)"):format(self.server_override)
  end
  if url == self.server then return true, "already connected to that" end

  self.server = url
  self.session:rebind(url)
  local moved, move_why = self.client:set_url(url)
  if not moved then return nil, move_why end
  self:toast("connecting to " .. url)
  return true
end

function App:go(name, params)
  local path = SCENES[name]
  if not path then
    self:log("error", "no scene named " .. tostring(name))
    return
  end
  if self.scene and self.scene.leave then self.scene:leave() end
  local scene = require(path).new(self)
  self.scene = scene
  self.scene_name = name
  -- LÖVE delivers `textinput` for a printable key *after* `keypressed` for
  -- the same physical press. A scene opened by a letter — S for search, P for
  -- the playground, Q for a category — would otherwise receive that letter as
  -- typed text on its first frame, and the search box opened reading
  -- "sborrow checker". One frame of deafness is the fix.
  self.swallow_textinput = true
  if scene.enter then scene:enter(params or {}) end
end

--- Walk back up the screen order. `boot` and `login` have nowhere to go.
function App:back()
  SFX.play("back")
  local up = {
    categories = "lands",
    map = "categories",
    quest = "map",
    result = "map",
    search = "map",
    stats = "map",
    ai = "map",
    -- Back to wherever it was opened from: the desk is reachable from the
    -- land select as well as from a map, and landing somebody on a map they
    -- never chose would be worse than either.
    playground = "map",
    lands = "lands",
  }
  local target = up[self.scene_name]
  if target and target ~= self.scene_name then
    self:go(target)
  end
end

function App:toast(text, seconds)
  self.toast_text = text
  self.toast_left = seconds or 3.2
end

function App:update(dt)
  Layout.flush()
  CRT.update(dt)
  self.client:update(dt)
  if self.toast_left > 0 then
    self.toast_left = math.max(0, self.toast_left - dt)
  end
  if self.scene and self.scene.update then self.scene:update(dt) end
  -- Cleared at the end of the frame, so exactly the keystroke that opened the
  -- scene is swallowed and nothing after it.
  self.swallow_textinput = false
end

function App:draw()
  if self.scene and self.scene.draw then
    self.scene:draw()
  else
    love.graphics.clear(Theme.void)
  end
  CRT.draw(self.scene_name == "quest" and 0.35 or 1)
  UI.toast(self.toast_text, math.min(1, self.toast_left / 0.5))
end

--- The modifier keys held right now.
---
--- `App.mods_override` exists for `src/drive.lua`: a scripted `love.keypressed`
--- cannot hold a physical modifier, so a drive step that wants ctrl-A sets
--- this for the length of the call. Nothing else writes it.
App.mods_override = nil

local function mods()
  if App.mods_override then return App.mods_override end
  return {
    ctrl = love.keyboard.isDown("lctrl", "rctrl"),
    shift = love.keyboard.isDown("lshift", "rshift"),
    alt = love.keyboard.isDown("lalt", "ralt"),
    gui = love.keyboard.isDown("lgui", "rgui"),
  }
end

App.mods = mods

function App:keypressed(key)
  if self.scene and self.scene.keypressed then
    if self.scene:keypressed(key, mods()) then return end
  end
  if key == "escape" then self:back() end
end

function App:textinput(text)
  if self.swallow_textinput then return end
  if self.scene and self.scene.textinput then self.scene:textinput(text) end
end

function App:mousepressed(x, y, button)
  local vx, vy = Layout.toVirtual(x, y)
  if not vx then return end
  -- The footer's display controls are global chrome and are tested first; a
  -- press that lands on one is consumed and never reaches the scene.
  if button == 1 and self:display_pressed(vx, vy) then return end
  if self.scene and self.scene.mousepressed then self.scene:mousepressed(vx, vy, button) end
end

--- A drag, and the end of one.
---
--- These exist for the code editor: a client with `mousepressed` and nothing
--- else can place a caret but cannot select a range with the mouse, which is
--- the one thing every other editor does. `mousereleased` is dispatched even
--- when the pointer has left the pane it started in, because that is exactly
--- the case a scene has to know about — a selection dragged past the edge
--- must end without the release landing on whatever is underneath.
function App:mousemoved(x, y)
  local vx, vy = Layout.toVirtual(x, y)
  if not vx then return end
  if self.scene and self.scene.mousemoved then self.scene:mousemoved(vx, vy) end
end

function App:mousereleased(x, y, button)
  local vx, vy = Layout.toVirtual(x, y)
  -- A release outside the letterbox still has to reach the scene, or a drag
  -- that ended off the edge of the canvas leaves a button held down forever.
  if self.scene and self.scene.mousereleased then
    self.scene:mousereleased(vx, vy, button)
  end
end

function App:wheelmoved(dx, dy)
  if self.scene and self.scene.wheelmoved then self.scene:wheelmoved(dx, dy) end
end

--- True when the current screen is taking text, so a bare letter key must
--- not be stolen for a global shortcut.
---
--- The quest screen is always typing (the editor has focus by default and a
--- letter belongs to the program); the login screen is typing whenever its
--- fields are live. Everything else is navigation, where `F` is free.
function App:typing()
  local scene = self.scene
  if not scene then return false end
  if self.scene_name == "quest" then return true end
  if self.scene_name == "playground" then return true end
  -- **The search screen's own footer says `TYPE to search`.** It was missing
  -- from this list before this round, so `F` had been toggling fullscreen
  -- instead of typing an `f` into the query box; adding `L` for the language
  -- would have taken a second letter for the same reason. A screen with a
  -- text field is a screen that is typing, whatever else it does.
  if self.scene_name == "search" then return true end
  if self.scene_name == "login" then return self.wallet_lib ~= nil end
  return false
end

-- --------------------------------------------------------- display controls

--- What the three footer buttons have to show.
---
--- One function, read by the draw and by the click, so the label a player is
--- looking at and the action a press performs can never come from two
--- different ideas of the state.
function App:display_state()
  return {
    -- Signed in: the row grows a fifth button, the way out.
    authed = (self.session and self.session.authed) and true or false,
    fullscreen = Layout.fullscreen,
    -- "auto" | "portrait" | "landscape" — the *state*, pin included.
    orientation = Layout.orientationLabel(),
    -- And the shape it actually resolved to, which is the half `auto` would
    -- otherwise not say.
    shape = Layout.mode,
    font = Layout.font,
    font_label = Layout.fontLabel(),
    lang = I18n.lang,
    lang_code = I18n.code(),
  }
end

--- A press on one of the display buttons. True when it was taken.
---
--- Tested **before** the scene sees the click, and it returns rather than
--- falling through: a press on the footer must not also land on whatever the
--- scene has underneath it.
---
--- Each button does exactly what its key does — the same `Layout` call and
--- the same toast — so the two paths cannot drift into meaning different
--- things. The keys are not replaced; this is the half of the feature a
--- player can see.
function App:display_pressed(x, y)
  local rects = self.display_rects
  if not rects then return false end
  local function inside(r)
    return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
  end
  if inside(rects.fullscreen) then
    SFX.play("select")
    self:toast(Layout.toggleFullscreen() and "fullscreen" or "window")
    return true
  end
  if inside(rects.orient) then
    SFX.play("select")
    self:toast("orientation: " .. Layout.cycleOrientation())
    return true
  end
  if inside(rects.font) then
    SFX.play("select")
    Layout.cycleFont()
    self:toast("type size " .. Layout.fontLabel())
    return true
  end
  if inside(rects.lang) then
    SFX.play("select")
    self:set_lang(I18n.cycle())
    return true
  end
  if inside(rects.logout) then
    self:logout()
    return true
  end
  return false
end

--- Sign out, from any screen.
---
--- The browser client's address chip does this (`frontend/src/ui/chrome.ts`:
--- the wallet *is* the account, so the thing showing who you are is the
--- thing that stops being you). Here the verb sits in the footer's control
--- row beside the other four, drawn only while signed in — this client had
--- a login with a server field, a phrase and a name, and no way back to it
--- short of deleting the store by hand.
---
--- Order matters. The socket is closed first, while the token is still
--- held, so the "closed with no token" route to the login screen does not
--- fire on top of the one below; then the token is forgotten here and on
--- disk (`Session:logout`, which fires `need_login` and that takes us to the
--- login screen); then a fresh, anonymous connection is opened for whoever
--- signs in next — the old one was authenticated with a token that is now
--- nobody's. The scene that was open gets its `leave`, so the playground
--- saves what was being typed.
function App:logout()
  if not (self.session and self.session.authed) then return false end
  SFX.play("back")
  self.logged_out_notice = I18n.t("signed out")
  self.client:close(1000, "logout")
  self.session:logout()
  if self.scene_name ~= "login" then self:go("login") end
  self.client.auto_reconnect = true
  self.client:connect()
  self.toast_left = 0
  return true
end

--- Change the interface language, and remember it.
---
--- The toast says the language's **own name** — `한국어`, not `KO` — because
--- the button had room for two letters and the moment somebody presses it is
--- exactly the moment the full name is worth the width.
function App:set_lang(code)
  I18n.set(code)
  Store.set_lang(I18n.lang)
  self:toast(I18n.name())
  return I18n.lang
end

--- The status strip, drawn by every scene so the connection is never a
--- mystery — and, on a row of its own under it, the four display controls.
---
--- They are drawn from here rather than from each scene for the same reason
--- the connection badge is: they work on every screen, so they belong in the
--- one piece of chrome every screen already draws. A scene added tomorrow
--- gets them by calling `app:footer`, which it has to do anyway, and cannot
--- forget them. `tests/test_screens.lua` asserts that every scene does.
function App:footer(hint)
  local left = hint or ""
  if self.session and self.session.authed then
    left = ("%s  %s   %s"):format(self.session:display_name(), self.session:short_address(), left)
  end
  local state = self:display_state()
  -- **First**, because this is also what decides whether the buttons can
  -- wear their labels at this canvas width, and the answer has to be settled
  -- before anything is drawn with it.
  local reserve = UI.displayReserve(state)
  -- Kept so a drive script can ask whether this screen's own hint fits in the
  -- room it was given, which is the question a translation actually raises.
  -- `last_reserve` is what the control row costs; `last_room` is what the
  -- hint was actually given, which since the split is very nearly the whole
  -- width.
  self.last_hint, self.last_reserve = left, reserve
  self.last_room = UI.footer(left, self.client and self.client.state or "idle")
  self.display_rects = UI.displayControls(state)
end

return App
