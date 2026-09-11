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
--
-- ## The draft, and the answer
--
-- Two more things this screen reads rather than owns:
--
--   * **`Quest.draft` (§4.8)** — the source of this player's own most recent
--     run or submit on this node. The editor opens on `draft ?? starter` and
--     there is **no save path in this file**: every RUN and SUBMIT already
--     sends the buffer, and the server has kept each one's source since SPEC
--     §2.2. Somebody who typed for ten minutes, quit the client and came back
--     finds their text, on this machine or another one, without ever having
--     pressed a save button. `null` under an interview (§4.9e), which needs
--     no branch here — the starter is the fallback either way.
--   * **`quest.solve` (§4.11b)** — the whole answer, in the editor, on one
--     press. Priced as the largest hint there is, so the node can still be
--     cleared but no longer at three stars; and *nothing is recorded by
--     asking*, because reading an answer is not a run of one. Both halves are
--     on screen, for the same reason the RUN copy above is exact: a control
--     that reads as free is a lie, and one that reads as a trap stops
--     somebody learning from a worked example.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
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
    -- §4.11b: what SOLVE said, in the hint register. `solve_unsupported`
    -- greys the button for the rest of the visit, the way FORMAT's does.
    solve_note = nil,
    solve_unsupported = false,
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
    -- §4.8: `draft ?? starter`. The draft is the source of this player's own
    -- most recent run or submit on this quest, and it costs this screen
    -- nothing to honour — every RUN and SUBMIT already sent the buffer, so
    -- there is **no save path here** and there must not be one. Come back to
    -- a node an hour later, or on another machine, and the editor opens on
    -- what you left rather than on the starter you had already replaced.
    --
    -- Only into a buffer the player has not touched, so a reconnect
    -- mid-quest does not eat what they were writing.
    if not self.editor.dirty then
      self.editor:set_text(Editor.opening_text(self.quest))
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
  -- The note row holds one thing at a time, and what SOLVE said belongs to
  -- the buffer as it was before this ran.
  self.solve_note = nil
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
        self.error = I18n.t("RUN is not on this server yet — SUBMIT still works")
        self.app:toast(self.error)
        return
      end
      if payload.code == "busy" then
        -- The other button is still going. Says which, because "busy" with
        -- no subject is the least useful message in any program.
        local running = (payload.detail or {}).running
        self.app:toast(running == "quest.run" and I18n.t("a run is still going")
          or I18n.t("a submission is already running"))
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
  self.solve_note = nil
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
        self.format_note = I18n.t("FORMAT is not on this server yet")
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
      self.format_note = I18n.t("already tidy")
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
    self.app:toast(I18n.t("starter code restored"))
  end)
end

function Quest:take_hint()
  if not self.quest then return end
  local index = self.quest.hints_used or 0
  if index >= (self.quest.hints_total or 0) then
    self.app:toast(I18n.t("no more hints"))
    return
  end
  self.app.session:request("quest.hint", { quest_id = self.quest.id, index = index },
    function(ok, payload, why)
      if not ok then self.app:toast(why.player); return end
      self.hint = payload.hint
      self.quest.hints_used = payload.hints_used or (index + 1)
      self.app:toast(I18n.t("hint %d of %d — costs stars",
        payload.index + 1, payload.total))
    end)
end

