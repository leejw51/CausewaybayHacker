-- The Rust coder's panel: the room, the verbs and the setup.
--
-- The LÖVE half of `frontend/src/ui/agent/panel.ts`. The same screen in the
-- same order — a provider tab row, the conversation, the line you type in, and
-- SEND / WRITE / REVIEW / IMAGE / STOP / CLEAR under it — drawn with this
-- client's own `src/ui.lua` rather than with a canvas. A player who has used
-- one should recognise the other without being told.
--
-- What the panel is **not** is the agent. It draws, it takes clicks and keys,
-- and it calls the host back; every decision — what to send, when to type,
-- what to keep — belongs to `coder.lua`. That split is why this file has no
-- network in it and no editor.
--
-- ## SETUP
--
-- One tab further along: the key (or, for Ollama, the host), the model, a
-- button that asks the provider what models it has, AUTO — the one call
-- nobody pressed for — and whether the character is on the screen at all.
-- The key is shown masked once it is set, because a key on a screen somebody
-- is streaming is a key that has been given away.

local Layout = require("src.layout")
local Theme = require("src.theme")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Prefs = require("src.agent.prefs")

local M = {}

local Panel = {}
Panel.__index = Panel

--- How many characters of a field are kept. A key is long; a brief is not.
local FIELD_MAX = 512

--- `host` wants: send(text), write(brief), review(), image(brief), stop(),
--- clear(), pick(id), erase(id), fetch_models(), note(text).
function M.new(host)
  return setmetatable({
    host = host,
    open = false,
    view = "chat",
    items = {},
    input = "",
    field = "",
    model_field = "",
    focus = "input",
    status = nil,
    scroll = 0,
    models = nil,
    selected = nil,
    rects = {},
    busy = false,
    can_image = false,
  }, Panel)
end

