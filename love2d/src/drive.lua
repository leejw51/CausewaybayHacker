-- Scripted input, for smoke runs and screenshots.
--
--   CWBH_DRIVE=tests/drive/slice.lua love .
--
-- Ported from `CausewaybayGolang/love2d/src/drive.lua`, with `wait`, `until_`
-- and `shot` reworked: this client talks to a server, so a script cannot
-- assume a scene has arrived by a fixed time. A step may carry
-- `until_ = function(app) return ... end` and the script blocks on it, with
-- `timeout` seconds before it gives up and says which step stalled.
--
-- The script returns a list of steps, in order:
--
--   { key = "return" }                 love.keypressed (+ textinput for a
--                                      single printable character)
--   { text = "fn main() {" }           love.textinput, one character at a time
--   { click = { x, y } }               a click in virtual coordinates
--   { orient = "portrait" }            pin the orientation
--   { resize = { w, h } }              resize the window
--   { shot = "map.png" }               screenshot into the save directory
--   { wait = 0.5 }                     hold for seconds
--   { until_ = f, timeout = 10 }       hold until f(app) is true
--   { note = "…" }                     print a line, so a log reads as a story
--   { quit = true }
--
-- Any step may also carry `when = function(app) -> boolean`; a step whose
-- `when` is false is skipped. A script that signs in has to survive a run
-- where the stored token already did (PROTOCOL §4.4), and "type the mnemonic
-- only if we are actually on the login screen" is that, in one line.

local Layout = require("src.layout")

local Drive = {}
Drive.__index = Drive

function Drive.load(path)
  local chunk, err = loadfile(path)
  if not chunk then
    error("CWBH_DRIVE: " .. tostring(err))
  end
  local steps = chunk()
  assert(type(steps) == "table", "CWBH_DRIVE script must return a list of steps")
  print(("drive: %d steps, shots -> %s"):format(#steps, love.filesystem.getSaveDirectory()))
  return setmetatable({ steps = steps, i = 1, held = 0, waited = 0, failed = false }, Drive)
end

--- Go through the real callbacks, so main.lua's F1/F11 routing applies.
---
--- A printable key also raises `textinput`, as a real keyboard does — unless
--- a command modifier is held, where the OS sends the shortcut and no text.
--- Without that guard a scripted ctrl-A both selects everything and types an
--- "a" over it.
local function press(key, mods)
  love.keypressed(key)
  if mods and (mods.ctrl or mods.gui or mods.alt) then return end
  if #key == 1 and key:match("[%w%p]") then
    love.textinput(key)
  elseif key == "space" then
    love.textinput(" ")
  end
end

function Drive:fire(step, app)
  if step.note then
    print("drive: " .. step.note .. "   [scene=" .. tostring(app.scene_name) .. "]")
  end
  if step.key then
    -- A scripted key cannot hold a physical modifier, so `mods` is handed to
    -- the app for the length of the call.
    if step.mods then require("src.app").mods_override = step.mods end
    press(step.key, step.mods)
    require("src.app").mods_override = nil
  elseif step.text then
    for _, ch in ipairs(Drive.chars(step.text)) do
      if ch == "\n" then love.keypressed("return") else love.textinput(ch) end
    end
  elseif step.click then
    local c = step.click
    if type(c) == "function" then c = c(app) end
    love.mousepressed(c[1] * Layout.scale + Layout.ox, c[2] * Layout.scale + Layout.oy, 1)
  elseif step.orient then
    Layout.setOrientation(step.orient)
    Layout.flush()
  elseif step.resize then
    love.window.setMode(step.resize[1], step.resize[2], { resizable = true, highdpi = true })
    Layout.updateViewport()
  elseif step.shot then
    love.graphics.captureScreenshot(step.shot)
    print(("drive: shot %s   scene=%s  %s  %dx%d"):format(
      step.shot, tostring(app.scene_name), Layout.mode, Layout.vw, Layout.vh))
  elseif step.quit then
    love.event.quit(step.code or 0)
  end
end

--- Split a string into UTF-8 characters, so a drive script can type a name
--- with a non-ASCII character in it.
function Drive.chars(text)
  local out = {}
  local i = 1
  while i <= #text do
    local b = text:byte(i)
    local n = 1
    if b >= 0xF0 then n = 4 elseif b >= 0xE0 then n = 3 elseif b >= 0xC0 then n = 2 end
    out[#out + 1] = text:sub(i, i + n - 1)
    i = i + n
  end
  return out
end

--- Driven by the wall clock, not by `dt`.
---
--- `love.update` caps `dt` at 0.05 so a stalled frame does not teleport the
--- animation — which is right for the game and wrong for a deadline. macOS
--- throttles an occluded window to a couple of frames a second, and a
--- timeout summed from a capped `dt` then runs twenty times slower than the
--- seconds it claims: a 90-second wait for `quest.submit` silently becomes
--- half an hour. Every deadline here is `love.timer.getTime()`.
function Drive:update(_, app)
  if self.failed then return end
  local step = self.steps[self.i]
  if not step then return end
  local now = love.timer.getTime()
  self.since = self.since or now

  if step.when then
    local ok, wanted = pcall(step.when, app)
    if not ok or not wanted then
      if step.note then print("drive: skipped — " .. step.note) end
      self.i = self.i + 1
      self.since = now
      self.waited = 0
      return
    end
  end

  if step.wait then
    if now - self.since < step.wait then return end
    self.since = now
    self.i = self.i + 1
    return
  end

  if step.until_ then
    self.waited = now - self.since
    local ok, ready = pcall(step.until_, app)
    if ok and ready then
      print(("drive: condition met after %.1fs   [%s]"):format(
        self.waited, step.note or "step " .. self.i))
      self.waited = 0
      self.i = self.i + 1
      return
    end
    if self.waited > (step.timeout or 15) then
      self.failed = true
      print(("drive: TIMEOUT on step %d (%s) after %.1fs   scene=%s")
        :format(self.i, step.note or "?", self.waited, tostring(app.scene_name)))
      love.event.quit(1)
    end
    return
  end

  self.i = self.i + 1
  local ok, err = pcall(self.fire, self, step, app)
  if not ok then
    self.failed = true
    print(("drive: step %d failed: %s"):format(self.i - 1, tostring(err)))
    love.event.quit(1)
  end
end

return Drive
