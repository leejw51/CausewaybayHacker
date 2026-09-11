-- The PROTOCOL.md client: envelopes, correlation, keepalive, reconnection.
--
-- It owns no socket and no `love`. A *transport* is injected — `socket.lua`
-- in the game, a fake in `tests/` — which is what lets every conformance
-- point in PROTOCOL §8 that does not need a server be checked with no server.
--
-- The transport contract, in full:
--
--   t:connect(host, port)  -> "connected" | "pending" | nil, message
--   t:poll()               -> "connected" | "pending" | nil, message
--   t:send(bytes)          -> bytes_written | nil, message     (partial is ok)
--   t:receive()            -> bytes | "" (nothing yet) | nil, message
--   t:close()
--
-- Nothing in the contract may block. `receive` returning `""` is the normal
-- case on a quiet frame.

local json = require("src.json")
local ws = require("src.net.ws")
local errors = require("src.net.errors")

local M = {}

M.PROTOCOL_VERSION = 1

-- PROTOCOL §6: 0.5, 1, 2, 4, 8, then every 8, each with ±20% jitter.
M.BACKOFF = { 0.5, 1, 2, 4, 8 }
M.BACKOFF_MAX = 8

-- PROTOCOL §1.1: answering the server's websocket pings with pongs is the
-- better half of the rule, and this client does. The application-level `ping`
-- is sent as well, at 20 s, because it is also §4.1's round-trip timer and
-- because a client that relies solely on a pong it cannot observe has no way
-- to know the link is dead. Costs one frame every 20 seconds.
M.APP_PING_S = 20

-- How long a request may sit unanswered before the client stops waiting for
-- it. Judging takes seconds (§4.9), so this is generous.
M.REQUEST_TIMEOUT_S = 180

local Client = {}
Client.__index = Client
M.Client = Client

--- Split `ws://host:port/path`. Returns a table or nil, message.
function M.parse_url(url)
  local scheme, rest = tostring(url):match("^(%a[%w+.-]*)://(.*)$")
  if not scheme then
    return nil, ("%q is not a ws:// URL"):format(tostring(url))
  end
  scheme = scheme:lower()
  if scheme ~= "ws" then
    -- wss would need TLS, which LuaSocket alone does not have. PROTOCOL §1
    -- is ws:// on loopback, so this is a clear refusal rather than a silent
    -- downgrade.
    return nil, ("scheme %q is not supported; this client speaks ws:// only"):format(scheme)
  end
  local hostport, path = rest:match("^([^/]+)(/.*)$")
  if not hostport then
    hostport, path = rest, "/"
  end
  local host, port = hostport:match("^(.*):(%d+)$")
  if not host then
    host, port = hostport, 80
  end
  return { scheme = scheme, host = host, port = tonumber(port), path = path }
end

--- `opts`:
---   url        ws://127.0.0.1:5390/ws
---   transport  a factory: function() -> transport
---   now        function() -> seconds, monotonic
---   rand       function(lo, hi) -> integer, for mask keys
---   log        function(level, message)
---   auto_reconnect  default true
---
--- `update(dt)` takes `dt` only so it drops straight into the game's frame
--- callback; every deadline in here is measured against `now()`, because a
--- summed `dt` drifts and a laptop that slept did not advance it at all.
function M.new(opts)
  opts = opts or {}
  local parsed, err = M.parse_url(opts.url or "ws://127.0.0.1:5390/ws")
  if not parsed then error(err, 2) end

  local self = setmetatable({
    url = opts.url or "ws://127.0.0.1:5390/ws",
    host = parsed.host,
    port = parsed.port,
    path = parsed.path,
    make_transport = opts.transport,
    now = opts.now or os.time,
    rand = opts.rand or math.random,
    log = opts.log or function() end,
    auto_reconnect = opts.auto_reconnect ~= false,
    app_ping_s = opts.app_ping_s or M.APP_PING_S,

    state = "idle",
    transport = nil,
    conn = nil,
    outbox = "",
    inbuf = "",
    key = nil,

    counter = 0,
    pending = {},          -- id -> { type, cb, sent_at }
    handlers = {},         -- type -> { fn, ... }  server-initiated events
    state_handlers = {},
    unknown_types = {},    -- type -> count, for §8 point 3

    submit_inflight = false,

    attempt = 0,
    retry_at = nil,
    last_app_ping = nil,
    last_rx = nil,
    pongs_sent = 0,
    pings_sent = 0,
    -- Set when the peer sends §4.21 `server.bye`, so a close right after it
    -- is expected rather than a fault (§8 point 11).
    saw_bye = nil,
  }, Client)
  return self
end

-- ------------------------------------------------------------------ plumbing

