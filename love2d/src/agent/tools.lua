-- What the model may do, and the bench it does it on.
--
-- One list of JSON-schema tools (docs/agent.md §3), the same list the browser
-- sends (`frontend/src/ai/tools.ts`), rendered into each provider's own shape
-- by `providers.lua`. Every tool runs **on this machine**: the model asks, the
-- bench — implemented by the screen that owns the editor — does it, and the
-- result goes back as text. Nothing here is a server call except through the
-- bench's own websocket.
--
-- One file per entry, always, so there is no path in any of these: "the code"
-- is the editor's text and that is the whole project.
--
-- ## Slow tools yield
--
-- The web writes this with `await`. Here the session runs in a coroutine, and
-- a tool that takes time — anything typed, anything that runs — yields; the
-- screen resumes it when the typist has finished or the run has come back. A
-- tool is therefore written as straight-line code in both clients, and in
-- neither does the model get its next turn while the program is still
-- appearing on the screen.

local M = {}

--- The whole catalogue. Descriptions are kept word-for-word with the web's:
--- the model's behaviour is the product, and two clients that describe their
--- tools differently are two different products.
M.TOOLS = {
  {
    name = "read_code",
    description = "Read the whole program as it is in the editor right now, with 1-based line numbers. Call this before editing if the text may have changed since you last saw it.",
    properties = {},
    required = {},
  },
  {
    name = "edit_code",
    description = "Replace one exact span of the program. `find` must appear exactly once in the current text (copy it verbatim, including indentation); it is replaced by `replace`. Use this for a small change — a line, a function — rather than rewriting the file.",
    properties = {
      find = { type = "string", description = "The exact text to replace; must occur exactly once." },
      replace = { type = "string", description = "What to put in its place." },
      note = {
        type = "string",
        description = "One short sentence, for the person watching, saying what this does. Optional.",
      },
    },
    required = { "find", "replace" },
  },
  {
    name = "write_code",
    description = "Replace the whole program with `source`. Use this for a new program or a rewrite; for a small change prefer edit_code. The text is typed into the editor one character at a time while the person watches, so keep it to what is needed.",
    properties = {
      source = { type = "string", description = "The complete new program." },
      note = {
        type = "string",
        description = "One short sentence, for the person watching, saying what this does. Optional.",
      },
    },
    required = { "source" },
  },
  {
    name = "insert_code",
    description = "Type `text` at the caret, where the person's cursor is.",
    properties = {
      text = { type = "string", description = "The text to type at the caret." },
    },
    required = { "text" },
  },
  {
    name = "run_code",
    description = "Compile and run the program as the RUN button does, and get back the outcome, stdout and stderr (the compiler's own errors on a failed build). After writing code, run it and fix what the compiler says before answering.",
    properties = {
      stdin = { type = "string", description = "What the program reads on standard input. Optional." },
      note = {
        type = "string",
        description = "One short sentence, for the person watching, saying what this does. Optional.",
      },
    },
    required = {},
  },
  {
    name = "format_code",
    description = "Run the language's own formatter (rustfmt, gofmt, clang-format, black, prettier) over the program in place.",
    properties = {},
    required = {},
  },
  {
    name = "search_notes",
    description = "Search this person's own notes: every message and photo prompt in the chatrooms of all their scratchpads, by keyword and by meaning. Use it when they refer to something they wrote before.",
    properties = { q = { type = "string", description = "What to look for." } },
    required = { "q" },
  },
  {
    name = "make_image",
    description = "Generate a picture from a prompt and post it in this scratchpad's chatroom. Only when the person asks for a picture.",
    properties = { prompt = { type = "string", description = "What the picture shows." } },
    required = { "prompt" },
  },
}

