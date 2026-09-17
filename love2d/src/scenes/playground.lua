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
local CodeFx = require("src.codefx")
local CoderM = require("src.agent.coder")
local Anim = require("src.anim")
local runlog = require("src.net.runlog")

local Playground = {}
Playground.__index = Playground

local Land = require("src.land")
local Poster = require("src.poster")
local Reader = require("src.diskreader")
local Wallet = require("src.wallet")
local Store = require("src.store")

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
    -- POSTER and DISK READER (`src/poster.lua`, `src/diskreader.lua`).
    -- The key for the stamp. The session keeps the phrase it signed in
    -- with for the run (`Session:signer`), the browser's rule for its tab;
    -- a session resumed from its token has none, so then the poster asks
    -- for it, in place, and holds it **for this screen only** — `leave`
    -- drops it.
    secret = nil,
    secret_index = 0,
    stamp_edit = nil,   -- what is in the key field; nil when it is closed
    disk_edit = nil,    -- what is in the path field; nil when it is closed
    postering = false,
    -- The Rust coder: the AI agent that flies over the code
    -- (`src/agent/coder.lua`). Made in `enter`, because it wants the editor.
    coder = nil,
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
  -- The typing effects, over the editor: `src/codefx.lua`.
  self.fx = self.fx or CodeFx.new()
  self.fx:clear()
  self.fx:attach(self.editor, self.pane)
  self.editor.auto_close = true
  self.editor.lang = self.lang
  self.editor:set_text(STARTER[self.lang])
  self.editor.dirty = false

  self.subscriptions = {
    self.app.session:on("run.stage", function(payload) self:on_stage(payload) end),
    self.app.session:on("run.log", function(payload) self:on_log(payload) end),
  }
  self.coder = CoderM.new(self.app, self:agent_host())
  self.coder:mount(self.editor)
  self:list()
end

--- What the coder is allowed to do on this screen. The playground is the
--- generous one: it runs code, formats it, has a room per pad and can put a
--- picture in it. The quest screen hands over a much shorter list.
function Playground:agent_host()
  local scene = self
  return {
    lang = function() return scene.lang end,
    caret = function()
      if not scene.pane then return nil end
      return scene.pane:cell(scene.editor.line, scene.editor.col)
    end,
    room_id = function() return scene.snippet_id end,
    room_name = function() return scene.name or "" end,
    ensure_room = function()
      -- A pad nobody has saved has no id, and a room belongs to an id. So the
      -- first thing said in an unsaved pad saves it.
      if scene.snippet_id then return false end
      scene:save()
      return true
    end,
    touched = function()
      scene.dirty_at = Anim.now()
    end,
    fx = function() return scene.fx end,
    request = function(type_name, payload, cb)
      scene.app.session:request(type_name, payload, cb)
    end,
    run = function(stdin, done)
      if scene.running then return done(nil) end
      if stdin then scene.stdin = stdin end
      scene.agent_run_done = done
      scene:run()
    end,
    format = function(done)
      scene.agent_format_done = done
      scene:format()
    end,
  }
end

function Playground:leave()
  if self.coder then self.coder:leave() end
  -- The stamp's key does not outlive the screen.
  Wallet.forget(self, "secret")
  self.stamp_edit, self.disk_edit = nil, nil
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
    -- The pad's input belongs to the pad: a scratchpad has no test cases, so
    -- this is the only thing its program will ever read, and reopening the
    -- pad without it hands back a program that cannot be run.
    stdin = self.stdin or "",
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
    self.stdin = snippet.stdin or self.stdin or ""
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
    -- The input comes back with the code: one entry, two things.
    self.stdin = snippet.stdin or ""
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
      self:tell_agent_run(nil)
      return
    end
    self.result = payload.run
    -- No accepted/rejected chime either way. Nothing was judged.
    SFX.play("move")
    self:tell_agent_run(payload.run)
  end)
end

--- The coder asked for the RUN it is watching; hand it the report exactly
--- once. The button's own run answers nobody, which is why this is a
--- separate call rather than something the callback always does.
function Playground:tell_agent_run(report)
  local done = self.agent_run_done
  self.agent_run_done = nil
  if done then done(report) end
end

function Playground:tell_agent_format(report)
  local done = self.agent_format_done
  self.agent_format_done = nil
  if done then done(report) end
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
      self:tell_agent_format({ changed = false, problem = self.note })
      return
    end
    if payload.problem and payload.problem ~= "" then
      self.problem = payload.problem
      self:tell_agent_format({ changed = false, problem = payload.problem })
      return
    end
    if payload.changed == false then
      self.note = I18n.t("already tidy")
      self:tell_agent_format({ changed = false })
      return
    end
    self.editor:replace_all(payload.source or self.editor:text())
    self.note = "formatted"
    self:tell_agent_format({ changed = true })
  end)
end

