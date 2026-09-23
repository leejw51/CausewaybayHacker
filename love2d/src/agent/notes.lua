-- The coder's answer, as a comment in the file it is about.
--
-- Word for word the browser's `frontend/src/ai/notes.ts`: a reply in the room
-- is read once and scrolls away, while a reply in the code sits next to the
-- line it is about and is still there tomorrow, in the pad that gets saved.
--
-- Pure — no LÖVE in here — because the shape is the part worth testing: a
-- comment that lets a line through unprefixed is a file that does not
-- compile.

local M = {}

--- How each land spells "the rest of this line is not code".
M.LINE_COMMENT = {
  rust = "//", go = "//", cpp = "//", python = "#", pytorch = "#", typescript = "//",
}

--- The mark that says who wrote the comment.
M.NOTE_MARK = "AI:"

--- Where a comment stops being a comment and becomes a margin.
local COLS = 72

--- Wrap on spaces, never breaking a word longer than the line — a URL or an
--- identifier goes over rather than in half.
local function wrap_words(text, cols)
  local out = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      if line == "" then
        line = word
      elseif #line + 1 + #word <= cols then
        line = line .. " " .. word
      else
        out[#out + 1] = line
        line = word
      end
    end
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

--- The reply as comment lines, ready to go in above a line of code.
---
--- The first carries `AI:`; the rest are indented under it by the width of
--- that mark, so a wrapped sentence reads as one paragraph. A reply with
--- nothing in it is no lines at all, not an empty comment.
function M.comment_lines(text, lang, cols)
  cols = cols or COLS
  local mark = M.LINE_COMMENT[lang] or "//"
  local body = (text or ""):gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if body == "" then return {} end
  local pad = (" "):rep(#M.NOTE_MARK + 1)
  local room = math.max(16, cols - #mark - #pad - 1)
  local out = {}
  for i, line in ipairs(wrap_words(body, room)) do
    if i == 1 then
      out[i] = ("%s %s %s"):format(mark, M.NOTE_MARK, line)
    else
      out[i] = ("%s %s%s"):format(mark, pad, line)
    end
  end
  return out
end

return M
