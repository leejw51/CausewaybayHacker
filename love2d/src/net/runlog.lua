-- Reassembly for PROTOCOL §4.18 `run.log`.
--
-- The two rules that file states, and that this module exists to obey:
--
--   * "Chunks are UTF-8 and **may split anywhere, including mid-line**; a
--     client must buffer rather than assume lines." So nothing here splits on
--     "\n" on the way in. Lines are a *view*, computed on demand, and the
--     tail without a trailing newline is a partial line, not a line.
--   * "`seq` counts from 0 **per stream** per attempt, so a client can detect
--     a gap." A gap is recorded and surfaced, not silently healed: a missing
--     chunk means the compiler output the player is reading has a hole in it,
--     and pretending otherwise is worse than saying so.
--
-- Chunks may also arrive out of order (the server replies out of order by
-- §2.2, and nothing promises event ordering across streams), so they are
-- placed by `seq` and the contiguous prefix is what `text()` returns.
--
-- A chunk may also split a UTF-8 code point, which is why concatenation is by
-- byte and any character-level work happens after reassembly.
--
-- No `love.` in this file.

local M = {}

local Stream = {}
Stream.__index = Stream

local function new_stream()
  return setmetatable({
    chunks = {},     -- seq -> chunk bytes
    next_seq = 0,    -- the first seq not yet folded into `text`
    text = "",       -- the contiguous prefix
    highest = -1,    -- the highest seq seen
    received = 0,
    duplicates = 0,
  }, Stream)
end

--- Fold everything contiguous from `next_seq` into `text`.
function Stream:drain()
  local parts = nil
  while self.chunks[self.next_seq] ~= nil do
    parts = parts or { self.text }
    parts[#parts + 1] = self.chunks[self.next_seq]
    self.chunks[self.next_seq] = nil
    self.next_seq = self.next_seq + 1
  end
  if parts then
    self.text = table.concat(parts)
  end
end

--- Every seq below `highest` that has not arrived.
function Stream:gaps()
  local missing = {}
  for s = self.next_seq, self.highest do
    if self.chunks[s] == nil then
      missing[#missing + 1] = s
    end
  end
  return missing
end

local Log = {}
Log.__index = Log
M.Log = Log

--- One attempt's streamed output.
function M.new(attempt_id)
  return setmetatable({
    attempt_id = attempt_id,
    streams = {},
    order = {},       -- stream names, in the order they first appeared
    total_bytes = 0,
    truncated = false,
  }, Log)
end

function Log:stream(name)
  local s = self.streams[name]
  if not s then
    s = new_stream()
    self.streams[name] = s
    self.order[#self.order + 1] = name
  end
  return s
end

--- Take one `run.log` payload.
---
--- Returns `true` normally, or `false, reason` when the payload is not one
--- this log should hold (a different attempt, a malformed seq).
function Log:add(payload)
  if type(payload) ~= "table" then return false, "payload is not an object" end
  if payload.attempt_id ~= nil and self.attempt_id ~= nil
    and payload.attempt_id ~= self.attempt_id then
    return false, "chunk belongs to " .. tostring(payload.attempt_id)
  end
  local name = payload.stream
  if type(name) ~= "string" then return false, "no stream name" end
  local seq = payload.seq
  if type(seq) ~= "number" or seq < 0 or seq ~= math.floor(seq) then
    return false, "seq is not a non-negative integer"
  end
  local chunk = payload.chunk
  if type(chunk) ~= "string" then return false, "chunk is not a string" end

  local s = self:stream(name)
  if seq < s.next_seq or s.chunks[seq] ~= nil then
    -- Already folded in, or already held: a duplicate. Counted, not applied,
    -- so a retransmit cannot double a line of compiler output.
    s.duplicates = s.duplicates + 1
    return true
  end
  s.chunks[seq] = chunk
  s.received = s.received + 1
  if seq > s.highest then s.highest = seq end
  self.total_bytes = self.total_bytes + #chunk
  s:drain()

  -- PROTOCOL §4.18: the server caps an attempt at 256 KiB and then sends one
  -- final chunk saying so. Recognised here so the UI can render it as a note
  -- rather than as compiler output.
  if chunk:find("…output truncated", 1, true) then
    self.truncated = true
  end
  return true
end

--- The contiguous text of one stream — everything up to the first hole.
function Log:text(name)
  local s = self.streams[name]
  if not s then return "" end
  return s.text
end

--- The text of one stream split for display: whole lines, plus the partial
--- tail as its own entry when there is one.
---
--- A caller that renders `lines` and drops `tail` is a caller that never
--- shows the last line of a compile error until the newline arrives.
function Log:lines(name)
  local text = self:text(name)
  local lines, tail = {}, ""
  local start = 1
  while true do
    local nl = text:find("\n", start, true)
    if not nl then
      tail = text:sub(start)
      break
    end
    lines[#lines + 1] = text:sub(start, nl - 1)
    start = nl + 1
  end
  return lines, tail
end

--- Every stream that is missing a chunk, as `{ stream = {seq, ...}, ... }`.
--- Empty when nothing is missing. §8 point 8 is "notices a `seq` gap"; this
--- is the noticing.
function Log:gaps()
  local out, any = {}, false
  for _, name in ipairs(self.order) do
    local missing = self.streams[name]:gaps()
    if #missing > 0 then
      out[name] = missing
      any = true
    end
  end
  if not any then return nil end
  return out
end

--- True when every chunk seen so far is contiguous.
function Log:complete()
  return self:gaps() == nil
end

--- A one-line description of the holes, for the console and the quest screen.
function Log:gap_report()
  local gaps = self:gaps()
  if not gaps then return nil end
  local parts = {}
  for _, name in ipairs(self.order) do
    if gaps[name] then
      parts[#parts + 1] = ("%s: missing seq %s"):format(name, table.concat(gaps[name], ", "))
    end
  end
  return table.concat(parts, "; ")
end

return M
