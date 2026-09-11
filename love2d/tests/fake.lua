-- A fake server that lives inside the process: it speaks the real RFC 6455
-- handshake and the real frame codec, through the same transport interface
-- `src/net/socket.lua` implements.
--
-- It is deliberately *not* a second implementation of the game. It hands back
-- whatever frames a test tells it to, which is what makes it useful for the
-- PROTOCOL §8 points about correlation, ordering and tolerance — the points
-- that are about the client's behaviour and not about the server's answers.
--
-- The handshake it performs is the genuine one, including checking that the
-- client masked its frames: an unmasked client frame is a protocol violation
-- (RFC 6455 §5.1) and a fake that quietly accepted one would hide the single
-- most likely way this client could be wrong on a real server.

local ws = require("src.net.ws")
local json = require("src.json")

local M = {}

local Fake = {}
Fake.__index = Fake

--- `opts.on_request(fake, envelope)` is called for each client envelope.
--- `opts.reject_handshake` answers 400 instead of 101.
--- `opts.bad_accept` answers 101 with a wrong Sec-WebSocket-Accept.
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    opts = opts,
    -- Bytes the client has written and the fake has not yet parsed.
    from_client = "",
    -- Bytes the fake wants the client to read.
    to_client = "",
    handshook = false,
    closed = false,
    eof = false,
    connect_pending = opts.connect_pending or 0,
    conn = ws.Conn.new(),
    -- Everything the client sent, as decoded envelopes.
    envelopes = {},
    -- Raw client frames, for the masking assertions.
    frames = {},
    pongs = {},
    client_closed_with = nil,
    unmasked_seen = false,
  }, Fake)
  return self
end

-- ------------------------------------------------------- transport interface

function Fake:connect(host, port)
  self.host, self.port = host, port
  if self.opts.connect_fails then
    -- What a `connect(2)` to a port nobody is listening on gives back.
    return nil, "connection refused"
  end
  if self.connect_pending > 0 then
    return "pending"
  end
  return "connected"
end

function Fake:poll()
  if self.connect_pending > 0 then
    self.connect_pending = self.connect_pending - 1
    if self.connect_pending > 0 then return "pending" end
  end
  if self.opts.connect_fails then
    return nil, "connection refused"
  end
  return "connected"
end

function Fake:send(bytes)
  self.from_client = self.from_client .. bytes
  self:pump()
  return #bytes
end

function Fake:receive()
  if self.to_client == "" then
    if self.eof then return nil, "closed" end
    return ""
  end
  local out = self.to_client
  self.to_client = ""
  return out
end

function Fake:close()
  self.closed = true
end

-- ------------------------------------------------------------- the fake side

function Fake:pump()
  if not self.handshook then
    local status, headers, rest = ws.parse_handshake_response(self.from_client)
    -- `parse_handshake_response` reads a response head; the client sent a
    -- *request* head, which has the same "lines then blank line" shape. Parse
    -- it directly instead.
    local head_end = self.from_client:find("\r\n\r\n", 1, true)
    if not head_end then return end
    local head = self.from_client:sub(1, head_end - 1)
    self.from_client = self.from_client:sub(head_end + 4)
    self.request_head = head
    local key = head:match("Sec%-WebSocket%-Key: ([^\r\n]+)")
    self.client_key = key
    if self.opts.reject_handshake then
      self.to_client = self.to_client
        .. "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
      self.eof = true
      return
    end
    local accept = self.opts.bad_accept and "AAAAAAAAAAAAAAAAAAAAAAAAAAA="
      or ws.accept_for(key or "")
    self.to_client = self.to_client
      .. "HTTP/1.1 101 Switching Protocols\r\n"
      .. "Upgrade: websocket\r\nConnection: Upgrade\r\n"
      .. "Sec-WebSocket-Accept: " .. accept .. "\r\n\r\n"
      .. (self.opts.piggyback or "")
    self.handshook = true
    if status and headers and rest then end -- silence the unused locals
  end

  -- Whole client frames.
  local offset = 1
  while true do
    local frame, next_offset = ws.decode(self.from_client, offset)
    if not frame then break end
    offset = next_offset
    self.frames[#self.frames + 1] = frame
    if not frame.masked then
      -- The real server closes the connection here. The fake records it so a
      -- test can assert it never happens.
      self.unmasked_seen = true
    end
    if frame.opcode == ws.PONG then
      self.pongs[#self.pongs + 1] = frame.payload
    elseif frame.opcode == ws.CLOSE then
      self.client_closed_with = select(1, ws.parse_close(frame.payload))
    elseif frame.opcode == ws.TEXT then
      local env = json.try_decode(frame.payload)
      self.envelopes[#self.envelopes + 1] = env or { raw = frame.payload }
      if self.opts.on_request and env then
        self.opts.on_request(self, env)
      end
    end
  end
  if offset > 1 then
    self.from_client = self.from_client:sub(offset)
  end
end

--- Queue a server frame. Server frames are never masked (RFC 6455 §5.1).
function Fake:raw(opcode, payload, fin)
  if fin == nil then fin = true end
  local b0 = opcode + (fin and 0x80 or 0)
  local n = #payload
  local header
  if n <= 125 then
    header = string.char(b0, n)
  elseif n <= 0xFFFF then
    header = string.char(b0, 126, math.floor(n / 256), n % 256)
  else
    local parts = {}
    local v = n
    for i = 8, 1, -1 do parts[i] = string.char(v % 256); v = math.floor(v / 256) end
    header = string.char(b0, 127) .. table.concat(parts)
  end
  self.to_client = self.to_client .. header .. payload
end

--- Send one §2 envelope.
function Fake:send_envelope(env)
  self:raw(ws.TEXT, json.encode(env))
end

--- Reply to a request: `type .. ".ok"` with the same id.
function Fake:reply(id, type_name, payload)
  self:send_envelope({ v = 1, id = id, type = type_name, payload = payload or {} })
end

--- A §3.3 error reply.
function Fake:reply_err(id, type_name, code, message, detail)
  self:send_envelope({
    v = 1,
    id = id,
    type = type_name .. ".err",
    payload = { code = code, message = message or code, detail = detail or {} },
  })
end

--- A server-initiated event: id is null (§2.2).
function Fake:event(type_name, payload)
  self:send_envelope({ v = 1, id = json.null, type = type_name, payload = payload or {} })
end

function Fake:ping(payload)
  self:raw(ws.PING, payload or "")
end

function Fake:close_frame(code, reason)
  self:raw(ws.CLOSE, ws.close_payload(code or 1000, reason or ""))
end

--- Drop the TCP connection with no close frame at all — §8 point 11's "and a
--- close without one".
function Fake:drop()
  self.eof = true
end

--- Everything the client sent of one type.
function Fake:sent(type_name)
  local out = {}
  for _, env in ipairs(self.envelopes) do
    if env.type == type_name then out[#out + 1] = env end
  end
  return out
end

function Fake:last()
  return self.envelopes[#self.envelopes]
end

M.Fake = Fake

--- A clock a test drives by hand, so nothing waits on real seconds.
function M.clock(start)
  local t = start or 1000
  return {
    now = function() return t end,
    advance = function(dt) t = t + dt end,
    set = function(v) t = v end,
  }
end

--- A deterministic `love.math.random(lo, hi)`.
function M.rand(seed)
  local state = seed or 1
  return function(lo, hi)
    state = (state * 1103515245 + 12345) % 2147483648
    return lo + (math.floor(state / 65536) % (hi - lo + 1))
  end
end

return M
