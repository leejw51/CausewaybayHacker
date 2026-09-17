-- Typing like a person.
--
-- The model answers in a burst and the editor could take the whole file in one
-- call, and that is exactly what this must not do: the coder is a character
-- who *writes*, and the whole reason it is a sprite rather than a PASTE button
-- is that you can watch the program appear and read it as it goes. So the text
-- is fed in one character at a time on a schedule that looks typed — a floor
-- so it never blurs, jitter so it never ticks, a breath at every newline, a
-- longer one after a `}` or a `;`, and a rush through the middle of a long
-- identifier the way fingers do once the word is decided.
--
-- `schedule` is pure and tested, and is the same arithmetic as the web's
-- `frontend/src/ai/typist.ts` down to the constants — the two clients type at
-- the same speed because they are the same character. The driver is a clock
-- rather than a timer: `love.update` hands it `dt` and it hands back however
-- many characters that was worth.

local bitops = require("src.net.bitops")

local M = {}

--- Milliseconds per character, before jitter.
M.BASE_MS = 46
--- The floor: never faster than this, or the screen shows a paste.
M.FLOOR_MS = 18
--- The breath at a newline — read the line you just wrote.
M.NEWLINE_MS = 190
--- After a closing brace or a semicolon: the thought ends.
M.STOP_MS = 110
--- Whole-file typing is capped so a 300-line answer is not a five-minute wait.
M.MAX_TOTAL_MS = 45000

--- Deterministic jitter from the character's index, so tests can pin it.
---
--- The web does this in 32-bit arithmetic; LuaJIT's numbers are doubles, so
--- the multiplies are taken modulo 2^32 by hand. The sequence matches the
--- browser's to about seven decimal places: JavaScript's own version
--- multiplies a 32-bit value by 1274126177 in *double* precision, which is
--- past 2^53 and loses its low bits, and this one does not. The difference is
--- a thousandth of a millisecond on a delay of forty — the two clients type
--- at the same speed, which is what the shared constant was for.
local function mul32(a, b)
  -- A 32-bit multiply that does not lose its low bits to a double's mantissa:
  -- split one side into halves, and let the high half's overflow fall off the
  -- top the way it does in C.
  local ah = math.floor(a / 65536) % 65536
  local al = a % 65536
  return ((ah * b) % 65536 * 65536 + al * b) % 4294967296
end

local function jitter(i)
  local x = mul32(i + 1, 2654435761)
  x = mul32(bitops.tou32(bitops.bxor(x, math.floor(x / 8192))), 1274126177)
  x = bitops.tou32(bitops.bxor(x, math.floor(x / 65536)))
  return x / 4294967296
end

M.jitter = jitter

local function is_word(ch)
  return ch ~= nil and ch ~= "" and ch:match("[A-Za-z0-9_]") ~= nil
end

--- The delay *before* each character of `text`, in milliseconds.
---
--- The sum is bounded by `MAX_TOTAL_MS`: when the text is long the whole
--- schedule is scaled down, floored per character, so a long file is typed
--- faster rather than not being watched at all.
function M.schedule(text)
  local out = {}
  local run = 0
  local total = 0
  for i = 1, #text do
    local ch = text:sub(i, i)
    local prev = i > 1 and text:sub(i - 1, i - 1) or ""
    local ms = M.BASE_MS * (0.7 + jitter(i - 1) * 0.6)
    -- Inside a word the fingers speed up; the third letter on is fast.
    if is_word(ch) and is_word(prev) then
      run = run + 1
      if run >= 2 then ms = ms * 0.65 end
    else
      run = 0
    end
    if prev == "\n" then
      ms = ms + M.NEWLINE_MS
    elseif prev == "}" or prev == ";" then
      ms = ms + M.STOP_MS
    end
    -- Leading indentation is one motion, not four keystrokes.
    if ch == " " and (prev == " " or prev == "\n") then ms = M.FLOOR_MS end
    ms = math.max(M.FLOOR_MS, math.floor(ms + 0.5))
    out[i] = ms
    total = total + ms
  end
  if total > M.MAX_TOTAL_MS then
    local k = M.MAX_TOTAL_MS / total
    for i = 1, #out do
      out[i] = math.max(M.FLOOR_MS, math.floor(out[i] * k + 0.5))
    end
  end
  return out
end

-- ------------------------------------------------------------------ the driver

local Typist = {}
Typist.__index = Typist

function M.new()
  return setmetatable({
    text = nil,
    delays = nil,
    typed = 0,
    total = 0,
    clock = 0,
    on_each = nil,
    on_done = nil,
  }, Typist)
end

function Typist:busy()
  return self.text ~= nil
end

--- Start typing `text` into `sink`, which is anything with a `type(ch)`.
--- `on_each` runs after every character; `on_done(finished)` at the end,
--- with `false` when it was stopped. A second `run` stops the first.
function Typist:run(text, sink, on_each, on_done)
  self:stop(false)
  if not text or text == "" then
    if on_done then on_done(true) end
    return
  end
  self.text = text
  self.sink = sink
  self.delays = M.schedule(text)
  self.typed = 0
  self.total = #text
  self.clock = 0
  self.on_each = on_each
  self.on_done = on_done
end

--- Hand it a frame. Types however many characters that frame was worth, so a
--- slow frame catches up rather than falling behind.
function Typist:update(dt)
  if not self.text then return end
  self.clock = self.clock + dt * 1000
  local guard = 0
  while self.text and self.typed < self.total do
    local wait = self.delays[self.typed + 1]
    if self.clock < wait then break end
    self.clock = self.clock - wait
    self.typed = self.typed + 1
    local ch = self.text:sub(self.typed, self.typed)
    self.sink.type(ch)
    if self.on_each then self.on_each(ch) end
    -- A frame that was away for a second must not type a thousand characters
    -- in one go: the point is that it is watched.
    guard = guard + 1
    if guard >= 64 then break end
  end
  if self.text and self.typed >= self.total then
    local done = self.on_done
    self.text = nil
    self.delays = nil
    self.sink = nil
    self.on_each = nil
    self.on_done = nil
    if done then done(true) end
  end
end

--- Stop between two characters. `tell` false skips the callback, for a `run`
--- that is replacing this one.
function Typist:stop(tell)
  local done = self.on_done
  local was = self.text ~= nil
  self.text = nil
  self.delays = nil
  self.sink = nil
  self.on_each = nil
  self.on_done = nil
  if was and tell ~= false and done then done(false) end
end

return M
