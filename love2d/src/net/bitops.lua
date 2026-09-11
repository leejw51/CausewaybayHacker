-- 32-bit integer operations, on LuaJIT's `bit` where it exists.
--
-- LÖVE ships LuaJIT, so `bit` is always there in the game; the arithmetic
-- fallback is for a plain-Lua host running the headless suite. Having both
-- behind one name keeps `sha1.lua` and `ws.lua` free of `pcall(require)`.
--
-- No `love.` in this file, or anywhere under src/net/ — the whole codec has
-- to be testable with no window and no server.

local ok, bit = pcall(require, "bit")
if ok and bit then
  return {
    band = bit.band,
    bor = bit.bor,
    bxor = bit.bxor,
    bnot = bit.bnot,
    lshift = bit.lshift,
    rshift = bit.rshift,
    rol = bit.rol,
    tobit = bit.tobit,
    -- LuaJIT's bit ops produce signed 32-bit values; a byte or a length is
    -- wanted unsigned.
    tou32 = function(x)
      x = bit.tobit(x)
      if x < 0 then return x + 4294967296 end
      return x
    end,
  }
end

-- ------------------------------------------------------- arithmetic fallback

local M = {}
local floor = math.floor
local TWO32 = 4294967296

local function norm(x)
  x = x % TWO32
  if x < 0 then x = x + TWO32 end
  return x
end

local function apply(a, b, f)
  a, b = norm(a), norm(b)
  local out, bitv = 0, 1
  for _ = 1, 32 do
    local ab, bb = a % 2, b % 2
    if f(ab, bb) == 1 then out = out + bitv end
    a, b, bitv = floor(a / 2), floor(b / 2), bitv * 2
  end
  return out
end

function M.band(a, b) return apply(a, b, function(x, y) return (x == 1 and y == 1) and 1 or 0 end) end
function M.bor(a, b) return apply(a, b, function(x, y) return (x == 1 or y == 1) and 1 or 0 end) end
function M.bxor(a, b) return apply(a, b, function(x, y) return (x ~= y) and 1 or 0 end) end
function M.bnot(a) return norm(TWO32 - 1 - norm(a)) end
function M.lshift(a, n) return norm(norm(a) * 2 ^ n) end
function M.rshift(a, n) return floor(norm(a) / 2 ^ n) end
function M.rol(a, n) return M.bor(M.lshift(a, n), M.rshift(a, 32 - n)) end
function M.tobit(a) return norm(a) end
function M.tou32(a) return norm(a) end

return M
