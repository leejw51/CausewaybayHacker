-- The LuaSocket transport: a non-blocking TCP socket behind the four-method
-- contract `client.lua` describes.
--
-- LÖVE bundles LuaSocket, so `require("socket")` is all the dependency this
-- client has. Everything is `settimeout(0)`: `love.update` runs sixty times a
-- second and a single blocking read is a visible stall, so this file never
-- waits for anything. It drains what is there and returns.
--
-- No `love.` here either — a plain LuaJIT with LuaSocket can drive it, which
-- is how the client is tested against a real server outside LÖVE.

local M = {}

local Transport = {}
Transport.__index = Transport

-- 64 KiB a go. A `run.log` burst is many small frames rather than one big
-- one, so this is about syscall count, not about frame size.
local READ_CHUNK = 65536

--- A factory, so `client.lua` can make a fresh socket per connection attempt.
function M.factory(opts)
  opts = opts or {}
  return function()
    return M.new(opts)
  end
end

function M.new(opts)
  opts = opts or {}
  local ok, socket = pcall(require, "socket")
  if not ok or not socket then
    error(
      "LuaSocket is missing. LÖVE bundles it; a plain Lua host needs"
        .. " `luarocks install luasocket`.",
      2
    )
  end
  return setmetatable({
    socket = socket,
    sock = nil,
    host = nil,
    port = nil,
    connected = false,
    eof = false,
    keepalive = opts.keepalive ~= false,
  }, Transport)
end

function Transport:connect(host, port)
  local sock, err = self.socket.tcp()
  if not sock then
    return nil, "could not make a socket: " .. tostring(err)
  end
  sock:settimeout(0)
  if self.keepalive and sock.setoption then
    -- Best effort; a socket option this platform lacks is not a reason to
    -- fail a connection.
    pcall(function() sock:setoption("keepalive", true) end)
    pcall(function() sock:setoption("tcp-nodelay", true) end)
  end
  self.sock, self.host, self.port = sock, host, port

  local ok, cerr = sock:connect(host, port)
  if ok then
    self.connected = true
    return "connected"
  end
  -- A non-blocking connect reports "timeout" (LuaSocket) or the platform's
  -- own "Operation already in progress" while the SYN is in flight.
  if cerr == "timeout" or cerr == "Operation already in progress" then
    return "pending"
  end
  if cerr == "already connected" then
    self.connected = true
    return "connected"
  end
  return nil, ("could not connect to %s:%s — %s"):format(host, tostring(port), tostring(cerr))
end

function Transport:poll()
  if self.connected then return "connected" end
  if not self.sock then return nil, "no socket" end
  local _, writable = self.socket.select(nil, { self.sock }, 0)
  if not writable or #writable == 0 then
    return "pending"
  end
  -- The second connect on a writable non-blocking socket is what reports the
  -- outcome: success, or the error the SYN got back.
  local ok, err = self.sock:connect(self.host, self.port)
  if ok or err == "already connected" then
    self.connected = true
    return "connected"
  end
  if err == "timeout" or err == "Operation already in progress" then
    return "pending"
  end
  return nil, ("could not connect to %s:%s — %s"):format(self.host, tostring(self.port), tostring(err))
end

--- Write what the kernel will take. A short write is normal and the caller
--- keeps the remainder.
function Transport:send(bytes)
  if not self.sock then return nil, "no socket" end
  local sent, err, last = self.sock:send(bytes)
  if sent then return sent end
  if err == "timeout" then
    -- `last` is the index of the final byte that did go out.
    return last or 0
  end
  return nil, err
end

--- Everything available right now. `""` means nothing yet; `nil` means the
--- peer is gone.
function Transport:receive()
  if not self.sock then return nil, "no socket" end
  if self.eof then return nil, "closed" end

  local parts = {}
  while true do
    local data, err, partial = self.sock:receive(READ_CHUNK)
    if data then
      parts[#parts + 1] = data
      -- A full chunk may mean there is more waiting; a short one means the
      -- buffer is drained and another read would only return "timeout".
      if #data < READ_CHUNK then break end
    else
      if partial and partial ~= "" then
        parts[#parts + 1] = partial
      end
      if err == "timeout" then
        break
      end
      -- "closed" or a real error. Hand over whatever arrived with it first;
      -- the EOF is reported on the next call.
      self.eof = true
      if #parts > 0 then
        return table.concat(parts)
      end
      return nil, err or "closed"
    end
  end
  return table.concat(parts)
end

function Transport:close()
  if self.sock then
    pcall(function() self.sock:close() end)
    self.sock = nil
  end
  self.connected = false
end

M.Transport = Transport

return M
