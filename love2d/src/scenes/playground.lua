-- THE PLAYGROUND (PROTOCOL §4.9c). Mei's own desk.
--
-- A scratchpad: no quest, no tests, no verdict. You write whatever you like,
-- run it, and it prints what it prints.
--
-- ## Nothing here is scored, and the screen has to say so by how it looks
--
-- DESIGN made `bg_playground` and deliberately nothing else — the room the
-- game opens in, "identity is absence". So this screen follows the same rule
-- in its language:
--
--   * **compiler output does not speak in the failure register.** No red, no
--     `Theme.verdict` colours, no banner. A compile error here is information,
--     not a judgement, and the outcome line says "did not compile" the way a
--     terminal would.
--   * **the word "wrong" does not appear**, and neither does FAIL, ERROR as a
--     headline, or anything else that implies there was a right answer. There
--     is no answer here; there is only what the program did.
--
-- That is not decoration. §4.9c says a playground run is deliberately *not*
-- recorded and does not feed the curriculum, precisely because this is where
-- somebody writes something broken on purpose to see what the compiler says.
-- A screen that scolded them for it would be arguing with its own contract.
--
-- ## Snippets live on the server
--
-- §4.9c: saved per user, server-side, so the same scratchpad opens in the
-- browser and here. Autosave is on a timer and `playground.save` is idempotent
-- by contract, so an unchanged buffer costs nothing.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Editor = require("src.editor")
local CodePane = require("src.codepane")
local Anim = require("src.anim")
local runlog = require("src.net.runlog")

local Playground = {}
Playground.__index = Playground

local Land = require("src.land")

-- TAB walks the languages in the lands' order, and the starter is the same
-- program in each: the smallest thing that compiles and prints, so the desk
-- proves the toolchain is there before anybody types.
local LANGS = Land.ORDER

local STARTER = {
  rust = 'fn main() {\n    println!("hello");\n}\n',
  go = 'package main\n\nimport "fmt"\n\nfunc main() {\n\tfmt.Println("hello")\n}\n',
  cpp = '#include <iostream>\n\nint main() {\n    std::cout << "hello\\n";\n}\n',
  python = 'print("hello")\n',
}
Playground.LANGS = LANGS
Playground.STARTER = STARTER

--- §5.9's `outcome`, in plain words. Not one of them is a verdict: every line
--- describes what the program did, which is all that happened.
local OUTCOME = {
  ok = "ran",
  compile_error = "did not compile",
  runtime_error = "stopped early",
  timeout = "took too long",
  output_limit = "printed too much",
}

-- How long an untouched buffer waits before it is saved. Long enough that
-- typing does not generate traffic, short enough that nobody loses a thought.
Playground.AUTOSAVE_S = 4

function Playground.new(app)
  return setmetatable({
    app = app,
    lang = "rust",
    snippets = nil,
    snippet_id = nil,
    name = nil,
    focus = "editor",       -- "editor" | "stdin" | "snippets"
    stdin = "",
    running = false,
    result = nil,
    log = nil,
    stage = nil,
    elapsed_ms = 0,
    note = nil,
    problem = nil,
    formatting = false,
    format_unsupported = nil,
    cursor = 1,
    dirty_at = nil,
    saved_at = nil,
    t = 0,
    -- CODE: the editor and nothing else. The quest screen has the same mode
    -- for the same reason — this screen is five panes in one window, and on
    -- a phone that leaves the thing you are typing into a few lines tall.
    big = false,
    -- What is in the name field while somebody is renaming. Nil when nobody
    -- is: `focus == "name"` and this are set and cleared together.
    name_edit = nil,
    -- True until the first keystroke of a rename, which then replaces the
    -- whole name rather than appending to it — the desktop client's "arrives
    -- selected", with no selection to draw.
    name_fresh = false,
    -- Narrowing the list by name. The pads are in most-recently-touched
    -- order, which is the right order to keep and the wrong one to hunt
    -- through once there are a dozen.
    query = "",
    finding = false,
  }, Playground)
end

function Playground:enter()
  self.editor = Editor.new({
    clipboard = {
      get = function() return love.system.getClipboardText() or "" end,
      set = function(text) love.system.setClipboardText(text or "") end,
    },
    now = function() return love.timer.getTime() end,
  })
  -- Same pane object as the quest screen's: the hit test, drag-select and the
  -- bracket overlay are one implementation, not two that look alike.
  self.pane = CodePane.new(self.editor)
  self.editor:set_text(STARTER[self.lang])
  self.editor.dirty = false

  self.subscriptions = {
    self.app.session:on("run.stage", function(payload) self:on_stage(payload) end),
    self.app.session:on("run.log", function(payload) self:on_log(payload) end),
  }
  self:list()
end

function Playground:leave()
  -- Save on the way out rather than losing the last few seconds of typing.
  if self.editor and self.editor.dirty then self:save() end
  self.app.session:off_all(self.subscriptions)
  self.subscriptions = nil
end

-- ----------------------------------------------------------------- snippets

