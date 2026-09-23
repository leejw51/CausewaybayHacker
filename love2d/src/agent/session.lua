-- One conversation with the model, and the loop that lets it act.
--
-- `ask()` sends the transcript, streams the prose back, and — while the model
-- keeps asking for tools — runs them on the bench and sends the results, up to
-- `MAX_ROUNDS` turns. That is the whole "coding agent": read the file, edit or
-- write it, run it, read what the compiler said, fix it, run again, then
-- explain. Every step of it happens on this machine (docs/agent.md §3).
--
-- The session is the client's memory of the room: what was said, which tools
-- ran, what they answered. The screen posts the human-readable messages to the
-- server for keeps (`playground.chat.post`); this holds the shape the model
-- needs, tool ids and all, for the length of the visit.
--
-- ## A coroutine, not a promise
--
-- The browser writes this with `await`. Here the whole ask runs inside one
-- coroutine that yields a frame whenever it is waiting — on the network, on
-- the typist, on a run — and `Session:update` resumes it once a frame. The
-- code either side of a wait is therefore the same straight line in both
-- clients. (LuaJIT can yield across `pcall`, which is what lets `tools.lua`
-- guard a tool that waits.)

local Prefs = require("src.agent.prefs")
local Providers = require("src.agent.providers")
local Tools = require("src.agent.tools")
local json = require("src.json")

local M = {}

--- How many times in one ask the model may come back for another tool.
M.MAX_ROUNDS = 10
--- Transcript turns kept for the model; older ones fall off the front.
M.KEEP_TURNS = 24

--- The names the game uses for itself, for the model.
local LANG_NAME = {
  rust = "Rust",
  go = "Go",
  cpp = "C++ (C++20)",
  python = "Python 3",
  pytorch = "Python 3 + PyTorch",
  typescript = "TypeScript (tsc --strict, run on Node)",
}

--- The most of one stream or one wrong answer that goes into the prompt.
local CLIP = 2000

