-- The whole suite.
--
-- Two ways in, one list of tests:
--
--   make test           LÖVE runs it (CWBH_TEST=1), window opened and closed
--   make test-headless  `luajit tests/run.lua`, no window, no LÖVE at all
--
-- Everything under `src/net/`, `src/json.lua`, `src/editor.lua` and the FFI
-- runs in both. The layout and the scene tests need `love.graphics` and are
-- skipped, by name, in the headless run — a skipped test says so out loud
-- rather than quietly not existing.

local T = require("tests.framework")

local M = {}

--- Suites that need nothing but Lua.
local PURE = {
  "tests.test_json",
  "tests.test_ws",
  "tests.test_runlog",
  "tests.test_client",
  "tests.test_session",
  "tests.test_editor",
  "tests.test_wallet",
}

--- Suites that need a LÖVE graphics context.
local GRAPHICAL = {
  "tests.test_layout",
}

function M.run()
  local has_love = type(_G.love) == "table" and _G.love.graphics ~= nil

  print("")
  print("CAUSEWAYBAY HACKER // love2d " .. (has_love and "(under LÖVE)" or "(headless, luajit)"))

  for _, name in ipairs(PURE) do
    require(name)()
  end

  for _, name in ipairs(GRAPHICAL) do
    if has_love then
      require(name)()
    else
      T.section(name .. " — skipped")
      T.skip(name, "needs love.graphics; run `make test`")
    end
  end

  return T.report()
end

return M
