-- QUEST. The brief, the editor, and the run log streaming in.
--
-- `quest.get` (§4.8) fills it, `quest.submit` (§4.9) runs it, `run.stage` and
-- `run.log` (§4.17, §4.18) are what the player watches while it runs, and
-- `quest.submit.ok` carries the `Attempt` that decides everything. Not one of
-- those decisions is made here.
--
-- Two things worth knowing about this screen:
--
--   * **The log is buffered, not appended.** `src/net/runlog.lua` holds the
--     chunks by `seq` and hands back the contiguous prefix, because §4.18
--     says chunks "may split anywhere, including mid-line". A gap is shown as
--     a gap rather than quietly closed up.
--   * **Both buttons are disabled while either is in flight** (§3.2, §4.9b,
--     §8.10). Runs and submits share one execution slot, the client refuses
--     locally, and the buttons go grey rather than the player learning it
--     from a `busy` round trip.
--
-- ## RUN and SUBMIT
--
-- §4.9b: a run is for the player, a submit is for the record. RUN compiles
-- and runs the **visible** cases and is meant to be pressed constantly;
-- SUBMIT runs everything, and is the only one that can clear the node.
--
-- Two consequences for this screen, and they are the whole design:
--
--   1. **A passing run is not a verdict.** It is drawn in `cyan` and says
--      SAMPLE PASSES, never ACCEPTED and never in the green this game uses
--      for a clear. If green meant "done" after a run, SUBMIT would then
--      contradict the player — which is a worse feeling than a plain
--      failure, because it teaches them not to trust the screen.
--   2. **The buttons are far apart**, on the keyboard and on the panel, with
--      RUN on the reflex key it already had. Reaching for RUN must not land
--      on SUBMIT.
--
-- And one thing the copy has to be exactly right about: a run **is** recorded
-- and its mistakes **do** feed the drills (§4.9b, SPEC §7) — the errors made
-- while iterating are the truest record of the struggle. What a run does not
-- do is count as an attempt against the node. "Runs don't count against your
-- stars" is true. "Runs aren't saved" is not, and is not written anywhere
-- here.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local SFX = require("src.sfx")
local Editor = require("src.editor")
local CodePane = require("src.codepane")
local runlog = require("src.net.runlog")
local External = require("src.external")
local Anim = require("src.anim")
local Clock = require("src.clock")
local Ease = require("src.ease")

local Quest = {}
Quest.__index = Quest

local STAGES = { queued = 1, compiling = 2, running = 3, judging = 4 }

--- Which plate stands behind a quest. `docs/art.md` §5's table, using the
--- `art/` names; `Assets.pick` falls through to a placeholder when `art/` is
--- not readable.
function Quest.backdrop(land, category)
  if category == "hacker" then
    return Assets.pick("bg_room732", "bg_flat", "bg_night")
  end
  if land == "go" then
    return Assets.pick(category == "advanced" and "bg_mtr" or "bg_till",
      "bg_mtr", "bg_flat")
  end
  return Assets.pick(category == "advanced" and "bg_times" or "bg_street",
    "bg_street", "bg_flat")
end

function Quest.new(app)
  return setmetatable({
    app = app,
    quest = nil,
    error = nil,
    editor = nil,
    log = nil,
    stage = nil,
    elapsed_ms = 0,
    -- The execution in flight: "quest.run", "quest.submit", or nil.
    running_mode = nil,
    attempt = nil,
    -- The last run's Attempt, shown in place rather than on the result
    -- screen: a run is not a verdict and does not deserve that banner.
    run_attempt = nil,
    hint = nil,
    focus = "editor",     -- "editor" | "brief"
    clock_arrived = nil,  -- when the clock first appeared, for its entrance
    clock_phase = nil,    -- the last phase seen, so a crossing can pulse
    clock_crossed = nil,  -- when that crossing happened
    brief_scroll = 0,
    log_scroll = 0,
    show_log = false,
    t = 0,
  }, Quest)
end

function Quest:enter(params)
  self.quest_id = params.quest_id or self.app.quest_id
  self.editor = Editor.new({
    clipboard = {
      get = function() return love.system.getClipboardText() or "" end,
      set = function(text) love.system.setClipboardText(text or "") end,
    },
    now = function() return love.timer.getTime() end,
  })
  -- The mouse half of the pane: the hit test, drag-select and the bracket
  -- overlay, shared with the playground so the two cannot drift.
  self.pane = CodePane.new(self.editor)

  -- Taken back in `leave`: this scene is entered once per visit to a node,
  -- and a subscription that outlived it would keep this scene (and its whole
  -- buffer) alive and still take `run.log` chunks for an attempt nobody is
  -- looking at.
  self.subscriptions = {
    self.app.session:on("run.stage", function(payload) self:on_stage(payload) end),
    self.app.session:on("run.log", function(payload) self:on_log(payload) end),
  }

  self:refresh()
end

function Quest:leave()
  self.app.session:off_all(self.subscriptions)
  self.subscriptions = nil
