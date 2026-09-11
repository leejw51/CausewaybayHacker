-- RFC 6455 in pure Lua: the handshake strings and the frame codec.
--
-- This file owns no socket and knows no `love`. It turns bytes into frames
-- and frames into bytes, which is what makes the whole websocket testable
-- with no window and no server — see `love2d/tests/test_ws.lua`.
--
-- Three things here are the ones that actually go wrong:
--
--   1. **Masking is mandatory for a client.** RFC 6455 §5.1: "A client MUST
--      mask all frames that it sends to the server." A server that receives
--      an unmasked frame must fail the connection, so an unmasked client
--      looks like a working client on a loopback test and is dropped by the
--      real one. `encode` has no unmasked path.
--   2. **Three length encodings.** 0..125 inline, 126 → a 16-bit length,
--      127 → a 64-bit one. The boundaries (125/126 and 65535/65536) are
--      where off-by-ones live, so the tests walk them.
--   3. **Continuation frames.** A message may arrive as text + cont + cont
--      with control frames interleaved. `Conn` reassembles; the interleaved
--      ping is answered without disturbing the partial message.

local base64 = require("src.net.base64")
local sha1 = require("src.net.sha1")
local b = require("src.net.bitops")

local M = {}

M.GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

M.CONTINUATION = 0x0
M.TEXT = 0x1
M.BINARY = 0x2
M.CLOSE = 0x8
M.PING = 0x9
M.PONG = 0xA

M.OPCODE_NAME = {
  [0x0] = "continuation",
  [0x1] = "text",
  [0x2] = "binary",
  [0x8] = "close",
  [0x9] = "ping",
  [0xA] = "pong",
}

-- PROTOCOL §1: 4 MiB inbound, the server closes with 1009 above it. A client
-- that buffers past that is a client somebody can make eat memory.
M.MAX_PAYLOAD = 4 * 1024 * 1024

-- ------------------------------------------------------------------ handshake

--- 16 random bytes, base64'd, as `Sec-WebSocket-Key`.
---
--- `rand` is injected so a test can be deterministic. In the game it is
--- `love.math.random`, which LÖVE seeds from the OS.
function M.new_key(rand)
  rand = rand or math.random
  local bytes = {}
  for i = 1, 16 do
    bytes[i] = string.char(rand(0, 255))
  end
  return base64.encode(table.concat(bytes))
end

--- The `Sec-WebSocket-Accept` a conformant server must answer with.
function M.accept_for(key)
  return base64.encode(sha1.binary(key .. M.GUID))
end

--- The opening HTTP request, verbatim bytes.
function M.handshake_request(host, port, path, key, extra)
  local host_header = host
  -- A default port is left out of the Host header; some servers compare it.
  if not ((port == 80) or (port == 443)) then
    host_header = host .. ":" .. tostring(port)
  end
  local lines = {
    ("GET %s HTTP/1.1"):format(path),
    ("Host: %s"):format(host_header),
    "Upgrade: websocket",
    "Connection: Upgrade",
    ("Sec-WebSocket-Key: %s"):format(key),
    "Sec-WebSocket-Version: 13",
    -- PROTOCOL §1: no subprotocol, and permessage-deflate is not negotiated,
    -- so it is not offered. Offering an extension a client cannot decode is
    -- how a handshake succeeds and the first frame is gibberish.
  }
  for _, line in ipairs(extra or {}) do
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n"
end

