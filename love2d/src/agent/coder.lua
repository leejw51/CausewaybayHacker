-- The Rust coder: the character, the bench it works at, and the room it talks in.
--
-- The LÖVE half of `frontend/src/ui/agent/coder.ts`. Everything the browser's
-- one does, in the same order and with the same rules:
--
--   * the sprite flies over the code (`sprite.lua`) and says things in a
--     bubble — tips and advice that cost nothing, read out of the text on the
--     screen (`tips.lua`);
--   * the panel (`panel.lua`) is the room, and the verbs are the only things
--     that spend a call, with AUTO the single opt-in exception;
--   * an ask runs the whole tool loop here on this machine (`session.lua`),
--     and every character the model writes is typed into the editor at a
--     human speed (`typist.lua`) while the person watches;
--   * the conversation is kept by the server, one room per scratchpad, and
--     folded by id so two clients see the same room (`sync.lua`).
--
-- ## Agent mode
--
-- The character is on the screen only while the panel is open. It arrives on
-- an entrance — huge, shrinking to size on an ease-out — and fades out when
-- the panel closes; a touch on it stops it dead still so its bubble can be
-- read, and a touch anywhere else lets it go. None of that is decoration: a
-- sprite that flies over the code you are reading, at speed, with no way to
-- catch it, is a thing you would turn off.
--
-- ## Where the key goes
--
-- Nowhere but the provider. The game server is storage; it never sees a
-- provider key, and the only calls it gets from here are the room's own
-- (`playground.chat.*`) and the bench's RUN.

local Theme = require("src.theme")
local Assets = require("src.assets")
local Wallet = require("src.wallet")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Ease = require("src.ease")
local Layout = require("src.layout")

local Prefs = require("src.agent.prefs")
local Notes = require("src.agent.notes")
local SpriteM = require("src.agent.sprite")
local PanelM = require("src.agent.panel")
local SessionM = require("src.agent.session")
local Typist = require("src.agent.typist")
local Tips = require("src.agent.tips")
local Providers = require("src.agent.providers")
local Sync = require("src.agent.sync")

local M = {}

--- How long a bubble stays, plus a share per character.
local BUBBLE_BASE = 4.5
local BUBBLE_PER_CHAR = 0.045
--- A tip, now and then, while nobody is mid-thought.
local TIP_EVERY = { 28, 55 }
--- How long the text must sit still before the advice reads it.
local ADVISE_AFTER = 2.5
--- AUTO: idle seconds before a review may fire, and the floor between two.
local AUTO_IDLE = 25
local AUTO_EVERY = 240
--- AUTO: how much the text must have changed since the last review.
local AUTO_DELTA = 40
--- How long a mouse that has stopped still counts as reaching for the sprite.
local CALM_FOR = 1.4
--- The sprite's drawn size in virtual pixels.
local SIZE = 64

local Coder = {}
Coder.__index = Coder

--- `host` is the screen: `lang()`, `room_id()`, `ensure_room()`, `room_name()`,
--- `run` (or nil), `format` (or nil), `touched()`, `fx()`, `request(type,
--- payload, cb)`, and `wallet`/`lib` for the network.
function M.new(app, host)
  local coder = setmetatable({
    app = app,
    host = host,
    t = 0,
    sprite = SpriteM.new(SIZE, function()
      -- The client has no reduced-motion setting of its own; the sprite's
      -- switch is the CODER toggle, and off means gone rather than still.
      return false
    end),
    typist = Typist.new(),
    editor = nil,
    session = nil,
    box = { 0, 0, Theme.landW, Theme.landH },
    bubble = nil,
    last_said = nil,
    presence = 0,
    was_active = false,
    pointer_at = -1000,
    mood = "idle",
    mood_since = 0,
    since_tip = 0,
    since_call = 0,
    since_change = 0,
    advised = false,
    said = {},
    last_tip = 0,
    next_tip_at = TIP_EVERY[1],
    last_source = "",
    reviewed_source = "",
    room = Sync.empty_room(),
    room_id = nil,
    -- The pad as last seen, `{ key, id }`, for `Sync.room_move`.
    pad = nil,
    rings = {},
    live = nil,
    pending_run = nil,
  }, Coder)
  coder.panel = PanelM.new({
    send = function(text) coder:ask(text) end,
    write = function(brief) coder:write(brief) end,
    review = function() coder:review() end,
    image = function(brief) coder:picture(brief) end,
    stop = function() coder:stop() end,
    clear = function() coder:clear_room() end,
    erase = function(id) coder:erase(id) end,
    amend = function(id, text) coder:amend(id, text) end,
    fetch_models = function() coder:fetch_models() end,
    note = function(text) coder:say(text, "say") end,
  })
  return coder
end

-- ----------------------------------------------------------------- lifecycle