end

function Quest:refresh()
  self.error = nil
  self.app.session:request("quest.get", { quest_id = self.quest_id }, function(ok, payload, why)
    if not ok then
      self.error = why.player
      if payload.code == "locked" then
        local requires = (payload.detail or {}).requires
        self.error = "locked" .. (requires and (" — needs " .. tostring(requires[1])) or "")
      end
      return
    end
    self.quest = payload.quest
    -- §4.8b: the clock arrives with the quest. `opened_at` and `deadline_at`
    -- are the server's and are the *same pair* on every later `quest.get`, so
    -- a reconnect shows one clock rather than starting a new one — which is
    -- why nothing here records a start time of its own.
    if Clock.read(self.quest) and not self.clock_arrived then
      self.clock_arrived = Anim.now()
    end
    -- Only load the starter into a buffer the player has not touched, so a
    -- reconnect mid-quest does not eat what they were writing.
    if not self.editor.dirty then
      self.editor:set_text(self.quest.starter or "")
    end
  end)
end

-- ----------------------------------------------------------------- the run

function Quest:on_stage(payload)
  if self.attempt_id and payload.attempt_id ~= self.attempt_id then return end
  self.attempt_id = payload.attempt_id
  self.stage = payload.stage
  self.elapsed_ms = payload.elapsed_ms or 0
  self.queued = payload.queued
  self.show_log = true
end

function Quest:on_log(payload)
  if not self.log or (self.log.attempt_id and payload.attempt_id ~= self.log.attempt_id) then
    -- The first chunk of an attempt may beat the first `run.stage`.
    self.log = runlog.new(payload.attempt_id)
  end
  self.log:add(payload)
  self.show_log = true
  -- Follow the tail unless the player has scrolled back.
  if self.log_follow ~= false then self.log_scroll = 1e9 end
end

--- RUN (§4.9b) — visible cases only, never clears, stays on this screen.
function Quest:run()
  self:execute("quest.run")
end

--- SUBMIT (§4.9) — everything, and the only one that can clear the node.
function Quest:submit()
  self:execute("quest.submit")
end

--- One path for both, because §4.9b gave them the same payload shape on
--- purpose.
function Quest:execute(mode)
  if self.running_mode or not self.quest then return end
  if mode == "quest.run" and self.run_unsupported then SFX.play("locked"); return end
  if self.quest.state == "locked" then SFX.play("locked"); return end

  local is_run = mode == "quest.run"
  self.running_mode = mode
  self.attempt = nil
  self.attempt_id = nil
  self.run_attempt = nil
  self.stage = "queued"
  self.elapsed_ms = 0
  self.log = nil
  self.log_follow = true
  self.show_log = true
  SFX.play("submit")

  self.app.session:request(mode, {
    quest_id = self.quest.id,
    -- §4.9: `lang` must match the quest's land.
    lang = self.quest.land,
    source = self.editor:text(),
  }, function(ok, payload, why)
    self.running_mode = nil
    self.stage = nil
    if not ok then
      SFX.play("rejected")
      self.error = why.player
      -- §4.9b is newer than some servers. `not_found` on a run means the
      -- endpoint is not there yet, which is not the player's problem and is
      -- not "no such quest" — SUBMIT still works, so say that.
      if is_run and payload.code == "not_found" then
        self.run_unsupported = true
        self.error = "RUN is not on this server yet — SUBMIT still works"
        self.app:toast(self.error)
        return
      end
      if payload.code == "busy" then
        -- The other button is still going. Says which, because "busy" with
        -- no subject is the least useful message in any program.
        local running = (payload.detail or {}).running
        self.app:toast(running == "quest.run" and "a run is still going"
          or "a submission is already running")
      end
      return
    end

    local attempt = payload.attempt
    if attempt.verdict == "accepted" then SFX.play("accepted") else SFX.play("rejected") end

    if is_run then
      -- Stay here. A run is an iteration, not an outcome, and bouncing the
      -- player to a result screen after every RUN would make the reflex
      -- button feel expensive.
      self.run_attempt = attempt
      self.run_at = Anim.now()
      self.show_log = true
      return
    end

    self.attempt = attempt
    self.app.last_attempt = attempt
    self.app:go("result", {
      attempt = attempt,
      quest = self.quest,
      log = self.log,
      source = self.editor:text(),
    })
  end)
end