function Client:on(type_name, fn)
  local list = self.handlers[type_name]
  if not list then
    list = {}
    self.handlers[type_name] = list
  end
  list[#list + 1] = fn
  return fn
end

function Client:on_state(fn)
  self.state_handlers[#self.state_handlers + 1] = fn
end

function Client:set_state(state, detail)
  if self.state == state then return end
  self.state = state
  for _, fn in ipairs(self.state_handlers) do
    fn(state, detail)
  end
end

function Client:emit(type_name, payload, envelope)
  local list = self.handlers[type_name]
  if not list then return false end
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, payload, envelope)
    if not ok then
      self.log("error", ("handler for %s failed: %s"):format(type_name, tostring(err)))
    end
  end
  return true
end

-- ----------------------------------------------------------------- connecting

function Client:connect()
  if self.state == "open" or self.state == "connecting" or self.state == "handshaking" then
    return
  end
  if not self.make_transport then
    self:fail("no transport was given to the client")
    return
  end
  self.retry_at = nil
  self.inbuf, self.outbox = "", ""
  self.saw_bye = nil
  self.conn = ws.Conn.new({ rand = self.rand })
  self.transport = self.make_transport()
  self:set_state("connecting")

  local status, err = self.transport:connect(self.host, self.port)
  if status == nil then
    self:fail(err or "connect failed")
    return
  end
  if status == "connected" then
    self:start_handshake()
  end
end

function Client:start_handshake()
  self.key = ws.new_key(self.rand)
  local request = ws.handshake_request(self.host, self.port, self.path, self.key)
  self:set_state("handshaking")
  self:push(request)
end

--- Queue bytes. Partial writes are normal on a non-blocking socket, so the
--- remainder stays in `outbox` and `flush` keeps at it.
function Client:push(bytes)
  self.outbox = self.outbox .. bytes
  self:flush()
end

function Client:flush()
  if self.outbox == "" or not self.transport then return end
  local written, err = self.transport:send(self.outbox)
  if written == nil then
    self:fail("send failed: " .. tostring(err))
    return
  end
  if written > 0 then
    self.outbox = self.outbox:sub(written + 1)
  end
end

--- Drop the connection and schedule a retry.
function Client:fail(message)
  self.log("warn", "connection: " .. tostring(message))
  self:teardown(message)
end

function Client:teardown(message)
  if self.transport then
    pcall(function() self.transport:close() end)
    self.transport = nil
  end
  self.conn = nil
  self.outbox, self.inbuf = "", ""
  self.submit_inflight = false

  -- Every in-flight request is answered locally rather than left hanging:
  -- a scene waiting on a callback that never comes is a scene that spins
  -- forever with no way to say what happened.
  local pending = self.pending
  self.pending = {}
  for id, entry in pairs(pending) do
    if entry.cb then
      pcall(entry.cb, false, {
        code = "internal",
        message = "the connection dropped before the reply arrived",
        detail = { transport = true, id = id },
      }, nil)
    end
  end

  self:set_state("closed", message)
  if self.auto_reconnect then
    self:schedule_retry()
  end
end

function Client:schedule_retry()
  self.attempt = self.attempt + 1
  local base = M.BACKOFF[self.attempt] or M.BACKOFF_MAX
  -- ±20% jitter, so a server restart does not bring every client back at the
  -- same instant.
  local jitter = 0.8 + (self.rand(0, 400) / 1000)
  self.retry_at = self.now() + base * jitter
  self.log("info", ("reconnecting in %.1fs (attempt %d)"):format(base * jitter, self.attempt))
end

function Client:close(code, reason)
  self.auto_reconnect = false
  if self.state == "open" and self.conn then
    local frame = self.conn:encode(ws.CLOSE, ws.close_payload(code or 1000, reason or ""))
    if frame then self:push(frame) end
    self:set_state("closing")
  end
  self:teardown(reason or "closed by the client")
  self:set_state("closed", reason)
end

-- ------------------------------------------------------------------ the pump

function Client:update(dt)
  local now = self.now()

  if self.retry_at and now >= self.retry_at then
    self.retry_at = nil
    self:connect()
    -- Fall through rather than returning: a fake transport (and a loopback
    -- socket) is connected the instant `connect` is called, and making the
    -- caller spend a second frame to notice would put a frame of latency
    -- into every reconnection for no reason.
  end
  if not self.transport then return end

  if self.state == "connecting" then
    local status, err = self.transport:poll()
    if status == nil then
      self:fail(err or "connect failed")
      return
    end
    if status ~= "connected" then return end
    self:start_handshake()
  end

  self:flush()
  self:drain()
  if self.state ~= "open" then return end

  -- §8 point 12: the application-level ping, on its own clock.
  self.last_app_ping = self.last_app_ping or now
  if self.app_ping_s and now - self.last_app_ping >= self.app_ping_s then
    self.last_app_ping = now
    self.pings_sent = self.pings_sent + 1
    self:request("ping", {}, nil)
  end

  self:expire_requests(now)
end

--- Read whatever the socket has and turn it into frames.
function Client:drain()
  while true do
    local bytes, err = self.transport:receive()
    if bytes == nil then
      -- A clean EOF from the peer. Expected after §4.21 `server.bye`, and
      -- perfectly legal without one (§8 point 11).
      local why = err or "closed"
      if self.saw_bye then
        why = ("closed after server.bye (%s)"):format(tostring(self.saw_bye))
      end
      self:fail(why)
      return
    end
    if bytes == "" then break end
    self.last_rx = self.now()
    if self.state == "handshaking" then
      self.inbuf = self.inbuf .. bytes
      if not self:try_handshake() then return end
    else
      self.conn:feed(bytes)
    end
  end

  if self.state == "open" then
    self:read_messages()
  end
end

function Client:try_handshake()
  local status, headers, rest = ws.parse_handshake_response(self.inbuf)
  if not status then
    if headers == "incomplete" then return true end
    self:fail(headers)
    return false
  end
  local ok, err = ws.check_handshake(status, headers, self.key)
  if not ok then
    self:fail(err)
    return false
  end
  self.inbuf = ""
  self.attempt = 0
  self.last_app_ping = self.now()
  self:set_state("open")
  if rest and rest ~= "" then
    self.conn:feed(rest)
  end
  return true
end

function Client:read_messages()
  while self.conn do
    local msg, err, close_code = self.conn:next()
    if not msg then
      if err then
        -- A framing violation: say so on the wire, then drop.
        local frame = self.conn:encode(ws.CLOSE, ws.close_payload(close_code or 1002, ""))
        if frame then self:push(frame) end
        self:fail("protocol error: " .. err)
      end
      return
    end

    if msg.kind == "ping" then
      -- PROTOCOL §1.1's better half: answer the real ping frames.
      local frame = self.conn:encode(ws.PONG, msg.payload)
      if frame then
        self:push(frame)
        self.pongs_sent = self.pongs_sent + 1
      end
    elseif msg.kind == "pong" then
      -- Nothing to do; `last_rx` already moved.
    elseif msg.kind == "close" then
      self.log("info", ("server closed: %d %s"):format(msg.code, msg.reason))
      local echo = self.conn:encode(ws.CLOSE, ws.close_payload(msg.code, ""))
      if echo then self:push(echo) end
      self:flush()
      -- 4001 is "session revoked — re-authenticate from scratch" (§1.2); the
      -- app layer reads it off the state detail.
      self:teardown(("close:%d"):format(msg.code))
      return
    elseif msg.kind == "binary" then
      -- §1: "Binary frames are not used; a client that sends one is closed
      -- with 1003." Receiving one means the peer is not the server.
      local frame = self.conn:encode(ws.CLOSE, ws.close_payload(1003, "binary frames are not used"))
      if frame then self:push(frame) end
      self:fail("the server sent a binary frame")
      return
    elseif msg.kind == "text" then
      self:handle_text(msg.payload)
    end
  end
end

-- ------------------------------------------------------------------ envelopes

--- True when `env` is PROTOCOL §2's envelope and nothing else.
function M.is_envelope(env)
  if type(env) ~= "table" then return false, "not an object" end
  if env.v ~= M.PROTOCOL_VERSION then return false, "bad or missing `v`" end
  if type(env.type) ~= "string" then return false, "bad or missing `type`" end
  if type(env.payload) ~= "table" then return false, "`payload` is not an object" end
  if env.id ~= nil and env.id ~= json.null and type(env.id) ~= "string" then
    return false, "`id` is neither a string nor null"
  end
  local n = 0
  for _ in pairs(env) do n = n + 1 end
  if n ~= 4 then return false, "the envelope has " .. n .. " keys, not 4" end
  return true
end

--- Turn `json.null` into absence, in place, inside a payload.
---
--- PROTOCOL §2.4: "an optional field is **omitted**, not sent as `null`,
--- unless `null` is a meaningful value (`id`, `time_limit_s`, `code`)." Of
--- those three, only `id` carries information a client acts on — it is what
--- separates a reply from a server-initiated event (§2.2) — and it is read
--- off the envelope below *before* this runs.
---
--- The other two mean the same thing to this client as absence:
--- `time_limit_s: null` is "untimed" and `code: null` is "no compiler code",
--- and both render as nothing either way. Leaving the sentinel in would put a
--- table where every scene expects a string or nil, and the failure is a
--- crash inside `draw` on the one attempt whose mistake had no error code —
--- which is exactly how it was found.
local function denull(value, depth)
  if type(value) ~= "table" then return value end
  if (depth or 0) > 32 then return value end
  for k, v in pairs(value) do
    if v == json.null then
      value[k] = nil
    elseif type(v) == "table" then
      denull(v, (depth or 0) + 1)
    end
  end
  return value
end

M.denull = denull

function Client:handle_text(text)
  local env, err = json.try_decode(text)
  if not env then
    self.log("error", "a frame was not JSON: " .. tostring(err))
    return
  end
  local ok, why = M.is_envelope(env)
  if not ok then
    self.log("error", ("a frame is not a §2 envelope (%s): %s"):format(why, text:sub(1, 160)))
    return
  end

  -- Read `id` first; it is the one null whose meaning a client acts on.
  local id = env.id
  if id == json.null then id = nil end
  denull(env.payload)

  if id ~= nil then
    local entry = self.pending[id]
    if entry then
      self.pending[id] = nil
      if entry.type == "quest.submit" then
        self.submit_inflight = false
      end
      local succeeded = env.type == entry.type .. ".ok"
      local failed = env.type == entry.type .. ".err"
      if succeeded or failed then
        if entry.cb then
          local cb_ok, cb_err = pcall(entry.cb, succeeded, env.payload, env)
          if not cb_ok then
            self.log("error", ("reply handler for %s failed: %s"):format(env.type, tostring(cb_err)))
          end
        end
        if failed then
          self:emit("*.err", env.payload, env)
        end
        return
      end
      -- A reply with the right id and the wrong type is a server bug. The
      -- request is still answered, so a scene does not hang on it.
      self.log("error", ("reply to %s arrived as %s"):format(entry.type, env.type))
      if entry.cb then
        pcall(entry.cb, false, {
          code = "internal",
          message = ("expected %s.ok or %s.err, got %s"):format(entry.type, entry.type, env.type),
          detail = {},
        }, env)
      end
      return
    end
    -- An id nobody is waiting for: a late reply to a request that timed out,
    -- or a server bug. Ignored, loudly.
    self.log("warn", ("reply %s carries id %q, which is not in flight"):format(env.type, tostring(id)))
    return
  end

  -- id == null: a server-initiated event (§2.2).
  if env.type == "server.bye" then
    self.saw_bye = env.payload.reason or "unspecified"
  end
  if not self:emit(env.type, env.payload, env) then
    -- §2.3 / §8 point 3: "A client must ignore an unknown `type` rather than
    -- erroring or closing." Counted so a test can prove it was ignored and
    -- not merely lost.
    self.unknown_types[env.type] = (self.unknown_types[env.type] or 0) + 1
    self.log("info", ("ignoring unknown event type %q"):format(env.type))
  end
end

--- Send a request. Returns the correlation id, or nil, message.
---
--- `cb(ok, payload, envelope)` — `ok` is true for `.ok`, false for `.err` and
--- for a local failure, in which case `payload` is a §3.3-shaped error.
function Client:request(type_name, payload, cb)
  if self.state ~= "open" then
    if cb then
      cb(false, {
        code = "internal",
        message = "not connected",
        detail = { state = self.state },
      }, nil)
    end
    return nil, "not connected"
  end

  -- §3.2 / §8 point 10: one in-flight `quest.submit` per connection. The
  -- client refuses locally rather than letting the server answer `busy`,
  -- because the submit button has to be disabled either way and a round trip
  -- to learn that is a round trip the player watches.
  if type_name == "quest.submit" then
    if self.submit_inflight then
      if cb then
        cb(false, {
          code = "busy",
          message = "a submission is already in flight on this connection",
          detail = { local_check = true },
        }, nil)
      end
      return nil, "busy"
    end
    self.submit_inflight = true
  end

  self.counter = self.counter + 1
  local id = "c-" .. self.counter
  local envelope = {
    v = M.PROTOCOL_VERSION,
    id = id,
    type = type_name,
    payload = payload or {},
  }
  local text = json.encode(envelope)
  local frame = self.conn:encode(ws.TEXT, text)
  if not frame then
    self.submit_inflight = false
    return nil, "could not encode the frame"
  end
  self.pending[id] = { type = type_name, cb = cb, sent_at = self.now() }
  self:push(frame)
  return id
end

function Client:expire_requests(now)
  for id, entry in pairs(self.pending) do
    if now - entry.sent_at > M.REQUEST_TIMEOUT_S then
      self.pending[id] = nil
      if entry.type == "quest.submit" then
        self.submit_inflight = false
      end
      if entry.cb then
        pcall(entry.cb, false, {
          code = "internal",
          message = ("no reply to %s after %ds"):format(entry.type, M.REQUEST_TIMEOUT_S),
          detail = { id = id },
        }, nil)
      end
    end
  end
end

--- How many requests are waiting for a reply.
function Client:inflight()
  local n = 0
  for _ in pairs(self.pending) do n = n + 1 end
  return n
end

M.classify_error = errors.classify

return M