--- The tools this bench can actually honour.
function M.tools_for(bench)
  local out = {}
  for _, tool in ipairs(M.TOOLS) do
    local keep = true
    if tool.name == "run_code" then
      keep = bench.run ~= nil
    elseif tool.name == "format_code" then
      keep = bench.format ~= nil
    elseif tool.name == "search_notes" then
      keep = bench.search ~= nil
    elseif tool.name == "make_image" then
      keep = bench.image ~= nil
    end
    if keep then out[#out + 1] = tool end
  end
  return out
end

--- The program with line numbers, the way a reviewer reads it.
function M.numbered(source)
  local lines = {}
  for line in (source .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  -- A trailing newline in the source makes one empty line too many.
  if #lines > 1 and lines[#lines] == "" and source:sub(-1) ~= "\n" then lines[#lines] = nil end
  local width = #tostring(#lines)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = string.format("%" .. width .. "d| %s", i, line)
  end
  return table.concat(out, "\n")
end

--- How much of a run's output the model gets to read.
M.OUTPUT_CAP = 6000

local function cap(text)
  text = text or ""
  if #text <= M.OUTPUT_CAP then return text end
  return text:sub(1, M.OUTPUT_CAP) .. ("\n…[%d more chars]"):format(#text - M.OUTPUT_CAP)
end

local function str(input, key)
  local v = input and input[key]
  return type(v) == "string" and v or ""
end

--- Run one tool call. Every outcome is a string for the model, and a refusal
--- is a sentence rather than an error: the model can read "that span is not in
--- the file" and try again, and cannot read a stack trace.
---
--- Returns `text, is_error`.
function M.run_tool(bench, name, input)
  input = input or {}
  local ok, text, failed = pcall(function()
    if name == "read_code" then
      return bench.file .. ":\n" .. M.numbered(bench.read()), false
    elseif name == "edit_code" then
      local find = str(input, "find")
      if find == "" then return "`find` is empty.", true end
      local res = bench.edit(find, str(input, "replace"))
      if res.ok then return "Edited.", false end
      return res.why or "That span is not in the file exactly once.", true
    elseif name == "write_code" then
      local source = str(input, "source")
      if source:match("^%s*$") then return "`source` is empty.", true end
      local r = bench.write(source)
      if r.stopped then
        return ("Stopped by the person after %d of %d characters."):format(r.typed, r.total), true
      end
      return ("Typed %d characters; the file is now the new program."):format(r.total), false
    elseif name == "insert_code" then
      local text = str(input, "text")
      if text == "" then return "`text` is empty.", true end
      local r = bench.insert(text)
      if r.stopped then
        return ("Stopped by the person after %d of %d characters."):format(r.typed, r.total), true
      end
      return ("Typed %d characters at the caret."):format(r.total), false
    elseif name == "run_code" then
      if not bench.run then return "This screen cannot run code.", true end
      local stdin = str(input, "stdin")
      local r = bench.run(stdin ~= "" and stdin or nil)
      local lines = {
        ("outcome: %s"):format(r.outcome),
        ("compile %d ms · run %d ms%s"):format(
          r.compile_ms or 0,
          r.run_ms or 0,
          r.exit_code == nil and "" or (" · exit %d"):format(r.exit_code)
        ),
      }
      if (r.stdout or ""):match("%S") then lines[#lines + 1] = "stdout:\n" .. cap(r.stdout) end
      if (r.stderr or ""):match("%S") then lines[#lines + 1] = "stderr:\n" .. cap(r.stderr) end
      return table.concat(lines, "\n"), false
    elseif name == "format_code" then
      if not bench.format then return "There is no formatter for this language here.", true end
      local r = bench.format()
      if r.problem then return "The formatter could not parse it: " .. r.problem, true end
      return r.changed and "Formatted." or "Already tidy.", false
    elseif name == "search_notes" then
      if not bench.search then return "There are no notes to search on this screen.", true end
      return bench.search(str(input, "q")), false
    elseif name == "make_image" then
      if not bench.image then return "This provider cannot make pictures.", true end
      return bench.image(str(input, "prompt")), false
    end
    return ("Unknown tool %s."):format(tostring(name)), true
  end)
  if not ok then
    return ("%s failed: %s"):format(tostring(name), tostring(text)), true
  end
  return text, failed
end

return M