--- FORMAT (PROTOCOL §4.9d) — `rustfmt` or `gofmt`, on the server.
---
--- Three things this has to get right, and all three are about not punishing
--- somebody for pressing it mid-thought:
---
---   * **unparseable source is not an error.** The reply is `.ok` with the
---     original bytes and the formatter's complaint in `problem`. It is shown
---     in the hint register, not the failure register, and the buffer is left
---     exactly alone.
---   * **`changed: false` means already tidy** — say so rather than replacing
---     the buffer with an identical one, which makes the button feel broken.
---   * **the caret survives**, as one undo step. `Editor:replace_all` anchors
---     it to the text rather than to a coordinate; see its header.
function Quest:format()
  if not self.quest or self.formatting then return end
  self.formatting = true
  self.format_note = nil
  self.format_problem = nil
  SFX.play("move")

  self.app.session:request("code.format", {
    lang = self.quest.land,
    source = self.editor:text(),
  }, function(ok, payload, why)
    self.formatting = false
    if not ok then
      -- A server without §4.9d yet: grey the button and say so, rather than
      -- leaving a control that does nothing.
      if payload.code == "not_found" then
        self.format_unsupported = true
        self.format_note = "FORMAT is not on this server yet"
      else
        self.format_note = why.player
      end
      SFX.play("locked")
      return
    end

    if payload.problem and payload.problem ~= "" then
      -- Quiet. Half-written code is the normal state of an editor, not a
      -- fault, and the buffer is not touched.
      self.format_problem = payload.problem
      return
    end
    if payload.changed == false then
      self.format_note = "already tidy"
      SFX.play("move")
      return
    end
    self.editor:replace_all(payload.source or self.editor:text())
    self.format_note = "formatted"
    SFX.play("select")
  end)
end

function Quest:reset()
  if not self.quest then return end
  self.app.session:request("quest.reset", { quest_id = self.quest.id }, function(ok, payload)
    if not ok then return end
    self.editor:set_text(payload.starter or "")
    self.editor.dirty = false
    self.app:toast("starter code restored")
  end)
end

function Quest:take_hint()
  if not self.quest then return end
  local index = self.quest.hints_used or 0
  if index >= (self.quest.hints_total or 0) then
    self.app:toast("no more hints")
    return
  end
  self.app.session:request("quest.hint", { quest_id = self.quest.id, index = index },
    function(ok, payload, why)
      if not ok then self.app:toast(why.player); return end
      self.hint = payload.hint
      self.quest.hints_used = payload.hints_used or (index + 1)
      self.app:toast(("hint %d of %d — costs stars"):format(payload.index + 1, payload.total))
    end)
end

--- The honest fallback: hand the buffer to `$EDITOR` and read it back.
function Quest:external_edit()
  local text, err = External.edit(self.editor:text(), self.quest and self.quest.land or "rust")
  if not text then
    self.app:toast(err or "could not open $EDITOR")
    return
  end
  self.editor:push_undo(false)
  self.editor:set_text(text)
  self.editor.dirty = true
  self.app:toast("loaded back from $EDITOR")
end

--- Notice a threshold crossing, so it can be marked once rather than
--- animated continuously.
function Quest:tick_clock()
  local state = Clock.read(self.quest)
  if not state then
    self.clock_phase = nil
    return nil
  end
  if state.phase ~= self.clock_phase then
    -- Not on the first sight of the clock: arriving is its own moment and
    -- already has an entrance.
    if self.clock_phase ~= nil then self.clock_crossed = Anim.now() end
    self.clock_phase = state.phase
  end
  return state
end

function Quest:update(dt)
  self.t = self.t + dt
  self:tick_clock()
  if self.running_mode then
    self.elapsed_ms = self.elapsed_ms + dt * 1000
  end
end

-- ------------------------------------------------------------------ drawing

--- The two panes, in whichever orientation is current. Both are first-class:
--- landscape puts the brief beside the editor, portrait stacks them.
function Quest:panes()
  local vw, vh = Layout.vw, Layout.vh
  local top, bottom = 48, 56
  local pad = 10
  if Layout.isPortrait() then
    local brief_h = math.floor((vh - top - bottom) * 0.32)
    return
      { x = pad, y = top, w = vw - pad * 2, h = brief_h },
      { x = pad, y = top + brief_h + pad, w = vw - pad * 2,
        h = vh - top - bottom - brief_h - pad }
  end
  local brief_w = math.floor(vw * 0.34)
  return
    { x = pad, y = top, w = brief_w - pad, h = vh - top - bottom },
    { x = brief_w + pad, y = top, w = vw - brief_w - pad * 2, h = vh - top - bottom }
end

