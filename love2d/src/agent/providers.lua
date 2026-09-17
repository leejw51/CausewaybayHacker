-- Five providers behind one door.
--
-- `chat()` takes a neutral transcript and the tool catalogue, streams the text
-- back as it arrives, and answers with the turn: what was said, which tools
-- were asked for, and why it stopped. `image()` makes a picture where the
-- provider can. `models()` is what SETUP's FETCH MODELS presses.
--
-- The browser does this with two SDKs (`frontend/src/ai/providers.ts`). There
-- is no SDK here, so this file is the wire: the same REST endpoints, the same
-- request bodies, the same server-sent-event streams, over the key library's
-- HTTP (`agent/http.lua`). Two dialects cover all five — Anthropic's own, and
-- OpenAI's, which xAI, OpenRouter and Ollama all speak.
--
-- ## The rule
--
-- The key goes in a header on the way out to the provider that issued it, and
-- nowhere else. It is never sent to the game server, never written to the
-- event log, never printed. See `prefs.lua` for where it is kept and why.
--
-- Everything in here runs inside the session's coroutine and yields a frame
-- whenever it is waiting, so `love.update` is never blocked.

local json = require("src.json")
local Http = require("src.agent.http")
local SSE = require("src.agent.sse")
local Prefs = require("src.agent.prefs")

local M = {}

--- Room for a whole program in one tool call, and a long explanation.
M.MAX_TOKENS = 16000

M.ANTHROPIC_URL = "https://api.anthropic.com/v1"
M.OPENAI_URL = "https://api.openai.com/v1"
M.XAI_URL = "https://api.x.ai/v1"
M.OPENROUTER_URL = "https://openrouter.ai/api/v1"

M.ANTHROPIC_VERSION = "2023-06-01"

--- Where each provider's OpenAI-dialect endpoints live.
function M.base_url(provider)
  if provider == "openai" then return M.OPENAI_URL end
  if provider == "grok" then return M.XAI_URL end
  if provider == "openrouter" then return M.OPENROUTER_URL end
  if provider == "ollama" then return Prefs.ollama_host() .. "/v1" end
  return M.OPENAI_URL
end

local function headers(provider, key)
  if provider == "anthropic" then
    return {
      ["content-type"] = "application/json",
      ["x-api-key"] = key,
      ["anthropic-version"] = M.ANTHROPIC_VERSION,
    }
  end
  local h = {
    ["content-type"] = "application/json",
    -- Ollama wants no key at all and ignores this; the others need it.
    ["authorization"] = "Bearer " .. (provider == "ollama" and "ollama" or key),
  }
  if provider == "openrouter" then
    -- What OpenRouter asks callers to identify themselves with.
    h["HTTP-Referer"] = "https://github.com/leejw51/CausewaybayHacker"
    h["X-Title"] = "Causewaybay Hacker"
  end
  return h
end

-- `src/json.lua` encodes an empty table as `{}` and a tagged one as `[]`, so
-- an empty object is a bare table and an empty `required` has to say so. A
-- schema with `"required": {}` in it is rejected by every provider here.
local EMPTY_OBJECT = {}

local function schema_of(tool)
  local properties = {}
  local any = false
  for name, prop in pairs(tool.properties or {}) do
    properties[name] = { type = prop.type, description = prop.description }
    any = true
  end
  return {
    type = "object",
    properties = any and properties or EMPTY_OBJECT,
    required = json.array(tool.required or {}),
  }
end

--- The failure a provider's own error body describes, in one line.
local function refusal(status, body)
  local value = json.try_decode(body or "")
  local message = nil
  if type(value) == "table" then
    if type(value.error) == "table" then
      message = value.error.message
    elseif type(value.error) == "string" then
      message = value.error
    elseif type(value.message) == "string" then
      message = value.message
    end
  end
  if not message or message == "" then
    message = (body or ""):gsub("%s+", " "):sub(1, 200)
  end
  if message == "" then message = "no reason given" end
  return ("the provider answered %s: %s"):format(tostring(status), message)
end

-- ------------------------------------------------------------------- the chat