--- SOLVE (PROTOCOL §4.11b) — the whole answer, in the editor, now.
---
--- **Instant, and one undo step.** No confirmation dialog: somebody who has
--- been stuck for twenty minutes and reaches for the answer should get the
--- answer, not a modal asking whether they meant it. `Editor:replace_all` is
--- the same call FORMAT makes, so ctrl-Z puts their own code back in one
--- press — which is all the protection this needs, because nothing here is
--- irreversible in the editor.
---
--- **What it costs, and what it does not.** §4.11b prices this as the largest
--- hint there is: the server bumps `hints_used`, and SPEC §6.3's cascade only
--- ever asks whether any hint was taken, so this quest can still be cleared
--- but no longer at three stars. What it does *not* do is record anything —
--- there is no attempt here, nothing appears in `stats.history`, and only a
--- later SUBMIT writes to the record. Both halves are said on screen, because
--- a button that reads as free is a lie and a button that reads as a trap
--- stops somebody learning from a worked example.
---
--- `not_found` means either "there is no answer key on a live screen"
--- (§4.9e, interview) or "this server predates §4.11b" — identical on the
--- wire, the same trap RUN documents above. So the message says what is true
--- of both rather than guessing which.
function Quest:solve()
  if not self.quest or self.solving or self.solve_unsupported then
    if self.solve_unsupported then SFX.play("locked") end
    return
  end
  self.solving = true
  self.solve_note = nil
  SFX.play("move")

  self.app.session:request("quest.solve", { quest_id = self.quest.id },
    function(ok, payload, why)
      self.solving = false
      if not ok then
        SFX.play("locked")
        if payload.code == "not_found" then
          self.solve_unsupported = true
          self.solve_note = I18n.t("no answer key here")
        else
          self.solve_note = why.player
        end
        return
      end

      self.editor:replace_all(payload.source or self.editor:text())
      -- The server just moved it, so this screen's hint counter is stale by
      -- exactly one round trip. Taken from the payload rather than guessed.
      if payload.hints_used then self.quest.hints_used = payload.hints_used end
      self.solve_note = I18n.t("the answer is in the editor — CTRL-Z puts yours "
        .. "back. It can still clear, just not at three stars, and asking is "
        .. "not an attempt — only SUBMIT records one")
      SFX.play("select")
    end)
end

--- The honest fallback: hand the buffer to `$EDITOR` and read it back.
function Quest:external_edit()
  local text, err = External.edit(self.editor:text(), self.quest and self.quest.land or "rust")
  if not text then
    self.app:toast(err or I18n.t("could not open $EDITOR"))
    return
  end
  self.editor:push_undo(false)
  self.editor:set_text(text)
  self.editor.dirty = true
  self.app:toast(I18n.t("loaded back from $EDITOR"))
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
--- The header band's height, measured from the two lines of type in it.
---
--- It was a hard 48 px, which fitted a 13 px title over a 7 px id. At twice
--- that ladder the id was printed through the title and the editor pane
--- started underneath both.
function Quest:header_h()
  return math.max(48, 8 + UI.lineHeight(13) + 2 + UI.lineHeight(7) + 8)
end