--- Split an HTTP response head out of `buffer`.
---
--- Returns `status, headers, rest` once the blank line has arrived,
--- `nil, "incomplete"` while it has not, and `nil, message` on garbage.
function M.parse_handshake_response(buffer)
  local head_end = buffer:find("\r\n\r\n", 1, true)
  if not head_end then
    if #buffer > 16384 then
      return nil, "the server sent 16 KiB without finishing its response head"
    end
    return nil, "incomplete"
  end
  local head = buffer:sub(1, head_end - 1)
  local rest = buffer:sub(head_end + 4)

  local lines = {}
  for line in (head .. "\r\n"):gmatch("(.-)\r\n") do
    lines[#lines + 1] = line
  end
  local status_line = lines[1] or ""
  local code = tonumber(status_line:match("^HTTP/1%.1 (%d%d%d)"))
  if not code then
    return nil, "not an HTTP/1.1 response: " .. status_line:sub(1, 80)
  end

  local headers = {}
  for i = 2, #lines do
    local name, value = lines[i]:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = value
    end
  end
  return { code = code, line = status_line }, headers, rest
end

--- Check a parsed response against RFC 6455 §4.1. Returns `true` or
--- `nil, message`.
function M.check_handshake(status, headers, key)
  if status.code ~= 101 then
    return nil, ("the server answered %d, not 101 Switching Protocols"):format(status.code)
  end
  if (headers["upgrade"] or ""):lower() ~= "websocket" then
    return nil, "the server did not answer `Upgrade: websocket`"
  end
  if not (headers["connection"] or ""):lower():find("upgrade", 1, true) then
    return nil, "the server did not answer `Connection: Upgrade`"
  end
  local want = M.accept_for(key)
  if headers["sec-websocket-accept"] ~= want then
    return nil,
      ("Sec-WebSocket-Accept is %s, expected %s — this is not a websocket server")
        :format(tostring(headers["sec-websocket-accept"]), want)
  end
  -- PROTOCOL §1 does not negotiate compression, so a server that claims an
  -- extension is one this client cannot read. Better to say so than to
  -- deliver corrupt frames upward.
  if headers["sec-websocket-extensions"] and headers["sec-websocket-extensions"] ~= "" then
    return nil, "the server negotiated an extension this client did not offer: "
      .. headers["sec-websocket-extensions"]
  end
  return true
end

-- ---------------------------------------------------------------- frame codec

local function u16be(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end

local function u64be(n)
  local out = {}
  for i = 8, 1, -1 do
    out[i] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  return table.concat(out)
end

--- XOR `payload` with the 4-byte `key`, the RFC 6455 §5.3 transform.
---
--- It is its own inverse, which is why the decode path calls the same
--- function.
function M.mask(payload, key)
  local k = { key:byte(1, 4) }
  local out = {}
  -- Chunked so the table of parts stays small on a 256 KiB `run.log` frame.
  local n = #payload
  local i = 1
  while i <= n do
    local stop = math.min(i + 4095, n)
    local part = {}
    for j = i, stop do
      part[j - i + 1] = string.char(b.bxor(payload:byte(j), k[(j - 1) % 4 + 1]))
    end
    out[#out + 1] = table.concat(part)
    i = stop + 1
  end
  return table.concat(out)
end

--- Four random mask bytes. Injected rng, as for `new_key`.
function M.new_mask(rand)
  rand = rand or math.random
  return string.char(rand(0, 255), rand(0, 255), rand(0, 255), rand(0, 255))
end

--- Encode one client frame. **Always masked** — there is no other option.
---
--- `fin` defaults to true; pass false to start a fragmented message.
function M.encode(opcode, payload, mask_key, fin)
  payload = payload or ""
  if fin == nil then fin = true end
  if opcode >= 0x8 and #payload > 125 then
    return nil, "a control frame payload is 125 bytes at most"
  end
  if opcode >= 0x8 and not fin then
    return nil, "a control frame cannot be fragmented"
  end
  mask_key = mask_key or M.new_mask()
  if #mask_key ~= 4 then
    return nil, "a mask key is exactly 4 bytes"
  end

  local b0 = opcode + (fin and 0x80 or 0x00)
  local n = #payload
  local header
  if n <= 125 then
    header = string.char(b0, 0x80 + n)
  elseif n <= 0xFFFF then
    header = string.char(b0, 0x80 + 126) .. u16be(n)
  else
    header = string.char(b0, 0x80 + 127) .. u64be(n)
  end
  return header .. mask_key .. M.mask(payload, mask_key)
end

--- Decode one frame out of `buffer` starting at `offset` (1-based).
---
--- Returns `frame, next_offset`, or `nil, "incomplete"` when more bytes are
--- needed, or `nil, message, close_code` on a protocol violation.
function M.decode(buffer, offset)
  offset = offset or 1
  local available = #buffer - offset + 1
  if available < 2 then return nil, "incomplete" end

  local b0, b1 = buffer:byte(offset, offset + 1)
  local fin = b.band(b0, 0x80) ~= 0
  local rsv = b.band(b0, 0x70)
  local opcode = b.band(b0, 0x0F)
  local masked = b.band(b1, 0x80) ~= 0
  local len = b.band(b1, 0x7F)
  local cursor = offset + 2

  if rsv ~= 0 then
    -- No extension was negotiated, so a reserved bit is either a bug or a
    -- compressed frame this client cannot read. 1002 is "protocol error".
    return nil, "a reserved bit is set but no extension was negotiated", 1002
  end
  if not M.OPCODE_NAME[opcode] then
    return nil, ("unknown opcode 0x%x"):format(opcode), 1002
  end
  if opcode >= 0x8 then
    if len > 125 then
      return nil, "a control frame payload is 125 bytes at most", 1002
    end
    if not fin then
      return nil, "a control frame cannot be fragmented", 1002
    end
  end

  if len == 126 then
    if #buffer - cursor + 1 < 2 then return nil, "incomplete" end
    local h, l = buffer:byte(cursor, cursor + 1)
    len = h * 256 + l
    cursor = cursor + 2
  elseif len == 127 then
    if #buffer - cursor + 1 < 8 then return nil, "incomplete" end
    len = 0
    for i = 0, 7 do
      len = len * 256 + buffer:byte(cursor + i)
      -- A length Lua cannot represent exactly is a length this client is
      -- never going to hold in a string anyway.
      if len > M.MAX_PAYLOAD then
        return nil, ("frame of %d bytes is over the 4 MiB limit"):format(len), 1009
      end
    end
    cursor = cursor + 8
  end
  if len > M.MAX_PAYLOAD then
    return nil, ("frame of %d bytes is over the 4 MiB limit"):format(len), 1009
  end

  local mask_key
  if masked then
    if #buffer - cursor + 1 < 4 then return nil, "incomplete" end
    mask_key = buffer:sub(cursor, cursor + 3)
    cursor = cursor + 4
  end

  if #buffer - cursor + 1 < len then return nil, "incomplete" end
  local payload = buffer:sub(cursor, cursor + len - 1)
  if masked then
    payload = M.mask(payload, mask_key)
  end

  return {
    fin = fin,
    opcode = opcode,
    masked = masked,
    payload = payload,
  }, cursor + len
end

--- Build a close payload: a 2-byte big-endian code then a UTF-8 reason.
function M.close_payload(code, reason)
  reason = reason or ""
  if #reason > 123 then reason = reason:sub(1, 123) end
  return u16be(code or 1000) .. reason
end

--- Read a close payload back. An empty one is a close with no code, which
--- RFC 6455 allows and which means 1005 "no status received".
function M.parse_close(payload)
  if #payload == 0 then return 1005, "" end
  if #payload == 1 then return 1002, "" end
  local h, l = payload:byte(1, 2)
  return h * 256 + l, payload:sub(3)
end

-- ------------------------------------------------- message-level reassembly

local Conn = {}
Conn.__index = Conn
M.Conn = Conn

--- A frame reassembler. Feed it bytes; take whole messages out.
---
--- `opts.rand` is the rng used for mask keys.
function Conn.new(opts)
  opts = opts or {}
  return setmetatable({
    buffer = "",
    offset = 1,
    rand = opts.rand,
    -- The message being assembled across continuation frames.
    fragment_opcode = nil,
    fragment_parts = nil,
    fragment_bytes = 0,
    closed = false,
  }, Conn)
end

function Conn:feed(bytes)
  if bytes == nil or bytes == "" then return end
  -- Compact rather than growing forever: the offset walks forward through a
  -- buffer that a long session would otherwise keep every byte of.
  if self.offset > 1 then
    self.buffer = self.buffer:sub(self.offset)
    self.offset = 1
  end
  self.buffer = self.buffer .. bytes
end

--- The next complete *message*, or nil.
---
--- Returns one of:
---   `{ kind = "text",  payload = "..." }`
---   `{ kind = "binary", payload = "..." }`   (PROTOCOL §1 never sends one)
---   `{ kind = "ping" | "pong", payload = "..." }`
---   `{ kind = "close", code = 1000, reason = "..." }`
---   `nil` — nothing complete yet
---   `nil, message, close_code` — a protocol violation; the caller closes
function Conn:next()
  while true do
    local frame, next_offset, close_code = M.decode(self.buffer, self.offset)
    if not frame then
      if next_offset == "incomplete" then return nil end
      return nil, next_offset, close_code
    end
    self.offset = next_offset

    local op = frame.opcode
    if op == M.PING or op == M.PONG then
      return { kind = M.OPCODE_NAME[op], payload = frame.payload }
    elseif op == M.CLOSE then
      local code, reason = M.parse_close(frame.payload)
      self.closed = true
      return { kind = "close", code = code, reason = reason }
    elseif op == M.CONTINUATION then
      if not self.fragment_opcode then
        return nil, "a continuation frame arrived with no message to continue", 1002
      end
      self.fragment_parts[#self.fragment_parts + 1] = frame.payload
      self.fragment_bytes = self.fragment_bytes + #frame.payload
      if self.fragment_bytes > M.MAX_PAYLOAD then
        return nil, "a fragmented message went over the 4 MiB limit", 1009
      end
      if frame.fin then
        local kind = M.OPCODE_NAME[self.fragment_opcode]
        local payload = table.concat(self.fragment_parts)
        self.fragment_opcode, self.fragment_parts, self.fragment_bytes = nil, nil, 0
        return { kind = kind, payload = payload }
      end
    else -- TEXT or BINARY
      if self.fragment_opcode then
        return nil, "a new message started before the previous one finished", 1002
      end
      if frame.fin then
        return { kind = M.OPCODE_NAME[op], payload = frame.payload }
      end
      self.fragment_opcode = op
      self.fragment_parts = { frame.payload }
      self.fragment_bytes = #frame.payload
    end
  end
end

--- Encode a masked client frame with this connection's rng.
function Conn:encode(opcode, payload, fin)
  return M.encode(opcode, payload, M.new_mask(self.rand), fin)
end

return M