function Quest:draw()
  local vw, vh = Layout.vw, Layout.vh
  local land = (self.quest and self.quest.land) or self.app.land or "rust"
  Assets.cover(Quest.backdrop(land, self.quest and self.quest.category
    or self.app.category), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.78)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local tint = Theme.land[land] or Theme.coin
  UI.setColor(Theme.ink, 0.9)
  love.graphics.rectangle("fill", 0, 0, vw, 48)
  love.graphics.setColor(1, 1, 1, 1)
  local title = self.quest and self.quest.title or (self.error or "loading…")
  UI.text(title, 12, 10, 13, tint)
  UI.text(self.quest_id or "", 12, 30, 7, Theme.withAlpha(Theme.cream, 0.55))
  self:draw_clock(vw)

  if self.quest then
    -- Earned stars get the star; difficulty gets pips (design review §4).
    UI.text("STARS", vw - 12 - 3 * 13 - UI.textWidth("STARS ", 7), 12, 7,
      Theme.withAlpha(Theme.cream, 0.6))
    UI.stars(vw - 12 - 3 * 13, 10, self.quest.stars or 0, 10)
    local pw = UI.pipsWidth(5)
    UI.text("DIFFICULTY", vw - 12 - pw - UI.textWidth("DIFFICULTY ", 7), 32, 7,
      Theme.withAlpha(Theme.cream, 0.6))
    UI.pips(vw - 12 - pw, 30, self.quest.difficulty or 1, 5)
  end

  local brief, code = self:panes()
  self:draw_brief(brief, tint)
  self:draw_editor(code, tint)

  if self.show_log and (self.running_mode or self.log or self.run_attempt) then
    self:draw_run_overlay()
  end

  -- **Not** a second listing of F5, F10 and F2. Those three are printed on
  -- the buttons they belong to, a few centimetres above this line — `RUN F5`,
  -- `SUBMIT F10`, `FORMAT F2` — so repeating them here bought nothing and
  -- cost the four keys that have no button at all, which is what got clipped
  -- in portrait once the display controls took the right-hand end of the
  -- strip. What is left is exactly the keys the screen does not otherwise
  -- say out loud.
  self.app:footer("F6 reset   F7 hint   F8 log   F9 $EDITOR   ESC map")
end

--- The clock (PROTOCOL §4.8b), on the header band.
---
--- **Calm for most of its life.** `Ease.attention` is flat zero until the last
--- quarter of the limit, so for the great majority of a timed quest this is a
--- number that changes once a second and does nothing else. It sits on the
--- screen somebody is concentrating on code in, and a permanently animating
--- countdown is noise.
---
--- The motion is saved for the three moments that mean something: the clock
--- arriving with the quest, a threshold crossing, and the deadline passing.
--- Each is one pulse, not a loop.
function Quest:draw_clock(vw)
  local state = Clock.read(self.quest)
  if not state then return end

  local scale = Layout.uiScale()
  local now = Anim.now()

  -- Colour by phase. Overtime gets its own register — counting up, in the
  -- game's failure red — so it is unmistakably past the line rather than a
  -- countdown that went strange.
  local colour = ({
    calm = Theme.cream,
    warning = Theme.coin,
    urgent = Theme.brick,
    overtime = Theme.red,
  })[state.phase] or Theme.cream

  -- Three one-shot moments, never a loop.
  local entrance = Ease.pulse(self.clock_arrived and (now - self.clock_arrived), 0.55)
  local crossing = Ease.pulse(self.clock_crossed and (now - self.clock_crossed),
    state.phase == "overtime" and 0.9 or 0.5)
  -- And a floor of insistence in the last quarter, which is zero before it.
  local urgency = Ease.attention(state.fraction)

  local text = Clock.format(state)
  local size = math.floor((state.phase == "overtime" and 15 or 14) * scale)
  local grow = 1 + 0.35 * crossing + 0.5 * entrance + 0.10 * urgency
  local w = UI.textWidth(text, size)

  -- Sliding down into place on arrival, rather than appearing.
  local y = 6 - (1 - Ease.expOut(math.min(1,
    self.clock_arrived and (now - self.clock_arrived) / 0.4 or 1))) * 26
  local x = vw / 2

  love.graphics.push()
  love.graphics.translate(x, y + size / 2 + 2)
  love.graphics.scale(grow, grow)
  -- A faint plate behind it so it reads against the map art in the header.
  UI.setColor(Theme.ink, 0.55 + 0.35 * math.max(crossing, urgency))
  love.graphics.rectangle("fill", -w / 2 - 10, -size / 2 - 5, w + 20, size + 10)
  UI.text(text, -w / 2, -size / 2 - 1, size, colour)
  love.graphics.pop()

  local caption = Clock.caption(state)
  if caption then
    local cw = UI.textWidth(caption, 7)
    UI.text(caption, x - cw / 2, y + size + 10, 7, Theme.withAlpha(colour, 0.85))
  end
end

