-- LÖVE 11.5 configuration.
--
-- Shape follows `CausewaybayGolang/love2d/conf.lua`. Two differences:
--
--   * `CWBH_TEST=1` shrinks the window to a stamp and switches audio off, so
--     the suite can run on a machine with no sound device and no patience.
--   * the window starts portrait when `CWBH_ORIENT=portrait`, because the
--     drive scripts screenshot both orientations and the first frame should
--     already be the right shape.

function love.conf(t)
  local testing = os.getenv("CWBH_TEST") == "1"
  local portrait = os.getenv("CWBH_ORIENT") == "portrait"
  local driving = (os.getenv("CWBH_DRIVE") or "") ~= ""

  t.identity = "causewaybay-hacker"
  t.version = "11.5"
  t.console = false

  t.window.title = "CAUSEWAYBAY HACKER"
  if testing then
    t.window.width, t.window.height = 320, 180
    t.window.minwidth, t.window.minheight = 160, 90
  elseif portrait then
    t.window.width, t.window.height = 720, 1000
    t.window.minwidth, t.window.minheight = 400, 560
  else
    t.window.width, t.window.height = 1280, 720
    t.window.minwidth, t.window.minheight = 640, 400
  end
  t.window.resizable = true
  t.window.fullscreen = false
  t.window.fullscreentype = "desktop"
  -- Vsync off while a drive script is running. macOS stalls the display link
  -- for a window nobody can see, and a vsynced loop then runs at nearly zero
  -- frames — which stops `love.update`, which stops the script, and the run
  -- hangs rather than failing. Unthrottled it finishes whether the window is
  -- on screen or behind everything.
  t.window.vsync = (testing or driving) and 0 or 1
  t.window.msaa = 0
  t.window.highdpi = true

  t.modules.joystick = false
  t.modules.physics = false
  t.modules.video = false
  t.modules.audio = not testing
  t.modules.sound = not testing
end
