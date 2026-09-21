-- What the coder needs to remember about *you*: which provider, which key,
-- which model, and whether it may review on its own.
--
-- The web keeps all of this in `localStorage` under `cwbhacker.ai.*`
-- (`frontend/src/ai/prefs.ts`). The desktop client has no `localStorage`, and
-- it cannot use the one file it already has: `src/store.lua` is an event log
-- that **refuses** to persist any field whose name contains `key` or `secret`
-- (`Store.check_no_secrets`), and that guard is the whole reason the wallet is
-- safe here. So this is its own file, `agent.json`, beside the log in the same
-- `0700` directory and set `0600` the same way, holding the same names the
-- browser uses so `docs/agent.md`'s table is one table for both clients.
--
-- ## Why a provider key is allowed to be written down at all
--
-- SPEC §3.1's rule is about the *identity* — the mnemonic, the private key,
-- the thing that is you. A provider key is a spending limit: it is issued by
-- somebody else, revoked from a dashboard, and asking for it at every launch
-- is how people end up pasting it into a chat window instead. It never goes
-- to the game server; the only machine it is ever sent to is the provider
-- that issued it (docs/agent.md §1).
--
-- Nothing in this file touches `love.`: the headless suite drives it with a
-- directory of its own.

local json = require("src.json")
local Store = require("src.store")

local M = {}

M.PROVIDERS = { "anthropic", "openai", "grok", "openrouter", "ollama" }

--- Where Ollama listens unless told otherwise.
M.OLLAMA_DEFAULT_HOST = "http://localhost:11434"

--- The model each provider starts on. Editable; FETCH MODELS lists the rest.
M.DEFAULT_MODEL = {
  anthropic = "claude-opus-5",
  openai = "gpt-4.1",
  grok = "grok-4",
  -- OpenRouter names models as vendor/model; this one is on every plan.
  openrouter = "openai/gpt-4.1",
  -- A coding model small enough to run on a laptop. `ollama pull` it first.
  ollama = "qwen2.5-coder:7b",
}

--- The image model, where there is one. Anthropic, OpenRouter and Ollama have none.
M.IMAGE_MODEL = {
  openai = "gpt-image-1",
  -- The model `art/tools/grok_image.sh` draws this game's own art with.
  grok = "grok-imagine-image",
}

M.PROVIDER_NAME = {
  anthropic = "ANTHROPIC",
  openai = "OPENAI",
  grok = "GROK",
  openrouter = "OPENROUTER",
  ollama = "OLLAMA",
}

--- The companion sprite that flies beside the coder for each provider.
M.PROVIDER_BOT = {
  anthropic = "agent_bot_anthropic",
  openai = "agent_bot_openai",
  grok = "agent_bot_grok",
  -- Both speak OpenAI's dialect; both fly the green bot.
  openrouter = "agent_bot_openai",
  ollama = "agent_bot_openai",
}

M.FILE = "agent.json"

-- Everything the file holds, and the only copy the program works from.
local state = nil
local dir = nil
local secure = nil

local function blank()
  return { provider = "anthropic", keys = {}, models = {}, auto = false, shown = true,
    notes = true }
end

--- True when `name` is a provider this client knows.
function M.is_provider(name)
  for _, p in ipairs(M.PROVIDERS) do
    if p == name then return true end
  end
  return false
end

--- Whether the provider wants a key at all. Ollama is a program on your own
--- machine: what goes in its field is the host it listens on, and empty means
--- the default.
function M.needs_key(provider)
  return provider ~= "ollama"
end

