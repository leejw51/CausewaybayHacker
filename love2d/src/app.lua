-- The shell: one websocket, one session, one scene at a time.
--
-- Screens, per SPEC §10:
--
--   boot → login → lands → categories → map → quest → result
--
-- plus `search`, `stats` and `ai` reachable from the map. Milestone 1 is
-- login → RUST → BASIC → a map → a quest → submit → CLEARED, and the three
-- extra screens are honest stubs (see `src/scenes/stub.lua`): they say what
-- they will be and go back, rather than pretending.
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
local Wallet = require("src.wallet")
local Session = require("src.session")
local netclient = require("src.net.client")
local socket_transport = require("src.net.socket")

local App = {}
App.__index = App

local SCENES = {
  boot = "src.scenes.boot",
  login = "src.scenes.login",
  lands = "src.scenes.lands",
  categories = "src.scenes.categories",
  map = "src.scenes.map",
  quest = "src.scenes.quest",
  result = "src.scenes.result",
  search = "src.scenes.search",
  stats = "src.scenes.stats",
  ai = "src.scenes.ai",
}

App.DEFAULT_SERVER = "ws://127.0.0.1:5390/ws"

function App.new()
  local self = setmetatable({
    scene = nil,
    scene_name = nil,
    toast_text = nil,
    toast_left = 0,
    log_lines = {},
    server = os.getenv("CWBH_SERVER") or App.DEFAULT_SERVER,
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

function App:load()
  Assets.load()
  SFX.load()

  Layout.storage = { save = Store.save_display, load = Store.load_display }
  Layout.init(os.getenv("CWBH_ORIENT"))

  -- The key library. A failure here is *not* fatal: the login screen renders
  -- the reason and the build command, because "run `make -C love2d ffi`" is
  -- a thing a person can act on and a crash is not.
  local lib, why = Wallet.load(love.filesystem.getSource())
  self.wallet_lib = lib
  self.wallet_error = why
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

  self.session:on("need_login", function(payload)
    if payload and payload.message then self:toast(payload.message) end
    if self.scene_name ~= "login" then self:go("login") end
  end)

  self.session:on("auth", function(payload)
    if self.scene_name == "login" or self.scene_name == "boot" then
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
  if self.scene and self.scene.textinput then self.scene:textinput(text) end
end

function App:mousepressed(x, y, button)
  local vx, vy = Layout.toVirtual(x, y)
  if not vx then return end
  if self.scene and self.scene.mousepressed then self.scene:mousepressed(vx, vy, button) end
end

function App:wheelmoved(dx, dy)
  if self.scene and self.scene.wheelmoved then self.scene:wheelmoved(dx, dy) end
end

--- The status strip, drawn by every scene so the connection is never a
--- mystery.
function App:footer(hint)
  local left = hint or ""
  if self.session and self.session.authed then
    left = ("%s  %s   %s"):format(self.session:display_name(), self.session:short_address(), left)
  end
  UI.footer(left, self.client and self.client.state or "idle")
end

return App