function Quest:panes()
  local vw, vh = Layout.vw, Layout.vh
  local top = self:header_h()
  local bottom = math.max(56, UI.footerHeight() + UI.lineHeight(9) + 14)
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
  local head = self:header_h()
  local row1 = 8
  local row2 = 8 + UI.lineHeight(13) + 2
  UI.setColor(Theme.ink, 0.9)
  love.graphics.rectangle("fill", 0, 0, vw, head)
  love.graphics.setColor(1, 1, 1, 1)
  -- **The title is the quest's own, and it is not translated** (SPEC §1.1 is
  -- the client's store; the quests are content and belong to another repo).
  -- It is drawn beside its id, in the land's tint, so a Korean player reads
  -- it as the identifier it is rather than as a sentence somebody forgot.
  local title = self.quest and self.quest.title or (self.error or I18n.t("loading…"))
  UI.text(title, 12, row1, 13, tint)
  UI.text(self.quest_id or "", 12, row2, 7, Theme.withAlpha(Theme.cream, 0.55))
  self:draw_clock(vw)

  if self.quest then
    -- Earned stars get the star; difficulty gets pips (design review §4).
    local star = math.max(10, math.floor(UI.lineHeight(7) * 0.8))
    local caption = UI.lineHeight(7)
    UI.text(I18n.t("STARS"), vw - 12 - 3 * (star + 3)
      - UI.textWidth(I18n.t("STARS") .. " ", 7), row1 + (star - caption) / 2, 7,
      Theme.withAlpha(Theme.cream, 0.6))
    UI.stars(vw - 12 - 3 * (star + 3), row1, self.quest.stars or 0, star)
    local pip = math.max(6, math.floor(star * 0.6))
    local pw = UI.pipsWidth(pip)
    UI.text(I18n.t("DIFFICULTY"), vw - 12 - pw - UI.textWidth(I18n.t("DIFFICULTY") .. " ", 7),
      row2, 7, Theme.withAlpha(Theme.cream, 0.6))
    UI.pips(vw - 12 - pw, row2 + (caption - pip * 2) / 2, self.quest.difficulty or 1, pip)
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
  self.app:footer(I18n.t("F6 reset   F7 hint   F8 log   F9 $EDITOR   ESC map"))
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
  local size = (state.phase == "overtime" and 15 or 14)
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
      y = y + UI.text(I18n.t("CONCEPTS"), x, y, 8, Theme.withAlpha(Theme.cream, 0.6)) + 4
      for _, line in ipairs(UI.wrap(table.concat(self.quest.concepts, ", "), column, 8)) do
        y = y + UI.text(line, x, y, 8, tint) + 3
      end
      y = y + 8
    end

    local tests = self.quest.tests or {}
    -- A `("…"):format(…)` call, which is why the sweep that found every
    -- `I18n.t` site walked past it: it does not look like a string being
    -- drawn until you read the line. Given a width for the same reason.
    y = y + UI.text(I18n.t("TESTS  match %s   %d hidden",
      tostring(tests.match or "?"), tests.hidden_count or 0), x, y, 8,
      Theme.withAlpha(Theme.cream, 0.6), "left", indent) + 6
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
      y = y + UI.text(I18n.t("HINT"), x, y, 8, Theme.coin) + 4
      for _, line in ipairs(UI.wrap(self.hint, column, 8)) do
        y = y + UI.text(line, x, y, 8, Theme.coin) + 3
      end
    end
    local hints = I18n.t("hints %d/%d  (F7)",
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
  -- **Measured from their own labels.** `SUBMIT  F10` at the old 9 px ladder
  -- was 99 px wide inside a 150 px button; at twice the ladder it is 264, and
  -- a fixed width printed `SUBMIT  F1` and then stopped. The gap between RUN
  -- and SUBMIT is kept whatever else gives way — it is the reason the two are
  -- laid out at all (reaching for RUN must never land on SUBMIT).
  local run_label = self.running_mode == "quest.run" and I18n.t("RUNNING…") or I18n.t("RUN  F5")
  local submit_label = self.running_mode == "quest.submit"
    and I18n.t("JUDGING…") or I18n.t("SUBMIT  F10")
  local format_label = self.formatting and "…" or I18n.t("FORMAT  F2")
  local solve_label = self.solving and "…" or I18n.t("SOLVE  SHIFT-F7")
  local bh = math.max(28, UI.lineHeight(9) + 12)
  local gap = 22
  local want = math.max(UI.textWidth(run_label, 9), UI.textWidth(submit_label, 9)) + 20
  -- The left-hand cluster is two buttons now, and both are measured from
  -- their own labels for the reason the pair on the right is: `SOLVE
  -- SHIFT-F7` in Czech is not `SOLVE  SHIFT-F7` in English, and a width
  -- written as a number prints half a word at the other end of the language
  -- list. The `gap` stays a subtracted term and is never divided up.
  --
  -- **The right-hand pair is measured first and keeps its labels.** The left
  -- cluster is subtracted as a floor, not as its full want: sizing RUN and
  -- SUBMIT around whatever SOLVE and FORMAT would like is how `SUBMIT  F10`
  -- became `SUBMIT  F1` the last time, and this screen has that mistake
  -- written down.
  local left_gap = 8
  local left_floor = 100
  -- The caption row's height, needed here as well as below: when the buffer
  -- buttons take a row of their own, the captions belonging to RUN and SUBMIT
  -- have to fit *between* the two rows rather than through the upper one.
  local cap = UI.lineHeight(7) + 3
  local room = math.floor((rect.w - 30 - gap - left_floor - 10) / 2)
  local bw = math.max(60, math.min(want, room))
  local by = rect.y + rect.h - bh - 8
  local sx = rect.x + rect.w - bw - 10
  local rx = sx - gap - bw

  local busy = self.running_mode ~= nil
  local usable = (self.quest ~= nil) and not busy

  -- The left of the row is the two buttons that only ever change the buffer:
  -- **SOLVE, then FORMAT**, then a wide gap, then the pair that costs
  -- something. Neither of the left two writes an attempt (§4.9d, §4.11b), and
  -- neither must read as a third way to submit.
  --
  -- SOLVE is the far-left button on purpose: FORMAT stands between it and
  -- RUN, so the one control on this screen that gives the answer away cannot
  -- be reached by a press that was aimed a centimetre wide of RUN.
  local sw = UI.textWidth(solve_label, 8) + 16
  local fw = UI.textWidth(format_label, 8) + 16
  local left_room = rx - rect.x - 20
  -- Which row the two of them sit on. Beside RUN and SUBMIT when they fit
  -- there; **on their own row above** when they do not, which is portrait in
  -- every language and landscape in Czech. Four full labels do not fit across
  -- 720 virtual pixels, and of the three ways out — shrink the pair on the
  -- right, shrink the type, or use the empty row above — only the last one
  -- costs nothing. The well has that row spare on every screen this game
  -- draws, and the wide gap between the reflex button and the deliberate one
  -- survives untouched.
  local ly = by
  if sw + left_gap + fw > left_room then
    ly = by - bh - 6 - cap
    left_room = rect.w - 20
    if sw + left_gap + fw > left_room then
      -- Narrower still: both give way together rather than one eating the
      -- other, with a floor that still shows a word.
      local scale = (left_room - left_gap) / (sw + fw)
      sw = math.max(44, math.floor(sw * scale))
      fw = math.max(44, math.floor(fw * scale))
    end
  end
  local vx = rect.x + 10
  local fx = vx + sw + left_gap
  UI.button(vx, ly, sw, bh, solve_label,
    (usable and not self.solve_unsupported) and "normal" or "disabled", 8)
  self.solve_rect = { x = vx, y = ly, w = sw, h = bh }
  UI.button(fx, ly, fw, bh, format_label,
    (usable and not self.format_unsupported) and "normal" or "disabled", 8)
  self.format_rect = { x = fx, y = ly, w = fw, h = bh }

  UI.button(rx, by, bw, bh, run_label,
    (usable and not self.run_unsupported) and "normal" or "disabled", 9)
  UI.button(sx, by, bw, bh, submit_label, usable and "hot" or "disabled", 9)
  self.run_rect = { x = rx, y = by, w = bw, h = bh }
  self.submit_rect = { x = sx, y = by, w = bw, h = bh }

  -- What each one is for, under the button it belongs to.
  local tests = (self.quest and self.quest.tests) or {}
  local visible = #(tests.visible or {})
  local hidden = tests.hidden_count or 0
  -- Singular and plural as two translatable strings, the same as the streak
  -- on the stats screen. One "%d samples" for both reads "1 samples" in the
  -- source language, which is the language that has no excuse.
  UI.text(self.run_unsupported and I18n.t("not on this server")
      or (visible == 1 and I18n.t("%d sample", 1) or I18n.t("%d samples", visible)),
    rx, by - cap, 7, Theme.withAlpha(self.run_unsupported and Theme.dim or Theme.cyan, 0.9))
  -- Under the SUBMIT button, so it gets the button's width and no more.
  UI.text(hidden > 0 and I18n.t("+%d hidden", hidden) or I18n.t("all cases"),
    sx, by - cap, 7, Theme.withAlpha(Theme.coin, 0.8), "left", bw)

  -- **What SOLVE costs, said before it is pressed.** Under its own button, in
  -- the same caption row and the same register as `+2 hidden`: revealing the
  -- answer is priced as the largest hint there is (§4.11b), so the third star
  -- goes. One clause, because a button whose caption is a paragraph reads as
  -- a warning and this is a price. The rest of the story — that nothing is
  -- recorded by asking — is in the note the press itself puts up, where
  -- somebody is actually looking.
  UI.text(self.solve_unsupported and I18n.t("no answer key here")
      or I18n.t("costs a star"),
    vx, ly - cap, 7,
    Theme.withAlpha(self.solve_unsupported and Theme.dim or Theme.coin, 0.85),
    "left", sw)

  -- On the caption row with `1 sample` and `+2 hidden`, not eighteen pixels
  -- off the bottom of the well — which put it *inside* the button band, so
  -- the FORMAT button was printed over the top of it and neither could be
  -- read. Found by looking at a screenshot; no test would have caught it.
  --
  -- It sits to the right of the two buffer buttons rather than at the left
  -- margin, which is where SOLVE's own caption now is, and is dropped rather
  -- than overprinted when a narrow window leaves it no room.
  local info = I18n.t("%d lines   %d bytes", total, #self.editor:text())
  -- Always just past FORMAT, on whichever row FORMAT is on — because the row
  -- *below* an upper button row is the button row itself, and printing a dim
  -- line there puts it through the labels. `by - 12` was right when there was
  -- one row and is a stripe across two.
  local two_rows = ly ~= by
  -- Two rows frees the left margin of the *lower* caption row, which is where
  -- this line has always lived; one row does not, because SOLVE's own caption
  -- is there, so it goes just past FORMAT instead.
  local ix = two_rows and (rect.x + 10) or (fx + fw + 10)
  local iy = two_rows and (by - cap) or (by - 12)
  local limit = rx - 8
  if ix + UI.textWidth(info, 7) < limit then
    UI.text(info, ix, iy, 7, Theme.withAlpha(Theme.cream, 0.45))
  end

  -- The note row, in the **hint** register rather than the failure one, and
  -- shared by the two buttons on the left because only one of them can have
  -- spoken last:
  --
  --   * §4.9d's `problem` — a formatter pressed mid-edit meeting half-written
  --     code is the normal state of a text editor, not a fault, and the
  --     buffer was left alone.
  --   * §4.11b's aftermath — what the answer just cost, and what it did not.
  --     Three lines rather than two, because that sentence has to arrive
  --     whole: half of it says the opposite of the whole of it.
  local said = self.format_problem or self.format_note or self.solve_note
  if said then
    local colour = (self.format_problem or self.solve_note) and Theme.coin
      or Theme.withAlpha(Theme.cyan, 0.9)
    -- Above the button row, so it has the whole width of the well, and
    -- measured **upward** from the caption row so the last line cannot land
    -- on `costs a star` however many lines it took. Four of them, on a plate:
    -- at 7px in a portrait well this sentence is four lines, the first draft
    -- allowed three, and what a player actually read was "... only SUBMIT
    -- records" with the word `one` cut off — the precise failure the RUN copy
    -- above is written to avoid. The plate is the clock's trick: this is an
    -- overlay over somebody's program, and unreadable advice printed through
    -- their own code is worse than none.
    local lines = UI.wrap(said, rect.w - 28, 7)
    local lh = UI.lineHeight(7)
    local shown = math.min(#lines, 4)
    local top = math.min(by, ly) - cap - 6 - shown * lh
    UI.setColor(Theme.ink, 0.88)
    love.graphics.rectangle("fill", rect.x + 4, top - 5, rect.w - 8, shown * lh + 10)
    love.graphics.setColor(1, 1, 1, 1)
    for i = 1, shown do
      UI.text(lines[i], rect.x + 10, top + (i - 1) * lh, 7, colour)
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
    lines[1] = { name = "",
      text = self.running_mode and I18n.t("waiting for the compiler…") or "" }
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
    UI.text(I18n.t("output truncated at 256 KiB"), x + 12, y + h - 16, 7, Theme.coin)
  end
  UI.text(I18n.t("F8 hide"), x + w - 12 - UI.textWidth("F8 hide", 7), y + h - 16, 7,
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
    -- Three whole sentences that the `I18n.t` sweep walked past, because
    -- they are built with `:format` and `UI.wrap` rather than passed to it.
    note_lines = { hidden > 0
      and (hidden == 1
        and I18n.t("now SUBMIT — %d hidden case has not run yet", hidden)
        or I18n.t("now SUBMIT — %d hidden cases have not run yet", hidden))
      or I18n.t("now SUBMIT to record it against the node") }
  else
    note_lines = UI.wrap(
      I18n.t("runs do not count against your stars — but they are kept, "
        .. "and what went wrong feeds your drills"), w - 24, 7)
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

  local counts = I18n.t("%d / %d samples", a.tests_passed or 0, a.tests_total or 0)
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
  -- SOLVE is **shift-F7**, and the reason is arithmetic before it is taste:
  -- every one of F1..F12 is already spoken for on this screen — F1/F3/F4/F11/
  -- F12 globally in `main.lua` (orientation, scanlines, sound, fullscreen,
  -- type size) and F2/F5/F6/F7/F8/F9/F10 here. There was no free key to pick.
  --
  -- A modifier on the *hint* key is the better answer anyway. §4.11b prices
  -- the answer as "the largest hint there is", and that is exactly what
  -- shift-F7 reads as with a hand on the keyboard: the same key, more of it.
  -- It is also five keys from RUN and three from SUBMIT, which is the
  -- distance this screen has always kept between a reflex and a decision.
  -- Tested before plain F7 so the bare key still takes an ordinary hint, and
  -- `ctrl` is excluded so a ctrl-shift-F7 aimed at something else misses.
  if key == "f7" and mods.shift and not cmd then self:solve(); return true end
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
  if inside(self.solve_rect) then self:solve(); return end
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
