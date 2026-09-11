-- SHA-1, in pure Lua.
--
-- Here for exactly one reason: RFC 6455 §4.1 says the client must check that
-- the server's `Sec-WebSocket-Accept` is
-- `base64(sha1(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))`. Skipping
-- that check is how a client ends up talking to something that is not a
-- websocket server and reporting a framing bug.
--
-- Not a general-purpose hash and not for anything secret: the key material in
-- this client never touches Lua at all (SPEC §3.1) — it goes through the Rust
-- FFI. This is a 20-byte handshake checksum and nothing else.

local b = require("src.net.bitops")

local M = {}

local band, bor, bxor, bnot, rol = b.band, b.bor, b.bxor, b.bnot, b.rol
local tou32 = b.tou32

local function u32be(n)
  n = tou32(n)
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256
  )
end

--- The raw 20-byte digest of `message`.
function M.binary(message)
  local len = #message

  -- Padding: 0x80, zeroes, then the bit length as a 64-bit big-endian count.
  local padded = message .. "\128" .. string.rep("\0", (55 - len) % 64)
  local bits = len * 8
  padded = padded .. u32be(math.floor(bits / 4294967296)) .. u32be(bits % 4294967296)

  local h0, h1, h2, h3, h4 =
    0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0

  local w = {}
  for chunk = 1, #padded, 64 do
    for i = 0, 15 do
      local o = chunk + i * 4
      local a, c, d, e = padded:byte(o, o + 3)
      w[i] = a * 16777216 + c * 65536 + d * 256 + e
    end
    for i = 16, 79 do
      w[i] = rol(bxor(bxor(w[i - 3], w[i - 8]), bxor(w[i - 14], w[i - 16])), 1)
    end

    local a, c, d, e, f = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local k, mix
      if i < 20 then
        mix, k = bor(band(c, d), band(bnot(c), e)), 0x5A827999
      elseif i < 40 then
        mix, k = bxor(bxor(c, d), e), 0x6ED9EBA1
      elseif i < 60 then
        mix, k = bor(bor(band(c, d), band(c, e)), band(d, e)), 0x8F1BBCDC
      else
        mix, k = bxor(bxor(c, d), e), 0xCA62C1D6
      end
      -- The additions are done in plain arithmetic and folded back to 32 bits
      -- once, because the fallback bitops are the slow path and this keeps
      -- them off the hot line.
      local temp = (tou32(rol(a, 5)) + tou32(mix) + tou32(f) + k + tou32(w[i])) % 4294967296
      f, e, d, c, a = e, d, rol(c, 30), a, temp
    end

    h0 = (h0 + a) % 4294967296
    h1 = (h1 + c) % 4294967296
    h2 = (h2 + d) % 4294967296
    h3 = (h3 + e) % 4294967296
    h4 = (h4 + f) % 4294967296
  end

  return u32be(h0) .. u32be(h1) .. u32be(h2) .. u32be(h3) .. u32be(h4)
end

--- Lowercase hex digest, for tests and for a log line.
function M.hex(message)
  return (M.binary(message):gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

return M