function Quest:draw_brief(rect, tint)
  UI.panel(rect.x, rect.y, rect.w, rect.h, {
    fill = Theme.withAlpha(Theme.navy, 0.95),
    tint = self.focus == "brief" and Theme.coin or tint,
  })
  love.graphics.setScissor(rect.x + 4, rect.y + 4, rect.w - 8, rect.h - 8)
  local x = rect.x + 12
  local y = rect.y + 10 - self.brief_scroll
  -- The text column, in pixels: the panel minus its padding.
  local column = rect.w - 24
  local indent = column - 10

  if self.error then
    for _, line in ipairs(UI.wrap(self.error, column, 9)) do
      y = y + UI.text(line, x, y, 9, Theme.red) + 4
    end
  end

  if self.quest then
    if self.quest.story and self.quest.story ~= "" then
      for _, line in ipairs(UI.wrap(self.quest.story, column, 8)) do
        y = y + UI.text(line, x, y, 8, Theme.withAlpha(Theme.coin, 0.9)) + 3
      end
      y = y + 8
    end
    for _, line in ipairs(UI.wrap(self.quest.brief or "", column, 8)) do
      y = y + UI.text(line, x, y, 8, Theme.cream) + 3
    end
    y = y + 10

    if self.quest.concepts and #self.quest.concepts > 0 then
      y = y + UI.text("CONCEPTS", x, y, 8, Theme.withAlpha(Theme.cream, 0.6)) + 4
      for _, line in ipairs(UI.wrap(table.concat(self.quest.concepts, ", "), column, 8)) do
        y = y + UI.text(line, x, y, 8, tint) + 3
      end
      y = y + 8
    end

    local tests = self.quest.tests or {}
    y = y + UI.text(("TESTS  match %s   %d hidden"):format(
      tostring(tests.match or "?"), tests.hidden_count or 0), x, y, 8,
      Theme.withAlpha(Theme.cream, 0.6)) + 6
    for _, case in ipairs(tests.visible or {}) do
      y = y + UI.text("· " .. tostring(case.name), x, y, 8, Theme.cream) + 2
      if case.stdin and case.stdin ~= "" then
        for _, line in ipairs(UI.wrap("in  " .. case.stdin:gsub("\n", "⏎"), indent, 7)) do
          y = y + UI.text("  " .. line, x, y, 7, Theme.withAlpha(Theme.cream, 0.7)) + 2
        end
      end
      for _, line in ipairs(UI.wrap("out " .. tostring(case.expect):gsub("\n", "⏎"), indent, 7)) do
        y = y + UI.text("  " .. line, x, y, 7, Theme.withAlpha(Theme.admit, 0.9)) + 2
      end
      y = y + 4
    end

    if self.hint then
      y = y + 6
      y = y + UI.text("HINT", x, y, 8, Theme.coin) + 4
      for _, line in ipairs(UI.wrap(self.hint, column, 8)) do
        y = y + UI.text(line, x, y, 8, Theme.coin) + 3
      end
    end
    local hints = ("hints %d/%d  (F7)"):format(
      self.quest.hints_used or 0, self.quest.hints_total or 0)
    y = y + 10
    UI.text(hints, x, y, 7, Theme.withAlpha(Theme.cream, 0.5))
  end
  love.graphics.setScissor()
end