function Playground:update(dt)
  self.t = self.t + dt
  if self.fx then self.fx:update(dt) end
  if self.coder then
    -- The whole screen is the coder's sky, minus whatever the panel took.
    self.coder:fly({ 0, 0, Layout.vw, Layout.vh }, self.agent_rect)
    self.coder:update(dt)
  end
  if self.editor then self.editor.lang = self.lang end
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
    -- Stacked, the browser's way: the pads on top at a quarter of the
    -- height, then the bench. The list used to have no width at all in
    -- portrait, which left a phone with no way to open a second pad.
    local h = vh - top - bottom
    -- A quarter, or what the title, the search field, three rows and the
    -- buttons need — whichever is more, up to two fifths: at the largest
    -- type step a quarter held one row of the list it exists to show.
    local need = 8 + UI.lineHeight(8) + 6 + (UI.lineHeight(7) + 14)
      + 3 * (UI.lineHeight(7) + 10) + 6 + UI.chipHeight() + 12
    local list_h = math.max(math.floor((h - pad * 2) * 0.26),
      math.min(math.floor(h * 0.4), need))
    local rest = h - list_h - pad * 2
    local code_h = math.floor(rest * 0.6)
    return
      { x = pad, y = top + list_h + pad, w = vw - pad * 2, h = code_h },
      { x = pad, y = top + list_h + pad + code_h + pad, w = vw - pad * 2,
        h = rest - code_h },
      { x = pad, y = top, w = vw - pad * 2, h = list_h }
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
  -- **Right of the TAB caption, not over it.** The strip and the captions
  -- share this line, and laying the buttons from the language's left edge put
  -- the first of them straight through `TAB` and the `saved` notice on a
  -- window with no room to spare.
  local tab_reserve = UI.textWidth(I18n.t("TAB"), 7) + 16
  local rx = lx - 8 - tab_reserve
  self.code_button_rect, self.rename_rect, self.poster_rect, self.reader_rect = nil, nil, nil, nil
  self.agent_button_rect = nil
  for _, item in ipairs({
    { id = "code", label = I18n.t("CODE") },
    { id = "agent", label = I18n.t("AGENT") },
    { id = "rename", label = I18n.t("RENAME") },
    -- Out as a picture, and back in: dropped first when the header is short.
    { id = "poster", label = I18n.t("POSTER") },
    { id = "reader", label = I18n.t("DISK READER") },
  }) do
    local w = math.max(64, UI.textWidth(item.label, UI.CHIP_SIZE) + 24)
    if rx - w < 200 then break end
    rx = rx - w
    UI.button(rx, ly, w, lh, item.label, "normal", UI.CHIP_SIZE)
    local rect = { x = rx, y = ly, w = w, h = lh }
    if item.id == "code" then self.code_button_rect = rect
    elseif item.id == "agent" then self.agent_button_rect = rect
    elseif item.id == "rename" then self.rename_rect = rect
    elseif item.id == "poster" then self.poster_rect = rect
    else self.reader_rect = rect end
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

  if self.fx then self.fx:draw() end
  -- **The room is not a sliver.** In the framed view the output column is a
  -- fifth of the window, which is a fine width for a compiler message and far
  -- too narrow for a conversation, so the panel takes the code and output
  -- panes together and the list stays where it is.
  local body = {
    x = code.x,
    y = math.min(code.y, out.y),
    w = out.x + out.w - code.x,
    h = math.max(code.y + code.h, out.y + out.h) - math.min(code.y, out.y),
  }
  self:draw_agent(body, not Layout.isPortrait())
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
    -- The Rust coder. Next to RUN because it is the other thing that acts
    -- on the program rather than on the file.
    { id = "agent", label = I18n.t("AGENT"), every = { I18n.t("AGENT") },
      state = (self.coder and self.coder.panel.open) and "hot" or "normal" },
    { id = "save", label = I18n.t("SAVE"), every = { I18n.t("SAVE") }, state = "normal" },
    { id = "rename", label = I18n.t("RENAME"), every = { I18n.t("RENAME") }, state = "normal" },
    -- In and out of the screen. Nothing on a canvas can be selected with a
    -- mouse, so without these the code and the compiler's answer cannot leave
    -- it at all -- which is what somebody pasting into an assistant and
    -- pasting the reply back needs.
    { id = "copycode", label = I18n.t("COPY CODE"), every = { I18n.t("COPY CODE") },
      state = "normal" },
    { id = "pastecode", label = I18n.t("PASTE"), every = { I18n.t("PASTE") }, state = "normal" },
    -- The face code is drawn in, cycled. Says the face it is **in**, like
    -- every other toggle on this strip.
    { id = "face", label = Assets.CODE_FACE_NAME[Assets.codeFace()],
      every = { "JETBRAINS" }, state = "normal" },
    { id = "copyin", label = I18n.t("COPY INPUT"), every = { I18n.t("COPY INPUT") },
      state = (self.stdin or "") ~= "" and "normal" or "disabled" },
    { id = "pastein", label = I18n.t("PASTE INPUT"), every = { I18n.t("PASTE INPUT") },
      state = "normal" },
    { id = "copyout", label = I18n.t("COPY OUTPUT"), every = { I18n.t("COPY OUTPUT") },
      -- Parenthesised, and it matters: `a or b and c or d` binds as
      -- `a or ((b and c) or d)`, so after a run this handed `UI.button` the
      -- result *table* where it wanted the word "normal".
      state = (self.result or self.log) and "normal" or "disabled" },
    -- Out of the screen as a picture, signed; and a picture back in, checked.
    { id = "poster", label = I18n.t("POSTER"), every = { I18n.t("POSTER") },
      state = self.postering and "disabled" or "normal" },
    { id = "reader", label = I18n.t("DISK READER"), every = { I18n.t("DISK READER") },
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
  local hot = self.focus == "name"
  -- The key field and the path field take this line while they are open:
  -- the key masked, the way the login screen masks it.
  if self.focus == "stamp" then
    info = ("%s   %s_"):format(I18n.t("POSTER"), (self.stamp_edit or ""):gsub("%S", "*"))
    hot = true
  elseif self.focus == "disk" then
    info = ("%s   %s_"):format(I18n.t("DISK READER"), self.disk_edit or "")
    hot = true
  elseif self.note then
    info = info .. "   " .. tostring(self.note)
  end
  -- One line, elided: a saved poster's path is long, and a line that wraps
  -- here walks down over the editor.
  info = Poster.elide(info, vw - pad * 2 - 8, function(t) return UI.textWidth(t, 7) end)
  UI.text(info, pad + 4, pad + math.max(band, bh) + 3, 7,
    hot and Theme.coin or Theme.withAlpha(Theme.cream, 0.5))

  -- **Beside the code when the window is wide, under it when it is tall.**
  -- A landscape window has width to spare and height to spare nothing: output
  -- stacked under the editor there costs a quarter of the few lines the screen
  -- has. Upright it is the other way round, and a column of output beside the
  -- code would be too narrow to read a compiler error in.
  -- **One line of stdin, kept.** CODE exists to give the editor the window,
  -- and this is the one thing it cannot take back from it: a scratchpad has
  -- no test cases, so this box is the only way a program that reads anything
  -- is fed at all. One line rather than the framed screen's row, with its
  -- label beside it rather than over it.
  -- **Input and output keep each other company, across the short axis.**
  -- Wide window: the output is a column beside the code and stdin sits at the
  -- top of it, so the editor keeps its width. Tall window: the output is a
  -- band under the code and stdin takes the left of it, so the editor keeps
  -- its height. Either way the pair costs the editor one dimension, not two.
  local field_font = Assets.mono(Layout.ui(8))
  local fed_h = math.max(field_font:getHeight() + 8, UI.lineHeight(7) + 8)
  local label = I18n.t("STDIN")
  local label_w = UI.textWidth(label, 7) + 14
  -- `h` because the box is not always one line: set beside the output it
  -- matches the output's height, so the pair reads as one band rather than as
  -- a full panel with a sliver next to it.
  local function fed(x, y, w, h)
    h = h or fed_h
    UI.setColor(Theme.void, 0.9)
    love.graphics.rectangle("fill", x, y, w, h)
    love.graphics.setLineWidth(2)
    UI.setColor(self.focus == "stdin" and Theme.coin or Theme.withAlpha(Theme.cream, 0.3))
    love.graphics.rectangle("line", x + 1, y + 1, w - 2, h - 2)
    love.graphics.setColor(1, 1, 1, 1)
    -- **The label goes over the field when there is a field to go over.**
    -- Beside it, `표준 입력` is two thirds of a narrow box's width and the
    -- input is typed into the third that is left. On a single line there is
    -- no room above, so there it stays alongside.
    local stacked = h >= fed_h * 1.6
    love.graphics.setColor(1, 1, 1, 1)
    local tx, ty
    if stacked then
      UI.text(label, x + 6, y + 3, 7, Theme.withAlpha(Theme.cream, 0.5))
      tx, ty = x + 6, y + 3 + UI.lineHeight(7) + 2
    else
      UI.text(label, x + 6, y + math.floor((fed_h - UI.lineHeight(7)) / 2), 7,
        Theme.withAlpha(Theme.cream, 0.5))
      tx, ty = x + label_w, y + math.floor((fed_h - field_font:getHeight()) / 2)
    end
    love.graphics.setFont(field_font)
    UI.setColor(Theme.cream)
    local caret = self.focus == "stdin"
    if stacked then
      -- Real lines when there is height for them, so multi-line input reads
      -- as what it is rather than as a row of pilcrows.
      local line_h = field_font:getHeight()
      local yy = ty
      local text = (self.stdin or "") .. (caret and "_" or "")
      for line in (text .. "\n"):gmatch("(.-)\n") do
        if yy + line_h > y + h - 4 then break end
        love.graphics.print(line, tx, yy)
        yy = yy + line_h
      end
    else
      local shown = (self.stdin or ""):gsub("\n", "⏎")
      if caret then shown = shown .. "_" end
      love.graphics.print(shown, tx, ty)
    end
    love.graphics.setColor(1, 1, 1, 1)
    self.stdin_rect = { x = x, y = y, w = w, h = h }
  end

  local has_out = (self.result ~= nil) or (self.log ~= nil) or self.running
  local wide = not Layout.isPortrait()
  local top = strip + 6
  local body_w = vw - pad * 2
  -- Nothing run yet: no column or band to join, so a line of its own. Never
  -- hidden — it is the only way a program that reads is fed at all.
  if not has_out then
    fed(pad, top, body_w)
    top = top + fed_h + 5
  end
  local body_h = vh - top - UI.footerHeight() - 6
  if has_out and wide then
    local out_w = math.floor(body_w * 0.38)
    local x = pad + body_w - out_w
    -- A share of the column rather than a single line: input is usually
    -- several lines -- a count and then the numbers -- and a box that shows
    -- one of them is a box you cannot check what you typed in.
    local in_h = math.max(fed_h, math.floor(body_h * 0.26))
    fed(x, top, out_w, in_h)
    self:draw_code({ x = pad, y = top, w = body_w - out_w - pad, h = body_h }, true)
    self:draw_output({ x = x, y = top + in_h + 5, w = out_w, h = body_h - in_h - 5 })
  elseif has_out then
    local band_h = math.max(fed_h, math.floor(body_h * 0.28))
    local y = top + body_h - band_h
    local in_w = math.floor(body_w * 0.4)
    fed(pad, y, in_w, band_h)
    self:draw_code({ x = pad, y = top, w = body_w, h = body_h - band_h - pad }, true)
    self:draw_output({ x = pad + in_w + pad, y = y, w = body_w - in_w - pad, h = band_h })
  else
    self:draw_code({ x = pad, y = top, w = body_w, h = body_h }, true)
  end

  if self.fx then self.fx:draw() end
  self:draw_agent({ x = pad, y = top, w = body_w, h = body_h }, wide)
  self.app:footer(I18n.t("F5 run   F2 format   TAB lang   CTRL-S save   CTRL-N new   ESC back"))
end

--- The coder's panel, and then the coder itself.
---
--- **The sprite is drawn last, after every pane and after the panel.** LÖVE
--- has no z-index; a thing is on top of the interface by being painted after
--- it, and the whole point of this character is that it flies over the code.
---
--- The panel takes the short axis the way the browser's does: a column on the
--- right of a wide window, a band across the foot of a tall one, so the
--- editor gives up one dimension and not two.
function Playground:draw_agent(body, wide)
  self.agent_rect = nil
  if not self.coder then return end
  if self.coder.panel.open then
    local rect
    if wide then
      -- **Half, not a third.** The room is a conversation and the editor is
      -- the program; on a wide window both want a column a sentence can turn
      -- a corner in, and the pads' list on the left is already paying for
      -- itself.
      local w = math.max(320, math.floor(body.w * 0.52))
      rect = { x = body.x + body.w - w, y = body.y, w = w, h = body.h }
    else
      local h = math.max(240, math.floor(body.h * 0.52))
      rect = { x = body.x, y = body.y + body.h - h, w = body.w, h = h }
    end
    self.agent_rect = rect
    self.coder:draw_panel(rect)
  end
  self.coder:draw()
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
  local row = UI.lineHeight(7) + 10

  -- What the buttons at the foot of this panel take, measured before
  -- anything above them is drawn — in portrait this panel is a quarter of
  -- the window and the rows ran straight under them. NEW, RENAME, and
  -- DELETE only while a saved pad is open: the browser's three.
  local items = {
    { id = "new", label = I18n.t("NEW") },
    { id = "rename", label = I18n.t("RENAME") },
  }
  if self.snippet_id then items[#items + 1] = { id = "delete", label = I18n.t("DELETE") } end
  local bh = UI.chipHeight()
  local gap = 6
  local widths, total = {}, 0
  for i, item in ipairs(items) do
    widths[i] = math.max(56, UI.textWidth(item.label, UI.CHIP_SIZE) + 20)
    total = total + widths[i]
  end
  total = total + gap * (#items - 1)
  -- One row when they fit across, else one under the other.
  local across = total <= rect.w - 12
  local rows_of = across and 1 or #items
  local foot_h = rows_of * bh + (rows_of - 1) * gap
  local foot_y = rect.y + rect.h - 6 - foot_h
  self.list_rects = {}
  local bx, by = rect.x + 6, foot_y
  for i, item in ipairs(items) do
    local w = across and widths[i] or rect.w - 12
    UI.button(bx, by, w, bh, item.label,
      self.hover == "list:" .. item.id and "hot" or "normal", UI.CHIP_SIZE)
    self.list_rects[item.id] = { x = bx, y = by, w = w, h = bh }
    if across then bx = bx + w + gap else by = by + bh + gap end
  end

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

  -- The rows scroll to keep the cursor in view: a list that only showed
  -- its first screen was a list whose sixth pad could not be opened.
  local hits = self:visible_snippets()
  local room = math.max(0, math.floor((foot_y - 6 - y) / row))
  local at = 1
  for k, hit in ipairs(hits) do
    if hit.index == self.cursor then at = k end
  end
  local first = math.max(1, math.min(at - room + 1, #hits - room + 1))
  self.snippet_rects = {}
  for k = first, math.min(#hits, first + room - 1) do
    local i, brief = hits[k].index, hits[k].brief
    local here = brief.id == self.snippet_id
    local under = self.focus == "snippets" and i == self.cursor
    if here or under then
      UI.setColor(Theme.coin, here and 0.22 or 0.1)
      love.graphics.rectangle("fill", rect.x + 4, y - 2, rect.w - 8, row)
      love.graphics.setColor(1, 1, 1, 1)
    end
    -- The land's colour along the left edge, the browser's way, so a Go
    -- pad and a Rust pad are told apart before the name is read.
    UI.setColor(Theme.land[brief.lang] or Theme.dim, 0.9)
    love.graphics.rectangle("fill", rect.x + 4, y - 2, 3, row)
    love.graphics.setColor(1, 1, 1, 1)
    -- The land's initial, right-aligned inside the panel, and the name
    -- given what is left of the row: it used to be placed 14 px from the
    -- edge whatever its width, and at the doubled ladder hung outside.
    local initial = tostring(brief.lang):sub(1, 1):upper()
    local iw = UI.textWidth(initial, 7)
    local label = tostring(brief.name or brief.id)
    while UI.textWidth(label, 7) > rect.w - 30 - iw and #label > 3 do
      label = label:sub(1, -2)
    end
    UI.text(label, rect.x + 12, y + 2, 7,
      here and Theme.coin or Theme.withAlpha(Theme.cream, 0.85))
    UI.text(initial, rect.x + rect.w - 10 - iw, y + 2, 7,
      Theme.withAlpha(Theme.cream, 0.4))
    self.snippet_rects[i] = { x = rect.x, y = y - 2, w = rect.w, h = row }
    y = y + row
  end
  if not self.snippets then
    UI.text("…", rect.x + 10, y, 8, Theme.dim)
  elseif #self.snippets == 0 then
    UI.paragraph(I18n.t("nothing saved yet"), rect.x + 10, y, rect.w - 20, 7,
      Theme.withAlpha(Theme.cream, 0.45))
  elseif #hits == 0 then
    UI.paragraph(I18n.t("no pad by that name"), rect.x + 10, y, rect.w - 20, 7,
      Theme.withAlpha(Theme.cream, 0.45))
  end
end

--- The editor.
---
--- `bare` leaves off the strip under it — the stdin field, RUN and FORMAT and
--- the line count — because in CODE those controls are along the top and the
--- whole of the rest of the window is for the code.
function Playground:draw_code(rect, bare)
  UI.well(rect.x, rect.y, rect.w, rect.h,
    self.focus == "editor" and Theme.coin or Theme.cyan)

  -- The strip under the code — the stdin field, the two buttons, and the
  -- line count — measured from what is in it. It was a hard 64 px: a 7 px
  -- caption over a 22 px field and a 24 px button, and at the doubled ladder
  -- the caption printed through the field and `FORMAT F2` wrapped inside
  -- its own button.
  --
  -- Measured **first**, because what is left over decides how big the code
  -- can be drawn: none of it depends on the code font.
  local cap_h = UI.lineHeight(7)
  local field_font = Assets.mono(Layout.ui(8))
  local field_h = field_font:getHeight() + 6
  local bh = UI.chipHeight()
  local row_h = math.max(field_h, bh)
  local strip = 6 + cap_h + 2 + row_h + 4 + cap_h + 6
  if bare then strip = 0 end

  local font = Assets.mono(Layout.codeSizeFor(18, rect.h - strip - 12, 6))
  local line_h = font:getHeight()
  -- The trailing space is not decoration: `%4d` right-aligns, so without
  -- it the last digit of the line number touches the first character of an
  -- unindented line and `1` reads as part of `fn`.
  local gutter = font:getWidth("0000 ")
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
    -- `stdin_rect` is not cleared: in CODE the field is drawn by `draw_big`,
    -- above the editor rather than under it, and it owns that rect.
    self.run_rect, self.format_rect = nil, nil
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
    -- Two lines at most, the second elided: a saved poster's path is long,
    -- and a note that wrapped for as long as it liked once ate the whole
    -- pane and handed the scissor below a negative height.
    local wrapped = UI.wrap(self.note, rect.w - 24, 7)
    for i = 1, math.min(2, #wrapped) do
      local line = wrapped[i]
      if i == 2 and #wrapped > 2 then
        line = Poster.elide(table.concat(wrapped, " ", 2), rect.w - 24,
          function(t) return UI.textWidth(t, 7) end)
      end
      UI.text(line, rect.x + 10, y, 7, Theme.withAlpha(Theme.cyan, 0.9))
      y = y + small
    end
  end

  love.graphics.setScissor(rect.x + 4, y, rect.w - 8, math.max(0, rect.y + rect.h - y - 6))
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
  -- The room's field first while it is open: whatever is being typed into
  -- the panel is not being typed into the program.
  if self.coder and self.coder:textinput(text) then return end
  if self.focus == "name" then
    if self.name_fresh then self.name_edit, self.name_fresh = "", false end
    if #(self.name_edit or "") < 48 then self.name_edit = (self.name_edit or "") .. text end
  elseif self.focus == "find" then
    if #(self.query or "") < 48 then self.query = (self.query or "") .. text end
  elseif self.focus == "stamp" then
    if #(self.stamp_edit or "") < 400 then self.stamp_edit = (self.stamp_edit or "") .. text end
  elseif self.focus == "disk" then
    if #(self.disk_edit or "") < 1024 then self.disk_edit = (self.disk_edit or "") .. text end
  elseif self.focus == "editor" then
    self.editor:textinput(text)
    SFX.play("type")
  elseif self.focus == "stdin" then
    self.stdin = self.stdin .. text
    -- Part of the pad, so touching it is an edit: without this the autosave
    -- never carries what was typed into it.
    self.editor.dirty = true
    self.dirty_at = Anim.now()
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

--- The code face, cycled and remembered.
---
--- One preference for both code panes, because how somebody likes to read
--- code is a fact about them and not about which screen they are on.
function Playground:cycle_face()
  local faces = Assets.CODE_FACES
  local at = 1
  for i, name in ipairs(faces) do
    if name == Assets.codeFace() then at = i end
  end
  local next_face = faces[(at % #faces) + 1]
  Assets.setCodeFace(next_face)
  require("src.store").set_face(next_face)
  self.note = Assets.CODE_FACE_NAME[next_face]
  SFX.play("select")
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
  elseif which == "copyin" then
    local text = self.stdin or ""
    if text == "" then self.note = I18n.t("nothing to copy"); return end
    love.system.setClipboardText(text)
    self.note = I18n.t("copied")
  elseif which == "in" then
    -- Checked like the editor's paste is: an empty clipboard silently wiping
    -- the program's input is a button that looks like it worked.
    local text = love.system.getClipboardText() or ""
    if text == "" then self.note = I18n.t("the clipboard is empty"); return end
    self.stdin = text
    self.editor.dirty = true
    self.dirty_at = Anim.now()
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

-- ------------------------------------------------------ POSTER / DISK READER

--- Who signed, through the library: `recover(message, signature) -> address|nil`.
function Playground:recoverer()
  local lib = self.app.wallet_lib
  return function(message, signature)
    local r = Wallet.recover(lib, message, signature)
    return r and r.address or nil
  end
end

--- POSTER: the pad as one square PNG (and a JPEG), signed, saved to disk.
---
--- The signature is EIP-191 over the source and only the source — the same
--- scheme as the login challenge and as the browser client's poster, so one
--- reader checks both. Made here because the key is here — or is not: this
--- client keeps the phrase for the run after a login with one, and a session
--- resumed from its token has none: then the field opens and `stamp_with`
--- comes back to this. A stranger's key is dropped again at
--- once; the right one stays for the screen.
function Playground:poster()
  if self.postering then return end
  local lib = self.app.wallet_lib
  if not lib then
    self.note = "libcwbh_ffi is not built — " .. Wallet.BUILD_HINT
    return
  end
  -- The session keeps the key it signed in with (`Session:signer`), the
  -- way the browser holds it for the tab; a session resumed from its token
  -- has none, and only then does the field open.
  if not self.secret then
    local signer = self.app.session:signer()
    if signer then
      self.secret, self.secret_index = signer.secret, signer.index
    else
      return self:start_stamp()
    end
  end
  self.postering = true
  local ok, err = pcall(function() self:make_poster(lib) end)
  self.postering = false
  if not ok then
    self.app:log("warn", "poster: " .. tostring(err))
    self.note = I18n.t("could not make the poster")
    SFX.play("locked")
  end
end

function Playground:make_poster(lib)
  local source = self.editor and self.editor:text() or ""
  local address = self.app.session:address()
  if not address then error("nobody is signed in") end
  local signed, sign_err = Wallet.sign(lib, self.secret, self.secret_index, source)
  if not signed then error(sign_err or "the library did not sign") end
  local signature = signed.signature
  -- The output as the pane shows it: every stream's whole lines, then the
  -- partial tail a run may have ended on.
  local log_lines = {}
  if self.log then
    for _, name in ipairs(self.log.order or {}) do
      local lines, tail = self.log:lines(name)
      for _, line in ipairs(lines) do log_lines[#log_lines + 1] = { stream = name, text = line } end
      if tail and tail ~= "" then log_lines[#log_lines + 1] = { stream = name, text = tail } end
    end
  end
  local pad_name = self.name and tostring(self.name) or "scratch"
  local function qr(text)
    local r = Wallet.qr(lib, text)
    if not r then error("no QR holds that label") end
    return r.rows
  end
  local rendered = Poster.make({
    lang = self.lang,
    name = pad_name,
    file = ({ rust = "main.rs", go = "main.go", cpp = "main.cpp", python = "main.py" })[self.lang],
    source = source,
    run = Poster.run_of(self.result, log_lines),
    user = { name = self.app.session:display_name() or "hacker", address = address },
    signature = signature,
    at = os.time(),
    qr = qr,
    too_dense = function(text)
      local r = Wallet.qr(lib, text)
      return (not r) or r.size > Poster.QR_MAX_MODULES
    end,
    keccak_hex = function(text)
      local r = Wallet.keccak(lib, text)
      return r and r.digest:sub(3) or ("0"):rep(64)
    end,
  })
  -- Where it goes: `<home>/posters/`, made 0700 by the library (LÖVE has no
  -- mkdir outside its own save directory).
  local dir = Store.home(self.app.home) .. "/posters"
  Wallet.secure(lib, dir, true)
  local path = dir .. "/" .. Poster.file_name(pad_name, os.time())
  local written, werr = Poster.write_png(rendered.canvas, path)
  rendered.canvas:release()
  if not written then error(werr or "could not write the PNG") end
  local ok, perr = Wallet.png_text(lib, path, {
    Title = pad_name,
    Author = self.app.session:display_name() or "hacker",
    Software = "Causewaybay Hacker",
    Source = source,
    Lang = self.lang,
    Signer = address,
    Signature = signature,
    Comment = "Signature is EIP-191 personal_sign over Source, by Signer (Cronos EVM / Ethereum address).",
  })
  if not ok then error(perr or "could not write the proof") end
  -- Proved against the file on disk before it is kept: the signature to the
  -- address, the chunks to the program, the label off the pixels.
  local read = Wallet.disk_read(lib, path, true)
  local problem = Reader.prove(read, read and read.label, source, address, signature,
    self:recoverer(), rendered.payload)
  if problem then
    os.remove(path)
    self.note = ("%s: %s"):format(I18n.t("not saved — the disk did not read back"), problem)
    SFX.play("locked")
    return
  end
  Wallet.jpeg(lib, path, (path:gsub("%.png$", ".jpg")), 92)
  self.note = ("%s · %s + .jpg"):format(I18n.t("poster saved"), path)
  SFX.play("select")
end

--- Ask for the key, on the status line.
function Playground:start_stamp()
  self.focus = "stamp"
  self.stamp_edit = ""
  self.note = I18n.t("paste your phrase or private key to stamp — it stays in this screen")
end

--- Take what was typed as the key: derived at the index the login used,
--- kept only if it is the account that is signed in.
function Playground:stamp_with(text)
  local typed = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if typed == "" then return end
  local lib = self.app.wallet_lib
  local index = self.app.session.index or 0
  local who = Wallet.derive(lib, typed, index)
  if not who then
    self.note = I18n.t("that is not a phrase or a private key")
    SFX.play("locked")
    return
  end
  local me = self.app.session:address() or ""
  if who.address:lower() ~= me:lower() then
    self.note = I18n.t("that key is not the account signed in here")
    SFX.play("locked")
    return
  end
  self.secret, self.secret_index = typed, index
  SFX.play("select")
  self:poster()
end

--- DISK READER: a path field, or a file dropped on the window.
function Playground:start_disk()
  self.focus = "disk"
  self.disk_edit = ""
  self.note = I18n.t("drop a poster on the window, or type its path and press ENTER")
end

function Playground:filedropped(file)
  local path = file.getFilename and file:getFilename() or tostring(file)
  self:read_disk_path(path)
end

--- A picture at `path` back into a pad, with the verdict on the status line.
--- The program opens as a **new, unsaved pad** in its own language, named
--- after the poster, so reading a disk never overwrites what was being
--- written.
function Playground:read_disk_path(path)
  path = Store.expand_tilde((path or ""):gsub("^%s+", ""):gsub("%s+$", ""))
  if path == "" then return end
  local lib = self.app.wallet_lib
  if not lib then
    self.note = "libcwbh_ffi is not built — " .. Wallet.BUILD_HINT
    return
  end
  local read, err = Wallet.disk_read(lib, path)
  if not read then
    self.note = I18n.t("could not read that file")
    self.app:log("warn", "disk reader: " .. tostring(err))
    SFX.play("locked")
    return
  end
  local disk = Reader.from_read(read, self:recoverer())
  if not disk then
    self.note = I18n.t("no disk on that picture")
    SFX.play("locked")
    return
  end
  local short = disk.address:sub(1, 6) .. "…" .. disk.address:sub(-4)
  if disk.verdict == "hashed" then
    self.note = I18n.t("the label holds only the hash — the code is on the disc, not the label")
    SFX.play("locked")
    return
  end
  self:new_snippet()
  self.lang = disk.lang
  self.editor.lang = disk.lang
  self.editor:set_text(disk.source)
  self.editor.dirty = true
  self.dirty_at = Anim.now()
  self.name = disk.title or Reader.name_from_file(path)
  if disk.verdict == "verified" then
    self.note = I18n.t("disk read · written and signed by %s · verified"):format(short)
    SFX.play("select")
  elseif disk.verdict == "forged" then
    self.note = I18n.t("disk read · the signature does NOT match %s"):format(short)
    SFX.play("locked")
  else
    self.note = I18n.t("disk read · unsigned · claims %s"):format(short)
    SFX.play("select")
  end
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

  -- Ctrl/Cmd-Shift-A opens and closes the coder from anywhere on the screen,
  -- the browser's accelerator.
  if key == "a" and cmd and mods.shift then
    if self.coder then self.coder:toggle() end
    return true
  end
  -- Then the panel, while it is open and holding a field.
  if self.coder and self.coder:keypressed(key, mods) then return true end

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

  if self.focus == "stamp" or self.focus == "disk" then
    local field = self.focus == "stamp" and "stamp_edit" or "disk_edit"
    if key == "backspace" then
      self[field] = (self[field] or ""):sub(1, -2)
    elseif cmd and key == "v" then
      self[field] = (self[field] or "") .. (love.system.getClipboardText() or "")
    elseif key == "escape" then
      self[field], self.focus = nil, "editor"
    elseif key == "return" or key == "kpenter" then
      local text = self[field] or ""
      self[field], self.focus = nil, "editor"
      if field == "stamp_edit" then self:stamp_with(text) else self:read_disk_path(text) end
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
  if self.coder then
    local mx, my = love.mouse.getPosition()
    local vx, vy = Layout.toVirtual(mx, my)
    if self.coder:wheelmoved(dy, vx, vy) then return end
  end
  if self.focus == "editor" then
    self.editor:scroll_by(-dy * 3, self.visible_rows or 20)
  end
end

function Playground:mousepressed(x, y, button)
  local function inside(r)
    return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
  end
  -- The coder first: its panel is drawn over the screen and owns what is
  -- under it, and a press on the sprite holds it still. A press anywhere else
  -- lets a held sprite go and then **carries on** to whatever it was aimed
  -- at, which is why this is not a plain "handled" gate.
  if self.coder and self.coder:mousepressed(x, y, button) then return end
  if self.big then
    if inside(self.done_rect) then self.big = false; SFX.play("select"); return end
    if inside((self.big_rects or {}).agent) then self.coder:toggle(); return end
    local r = self.big_rects or {}
    if inside(r.run) then self:run(); return end
    if inside(r.format) then self:format(); return end
    if inside(r.save) then self:save(); SFX.play("select"); return end
    if inside(r.rename) then self:start_rename(); return end
    if inside(r.copycode) then self:clip("code"); return end
    if inside(r.pastecode) then self:clip("paste"); return end
    if inside(r.copyout) then self:clip("out"); return end
    if inside(r.face) then self:cycle_face(); return end
    if inside(r.copyin) then self:clip("copyin"); return end
    if inside(r.pastein) then self:clip("in"); return end
    if inside(r.poster) then self:poster(); return end
    if inside(r.reader) then self:start_disk(); return end
    -- CODE draws the stdin field itself, above the editor. Without this the
    -- box took no caret and nothing could be typed into it.
    if inside(self.stdin_rect) then self.focus = "stdin"; return end
    if inside(r.lang) then self:toggle_lang(); return end
    local shift = love.keyboard.isDown("lshift", "rshift")
    if self.pane:mousepressed(x, y, button, shift) then self.focus = "editor" end
    return
  end
  if inside(self.find_rect) then self.focus = "find"; return end
  local lr = self.list_rects or {}
  if inside(lr.new) then self:new_snippet(); return end
  if inside(lr.rename) then self:start_rename(); return end
  if inside(lr.delete) then
    for i, brief in ipairs(self.snippets or {}) do
      if brief.id == self.snippet_id then self:delete(i) end
    end
    return
  end
  if inside(self.code_button_rect) then self.big = true; SFX.play("select"); return end
  if inside(self.agent_button_rect) then self.coder:toggle(); return end
  if inside(self.rename_rect) then self:start_rename(); return end
  if inside(self.poster_rect) then self:poster(); return end
  if inside(self.reader_rect) then self:start_disk(); return end
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
  -- A moving mouse slows the coder's wander, so it can be caught.
  if self.coder then self.coder:mousemoved(x, y) end
  if self.pane then self.pane:mousemoved(x, y) end
  self.hover = nil
  for id, r in pairs(self.list_rects or {}) do
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
      self.hover = "list:" .. id
    end
  end
  if self.fx then self.fx:pointer(x, y) end
end

function Playground:mousereleased()
  if self.pane then self.pane:mousereleased() end
end

return Playground