--- Ask for a turn.
---
---   o.wallet, o.lib   the key library and its binding
---   o.provider, o.key, o.model
---   o.system          the system prompt
---   o.messages        the neutral transcript (see `session.lua`)
---   o.tools           what the bench can honour
---   o.on_text         every piece of prose as it lands
---   o.cancelled       a function returning true when the person pressed STOP
---
--- Returns a turn `{ text, tool_uses, stop }`, or nil and a message.
--- `stop` is one of "end", "tool", "max", "refusal".
function M.chat(o)
  if o.provider == "anthropic" then return M.anthropic_chat(o) end
  return M.openai_chat(o)
end

local function run_stream(o, url, body, on_event)
  local call, err = Http.start(o.wallet, o.lib, {
    url = url,
    method = "POST",
    headers = headers(o.provider, o.key),
    body = json.encode(body),
  })
  if not call then return nil, err end
  local stream = SSE.new()
  local raw = {}
  local stopped = false
  while true do
    local piece = call:poll()
    if piece ~= "" then
      raw[#raw + 1] = piece
      -- A failure comes back as one JSON object, not as events; it is kept
      -- whole so `refusal` can read it.
      if call.status and call.status < 400 then
        for _, event in ipairs(stream:feed(piece)) do
          on_event(event)
        end
      end
    end
    if call.done then break end
    if o.cancelled and o.cancelled() then
      call:cancel()
      stopped = true
      break
    end
    coroutine.yield()
  end
  local body_text = table.concat(raw)
  local status, failed = call.status, call.failed
  call:close()
  if stopped then return nil, "stopped" end
  if failed then return nil, failed end
  if not status or status >= 400 then return nil, refusal(status, body_text) end
  return true
end

function M.anthropic_chat(o)
  local messages = {}
  for _, m in ipairs(o.messages) do
    local content = {}
    for _, part in ipairs(m.content) do
      if part.type == "text" then
        -- An empty text block is rejected; a space is not.
        content[#content + 1] = { type = "text", text = part.text ~= "" and part.text or " " }
      elseif part.type == "tool_use" then
        content[#content + 1] = {
          type = "tool_use",
          id = part.id,
          name = part.name,
          input = next(part.input or {}) and part.input or EMPTY_OBJECT,
        }
      elseif part.type == "tool_result" then
        content[#content + 1] = {
          type = "tool_result",
          tool_use_id = part.tool_use_id,
          content = part.content,
          is_error = part.is_error and true or false,
        }
      end
    end
    messages[#messages + 1] = { role = m.role, content = content }
  end
  local tools = {}
  for i, tool in ipairs(o.tools) do
    tools[i] = { name = tool.name, description = tool.description, input_schema = schema_of(tool) }
  end

  local text_parts = {}
  local uses = {}
  local stop_reason = nil
  -- Which content block is being streamed, and what it is collecting.
  local blocks = {}

  local ok, err = run_stream(o, M.ANTHROPIC_URL .. "/messages", {
    model = o.model,
    max_tokens = M.MAX_TOKENS,
    system = o.system,
    messages = messages,
    tools = #tools > 0 and tools or nil,
    stream = true,
  }, function(event)
    local value = json.try_decode(event.data)
    if type(value) ~= "table" then return end
    local kind = value.type or event.event
    if kind == "content_block_start" then
      local block = value.content_block or {}
      blocks[value.index or 0] = { type = block.type, id = block.id, name = block.name, args = {} }
    elseif kind == "content_block_delta" then
      local delta = value.delta or {}
      local block = blocks[value.index or 0]
      if delta.type == "text_delta" and delta.text then
        text_parts[#text_parts + 1] = delta.text
        if o.on_text then o.on_text(delta.text) end
      elseif delta.type == "input_json_delta" and block then
        block.args[#block.args + 1] = delta.partial_json or ""
      end
    elseif kind == "message_delta" then
      stop_reason = (value.delta or {}).stop_reason or stop_reason
    elseif kind == "error" then
      stop_reason = "error"
    end
  end)
  if not ok then return nil, err end

  -- The blocks in the order the model sent them.
  local indices = {}
  for index in pairs(blocks) do indices[#indices + 1] = index end
  table.sort(indices)
  for _, index in ipairs(indices) do
    local block = blocks[index]
    if block.type == "tool_use" then
      local args = table.concat(block.args)
      local input = args ~= "" and json.try_decode(args) or {}
      if type(input) ~= "table" then input = { __invalid_json = args } end
      uses[#uses + 1] = { id = block.id, name = block.name, input = input }
    end
  end

  local stop = "end"
  if stop_reason == "refusal" then
    stop = "refusal"
  elseif stop_reason == "max_tokens" then
    stop = "max"
  elseif stop_reason == "tool_use" and #uses > 0 then
    stop = "tool"
  end
  return { text = table.concat(text_parts), tool_uses = uses, stop = stop }
end

function M.openai_chat(o)
  local messages = { { role = "system", content = o.system } }
  for _, m in ipairs(o.messages) do
    if m.role == "assistant" then
      local text, calls = {}, {}
      for _, part in ipairs(m.content) do
        if part.type == "text" then
          text[#text + 1] = part.text
        elseif part.type == "tool_use" then
          calls[#calls + 1] = {
            id = part.id,
            type = "function",
            ["function"] = {
              name = part.name,
              arguments = json.encode(next(part.input or {}) and part.input or EMPTY_OBJECT),
            },
          }
        end
      end
      local out = { role = "assistant", content = #text > 0 and table.concat(text) or nil }
      if #calls > 0 then out.tool_calls = calls end
      messages[#messages + 1] = out
    else
      for _, part in ipairs(m.content) do
        if part.type == "text" then
          messages[#messages + 1] = { role = "user", content = part.text }
        elseif part.type == "tool_result" then
          messages[#messages + 1] =
            { role = "tool", tool_call_id = part.tool_use_id, content = part.content }
        end
      end
    end
  end
  local tools = {}
  for i, tool in ipairs(o.tools) do
    tools[i] = {
      type = "function",
      ["function"] = {
        name = tool.name,
        description = tool.description,
        parameters = schema_of(tool),
      },
    }
  end

  local text_parts = {}
  -- Tool calls arrive as fragments addressed by index; the name and the
  -- arguments are both assembled a piece at a time.
  local calls, order = {}, {}
  local finish = nil

  local ok, err = run_stream(o, M.base_url(o.provider) .. "/chat/completions", {
    model = o.model,
    stream = true,
    messages = messages,
    tools = #tools > 0 and tools or nil,
  }, function(event)
    if event.data == "[DONE]" then return end
    local value = json.try_decode(event.data)
    if type(value) ~= "table" then return end
    local choice = (value.choices or {})[1]
    if not choice then return end
    local delta = choice.delta or {}
    if type(delta.content) == "string" and delta.content ~= "" then
      text_parts[#text_parts + 1] = delta.content
      if o.on_text then o.on_text(delta.content) end
    end
    for _, tc in ipairs(delta.tool_calls or {}) do
      local index = tc.index or 0
      local slot = calls[index]
      if not slot then
        slot = { id = "", name = "", args = {} }
        calls[index] = slot
        order[#order + 1] = index
      end
      if tc.id and tc.id ~= "" then slot.id = tc.id end
      local fn = tc["function"] or {}
      if fn.name then slot.name = slot.name .. fn.name end
      if fn.arguments then slot.args[#slot.args + 1] = fn.arguments end
    end
    if choice.finish_reason and choice.finish_reason ~= json.null then
      finish = choice.finish_reason
    end
  end)
  if not ok then return nil, err end

  table.sort(order)
  local uses = {}
  for _, index in ipairs(order) do
    local slot = calls[index]
    local args = table.concat(slot.args)
    local input = args ~= "" and json.try_decode(args) or {}
    if type(input) ~= "table" then input = { __invalid_json = args } end
    uses[#uses + 1] = {
      id = slot.id ~= "" and slot.id or ("call_%d"):format(#uses),
      name = slot.name,
      input = input,
    }
  end

  local stop = "end"
  if finish == "content_filter" then
    stop = "refusal"
  elseif finish == "length" then
    stop = "max"
  elseif #uses > 0 then
    stop = "tool"
  end
  return { text = table.concat(text_parts), tool_uses = uses, stop = stop }
end

-- ------------------------------------------------------------------ one-shots

--- A plain request and its whole body, yielding while it arrives.
local function fetch(o, url, method, body)
  local call, err = Http.start(o.wallet, o.lib, {
    url = url,
    method = method,
    headers = headers(o.provider, o.key),
    body = body and json.encode(body) or nil,
  })
  if not call then return nil, err end
  local text, status, failed = call:read(nil)
  call:close()
  if failed then return nil, failed end
  if not status or status >= 400 then return nil, refusal(status, text) end
  local value = json.try_decode(text)
  if type(value) ~= "table" then return nil, "the provider sent something that is not JSON" end
  return value
end

--- A picture, as base64 bytes the chatroom can keep. Returns `b64, mime`.
function M.image(o, prompt)
  local model = Prefs.IMAGE_MODEL[o.provider]
  if not model then return nil, o.provider .. " cannot make pictures" end
  local body = { model = model, prompt = prompt, n = 1 }
  -- gpt-image-1 always answers base64; xAI has to be asked.
  if o.provider == "grok" then body.response_format = "b64_json" end
  if o.provider == "openai" then body.size = "1024x1024" end
  local value, err = fetch(o, M.base_url(o.provider) .. "/images/generations", "POST", body)
  if not value then return nil, err end
  local first = (value.data or {})[1] or {}
  if type(first.b64_json) ~= "string" or first.b64_json == "" then
    return nil, "the provider sent no picture"
  end
  -- xAI says what it drew (`mime_type`, usually a JPEG); OpenAI's gpt-image-1
  -- is a PNG and says nothing.
  local mime = "image/png"
  if type(first.mime_type) == "string" and first.mime_type:match("^image/") then
    mime = first.mime_type
  end
  return first.b64_json, mime
end

--- Every model the key can see, sorted the way the panel wants to read it.
function M.models(o)
  local base = o.provider == "anthropic" and M.ANTHROPIC_URL or M.base_url(o.provider)
  local value, err = fetch(o, base .. "/models", "GET", nil)
  if not value then return nil, err end
  local ids = {}
  for _, entry in ipairs(value.data or value.models or {}) do
    local id = type(entry) == "table" and (entry.id or entry.name) or entry
    if type(id) == "string" then ids[#ids + 1] = id end
  end
  table.sort(ids)
  if o.provider == "openai" then
    -- OpenAI's list is everything they have ever shipped; only the chat
    -- models are any use here.
    local out = {}
    for _, id in ipairs(ids) do
      local chatty = id:match("^gpt%-") or id:match("^o%d")
      local other = id:match("audio") or id:match("realtime") or id:match("tts")
        or id:match("transcribe") or id:match("image") or id:match("embedding")
        or id:match("moderation") or id:match("search") or id:match("instruct")
      if chatty and not other then out[#out + 1] = id end
    end
    return out
  end
  if o.provider == "openrouter" then
    -- OpenRouter's is every model on the internet; the houses this game
    -- already knows come first, so the list has a top worth reading.
    local known, rest = {}, {}
    for _, id in ipairs(ids) do
      local skip = id:match("embedding") or id:match("tts") or id:match("whisper")
        or id:match("image")
      if not skip then
        local house = id:match("^([^/]+)/")
        local first = house == "openai" or house == "anthropic" or house == "x%-ai"
          or house == "x-ai" or house == "google" or house == "meta-llama" or house == "qwen"
          or house == "deepseek" or house == "mistralai"
        if first then known[#known + 1] = id else rest[#rest + 1] = id end
      end
    end
    local out = {}
    for _, id in ipairs(known) do out[#out + 1] = id end
    for _, id in ipairs(rest) do out[#out + 1] = id end
    return out
  end
  return ids
end

return M
