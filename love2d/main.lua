-- CAUSEWAYBAY HACKER — the LÖVE client.
--
-- A *client*. The server owns progress, judging, quests, mistakes and drills
-- (docs/decisions.md, first entry); this program draws what it is told and
-- sends what the player did.
--
--   love .                       play
--   love . --home ~/somewhere    put this client's store there (SPEC §1.1)
--   CWBH_TEST=1 love . --test    run the suite and quit
--   CWBH_DRIVE=script.lua love . replay a scripted session (screenshots)
--   CWBH_SERVER=ws://…/ws        point at another server
--   CWBH_ORIENT=portrait         start in portrait
--
-- The test/drive pair is `CausewaybayGolang/love2d`'s `GOSET_TEST` /
-- `GOSET_DRIVE`, renamed.

local App = require("src.app")
local Layout = require("src.layout")
local SFX = require("src.sfx")
local CRT = require("src.crt")

local app
local drive
local testing = false

local function wants_tests(args)
  if os.getenv("CWBH_TEST") == "1" then return true end
  for _, a in ipairs(args or {}) do
    if a == "--test" then return true end
  end
  return false
end

--- `--home <PATH>` or `--home=PATH`, SPEC §1.1's first step of precedence.
---
--- It is parsed here rather than read from the environment inside the store,
--- because a flag is the one control a person can use on a machine whose
--- shell profile they do not own. It wins over `CWBH_LOVE2D_HOME`; a flag
--- that loses to an environment variable somebody exported last month is a
--- flag that does nothing.
local function home_flag(args)
  for i, a in ipairs(args or {}) do
    local inline = a:match("^%-%-home=(.*)$")
    if inline then return inline end
    if a == "--home" then return (args or {})[i + 1] end
  end
  return nil
end

function love.load(args)
  if wants_tests(args) then
    testing = true
    local passed = require("tests.init").run()
    love.event.quit(passed and 0 or 1)
    return
  end

  love.graphics.setDefaultFilter("nearest", "nearest")
  love.graphics.setLineStyle("rough")
  love.graphics.setLineWidth(1)
  -- Held keys repeat: without this a backspace in the editor deletes one
  -- character per press and typing feels broken.
  love.keyboard.setKeyRepeat(true)

  app = App.new({ home = home_flag(args) })
  app:load()

  local script = os.getenv("CWBH_DRIVE")
  if script and script ~= "" then
    -- A Lua error under a drive script must *fail*, not hang. LÖVE's default
    -- handler replaces the update and draw callbacks with its blue screen and
    -- waits for a human, so an unattended run stops making progress and the
    -- script never times out — which reads as "still going" for as long as
    -- anybody is willing to wait. This one prints the traceback and exits
    -- non-zero, which is what a test harness needs.
    --
    -- **Installed before `Drive.load`, not after.** `loadfile` resolves
    -- `CWBH_DRIVE` against the *process's* working directory, so running the
    -- client from the repository root instead of from `love2d/` raises here —
    -- and the handler that exists to stop exactly this from hanging was
    -- installed on the line below the one that raised. The blue screen then
    -- waited for a human who was not there, and the run had to be found with
    -- `pgrep` and killed. The one error this handler is most likely to meet
    -- was the one error it was not yet installed for.
    function love.errorhandler(message)
      io.stderr:write("drive: the client crashed\n")
      io.stderr:write(tostring(message) .. "\n")
      io.stderr:write(debug.traceback("", 2) .. "\n")
      return function() return 1 end
    end
    love.errhand = love.errorhandler
    drive = require("src.drive").load(script)
  end
end

function love.update(dt)
  if testing then return end
  -- A long frame (a window drag, a breakpoint) must not make the game think
  -- seconds of animation happened.
  dt = math.min(dt, 0.05)
  app:update(dt)
  if drive then drive:update(dt, app) end
end

function love.draw()
  if testing then return end
  Layout.begin()
  app:draw()
  Layout.finish()
end

function love.keypressed(key)
  if testing or not app then return end
  -- The global bindings, before the scene sees the key.
  --
  -- `f11` and `f` both, matching `CausewaybayRaiden`'s README ("F / F11 |
  -- Toggle window / fullscreen"), so a player who has used either sibling
  -- already knows the key. `f` is swallowed here only when no screen is
  -- typing: the editor, the login fields and the confirm fields all need the
  -- letter, and a fullscreen toggle in the middle of a word would be far
  -- worse than one extra key to remember.
  if key == "f11" or (key == "f" and not app:typing()) then
    app:toast(Layout.toggleFullscreen() and "fullscreen" or "window")
    return
  end
  if key == "f1" then
    app:toast("orientation: " .. Layout.cycleOrientation())
    return
  end
  -- The type size. It belongs with F1 and F11 — the three controls that
  -- decide how this window is set up — and is the only one of them that had
  -- no key at all until the buttons arrived. F12 is free on every screen for
  -- the same reason F1 is: nothing here takes a function key as text.
  if key == "f12" then
    Layout.cycleFont()
    app:toast("code size " .. Layout.fontLabel())
    return
  end
  if key == "f4" then
    app:toast(SFX.toggle() and "sound on" or "sound off")
    return
  end
  if key == "f3" then
    app:toast(CRT.toggle() and "scanlines on" or "scanlines off")
    return
  end
  app:keypressed(key)
end

function love.textinput(text)
  if testing or not app then return end
  app:textinput(text)
end

function love.mousepressed(x, y, button)
  if testing or not app then return end
  app:mousepressed(x, y, button)
end

function love.mousemoved(x, y)
  if testing or not app then return end
  app:mousemoved(x, y)
end

function love.mousereleased(x, y, button)
  if testing or not app then return end
  app:mousereleased(x, y, button)
end

function love.wheelmoved(dx, dy)
  if testing or not app then return end
  app:wheelmoved(dx, dy)
end

function love.resize()
  Layout.updateViewport()
end

function love.quit()
  -- PROTOCOL §1.2: 1000 is "normal; the client asked".
  if app and app.client then
    app.client:close(1000, "player quit")
  end
end
