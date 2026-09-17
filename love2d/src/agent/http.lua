-- The Lua side of the key library's streaming HTTP (`love2d/ffi/src/http.rs`).
--
-- A call is a handle: `M.start` spawns the request, `call:poll()` takes
-- whatever bytes have landed since the last frame, `call:cancel()` stops it
-- and `call:close()` releases it. Nothing here ever blocks, because everything
-- here is called from inside `love.update`.
--
-- Bytes come across base64 (a network read can split a UTF-8 sequence, and a
-- JSON string cannot carry half a character) and are decoded with the same
-- `src/net/base64.lua` the websocket handshake uses.
--
-- No `love.` in this file: the headless suite drives it against a loopback
-- server with nothing but LuaJIT.

local base64 = require("src.net.base64")

local M = {}

local Call = {}
Call.__index = Call

--- Start a request. `lib` is the loaded key library, `wallet` its binding.
---
---   opts.url      where to, http:// or https://
---   opts.method   default POST when there is a body, GET otherwise
---   opts.headers  a table of name → value
---   opts.body     the request body as text
---
--- Returns a call, or nil and a message.
function M.start(wallet, lib, opts)
  if not lib then return nil, "the key library is not loaded" end
  local res, err = wallet.execute(lib, {
    op = "http_start",
    url = opts.url,
    method = opts.method,
    headers = opts.headers,
    body = opts.body,
  })
  if not res then return nil, err end
  return setmetatable({
    wallet = wallet,
    lib = lib,
    handle = res.handle,
    status = nil,
    done = false,
    failed = nil,
    cancelled = false,
    closed = false,
    bytes = 0,
  }, Call)
end

--- Take whatever has arrived. Returns the text of this poll (possibly ""),
--- and sets `status`, `done` and `failed` on the call.
function Call:poll()
  if self.closed or self.done then return "" end
  local res, err = self.wallet.execute(self.lib, { op = "http_poll", handle = self.handle })
  if not res then
    self.failed = err or "the request could not be polled"
    self.done = true
    return ""
  end
  -- JSON `null` decodes to `json.null`, a table, which is **truthy** in Lua:
  -- every one of these has to be asked what type it is rather than whether it
  -- is there. A status of `null` taken as a status, or an error of `null`
  -- taken as an error, fails every call that ever succeeded.
  if type(res.status) == "number" then self.status = res.status end
  local text = {}
  for _, chunk in ipairs(res.chunks or {}) do
    local piece = base64.decode(chunk)
    self.bytes = self.bytes + #piece
    text[#text + 1] = piece
  end
  if type(res.error) == "string" and res.error ~= "" then self.failed = res.error end
  if res.cancelled == true then self.cancelled = true end
  if res.done == true then self.done = true end
  return table.concat(text)
end

--- Ask it to stop at the next read. The handle stays pollable.
function Call:cancel()
  if self.closed then return end
  self.cancelled = true
  self.wallet.execute(self.lib, { op = "http_cancel", handle = self.handle })
end

--- Cancel and forget. The only way a handle is released.
function Call:close()
  if self.closed then return end
  self.closed = true
  self.done = true
  self.wallet.execute(self.lib, { op = "http_close", handle = self.handle })
end

--- Read the whole reply, one `coroutine.yield` per frame while it arrives.
---
--- This is what a provider call looks like from inside the session's
--- coroutine: straight-line code that happens to give the screen a frame back
--- between chunks. `on_text` sees every piece as it lands.
---
--- Returns the whole body, the status, and a message when it failed.
function Call:read(on_text)
  local body = {}
  while true do
    -- One poll carries both the bytes and the end: the last chunks and
    -- `done` come back together, so there is nothing left to collect after
    -- the loop breaks.
    local piece = self:poll()
    if piece ~= "" then
      body[#body + 1] = piece
      if on_text then on_text(piece) end
    end
    if self.done then break end
    coroutine.yield()
  end
  return table.concat(body), self.status, self.failed
end

return M