function Playground:list()
  self.app.session:request("playground.list", {}, function(ok, payload)
    if not ok then return end
    self.snippets = payload.snippets or {}
    self.cursor = math.max(1, math.min(#self.snippets, self.cursor))
  end)
end

--- §4.9c: idempotent by contract, so this can sit on a timer.
function Playground:save()
  if not self.editor then return end
  local payload = {
    lang = self.lang,
    source = self.editor:text(),
  }
  if self.snippet_id then payload.id = self.snippet_id end
  if self.name then payload.name = self.name end

  self.app.session:request("playground.save", payload, function(ok, reply, why)
    if not ok then
      self.note = why.player
      return
    end
    local snippet = reply.snippet
    self.snippet_id = snippet.id
    self.name = snippet.name
    self.saved_at = Anim.now()
    self.editor.dirty = false
    self.dirty_at = nil
    self:list()
  end)
end

function Playground:load(index)
  local brief = self.snippets and self.snippets[index]
  if not brief then return end
  self.app.session:request("playground.load", { id = brief.id }, function(ok, payload, why)
    if not ok then self.note = why.player; return end
    local snippet = payload.snippet
    self.snippet_id = snippet.id
    self.name = snippet.name
    self.lang = snippet.lang
    self.editor:set_text(snippet.source or "")
    self.editor.dirty = false
    self.dirty_at = nil
    self.result = nil
    self.log = nil
    self.note = "opened " .. tostring(snippet.name)
    SFX.play("select")
  end)
end

function Playground:delete(index)
  local brief = self.snippets and self.snippets[index]
  if not brief then return end
  self.app.session:request("playground.delete", { id = brief.id }, function(ok, _, why)
    if not ok then self.note = why.player; return end
    if self.snippet_id == brief.id then
      self.snippet_id = nil
      self.name = nil
    end
    self.note = "deleted"
    self:list()
  end)
end

function Playground:new_snippet()
  self.snippet_id = nil
  self.name = nil
  self.editor:set_text(STARTER[self.lang])
  self.editor.dirty = false
  self.result = nil
  self.log = nil
  self.note = I18n.t("a fresh page")
  SFX.play("select")
end

function Playground:toggle_lang()
  for i, lang in ipairs(LANGS) do
    if lang == self.lang then
      self.lang = LANGS[i % #LANGS + 1]
      break
    end
  end
  -- Only swap the starter into a buffer nobody has touched; somebody's Rust
  -- must not vanish because they looked at what Go does.
  if not self.editor.dirty then
    self.editor:set_text(STARTER[self.lang])
    self.editor.dirty = false
  end
  self.note = self.lang:upper()
  SFX.play("move")
end

-- --------------------------------------------------------------------- run

function Playground:on_stage(payload)
  if self.attempt_id and payload.attempt_id ~= self.attempt_id then return end
  self.attempt_id = payload.attempt_id
  self.stage = payload.stage
  self.elapsed_ms = payload.elapsed_ms or 0
end

function Playground:on_log(payload)
  if not self.log or (self.log.attempt_id and payload.attempt_id ~= self.log.attempt_id) then
    self.log = runlog.new(payload.attempt_id)
  end
  self.log:add(payload)
end

function Playground:run()
  if self.running then return end
  self.running = true
  self.result = nil
  self.log = nil
  self.attempt_id = nil
  self.stage = "queued"
  self.elapsed_ms = 0
  self.note = nil
  self.problem = nil
  SFX.play("submit")

  self.app.session:request("playground.run", {
    lang = self.lang,
    source = self.editor:text(),
    stdin = self.stdin,
  }, function(ok, payload, why)
    self.running = false
    self.stage = nil
    if not ok then
      -- Still not the failure register: a refusal is about the request, not
      -- about the program.
      self.note = why.player
      return
    end
    self.result = payload.run
    -- No accepted/rejected chime either way. Nothing was judged.
    SFX.play("move")
  end)
end

function Playground:format()
  if not self.editor or self.formatting or self.format_unsupported then return end
  self.formatting = true
  self.note = nil
  self.problem = nil
  self.app.session:request("code.format", {
    lang = self.lang,
    source = self.editor:text(),
  }, function(ok, payload, why)
    self.formatting = false
    if not ok then
      if payload.code == "not_found" then
        self.format_unsupported = true
        self.note = I18n.t("FORMAT is not on this server yet")
      else
        self.note = why.player
      end
      return
    end
    if payload.problem and payload.problem ~= "" then
      self.problem = payload.problem
      return
    end
    if payload.changed == false then
      self.note = I18n.t("already tidy")
      return
    end
    self.editor:replace_all(payload.source or self.editor:text())
    self.note = "formatted"
  end)
end

function Playground:update(dt)
  self.t = self.t + dt
  if self.running then self.elapsed_ms = self.elapsed_ms + dt * 1000 end

  -- Autosave. The contract says `playground.save` is cheap and idempotent, so
  -- the only thing this has to avoid is sending on every keystroke.
  if self.editor and self.editor.dirty then
    self.dirty_at = self.dirty_at or Anim.now()
    if Anim.now() - self.dirty_at >= Playground.AUTOSAVE_S then
      self:save()
    end
  end
end

-- ------------------------------------------------------------------ drawing

--- The header band's height, measured from the two lines of type in it —
--- the same rule as `Quest:header_h`, for the same reason: it was a hard
--- 46 px, which fitted a 14 px title over a 7 px name, and at the doubled
--- ladder the name was printed through the title.
function Playground:header_h()
  return math.max(46, 8 + UI.lineHeight(14) + 2 + UI.lineHeight(7) + 8)
end

function Playground:panes()
  local vw, vh = Layout.vw, Layout.vh
  local top = self:header_h()
  local bottom = UI.footerHeight() + 8
  local pad = 10
  if Layout.isPortrait() then
    local h = vh - top - bottom
    return
      { x = pad, y = top, w = vw - pad * 2, h = math.floor(h * 0.52) },
      { x = pad, y = top + math.floor(h * 0.52) + pad, w = vw - pad * 2,
        h = h - math.floor(h * 0.52) - pad },
      { x = pad, y = top, w = 0, h = 0 }
  end
  -- Wide enough for its own title at the current type, never more than
  -- a third of the canvas: at the largest type step 18 % was six letters.
  local list_w = math.min(math.floor(vw * 0.3),
    math.max(190, UI.textWidth(I18n.t("SNIPPETS"), 8) + 40))
  local rest = vw - list_w - pad * 3
  return
    { x = pad + list_w + pad, y = top, w = math.floor(rest * 0.56), h = vh - top - bottom },
    { x = pad + list_w + pad + math.floor(rest * 0.56) + pad, y = top,
      w = rest - math.floor(rest * 0.56) - pad, h = vh - top - bottom },
    { x = pad, y = top, w = list_w, h = vh - top - bottom }
end

function Playground:draw()
  if self.big then return self:draw_big() end
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick(
    Layout.isPortrait() and "bg_playground_p" or "bg_playground",
    "bg_playground", "bg_datacentre", "bg_flat"), 0, 0, vw, vh)
  -- Lighter than every other screen's scrim. DESIGN made `bg_playground` and
  -- deliberately nothing else — it is the room the game opens in, and a dim
  -- that hid it would be drawing the one asset this screen has and then
  -- covering it up.
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.52)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local head = self:header_h()
  UI.setColor(Theme.ink, 0.9)
  love.graphics.rectangle("fill", 0, 0, vw, head)
  love.graphics.setColor(1, 1, 1, 1)
  local ty = 8 + UI.text(I18n.t("PLAYGROUND"), 12, 8, 14, Theme.cyan) + 2
  local shown = self.name and tostring(self.name) or I18n.t("unsaved")
  if self.focus == "name" then shown = (self.name_edit or "") .. "_" end
  UI.text(shown, 12, ty, 7,
    self.focus == "name" and Theme.coin or Theme.withAlpha(Theme.cream, 0.55))

  -- The language, as a toggle rather than a menu. Sized from its label and
  -- set at the display controls' height, with its key to the left of it —
  -- measured, so `TAB` is next to the button and not under it.
  local lh = UI.chipHeight()
  local lw = math.max(64, UI.textWidth(self.lang:upper(), UI.CHIP_SIZE) + 28)
  local lx = vw - lw - 12
  local ly = math.floor((head - lh) / 2)
  UI.button(lx, ly, lw, lh, self.lang:upper(), "normal", UI.CHIP_SIZE)
  self.lang_rect = { x = lx, y = ly, w = lw, h = lh }

  -- CODE and RENAME, left of the language. Laid right to left so they sit
  -- against it however wide their own labels measure, and dropped rather
  -- than overlapped when the header has no room for them — the name and the
  -- language are what this strip is for.
  local rx = lx - 8
  for _, item in ipairs({
    { id = "code", label = I18n.t("CODE") },
    { id = "rename", label = I18n.t("RENAME") },
  }) do
    local w = math.max(64, UI.textWidth(item.label, UI.CHIP_SIZE) + 24)
    if rx - w < 200 then break end
    rx = rx - w
    UI.button(rx, ly, w, lh, item.label, "normal", UI.CHIP_SIZE)
    if item.id == "code" then
      self.code_button_rect = { x = rx, y = ly, w = w, h = lh }
    else
      self.rename_rect = { x = rx, y = ly, w = w, h = lh }
    end
    rx = rx - 8
  end
  local tab = I18n.t("TAB")
  local tab_x = lx - UI.textWidth(tab, 7) - 8
  local cap_y = math.floor((head - UI.lineHeight(7)) / 2)
  UI.text(tab, tab_x, cap_y, 7, Theme.withAlpha(Theme.cream, 0.4))

  if self.saved_at and Anim.now() - self.saved_at < 2.2 then
    local text = "saved"
    UI.text(text, tab_x - UI.textWidth(text, 7) - 10, cap_y, 7,
      Theme.withAlpha(Theme.admit, 0.9))
  end

  local code, out, list = self:panes()
  if list.w > 0 then self:draw_snippets(list) end
  self:draw_code(code)
  self:draw_output(out)

  self.app:footer(I18n.t("F5 run   F2 format   TAB lang   CTRL-S save   CTRL-N new   ESC back"))
end

--- CODE: one strip of controls, and the editor under it.
---
--- The display chips are the footer's, which every screen draws, so
--- fullscreen and orientation are here without this screen owning them.
function Playground:draw_big()
  local vw, vh = Layout.vw, Layout.vh
  Assets.cover(Assets.pick(
    Layout.isPortrait() and "bg_playground_p" or "bg_playground",
    "bg_playground", "bg_datacentre", "bg_flat"), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.72)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local pad = 8
  local bh = UI.chipHeight()
  local cap_h = UI.lineHeight(7)

  -- DONE in the corner, then the writing controls from the left. Measured
  -- from the widest label each can wear so a button does not change width
  -- when its own state changes.
  local done = I18n.t("DONE")
  local dw = math.max(72, UI.textWidth(done, 8) + 20)
  local dx = vw - dw - pad

  local items = {
    -- Literals, as the framed strip has them: these are key names with a
    -- word in front, and the suite asks for a translation of every string
    -- that goes through `I18n.t`.
    { id = "run", label = self.running and "RUNNING…" or "RUN  F5",
      every = { "RUNNING…", "RUN  F5" },
      state = self.running and "disabled" or "hot" },
    { id = "format", label = self.formatting and "…" or "FORMAT F2",
      every = { "FORMAT F2" },
      state = self.format_unsupported and "disabled" or "normal" },
    { id = "save", label = I18n.t("SAVE"), every = { I18n.t("SAVE") }, state = "normal" },
    { id = "rename", label = I18n.t("RENAME"), every = { I18n.t("RENAME") }, state = "normal" },
    -- In and out of the screen. Nothing on a canvas can be selected with a
    -- mouse, so without these the code and the compiler's answer cannot leave
    -- it at all -- which is what somebody pasting into an assistant and
    -- pasting the reply back needs.
    { id = "copycode", label = I18n.t("COPY CODE"), every = { I18n.t("COPY CODE") },
      state = "normal" },
    { id = "pastecode", label = I18n.t("PASTE"), every = { I18n.t("PASTE") }, state = "normal" },
    { id = "copyout", label = I18n.t("COPY OUTPUT"), every = { I18n.t("COPY OUTPUT") },
      -- Parenthesised, and it matters: `a or b and c or d` binds as
      -- `a or ((b and c) or d)`, so after a run this handed `UI.button` the
      -- result *table* where it wanted the word "normal".
      state = (self.result or self.log) and "normal" or "disabled" },
    { id = "pastein", label = I18n.t("PASTE INPUT"), every = { I18n.t("PASTE INPUT") },
      state = "normal" },
    { id = "lang", label = self.lang:upper(), every = { "PYTHON" }, state = "normal" },
  }
  -- **Wrapped, not truncated.** The row used to stop at the first button that
  -- did not fit and simply never draw the rest: at eleven controls that is
  -- most of them, gone with no way to reach what they do.
  -- **Two rows at most, and the type gives way before the editor does.**
  -- Eleven controls at the caption size is three rows on a 1000-wide window,
  -- and three rows of chrome is the whole of what CODE was built to hand to
  -- the code: the drive measured it giving the editor no more room than the
  -- framed screen did. So the labels shrink a step at a time until the band
  -- is two rows, exactly as the bench sheds buttons.
  local size, rows = 8, {}
  local function lay(at)
    local out, line, bx = {}, {}, pad
    for _, item in ipairs(items) do
      local w = 0
      for _, label in ipairs(item.every) do w = math.max(w, UI.textWidth(label, at) + 16) end
      -- The first row keeps clear of DONE in the corner; the rest have it all.
      local limit = (#out == 0) and (dx - pad) or (vw - pad)
      if #line > 0 and bx + w > limit then
        out[#out + 1] = line
        line, bx = {}, pad
      end
      line[#line + 1] = { item = item, w = w, x = bx }
      bx = bx + w + 6
    end
    if #line > 0 then out[#out + 1] = line end
    return out
  end
  rows = lay(size)
  while #rows > 2 and size > 5 do
    size = size - 1
    rows = lay(size)
  end

  local band = #rows * bh + (#rows - 1) * 6
  local strip = pad + math.max(band, bh) + 3 + cap_h + 4
  UI.setColor(Theme.ink, 0.86)
  love.graphics.rectangle("fill", 0, 0, vw, strip)
  UI.setColor(Theme.withAlpha(Theme.dim, 0.5))
  love.graphics.rectangle("fill", 0, strip, vw, 1)
  love.graphics.setColor(1, 1, 1, 1)

  UI.button(dx, pad, dw, bh, done, "normal", 8)
  self.done_rect = { x = dx, y = pad, w = dw, h = bh }

  self.big_rects = {}
  for ri, r in ipairs(rows) do
    local by = pad + (ri - 1) * (bh + 6)
    for _, cell in ipairs(r) do
      UI.button(cell.x, by, cell.w, bh, cell.item.label, cell.item.state, size)
      self.big_rects[cell.item.id] = { x = cell.x, y = by, w = cell.w, h = bh }
    end
  end

  -- Which file, what it is called, and whether it is safe on the server.
  local name = self.name and tostring(self.name) or I18n.t("unsaved")
  if self.focus == "name" then name = (self.name_edit or "") .. "_" end
  local info = ("%s   %s%s"):format(self.lang:upper(), name,
    self.editor.dirty and "   ·" or "")
  UI.text(info, pad + 4, pad + math.max(band, bh) + 3, 7,
    self.focus == "name" and Theme.coin or Theme.withAlpha(Theme.cream, 0.5))

  -- **Beside the code when the window is wide, under it when it is tall.**
  -- A landscape window has width to spare and height to spare nothing: output
  -- stacked under the editor there costs a quarter of the few lines the screen
  -- has. Upright it is the other way round, and a column of output beside the
  -- code would be too narrow to read a compiler error in.
  local top = strip + 6
  local body_w, body_h = vw - pad * 2, vh - top - UI.footerHeight() - 6
  local has_out = (self.result ~= nil) or (self.log ~= nil) or self.running
  local side = not Layout.isPortrait() and has_out
  if side then
    local out_w = math.floor(body_w * 0.38)
    self:draw_code({ x = pad, y = top, w = body_w - out_w - pad, h = body_h }, true)
    self:draw_output({ x = pad + body_w - out_w, y = top, w = out_w, h = body_h })
  elseif has_out then
    local out_h = math.floor(body_h * 0.28)
    self:draw_code({ x = pad, y = top, w = body_w, h = body_h - out_h - pad }, true)
    self:draw_output({ x = pad, y = top + body_h - out_h, w = body_w, h = out_h })
  else
    self:draw_code({ x = pad, y = top, w = body_w, h = body_h }, true)
  end

  self.app:footer(I18n.t("F5 run   F2 format   TAB lang   CTRL-S save   CTRL-N new   ESC back"))
end

function Playground:draw_snippets(rect)
  UI.panel(rect.x, rect.y, rect.w, rect.h, {
    fill = Theme.withAlpha(Theme.navy, 0.9),
    tint = self.focus == "snippets" and Theme.coin or Theme.cyan,
  })
  UI.text(I18n.t("SNIPPETS"), rect.x + 10, rect.y + 8,
    UI.fitSize(I18n.t("SNIPPETS"), rect.w - 20, 8, 5), Theme.withAlpha(Theme.cream, 0.7))
  local y = rect.y + 8 + UI.lineHeight(8) + 6
  -- A row is the label's own height plus air: `20` was the row at a 7 px
  -- label, and at the doubled ladder the names printed over each other.
  local row = UI.lineHeight(7) + 6

  -- The search field, once there are enough pads to be worth hunting through.
  self.find_rect = nil
  if self:searchable() then
    local fh = UI.lineHeight(7) + 8
    UI.setColor(Theme.void, 0.9)
    love.graphics.rectangle("fill", rect.x + 6, y, rect.w - 12, fh)
    love.graphics.setLineWidth(2)
    UI.setColor(self.focus == "find" and Theme.coin or Theme.withAlpha(Theme.cream, 0.3))
    love.graphics.rectangle("line", rect.x + 7, y + 1, rect.w - 14, fh - 2)
    love.graphics.setColor(1, 1, 1, 1)
    local shown = (self.query or "") ~= "" and self.query or I18n.t("SEARCH")
    if self.focus == "find" then shown = (self.query or "") .. "_" end
    UI.text(shown, rect.x + 12, y + 4, 7,
      (self.query or "") ~= "" and Theme.cream or Theme.withAlpha(Theme.cream, 0.45))
    self.find_rect = { x = rect.x + 6, y = y, w = rect.w - 12, h = fh }
    y = y + fh + 6
  end

  self.snippet_rects = {}
  for _, hit in ipairs(self:visible_snippets()) do
    local i, brief = hit.index, hit.brief
    if y > rect.y + rect.h - row - 2 then break end
    local here = brief.id == self.snippet_id
    if here then
      UI.setColor(Theme.coin, 0.22)
      love.graphics.rectangle("fill", rect.x + 4, y - 2, rect.w - 8, row)
      love.graphics.setColor(1, 1, 1, 1)
    end
    local label = tostring(brief.name or brief.id)
    while UI.textWidth(label, 7) > rect.w - 24 and #label > 3 do
      label = label:sub(1, -2)
    end
    UI.text(label, rect.x + 10, y, 7,
      here and Theme.coin or Theme.withAlpha(Theme.cream, 0.85))
    UI.text(tostring(brief.lang):sub(1, 1):upper(), rect.x + rect.w - 14, y, 7,
      Theme.withAlpha(Theme.cream, 0.4))
    self.snippet_rects[i] = { x = rect.x, y = y - 2, w = rect.w, h = row }
    y = y + row
  end
  if not self.snippets then
    UI.text("…", rect.x + 10, y, 8, Theme.dim)
  elseif #self.snippets == 0 then
    UI.paragraph(I18n.t("nothing saved yet"), rect.x + 10, y, rect.w - 20, 7,
      Theme.withAlpha(Theme.cream, 0.45))
  elseif #self:visible_snippets() == 0 then
    UI.paragraph(I18n.t("no pad by that name"), rect.x + 10, y, rect.w - 20, 7,
      Theme.withAlpha(Theme.cream, 0.45))
  end
  UI.text(I18n.t("CTRL-N new"), rect.x + 10, rect.y + rect.h - 8 - UI.lineHeight(7),
    UI.fitSize(I18n.t("CTRL-N new"), rect.w - 20, 7, 4),
    Theme.withAlpha(Theme.cream, 0.4))
end

--- The editor.
---
--- `bare` leaves off the strip under it — the stdin field, RUN and FORMAT and
--- the line count — because in CODE those controls are along the top and the
--- whole of the rest of the window is for the code.
function Playground:draw_code(rect, bare)
  UI.well(rect.x, rect.y, rect.w, rect.h,
    self.focus == "editor" and Theme.coin or Theme.cyan)

  local font = Assets.mono(Layout.codeSize(18))
  local line_h = font:getHeight()
  -- The trailing space is not decoration: `%4d` right-aligns, so without
  -- it the last digit of the line number touches the first character of an
  -- unindented line and `1` reads as part of `fn`.
  local gutter = font:getWidth("0000 ")
  -- The strip under the code — the stdin field, the two buttons, and the
  -- line count — measured from what is in it. It was a hard 64 px: a 7 px
  -- caption over a 22 px field and a 24 px button, and at the doubled ladder
  -- the caption printed through the field and `FORMAT F2` wrapped inside
  -- its own button.
  local cap_h = UI.lineHeight(7)
  local field_font = Assets.mono(Layout.ui(8))
  local field_h = field_font:getHeight() + 6
  local bh = UI.chipHeight()
  local row_h = math.max(field_h, bh)
  local strip = 6 + cap_h + 2 + row_h + 4 + cap_h + 6
  if bare then strip = 0 end
  local rows = math.max(1, math.floor((rect.h - strip - 12) / line_h))
  self.editor:ensure_visible(rows)
  self.visible_rows = rows
  self.code_rect = rect
  self.line_h = line_h
  self.gutter = gutter
  self.mono_font = font

  love.graphics.setScissor(rect.x + 3, rect.y + 3, rect.w - 6, rect.h - strip - 6)
  love.graphics.setFont(font)
  local x0, y0 = rect.x + 8, rect.y + 6
  self.pane:frame(rect, font, gutter, x0, y0, line_h, rows)
  local state = "code"
  for i = 1, self.editor.scroll do
    _, state = Editor.highlight(self.editor.lines[i] or "", state)
  end
  local sel_l1, sel_c1, sel_l2, sel_c2 = self.editor:selection()

  for row = 1, rows do
    local index = self.editor.scroll + row
    local line = self.editor.lines[index]
    if not line then break end
    local y = y0 + (row - 1) * line_h
    if index == self.editor.line then
      UI.setColor(Theme.cream, 0.06)
      love.graphics.rectangle("fill", rect.x + 3, y, rect.w - 6, line_h)
    end
    if sel_l1 and index >= sel_l1 and index <= sel_l2 then
      local from = (index == sel_l1) and sel_c1 or 1
      local to = (index == sel_l2) and sel_c2 or (#line + 1)
      local sx = x0 + gutter + font:getWidth(line:sub(1, from - 1))
      UI.setColor(Theme.coin, 0.28)
      love.graphics.rectangle("fill", sx, y,
        math.max(2, font:getWidth(line:sub(from, to - 1))), line_h)
    end
    UI.setColor(self.pane:gutter_color(index))
    love.graphics.print(("%4d"):format(index), x0, y)
    local spans
    spans, state = Editor.highlight(line, state)
    local cx = x0 + gutter
    for _, span in ipairs(spans) do
      UI.setColor(Theme.code[span.kind] or Theme.cream)
      love.graphics.print(span.text, cx, y)
      cx = cx + font:getWidth(span.text)
    end
    if index == self.editor.line and self.focus == "editor"
      and (love.timer.getTime() * 2) % 2 < 1.2 then
      UI.setColor(Theme.coin)
      love.graphics.rectangle("fill",
        x0 + gutter + font:getWidth(line:sub(1, self.editor.col - 1)), y, 2, line_h)
    end
  end
  self.pane:draw_brackets()
  love.graphics.setScissor()
  love.graphics.setColor(1, 1, 1, 1)

  if bare then
    -- Nothing below the code: the rects the strip would have set must not
    -- survive from the framed layout, or a tap lands on a button that is not
    -- on the screen.
    self.stdin_rect, self.run_rect, self.format_rect = nil, nil, nil
    return
  end

  -- stdin, and the buttons. The buttons are as wide as the widest label
  -- they can wear, so RUN and RUNNING… are the same button.
  local strip_top = rect.y + rect.h - strip
  UI.text(I18n.t("STDIN"), rect.x + 8, strip_top + 6, 7, Theme.withAlpha(Theme.cream, 0.5))
  local sy = strip_top + 6 + cap_h + 2
  local bw = 0
  for _, label in ipairs({ "RUN  F5", "RUNNING…", "FORMAT F2" }) do
    bw = math.max(bw, UI.textWidth(label, 8) + 20)
  end
  -- Never wider than half the pane: the pair used to run off its left
  -- edge, and `UI.button` fits the label to whatever width this leaves.
  bw = math.min(bw, math.floor((rect.w - 24) / 2))
  local field_w = math.max(60, rect.w - 12 - (bw * 2 + 16))
  local fy = sy + math.floor((row_h - field_h) / 2)
  UI.setColor(Theme.void, 0.9)
  love.graphics.rectangle("fill", rect.x + 6, fy, field_w, field_h)
  love.graphics.setLineWidth(2)
  UI.setColor(self.focus == "stdin" and Theme.coin or Theme.withAlpha(Theme.cream, 0.3))
  love.graphics.rectangle("line", rect.x + 7, fy + 1, field_w - 2, field_h - 2)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(field_font)
  UI.setColor(Theme.cream)
  love.graphics.print((self.stdin:gsub("\n", "⏎")), rect.x + 12, fy + 3)
  love.graphics.setColor(1, 1, 1, 1)
  self.stdin_rect = { x = rect.x + 6, y = fy, w = field_w, h = field_h }

  local by = sy + math.floor((row_h - bh) / 2)
  local rx = rect.x + rect.w - bw - 8
  UI.button(rx, by, bw, bh, self.running and "RUNNING…" or "RUN  F5",
    self.running and "disabled" or "hot", 8)
  self.run_rect = { x = rx, y = by, w = bw, h = bh }
  local fx = rx - bw - 8
  UI.button(fx, by, bw, bh, self.formatting and "…" or "FORMAT F2",
    self.format_unsupported and "disabled" or "normal", 8)
  self.format_rect = { x = fx, y = by, w = bw, h = bh }

  local info = I18n.t("%d lines   %d bytes%s",
    self.editor:line_count(), #self.editor:text(),
    self.editor.dirty and "   ·" or "")
  UI.text(info, rect.x + 8, sy + row_h + 4, 7, Theme.withAlpha(Theme.cream, 0.4))
end

--- What the program did.
---
--- Deliberately flat: one outcome line, then stdout, then stderr. No banner,
--- no verdict colour, no red. §4.9c — nothing here is scored, and this is
--- where somebody writes something broken on purpose to see what the compiler
--- says.
function Playground:draw_output(rect)
  -- Kept for the drives: where this pane landed is the only way a test can
  -- ask whether it went beside the code or under it.
  self.out_rect = rect
  UI.well(rect.x, rect.y, rect.w, rect.h, Theme.cyan)
  local font = Assets.mono(Layout.codeSize(16))
  local line_h = font:getHeight()
  local y = rect.y + 8

  local head, colour
  if self.running then
    head = ("%s…  %dms"):format(tostring(self.stage or "queued"), math.floor(self.elapsed_ms))
    colour = Theme.coin
  elseif self.result then
    head = ("%s   %dms compile   %dms run   exit %s"):format(
      I18n.t(OUTCOME[self.result.outcome] or tostring(self.result.outcome)),
      self.result.compile_ms or 0, self.result.run_ms or 0,
      self.result.exit_code == nil and "-" or tostring(self.result.exit_code))
    -- `ok` gets a quiet green; everything else gets **cream**, not red. What
    -- happened is information, and the register is a terminal's, not a
    -- verdict screen's.
    colour = self.result.outcome == "ok" and Theme.admit
      or Theme.withAlpha(Theme.cream, 0.85)
  else
    head = I18n.t("nothing has run yet")
    colour = Theme.withAlpha(Theme.cream, 0.45)
  end
  -- Every advance below is the line's own height: the constants they
  -- replace (18, 10, 12) were written against 7 and 8 px type, and at the
  -- doubled ladder each line was printed through the one above it.
  local small = UI.lineHeight(7) + 2
  y = y + UI.paragraph(head, rect.x + 10, y, rect.w - 20, 8, colour) + 4

  if self.problem then
    for _, line in ipairs(UI.wrap(self.problem, rect.w - 24, 7)) do
      UI.text(line, rect.x + 10, y, 7, Theme.coin)
      y = y + small
    end
  elseif self.note then
    for _, line in ipairs(UI.wrap(self.note, rect.w - 24, 7)) do
      UI.text(line, rect.x + 10, y, 7, Theme.withAlpha(Theme.cyan, 0.9))
      y = y + small
    end
  end

  love.graphics.setScissor(rect.x + 4, y, rect.w - 8, rect.y + rect.h - y - 6)
  love.graphics.setFont(font)

  local function block(label, text, alpha)
    if not text or text == "" then return end
    y = y + UI.text(label, rect.x + 10, y, 7, Theme.withAlpha(Theme.cream, 0.4)) + 4
    love.graphics.setFont(font)
    UI.setColor(Theme.cream, alpha)
    for line in (text .. "\n"):gmatch("(.-)\n") do
      love.graphics.print(line, rect.x + 10, y)
      y = y + line_h
    end
    love.graphics.setColor(1, 1, 1, 1)
    y = y + 6
  end

  if self.result then
    block("STDOUT", self.result.stdout, 1)
    block("STDERR", self.result.stderr, 0.8)
    if self.result.diagnostics and #self.result.diagnostics > 0 then
      y = y + UI.text(I18n.t("WHAT THE COMPILER SAID"), rect.x + 10, y, 7,
        Theme.withAlpha(Theme.cream, 0.4)) + 4
      for _, d in ipairs(self.result.diagnostics) do
        local head_line = ("%s%s"):format(d.kind or "",
          d.code and (" [" .. d.code .. "]") or "")
        UI.text(head_line, rect.x + 10, y, 7, Theme.withAlpha(Theme.cyan, 0.9))
        y = y + small
        for _, line in ipairs(UI.wrap(d.message or "", rect.w - 34, 7)) do
          UI.text("  " .. line, rect.x + 10, y, 7, Theme.withAlpha(Theme.cream, 0.8))
          y = y + small
        end
        if d.line then
          UI.text(("  line %d%s"):format(d.line, d.col and (":" .. d.col) or ""),
            rect.x + 10, y, 7, Theme.withAlpha(Theme.cream, 0.45))
          y = y + small
        end
        y = y + 4
      end
    end
  elseif self.log then
    -- Streaming, before the reply lands.
    for _, name in ipairs(self.log.order) do
      local lines, tail = self.log:lines(name)
      for _, line in ipairs(lines) do
        love.graphics.setFont(font)
        UI.setColor(Theme.cream, 0.85)
        love.graphics.print(line, rect.x + 10, y)
        y = y + line_h
      end
      if tail ~= "" then
        love.graphics.print(tail, rect.x + 10, y)
        y = y + line_h
      end
    end
  end
  love.graphics.setScissor()
  love.graphics.setColor(1, 1, 1, 1)
end

-- -------------------------------------------------------------------- input

function Playground:textinput(text)
  if self.focus == "name" then
    if self.name_fresh then self.name_edit, self.name_fresh = "", false end
    if #(self.name_edit or "") < 48 then self.name_edit = (self.name_edit or "") .. text end
  elseif self.focus == "find" then
    if #(self.query or "") < 48 then self.query = (self.query or "") .. text end
  elseif self.focus == "editor" then
    self.editor:textinput(text)
    SFX.play("type")
  elseif self.focus == "stdin" then
    self.stdin = self.stdin .. text
  end
end

--- Open the name field, with what it is called already in it.
---
--- `name_fresh` is the browser client's "arrives selected": the first thing
--- typed replaces the name, and backspace or an arrow key keeps it to edit.
--- There is no selection to draw here, so the flag is the whole of it.
function Playground:start_rename()
  self.focus = "name"
  self.name_edit = self.name and tostring(self.name) or ""
  self.name_fresh = true
end

--- The pads the list is showing: all of them, or those the query matches.
---
--- Each carries the index it has in `self.snippets`, because `load` takes a
--- position in that list and a filtered view would otherwise open the wrong
--- pad the moment anything was typed.
function Playground:visible_snippets()
  local out = {}
  local q = (self.query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  for i, brief in ipairs(self.snippets or {}) do
    local name = tostring(brief.name or brief.id):lower()
    if q == "" or name:find(q, 1, true) then
      out[#out + 1] = { index = i, brief = brief }
    end
  end
  return out
end

--- Whether the box is worth its row. Four pads are read in one glance.
function Playground:searchable()
  return #(self.snippets or {}) >= 5 or (self.query or "") ~= ""
end

--- What the run said, as text somebody can paste somewhere else.
---
--- Canvas output is pixels: nothing in that pane can be selected with a
--- mouse, so this is the only way a compiler error leaves the screen — which
--- is the thing somebody wants to hand to an assistant and ask about.
function Playground:output_text()
  local out = {}
  local r = self.result
  if r then
    out[#out + 1] = ("%s   %dms compile   %dms run   exit %s"):format(
      I18n.t(OUTCOME[r.outcome] or tostring(r.outcome)),
      r.compile_ms or 0, r.run_ms or 0,
      r.exit_code == nil and "-" or tostring(r.exit_code))
    if r.stdout and r.stdout ~= "" then
      out[#out + 1] = ""
      out[#out + 1] = "STDOUT"
      out[#out + 1] = r.stdout
    end
    if r.stderr and r.stderr ~= "" then
      out[#out + 1] = ""
      out[#out + 1] = "STDERR"
      out[#out + 1] = r.stderr
    end
    for _, d in ipairs(r.diagnostics or {}) do
      out[#out + 1] = ("%s%s %s"):format(d.kind or "",
        d.code and (" [" .. d.code .. "]") or "", d.message or "")
    end
  elseif self.log then
    for _, name in ipairs(self.log.order) do
      local lines, tail = self.log:lines(name)
      for _, line in ipairs(lines) do out[#out + 1] = line end
      if tail ~= "" then out[#out + 1] = tail end
    end
  end
  return (table.concat(out, "\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Copy and paste: the two halves of working with something else.
function Playground:clip(which)
  if which == "code" then
    love.system.setClipboardText(self.editor and self.editor:text() or "")
    self.note = I18n.t("copied")
  elseif which == "out" then
    local text = self:output_text()
    if text == "" then self.note = I18n.t("nothing has run yet"); return end
    love.system.setClipboardText(text)
    self.note = I18n.t("copied")
  elseif which == "in" then
    self.stdin = love.system.getClipboardText() or ""
    self.note = I18n.t("pasted")
  elseif which == "paste" and self.editor then
    local text = love.system.getClipboardText() or ""
    if text == "" then self.note = I18n.t("the clipboard is empty"); return end
    self.editor:set_text(text)
    self.editor.dirty = true
    self.note = I18n.t("pasted")
  end
  SFX.play("select")
end

--- Take what is in the field, if it is anything, and save under it.
function Playground:commit_rename()
  local want = (self.name_edit or ""):gsub("^%s+", ""):gsub("%s+$", "")
  self.focus = "editor"
  self.name_edit = nil
  if want == "" or want == self.name then return end
  self.name = want
  self.editor.dirty = true
  self:save()
  SFX.play("select")
end

function Playground:keypressed(key, mods)
  mods = mods or {}
  local cmd = mods.ctrl or mods.gui

  -- The name field owns every key while it is open: a rename that ran F5
  -- because the name has an "f5" in it would be a field nobody trusts.
  if self.focus == "find" then
    if key == "backspace" then
      self.query = (self.query or ""):sub(1, -2)
    elseif key == "escape" then
      self.query, self.focus = "", "editor"
    elseif key == "return" or key == "kpenter" then
      -- Enter opens the only match, which is what a search box that found
      -- one thing should do.
      local hits = self:visible_snippets()
      if #hits > 0 then self:load(hits[1].index) end
      self.focus = "editor"
    end
    return true
  end

  if self.focus == "name" then
    -- Backspace edits what is there rather than clearing it: the whole name
    -- being "selected" means the first *character* replaces it, not the first
    -- key of any kind.
    self.name_fresh = false
    if key == "backspace" then
      self.name_edit = (self.name_edit or ""):sub(1, -2)
    elseif key == "return" or key == "kpenter" then
      self:commit_rename()
    elseif key == "escape" then
      self.focus, self.name_edit = "editor", nil
    end
    return true
  end

  if key == "f5" or (cmd and not mods.shift and (key == "return" or key == "kpenter")) then
    self:run(); return true
  end
  if key == "f2" then self:format(); return true end
  if cmd and key == "s" then self:save(); SFX.play("select"); return true end
  if cmd and key == "n" then self:new_snippet(); return true end
  if key == "tab" and not cmd and self.focus ~= "editor" then
    self:toggle_lang(); return true
  end
  if cmd and key == "tab" then
    self.focus = ({ editor = "stdin", stdin = "snippets", snippets = "editor" })[self.focus]
    return true
  end

  if self.focus == "stdin" then
    if key == "backspace" then self.stdin = self.stdin:sub(1, -2); return true end
    if key == "return" or key == "kpenter" then self.stdin = self.stdin .. "\n"; return true end
    if key == "escape" then self.focus = "editor"; return true end
    return true
  end

  if self.focus == "snippets" then
    local n = #(self.snippets or {})
    if key == "up" then self.cursor = math.max(1, self.cursor - 1); return true end
    if key == "down" then self.cursor = math.min(n, self.cursor + 1); return true end
    if key == "return" or key == "kpenter" then self:load(self.cursor); return true end
    if key == "delete" or key == "backspace" then self:delete(self.cursor); return true end
    if key == "escape" then self.focus = "editor"; return true end
    return true
  end

  -- In CODE, ESC is the way back to the framed screen, not out of it: the
  -- mode is a place you are, and the key that leaves a place leaves the
  -- innermost one first.
  if key == "escape" and self.big then
    self.big = false
    SFX.play("select")
    return true
  end

  if self.editor:keypressed(key, mods) then return true end
  return false
end

function Playground:wheelmoved(_, dy)
  if self.focus == "editor" then
    self.editor:scroll_by(-dy * 3, self.visible_rows or 20)
  end
end

function Playground:mousepressed(x, y, button)
  local function inside(r)
    return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
  end
  if self.big then
    if inside(self.done_rect) then self.big = false; SFX.play("select"); return end
    local r = self.big_rects or {}
    if inside(r.run) then self:run(); return end
    if inside(r.format) then self:format(); return end
    if inside(r.save) then self:save(); SFX.play("select"); return end
    if inside(r.rename) then self:start_rename(); return end
    if inside(r.copycode) then self:clip("code"); return end
    if inside(r.pastecode) then self:clip("paste"); return end
    if inside(r.copyout) then self:clip("out"); return end
    if inside(r.pastein) then self:clip("in"); return end
    if inside(r.lang) then self:toggle_lang(); return end
    local shift = love.keyboard.isDown("lshift", "rshift")
    if self.pane:mousepressed(x, y, button, shift) then self.focus = "editor" end
    return
  end
  if inside(self.find_rect) then self.focus = "find"; return end
  if inside(self.code_button_rect) then self.big = true; SFX.play("select"); return end
  if inside(self.rename_rect) then self:start_rename(); return end
  if inside(self.lang_rect) then self:toggle_lang(); return end
  if inside(self.run_rect) then self:run(); return end
  if inside(self.format_rect) then self:format(); return end
  if inside(self.stdin_rect) then self.focus = "stdin"; return end
  for i, rect in pairs(self.snippet_rects or {}) do
    if inside(rect) then
      self.focus = "snippets"
      if self.cursor == i then self:load(i) else self.cursor = i end
      return
    end
  end
  -- Both shifts: the old hit test asked for the left one only.
  local shift = love.keyboard.isDown("lshift", "rshift")
  if self.pane:mousepressed(x, y, button, shift) then
    self.focus = "editor"
    return
  end
  if inside(select(1, self:panes())) then self.focus = "editor" end
end

function Playground:mousemoved(x, y)
  if self.pane then self.pane:mousemoved(x, y) end
end

function Playground:mousereleased()
  if self.pane then self.pane:mousereleased() end
end

return Playground
