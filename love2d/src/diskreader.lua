-- DISK READER: a poster back into a pad, and a claim back into a fact.
--
-- The LÖVE half of `frontend/src/ui/diskreader.ts`. A picture comes in as a
-- path — dropped on the window, or typed — and this says what is on it and
-- whether it is true: the file's own text chunks when it is our PNG, the QR
-- label off its pixels otherwise (both through `libcwbh_ffi`'s `disk_read`),
-- and then the signature recovered and compared to the address the picture
-- *names*. The verdict is one of `verified`, `forged`, `unsigned`, `hashed`.
-- What is never done: trusting the picture's own claim.
--
-- `judge` and `from_chunks`/`from_label` take the library's answers as
-- plain tables, so `tests/test_poster.lua` runs them without a library.

local Poster = require("src.poster")

local Reader = {}

local LANDS = { rust = true, go = true, cpp = true, python = true }

--- The verdict on a claim, given `recover(message, signature) -> address|nil`.
function Reader.judge(source, address, signature, recover)
  if not signature then
    return "unsigned"
  end
  local who = recover(source, signature)
  if who and who:lower() == address:lower() then
    return "verified"
  end
  return "forged"
end

--- The disk in a PNG's text chunks, or nil when the file has none of ours.
function Reader.from_chunks(chunks, recover)
  if type(chunks) ~= "table" then
    return nil
  end
  if type(chunks.Source) ~= "string" or type(chunks.Signer) ~= "string" then
    return nil
  end
  local signature = type(chunks.Signature) == "string" and chunks.Signature or nil
  return {
    source = chunks.Source,
    lang = LANDS[chunks.Lang] and chunks.Lang or "rust",
    address = chunks.Signer,
    signature = signature,
    title = type(chunks.Title) == "string" and chunks.Title or nil,
    via = "chunks",
    verdict = Reader.judge(chunks.Source, chunks.Signer, signature, recover),
  }
end

--- The disk in a decoded label, or nil when the text is not one of ours.
function Reader.from_label(text, recover)
  local p = Poster.parse_payload(text)
  if not p then
    return nil
  end
  local lang = LANDS[p.lang] and p.lang or "rust"
  if p.body:sub(1, 10) == "keccak256:" then
    return {
      source = "",
      lang = lang,
      address = p.address,
      signature = p.signature,
      title = nil,
      via = "label",
      verdict = "hashed",
    }
  end
  return {
    source = p.body,
    lang = lang,
    address = p.address,
    signature = p.signature,
    title = nil,
    via = "label",
    verdict = Reader.judge(p.body, p.address, p.signature, recover),
  }
end

--- What the library read (`{ chunks, label }`) as a disk, or nil.
function Reader.from_read(read, recover)
  if not read then
    return nil
  end
  local disk = Reader.from_chunks(read.chunks, recover)
  if disk then
    return disk
  end
  if type(read.label) == "string" then
    return Reader.from_label(read.label, recover)
  end
  return nil
end

--- The pad's name for a file with no title of its own: the file's name with
--- what `Poster.file_name` added taken off again.
function Reader.name_from_file(path)
  local base = path:match("([^/\\]+)$") or path
  base = base:gsub("%.[^.]+$", ""):gsub("^cwbhacker%-", ""):gsub("%-%d%d%d%d%d%d%d%d%-%d%d%d%d$", "")
  return base:sub(1, 48)
end

--- The check a poster passes before it is saved, or the name of the check it
--- failed: `signature`, `chunks`, `label`. `read` is the library's
--- `disk_read` of the file just written, `label_text` the QR decoded from
--- the same file (the library reads it only when the chunks are missing, so
--- the caller asks for it separately).
function Reader.prove(read, label_text, source, address, signature, recover, expected_payload)
  if signature and Reader.judge(source, address, signature, recover) ~= "verified" then
    return "signature"
  end
  local c = Reader.from_chunks(read and read.chunks, recover)
  if not c or c.source ~= source or c.address:lower() ~= address:lower() then
    return "chunks"
  end
  if c.signature ~= signature then
    return "chunks"
  end
  if label_text == nil then
    return "label"
  end
  if label_text ~= expected_payload then
    return "label"
  end
  return nil
end

return Reader