local function clip(text)
  if #text <= CLIP then return text end
  return text:sub(1, CLIP) .. ("\n… (%d more characters)"):format(#text - CLIP)
end

--- JSON's spelling of a string, for the sample cases: a newline has to be
--- visible in the prompt as `\n` or a one-line expectation reads as two.
local function quoted(text)
  return json.encode(tostring(text or ""))
end

--- The exercise, for the screens that set one (`bench.task`).
---
--- Everything in here is something the person is already looking at: the
--- brief they are reading, the sample cases under it, the report the last RUN
--- printed, and — only on a quest they have already cleared, because that is
--- the only time the server sends it — the reference answer. The hidden cases
--- are a number, the way they are on the screen.
local function task_lines(task, out)
  out[#out + 1] = ""
  out[#out + 1] =
    "The person is not writing whatever they like: this screen is a graded exercise, and this is it."
  out[#out + 1] = ""
  out[#out + 1] = ("Title: %s"):format(task.title or "")
  out[#out + 1] = ("Brief: %s"):format(task.brief or "")
  if task.story and task.story:match("%S") then
    out[#out + 1] = ("Story: %s"):format(task.story)
  end
  local tests = task.tests or {}
  if #tests > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "The sample cases (stdin → expected stdout):"
    for _, c in ipairs(tests) do
      out[#out + 1] = ("- %s → %s"):format(quoted(c.stdin), quoted(c.expect))
    end
  end
  if (task.hidden_count or 0) > 0 then
    out[#out + 1] = ("There are also %d hidden case(s) nobody can see, including you. A program that only answers the samples will fail them.")
      :format(task.hidden_count)
  end
  local run = task.last_run
  if run then
    out[#out + 1] = ""
    out[#out + 1] = ("The last RUN: %s, %d/%d of the visible cases passed.")
      :format(run.verdict or "?", run.passed or 0, run.total or 0)
    if run.stderr and run.stderr:match("%S") then
      out[#out + 1] = "What the compiler or the program said:"
      out[#out + 1] = "```"
      out[#out + 1] = clip(run.stderr)
      out[#out + 1] = "```"
    end
    for _, c in ipairs(run.failing or {}) do
      out[#out + 1] = ("Failed on %s: expected %s, got %s.")
        :format(quoted(c.stdin), quoted(c.expect), quoted(clip(c.got or "")))
    end
  end
  if task.cleared then
    out[#out + 1] = ""
    out[#out + 1] =
      "The person has already cleared this one; they are here to practise or to understand it."
  end
  if task.solution and task.solution:match("%S") then
    out[#out + 1] = ""
    out[#out + 1] =
      "The reference answer (they have cleared this quest, so they can already read it — use it to explain, not to replace their own):"
    out[#out + 1] = "```"
    out[#out + 1] = task.solution
    out[#out + 1] = "```"
  end
  out[#out + 1] = ""
  out[#out + 1] =
    "On a graded screen: answer the question they asked. Explain, name the line, say what the compiler is complaining about. They learn nothing from a program that appeared while they were reading, so write the whole answer into the editor only when they ask you for it outright — and then say what it does."
end

--- The coder's standing orders. Stable text first, the exercise, the file last.
---
--- Word-for-word the browser's (`frontend/src/ai/session.ts`). The prompt is
--- what makes the character; two clients with different prompts would be two
--- different characters wearing the same sprite.
function M.system_prompt(bench, can_run)
  local lang = LANG_NAME[bench.lang] or bench.lang
  local task = bench.task and bench.task() or nil
  local lines = {
    ("You are the Rust coder — a small pixel-art character on a flying keyboard who lives on the code screen of Causewaybay Hacker, a 16-bit coding game set in Hong Kong. The person is learning %s. You are their pair: a friendly senior engineer who explains briefly and lets the code speak."):format(lang),
    "",
    "The whole project is ONE source file, the one in the editor. There are no other files, no build system to configure, no dependencies beyond the standard library (Rust: std only, no crates; Go: standard library; C++: the standard library, compiled with -std=c++20; Python 3: the standard library; TypeScript: tsc in strict mode with no @types/node — only process, console, the timers and fs.readFileSync are declared, so stdin is read with `const input: string = require(\"fs\").readFileSync(0, \"utf8\");` and output goes through console.log).",
    "",
    "How to work:",
    "- For a small change, use edit_code with the exact span. For a new program or a rewrite, use write_code. Both are typed into the editor character by character while the person watches, so write only what is needed and no filler comments.",
    can_run
        and "- After changing code, call run_code and read the outcome. If it did not compile or crashed, read the compiler's message, fix the code, and run again — up to a few times — before you answer."
      or "- This screen cannot run code, so read carefully and reason about it instead.",
    "- Do not paste code into your prose when you could put it in the editor with a tool. Your prose is a short chat message: what you did and why, one to four sentences, plain text, no markdown headings.",
    "- If asked to review, be concrete: name the line and the habit, and offer the fix. Do not rewrite a working program nobody asked you to rewrite.",
    "- Keep the person's style, names and formatting unless asked. Keep the program's existing behaviour unless asked.",
    "- Never invent an API. If unsure, prefer the plain standard-library way.",
    "- A picture is not a program. When the person asks for a picture, image, drawing or photo, call make_image with a prompt; do not write code that prints one, and do not describe it instead.",
  }
  if task then task_lines(task, lines) end
  local tail = {
    "",
    ("The file is %s. Its current text, with line numbers (do not include the numbers in edits):"):format(bench.file),
    "```",
    Tools.numbered(bench.read()),
    "```",
  }
  for _, line in ipairs(tail) do lines[#lines + 1] = line end
  return table.concat(lines, "\n")
end

--- The last-round nudge: no tools left, so say where you got to.
M.FINAL_NUDGE =
  "You have used every tool round you have. Do not call tools; say in two or three sentences what you did and what, if anything, is left."

local Session = {}
Session.__index = Session

--- `listener` wants `text(delta)`, `tool(name, input)`,
--- `tool_done(name, text, error)` and `mood(m)`, where a mood is one of
--- "idle", "thinking", "typing", "running".
function M.new(bench, listener, wallet, lib)
  return setmetatable({
    bench = bench,
    listener = listener,
    wallet = wallet,
    lib = lib,
    messages = {},
    co = nil,
    stopping = false,
    last = "",
  }, Session)
end

function Session:busy()
  return self.co ~= nil
end

--- Forget the conversation. The server's copy, if any, is the screen's business.
function Session:clear()
  self:stop()
  self.messages = {}
end

--- Ask it to stop. The coroutine notices at its next wait: mid-stream the
--- request is cancelled, mid-typing the typist is stopped by the screen.
function Session:stop()
  if self.co then self.stopping = true end
end

local function push_text(messages, role, text)
  messages[#messages + 1] = { role = role, content = { { type = "text", text = text } } }
end

--- Keep the transcript to a size a model can hold, without ever cutting
--- between a tool call and its result: the front is dropped in whole
--- user-started exchanges.
function Session:trim()
  while #self.messages > M.KEEP_TURNS do
    table.remove(self.messages, 1)
    while #self.messages > 0 do
      local first = self.messages[1]
      local starts = false
      if first.role == "user" then
        for _, part in ipairs(first.content) do
          if part.type == "text" then starts = true end
        end
      end
      if starts then break end
      table.remove(self.messages, 1)
    end
  end
end

--- One ask, however many rounds it takes.
---
--- Returns immediately: the work runs in a coroutine that `update` pumps.
--- `done(text, err)` is called at the end with the prose of the last turn, or
--- nil and a message when the provider refused or the network failed.
function Session:ask(provider, text, done)
  if self:busy() then
    if done then done(nil, "busy") end
    return
  end
  local key = Prefs.key(provider)
  local model = Prefs.model(provider)
  if key == "" and Prefs.needs_key(provider) then
    if done then done(nil, "no api key") end
    return
  end
  self.stopping = false
  self.last = ""
  push_text(self.messages, "user", text)
  self:trim()
  local tools = Tools.tools_for(self.bench)
  local session = self

  self.co = coroutine.create(function()
    for round = 0, M.MAX_ROUNDS do
      session.listener.mood("thinking")
      -- The last round goes out with no tools at all, so a model that would
      -- keep going is made to stop and say where it got to rather than being
      -- cut off mid-loop with nothing said.
      local final = round == M.MAX_ROUNDS
      local messages = session.messages
      if final then
        messages = {}
        for i, m in ipairs(session.messages) do messages[i] = m end
        push_text(messages, "user", M.FINAL_NUDGE)
      end
      local turn, err = Providers.chat({
        wallet = session.wallet,
        lib = session.lib,
        provider = provider,
        key = key,
        model = model,
        system = M.system_prompt(session.bench, session.bench.run ~= nil),
        messages = messages,
        tools = final and {} or tools,
        on_text = function(delta) session.listener.text(delta) end,
        cancelled = function() return session.stopping end,
      })
      if not turn then
        if err == "stopped" then return session.last end
        error(err or "the provider said nothing", 0)
      end

      local parts = {}
      if turn.text ~= "" then parts[#parts + 1] = { type = "text", text = turn.text } end
      for _, use in ipairs(turn.tool_uses) do
        parts[#parts + 1] =
          { type = "tool_use", id = use.id, name = use.name, input = use.input }
      end
      if #parts > 0 then
        session.messages[#session.messages + 1] = { role = "assistant", content = parts }
      end
      session.last = turn.text
      if turn.stop ~= "tool" or #turn.tool_uses == 0 then return session.last end

      local results = {}
      for _, use in ipairs(turn.tool_uses) do
        if session.stopping then break end
        local mood = "thinking"
        if use.name == "run_code" then
          mood = "running"
        elseif use.name:match("code$") then
          mood = "typing"
        end
        session.listener.mood(mood)
        session.listener.tool(use.name, use.input)
        local out, failed
        if use.input.__invalid_json then
          out, failed = "The tool call's JSON did not parse; send it again.", true
        else
          out, failed = Tools.run_tool(session.bench, use.name, use.input)
        end
        session.listener.tool_done(use.name, out, failed)
        results[#results + 1] = {
          type = "tool_result",
          tool_use_id = use.id,
          name = use.name,
          content = out,
          is_error = failed,
        }
      end
      -- STOP during a tool: every tool_use in the assistant turn still has
      -- to be answered, or the next ask goes out with a call and no result
      -- and the provider refuses the whole transcript until the room is
      -- cleared. The tools that ran keep their result; the rest are told so.
      if session.stopping then
        for i = #results + 1, #turn.tool_uses do
          local use = turn.tool_uses[i]
          results[#results + 1] = {
            type = "tool_result",
            tool_use_id = use.id,
            name = use.name,
            content = "Stopped by the player before this tool ran.",
            is_error = true,
          }
        end
        session.messages[#session.messages + 1] = { role = "user", content = results }
        return session.last
      end
      session.messages[#session.messages + 1] = { role = "user", content = results }
    end
    return session.last
  end)

  self.done = done
  -- One resume now, so a failure that needs no network is reported this frame.
  self:update()
end

--- Give the ask a frame. Does nothing when there is none.
function Session:update()
  if not self.co then return end
  local ok, value = coroutine.resume(self.co)
  if coroutine.status(self.co) == "dead" then
    local done = self.done
    self.co = nil
    self.done = nil
    self.stopping = false
    self.listener.mood("idle")
    if done then
      if ok then
        done(value or "", nil)
      else
        done(nil, tostring(value))
      end
    end
  elseif not ok then
    -- A coroutine that is neither dead nor fine cannot happen; treated as a
    -- failure rather than left running.
    self.co = nil
    self.listener.mood("idle")
    if self.done then self.done(nil, tostring(value)) end
    self.done = nil
  end
end

M.Session = Session

return M
