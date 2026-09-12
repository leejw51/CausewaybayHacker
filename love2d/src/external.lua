-- The `$EDITOR` escape hatch.
--
-- The in-game editor is a real editor (multi-line, selection, undo, the
-- clipboard, syntax colour) and a player can finish a quest in it. It is
-- still not vim, and somebody who has spent fifteen years in vim will want
-- vim. F9 writes the buffer to a temp file, opens `$EDITOR` on it, waits, and
-- reads it back.
--
-- Where the file goes: `$CAUSEWAYBAY_HACKER_HOME` or `~/.causewaybayhacker`,
-- matching SPEC §1's home so a scratch file is not scattered across `/tmp`.
-- The file is removed afterwards; it is the player's own source, but it is
-- also the thing they are being graded on, and leaving copies around is how a
-- stale one gets submitted.
--
-- On macOS and Linux this blocks the whole game while the editor is open,
-- which is correct: there is nothing to render, and a terminal editor owns
-- the terminal until it exits. LÖVE has no terminal of its own, so this only
-- works when the game was started from one — which is said out loud rather
-- than failing mysteriously.

local M = {}

M.DIR_ENV = "CAUSEWAYBAY_HACKER_HOME"

-- The scratch file's extension, so `$EDITOR` picks the right mode. A land
-- not listed gets `.txt`, which is plain but never wrong.
local EXT = { rust = "rs", go = "go", cpp = "cpp", python = "py" }
M.EXT = EXT

function M.home()
  local override = os.getenv(M.DIR_ENV)
  if override and override ~= "" then return override end
  local home = os.getenv("HOME") or os.getenv("USERPROFILE")
  if not home or home == "" then return nil end
  return home .. "/.causewaybayhacker"
end

function M.editor_command()
  local editor = os.getenv("VISUAL")
  if not editor or editor == "" then editor = os.getenv("EDITOR") end
  if not editor or editor == "" then return nil end
  return editor
end

--- Round-trip `text` through `$EDITOR`. Returns the new text, or nil, message.
function M.edit(text, land)
  local editor = M.editor_command()
  if not editor then
    return nil, "no $EDITOR or $VISUAL is set"
  end
  local dir = M.home()
  if not dir then
    return nil, "no home directory to write a scratch file in"
  end
  -- 0700, as SPEC §1 says the home is created; `mkdir -p` is a no-op when it
  -- already exists.
  os.execute(("mkdir -p %q && chmod 700 %q"):format(dir, dir))

  local path = ("%s/scratch-%d.%s"):format(dir, os.time(), EXT[land] or "txt")
  local fh, err = io.open(path, "w")
  if not fh then
    return nil, "could not write " .. path .. ": " .. tostring(err)
  end
  fh:write(text or "")
  fh:close()
  os.execute(("chmod 600 %q"):format(path))

  local ok = os.execute(("%s %q"):format(editor, path))
  if ok == false then
    os.remove(path)
    return nil, ("%s exited with an error"):format(editor)
  end

  local read = io.open(path, "r")
  if not read then
    return nil, "the file came back missing"
  end
  local body = read:read("*a")
  read:close()
  os.remove(path)
  return body
end

return M