--- After the screen has made its editor. Safe to call again with a new one.
function Coder:mount(editor)
  self.editor = editor
  self.last_source = editor and editor:text() or ""
  self.session = SessionM.new(self:bench(), self:listener(), Wallet, self.app.wallet_lib)
  self:sync_room()
end

function Coder:leave()
  self:stop()
  -- A stop is noticed at the coroutine's next wait, so the ask has to be
  -- given the frames to notice it in. Without them the request is left
  -- streaming into a buffer nobody will ever read, and its handle is never
  -- closed — the thread is the key library's, and it outlives this screen.
  if self.session then
    for _ = 1, 4 do
      if not self.session:busy() then break end
      self.session:update()
    end
  end
  self.editor = nil
  self.session = nil
end

function Coder:toggle()
  self.panel.open = not self.panel.open
  if self.panel.open then self:sync_room() end
  SFX.play("select")
end

--- ASK: the room, open on CHAT with the caret already in the field.
---
--- The browser's `Coder.openAsk`. On a graded screen the press means "I have
--- a question", not "show me the panel", so it lands where the question is
--- typed rather than wherever the panel was left.
function Coder:open_ask()
  self.panel.open = true
  self.panel.view = "chat"
  self.panel.focus = "input"
  self:sync_room()
  SFX.play("select")
end

--- Agent mode: the sprite lives only while the panel is open.
function Coder:active()
  return Prefs.shown() and self.panel.open
end

-- --------------------------------------------------------------------- bench

--- Turn a byte offset in the whole text into the editor's line and column.
local function place_of(text, offset)
  local line, last = 1, 0
  for at in text:sub(1, offset):gmatch("()\n") do
    line = line + 1
    last = at
  end
  return line, offset - last
end

