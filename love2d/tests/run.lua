-- Headless entry point: `luajit tests/run.lua` from love2d/.
--
-- No window, no LÖVE, no server. This is the run that has to stay green on a
-- machine where LÖVE cannot be installed — which, on this laptop, is the
-- situation: Homebrew's `love` cask was disabled on 2026-09-01 for failing
-- the macOS Gatekeeper check.

local here = arg and arg[0] and arg[0]:match("^(.*)/tests/run%.lua$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local ok, result = pcall(function()
  return require("tests.init").run()
end)

if not ok then
  io.stderr:write("the suite itself failed to run:\n" .. tostring(result) .. "\n")
  os.exit(2)
end

os.exit(result and 0 or 1)
