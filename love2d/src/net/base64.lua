-- Base64, standard alphabet with padding.
--
-- Needed twice in the handshake: the 16 random bytes of `Sec-WebSocket-Key`
-- go out encoded, and the server's `Sec-WebSocket-Accept` comes back encoded.
-- Both are RFC 4648 §4 with `=` padding; there is no URL-safe variant here
-- (the session token PROTOCOL §4.3 hands back is base64url, but that is an
-- opaque string this client only ever stores and echoes, never decodes).
--
-- No `love.` in this file.

local M = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local DECODE = {}
for i = 1, #ALPHABET do
  DECODE[ALPHABET:sub(i, i)] = i - 1
end

function M.encode(data)
  local out = {}
  local n = #data
  local i = 1
  while i + 2 <= n do
    local a, b, c = data:byte(i, i + 2)
    local v = a * 65536 + b * 256 + c
    out[#out + 1] = ALPHABET:sub(math.floor(v / 262144) + 1, math.floor(v / 262144) + 1)
      .. ALPHABET:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
      .. ALPHABET:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
      .. ALPHABET:sub(v % 64 + 1, v % 64 + 1)
    i = i + 3
  end
  local left = n - i + 1
  if left == 1 then
    local a = data:byte(i)
    local v = a * 16
    out[#out + 1] = ALPHABET:sub(math.floor(v / 64) + 1, math.floor(v / 64) + 1)
      .. ALPHABET:sub(v % 64 + 1, v % 64 + 1)
      .. "=="
  elseif left == 2 then
    local a, b = data:byte(i, i + 1)
    local v = (a * 256 + b) * 4
    out[#out + 1] = ALPHABET:sub(math.floor(v / 4096) + 1, math.floor(v / 4096) + 1)
      .. ALPHABET:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
      .. ALPHABET:sub(v % 64 + 1, v % 64 + 1)
      .. "="
  end
  return table.concat(out)
end

--- Decode, ignoring whitespace. Returns `nil, message` on a bad character
--- rather than raising: the input is a header field from the network.
function M.decode(text)
  text = text:gsub("[ \t\r\n]", "")
  local body = text:gsub("=+$", "")
  local out, acc, bits = {}, 0, 0
  for i = 1, #body do
    local c = body:sub(i, i)
    local v = DECODE[c]
    if not v then
      return nil, ("base64: %q is not in the alphabet"):format(c)
    end
    acc = acc * 64 + v
    bits = bits + 6
    if bits >= 8 then
      bits = bits - 8
      local byte = math.floor(acc / 2 ^ bits)
      acc = acc - byte * 2 ^ bits
      out[#out + 1] = string.char(byte)
    end
  end
  return table.concat(out)
end

return M