function Quest:draw_editor(rect, tint)
  UI.well(rect.x, rect.y, rect.w, rect.h,
    self.focus == "editor" and Theme.coin or tint)

  -- The player's type-size step, through one function both code panes call.
  -- Before `Layout.codeSize` this expression was written out here and again
  -- in `src/scenes/playground.lua`, which is how the two would have drifted
  -- the first time either was tuned.
  local font = Assets.mono(Layout.codeSize(18))
  local line_h = font:getHeight()
  -- The trailing space is not decoration: `%4d` right-aligns, so without
  -- it the last digit of the line number touches the first character of an
  -- unindented line and `1` reads as part of `fn`.
  local gutter = font:getWidth("0000 ")
  local rows = math.max(1, math.floor((rect.h - 12) / line_h))
  self.editor:ensure_visible(rows)
  self.visible_rows = rows
  self.editor_rect = rect
  self.line_h = line_h
  self.gutter = gutter
  self.mono_font = font

  love.graphics.setScissor(rect.x + 3, rect.y + 3, rect.w - 6, rect.h - 6)
  love.graphics.setFont(font)

  local x0 = rect.x + 8
  local y0 = rect.y + 6
  -- The numbers the draw actually used, handed to the pane so a click is
  -- tested against what is on screen rather than a re-derivation of it.
  self.pane:frame(rect, font, gutter, x0, y0, line_h, rows)
  local state = "code"
  -- Comment state has to be carried from line 1, not from the first visible
  -- line, or scrolling into the middle of a /* … */ colours it as code.
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

    -- Selection, one band per line.
    if sel_l1 and index >= sel_l1 and index <= sel_l2 then
      local from = (index == sel_l1) and sel_c1 or 1
      local to = (index == sel_l2) and sel_c2 or (#line + 1)
      local sx = x0 + gutter + font:getWidth(line:sub(1, from - 1))
      local sw = font:getWidth(line:sub(from, to - 1))
      if to > #line and index < sel_l2 then sw = sw + font:getWidth(" ") end
      UI.setColor(Theme.coin, 0.28)
      love.graphics.rectangle("fill", sx, y, math.max(2, sw), line_h)
    end

    -- A line number in `brick` means that line holds a bracket that never
    -- closed — said in the gutter as well as on the bracket, because the
    -- bracket itself may have scrolled off to the right.
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

    if index == self.editor.line and self.focus == "editor" then
      local caret = x0 + gutter + font:getWidth(line:sub(1, self.editor.col - 1))
      if (love.timer.getTime() * 2) % 2 < 1.2 then
        UI.setColor(Theme.coin)
        love.graphics.rectangle("fill", caret, y, 2, line_h)
      end
    end
  end
  self.pane:draw_brackets()
  love.graphics.setScissor()
  love.graphics.setColor(1, 1, 1, 1)

  -- The scrollbar, and the submit button.
  local total = self.editor:line_count()
  if total > rows then
    local track_h = rect.h - 8
    local knob = math.max(16, track_h * rows / total)
    local ky = rect.y + 4 + (track_h - knob) * (self.editor.scroll / math.max(1, total - rows))
    UI.setColor(Theme.cream, 0.25)
    love.graphics.rectangle("fill", rect.x + rect.w - 6, ky, 3, knob)
    love.graphics.setColor(1, 1, 1, 1)
  end

  -- RUN and SUBMIT, with a deliberate gap between them.
  --
  -- RUN is the reflex button and keeps F5, the key it has always had here.
  -- SUBMIT is the deliberate one: F10, five keys away, and the right-hand
  -- button of the pair. A hand going for RUN cannot land on SUBMIT by being
  -- a centimetre off, and a finger going for F5 cannot submit.
  local bh = 28
  local gap = 22
  local bw = math.min(150, math.floor((rect.w - 30 - gap) / 2))
  local by = rect.y + rect.h - bh - 8
  local sx = rect.x + rect.w - bw - 10
  local rx = sx - gap - bw

  local busy = self.running_mode ~= nil
  local usable = (self.quest ~= nil) and not busy

  -- FORMAT sits on the far left of the row, apart from the pair that costs
  -- something. It changes the buffer and nothing else — never recorded, no
  -- attempt, no mistake (§4.9d) — so it must not read as a third way to
  -- submit.
  local fw = math.min(96, math.floor(bw * 0.7))
  local fx = rect.x + 10
  UI.button(fx, by, fw, bh,
    self.formatting and "…" or "FORMAT  F2",
    (usable and not self.format_unsupported) and "normal" or "disabled", 8)
  self.format_rect = { x = fx, y = by, w = fw, h = bh }

  UI.button(rx, by, bw, bh,
    self.running_mode == "quest.run" and "RUNNING…" or "RUN  F5",
    (usable and not self.run_unsupported) and "normal" or "disabled", 9)
  UI.button(sx, by, bw, bh,
    self.running_mode == "quest.submit" and "JUDGING…" or "SUBMIT  F10",
    usable and "hot" or "disabled", 9)
  self.run_rect = { x = rx, y = by, w = bw, h = bh }
  self.submit_rect = { x = sx, y = by, w = bw, h = bh }

  -- What each one is for, under the button it belongs to.
  local tests = (self.quest and self.quest.tests) or {}
  local visible = #(tests.visible or {})
  local hidden = tests.hidden_count or 0
  UI.text(self.run_unsupported and "not on this server"
      or ("%d sample%s"):format(visible, visible == 1 and "" or "s"),
    rx, by - 12, 7, Theme.withAlpha(self.run_unsupported and Theme.dim or Theme.cyan, 0.9))
  UI.text(hidden > 0 and ("+%d hidden"):format(hidden) or "all cases",
    sx, by - 12, 7, Theme.withAlpha(Theme.coin, 0.8))

  -- On the caption row with `1 sample` and `+2 hidden`, not eighteen pixels
  -- off the bottom of the well — which put it *inside* the button band, so
  -- the FORMAT button was printed over the top of it and neither could be
  -- read. Found by looking at a screenshot; no test would have caught it.
  local info = ("%d lines   %d bytes"):format(total, #self.editor:text())
  UI.text(info, rect.x + 10, by - 12, 7, Theme.withAlpha(Theme.cream, 0.45))

  -- §4.9d's `problem`, in the **hint** register rather than the failure one.
  -- A formatter pressed mid-edit meeting half-written code is the normal
  -- state of a text editor, not a fault, and the buffer was left alone.
  local said = self.format_problem or self.format_note
  if said then
    local colour = self.format_problem and Theme.coin or Theme.withAlpha(Theme.cyan, 0.9)
    -- Above the button row now, so it has the whole width of the well.
    local room = rect.w - 24
    for i, line in ipairs(UI.wrap(said, room, 7)) do
      if i <= 2 then
        UI.text(line, rect.x + 10, by - 34 + (i - 1) * 9, 7, colour)
      end
    end
  end
end

--- The run overlay: the four stages, then whatever has streamed in.
function Quest:draw_run_overlay()
  local vw, vh = Layout.vw, Layout.vh
  local w = math.min(vw - 40, Layout.isPortrait() and (vw - 24) or 620)
  local h = math.min(vh - 120, 300)
  local x = (vw - w) / 2
  local y = vh - h - 64

  UI.panel(x, y, w, h, { fill = Theme.withAlpha(Theme.ink, 0.96), tint = Theme.coin })

  local stage_index = STAGES[self.stage or ""] or 0
  local names = { "QUEUED", "COMPILING", "RUNNING", "JUDGING" }
  local sx = x + 12
  for i, name in ipairs(names) do
    local done = i < stage_index
    local now = i == stage_index
    local color = done and Theme.admit or (now and Theme.coin or Theme.dim)
    UI.text(name, sx, y + 10, 8, color)
    sx = sx + UI.textWidth(name, 8) + 14
  end
  local ms = ("%dms"):format(math.floor(self.elapsed_ms))
  UI.text(ms, x + w - 12 - UI.textWidth(ms, 8), y + 10, 8, Theme.withAlpha(Theme.cream, 0.7))
  if self.queued and self.queued > 0 then
    UI.text(("%d ahead"):format(self.queued), x + 12, y + 24, 7, Theme.coin)
  end

  UI.bar(x + 12, y + 26, w - 24, 6, stage_index / 4, Theme.coin)

  -- The compiler's own words, at the player's step: this is code too, and
  -- somebody who made the editor bigger did it because 18px was hard to read.
  local font = Assets.mono(Layout.codeSize(16))
  love.graphics.setFont(font)
  local line_h = font:getHeight()
  local top = y + 40
  local rows = math.floor((h - 52) / line_h)

  local lines = {}
  if self.log then
    -- The server labels rustc's stdout *and* stderr as `compile`, so the
    -- streams are shown in the order they first appeared rather than by a
    -- fixed list.
    for _, name in ipairs(self.log.order) do
      local stream_lines, tail = self.log:lines(name)
      for _, line in ipairs(stream_lines) do
        lines[#lines + 1] = { name = name, text = line }
      end
      if tail ~= "" then
        lines[#lines + 1] = { name = name, text = tail, partial = true }
      end
    end
    local report = self.log:gap_report()
    if report then
      lines[#lines + 1] = { name = "client", text = "… " .. report, gap = true }
    end
  end
  if #lines == 0 then
    lines[1] = { name = "", text = self.running_mode and "waiting for the compiler…" or "" }
  end

  local first = math.max(1, math.min(#lines - rows + 1, math.floor(self.log_scroll)))
  if self.log_scroll >= 1e8 then first = math.max(1, #lines - rows + 1) end
  love.graphics.setScissor(x + 8, top, w - 16, rows * line_h)
  for i = 0, rows - 1 do
    local entry = lines[first + i]
    if not entry then break end
    local color = Theme.cream
    if entry.gap then color = Theme.red
    elseif entry.name == "stderr" then color = Theme.brick
    elseif entry.name == "compile" then color = Theme.withAlpha(Theme.cream, 0.92) end
    UI.setColor(color)
    love.graphics.print(entry.text, x + 10, top + i * line_h)
  end
  love.graphics.setScissor()
  love.graphics.setColor(1, 1, 1, 1)

  if self.log and self.log.truncated then
    UI.text("output truncated at 256 KiB", x + 12, y + h - 16, 7, Theme.coin)
  end
  UI.text("F8 hide", x + w - 12 - UI.textWidth("F8 hide", 7), y + h - 16, 7,
    Theme.withAlpha(Theme.cream, 0.5))

  if self.run_attempt and not self.running_mode then
    self:draw_run_outcome(x, y, w)
  end
end

--- What a RUN came back with.
---
--- Drawn as a strip above the log, in **cyan** — never in `Theme.admit`, the
--- green this game uses for a clear, and never with the word ACCEPTED. A run
--- that passes means "the sample works, now submit", and a screen that said
--- anything stronger would be contradicted by the very next thing the player
--- does.
function Quest:draw_run_outcome(x, y, w)
  local a = self.run_attempt
  local passed = a.verdict == "accepted"
  local tests = (self.quest and self.quest.tests) or {}
  local hidden = tests.hidden_count or 0

  -- The note wraps, and the strip grows to hold it. The line about runs
  -- being kept is the one sentence on this screen that must not be clipped:
  -- half of it says the opposite of the whole of it.
  local note_lines
  if passed then
    note_lines = { hidden > 0
      and ("now SUBMIT — %d hidden case%s have not run yet"):format(
        hidden, hidden == 1 and "" or "s")
      or "now SUBMIT to record it against the node" }
  else
    note_lines = UI.wrap(
      "runs do not count against your stars — but they are kept, "
        .. "and what went wrong feeds your drills", w - 24, 7)
  end

  local h = 30 + #note_lines * 10
  local sy = y - h - 6
  -- A failed run shakes the strip — and **only** the strip. The editor is
  -- where somebody is reading their own program, and nothing on this screen
  -- may make that harder; shaking the code would be the worst thing this
  -- whole round could ship.
  local shx, shy = 0, 0
  if not passed and self.run_at then
    shx, shy = Anim.shake(Anim.now() - self.run_at, { duration = 0.3, amount = 4 })
  end
  love.graphics.push()
  love.graphics.translate(shx, shy)
  local tint = passed and Theme.cyan or (Theme.verdict[a.verdict] or Theme.brick)
  UI.setColor(Theme.ink, 0.96)
  love.graphics.rectangle("fill", x, sy, w, h)
  love.graphics.setLineWidth(2)
  UI.setColor(tint)
  love.graphics.rectangle("line", x + 1, sy + 1, w - 2, h - 2)
  love.graphics.setColor(1, 1, 1, 1)

  -- The headline. `SAMPLE PASSES`, not `ACCEPTED`.
  local headline = passed and "SAMPLE PASSES"
    or ({
      wrong_answer = "SAMPLE FAILS",
      compile_error = "DOES NOT COMPILE",
      runtime_error = "CRASHED",
      timeout = "TOO SLOW",
      output_limit = "TOO MUCH OUTPUT",
      internal_error = "THE RUNNER BROKE",
    })[a.verdict] or a.verdict:upper()
  UI.text(headline, x + 12, sy + 9, 11, tint)

  local counts = ("%d / %d samples"):format(a.tests_passed or 0, a.tests_total or 0)
  UI.text(counts, x + w - 12 - UI.textWidth(counts, 9), sy + 10, 9,
    Theme.withAlpha(Theme.cream, 0.85))

  -- The line that has to be exactly right (§4.9b). A run *is* saved and its
  -- mistakes *do* feed the drills; what it does not do is count against the
  -- node. "Runs aren't saved" would be false and is written nowhere.
  for i, line in ipairs(note_lines) do
    UI.text(line, x + 12, sy + 24 + (i - 1) * 10, 7, Theme.withAlpha(Theme.cream, 0.75))
  end
  love.graphics.pop()
end

-- -------------------------------------------------------------------- input

function Quest:textinput(text)
  if self.focus == "editor" then
    self.editor:textinput(text)
    SFX.play("type")
  end
end

function Quest:keypressed(key, mods)
  -- RUN keeps F5, the reflex key. SUBMIT is F10 — far enough away on the
  -- keyboard that neither is a slip of the other — and ctrl-shift-Enter for
  -- anyone whose hands already know that idiom.
  local cmd = mods.ctrl or mods.gui
  if key == "f5" or (cmd and not mods.shift and (key == "return" or key == "kpenter")) then
    self:run(); return true
  end
  if key == "f10" or (cmd and mods.shift and (key == "return" or key == "kpenter")) then
    self:submit(); return true
  end
  if key == "f6" then self:reset(); return true end
  -- F2, not F4: `main.lua` takes F1/F3/F4/F11 globally (orientation,
  -- scanlines, sound, fullscreen) before a scene ever sees them, and a
  -- FORMAT bound to one of those would silently never fire.
  if key == "f2" or (cmd and mods.shift and key == "f") then self:format(); return true end
  if key == "f7" then self:take_hint(); return true end
  if key == "f8" then self.show_log = not self.show_log; return true end
  if key == "f9" then self:external_edit(); return true end
  -- The pane toggle moved off F10 when SUBMIT took it; ctrl-TAB is the
  -- switch-pane gesture everywhere else anyway, and TAB alone still indents.
  if key == "tab" and cmd then
    self.focus = self.focus == "editor" and "brief" or "editor"
    return true
  end

  if self.focus == "editor" then
    if self.editor:keypressed(key, mods) then return true end
  else
    if key == "up" then self.brief_scroll = math.max(0, self.brief_scroll - 24); return true end
    if key == "down" then self.brief_scroll = self.brief_scroll + 24; return true end
    if key == "tab" then self.focus = "editor"; return true end
  end
  return false
end

function Quest:wheelmoved(_, dy)
  if self.show_log and self.log then
    self.log_follow = false
    self.log_scroll = math.max(1, (self.log_scroll >= 1e8 and 1e8 or self.log_scroll) - dy * 3)
    if dy < 0 then self.log_follow = nil end
    return
  end
  if self.focus == "editor" then
    self.editor:scroll_by(-dy * 3, self.visible_rows or 20)
  else
    self.brief_scroll = math.max(0, self.brief_scroll - dy * 30)
  end
end

function Quest:mousepressed(x, y, button)
  local brief, code = self:panes()
  local function inside(r)
    return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
  end
  -- The buttons sit inside the code well, so they are tested first. They also
  -- fire on the press and not the release, which is what makes a drag that
  -- started in the text and ended over SUBMIT harmless: the release does
  -- nothing at all.
  if inside(self.format_rect) then self:format(); return end
  if inside(self.run_rect) then self:run(); return end
  if inside(self.submit_rect) then self:submit(); return end
  if x >= brief.x and x <= brief.x + brief.w and y >= brief.y and y <= brief.y + brief.h then
    self.focus = "brief"
    return
  end
  -- Both shifts. The old hit test asked `isDown("lshift")` only, so
  -- shift-clicking with the right hand quietly placed the caret instead of
  -- extending the selection.
  local shift = love.keyboard.isDown("lshift", "rshift")
  if self.pane:mousepressed(x, y, button, shift) then
    self.focus = "editor"
    return
  end
  if inside(code) then self.focus = "editor" end
end

function Quest:mousemoved(x, y)
  if self.pane then self.pane:mousemoved(x, y) end
end

function Quest:mousereleased()
  if self.pane then self.pane:mousereleased() end
end

return Quest