--- Type `text` into the editor at the caret, a character at a time, giving
--- the screen a frame between each. Runs inside the session's coroutine.
function Coder:type_out(text)
  local editor = self.editor
  if not editor then return { typed = 0, total = #text, stopped = true } end
  self.sprite:typing(true)
  self.sprite:roll()
  local fx = self.host.fx and self.host.fx()
  if fx then fx:burst(self.sprite.x, self.sprite.y, 40) end
  local typist = self.typist
  local struck = 0
  typist:run(text, {
    type = function(ch)
      editor:insert(ch, true)
    end,
  }, function()
    struck = struck + 1
    self.host.touched()
    self.sprite:kick()
    -- A key tick every few characters: heard as typing, not as a machine gun.
    if struck % 4 == 1 then SFX.play("type") end
  end)
  while typist:busy() do
    coroutine.yield()
  end
  self.sprite:typing(false)
  local stopped = typist.typed < typist.total
  return { typed = typist.typed, total = #text, stopped = stopped }
end

function Coder:bench()
  local coder = self
  return {
    lang = self.host.lang(),
    file = "main." .. (self.host.lang() == "cpp" and "cpp" or self.host.lang() == "go" and "go"
      or self.host.lang() == "python" and "py" or self.host.lang() == "pytorch" and "py"
      or self.host.lang() == "typescript" and "ts" or "rs"),
    read = function()
      return coder.editor and coder.editor:text() or ""
    end,
    write = function(source)
      if not coder.editor then return { typed = 0, total = #source, stopped = true } end
      coder.editor:select_all()
      coder.editor:delete_selection()
      return coder:type_out(source)
    end,
    insert = function(text)
      return coder:type_out(text)
    end,
    edit = function(find, replace)
      local text = coder.editor and coder.editor:text() or ""
      local at = text:find(find, 1, true)
      if not at then return { ok = false, why = "That text is not in the file." } end
      if text:find(find, at + 1, true) then
        return { ok = false, why = "That text appears more than once; give a longer span." }
      end
      -- Put the caret at the span, take the span out, and type the new text
      -- in its place — so an edit is watched exactly like a write.
      local line, col = place_of(text, at - 1)
      coder.editor:goto_position(line, col, false)
      local last_line, last_col = place_of(text, at - 1 + #find)
      coder.editor:goto_position(last_line, last_col, true)
      coder.editor:delete_selection()
      local r = coder:type_out(replace)
      return { ok = not r.stopped, why = r.stopped and "Stopped by the person." or nil }
    end,
    -- Asked here rather than copied, so the exercise the prompt carries is
    -- the one on screen — the last RUN in it changes while the panel is open.
    task = coder.host.task and function() return coder.host.task() end or nil,
    run = coder.host.run and function(stdin)
      return coder:await_run(stdin)
    end or nil,
    format = coder.host.format and function()
      return coder:await_format()
    end or nil,
    search = coder.host.request and function(q)
      return coder:await_search(q)
    end or nil,
    -- A picture needs somewhere to go as well as somebody to draw it: the
    -- room is the pad's, and a graded screen has none. Asked here, not at
    -- mount, because both halves change while the screen is open.
    image = (Prefs.IMAGE_MODEL[Prefs.provider()] ~= nil
      and coder.host.room_id ~= nil and coder.host.room_id() ~= nil)
      and function(prompt) return coder:make_image(prompt) end or nil,
  }
end

--- Ask the screen to RUN, and wait for the answer without blocking a frame.
function Coder:await_run(stdin)
  local out = nil
  self.host.run(stdin, function(report)
    out = report or { outcome = "error", stdout = "", stderr = "", compile_ms = 0, run_ms = 0 }
  end)
  while out == nil do
    coroutine.yield()
  end
  return out
end

function Coder:await_format()
  local out = nil
  self.host.format(function(report)
    out = report or { changed = false, problem = "the formatter did not answer" }
  end)
  while out == nil do
    coroutine.yield()
  end
  return out
end

function Coder:await_search(q)
  local out = nil
  self.host.request("playground.chat.search", { q = q, mode = "unified", limit = 8 },
    function(ok, payload, why)
      if not ok then
        out = "The search failed: " .. ((why and why.player) or "no reason given")
        return
      end
      local hits = payload.hits or {}
      if #hits == 0 then
        out = "No notes match."
        return
      end
      local lines = {}
      for _, hit in ipairs(hits) do
        lines[#lines + 1] = ("%s: %s"):format(hit.role or "note", (hit.text or ""):sub(1, 200))
      end
      out = table.concat(lines, "\n")
    end)
  while out == nil do
    coroutine.yield()
  end
  return out
end

--- Make a picture and post it in the room. The provider draws it; the game
--- server only keeps it.
function Coder:make_image(prompt)
  local provider = Prefs.provider()
  local b64, mime = Providers.image({
    wallet = Wallet,
    lib = self.app.wallet_lib,
    provider = provider,
    key = Prefs.key(provider),
  }, prompt)
  if not b64 then return "The picture could not be made: " .. tostring(mime) end
  local id = self.room_id
  if not id then return "There is no room to put a picture in." end
  local posted = nil
  self.host.request("playground.chat.post", {
    id = id,
    role = "agent",
    text = prompt,
    image_b64 = b64,
    image_type = mime,
    provider = provider,
    model = Prefs.IMAGE_MODEL[provider],
  }, function(ok, payload, why)
    posted = ok and payload.message or { failed = (why and why.player) or "refused" }
  end)
  while posted == nil do
    coroutine.yield()
  end
  if posted.failed then return "The picture could not be kept: " .. posted.failed end
  self:fold_one(posted)
  return "Made the picture and put it in the room."
end

-- ------------------------------------------------------------------ the room

--- A different pad is a different room: forget this one and read that one.
function Coder:sync_room()
  local id = self.host.room_id and self.host.room_id() or nil
  self.room_id = id
  self.room = Sync.empty_room()
  self.panel:clear_items()
  -- **Lines held for the pad we are leaving do not follow us.** They were
  -- said in that room, and flushing them when the *next* pad gets an id
  -- would put somebody's words in a conversation they were not part of.
  self.pending = nil
  self.saving = false
  self.save_tries = nil
  self.said_unsaved = nil
  self:list_room()
end

--- Read the room from the server, keeping whatever is on the screen already:
--- `Panel:apply` merges rather than replaces, so a line still in flight does
--- not blink out when the list lands.
function Coder:list_room()
  local id = self.room_id
  if not id or not self.host.request then return end
  self.host.request("playground.chat.list", { id = id, limit = 200 }, function(ok, payload)
    if not ok then return end
    self.room = Sync.fold(self.room, payload.messages or {})
    self:show_room()
  end)
end

--- A pad that had no id has one: the save has landed. Keep what is on the
--- screen, post what was said before there was anywhere to post it, and read
--- whatever the server already had.
function Coder:room_arrived(id)
  self.room_id = id
  self.saving = false
  self.save_tries = nil
  self.said_unsaved = nil
  local held = self.pending or {}
  self.pending = nil
  for _, line in ipairs(held) do
    self:post(id, line.role, line.text)
  end
  self:list_room()
end

--- The room changed on another of this user's connections (§4.23): one row
--- as the server recorded it — a post, an edit, a tombstone — or the room
--- cleared. Folded by id like a page of the list; nothing is asked back.
function Coder:room_updated(id, message, cleared)
  if id == nil or id ~= self.room_id then return end
  if cleared then
    self.panel:clear_items()
    self.room = Sync.empty_room()
    self.pending = nil
    if self.session then self.session:clear() end
  elseif message then
    self:fold_one(message)
  else
    return
  end
  self.panel.status = I18n.t("the room changed on another device")
  SFX.play("select")
end

function Coder:fold_one(message)
  self.room = Sync.fold(self.room, { message })
  self:show_room()
end

function Coder:show_room()
  local items = {}
  for _, message in ipairs(self.room.messages or {}) do
    items[#items + 1] = {
      id = message.id,
      role = message.role == "user" and "you" or message.role,
      text = message.text or "",
      photo_url = message.photo_url,
      edited = message.edited,
    }
  end
  self.panel:apply(items)
end

--- Keep one line.
---
--- A pad that has never been saved has no id, and a room belongs to an id. So
--- the first thing said in a fresh pad asks the screen to save it and **holds
--- the line** until the save comes back — saving is a round trip, and reading
--- the id on the next line got nil and dropped the message on the floor while
--- the panel went on showing it.
function Coder:keep(role, text)
  local id = self.room_id
  if not id then
    self.pending = self.pending or {}
    self.pending[#self.pending + 1] = { role = role, text = text }
    if self.host.ensure_room and not self.saving then
      self.saving = true
      local made = self.host.ensure_room()
      if made and self.host.room_name then
        self.panel.status = I18n.t("saved as %s"):format(self.host.room_name())
      end
    end
    return
  end
  self:post(id, role, text)
end

function Coder:post(id, role, text)
  if not self.host.request then return end
  local provider = Prefs.provider()
  self.host.request("playground.chat.post", {
    id = id,
    role = role,
    text = text,
    provider = provider,
    model = Prefs.model(provider),
  }, function(ok, payload)
    if ok and payload.message then self:fold_one(payload.message) end
  end)
end

function Coder:clear_room()
  local id = self.room_id
  self.panel:clear_items()
  self.room = Sync.empty_room()
  self.pending = nil
  if self.session then self.session:clear() end
  if not id or not self.host.request then return end
  self.host.request("playground.chat.clear", { id = id }, function() end)
end

function Coder:erase(message_id)
  self.host.request("playground.chat.delete", { message_id = message_id }, function(ok, payload)
    if ok and payload.message then self:fold_one(payload.message) end
  end)
end

function Coder:amend(message_id, text)
  self.host.request("playground.chat.edit", { message_id = message_id, text = text },
    function(ok, payload)
      if ok and payload.message then self:fold_one(payload.message) end
    end)
end

-- ------------------------------------------------------------------ the asks

function Coder:listener()
  local coder = self
  return {
    text = function(delta)
      if not coder.live then
        coder.live = coder.panel:push({ role = "agent", text = "", live = true })
      end
      coder.live.text = coder.live.text .. delta
      coder.panel.scroll = 0
      -- Spoken as it arrives, not once it is finished: the wait for a model
      -- is the weakest moment on the screen, and words landing one by one are
      -- the sign of life. The bubble keeps the tail.
      coder:say(coder.live.text, "say", true)
    end,
    tool = function(name, input)
      local note = type(input) == "table" and type(input.note) == "string" and input.note or nil
      local label = note or name
      coder.panel:push({ role = "tool", text = label })
      coder:say(label, "busy")
    end,
    tool_done = function(name, text, failed)
      local first = text:match("^[^\n]*") or ""
      coder.panel:push({ role = failed and "error" or "tool", text = first })
      if failed then SFX.play("deny") end
    end,
    mood = function(mood)
      coder.mood = mood
      coder.mood_since = coder.t
      coder.sprite:thinking(mood == "thinking" or mood == "running")
      if mood == "idle" and coder.live then
        -- The streamed line is now a kept one.
        coder.live.live = nil
        coder:keep("agent", coder.live.text)
        coder:note_in_code(coder.live.text)
        coder.live = nil
      end
    end,
  }
end

--- The answer, written into the file as a comment above the caret's line.
---
--- The browser's `Coder.noteInCode`. The bubble fades and the room scrolls;
--- the file is what gets saved, and the question was about the line the
--- person was looking at. Not while the typist is working — the model may
--- have just written a program and its last characters may still be arriving
--- — and not when the switch in SETUP is off.
function Coder:note_in_code(reply)
  if not Prefs.notes() or self.typist:busy() then return end
  if not self.editor then return end
  local lines = Notes.comment_lines(reply, self.host.lang())
  if #lines == 0 then return end
  self.editor:note_above(lines)
  if self.host.touched then self.host.touched() end
  SFX.play("select")
end

--- The one place an ask starts. Everything else — WRITE, REVIEW — is this
--- with a different first sentence.
function Coder:ask(text, opts)
  opts = opts or {}
  if not self.session then return end
  -- The bench as it is *now*. A pad that has since been saved has a room to
  -- put a picture in, and TAB changes both the language the prompt names and
  -- the file it says it is editing.
  self.session.bench = self:bench()
  if self.session:busy() then
    self.panel.status = I18n.t("still working — press STOP first")
    return
  end
  local provider = Prefs.provider()
  if Prefs.key(provider) == "" and Prefs.needs_key(provider) then
    self.panel.view = "setup"
    self.panel.focus = "key"
    self.panel.status = I18n.t("no key yet — press here and paste")
    return
  end
  if not opts.quiet then
    self.panel:push({ role = "you", text = text })
    self:keep("user", text)
  end
  self.since_call = 0
  self.panel.status = nil
  self.session:ask(provider, text, function(_, err)
    if err then
      self.panel:push({ role = "error", text = err })
      self.panel.status = err
      self:say(err, "busy")
      SFX.play("deny")
    end
  end)
end

function Coder:write(brief)
  self:ask(("WRITE: %s"):format(brief))
end

function Coder:review()
  self.reviewed_source = self.editor and self.editor:text() or ""
  self:ask(I18n.t("Review this program. Be concrete and brief."))
end

function Coder:picture(brief)
  self:ask(("IMAGE: %s"):format(brief))
end

function Coder:stop()
  if self.session then self.session:stop() end
  self.typist:stop()
  self.sprite:typing(false)
  self:say(I18n.t("stopped"), "busy")
end

--- SETUP's MODELS button: ask the provider what it has.
function Coder:fetch_models()
  local provider = Prefs.provider()
  if Prefs.key(provider) == "" and Prefs.needs_key(provider) then
    self.panel.status = I18n.t("no key yet — press here and paste")
    return
  end
  self.panel.status = I18n.t("asking…")
  local coder = self
  self.models_co = coroutine.create(function()
    local list, err = Providers.models({
      wallet = Wallet,
      lib = coder.app.wallet_lib,
      provider = provider,
      key = Prefs.key(provider),
    })
    if not list then
      coder.panel.status = tostring(err)
      return
    end
    coder.panel.models = list
    coder.panel.status = I18n.t("%d models"):format(#list)
  end)
end

-- ------------------------------------------------------------------ the life

function Coder:say(text, tone, streaming)
  local clean = (text or ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if clean == "" then return end
  -- A reply still arriving shows its newest words; the whole of it is in the
  -- room, and a bubble that grows past four lines only hides code.
  local shown = clean
  if streaming and #clean > 160 then shown = "…" .. clean:sub(-158) end
  if tone ~= "busy" then self.last_said = { text = shown, tone = tone } end
  self.bubble = {
    text = shown,
    tone = tone,
    until_t = self.t + BUBBLE_BASE + math.min(9, #shown * BUBBLE_PER_CHAR),
  }
end

function Coder:update(dt)
  self.t = self.t + dt
  self.since_tip = self.since_tip + dt
  self.since_call = self.since_call + dt
  if self.session then self.session:update() end
  if self.models_co and coroutine.status(self.models_co) ~= "dead" then
    local ok, err = coroutine.resume(self.models_co)
    if not ok then
      self.panel.status = tostring(err)
      self.models_co = nil
    end
  elseif self.models_co then
    self.models_co = nil
  end
  self.typist:update(dt)

  -- Only in agent mode. Put away, or the panel closed: no flying, no tips, no
  -- advice, no effects — and the AUTO review is silenced with it, because a
  -- character that is off should not spend.
  -- The pad under this screen can change while it is open — another pad
  -- opened from the list, a new one made, or this one saved for the first
  -- time — and the room has to follow it.
  local id = self.host.room_id and self.host.room_id() or nil
  local key = self.host.room_key and self.host.room_key() or nil
  local move = Sync.room_move(self.pad, { key = key, id = id })
  if move ~= "same" then
    self.pad = { key = key, id = id }
    if move == "arriving" then
      self:room_arrived(id)
    else
      self:sync_room()
    end
  elseif self.pending and not id then
    -- Lines held for a pad that is still being saved. A save can be refused —
    -- the server rate-limits them, and a player at the snippet limit cannot
    -- make another pad at all — so this asks again now and then, and then
    -- **stops asking and says so**. A queue that grew forever behind a
    -- refusal nobody could see is how this was found.
    self.since_save = (self.since_save or 0) + dt
    if self.since_save >= 4 and (self.save_tries or 0) < 3 then
      self.since_save = 0
      self.save_tries = (self.save_tries or 0) + 1
      self.saving = false
      if self.host.ensure_room then
        self.saving = true
        self.host.ensure_room()
      end
    elseif (self.save_tries or 0) >= 3 and not self.said_unsaved then
      self.said_unsaved = true
      self.panel.status = I18n.t("this pad could not be saved, so the room is this screen only")
    end
  end

  local active = self:active()
  if active and not self.was_active then self.sprite:enter() end
  self.was_active = active
  local rate = active and 7 or 4
  self.presence = self.presence + ((active and 1 or 0) - self.presence) * (1 - math.exp(-rate * dt))
  if self.presence < 0.002 then self.presence = 0 end
  if not active then
    self.bubble = nil
    if self.sprite:holding() then self.sprite:hold(false) end
    return
  end
  self.sprite:calm(self.t - self.pointer_at < CALM_FOR)

  local source = self.editor and self.editor:text() or ""
  if source ~= self.last_source then
    self.last_source = source
    self.since_change = 0
    self.advised = false
  else
    self.since_change = self.since_change + dt
  end

  local busy = self.mood ~= "idle" or self.typist:busy()
  -- Held for a reader: no tips or advice over the words being read.
  if not busy and not self.sprite:holding() then
    if not self.advised and self.since_change >= ADVISE_AFTER and source:match("%S") then
      self.advised = true
      for _, finding in ipairs(Tips.advise(self.host.lang(), source)) do
        if not self.said[finding.id] then
          self.said[finding.id] = true
          self.sprite:peek()
          self:say(finding.text, "tip")
          self.since_tip = 0
          break
        end
      end
    end
    if self.since_tip >= self.next_tip_at and self.since_change >= 6 then
      self.since_tip = 0
      self.next_tip_at = TIP_EVERY[1] + math.random() * (TIP_EVERY[2] - TIP_EVERY[1])
      local lang = self.host.lang()
      self.last_tip = Tips.next_tip(lang, self.last_tip)
      if math.random() < 0.5 then self.sprite:peek() end
      self:say(Tips.TIPS[lang][self.last_tip], "tip")
    end
    -- AUTO: the one call nobody pressed for, throttled three ways.
    if Prefs.auto()
      and Prefs.key(Prefs.provider()) ~= ""
      and self.since_change >= AUTO_IDLE
      and self.since_call >= AUTO_EVERY
      and math.abs(#source - #self.reviewed_source) >= AUTO_DELTA
      and source:match("%S")
    then
      self:review()
    end
  end

  if self.mood == "thinking" or self.mood == "running" then
    self.bubble = {
      text = I18n.t("thinking… %ds"):format(math.floor(self.t - self.mood_since)),
      tone = "busy",
      until_t = self.t + 1,
    }
  elseif self.typist:busy() then
    -- **The count goes in the room, not over the code.** A bubble saying how
    -- far along the typing is, drawn across the program being typed, covers
    -- the one thing somebody is watching. The panel's status line is in
    -- nobody's way and says the same thing.
    self.panel.status = I18n.t("typing %d / %d"):format(self.typist.typed, self.typist.total)
    self.typing_said = true
    if self.bubble and self.bubble.tone == "busy" then self.bubble = nil end
  elseif self.typing_said then
    self.typing_said = nil
    self.panel.status = nil
  end
  -- A bubble stays as long as the sprite is held for it.
  if self.bubble and self.t > self.bubble.until_t and not self.sprite:holding() then
    self.bubble = nil
  end

  -- The caret, for peek and typing: the screen knows where it drew it.
  if self.host.caret then
    local cx, cy, cw = self.host.caret()
    if cx then
      self.sprite.caret = { cx, cy }
      if cw and cw > 0 then self.cell = cw end
    end
  end
  self.sprite:update(dt, self.box, self.cell or 8)
end

--- Where the sprite may fly. The whole screen, minus whatever the panel took.
function Coder:fly(box, panel_rect)
  if not panel_rect or not self.panel.open then
    self.box = box
    return
  end
  local x, y, w, h = box[1], box[2], box[3], box[4]
  local p = panel_rect
  -- Which side the panel is on, by the **edge it is flush with** rather than
  -- by where its left edge happens to fall. A room that takes a little over
  -- half the window is still a column on the right, and asking whether its
  -- left edge is past the middle said it was a band across the foot — which
  -- left the coder flying in the strip above it with its bubble hanging down
  -- over the conversation it had just had.
  local margin = 8
  local full_width = p.w >= w * 0.9
  local at_right = not full_width and (x + w) - (p.x + p.w) <= margin
  local at_left = not full_width and p.x - x <= margin
  if at_right then
    self.box = { x, y, math.max(160, p.x - x), h }
  elseif at_left then
    self.box = { p.x + p.w, y, math.max(160, x + w - p.x - p.w), h }
  else
    self.box = { x, y, w, math.max(120, p.y - y) }
  end
end

-- ------------------------------------------------------------------ drawing

--- Paint the sprite, its ribbon and its bubble. Called **last** by the scene,
--- after every pane and the panel: LÖVE has no z-index, and the coder is on
--- top of the interface by being drawn after it.
function Coder:draw()
  if self.presence <= 0 then return end
  local alpha = self.presence
  local x = self.sprite.x
  local y = self.sprite.y + self.sprite:bob()
  local size = self.sprite.size
  local zoom = self.sprite.scale
  local sqx, sqy = self.sprite:squash()

  self:draw_ribbon(alpha, size, x)

  -- The afterimages: where it has just been, fading back along the trail.
  local ship = Assets.image("agent_coder")
  if ship then
    for i, point in ipairs(self.sprite.trail) do
      local k = i / (#self.sprite.trail + 1)
      love.graphics.setColor(1, 1, 1, 0.28 * k * alpha)
      love.graphics.push()
      love.graphics.translate(point[1], point[2])
      love.graphics.rotate(self.sprite:angle() * k)
      love.graphics.scale(self.sprite.facing * zoom * k, zoom * k)
      love.graphics.draw(ship, -size / 2, -size / 2, 0, size / ship:getWidth(),
        size / ship:getHeight())
      love.graphics.pop()
    end
  end

  -- The engine, under the ship: three flames, the middle one longest,
  -- flickering with the clock, drawn in the ship's own frame so they tilt
  -- and zoom with it.
  love.graphics.push()
  love.graphics.translate(x, y)
  love.graphics.rotate(self.sprite:angle())
  love.graphics.scale(zoom * sqx, zoom * sqy)
  local burn = self.sprite:thrust()
  local flick = 0.75 + 0.25 * math.sin(self.t * 37) * math.cos(self.t * 23)
  local fw = math.max(2, math.floor(size * 0.06))
  for _, flame in ipairs({ { -0.28, 0.6 }, { 0, 1 }, { 0.28, 0.6 } }) do
    local fh = size * 0.22 * burn * flame[2] * flick
    local fx = flame[1] * size - fw / 2
    local fy = size * 0.42
    UI.setColor(Theme.cyan, 0.85 * alpha)
    love.graphics.rectangle("fill", fx, fy, fw, fh)
    UI.setColor(Theme.cream, 0.9 * alpha)
    love.graphics.rectangle("fill", fx + fw * 0.25, fy, fw * 0.5, fh * 0.55)
  end
  love.graphics.setColor(1, 1, 1, alpha)
  if ship then
    love.graphics.draw(ship, -size / 2, -size / 2, 0, size / ship:getWidth(),
      size / ship:getHeight())
  else
    UI.setColor(Theme.coin, 0.9 * alpha)
    love.graphics.rectangle("fill", -size / 2, -size / 2, size, size)
  end
  love.graphics.pop()
  love.graphics.setColor(1, 1, 1, 1)

  -- The companion: half a ship, trailing behind, on a slower bob.
  local bot = Assets.image(Prefs.PROVIDER_BOT[Prefs.provider()] or "")
  if bot then
    local bs = size * 0.5
    local bx = x - self.sprite.facing * size * 0.72
    local by = y - size * 0.12 + math.sin(self.t * 2.3) * 2.5
    love.graphics.setColor(1, 1, 1, alpha)
    love.graphics.draw(bot, bx - bs / 2, by - bs / 2, 0, bs / bot:getWidth(), bs / bot:getHeight())
    love.graphics.setColor(1, 1, 1, 1)
  end

  if self.bubble then self:draw_bubble(x, y, size, alpha) end
end

--- The light ribbon: where it has flown in the last second, as one stroke in
--- three layers — a wide glow, a body shading pink to cyan, a white core —
--- tapering and fading with age, with sparks winking along it.
function Coder:draw_ribbon(alpha, size, head_x)
  local wake = self.sprite.wake
  if #wake < 2 then return end
  local points = {}
  for i, p in ipairs(wake) do
    points[i] = { x = p.x, y = p.y, age = p.age }
  end
  points[#points + 1] = { x = head_x, y = self.sprite.y, age = 0 }
  local n = #points - 1

  local function blend(k)
    return {
      Theme.pink[1] + (Theme.cyan[1] - Theme.pink[1]) * k,
      Theme.pink[2] + (Theme.cyan[2] - Theme.pink[2]) * k,
      Theme.pink[3] + (Theme.cyan[3] - Theme.pink[3]) * k,
    }
  end
  local function pass(width, a, colour_of, additive)
    love.graphics.setBlendMode(additive and "add" or "alpha")
    for i = 2, n + 1 do
      local p = points[i]
      local k = (i - 1) / n
      local life = 1 - math.min(1, p.age / SpriteM.WAKE_SECS)
      local this = a * k * life * alpha
      if this > 0.01 then
        local colour = colour_of(k)
        love.graphics.setColor(colour[1], colour[2], colour[3], this)
        love.graphics.setLineWidth(math.max(1, width * (0.25 + 0.75 * k) * life))
        love.graphics.line(points[i - 1].x, points[i - 1].y, p.x, p.y)
      end
    end
  end
  pass(size * 1.1, 0.16, blend, true)
  pass(size * 0.42, 0.55, blend, false)
  pass(size * 0.12, 0.9, function() return Theme.cream end, false)

  -- Sparks: a diamond every few points, each winking on its own clock.
  love.graphics.setBlendMode("add")
  for i = 3, n, 3 do
    local p = points[i]
    local k = (i - 1) / n
    local life = 1 - math.min(1, p.age / SpriteM.WAKE_SECS)
    local wink = 0.5 + 0.5 * math.sin(self.t * 14 + i * 1.7)
    local r = math.max(1.5, size * 0.11 * k * life) * (0.6 + 0.4 * wink)
    local colour = i % 2 == 1 and Theme.cream or blend(k)
    love.graphics.setColor(colour[1], colour[2], colour[3], 0.9 * life * wink * alpha)
    love.graphics.polygon("fill", p.x, p.y - r, p.x + r, p.y, p.x, p.y + r, p.x - r, p.y)
  end
  love.graphics.setBlendMode("alpha")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setLineWidth(1)
end

function Coder:draw_bubble(x, y, size, alpha)
  local bubble = self.bubble
  local width = math.min(300, math.max(140, self.box[3] - 24))
  local lines = UI.wrap(bubble.text, width - 16, 7)
  if #lines > 4 then
    lines = { lines[1], lines[2], lines[3], lines[4] .. "…" }
  end
  local line_h = UI.lineHeight(7) + 1
  local h = #lines * line_h + 10
  local w = 16
  for _, line in ipairs(lines) do
    w = math.max(w, UI.textWidth(line, 7) + 16)
  end
  -- Above the sprite when there is room, else below; and off the line the
  -- caret is on, because a bubble over the line being written is the one
  -- place it must not be.
  local above_y = y - size * 0.6 - h - 4
  local below_y = y + size * 0.6 + 4
  local caret = self.sprite.caret
  local row = (self.cell or 8) * 1.6
  local function clears(top)
    return not caret or top + h < caret[2] - row or top > caret[2] + row
  end
  local fits_above = above_y >= self.box[2]
  local fits_below = below_y + h <= self.box[2] + self.box[4]
  local above = fits_above
  if fits_above and fits_below then
    if not clears(above_y) and clears(below_y) then above = false end
  elseif not fits_above and fits_below then
    above = false
  end
  local by = above and above_y or below_y
  local bx = math.min(self.box[1] + self.box[3] - w - 4, math.max(self.box[1] + 4, x - w / 2))

  local face = Theme.cream
  if bubble.tone == "tip" then
    face = Theme.panel
  elseif bubble.tone == "busy" then
    face = Theme.navy
  end
  UI.setColor(face, alpha)
  love.graphics.rectangle("fill", bx, by, w, h)
  UI.setColor(Theme.ink, alpha)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", bx + 1, by + 1, w - 2, h - 2)
  local ink = bubble.tone == "busy" and Theme.cream or Theme.ink
  local ly = by + 5
  for _, line in ipairs(lines) do
    UI.text(line, bx + 8, ly, 7, Theme.withAlpha(ink, alpha))
    ly = ly + line_h
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setLineWidth(1)
end

--- The panel, drawn by the scene wherever it decided to put it.
function Coder:draw_panel(rect)
  if not self.panel.open then return end
  self.panel:draw(rect, {
    busy = self.mood ~= "idle" or self.typist:busy(),
    can_image = Prefs.IMAGE_MODEL[Prefs.provider()] ~= nil and self.room_id ~= nil,
  })
end

-- -------------------------------------------------------------------- input

--- Whether a point is on the sprite.
function Coder:hits(x, y)
  if self.presence < 0.5 then return false end
  local half = self.sprite.size * self.sprite.scale * 0.55
  return math.abs(x - self.sprite.x) <= half
    and math.abs(y - self.sprite.y - self.sprite:bob()) <= half
end

--- Returns true when the press was the coder's and the scene should stop.
---
--- A touch on the sprite holds it; a touch anywhere else lets it go and
--- **keeps going**, so the press still reaches whatever was under it.
function Coder:mousepressed(x, y, button)
  if self.panel:mousepressed(x, y) then return true end
  if self:active() and self:hits(x, y) then
    self:press()
    return true
  end
  if self.sprite:holding() then self:release() end
  return false
end

function Coder:press()
  if self.sprite:holding() then return end
  if not self.sprite:hold(true, self.box) then return end
  SFX.play("select")
  if not self.bubble then
    if self.last_said then
      self:say(self.last_said.text, self.last_said.tone)
    else
      self:say(I18n.t("Holding still. Touch anywhere else and I'll roam."), "say")
    end
  end
end

function Coder:release()
  if not self.sprite:holding() then return end
  self.sprite:hold(false)
  if self.bubble then
    self.bubble.until_t = math.max(self.bubble.until_t, self.t + 2.5)
  end
end

function Coder:mousemoved(x, y)
  self.pointer_at = self.t
end

function Coder:textinput(text)
  return self.panel:textinput(text)
end

function Coder:keypressed(key, mods)
  return self.panel:keypressed(key, mods)
end

function Coder:wheelmoved(dy, x, y)
  if not self.panel.open then return false end
  local frame = self.panel.frame
  if frame and x and not (x >= frame.x and x <= frame.x + frame.w
    and y >= frame.y and y <= frame.y + frame.h) then
    return false
  end
  return self.panel:wheelmoved(dy)
end

M.Coder = Coder

return M
