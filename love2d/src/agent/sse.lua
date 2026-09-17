-- Server-sent events, reassembled from whatever the network felt like giving.
--
-- Both dialects this client speaks stream with `text/event-stream`: OpenAI's
-- sends bare `data:` lines ending in `data: [DONE]`, Anthropic's sends an
-- `event:` name with every one. A read can end anywhere — mid-line, mid-event,
-- mid-character — so bytes go in and whole events come out, and what has not
-- finished arriving is kept for the next call.
--
-- No `love.` here; the suite feeds it bytes a character at a time.

local M = {}

local Stream = {}
Stream.__index = Stream

function M.new()
  return setmetatable({ buffer = "" }, Stream)
end

--- Feed bytes. Returns the list of events they completed, each
--- `{ event = name|nil, data = text }`, oldest first.
---
--- A comment line (`:` first, which is how a server keeps a connection warm)
--- is dropped. An event with no `data` is dropped: there is nothing in it.
function Stream:feed(bytes)
  self.buffer = self.buffer .. (bytes or "")
  local out = {}
  while true do
    -- An event ends at a blank line. `\r\n` is legal and some proxies rewrite
    -- to it, so both endings are looked for and the nearer one wins.
    local at, stop = self.buffer:find("\n\n", 1, true)
    local at_r, stop_r = self.buffer:find("\r\n\r\n", 1, true)
    if at_r and (not at or at_r < at) then
      at, stop = at_r, stop_r
    end
    if not at then break end
    local block = self.buffer:sub(1, at - 1)
    self.buffer = self.buffer:sub(stop + 1)
    local name, data = nil, {}
    for line in (block .. "\n"):gmatch("(.-)\n") do
      line = line:gsub("\r$", "")
      if line ~= "" and line:sub(1, 1) ~= ":" then
        local field, value = line:match("^([^:]*):?%s?(.*)$")
        if field == "event" then
          name = value
        elseif field == "data" then
          data[#data + 1] = value
        end
      end
    end
    if #data > 0 then
      out[#out + 1] = { event = name, data = table.concat(data, "\n") }
    end
  end
  return out
end

--- Whatever is still half-arrived. For a test, and for an error message that
--- wants to show what the provider actually said.
function Stream:rest()
  return self.buffer
end

return M