--- Add one line to the room.
function Panel:push(item)
  self.items[#self.items + 1] = item
  self.scroll = 0
  return item
end

--- Replace the room with what the server has, keeping anything of ours that
--- has not been posted yet: a message in flight must not blink out because a
--- refresh landed first.
function Panel:apply(items)
  local pending = {}
  for _, item in ipairs(self.items) do
    if item.live or item.id == nil then pending[#pending + 1] = item end
  end
  self.items = {}
  for _, item in ipairs(items) do
    self.items[#self.items + 1] = item
  end
  for _, item in ipairs(pending) do
    -- A twin: the same words from the same side, already kept by the server.
    local twin = false
    for _, kept in ipairs(self.items) do
      if kept.role == item.role and kept.text == item.text then twin = true end
    end
    if not twin then self.items[#self.items + 1] = item end
  end
end

function Panel:clear_items()
  self.items = {}
  self.selected = nil
  self.scroll = 0
end

-- ------------------------------------------------------------------- drawing

local function inside(r, x, y)
  return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

--- The words for one line of the room, and the colour to draw them in.
local function tone_of(item)
  if item.role == "you" then return Theme.cyan end
  if item.role == "tool" then return Theme.withAlpha(Theme.cream, 0.5) end
  if item.role == "error" then return Theme.coin end
  return Theme.cream
end

local function label_of(item)
  if item.role == "you" then return I18n.t("YOU") end
  if item.role == "tool" then return I18n.t("TOOL") end
  if item.role == "error" then return I18n.t("PROBLEM") end
  return Prefs.PROVIDER_NAME[Prefs.provider()] or I18n.t("CODER")
end

function Panel:draw(rect, opts)
  opts = opts or {}
  self.busy = opts.busy and true or false
  self.can_image = opts.can_image and true or false
  self.rects = {}
  -- Kept for the hit test: a press anywhere on the panel is the panel's, so
  -- the scene behind it never takes a click through the glass.
  self.frame = rect
  UI.panel(rect.x, rect.y, rect.w, rect.h)

  local pad = 8
  local x = rect.x + pad
  local w = rect.w - pad * 2
  local y = rect.y + pad
  local row = UI.lineHeight(8) + 10

  -- The title: who is being spoken to, and on what.
  local provider = Prefs.provider()
  -- **A short panel spends its height on the conversation.** In CODE the room
  -- is a column beside the editor and in the framed view it is a quarter of
  -- the window; either can be too short for chrome that assumed a page. Under
  -- this, the model's name goes back to SETUP where it is edited anyway and
  -- the tabs take the smaller row.
  local compact = rect.h < 420
  local title = ("%s · %s"):format(I18n.t("RUST CODER"),
    Prefs.PROVIDER_NAME[provider] or provider)
  UI.text(title, x, y, UI.fitSize(title, w, 8, 5), Theme.coin)
  y = y + UI.lineHeight(8) + 2
  if not compact then
    -- Which model, under the name: it is the thing most worth knowing after
    -- who is being spoken to, and it is too long to sit on the same line.
    local model = Prefs.model(provider)
    UI.text(model, x, y, UI.fitSize(model, w, 7, 5), Theme.withAlpha(Theme.cream, 0.55))
    y = y + UI.lineHeight(7) + 2
  end
  y = y + 4
  local trow = compact and (UI.lineHeight(7) + 10) or row

  -- **The room comes first.** What the panel is for is the conversation and
  -- the line you type in, so the height those need is taken out here and the
  -- tabs get what is left. A panel too short for both drew its field through
  -- the CLOSE button.
  local need_below = (row - 6) + row + 3 * (UI.lineHeight(7) + 1) + 20
  local header_room = (rect.y + rect.h - 8) - y - need_below

  -- The provider tabs, in as many columns as the panel can hold a name in.
  -- Six across a narrow room gave each of them forty pixels, and `ANTHROPIC`
  -- came out as two stacked syllables.
  local columns = math.max(2, math.min(6, math.floor(w / 96)))
  local tab_w = math.floor((w - (columns - 1) * 4) / columns)
  -- **One size for the row, from its widest name.** `UI.button` fits each
  -- label to its own box, so a row of five came out at five different sizes —
  -- `ANTHROPIC` small, `GROK` large — which reads as a ransom note rather
  -- than a set of tabs.
  local tab_size = 7
  for _, name in ipairs(Prefs.PROVIDERS) do
    tab_size = math.min(tab_size, UI.fitSize(Prefs.PROVIDER_NAME[name], tab_w - 8, 7, 4))
  end
  local tab_rows = math.ceil((#Prefs.PROVIDERS + 2) / columns)
  if header_room < tab_rows * trow then
    -- No room for a grid of them: one button that says who is being spoken
    -- to and moves to the next one when pressed, and SETUP and CLOSE beside
    -- it. Every provider is still reachable, in one row instead of three.
    local third = math.floor((w - 8) / 3)
    for index, id in ipairs({ "cycle", "setup", "close" }) do
      local r = { x = x + (index - 1) * (third + 4), y = y, w = third, h = trow - 6 }
      local label = id == "cycle" and (Prefs.PROVIDER_NAME[provider] or provider)
        or I18n.t(id == "setup" and "SETUP" or "CLOSE")
      UI.button(r.x, r.y, r.w, r.h, label,
        (id == "setup" and self.view == "setup") and "hot" or "normal", 7)
      self.rects[id] = r
    end
    y = y + trow + 2
    if self.view == "setup" then
      self:draw_setup(rect, x, y, w, row)
    else
      self:draw_chat(rect, x, y, w, row)
    end
    return
  end
  local tx = x
  for _, name in ipairs(Prefs.PROVIDERS) do
    if tx + tab_w > x + w then
      tx = x
      y = y + trow
    end
    -- `hot` is this client's word for the one that is chosen.
    local state = provider == name and "hot" or "normal"
    local r = { x = tx, y = y, w = tab_w, h = trow - 6 }
    UI.button(r.x, r.y, r.w, r.h, Prefs.PROVIDER_NAME[name], state, tab_size)
    self.rects["tab:" .. name] = r
    tx = tx + tab_w + 4
  end
  if tx + tab_w > x + w then
    tx = x
    y = y + row
  end
  -- SETUP and CLOSE are two more cells of the same grid: a row of their own
  -- is a row the conversation does not get, and on a short window the
  -- conversation was three lines tall.
  for _, verb in ipairs({ "setup", "close" }) do
    if tx + tab_w > x + w then
      tx = x
      y = y + trow
    end
    local r = { x = tx, y = y, w = tab_w, h = trow - 6 }
    local hot = verb == "setup" and self.view == "setup"
    UI.button(r.x, r.y, r.w, r.h, I18n.t(verb == "setup" and "SETUP" or "CLOSE"),
      hot and "hot" or "normal", tab_size)
    self.rects[verb] = r
    tx = tx + tab_w + 4
  end
  y = y + trow + 2

  if self.view == "setup" then
    self:draw_setup(rect, x, y, w, row)
  else
    self:draw_chat(rect, x, y, w, row)
  end
end

function Panel:draw_chat(rect, x, y, w, row)
  local bottom = rect.y + rect.h - 8
  -- From the bottom up: the verbs, then the line you type in, then whatever
  -- height is left is the room. A room that took what it liked left no field.
  local verbs_y = bottom - (row - 6)
  local field_y = verbs_y - row
  local status_h = self.status and (UI.lineHeight(7) + 4) or 0
  local well_h = math.max(40, field_y - y - 6 - status_h)

  UI.well(x, y, w, well_h, Theme.navy)
  love.graphics.setScissor(x + 2, y + 2, w - 4, well_h - 4)
  -- Measured before it is drawn, so the **newest line is the one on screen**.
  -- A room that drew from the top showed the first thing ever said and hid
  -- the answer that just arrived, which is the wrong end of a conversation.
  local line_h = UI.lineHeight(7) + 1
  local wrapped, total = {}, 0
  for index, item in ipairs(self.items) do
    local head = label_of(item)
    local body = item.text or ""
    if item.photo_url then body = body .. "  " .. I18n.t("[picture]") end
    if item.edited then body = body .. "  " .. I18n.t("(edited)") end
    local lines = UI.wrap(head .. ": " .. body, w - 20, 7)
    wrapped[index] = lines
    total = total + #lines * line_h + 6
  end
  -- `scroll` is how far *back* the reader has gone, 0 at the newest.
  local iy = y + 6
  if total > well_h - 12 then iy = y + well_h - 6 - total + self.scroll end
  local shown = 0
  if #self.items == 0 then
    UI.paragraph(
      I18n.t("Nothing said yet. Ask about the code, or type a brief and press WRITE."),
      x + 8, iy, w - 16, 7, Theme.withAlpha(Theme.cream, 0.45))
  end
  for index, item in ipairs(self.items) do
    local lines = wrapped[index]
    local h = #lines * line_h + 4
    if iy + h > y and iy < y + well_h then
      if self.selected == index then
        UI.setColor(Theme.cyan, 0.15)
        love.graphics.rectangle("fill", x + 4, iy - 2, w - 8, h)
        love.graphics.setColor(1, 1, 1, 1)
      end
      local ly = iy
      for _, line in ipairs(lines) do
        UI.text(line, x + 8, ly, 7, tone_of(item))
        ly = ly + line_h
      end
      -- Clipped to the well, because this rect is what a press is tested
      -- against: a row half-scrolled out of the top used to take clicks from
      -- above the panel, where it was not drawn and could not be seen.
      local top = math.max(iy - 2, y + 2)
      local bottom = math.min(iy - 2 + h, y + well_h - 2)
      if bottom - top > 8 then
        self.rects["msg:" .. index] = { x = x + 4, y = top, w = w - 8, h = bottom - top }
      end
      shown = shown + 1
    end
    iy = iy + h + 2
  end
  love.graphics.setScissor()
  -- How far back the wheel may go: everything that is above the fold.
  self.extent = math.max(0, total - (well_h - 12))

  if self.status then
    UI.text(self.status, x, y + well_h + 2, 7, Theme.withAlpha(Theme.coin, 0.9))
  end

  -- The line you type in.
  local field_r = { x = x, y = field_y, w = w, h = row - 6 }
  UI.well(field_r.x, field_r.y, field_r.w, field_r.h,
    self.focus == "input" and Theme.cyan or Theme.navy)
  local text = self.input
  if text == "" and self.focus ~= "input" then
    UI.text(I18n.t("ask the coder, or say what to write…"), field_r.x + 6,
      field_r.y + 5, 7, Theme.withAlpha(Theme.cream, 0.4))
  else
    local caret = self.focus == "input" and "_" or ""
    UI.text(self:tail(text .. caret, field_r.w - 12), field_r.x + 6, field_r.y + 5, 7, Theme.cream)
  end
  self.rects["input"] = field_r

  -- The verbs. STOP is live only while it is busy; IMAGE only where the
  -- provider can draw and the pad has a room.
  local verbs = {
    { id = "send", label = I18n.t("SEND") },
    { id = "write", label = I18n.t("WRITE") },
    { id = "review", label = I18n.t("REVIEW") },
    { id = "image", label = I18n.t("IMAGE"), dim = not self.can_image },
    { id = "stop", label = I18n.t("STOP"), dim = not self.busy },
    { id = "clear", label = I18n.t("CLEAR") },
  }
  if self.selected then
    verbs = {
      { id = "edit", label = I18n.t("EDIT") },
      { id = "delete", label = I18n.t("DELETE") },
      { id = "unpick", label = I18n.t("BACK") },
    }
  end
  local vw = math.floor((w - (#verbs - 1) * 4) / #verbs)
  local verb_size = 7
  for _, verb in ipairs(verbs) do
    verb_size = math.min(verb_size, UI.fitSize(verb.label, vw - 8, 7, 4))
  end
  local vx = x
  for _, verb in ipairs(verbs) do
    local r = { x = vx, y = verbs_y, w = vw, h = row - 6 }
    UI.button(r.x, r.y, r.w, r.h, verb.label, verb.dim and "disabled" or "normal", verb_size)
    if not verb.dim then self.rects[verb.id] = r end
    vx = vx + vw + 4
  end
end

function Panel:draw_setup(rect, x, y, w, row)
  local provider = Prefs.provider()
  local needs = Prefs.needs_key(provider)
  local label_h = UI.lineHeight(7) + 4

  -- **Three rows, measured from the floor.** The key, the model and the two
  -- switches are what somebody came to SETUP to press, so the height is
  -- divided between them before anything is drawn and every position below
  -- comes out of that one division. Laid out downwards from the top instead,
  -- a short panel drew the key field straight through the model row and put
  -- the switches off the bottom edge, where they could be seen and not
  -- pressed.
  local bottom = rect.y + rect.h - 8
  local gaps = 12
  local room = bottom - y
  local labels = true
  local field_h = math.floor((room - gaps - 2 * label_h) / 3)
  if field_h < UI.lineHeight(7) + 8 then
    -- No room for the captions: the key field says what it wants when it is
    -- empty, and MODEL sits next to a button that says MODELS.
    labels = false
    field_h = math.floor((room - gaps) / 3)
  end
  field_h = math.max(14, math.min(row - 6, field_h))

  local switches_y = bottom - field_h
  local model_y = switches_y - 6 - field_h
  local model_label_y = labels and (model_y - label_h) or model_y
  local key_y = labels and (y + label_h) or y
  -- Whatever the arithmetic above left, the key row sits above the model row
  -- and not through it.
  key_y = math.min(key_y, model_label_y - 6 - field_h)
  key_y = math.max(key_y, y)

  -- The key, at the top, with its label when there is room for one.
  if labels then
    UI.text(needs and I18n.t("API KEY") or I18n.t("HOST"), x, key_y - label_h, 7,
      Theme.withAlpha(Theme.cream, 0.6))
  end

  local key_r = { x = x, y = key_y, w = w, h = field_h }
  UI.well(key_r.x, key_r.y, key_r.w, key_r.h,
    self.focus == "key" and Theme.cyan or Theme.navy)
  local shown
  if self.focus == "key" then
    shown = self:tail(self.field .. "_", key_r.w - 12)
  elseif Prefs.key(provider) ~= "" then
    shown = needs and Prefs.mask(Prefs.key(provider)) or Prefs.key(provider)
  elseif needs then
    shown = I18n.t("no key yet — press here and paste")
  else
    shown = Prefs.OLLAMA_DEFAULT_HOST
  end
  UI.text(shown, key_r.x + 6, key_r.y + 5, 7,
    Prefs.key(provider) == "" and self.focus ~= "key"
      and Theme.withAlpha(Theme.cream, 0.4) or Theme.cream)
  self.rects["key"] = key_r
  y = key_y + field_h + 6

  -- Where it goes, said plainly — but only when saying it does not cost the
  -- list its last line. A provider key on a game's screen deserves one
  -- sentence about where it is kept, and a panel too short to hold the
  -- sentence is a panel that needs its buttons more.
  local note = I18n.t("Kept on this machine only, and sent to the provider that issued it. Never to the game server.")
  local note_h = UI.lineHeight(7) * #UI.wrap(note, w, 7)
  if model_label_y - y > note_h + 40 then
    y = y + UI.paragraph(note, x, y, w, 7, Theme.withAlpha(Theme.cream, 0.45)) + 6
  end

  -- What the provider answered, in whatever room is left between the key and
  -- the model row. Dropped entirely when there is none.
  local list_h = model_label_y - y - 6
  if self.models and #self.models > 0 and list_h >= 40 then
    UI.well(x, y, w, list_h, Theme.navy)
    love.graphics.setScissor(x + 2, y + 2, w - 4, list_h - 4)
    local my = y + 4 - self.scroll
    for index, id in ipairs(self.models) do
      local h = UI.lineHeight(7) + 4
      if my + h > y and my < y + list_h then
        UI.text(id, x + 8, my, 7, id == Prefs.model(provider) and Theme.coin or Theme.cream)
        self.rects["model:" .. index] = { x = x + 4, y = my - 2, w = w - 8, h = h }
      end
      my = my + h
    end
    love.graphics.setScissor()
    self.extent = math.max(0, (my + self.scroll) - (y + list_h))
  elseif self.status and list_h >= UI.lineHeight(7) then
    UI.paragraph(self.status, x, y, w, 7, Theme.withAlpha(Theme.coin, 0.9), 2)
  end

  -- The model, named and chosen.
  if labels then
    UI.text(I18n.t("MODEL"), x, model_label_y, 7, Theme.withAlpha(Theme.cream, 0.6))
  end
  local fetch_w = math.min(math.floor(w * 0.4), math.max(72, UI.textWidth(I18n.t("MODELS"), 7) + 24))
  local model_r = { x = x, y = model_y, w = w - fetch_w - 4, h = field_h }
  UI.well(model_r.x, model_r.y, model_r.w, model_r.h,
    self.focus == "model" and Theme.cyan or Theme.navy)
  local model_text = self.focus == "model" and (self.model_field .. "_") or Prefs.model(provider)
  UI.text(self:tail(model_text, model_r.w - 12), model_r.x + 6, model_r.y + 5, 7, Theme.cream)
  self.rects["model"] = model_r
  local fetch_r = { x = x + w - fetch_w, y = model_y, w = fetch_w, h = field_h }
  UI.button(fetch_r.x, fetch_r.y, fetch_r.w, fetch_r.h, I18n.t("MODELS"), "normal", 7)
  self.rects["fetch"] = fetch_r

  -- And the two switches, on the floor.
  local half = math.floor((w - 4) / 2)
  local auto_r = { x = x, y = switches_y, w = half, h = field_h }
  UI.button(auto_r.x, auto_r.y, auto_r.w, auto_r.h,
    I18n.t("AUTO") .. ": " .. (Prefs.auto() and I18n.t("ON") or I18n.t("OFF")),
    Prefs.auto() and "hot" or "normal", 7)
  self.rects["auto"] = auto_r
  local shown_r = { x = x + half + 4, y = switches_y, w = half, h = field_h }
  UI.button(shown_r.x, shown_r.y, shown_r.w, shown_r.h,
    I18n.t("CODER") .. ": " .. (Prefs.shown() and I18n.t("ON") or I18n.t("OFF")),
    Prefs.shown() and "hot" or "normal", 7)
  self.rects["shown"] = shown_r
end

--- The end of a long line, which is the part being typed.
function Panel:tail(text, width)
  while UI.textWidth(text, 7) > width and #text > 1 do
    text = text:sub(2)
  end
  return text
end

-- --------------------------------------------------------------------- input

function Panel:mousepressed(x, y)
  if not self.open then return false end
  for id, r in pairs(self.rects) do
    if inside(r, x, y) then
      self:pressed(id)
      return true
    end
  end
  -- A press inside the panel is the panel's, even where nothing is drawn:
  -- the scene behind it must not take a click through it.
  return inside(self.frame, x, y)
end

function Panel:pressed(id)
  SFX.play("select")
  local tab = id:match("^tab:(.+)$")
  if tab then
    Prefs.set_provider(tab)
    self.models = nil
    self.status = nil
    return
  end
  local index = id:match("^msg:(%d+)$")
  if index then
    index = tonumber(index)
    self.selected = self.selected == index and nil or index
    return
  end
  local model_at = id:match("^model:(%d+)$")
  if model_at then
    local picked = self.models and self.models[tonumber(model_at)]
    if picked then
      Prefs.set_model(Prefs.provider(), picked)
      self.model_field = picked
    end
    return
  end
  if id == "cycle" then
    -- Round the list and back to the start: the tab row's job in one button.
    local at = 1
    for index, name in ipairs(Prefs.PROVIDERS) do
      if name == Prefs.provider() then at = index end
    end
    Prefs.set_provider(Prefs.PROVIDERS[(at % #Prefs.PROVIDERS) + 1])
    self.models = nil
    self.status = nil
    return
  end
  if id == "setup" then
    self.view = self.view == "setup" and "chat" or "setup"
    self.focus = self.view == "setup" and "key" or "input"
    self.field = Prefs.key(Prefs.provider())
    self.model_field = Prefs.model(Prefs.provider())
    self.scroll = 0
  elseif id == "close" then
    self:commit_fields()
    self.open = false
  elseif id == "input" then
    self.focus = "input"
  elseif id == "key" then
    self.focus = "key"
    self.field = Prefs.key(Prefs.provider())
  elseif id == "model" then
    self.focus = "model"
    self.model_field = Prefs.model(Prefs.provider())
  elseif id == "fetch" then
    self:commit_fields()
    self.host.fetch_models()
  elseif id == "auto" then
    Prefs.set_auto(not Prefs.auto())
  elseif id == "shown" then
    Prefs.set_shown(not Prefs.shown())
  elseif id == "send" then
    self:submit("send")
  elseif id == "write" then
    self:submit("write")
  elseif id == "review" then
    self.host.review()
  elseif id == "image" then
    self:submit("image")
  elseif id == "stop" then
    self.host.stop()
  elseif id == "clear" then
    self.host.clear()
  elseif id == "edit" then
    local item = self.items[self.selected or 0]
    if item then
      self.input = item.text or ""
      self.editing = item.id
      self.focus = "input"
    end
  elseif id == "delete" then
    local item = self.items[self.selected or 0]
    if item and item.id then self.host.erase(item.id) end
    self.selected = nil
  elseif id == "unpick" then
    self.selected = nil
  end
end

--- What the field is worth, and then it is empty.
function Panel:submit(how)
  local text = (self.input or ""):match("^%s*(.-)%s*$")
  if text == "" then return end
  self.input = ""
  if self.editing then
    local id = self.editing
    self.editing = nil
    self.selected = nil
    self.host.amend(id, text)
    return
  end
  if how == "write" then
    self.host.write(text)
  elseif how == "image" then
    self.host.image(text)
  else
    self.host.send(text)
  end
end

--- Whatever is half-typed in a field belongs to the preference it edits.
function Panel:commit_fields()
  if self.focus == "key" then
    Prefs.set_key(Prefs.provider(), self.field)
  elseif self.focus == "model" then
    Prefs.set_model(Prefs.provider(), self.model_field)
  end
end

function Panel:textinput(text)
  if not self.open then return false end
  if self.focus == "input" then
    if #self.input < FIELD_MAX then self.input = self.input .. text end
    return true
  elseif self.focus == "key" then
    if #self.field < FIELD_MAX then self.field = self.field .. text end
    return true
  elseif self.focus == "model" then
    if #self.model_field < FIELD_MAX then self.model_field = self.model_field .. text end
    return true
  end
  return false
end

function Panel:keypressed(key, mods)
  if not self.open then return false end
  local function backspace(text)
    -- One character, not one byte: a Korean brief must not come apart.
    local i = #text
    while i > 1 and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do
      i = i - 1
    end
    return text:sub(1, i - 1)
  end
  if key == "escape" then
    if self.selected then
      self.selected = nil
    elseif self.view == "setup" then
      self:commit_fields()
      self.view = "chat"
      self.focus = "input"
    else
      self:commit_fields()
      self.open = false
    end
    return true
  end
  if key == "tab" then
    if self.view == "setup" then
      self:commit_fields()
      self.focus = self.focus == "key" and "model" or "key"
      self.field = Prefs.key(Prefs.provider())
      self.model_field = Prefs.model(Prefs.provider())
    end
    return true
  end
  if key == "return" or key == "kpenter" then
    if self.view == "setup" then
      self:commit_fields()
      self.focus = self.focus == "key" and "model" or "key"
    elseif mods and mods.shift then
      self:submit("write")
    else
      self:submit("send")
    end
    return true
  end
  if key == "backspace" then
    if self.focus == "input" then
      self.input = backspace(self.input)
    elseif self.focus == "key" then
      self.field = backspace(self.field)
    elseif self.focus == "model" then
      self.model_field = backspace(self.model_field)
    end
    return true
  end
  if key == "v" and mods and (mods.ctrl or mods.gui) then
    local clip = love.system and love.system.getClipboardText and love.system.getClipboardText()
    if clip and clip ~= "" then
      clip = clip:gsub("[\r\n]", " ")
      if self.focus == "key" then
        self.field = (self.field .. clip):sub(1, FIELD_MAX)
      elseif self.focus == "model" then
        self.model_field = (self.model_field .. clip):sub(1, FIELD_MAX)
      else
        self.input = (self.input .. clip):sub(1, FIELD_MAX)
      end
    end
    return true
  end
  return false
end

function Panel:wheelmoved(dy)
  if not self.open then return false end
  -- Up goes back into the conversation; 0 is the newest line, which is where
  -- a new message puts it again.
  self.scroll = math.max(0, math.min(self.extent or 0, self.scroll + dy * 24))
  return true
end

M.Panel = Panel

return M
