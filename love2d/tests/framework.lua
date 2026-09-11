-- A test runner small enough that nothing in it can be the reason a test
-- passes. Modelled on `CausewaybayGolang/love2d/tests/framework.lua`.
--
-- Runs under LÖVE (`make test`) and under a bare `luajit` (`make test-headless`)
-- without changing a line, because nothing here touches `love`.

local F = {}

local results = { passed = 0, failed = 0, failures = {}, cases = {} }
local current = nil

local function record(ok, message)
  if ok then
    results.passed = results.passed + 1
  else
    results.failed = results.failed + 1
    local where = debug.traceback("", 3):match("\n%s*(.-)\n") or "?"
    results.failures[#results.failures + 1] = {
      case = current or "?",
      message = message,
      where = where,
    }
  end
end

function F.ok(value, message)
  record(value and true or false, message or "expected a truthy value")
end

function F.nope(value, message)
  record(not value, message or ("expected a falsy value, got " .. tostring(value)))
end

local function show(v)
  if type(v) == "string" then
    if #v > 200 then return string.format("%q…(%d bytes)", v:sub(1, 200), #v) end
    return string.format("%q", v)
  end
  return tostring(v)
end

F.show = show

function F.eq(got, want, message)
  local ok = got == want
  record(ok, message or ("expected " .. show(want) .. ", got " .. show(got)))
end

function F.ne(got, want, message)
  record(got ~= want, message or ("expected anything but " .. show(want)))
end

function F.near(got, want, tol, message)
  tol = tol or 1e-9
  record(
    type(got) == "number" and math.abs(got - want) <= tol,
    message or ("expected " .. tostring(want) .. " ±" .. tostring(tol) .. ", got " .. tostring(got))
  )
end

--- Deep equality, for decoded payloads.
function F.same(got, want, message, path)
  path = path or "value"
  if type(got) ~= type(want) then
    record(false, message or (path .. ": type " .. type(got) .. " ~= " .. type(want)))
    return
  end
  if type(want) ~= "table" then
    F.eq(got, want, message or (path .. ": " .. show(got) .. " ~= " .. show(want)))
    return
  end
  for k, v in pairs(want) do
    F.same(got[k], v, message, path .. "." .. tostring(k))
  end
  for k in pairs(got) do
    if want[k] == nil then
      record(false, message or (path .. "." .. tostring(k) .. " is unexpected"))
    end
  end
end

--- Assert that `fn` raises, and optionally that the message matches `pattern`.
function F.raises(fn, pattern, message)
  local ok, err = pcall(fn)
  if ok then
    record(false, message or "expected an error, none was raised")
    return
  end
  if pattern then
    record(
      tostring(err):find(pattern) ~= nil,
      message or ("error " .. show(tostring(err)) .. " does not match " .. show(pattern))
    )
  else
    record(true, nil)
  end
end

function F.case(name, fn)
  current = name
  results.cases[#results.cases + 1] = name
  local before = results.failed
  local ok, err = pcall(fn)
  if not ok then
    results.failed = results.failed + 1
    results.failures[#results.failures + 1] = {
      case = name,
      message = "the case itself raised: " .. tostring(err),
      where = "",
    }
  end
  local bad = results.failed - before
  print(("  %s %s"):format(bad == 0 and "ok  " or "FAIL", name))
  current = nil
end

function F.section(name)
  print("")
  print("-- " .. name)
end

function F.skip(name, why)
  results.cases[#results.cases + 1] = name
  print(("  skip %s  (%s)"):format(name, why))
end

--- Assert that a source file contains no *code* reference to `love`.
---
--- The structural rule the whole headless suite rests on: nothing under
--- `src/net/`, `src/json.lua`, `src/editor.lua`, `src/wallet.lua`,
--- `src/store.lua`, `src/anim.lua` or `src/clock.lua` may touch LÖVE, so all
--- of it runs under a bare `luajit`.
---
--- Comments are stripped first — these files talk about the rule in prose,
--- and a grep that cannot tell a sentence from a call would fail on the
--- documentation of the very thing it is checking.
---
--- **String literals are stripped too, and that stopped being optional.**
--- This used to say they never contain "love." and it was true right up
--- until `src/store.lua` grew a record tagged `from = "love.filesystem"` —
--- the name of the directory the first migration moved out of, which is
--- written into every existing player's log and therefore cannot be renamed
--- to please a grep. A quoted word is data, not a call.
function F.no_love(path)
  local fh = io.open(path, "r")
  if not fh then
    F.skip(path, "not readable from this working directory")
    return
  end
  local body = fh:read("*a")
  fh:close()
  body = body:gsub("%-%-%[%[.-%]%]", " ")
  local code = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do
    code[#code + 1] = line:gsub("%-%-.*$", "")
  end
  local stripped = table.concat(code, "\n")
  stripped = stripped:gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''")
  local hit = stripped:match("[^%w_]love%s*%.%s*[%w_]+")
  record(hit == nil, path .. " must not reference love, but does: " .. tostring(hit))
end

function F.results()
  return results
end

function F.report()
  print("")
  if results.failed > 0 then
    print(("FAILURES (%d):"):format(results.failed))
    for _, f in ipairs(results.failures) do
      print(("  [%s] %s"):format(f.case, f.message))
      if f.where ~= "" then print("      " .. f.where) end
    end
  end
  print(("%d cases, %d assertions passed, %d failed"):format(
    #results.cases, results.passed, results.failed))
  return results.failed == 0
end

return F
