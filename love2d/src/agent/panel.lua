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
  if item.role == "you" then return Theme.blue end
  if item.role == "tool" then return Theme.mute end
  if item.role == "error" then return Theme.gold end
  return Theme.text
end

local function label_of(item)
  if item.role == "you" then return I18n.t("YOU") end
  if item.role == "tool" then return I18n.t("TOOL") end
  if item.role == "error" then return I18n.t("PROBLEM") end
  return Prefs.PROVIDER_NAME[Prefs.provider()] or I18n.t("CODER")
end

--- A button's width for its widest label: the kit's padding each side.
local function button_w(labels, padx)
  local w = 0
  for _, label in ipairs(labels) do w = math.max(w, (UI.buttonSize(label, { padx = padx }))) end
  return math.ceil(w)
end

--- A row's height on this canvas: what the button face needs.
local function button_h()
  local _, h = UI.buttonSize("A")
  return math.max(Theme.control.chip + Theme.space.xs, h)
end

--- Lay `items` (each with `w`) into rows `w` wide, `gap` apart. Pure.
local function flow(items, w, gap)
  local rows, line, bx = {}, {}, 0
  for _, item in ipairs(items) do
    if #line > 0 and bx + item.w > w then
      rows[#rows + 1] = line
      line, bx = {}, 0
    end
    line[#line + 1] = { item = item, x = bx }
    bx = bx + item.w + gap
  end
  if #line > 0 then rows[#rows + 1] = line end
  return rows
end

--- A row (or rows) of buttons from `x, y`, by measurement; when the rows
--- would not fit `max_h`, one row of equal shares instead, so every verb
--- stays on the panel. Returns the height taken. `id_of(item)` keys the
--- rect; `state_of(item)` is the button state.
local function button_rows(self, items, x, y, w, max_h, h, id_of, state_of, prefix)
  local gap = Theme.space.sm
  local sized = {}
  for i, item in ipairs(items) do
    sized[i] = { item = item, w = button_w(item.every or { item.label }) }
  end
  local rows = flow(sized, w, gap)
  local total = #rows * h + (#rows - 1) * gap
  if total > max_h then
    -- Equal shares on one row: cramped, but on the panel.
    local bw = math.floor((w - (#items - 1) * gap) / #items)
    rows = { {} }
    for i, item in ipairs(items) do
      rows[1][i] = { item = { item = item, w = bw }, x = (i - 1) * (bw + gap) }
    end
    total = h
  end
  for ri, row in ipairs(rows) do
    local ry = y + (ri - 1) * (h + gap)
    for _, cell in ipairs(row) do
      local item = cell.item.item
      local r = { x = x + cell.x, y = ry, w = cell.item.w, h = h }
      UI.button(r.x, r.y, r.w, r.h, item.label, state_of(item), nil,
        { id = prefix .. id_of(item), variant = item.variant or "secondary" })
      if state_of(item) ~= "disabled" then self.rects[id_of(item)] = r end
    end
  end
  return total
end

--- A text well: the kit's well with a gold edge while it has the caret.
local function well(x, y, w, h, hot)
  UI.card(x, y, w, h, { variant = "well", pad = 0, edge = hot and Theme.gold or nil })
end

function Panel:draw(rect, opts)
  opts = opts or {}
  self.busy = opts.busy and true or false
  self.can_image = opts.can_image and true or false
  self.rects = {}
  -- Kept for the hit test: a press anywhere on the panel is the panel's, so
  -- the scene behind it never takes a click through the glass.
  self.frame = rect
  UI.card(rect.x, rect.y, rect.w, rect.h, { pad = 0, strip = Theme.gold })

  local pad = Theme.space.md
  local x = rect.x + pad
  local w = rect.w - pad * 2
  local y = rect.y + Theme.stripH + pad
  local bottom = rect.y + rect.h - pad
  local lead = UI.lead("label")

  -- The title: who is being spoken to, and on what.
  local provider = Prefs.provider()
  -- **A short panel spends its height on the conversation.** Under this the
  -- model's name goes back to SETUP, where it is edited anyway.
  local compact = rect.h < 420
  local title = ("%s · %s"):format(I18n.t("RUST CODER"), Prefs.PROVIDER_NAME[provider] or provider)
  UI.label(title, x, y, "label", { color = Theme.gold, width = w, ellipsis = true })
  y = y + lead + Theme.space.xs
  if not compact then
    UI.label(Prefs.model(provider), x, y, "label", { color = Theme.mute, width = w, ellipsis = true })
    y = y + lead + Theme.space.xs
  end
  y = y + Theme.space.xs

  -- **The room comes first.** What the panel is for is the conversation and
  -- the line you type in, so the least they need is taken out here and the
  -- tabs get what is left.
  local chip_h = Theme.control.chip
  local gap = Theme.space.sm
  local need_below = 40 + gap + button_h() * 2 + gap + Theme.space.lg
  local header_room = bottom - y - need_below

  -- The provider tabs as chips, flowing by measurement; SETUP and CLOSE are
  -- two more chips of the same row.
  local chips = {}
  for _, name in ipairs(Prefs.PROVIDERS) do
    chips[#chips + 1] = { id = "tab:" .. name, label = Prefs.PROVIDER_NAME[name] or name,
      selected = provider == name }
  end
  chips[#chips + 1] = { id = "setup", label = I18n.t("SETUP"), selected = self.view == "setup" }
  chips[#chips + 1] = { id = "close", label = I18n.t("CLOSE") }
  for _, chip in ipairs(chips) do chip.w = UI.chipWidth(chip.label) end
  local rows = flow(chips, w, gap)
  if #rows * (chip_h + gap) - gap > header_room then
    -- No room for a grid of them: one chip that says who is being spoken
    -- to and moves to the next one when pressed, with SETUP and CLOSE
    -- beside it. Every provider is still reachable.
    chips = {
      { id = "cycle", label = Prefs.PROVIDER_NAME[provider] or provider, selected = true },
      { id = "setup", label = I18n.t("SETUP"), selected = self.view == "setup" },
      { id = "close", label = I18n.t("CLOSE") },
    }
    local total = 0
    for _, chip in ipairs(chips) do chip.w = UI.chipWidth(chip.label); total = total + chip.w end
    if total + gap * 2 > w then
      local share = math.floor((w - gap * 2) / 3)
      for _, chip in ipairs(chips) do chip.w = share end
    end
    rows = flow(chips, w, gap)
  end
  for ri, row in ipairs(rows) do
    local ry = y + (ri - 1) * (chip_h + gap)
    for _, cell in ipairs(row) do
      local chip = cell.item
      UI.chip(x + cell.x, ry, chip.label, { selected = chip.selected, w = chip.w })
      self.rects[chip.id] = { x = x + cell.x, y = ry, w = chip.w, h = chip_h }
    end
  end
  y = y + #rows * (chip_h + gap)

  if self.view == "setup" then
    self:draw_setup(rect, x, y, w, bottom)
  else
    self:draw_chat(rect, x, y, w, bottom)
  end
end

function Panel:draw_chat(rect, x, y, w, bottom)
  local lead = UI.lead("label")
  local font = UI.font("label")
  local gap = Theme.space.sm
  local bh = button_h()

  -- From the bottom up: the verbs, then the line you type in, then whatever
  -- height is left is the room. A room that took what it liked left no field.
  -- The verbs. STOP is live only while it is busy; IMAGE only where the
  -- provider can draw and the pad has a room.
  local verbs = {
    { id = "send", label = I18n.t("SEND"), variant = "primary" },
    { id = "write", label = I18n.t("WRITE") },
    { id = "review", label = I18n.t("REVIEW") },
    { id = "image", label = I18n.t("IMAGE"), dim = not self.can_image },
    { id = "stop", label = I18n.t("STOP"), dim = not self.busy },
    { id = "clear", label = I18n.t("CLEAR") },
  }
  if self.selected then
    verbs = {
      { id = "edit", label = I18n.t("EDIT") },
      { id = "delete", label = I18n.t("DELETE"), variant = "danger" },
      { id = "unpick", label = I18n.t("BACK") },
    }
  end
  -- Measured first, so the room knows what the verbs will take: rows by
  -- measurement when they fit in half the panel, one cramped row when not.
  local sized = {}
  for i, verb in ipairs(verbs) do sized[i] = { w = button_w({ verb.label }) } end
  local verb_rows = #flow(sized, w, gap)
  local verbs_h = verb_rows * bh + (verb_rows - 1) * gap
  local room = bottom - y
  if verbs_h > room * 0.45 then verbs_h = bh end
  local verbs_y = bottom - verbs_h
  local field_h = bh
  local field_y = verbs_y - gap - field_h
  local status_h = self.status and (lead + Theme.space.xs) or 0
  local well_h = math.max(40, field_y - gap - status_h - y)

  well(x, y, w, well_h, false)
  love.graphics.setScissor(x + 1, y + 1, math.max(0, w - 2), math.max(0, well_h - 2))
  -- Measured before it is drawn, so the **newest line is the one on screen**.
  local inner = w - Theme.space.lg
  local wrapped, total = {}, 0
  for index, item in ipairs(self.items) do
    local head = label_of(item)
    local body = item.text or ""
    if item.photo_url then body = body .. "  " .. I18n.t("[picture]") end
    if item.edited then body = body .. "  " .. I18n.t("(edited)") end
    local lines = UI.wrapWith(head .. ": " .. body, inner, font)
    wrapped[index] = lines
    total = total + #lines * lead + Theme.space.xs
  end
  -- `scroll` is how far *back* the reader has gone, 0 at the newest.
  local iy = y + gap
  if total > well_h - gap * 2 then iy = y + well_h - gap - total + self.scroll end
  love.graphics.setFont(font)
  if #self.items == 0 then
    local hint = I18n.t("Nothing said yet. Ask about the code, or type a brief and press WRITE.")
    for i, line in ipairs(UI.wrapWith(hint, inner, font)) do
      UI.label(line, x + gap, iy + (i - 1) * lead, "label", { color = Theme.mute })
    end
  end
  for index, item in ipairs(self.items) do
    local lines = wrapped[index]
    local h = #lines * lead
    if iy + h > y and iy < y + well_h then
      if self.selected == index then
        UI.setColor(Theme.cardHi, 0.7)
        UI.rrect("fill", x + Theme.space.xs, iy - 2, w - Theme.space.xs * 2, h + 4, Theme.radiusSm)
        love.graphics.setColor(1, 1, 1, 1)
      end
      for li, line in ipairs(lines) do
        UI.label(line, x + gap, iy + (li - 1) * lead, "label", { color = tone_of(item) })
      end
      -- Clipped to the well, because this rect is what a press is tested
      -- against: a row half-scrolled out of the top must not take clicks
      -- from above the panel.
      local top = math.max(iy - 2, y + 2)
      local foot = math.min(iy + h + 2, y + well_h - 2)
      if foot - top > 8 then
        self.rects["msg:" .. index] = { x = x + Theme.space.xs, y = top, w = w - Theme.space.xs * 2, h = foot - top }
      end
    end
    iy = iy + h + Theme.space.xs
  end
  love.graphics.setScissor()
  -- How far back the wheel may go: everything that is above the fold.
  self.extent = math.max(0, total - (well_h - gap * 2))

  if self.status then
    UI.label(self.status, x, y + well_h + Theme.space.xs, "label",
      { color = Theme.gold, width = w, ellipsis = true })
  end

  -- The line you type in.
  local field_r = { x = x, y = field_y, w = w, h = field_h }
  well(field_r.x, field_r.y, field_r.w, field_r.h, self.focus == "input")
  local ty = field_y + math.floor((field_h - lead) / 2)
  local text = self.input
  if text == "" and self.focus ~= "input" then
    UI.label(I18n.t("ask the coder, or say what to write…"), field_r.x + gap, ty, "label",
      { color = Theme.mute, width = w - gap * 2, ellipsis = true })
  else
    local caret = self.focus == "input" and "_" or ""
    UI.label(self:tail(text .. caret, field_r.w - gap * 2), field_r.x + gap, ty, "label")
  end
  self.rects["input"] = field_r

  button_rows(self, verbs, x, verbs_y, w, verbs_h, bh,
    function(v) return v.id end,
    function(v) return v.dim and "disabled" or "normal" end, "agent:")
end

function Panel:draw_setup(rect, x, y, w, bottom)
  local provider = Prefs.provider()
  local needs = Prefs.needs_key(provider)
  local lead = UI.lead("label")
  local gap = Theme.space.sm
  local font = UI.font("label")

  -- **Measured from the floor.** The three switches, the model row and the
  -- key field are what somebody came to SETUP to press, so their heights are
  -- taken before anything is drawn; the captions, the note and the list of
  -- models get what is left, in that order of giving way.
  local switches = {
    { id = "auto", label = I18n.t("AUTO") .. ": " .. (Prefs.auto() and I18n.t("ON") or I18n.t("OFF")),
      every = { I18n.t("AUTO") .. ": " .. I18n.t("ON"), I18n.t("AUTO") .. ": " .. I18n.t("OFF") },
      on = Prefs.auto() },
    -- Whether an answer is also left in the file as a comment
    -- (`src/agent/notes.lua`).
    { id = "notes", label = I18n.t("COMMENT") .. ": " .. (Prefs.notes() and I18n.t("ON") or I18n.t("OFF")),
      every = { I18n.t("COMMENT") .. ": " .. I18n.t("ON"), I18n.t("COMMENT") .. ": " .. I18n.t("OFF") },
      on = Prefs.notes() },
    { id = "shown", label = I18n.t("CODER") .. ": " .. (Prefs.shown() and I18n.t("ON") or I18n.t("OFF")),
      every = { I18n.t("CODER") .. ": " .. I18n.t("ON"), I18n.t("CODER") .. ": " .. I18n.t("OFF") },
      on = Prefs.shown() },
  }
  local sized = {}
  for i, s in ipairs(switches) do sized[i] = { w = button_w(s.every) } end
  local switch_rows = #flow(sized, w, gap)

  local field_h = button_h()
  local labels = true
  local function need(fh, with_labels, rows)
    return (with_labels and lead * 2 or 0) + fh * 2 + gap * 2 + rows * fh + (rows - 1) * gap
  end
  local room = bottom - y
  if need(field_h, labels, switch_rows) > room then labels = false end
  if need(field_h, labels, switch_rows) > room then field_h = lead + Theme.space.sm end
  if need(field_h, labels, switch_rows) > room then switch_rows = 1 end
  local switches_h = switch_rows * field_h + (switch_rows - 1) * gap
  local switches_y = bottom - switches_h
  local model_y = switches_y - gap - field_h
  local model_label_y = labels and (model_y - lead) or model_y
  local key_y = labels and (y + lead) or y
  -- Whatever the arithmetic above left, the key row sits above the model
  -- row and not through it.
  key_y = math.min(key_y, model_label_y - gap - field_h)
  key_y = math.max(key_y, y)

  -- The key, at the top, with its label when there is room for one.
  if labels then
    UI.label(needs and I18n.t("API KEY") or I18n.t("HOST"), x, key_y - lead, "label", { color = Theme.mute })
  end
  local key_r = { x = x, y = key_y, w = w, h = field_h }
  well(key_r.x, key_r.y, key_r.w, key_r.h, self.focus == "key")
  local shown
  if self.focus == "key" then
    shown = self:tail(self.field .. "_", key_r.w - gap * 2)
  elseif Prefs.key(provider) ~= "" then
    shown = needs and Prefs.mask(Prefs.key(provider)) or Prefs.key(provider)
  elseif needs then
    shown = I18n.t("no key yet — press here and paste")
  else
    shown = Prefs.OLLAMA_DEFAULT_HOST
  end
  UI.label(shown, key_r.x + gap, key_y + math.floor((field_h - lead) / 2), "label",
    { color = (Prefs.key(provider) == "" and self.focus ~= "key") and Theme.mute or Theme.text,
      width = w - gap * 2, ellipsis = true })
  self.rects["key"] = key_r
  y = key_y + field_h + gap

  -- Where it goes, said plainly — but only when saying it does not cost the
  -- list its last line.
  local note = I18n.t("Kept on this machine only, and sent to the provider that issued it. Never to the game server.")
  local note_lines = UI.wrapWith(note, w, font)
  local note_h = #note_lines * lead
  if model_label_y - y > note_h + 40 then
    for i, line in ipairs(note_lines) do
      UI.label(line, x, y + (i - 1) * lead, "label", { color = Theme.mute })
    end
    y = y + note_h + gap
  end

  -- What the provider answered, in whatever room is left between the key and
  -- the model row. Dropped entirely when there is none.
  local list_h = model_label_y - y - gap
  if self.models and #self.models > 0 and list_h >= 40 then
    well(x, y, w, list_h, false)
    love.graphics.setScissor(x + 1, y + 1, math.max(0, w - 2), math.max(0, list_h - 2))
    local my = y + Theme.space.xs - self.scroll
    for index, id in ipairs(self.models) do
      if my + lead > y and my < y + list_h then
        UI.label(id, x + gap, my, "label",
          { color = id == Prefs.model(provider) and Theme.gold or Theme.text, width = w - gap * 2, ellipsis = true })
        self.rects["model:" .. index] = { x = x + Theme.space.xs, y = math.max(my, y + 1),
          w = w - Theme.space.xs * 2, h = math.min(lead, y + list_h - 1 - math.max(my, y + 1)) }
      end
      my = my + lead
    end
    love.graphics.setScissor()
    self.extent = math.max(0, (my + self.scroll) - (y + list_h))
  elseif self.status and list_h >= lead then
    local lines = UI.wrapWith(self.status, w, font)
    for i = 1, math.min(#lines, math.floor(list_h / lead), 2) do
      UI.label(lines[i], x, y + (i - 1) * lead, "label", { color = Theme.gold })
    end
  end

  -- The model, named and chosen.
  if labels then
    UI.label(I18n.t("MODEL"), x, model_label_y, "label", { color = Theme.mute })
  end
  local fetch_w = math.min(math.floor(w * 0.4), button_w({ I18n.t("MODELS") }))
  local model_r = { x = x, y = model_y, w = w - fetch_w - gap, h = field_h }
  well(model_r.x, model_r.y, model_r.w, model_r.h, self.focus == "model")
  local model_text = self.focus == "model" and (self.model_field .. "_") or Prefs.model(provider)
  UI.label(self:tail(model_text, model_r.w - gap * 2), model_r.x + gap,
    model_y + math.floor((field_h - lead) / 2), "label")
  self.rects["model"] = model_r
  local fetch_r = { x = x + w - fetch_w, y = model_y, w = fetch_w, h = field_h }
  UI.button(fetch_r.x, fetch_r.y, fetch_r.w, fetch_r.h, I18n.t("MODELS"), "normal", nil,
    { id = "agent:fetch", padx = Theme.space.sm })
  self.rects["fetch"] = fetch_r

  -- And the switches, on the floor, each saying the state it is in.
  button_rows(self, switches, x, switches_y, w, switches_h, field_h,
    function(s) return s.id end,
    function(s) return s.on and "hot" or "normal" end, "agent:")
end

--- The end of a long line, which is the part being typed.
function Panel:tail(text, width)
  local font = UI.font("label")
  while font:getWidth(text) > width and #text > 1 do
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
  elseif id == "notes" then
    Prefs.set_notes(not Prefs.notes())
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
