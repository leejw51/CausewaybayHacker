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

local LANGS = { "rust", "go" }

local STARTER = {
  rust = 'fn main() {\n    println!("hello");\n}\n',
  go = 'package main\n\nimport "fmt"\n\nfunc main() {\n\tfmt.Println("hello")\n}\n',
}

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

function Playground:panes()
  local vw, vh = Layout.vw, Layout.vh
  local top, bottom = 46, 54
  local pad = 10
  if Layout.isPortrait() then
    local h = vh - top - bottom
    return
      { x = pad, y = top, w = vw - pad * 2, h = math.floor(h * 0.52) },
      { x = pad, y = top + math.floor(h * 0.52) + pad, w = vw - pad * 2,
        h = h - math.floor(h * 0.52) - pad },
      { x = pad, y = top, w = 0, h = 0 }
  end
  local list_w = math.min(190, math.floor(vw * 0.18))
  local rest = vw - list_w - pad * 3
  return
    { x = pad + list_w + pad, y = top, w = math.floor(rest * 0.56), h = vh - top - bottom },
    { x = pad + list_w + pad + math.floor(rest * 0.56) + pad, y = top,
      w = rest - math.floor(rest * 0.56) - pad, h = vh - top - bottom },
    { x = pad, y = top, w = list_w, h = vh - top - bottom }
end

function Playground:draw()
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

  UI.setColor(Theme.ink, 0.9)
  love.graphics.rectangle("fill", 0, 0, vw, 46)
  love.graphics.setColor(1, 1, 1, 1)
    UI.text(I18n.t("PLAYGROUND"), 12, 8, 14, Theme.cyan)
  UI.text(self.name and tostring(self.name) or "unsaved", 12, 28, 7,
    Theme.withAlpha(Theme.cream, 0.55))

  -- The language, as a toggle rather than a menu.
  local lw = 64
  local lx = vw - lw - 12
  UI.button(lx, 8, lw, 28, self.lang:upper(), "normal", 9)
  self.lang_rect = { x = lx, y = 8, w = lw, h = 28 }
  UI.text(I18n.t("TAB"), lx - 26, 16, 7, Theme.withAlpha(Theme.cream, 0.4))

  if self.saved_at and Anim.now() - self.saved_at < 2.2 then
    local text = "saved"
    UI.text(text, lx - 26 - UI.textWidth(text, 7) - 10, 16, 7,
      Theme.withAlpha(Theme.admit, 0.9))
  end

  local code, out, list = self:panes()
  if list.w > 0 then self:draw_snippets(list) end
  self:draw_code(code)
  self:draw_output(out)

  self.app:footer(I18n.t("F5 run   F2 format   TAB lang   CTRL-S save   CTRL-N new   ESC back"))
end

function Playground:draw_snippets(rect)
  UI.panel(rect.x, rect.y, rect.w, rect.h, {
    fill = Theme.withAlpha(Theme.navy, 0.9),
    tint = self.focus == "snippets" and Theme.coin or Theme.cyan,
  })
  UI.text(I18n.t("SNIPPETS"), rect.x + 10, rect.y + 8, 8, Theme.withAlpha(Theme.cream, 0.7))
  local y = rect.y + 26
  self.snippet_rects = {}
  for i, brief in ipairs(self.snippets or {}) do
    if y > rect.y + rect.h - 22 then break end
    local here = brief.id == self.snippet_id
    if here then
      UI.setColor(Theme.coin, 0.22)
      love.graphics.rectangle("fill", rect.x + 4, y - 2, rect.w - 8, 20)
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
    self.snippet_rects[i] = { x = rect.x, y = y - 2, w = rect.w, h = 20 }
    y = y + 20
  end
  if not self.snippets then
    UI.text("…", rect.x + 10, y, 8, Theme.dim)
  elseif #self.snippets == 0 then
    UI.text(I18n.t("nothing saved yet"), rect.x + 10, y, 7, Theme.withAlpha(Theme.cream, 0.45))
  end
  UI.text(I18n.t("CTRL-N new"), rect.x + 10, rect.y + rect.h - 16, 7,
    Theme.withAlpha(Theme.cream, 0.4))
end