--- Open the file. `opts.dir` overrides where it lives (the tests pass their
--- own); `opts.secure` is `wallet`'s `secure` op, so the file is `0600` for
--- the same reason the session token's is.
function M.open(opts)
  opts = opts or {}
  secure = opts.secure
  dir = opts.dir
  if dir == nil then dir = Store.directory() end
  state = blank()
  if not dir then return state end
  local fh = io.open(dir .. "/" .. M.FILE, "r")
  if not fh then return state end
  local text = fh:read("*a")
  fh:close()
  local value = json.try_decode(text or "")
  if type(value) == "table" then
    state.provider = M.is_provider(value.provider) and value.provider or state.provider
    state.keys = type(value.keys) == "table" and value.keys or {}
    state.models = type(value.models) == "table" and value.models or {}
    state.auto = value.auto and true or false
    state.shown = value.shown ~= false
    state.notes = value.notes ~= false
  end
  return state
end

--- The path being written, or nil when this run keeps nothing.
function M.path()
  return dir and (dir .. "/" .. M.FILE) or nil
end

local function save()
  if not state or not dir then return false end
  local path = dir .. "/" .. M.FILE
  local existed = io.open(path, "r")
  if existed then existed:close() end
  local fh, err = io.open(path, "w")
  if not fh then
    print("agent: cannot write " .. path .. ": " .. tostring(err))
    return false, tostring(err)
  end
  fh:write(json.encode(state) .. "\n")
  fh:close()
  -- A file holding somebody's provider key is nobody else's business, and
  -- `io.open` has no mode argument. The key library does the chmod, and
  -- without the library the store's `os.execute` fallback does — the same
  -- one the session token's file gets, for the same reason.
  if not existed then
    local ok = secure and pcall(secure, path, false)
    if not ok then pcall(Store.make_private, path, false) end
  end
  return true
end

M.save = save

local function ensure()
  if not state then M.open({ dir = false }) end
  return state
end

function M.provider()
  return ensure().provider
end

function M.set_provider(name)
  if not M.is_provider(name) then return false end
  ensure().provider = name
  return save()
end

--- The key as typed, trimmed. For Ollama this is the host instead.
function M.key(provider)
  local raw = ensure().keys[provider]
  return (type(raw) == "string" and raw or ""):match("^%s*(.-)%s*$")
end

function M.set_key(provider, value)
  ensure().keys[provider] = (value or ""):match("^%s*(.-)%s*$")
  return save()
end

--- Ollama's host: what was typed, or the default.
function M.ollama_host()
  local raw = M.key("ollama"):gsub("/+$", "")
  if raw == "" then return M.OLLAMA_DEFAULT_HOST end
  return raw
end

function M.model(provider)
  local raw = ensure().models[provider]
  raw = (type(raw) == "string" and raw or ""):match("^%s*(.-)%s*$")
  if raw ~= "" then return raw end
  return M.DEFAULT_MODEL[provider]
end

function M.set_model(provider, value)
  ensure().models[provider] = (value or ""):match("^%s*(.-)%s*$")
  return save()
end

--- Whether the coder may spend a call nobody asked for (docs/agent.md §1).
function M.auto()
  return ensure().auto
end

function M.set_auto(on)
  ensure().auto = on and true or false
  return save()
end

--- Whether the coder is on the screen at all: the sprite, its tips, its
--- effects. Off, the panel still opens and the verbs still work — it is the
--- character that is put away, not the help. On by default.
function M.shown()
  return ensure().shown
end

function M.set_shown(on)
  ensure().shown = on and true or false
  return save()
end

--- Whether an answer is also written into the file as a comment
--- (`src/agent/notes.lua`, the browser's `ai/notes.ts`). On by default: the
--- room scrolls, the file is kept, and the reply is about the code it lands
--- in.
function M.notes()
  return ensure().notes
end

function M.set_notes(on)
  ensure().notes = on and true or false
  return save()
end

--- A key's shape for the setup line: the first and last few characters.
function M.mask(key)
  if not key or key == "" then return "" end
  if #key <= 10 then return ("•"):rep(#key) end
  return key:sub(1, 6) .. "…" .. key:sub(-4)
end

--- Forget everything, for a test that wants a fresh one.
function M.reset()
  state = nil
  dir = nil
  secure = nil
end

return M