function Playground:draw_code(rect)
  UI.well(rect.x, rect.y, rect.w, rect.h,
    self.focus == "editor" and Theme.coin or Theme.cyan)

  local font = Assets.mono(Layout.codeSize(18))
  local line_h = font:getHeight()
  -- The trailing space is not decoration: `%4d` right-aligns, so without
  -- it the last digit of the line number touches the first character of an
  -- unindented line and `1` reads as part of `fn`.
  local gutter = font:getWidth("0000 ")
  local rows = math.max(1, math.floor((rect.h - 64) / line_h))
  self.editor:ensure_visible(rows)
  self.visible_rows = rows
  self.code_rect = rect
  self.line_h = line_h
  self.gutter = gutter
  self.mono_font = font

  love.graphics.setScissor(rect.x + 3, rect.y + 3, rect.w - 6, rect.h - 60)
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

  -- stdin, and the buttons.
  local sy = rect.y + rect.h - 52
  UI.text(I18n.t("STDIN"), rect.x + 8, sy - 10, 7, Theme.withAlpha(Theme.cream, 0.5))
  UI.setColor(Theme.void, 0.9)
  love.graphics.rectangle("fill", rect.x + 6, sy, rect.w - 210, 22)
  love.graphics.setLineWidth(2)
  UI.setColor(self.focus == "stdin" and Theme.coin or Theme.withAlpha(Theme.cream, 0.3))
  love.graphics.rectangle("line", rect.x + 7, sy + 1, rect.w - 212, 20)
  love.graphics.setColor(1, 1, 1, 1)
  local small = Assets.mono(15)
  love.graphics.setFont(small)
  UI.setColor(Theme.cream)
  love.graphics.print((self.stdin:gsub("\n", "⏎")), rect.x + 12, sy + 3)
  love.graphics.setColor(1, 1, 1, 1)
  self.stdin_rect = { x = rect.x + 6, y = sy, w = rect.w - 210, h = 22 }

  local bh = 24
  local bw = 88
  local rx = rect.x + rect.w - bw - 8
  UI.button(rx, sy, bw, bh, self.running and "RUNNING…" or "RUN  F5",
    self.running and "disabled" or "hot", 8)
  self.run_rect = { x = rx, y = sy, w = bw, h = bh }
  local fx = rx - bw - 8
  UI.button(fx, sy, bw, bh, self.formatting and "…" or "FORMAT F2",
    self.format_unsupported and "disabled" or "normal", 8)
  self.format_rect = { x = fx, y = sy, w = bw, h = bh }

  local info = I18n.t("%d lines   %d bytes%s",
    self.editor:line_count(), #self.editor:text(),
    self.editor.dirty and "   ·" or "")
  UI.text(info, rect.x + 8, rect.y + rect.h - 18, 7, Theme.withAlpha(Theme.cream, 0.4))
end

--- What the program did.
---
--- Deliberately flat: one outcome line, then stdout, then stderr. No banner,
--- no verdict colour, no red. §4.9c — nothing here is scored, and this is
--- where somebody writes something broken on purpose to see what the compiler
--- says.
function Playground:draw_output(rect)
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
  UI.text(head, rect.x + 10, y, 8, colour, "left", rect.w - 20)
  y = y + 18

  if self.problem then
    for _, line in ipairs(UI.wrap(self.problem, rect.w - 24, 7)) do
      UI.text(line, rect.x + 10, y, 7, Theme.coin)
      y = y + 10
    end
  elseif self.note then
    for _, line in ipairs(UI.wrap(self.note, rect.w - 24, 7)) do
      UI.text(line, rect.x + 10, y, 7, Theme.withAlpha(Theme.cyan, 0.9))
      y = y + 10
    end
  end

  love.graphics.setScissor(rect.x + 4, y, rect.w - 8, rect.y + rect.h - y - 6)
  love.graphics.setFont(font)

  local function block(label, text, alpha)
    if not text or text == "" then return end
    UI.text(label, rect.x + 10, y, 7, Theme.withAlpha(Theme.cream, 0.4))
    y = y + 12
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
      UI.text(I18n.t("WHAT THE COMPILER SAID"), rect.x + 10, y, 7,
        Theme.withAlpha(Theme.cream, 0.4))
      y = y + 12
      for _, d in ipairs(self.result.diagnostics) do
        local head_line = ("%s%s"):format(d.kind or "",
          d.code and (" [" .. d.code .. "]") or "")
        UI.text(head_line, rect.x + 10, y, 7, Theme.withAlpha(Theme.cyan, 0.9))
        y = y + 10
        for _, line in ipairs(UI.wrap(d.message or "", rect.w - 34, 7)) do
          UI.text("  " .. line, rect.x + 10, y, 7, Theme.withAlpha(Theme.cream, 0.8))
          y = y + 10
        end
        if d.line then
          UI.text(("  line %d%s"):format(d.line, d.col and (":" .. d.col) or ""),
            rect.x + 10, y, 7, Theme.withAlpha(Theme.cream, 0.45))
          y = y + 10
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
  if self.focus == "editor" then
    self.editor:textinput(text)
    SFX.play("type")
  elseif self.focus == "stdin" then
    self.stdin = self.stdin .. text
  end
end

function Playground:keypressed(key, mods)
  mods = mods or {}
  local cmd = mods.ctrl or mods.gui

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
