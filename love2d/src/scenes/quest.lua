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
--
-- ## The edit stack — UNDO, REDO and CLEAR
--
-- A third thing this screen reads rather than owns, and the newest. The
-- server keeps a stack with a cursor per `(address, quest)`, persisted, so
-- the history of a node follows the player between this client and the
-- browser one and survives a reload. `src/net/edits.lua` speaks the five
-- messages and owns the two rules that decide whether a button is live;
-- everything here does is push at the right moments and draw what came back.
--
-- Two pieces of that are worth reading before changing anything:
--
--   * **A stack step is a thought, not a keystroke.** The buffer goes onto
--     the stack on RUN and SUBMIT — the moments its bytes already reach the
--     server — and otherwise 1.5 s after the typing stops. `src/editor.lua`
--     keeps the fine-grained history; this one keeps the coarse one, and the
--     two are deliberately different instruments.
--   * **A reply must never provoke a push.** Undoing replaces the buffer,
--     which bumps the editor's revision, which the idle timer below would
--     otherwise read as typing — and a push truncates the redo tail. One
--     undo, a pause, and redo would be gone. `edit_rev` records the revision
--     every reply leaves behind so that cannot happen; it is the single most
--     load-bearing line in this half of the file.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Sparks = require("src.sparks")
local Land = require("src.land")
local Editor = require("src.editor")
local CodePane = require("src.codepane")
local runlog = require("src.net.runlog")
local Edits = require("src.net.edits")
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
---
--- The two newer lands reuse the six plates rather than commissioning more.
--- C++ is the typhoon shelter and the pump room: the street outside at noon
--- for BASIC, and `bg_datacentre` — the one plate that is all machinery, and
--- the only one no other land had taken — for ADVANCED, where the quests are
--- threads holding buffers. Python is the wet market and the food hall: the
--- till, with its price board, for BASIC, and Times Square's crowd for
--- ADVANCED, twelve stalls and one lock. HACKER is Room 7-32 in every land,
--- because the interview is the same interview.
function Quest.backdrop(land, category)
  if category == "hacker" then
    return Assets.pick("bg_room732", "bg_flat", "bg_night")
  end
  local advanced = category == "advanced"
  if land == "go" then
    return Assets.pick(advanced and "bg_mtr" or "bg_till", "bg_mtr", "bg_flat")
  end
  if land == "cpp" then
    return Assets.pick(advanced and "bg_datacentre" or "bg_street", "bg_street", "bg_flat")
  end
  if land == "python" then
    return Assets.pick(advanced and "bg_times" or "bg_till", "bg_till", "bg_flat")
  end
  return Assets.pick(advanced and "bg_times" or "bg_street", "bg_street", "bg_flat")
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
    solving = false,
    -- CODE: the editor with the screen to itself. The brief, the band and
    -- the console are one press away and the code is what the screen is for.
    code_mode = false,
    -- ANSWER: the reference solution behind what the player types.
    --
    -- It is the same answer SOLVE fetches and it is priced the same way
    -- (§4.11b, a star), because it is the same knowledge. What differs is
    -- what happens to it: SOLVE *replaces* the buffer and the sitting is
    -- over; ANSWER puts it behind the caret as a target and every character
    -- is typed by the player. That is the difference between being told and
    -- remembering, and remembering is the point of this trainer.
    answer_text = nil,
    answer_on = false,
    answer_busy = false,
    answer_prog = { matched = 0, wrong = 0, done = false, total = 0 },
    answer_seen = nil,
    sparks = Sparks.new(),
    -- The server's edit stack. `nil` means "this screen has not been told",
    -- which is also what a server without the feature leaves behind, and
    -- every predicate in `src/net/edits.lua` answers `false` for it — so the
    -- three buttons are grey until something says otherwise.
    edit = nil,
    edit_unsupported = false,
    -- One `edit.*` message in flight at a time. They all rewrite the same
    -- stack, and two crossing on the wire would land in whichever order the
    -- network chose.
    edit_busy = false,
    -- The editor revision the stack was last in agreement with, and the one
    -- the idle timer last saw. See the header: without the first, an undo
    -- pushes itself back onto the stack a second and a half later.
    edit_rev = nil,
    edit_seen_rev = nil,
    edit_idle = 0,
    -- What CLEAR STACK said, in the hint register, resolved at draw time so
    -- the language button on this very screen still works.
    stack_note = nil,
    -- When CLEAR STACK was armed, so the second press is the one that acts.
    clear_armed = nil,
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
  -- Asked here and **not** in `refresh`: `refresh` fires again every time the
  -- language changes, and the stack has no locale — it is the same bytes in
  -- every language, and re-asking for it on a language switch would be a
  -- round trip that can only return what this screen already has.
  -- `true` for adopt, because **the stack wins over the draft** on open
  -- (PROTOCOL §4.11c). `draft` is a read of the last *attempt*, so it moves
  -- only when the player runs or submits; the stack also moves on the idle
  -- push and on undo and redo. Somebody who typed for a minute and closed the
  -- window without running has that minute on the stack and not in the draft,
  -- and opening on the draft would show them the older text and read as work
  -- lost — the exact failure persisting the stack exists to prevent.
  self:edit_ask(Edits.state, true)
end

function Quest:leave()
  self.app.session:off_all(self.subscriptions)
  self.subscriptions = nil
end

function Quest:refresh()
  self.error = nil
  -- PROTOCOL §4.8: the prose in the interface's language where the server
  -- has a translation pack for it; `payload.quest.text_locale` says which it
  -- actually got, and `draw_brief` reads that rather than assuming.
  self.asked_lang = I18n.lang
  self.app.session:request("quest.get", { quest_id = self.quest_id, locale = I18n.lang },
    function(ok, payload, why)
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
  self.stack_note = nil
  self.clear_armed = nil
  SFX.play("submit")

  -- The stack gets a step at the two moments the buffer already leaves this
  -- machine. A run or a submit is the clearest "I meant that" a player ever
  -- gives an editor, and the server's duplicate check makes a redundant one
  -- free.
  self:edit_push()

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
  -- And the stack's question, if one was up: a press on another button is an
  -- answer of "not now", and an armed CLEAR must not survive it.
  self.stack_note = nil
  self.clear_armed = nil
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
  -- F6 and SHIFT-F6 are neighbours, and a hand that reached for one after
  -- arming the other must not leave that arming behind for the next press.
  self.stack_note = nil
  self.clear_armed = nil
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
  self.app.session:request("quest.hint",
    { quest_id = self.quest.id, index = index, locale = I18n.lang },
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
--- How far the typed text still *is* the answer, and where it stopped.
---
--- A prefix, deliberately: ANSWER is a typing target read from the top, and
--- "the first place the two part company" is the thing to point at. Pure, so
--- `tests/test_quest.lua` can hold the rules.
function Quest.answer_progress(typed, answer)
  local k = 0
  local n = math.min(#typed, #answer)
  while k < n and typed:byte(k + 1) == answer:byte(k + 1) do k = k + 1 end
  return { matched = k, wrong = #typed - k, done = typed == answer, total = #answer }
end

--- What TAB completes in ANSWER mode: the rest of the line you are on.
---
--- **The rest of the line, and at a line's end the next line's indentation.**
--- Typing a whole solution character by character is the exercise; typing the
--- eight spaces at the start of a continuation line is not, and neither is the
--- tail of a line you have clearly already remembered. TAB is the pedal for
--- both.
---
--- `nil` when there is nothing to complete: the answer is typed, or — and
--- this is the one worth being strict about — the buffer has stopped being
--- the answer. Completing past a divergence would bury the mistake under
--- correct text and leave a buffer that cannot compile with no sign of where
--- it went wrong.
function Quest.answer_completion(typed, answer)
  if not answer or answer == "" then return nil end
  local p = Quest.answer_progress(typed, answer)
  if #typed ~= p.matched then return nil end
  local rest = answer:sub(p.matched + 1)
  if rest == "" then return nil end
  if rest:sub(1, 1) == "\n" then
    return "\n" .. (rest:sub(2):match("^[ \t]*") or "")
  end
  local nl = rest:find("\n", 1, true)
  return nl and rest:sub(1, nl - 1) or rest
end

--- Whether ANSWER should empty the buffer as it opens.
---
--- The starter is the server's boilerplate and against the answer it is
--- simply wrong text, so the mode would open on a screenful of red nobody
--- typed. It goes — **but only when it is exactly what the quest shipped.**
--- The editor may have opened on a saved draft instead, and a draft is the
--- player's own writing; clearing that would be this mode destroying work to
--- tidy its own display.
function Quest.clears_for_answer(buffer, starter)
  if not starter or starter:match("^%s*$") then return false end
  local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
  return trim(buffer) == trim(starter)
end

--- CODE on. ESC, or the DONE button, comes back.
function Quest:enter_code()
  if not self.quest then return end
  self.code_mode = true
  self.focus = "editor"
  SFX.play("select")
end

--- ANSWER on, ANSWER off. The first press pays for the answer; every press
--- after it is free, because the star is spent on knowing, not on looking.
function Quest:toggle_answer()
  if not self.quest or self.answer_busy or self.solve_unsupported then
    if self.solve_unsupported then SFX.play("locked") end
    return
  end
  if self.answer_on then
    self.answer_on = false
    SFX.play("move")
    return
  end
  if self.answer_text then
    self:arm_answer()
    return
  end
  self.answer_busy = true
  self.app.session:request("quest.solve", { quest_id = self.quest.id },
    function(ok, payload, why)
      self.answer_busy = false
      if not ok then
        SFX.play("locked")
        if payload.code == "not_found" then
          self.solve_unsupported = true
          self.solve_note = "unavailable"
        else
          self.solve_note = why.player
        end
        return
      end
      if payload.hints_used then self.quest.hints_used = payload.hints_used end
      self.answer_text = payload.source or ""
      self:arm_answer()
    end)
end

--- Switch the target on, clearing the boilerplate if that is all there is.
function Quest:arm_answer()
  if not self.answer_text then return end
  -- Written out rather than folded into an `or`: `tests/test_screens.lua`
  -- guards this file against ever reaching for the starter as a *fallback*
  -- (§4.8 opens on `draft ?? starter`), and the guard is a text search. What
  -- is wanted here is the starter itself, to compare against.
  local starter
  if self.quest then starter = self.quest.starter end
  if Quest.clears_for_answer(self.editor:text(), starter) then
    self.editor:replace_all("")
  end
  self.answer_on = true
  self.answer_lines = {}
  for chunk in (self.answer_text .. "\n"):gmatch("(.-)\n") do
    self.answer_lines[#self.answer_lines + 1] = chunk
  end
  -- `gmatch` over `text .. "\n"` gives one trailing empty piece for a source
  -- that already ended in a newline; it is not a line of the answer.
  if self.answer_text:sub(-1) == "\n" then
    self.answer_lines[#self.answer_lines] = nil
  end
  self.answer_prog = Quest.answer_progress(self.editor:text(), self.answer_text)
  self.answer_seen = self.editor:text()
  SFX.play("select")
end

--- What the last keystroke did to the target, as something to look at.
---
--- Four moments, and only the *moments*: a burst on every keystroke while a
--- line is wrong is noise, and noise is what a player stops seeing. The
--- divergence fires as it grows, getting back on target fires once, a line
--- fires when it closes, and the whole answer fires once, at the end.
function Quest:answer_tick()
  if not self.answer_on or not self.answer_text or not self.editor then return end
  local text = self.editor:text()
  if text == self.answer_seen then return end
  self.answer_seen = text
  local was = self.answer_prog
  local now = Quest.answer_progress(text, self.answer_text)
  self.answer_prog = now
  local x, y = self:caret_xy()
  if not x then return end
  if now.done and not was.done then
    self.sparks:add(x, y, 70, Theme.admit)
    SFX.play("accepted")
  elseif now.wrong > was.wrong or now.matched < was.matched then
    -- **The divergence *growing*, not merely existing.** A quest opens with
    -- boilerplate in the buffer that is already not the answer, so "wrong
    -- where it was right before" would never fire on the screen it is for.
    self.sparks:add(x, y, 10, Theme.red)
    SFX.play("rejected")
  elseif was.wrong > 0 and now.wrong == 0 then
    self.sparks:add(x, y, 20, Theme.cyan)
    SFX.play("move")
  elseif now.matched > was.matched
    and self.answer_text:sub(was.matched + 1, now.matched):find("\n", 1, true) then
    self.sparks:add(x, y, 16, Theme.coin)
    SFX.play("move")
  end
end

--- Where the caret is on screen, for an effect thrown at it.
function Quest:caret_xy()
  local geo = self.editor_geo
  if not geo or not self.editor then return nil end
  local row = self.editor.line - self.editor.scroll
  if row < 1 or row > (self.visible_rows or 0) then return nil end
  local line = self.editor.lines[self.editor.line] or ""
  local x = geo.x0 + geo.gutter + geo.font:getWidth(line:sub(1, self.editor.col - 1))
  local y = geo.y0 + (row - 1) * geo.line_h + geo.line_h / 2
  return x, y
end

function Quest:solve()
  -- `running_mode` is in the list because the button is painted `disabled`
  -- while a run or a submit is in flight, and a press that does something a
  -- greyed control says it will not do is worse than either behaviour on its
  -- own. (`Quest:format` still has that gap; it is not this round's to close.)
  if not self.quest or self.solving or self.solve_unsupported
    or self.running_mode then
    if self.solve_unsupported then SFX.play("locked") end
    return
  end
  self.solving = true
  self.solve_note = nil
  self.stack_note = nil
  self.clear_armed = nil
  SFX.play("move")

  self.app.session:request("quest.solve", { quest_id = self.quest.id },
    function(ok, payload, why)
      self.solving = false
      if not ok then
        SFX.play("locked")
        if payload.code == "not_found" then
          self.solve_unsupported = true
          self.solve_note = "unavailable"
        else
          self.solve_note = why.player
        end
        return
      end

      self.editor:replace_all(payload.source or self.editor:text())
      -- The server just moved it, so this screen's hint counter is stale by
      -- exactly one round trip. Taken from the payload rather than guessed.
      if payload.hints_used then self.quest.hints_used = payload.hints_used end
      -- The *kind* of thing that happened, not the sentence: the language
      -- button is on the footer of this very screen, and a sentence resolved
      -- at request time would still be in the old language a press later.
      self.solve_note = "solved"
      SFX.play("select")
    end)
end

--- What SOLVE has to say, in whatever language is current *now*.
function Quest:solve_said()
  local note = self.solve_note
  if not note then return nil end
  if note == "solved" then
    return I18n.t("the answer is in the editor — CTRL-Z puts yours "
      .. "back. It can still clear, just not at three stars, and asking is "
      .. "not an attempt — only SUBMIT records one")
  end
  if note == "unavailable" then return I18n.t("no answer key here") end
  -- Anything else is the error's own player-facing text, already resolved.
  return note
end

-- ----------------------------------------------------------- the edit stack

--- How long the typing has to stop before the buffer goes on the stack.
---
--- 1.5 s is the browser client's number and the reasoning is the same: a
--- stack step should be a thought. Shorter and the history fills with
--- half-typed identifiers; much longer and a player who types, thinks and
--- then presses UNDO finds the step they wanted was never taken.
Quest.PUSH_IDLE_S = 1.5

--- One path for `edit.state`, `edit.undo`, `edit.redo` and `edit.clear`,
--- which differ only in what the server does before answering: every one of
--- them replies with the whole state.
---
--- `adopt` is true for the two that move the cursor, and is what puts the
--- text at the new cursor into the editor.
function Quest:edit_ask(call, adopt, done)
  if not self.quest_id or self.edit_unsupported or self.edit_busy then return end
  self.edit_busy = true
  call(self.app.session, self.quest_id, function(ok, state, payload, why)
    self:edit_reply(ok, state, payload, why)
    if not ok then return end
    if adopt then self:adopt_stack_text(state) end
    if done then done(state) end
  end)
end

--- What every one of the five replies means to this screen.
---
--- **A stack this server has never heard of is not a failure the player
--- caused**, so nothing goes into `self.error` — that is the brief pane's red
--- band, and a node whose history is unavailable is not a node that failed to
--- load. The three buttons go grey for the rest of the visit instead, which
--- is what RUN and SOLVE already do about the same shape of gap (§4.9b,
--- §4.11b): identical on the wire, and a control that cannot work must read
--- as one that cannot work.
function Quest:edit_reply(ok, state, payload, why)
  self.edit_busy = false
  if not ok then
    if Edits.unsupported(payload) then
      -- This server has no stack and never will during this visit. Grey the
      -- three for good and stop asking.
      self.edit_unsupported = true
      self.stack_note = nil
      self.edit = nil
    elseif why then
      -- **Anything else leaves the last state standing.** A socket caught
      -- mid-reconnect answers `internal: not connected` the instant it is
      -- asked, and `edit.state` is asked exactly once — so dropping the state
      -- here would grey three working buttons for the rest of the visit
      -- because of one lost frame, and `tick_stack` would never push again.
      -- The state this screen holds is stale by one round trip at worst, and
      -- the next press or push corrects it.
      self.stack_note = why.player
    end
    return
  end
  self.edit = state
  -- The buffer and the stack agree as of this moment. Without this line the
  -- idle timer in `update` reads the server's own reply as typing and pushes
  -- it back a second and a half later, which truncates the redo tail — see
  -- the header. It is set for *every* reply, not only the two that replace
  -- the text, because a push's reply moves the revision too.
  self.edit_rev = self.editor and self.editor.rev
  self.edit_seen_rev = self.edit_rev
  self.edit_idle = 0
end

--- The text at the cursor, into the buffer, in **one** undo step.
---
--- `Editor:replace_all` is the call FORMAT and SOLVE make: the caret is
--- anchored to the text rather than to a coordinate, and the editor's own
--- ctrl-Z puts the buffer back in a single press. `set_text` would drop that
--- entry and with it the only protection an undo of an undo has.
---
--- A cursor at the bottom of the stack has no entry, and the quest's starter
--- is what belongs in the editor then. `Edits.text_for` is where that rule is
--- written, so it can be asserted without a window.
function Quest:adopt_stack_text(state)
  local quest = self.quest
  local starter = quest and quest.starter
  -- An empty stack has nothing to adopt: `text_for` would hand back the
  -- starter and wipe the draft the screen just opened on. UNDO and REDO can
  -- never be pressed at depth 0, so this only guards the open path.
  if (state.depth or 0) == 0 then return end
  self.editor:replace_all(Edits.text_for(state, starter))
  self.edit_rev = self.editor.rev
  self.edit_seen_rev = self.edit_rev
  self.edit_idle = 0
end

--- UNDO — one step back along the server's stack.
---
--- Refused when the button is grey, for the reason SOLVE gives: a press that
--- does something a greyed control says it will not do is worse than either
--- behaviour on its own.
function Quest:stack_undo()
  self.clear_armed = nil
  -- A message of its own is already on the wire. They all rewrite the same
  -- stack, so a second one would land in whichever order the network chose.
  if self.edit_busy then return end
  if not Edits.can_undo(self.edit) or self.running_mode then SFX.play("locked"); return end
  self.stack_note = nil
  SFX.play("move")
  self:edit_ask(Edits.undo, true)
end

--- REDO — one step forward, while the tail is still there. A push after an
--- undo drops that tail; that is the server's rule and this screen simply
--- stops offering the button when `cursor` has caught up with `depth`.
function Quest:stack_redo()
  self.clear_armed = nil
  if self.edit_busy then return end
  if not Edits.can_redo(self.edit) or self.running_mode then SFX.play("locked"); return end
  self.stack_note = nil
  SFX.play("move")
  self:edit_ask(Edits.redo, true)
end

--- CLEAR STACK — drop the history, keep the text.
---
--- **Two presses, and not a dialog.** SOLVE argues against a modal and is
--- right about SOLVE: what it does is one ctrl-Z away. This is not — the
--- stack is the only copy of a hundred steps, it is shared with the browser
--- client, and nothing brings it back. So the first press arms the button and
--- says in the note row exactly what the second one will do, which is a
--- sentence somebody can read without their hands leaving the keyboard, and
--- any other action disarms it.
---
--- What it does *not* touch is the editor. The buffer keeps whatever it is
--- showing and the editor keeps its own local history: clearing a history is
--- not an edit.
function Quest:stack_clear()
  -- Before the arming, not after: a confirmation the second press cannot act
  -- on is worse than no confirmation at all.
  if self.edit_busy then return end
  if not Edits.can_clear(self.edit) or self.running_mode then SFX.play("locked"); return end
  local now = Anim.now()
  if not (self.clear_armed and now - self.clear_armed < 6) then
    self.clear_armed = now
    self.stack_note = "confirm"
    SFX.play("locked")
    return
  end
  self.clear_armed = nil
  SFX.play("select")
  -- Said **after** the server agrees, not before. This screen already spells
  -- that rule out for SOLVE's hint counter — taken from the payload rather
  -- than guessed — and a line reading "the history is gone" over a history
  -- that is still there would be the same mistake in prose.
  self:edit_ask(Edits.clear, false, function() self.stack_note = "cleared" end)
end

--- Put the buffer on the stack.
---
--- Safe to call as often as this screen likes: a push whose source equals the
--- entry at the cursor is a no-op on the server, which is the property that
--- lets an idle timer drive it without filling a hundred slots with the same
--- function signature typed twice.
function Quest:edit_push()
  if not self.quest or self.edit_unsupported or self.edit_busy then return end
  local source = self.editor:text()
  -- Over the cap the server answers `bad_request`, and an autosave that fails
  -- is an autosave nobody sees fail. The buffer is left alone and the next
  -- push after it shrinks will take it.
  if #source > Edits.MAX_SOURCE_BYTES then return end
  self.edit_busy = true
  Edits.push(self.app.session, self.quest_id, source, function(ok, state, payload, why)
    self:edit_reply(ok, state, payload, why)
  end)
end

--- What the stack has to say, in whatever language is current *now* — the
--- same trick `solve_said` uses, and for the same reason: the language button
--- is on the footer of this very screen.
function Quest:stack_said()
  local note = self.stack_note
  if not note then return nil end
  if note == "confirm" then
    local depth = (self.edit and self.edit.depth) or 0
    return I18n.t("press CLEAR again to drop the %d steps behind this quest — "
      .. "the editor keeps the text it is showing, and so does CTRL-Z", depth)
  end
  if note == "cleared" then
    return I18n.t("the history is gone; the text in the editor is not")
  end
  -- Anything else is the error's own player-facing text, already resolved.
  return note
end

--- The caption under the three buttons: where the cursor is, and how deep the
--- stack goes. It is the only place a player is told the word `stack` at all,
--- which is why CLEAR can afford to be one word on its button.
function Quest:stack_caption()
  if self.edit_unsupported then return I18n.t("no stack here"), true end
  local state = self.edit
  if not state or state.depth == 0 then return I18n.t("stack empty"), true end
  return I18n.t("stack %d/%d", state.cursor, state.depth), false
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
  if self.quest and self.asked_lang and self.asked_lang ~= I18n.lang then
    -- The language changed under an open quest. The interface re-reads its
    -- own strings for free; the prose came from the server in the old
    -- language and has to be asked for again. `refresh` records the language
    -- it asked in before the reply lands, so this fires once per change.
    self:refresh()
  end
  self.t = self.t + dt
  self.sparks:update(dt)
  self:answer_tick()
  self:tick_clock()
  if self.running_mode then
    self.elapsed_ms = self.elapsed_ms + dt * 1000
  end
  self:tick_stack(dt)
end

--- The idle push: 1.5 s after the typing stops, and never because a reply
--- moved the text.
---
--- `editor.rev` is bumped by every mutation, including `replace_all` — which
--- is how an undo reaches the buffer. So the comparison is against
--- `edit_rev`, the revision the last reply left behind, and not against a
--- flag that only says "something changed": the difference is whether one
--- undo followed by a pause silently drops the whole redo tail.
---
--- Nothing is sent while a run is in flight either. `execute` has just pushed
--- the same bytes, and a second push mid-run would only race its own reply.
function Quest:tick_stack(dt)
  if not (self.editor and self.edit) or self.edit_unsupported then return end
  local rev = self.editor.rev
  if rev == self.edit_rev then
    self.edit_idle = 0
    return
  end
  if rev ~= self.edit_seen_rev then
    -- Still typing: the clock starts again from this keystroke.
    self.edit_seen_rev = rev
    self.edit_idle = 0
    return
  end
  self.edit_idle = (self.edit_idle or 0) + dt
  if self.edit_idle >= Quest.PUSH_IDLE_S and not self.running_mode then
    self.edit_idle = 0
    self:edit_push()
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

--- CODE mode: the editor with the screen to itself.
---
--- The brief, the console and the rest of the band are one press away and
--- the code is what the screen is for. The strip carries the four controls
--- the hands use while writing, ANSWER, and DONE — which ends the writing
--- session rather than the quest, and says so.
function Quest:draw_code()
  local vw, vh = Layout.vw, Layout.vh
  local land = (self.quest and self.quest.land) or self.app.land or "rust"
  Assets.cover(Quest.backdrop(land, self.quest and self.quest.category
    or self.app.category), 0, 0, vw, vh)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.86)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local pad = 8
  local bh = math.max(28, UI.lineHeight(9) + 12)
  local gap = 8
  local busy = self.running_mode ~= nil
  local usable = (self.quest ~= nil) and not busy
  local live = usable and not self.edit_unsupported

  local done_label = I18n.t("DONE")
  local dw = UI.textWidth(done_label, 8) + 20
  local dx = vw - pad - dw

  -- The row, flowed left to right and wrapped when the screen is narrow —
  -- a phone in portrait, or the largest type step.
  local items = {
    { id = "run", label = self.running_mode == "quest.run" and I18n.t("RUNNING…") or I18n.t("RUN  F5"),
      state = (usable and not self.run_unsupported) and "hot" or "disabled" },
    { id = "format", label = I18n.t("FORMAT"),
      state = (usable and not self.format_unsupported) and "normal" or "disabled" },
    { id = "undo", label = I18n.t("UNDO"),
      state = (live and Edits.can_undo(self.edit)) and "normal" or "disabled" },
    { id = "redo", label = I18n.t("REDO"),
      state = (live and Edits.can_redo(self.edit)) and "normal" or "disabled" },
    { id = "answer", label = I18n.t("ANSWER"),
      state = self.answer_on and "hot"
        or ((usable and not self.solve_unsupported) and "normal" or "disabled") },
  }
  self.code_rects = {}
  local x, y = pad, pad
  local room = dx - pad * 2
  for _, item in ipairs(items) do
    local w = UI.textWidth(item.label, 8) + 20
    if x > pad and x + w > pad + room then
      x = pad
      y = y + bh + 6
    end
    UI.button(x, y, w, bh, item.label, item.state, 8)
    self.code_rects[item.id] = { x = x, y = y, w = w, h = bh }
    x = x + w + gap
  end
  UI.button(dx, pad, dw, bh, done_label, "normal", 8)
  self.code_done_rect = { x = dx, y = pad, w = dw, h = bh }

  -- The file, and — in ANSWER mode — how much of it is already yours. The
  -- count is the whole scoreboard: characters typed that *are* the answer.
  local rowsb = y + bh
  -- The land, rather than a filename this client has never had: what the
  -- strip owes the player here is which language they are writing.
  local status = I18n.t(Land.name(land))
  local colour = Theme.withAlpha(Theme.cream, 0.55)
  if self.answer_on then
    local p = self.answer_prog
    status = ("%s   %d / %d"):format(status, p.matched, p.total)
    if p.done then
      status = status .. "   " .. I18n.t("MATCHED")
      colour = Theme.admit
    elseif p.wrong > 0 then
      status = status .. "   " .. I18n.t("FIX THE RED")
      colour = Theme.red
    else
      status = status .. "   " .. I18n.t("TAB completes the line")
      colour = Theme.coin
    end
  end
  local strip = rowsb + 4 + UI.lineHeight(7) + 4
  UI.setColor(Theme.ink, 0.82)
  love.graphics.rectangle("fill", 0, 0, vw, strip)
  love.graphics.setColor(1, 1, 1, 1)
  -- Painted after the plate, so the plate is behind them and not over them.
  for _, item in ipairs(items) do
    local r = self.code_rects[item.id]
    UI.button(r.x, r.y, r.w, r.h, item.label, item.state, 8)
  end
  UI.button(dx, pad, dw, bh, done_label, "normal", 8)
  UI.text(status, pad + 4, rowsb + 4, 7, colour)

  local top = strip + 6
  self:draw_editor({ x = pad, y = top, w = vw - pad * 2, h = vh - top - pad },
    Theme.land[land] or Theme.coin, true)
  self.sparks:draw()
end

function Quest:draw()
  local vw, vh = Layout.vw, Layout.vh
  if self.code_mode then
    self:draw_code()
    self.app:footer(I18n.t("ESC done   F5 run   F2 format"))
    return
  end
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
  -- **The title is whatever language the server sent it in.** Quests are
  -- content, translated pack by pack under `content/i18n/` (SPEC §12.1) and
  -- never here; `quest.text_locale` says which language arrived. It is drawn
  -- beside its id, in the land's tint, so when no translation exists yet a
  -- Korean player reads the English title as the identifier it is rather
  -- than as a sentence somebody forgot.
  local title = self.quest and self.quest.title or (self.error or I18n.t("loading…"))
  -- Clipped short of the right-hand cluster rather than printed through it:
  -- at the largest type step a title is wider than a portrait header.
  local cluster = self.quest and (UI.textWidth(I18n.t("DIFFICULTY") .. " ", 7)
    + math.max(UI.pipsWidth(math.max(6, math.floor(math.max(10, math.floor(UI.lineHeight(7) * 0.8)) * 0.6))),
      3 * (math.max(10, math.floor(UI.lineHeight(7) * 0.8)) + 3)) + 24) or 0
  -- And at the size that fits that room, before the scissor: `THE FARE B`
  -- is not a title.
  local title_room = math.max(40, vw - cluster - 12) - 12
  local title_size = UI.fitSize(title, title_room, 13, 7)
  local id_size = UI.fitSize(self.quest_id or "", title_room, 7, 4)
  love.graphics.setScissor(0, 0, math.max(40, vw - cluster - 12), head)
  UI.text(title, 12, row1 + (UI.lineHeight(13) - UI.lineHeight(title_size)) / 2, title_size, tint)
  UI.text(self.quest_id or "", 12, row2, id_size, Theme.withAlpha(Theme.cream, 0.55))
  love.graphics.setScissor()
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

  if self:console_open() then
    self:draw_run_overlay(self.console_rect_drawn)
    self.sparks:draw()
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
  -- The prose at 8, or the first size under it that puts fourteen
  -- characters on a line: a brief column eight characters wide at the
  -- largest type step in landscape wrapped `tram-stop` as `tram-sto` / `p`.
  local prose = UI.fitSize(("M"):rep(14), column, 8, 5)
  local indent = column - 10

  if self.error then
    for _, line in ipairs(UI.wrap(self.error, column, 9)) do
      y = y + UI.text(line, x, y, 9, Theme.red) + 4
    end
  end

  if self.quest then
    -- The prose is in `self.quest.text_locale` (English when the server has
    -- no translation for this quest); the labels around it are in
    -- `I18n.lang`. When the two differ the brief is drawn in the code face's
    -- cream rather than dimmed or flagged: an English specification under a
    -- Korean interface is what a Korean programmer's editor looks like, and
    -- `refresh` asks again the moment the language changes (see `update`).
    if self.quest.story and self.quest.story ~= "" then
      for _, line in ipairs(UI.wrap(self.quest.story, column, prose)) do
        y = y + UI.text(line, x, y, prose, Theme.withAlpha(Theme.coin, 0.9)) + 3
      end
      y = y + 8
    end
    for _, line in ipairs(UI.wrap(self.quest.brief or "", column, prose)) do
      y = y + UI.text(line, x, y, prose, Theme.cream) + 3
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
    y = y + UI.paragraph(I18n.t("TESTS  match %s   %d hidden",
      tostring(tests.match or "?"), tests.hidden_count or 0), x, y, indent, 8,
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

--- Where the seven buttons stand, and how much of the well they stand in.
---
--- Its own function because `draw_editor` has to know the answer *before* it
--- decides how many rows of code fit. The band is two rows deep in English
--- now, and the editor was still being told the well ran all the way to the
--- bottom — which put the last lines of a long program, and the caret with
--- them, behind the SOLVE button. It was one row's worth of hidden text
--- before this round and would have been three.
function Quest:button_band(rect)
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
  -- The stack's three. **No key printed on UNDO and REDO**, and that is
  -- deliberate rather than an omission: ctrl-Z inside the editor is the
  -- editor's own undo and stays that way (see `keypressed`), so a button
  -- captioned `UNDO  CTRL-Z` would be promising something the key does not do
  -- where a player's hands actually are. CLEAR's key is unambiguous and is
  -- printed the way FORMAT's and SOLVE's are.
  --
  -- `CLEAR`, not `CLEAR STACK`: the caption under the three says `stack 3/5`,
  -- which names the thing and costs nothing, where a second word on the
  -- button costs six characters of Press Start 2P at every type step — and at
  -- the largest step that is the difference between three whole labels and
  -- three truncated ones.
  local undo_label = I18n.t("UNDO")
  local redo_label = I18n.t("REDO")
  local clear_label = I18n.t("CLEAR  SHIFT-F6")
  local bh = math.max(28, UI.lineHeight(9) + 12)
  local gap = 22
  local want = math.max(UI.textWidth(run_label, 9), UI.textWidth(submit_label, 9)) + 20
  -- A label wider than its button is printed through the neighbour. When
  -- the pair cannot have the width their full labels want, the key comes
  -- off — `RUN` and `SUBMIT` — rather than the word: the keys are in the
  -- footer's hint as well, and the word is what the button is.
  local function bare(label) return (label:gsub("%s%s+.*$", "")) end
  local room_pair = math.floor((rect.w - 30 - gap - 100 - 10) / 2)
  if want > room_pair then
    run_label = self.running_mode == "quest.run" and run_label or bare(run_label)
    submit_label = self.running_mode == "quest.submit" and submit_label or bare(submit_label)
    want = math.max(UI.textWidth(run_label, 9), UI.textWidth(submit_label, 9)) + 20
  end
  -- The left of the well is two clusters now — SOLVE and FORMAT, which only
  -- ever change the buffer, and UNDO, REDO and CLEAR, which only ever move
  -- along the server's history of it — and every one of the five is measured
  -- from its own label for the reason the pair on the right is: `SOLVE
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


  -- The left of the row is the buttons that never cost anything: **SOLVE,
  -- then FORMAT**, then **UNDO, REDO and CLEAR**, then a wide gap, then the
  -- pair that does. None of the five writes an attempt (§4.9d, §4.11b, and
  -- the edit stack records nothing against the node), and none of them must
  -- read as another way to submit.
  --
  -- SOLVE is the far-left button on purpose: FORMAT stands between it and
  -- RUN, so the one control on this screen that gives the answer away cannot
  -- be reached by a press that was aimed a centimetre wide of RUN.
  local sw = UI.textWidth(solve_label, 8) + 16
  local fw = UI.textWidth(format_label, 8) + 16
  -- ANSWER and CODE join the cluster that only ever changes the *buffer*.
  -- Neither writes an attempt, and neither must read as another way to
  -- submit — the same rule SOLVE and FORMAT are here under.
  local answer_label = I18n.t("ANSWER")
  local code_label = I18n.t("CODE")
  local aw = UI.textWidth(answer_label, 8) + 16
  local cdw = UI.textWidth(code_label, 8) + 16
  local uw = UI.textWidth(undo_label, 8) + 16
  local rw = UI.textWidth(redo_label, 8) + 16
  local cw = UI.textWidth(clear_label, 8) + 16
  -- A whole row of the well, which is the most any cluster can ever have.
  local row = rect.w - 20
  -- The same rule for the left pair: when SOLVE and FORMAT with their keys
  -- do not fit a row of the well, the keys go.
  if sw + left_gap + fw + left_gap + aw + left_gap + cdw > row then
    solve_label = self.solving and solve_label or bare(solve_label)
    format_label = self.formatting and format_label or bare(format_label)
    sw = UI.textWidth(solve_label, 8) + 16
    fw = UI.textWidth(format_label, 8) + 16
  end
  local buffer_w = sw + left_gap + fw + left_gap + aw + left_gap + cdw
  local stack_w = uw + left_gap + rw + left_gap + cw
  local left_room = rx - rect.x - 20
  local upper = by - bh - 6 - cap

  -- Which row each cluster sits on. Beside RUN and SUBMIT when they fit
  -- there; **on a row of its own above** when they do not, which is portrait
  -- in every language and landscape in Czech. Of the three ways out — shrink
  -- the pair on the right, shrink the type, or use an empty row above — the
  -- last one is the one the well can usually afford, and the wide gap between
  -- the reflex button and the deliberate one survives all of it untouched.
  --
  -- The two clusters are asked for separately and in that order, so the
  -- commonest crowded case — everything fits except the stack's three — costs
  -- one extra row rather than two. Four cases, and they are all of them:
  --
  --   A  both beside RUN and SUBMIT               one row
  --   B  both on the row above                    two rows
  --   C  the buffer pair stays, the stack rises   two rows
  --   D  the buffer pair rises, the stack above   three rows
  local function choose()
    if buffer_w + left_gap + stack_w <= left_room then return by, by end   -- A
    if buffer_w + left_gap + stack_w <= row then return upper, upper end   -- B
    if buffer_w <= left_room then return by, upper end                     -- C
    return upper, upper - bh - 6 - cap                                     -- D
  end
  local ly, uy = choose()

  -- **A key comes off before a third row goes on.** `CLEAR  SHIFT-F6` is the
  -- only label in the stack's three that carries one, and the key is repeated
  -- nowhere else on this screen — but a row of the well is code the player is
  -- reading, and at every type step above the first this one trade is the
  -- difference between two rows and three.
  if uy < ly and clear_label ~= bare(clear_label) then
    clear_label = bare(clear_label)
    cw = UI.textWidth(clear_label, 8) + 16
    stack_w = uw + left_gap + rw + left_gap + cw
    ly, uy = choose()
  end

  -- **And past three fifths of the well, the type gives way instead.** The
  -- rows above are cheap exactly while the well has them spare, and it stops
  -- having them spare: at the largest type step in a 720-pixel-tall landscape
  -- window, three rows and their captions are 305 px of a 422 px well and
  -- what is left cannot hold one line of a compiler error. A band that has
  -- taken more of the well than the code has stopped being a band, so the two
  -- clusters come back down onto one row together and shrink to fit it.
  if uy < ly and (rect.y + rect.h) - (uy - cap) > rect.h * 0.6 then
    ly, uy = upper, upper
  end

  -- What each cluster's row actually has for it, once the neighbours on that
  -- row have taken theirs. Two clusters sharing a row that cannot hold both
  -- **share it in proportion to what each wants**, rather than the first one
  -- laid out taking all it asked for and the second one taking the remainder:
  -- SOLVE and FORMAT are not more important than UNDO, REDO and CLEAR, and a
  -- row that gave one pair its full labels and the other three single letters
  -- would only look like a bug.
  local buffer_room, stack_room
  if uy == ly then
    local shared = (ly == by) and left_room or row
    if buffer_w + left_gap + stack_w <= shared then
      buffer_room, stack_room = buffer_w, stack_w
    else
      local free = shared - left_gap
      buffer_room = math.floor(free * buffer_w / (buffer_w + stack_w))
      stack_room = free - buffer_room
    end
  else
    buffer_room = (ly == by) and left_room or row
    stack_room = (uy == by) and left_room or row
  end
  -- Narrower still: the members of a cluster give way together rather than
  -- one eating the other, with a floor that still shows something.
  if buffer_w > buffer_room then
    local scale = (buffer_room - 3 * left_gap) / (sw + fw + aw + cdw)
    sw = math.max(40, math.floor(sw * scale))
    fw = math.max(40, math.floor(fw * scale))
    aw = math.max(40, math.floor(aw * scale))
    cdw = math.max(40, math.floor(cdw * scale))
    buffer_w = sw + left_gap + fw + left_gap + aw + left_gap + cdw
  end
  if stack_w > stack_room then
    local scale = (stack_room - 2 * left_gap) / (uw + rw + cw)
    uw = math.max(40, math.floor(uw * scale))
    rw = math.max(40, math.floor(rw * scale))
    cw = math.max(40, math.floor(cw * scale))
    stack_w = uw + left_gap + rw + left_gap + cw
  end

  local vx = rect.x + 10
  local fx = vx + sw + left_gap
  local ax = fx + fw + left_gap
  local cdx = ax + aw + left_gap
  -- The stack follows the buffer pair when they share a row, and otherwise
  -- starts at the left margin of its own.
  local ux = (uy == ly) and (vx + buffer_w + left_gap) or (rect.x + 10)
  local rdx = ux + uw + left_gap
  local clx = rdx + rw + left_gap
  return {
    run_label = run_label, submit_label = submit_label,
    format_label = format_label, solve_label = solve_label,
    answer_label = answer_label, code_label = code_label,
    ax = ax, cdx = cdx, aw = aw, cdw = cdw,
    undo_label = undo_label, redo_label = redo_label, clear_label = clear_label,
    bh = bh, cap = cap, bw = bw,
    by = by, sx = sx, rx = rx, ly = ly, uy = uy,
    vx = vx, fx = fx, sw = sw, fw = fw,
    ux = ux, rdx = rdx, clx = clx, uw = uw, rw = rw, cw = cw,
    buffer_w = buffer_w, stack_w = stack_w,
    -- From the caption row above the topmost button row to the bottom of the
    -- well: the strip the code must not be laid out into. **Three rows are
    -- possible now**, so the minimum is over three numbers — a `math.min` of
    -- two here is how a new row gets code laid out underneath it.
    reserve = (rect.y + rect.h) - (math.min(by, ly, uy) - cap),
  }
end

--- The top of the button band: the caption row above whichever row is
--- highest. Three sites need it — the reserve above, the note plate, and the
--- console — and each one of them is a place a row can be printed through if
--- the three ever disagree.
function Quest.band_top(band)
  return math.min(band.by, band.ly, band.uy) - band.cap - 6
end

--- The code well.
---
--- `bare` is CODE mode: no band, no console, no captions — the rows take the
--- whole well and the controls live on the strip above it. The one function
--- either way, because two copies of a per-line draw loop is how a ghost, a
--- caret and a selection come to disagree about where a character is.
function Quest:draw_editor(rect, tint, bare)
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
  local band = self:button_band(rect)
  -- The console — the run's stages, its log and what it came back with —
  -- is **part of the layout, not a float**. It used to be a panel pinned to
  -- the bottom of the screen at a fixed 300 px, which in portrait sat on top
  -- of the button band and its captions: the very buttons a player needs
  -- after reading "does not compile" were under the compiler's output. The
  -- browser client subtracts a console height from the editor before laying
  -- anything out (`consoleH` in `frontend/src/scenes/quest.ts`), and this is
  -- the same rule: the code rows give up the space, the band keeps its row.
  local console = bare and { open = false, reserve = 0 } or self:console_rect(rect, band)
  local rows = math.max(1,
    math.floor((rect.h - 12 - (bare and 0 or band.reserve) - console.reserve) / line_h))
  self.editor:ensure_visible(rows)
  self.visible_rows = rows
  self.editor_rect = rect
  self.console_rect_drawn = console.open and console or nil
  self.line_h = line_h
  self.gutter = gutter
  self.mono_font = font

  love.graphics.setScissor(rect.x + 3, rect.y + 3, rect.w - 6, rect.h - 6)
  love.graphics.setFont(font)

  local x0 = rect.x + 8
  local y0 = rect.y + 6
  -- Kept so `caret_xy` can throw an effect where the caret is without
  -- re-deriving a layout that already exists here.
  self.editor_geo = { x0 = x0, y0 = y0, gutter = gutter, font = font, line_h = line_h }
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

    -- ANSWER's target: the rest of this line of the answer, hung off the end
    -- of what has been typed, and a mark under whatever was typed *instead*
    -- of it. The divergence is marked rather than hidden — noticing it is
    -- the exercise.
    if self.answer_on and self.answer_lines then
      local want = self.answer_lines[index]
      local typed_w = font:getWidth(line)
      if want then
        local k, n = 0, math.min(#line, #want)
        while k < n and line:byte(k + 1) == want:byte(k + 1) do k = k + 1 end
        if k < #line then
          local wx = x0 + gutter + font:getWidth(line:sub(1, k))
          UI.setColor(Theme.red, 0.3)
          love.graphics.rectangle("fill", wx, y,
            math.max(2, font:getWidth(line:sub(k + 1))), line_h)
        end
        if k < #want then
          UI.setColor(Theme.withAlpha(Theme.cream, 0.3))
          love.graphics.print(want:sub(k + 1), x0 + gutter + typed_w, y)
        end
      elseif #line > 0 then
        -- Typed past the end of the answer: all of this line is divergence.
        UI.setColor(Theme.red, 0.3)
        love.graphics.rectangle("fill", x0 + gutter, y, math.max(2, typed_w), line_h)
      end
      love.graphics.setColor(1, 1, 1, 1)
    end

    if index == self.editor.line and self.focus == "editor" then
      local caret = x0 + gutter + font:getWidth(line:sub(1, self.editor.col - 1))
      if (love.timer.getTime() * 2) % 2 < 1.2 then
        UI.setColor(Theme.coin)
        love.graphics.rectangle("fill", caret, y, 2, line_h)
      end
    end
  end
  -- The lines of the answer the document has not reached yet, under the last
  -- one it has, for as many rows as the well still has.
  if self.answer_on and self.answer_lines then
    local after = self.editor:line_count()
    local row = after - self.editor.scroll + 1
    UI.setColor(Theme.withAlpha(Theme.cream, 0.3))
    for i = after + 1, #self.answer_lines do
      if row > rows then break end
      love.graphics.print(self.answer_lines[i], x0 + gutter, y0 + (row - 1) * line_h)
      row = row + 1
    end
    love.graphics.setColor(1, 1, 1, 1)
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

  if bare then return end

  -- RUN and SUBMIT, with a deliberate gap between them, and SOLVE and FORMAT
  -- on the left. The geometry is `button_band`'s — worked out at the top of
  -- this function, because the code above had to be laid out around it.
  local run_label, submit_label = band.run_label, band.submit_label
  local format_label, solve_label = band.format_label, band.solve_label
  local bh, cap, bw = band.bh, band.cap, band.bw
  local by, sx, rx, ly = band.by, band.sx, band.rx, band.ly
  local vx, fx, sw, fw = band.vx, band.fx, band.sw, band.fw
  local uy, ux, rdx, clx = band.uy, band.ux, band.rdx, band.clx
  local uw, rw, cw = band.uw, band.rw, band.cw

  local busy = self.running_mode ~= nil
  local usable = (self.quest ~= nil) and not busy
  UI.button(vx, ly, sw, bh, solve_label,
    (usable and not self.solve_unsupported) and "normal" or "disabled", 8)
  self.solve_rect = { x = vx, y = ly, w = sw, h = bh }
  UI.button(fx, ly, fw, bh, format_label,
    (usable and not self.format_unsupported) and "normal" or "disabled", 8)
  self.format_rect = { x = fx, y = ly, w = fw, h = bh }
  -- ANSWER wears `hot` while it is on: the screen is in a mode, and a mode
  -- that does not say so is a mode a player forgets they are in.
  UI.button(band.ax, ly, band.aw, bh, band.answer_label,
    self.answer_on and "hot"
      or ((usable and not self.solve_unsupported) and "normal" or "disabled"), 8)
  self.answer_rect = { x = band.ax, y = ly, w = band.aw, h = bh }
  UI.button(band.cdx, ly, band.cdw, bh, band.code_label,
    self.quest and "normal" or "disabled", 8)
  self.code_rect = { x = band.cdx, y = ly, w = band.cdw, h = bh }

  -- The stack's three, drawn from the state the server last sent and from
  -- nothing else. `src/net/edits.lua` owns the three predicates so that the
  -- greyness of a button and the `stack 3/5` caption under it cannot come to
  -- different conclusions about the same numbers.
  local stack = self.edit
  local live = usable and not self.edit_unsupported
  UI.button(ux, uy, uw, bh, band.undo_label,
    (live and Edits.can_undo(stack)) and "normal" or "disabled", 8)
  self.undo_rect = { x = ux, y = uy, w = uw, h = bh }
  UI.button(rdx, uy, rw, bh, band.redo_label,
    (live and Edits.can_redo(stack)) and "normal" or "disabled", 8)
  self.redo_rect = { x = rdx, y = uy, w = rw, h = bh }
  UI.button(clx, uy, cw, bh, band.clear_label,
    (live and Edits.can_clear(stack)) and "normal" or "disabled", 8)
  self.clear_rect = { x = clx, y = uy, w = cw, h = bh }

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
  -- Each caption gets its button's width and no more, at the size that
  -- fits it: "1 sample" ran into "all cases" and "cases" was printed over
  -- SUBMIT when the buttons were narrower than the captions.
  local run_cap = self.run_unsupported and I18n.t("not on this server")
    or (visible == 1 and I18n.t("%d sample", 1) or I18n.t("%d samples", visible))
  local sub_cap = hidden > 0 and I18n.t("+%d hidden", hidden) or I18n.t("all cases")
  local cap_size = math.min(UI.fitSize(run_cap, bw - 4, 7, 5), UI.fitSize(sub_cap, bw - 4, 7, 5))
  -- Clipped to the button's column rather than wrapped: a caption that
  -- still does not fit at the floor would otherwise wrap onto the button.
  love.graphics.setScissor(rx, by - cap, bw, cap)
  UI.text(run_cap, rx, by - cap, cap_size,
    Theme.withAlpha(self.run_unsupported and Theme.dim or Theme.cyan, 0.9))
  love.graphics.setScissor(sx, by - cap, bw, cap)
  UI.text(sub_cap, sx, by - cap, cap_size, Theme.withAlpha(Theme.coin, 0.8))
  love.graphics.setScissor()

  -- **What SOLVE costs, said before it is pressed.** Under its own button, in
  -- the same caption row and the same register as `+2 hidden`: revealing the
  -- answer is priced as the largest hint there is (§4.11b), so the third star
  -- goes. One clause, because a button whose caption is a paragraph reads as
  -- a warning and this is a price. The rest of the story — that nothing is
  -- recorded by asking — is in the note the press itself puts up, where
  -- somebody is actually looking.
  -- One line, or nothing: a caption wrapped to two lines lands on the
  -- button it captions.
  local price = self.solve_unsupported and I18n.t("no answer key here") or I18n.t("costs a star")
  if UI.textWidth(price, 7) <= sw then
    UI.text(price, vx, ly - cap, 7,
      Theme.withAlpha(self.solve_unsupported and Theme.dim or Theme.coin, 0.85))
  end

  -- **Where the cursor is, over how deep the stack goes**, in the same
  -- caption row and the same register as `costs a star`. It is the only place
  -- the word `stack` appears on this screen, which is what lets the button
  -- under it be one word, and it is the difference between three greyed
  -- controls that look broken and three that are plainly waiting for a
  -- history to exist. Dropped rather than overprinted when the cluster is too
  -- narrow to hold it, the same rule the price above follows.
  local stack_caption, stack_dim = self:stack_caption()
  if UI.textWidth(stack_caption, 7) <= band.stack_w then
    UI.text(stack_caption, ux, uy - cap, 7,
      Theme.withAlpha(stack_dim and Theme.dim or Theme.cyan, 0.85))
  end

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
  -- On the buffer buttons' own caption row when they have one — beside
  -- `costs a star`, above FORMAT, with the whole width of the well to run
  -- into — and otherwise just past FORMAT on the single row. Never at the old
  -- left margin, which is where SOLVE's caption is now, and never below an
  -- upper row, which is the button band itself.
  --
  -- And never through the stack's three, which may stand on either of those
  -- places: when they share the buffer pair's row it is their left edge that
  -- ends this line's room, and when they share the button row it is their
  -- right edge this line starts from. A dim line is the thing that gives way.
  local shares_row = uy == ly
  local after_stack = shares_row and (ux + band.stack_w) or (fx + fw)
  local ix = two_rows and fx or (after_stack + 10)
  local iy = two_rows and (ly - cap) or (by - 12)
  local limit = two_rows and (shares_row and (ux - 8) or (rect.x + rect.w - 10)) or (rx - 8)
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
  --   * the edit stack's confirmation — what a second press of CLEAR will
  --     drop, and what it will not. **First** in the chain, because it is the
  --     only one of the four that is a *question*: the other three report
  --     something that has already happened and can wait a press, and a
  --     question the player cannot see is a press into the dark. The three
  --     buffer buttons each take this note down when they speak, the same way
  --     they already take each other's down.
  local said = self:stack_said() or self.format_problem or self.format_note
    or self:solve_said()
  if said then
    local colour = (self.format_problem or self.solve_note or self.stack_note) and Theme.coin
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
    -- **Leading, and Korean needs more of it.** Unifont's cells fill the whole
    -- point size, so CJK lines set at exactly `getHeight()` sit edge to edge
    -- with no air at all and read as one band; the Latin face leaves its own
    -- gap and needs only a little. `I18n.is_cjk` was written for this ("so a
    -- layout can give it room rather than discover it needs some") and had no
    -- caller until now.
    -- `UI.lineHeight` already carries the CJK overshoot; only the air here.
    local lh = UI.lineHeight(7) + 2
    -- Five lines, or as many as the well has room for above the band: at
    -- the largest type step in a short landscape window five Korean lines
    -- are taller than the well, and a plate that starts above it is drawn
    -- over the brief.
    local room = math.max(0, math.floor((Quest.band_top(band) - rect.y - 12) / lh))
    local shown = math.min(#lines, 5, room)
    local top = Quest.band_top(band) - shown * lh
    UI.setColor(Theme.ink, 0.88)
    love.graphics.rectangle("fill", rect.x + 4, top - 5, rect.w - 8, shown * lh + 10)
    love.graphics.setColor(1, 1, 1, 1)
    for i = 1, shown do
      UI.text(lines[i], rect.x + 10, top + (i - 1) * lh, 7, colour)
    end
  end
end

--- How a console `h` tall is divided once the outcome strip has taken
--- `strip_h`: the chrome (the stage names, their bar, and the F8 hint) and
--- the log rows under it. The chrome gives way before the log does — at the
--- largest type step in a short landscape window a full set of stage names
--- would leave no row for the one line that says what went wrong, and the
--- stage names are the least of it once the run is over. Returns the chrome
--- height, whether the stage row is drawn, and the number of log rows.
function Quest.console_split(h, strip_h, line_h)
  local left = h - strip_h
  local full, tight = 52, 12
  if left - full >= line_h then
    return full, true, math.floor((left - full) / line_h)
  end
  return tight, false, math.max(0, math.floor((left - tight) / line_h))
end

--- Whether the console has anything to show. `show_log` is the player's
--- toggle (F8); it only opens when there is a run to look at.
function Quest:console_open()
  return self.show_log and (self.running_mode ~= nil or self.log ~= nil or self.run_attempt ~= nil)
end

--- Where the console goes: inside the well, above the button band and its
--- caption row, and above the note plate when one is up. `reserve` is what
--- the code rows give up for it — zero when it is closed, so a screen with
--- no run in flight is exactly the screen it always was.
---
--- A fraction of the well rather than a fixed height, and a larger one in
--- portrait (the browser's 0.36 / 0.32): a portrait well is tall and narrow,
--- and a compiler error wraps to more lines there. Floored at four log rows
--- so a short landscape window still shows the line that matters.
function Quest:console_rect(rect, band)
  if not self:console_open() then
    return { open = false, reserve = 0 }
  end
  local mono = Assets.mono(Layout.codeSize(16))
  local line_h = mono:getHeight()
  local frac = Layout.isPortrait() and 0.36 or 0.32
  local want = math.floor(rect.h * frac)
  -- Above the caption row, and above the note plate if one is showing.
  local top_of_band = Quest.band_top(band)
  -- The same chain `draw_editor` draws, because this reserves the room that
  -- one prints into: a console sized against a shorter note lands on it.
  local said = self:stack_said() or self.format_problem or self.format_note
    or self:solve_said()
  if said then
    local lines = UI.wrap(said, rect.w - 28, 7)
    -- `UI.lineHeight` already carries the CJK overshoot; only the air here.
    local lh = UI.lineHeight(7) + 2
    -- The same cap as the plate's own draw, so the two agree.
    local room = math.max(0, math.floor((top_of_band - rect.y - 12) / lh))
    top_of_band = top_of_band - math.min(#lines, 5, room) * lh - 10
  end
  local bottom = top_of_band - 6
  -- Everything the well has above the band, keeping two code rows when it
  -- can; when it cannot, the console may take the rows too — a player who
  -- pressed RUN wants the answer, and F8 gives the code back.
  local code_line = Assets.mono(Layout.codeSize(18)):getHeight()
  local max_h = bottom - (rect.y + 6) - 6
  local kept = bottom - (rect.y + 6 + 2 * code_line) - 6
  -- The outcome strip, shrunk to what the console can hold with one log row
  -- under it, so the floor below is a floor that fits.
  local strip_h = 0
  if not self.running_mode then
    local _, sh = self:outcome_note(rect.w - 8, math.max(0, max_h - 12 - line_h))
    strip_h = sh
  end
  local floor_h = strip_h + 52 + 4 * line_h
  local h = math.max(floor_h, want)
  -- The floor wins over the fraction, the kept code rows win over the
  -- floor while they can, and the well wins over everything: nothing is
  -- ever drawn outside it.
  if floor_h <= kept then
    h = math.min(math.max(floor_h, math.min(h, kept)), kept)
  else
    h = math.min(math.max(floor_h, strip_h + 12 + line_h), max_h)
  end
  h = math.max(0, h)
  local _, _, log_rows = Quest.console_split(h, strip_h, line_h)
  return {
    open = true,
    x = rect.x + 4, y = bottom - h, w = rect.w - 8, h = h,
    strip_h = strip_h, log_rows = log_rows,
    -- What the rows lose: the console's own height plus the gap under it.
    reserve = h + 10,
  }
end

--- The run console: what the run came back with (once it has), the four
--- stages, then whatever has streamed in. Drawn into the rect `console_rect`
--- reserved inside the well — never over the buttons, never over the code
--- rows that were laid out around it.
function Quest:draw_run_overlay(rect)
  if not rect then return end
  local x, y, w, h = rect.x, rect.y, rect.w, rect.h

  UI.panel(x, y, w, h, { fill = Theme.withAlpha(Theme.ink, 0.96), tint = Theme.coin })

  -- The outcome strip takes the top of the console once the run has come
  -- back, and the stages and the log move down under it. It used to be
  -- drawn *above* the console, over the player's code — the one surface
  -- this screen must never print through.
  -- The compiler's own words, at the player's step: this is code too, and
  -- somebody who made the editor bigger did it because 18px was hard to read.
  local font = Assets.mono(Layout.codeSize(16))
  local line_h = font:getHeight()

  local head = 0
  if self.run_attempt and not self.running_mode then
    head = self:draw_run_outcome(x, y, w, h - 12 - line_h)
    y = y + head
    h = h - head
  end
  local chrome, stages, rows = Quest.console_split(h + head, head, line_h)
  self.console_log_rows = rows

  local stage_index = STAGES[self.stage or ""] or 0
  if stages then
    local names = { "QUEUED", "COMPILING", "RUNNING", "JUDGING" }
    local ms = ("%dms"):format(math.floor(self.elapsed_ms))
    -- The four names, or — when they would run into the timer — only the
    -- one the run is on. The bar under them says the same thing either way.
    local total = 0
    for _, name in ipairs(names) do total = total + UI.textWidth(name, 8) + 14 end
    local fits = x + 12 + total < x + w - 12 - UI.textWidth(ms, 8) - 8
    local sx = x + 12
    for i, name in ipairs(names) do
      local done = i < stage_index
      local now = i == stage_index
      if fits or now then
        local color = done and Theme.admit or (now and Theme.coin or Theme.dim)
        UI.text(name, sx, y + 10, 8, color)
        sx = sx + UI.textWidth(name, 8) + 14
      end
    end
    UI.text(ms, x + w - 12 - UI.textWidth(ms, 8), y + 10, 8, Theme.withAlpha(Theme.cream, 0.7))
    if self.queued and self.queued > 0 then
      UI.text(("%d ahead"):format(self.queued), x + 12, y + 24, 7, Theme.coin)
    end
    UI.bar(x + 12, y + 26, w - 24, 6, stage_index / 4, Theme.coin)
  end

  love.graphics.setFont(font)
  local top = y + (stages and 40 or 6)

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

  if stages then
    if self.log and self.log.truncated then
      UI.text(I18n.t("output truncated at 256 KiB"), x + 12, y + h - 16, 7, Theme.coin)
    end
    UI.text(I18n.t("F8 hide"), x + w - 12 - UI.textWidth("F8 hide", 7), y + h - 16, 7,
      Theme.withAlpha(Theme.cream, 0.5))
  end
end

--- What a RUN came back with.
---
--- Drawn as a strip above the log, in **cyan** — never in `Theme.admit`, the
--- green this game uses for a clear, and never with the word ACCEPTED. A run
--- that passes means "the sample works, now submit", and a screen that said
--- anything stronger would be contradicted by the very next thing the player
--- does.
--- The outcome strip's note lines and its height, for a console `w` wide.
--- One function, because `console_rect` has to reserve the strip's height
--- before the strip is drawn — a console floored below its own headline
--- handed the log a negative scissor and took the frame with it.
function Quest:outcome_note(w, budget)
  local a = self.run_attempt
  if not a then return {}, 0 end
  local passed = a.verdict == "accepted"
  local tests = (self.quest and self.quest.tests) or {}
  local hidden = tests.hidden_count or 0
  local note_lines
  if passed then
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
  local head_h = UI.lineHeight(11)
  local note_lh = UI.lineHeight(7) + 2
  -- The counts share the headline's line when both fit across the strip,
  -- and take a line of their own when they do not — at the largest type
  -- step "DOES NOT COMPILE" alone is wider than a portrait console.
  local headline = self:outcome_headline()
  local counts = I18n.t("%d / %d samples", a.tests_passed or 0, a.tests_total or 0)
  local two_lines = UI.textWidth(headline, 11) + UI.textWidth(counts, 9) + 36 > w
  local counts_h = two_lines and (UI.lineHeight(9) + 2) or 0
  local function height(n) return 8 + head_h + counts_h + 6 + n * note_lh + 8 end
  -- `budget` is what the console can give the strip. The note gives way a
  -- line at a time before the headline does: at the largest type step in a
  -- 720 px landscape window the whole well is under 400 px, and a strip
  -- that insisted on its four-line note would start above the well.
  local no_counts = false
  if budget then
    while #note_lines > 0 and height(#note_lines) > budget do
      note_lines[#note_lines] = nil
    end
    -- And after the note, the counts' own line: the headline is the one
    -- thing the strip exists to say, and it is the last to go.
    if two_lines and height(0) > budget then
      two_lines, counts_h, no_counts = false, 0, true
    end
  end
  return note_lines, height(#note_lines), two_lines, no_counts
end

--- `SAMPLE PASSES`, not `ACCEPTED`: a run is not a verdict.
function Quest:outcome_headline()
  local a = self.run_attempt
  if not a then return "" end
  if a.verdict == "accepted" then return "SAMPLE PASSES" end
  return ({
    wrong_answer = "SAMPLE FAILS",
    compile_error = "DOES NOT COMPILE",
    runtime_error = "CRASHED",
    timeout = "TOO SLOW",
    output_limit = "TOO MUCH OUTPUT",
    internal_error = "THE RUNNER BROKE",
  })[a.verdict] or tostring(a.verdict):upper()
end

function Quest:draw_run_outcome(x, y, w, budget)
  local a = self.run_attempt
  local passed = a.verdict == "accepted"

  -- The note wraps, and the strip grows to hold it. The line about runs
  -- being kept is the one sentence on this screen that must not be clipped:
  -- half of it says the opposite of the whole of it — so when the budget
  -- cannot hold all of it, `outcome_note` drops whole lines, never half.
  local note_lines, h, two_lines, no_counts = self:outcome_note(w, budget)
  local head_h = UI.lineHeight(11)
  local note_lh = UI.lineHeight(7) + 2
  local sy = y
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
  local headline = self:outcome_headline()
  UI.text(headline, x + 12, sy + 8, 11, tint)

  local counts = I18n.t("%d / %d samples", a.tests_passed or 0, a.tests_total or 0)
  local counts_y = two_lines and (sy + 8 + head_h + 2) or (sy + 8 + (head_h - UI.lineHeight(9)) / 2)
  local counts_h = two_lines and (UI.lineHeight(9) + 2) or 0
  if not no_counts then
    UI.text(counts, x + w - 12 - UI.textWidth(counts, 9), counts_y, 9,
      Theme.withAlpha(Theme.cream, 0.85))
  end

  -- The line that has to be exactly right (§4.9b). A run *is* saved and its
  -- mistakes *do* feed the drills; what it does not do is count against the
  -- node. "Runs aren't saved" would be false and is written nowhere.
  for i, line in ipairs(note_lines) do
    UI.text(line, x + 12, sy + 8 + head_h + counts_h + 6 + (i - 1) * note_lh, 7,
      Theme.withAlpha(Theme.cream, 0.75))
  end
  love.graphics.pop()
  self.outcome_rect = { x = x, y = sy, w = w, h = h }
  return h
end

-- -------------------------------------------------------------------- input

function Quest:textinput(text)
  if self.focus == "editor" then
    self.editor:textinput(text)
    SFX.play("type")
  end
end

function Quest:keypressed(key, mods)
  -- ESC ends the writing session before it ends the quest: a player in CODE
  -- pressing it means "put the furniture back", and taking them to the map
  -- would throw away the thing they were doing.
  if self.code_mode and key == "escape" then
    self.code_mode = false
    SFX.play("back")
    return true
  end
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
  -- SHIFT-F6 clears the server's edit stack, beside plain F6's reset to the
  -- starter. The pair is deliberate: both throw something away, the modifier
  -- marks the bigger of the two exactly as SHIFT-F7 marks the biggest hint,
  -- and the chord is tested first so the bare key still restores the starter.
  -- `ctrl` is excluded so a ctrl-shift-F6 aimed elsewhere misses.
  if key == "f6" and mods.shift and not cmd then self:stack_clear(); return true end
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
  -- **ctrl-Z is two different undos on this screen, and which one you get
  -- depends on where the focus is.** Inside the editor it is
  -- `src/editor.lua`'s own, the fine-grained one that takes back a keystroke,
  -- and it stays that way: swapping a per-keystroke undo for a per-thought
  -- one under the same chord would be a bad trade in the one place a
  -- programmer's hands are certain of it. On the brief, where the editor has
  -- no claim on the key, it drives the **server's** stack. The browser client
  -- draws the same line around CodeMirror for the same reason; the buttons
  -- are what everybody else reaches for, and they are always the server's.
  if cmd and key == "z" and self.focus ~= "editor" then
    if mods.shift then self:stack_redo() else self:stack_undo() end
    return true
  end
  if key == "f8" then self.show_log = not self.show_log; return true end
  if key == "f9" then self:external_edit(); return true end
  -- The pane toggle moved off F10 when SUBMIT took it; ctrl-TAB is the
  -- switch-pane gesture everywhere else anyway, and TAB alone still indents.
  if key == "tab" and cmd then
    self.focus = self.focus == "editor" and "brief" or "editor"
    return true
  end
  -- **TAB is ANSWER's pedal while ANSWER is on.** It takes the rest of the
  -- line, and at a line's end the next line's indentation. When there is
  -- nothing to take — the answer is typed out, or the buffer has stopped
  -- being the answer — the press is *consumed and does nothing* rather than
  -- falling through to indent: a tab put into a buffer that was exactly
  -- right a moment ago turns MATCHED into a line of red nobody typed, and
  -- past a divergence the thing to do is fix it, not indent it.
  if key == "tab" and not cmd and not mods.shift
    and self.answer_on and self.focus == "editor" and self.editor then
    local insert = Quest.answer_completion(self.editor:text(), self.answer_text)
    if insert then
      self.editor:move("doc_end")
      self.editor:insert(insert)
      SFX.play("move")
    end
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
  if self.code_mode then
    if inside(self.code_done_rect) then
      self.code_mode = false
      SFX.play("back")
      return
    end
    local r = self.code_rects or {}
    if inside(r.run) then self:run(); return end
    if inside(r.format) then self:format(); return end
    if inside(r.undo) then self:stack_undo(); return end
    if inside(r.redo) then self:stack_redo(); return end
    if inside(r.answer) then self:toggle_answer(); return end
    -- Anything else is a click into the code, and it goes through the same
    -- pane the framed screen uses — so the caret lands where it was aimed,
    -- a drag selects, and a double click takes a word, here as there.
    local shift = love.keyboard.isDown("lshift", "rshift")
    if self.pane:mousepressed(x, y, button, shift) then
      self.focus = "editor"
      return
    end
    self.focus = "editor"
    return
  end
  -- The buttons sit inside the code well, so they are tested first. They also
  -- fire on the press and not the release, which is what makes a drag that
  -- started in the text and ended over SUBMIT harmless: the release does
  -- nothing at all.
  if inside(self.solve_rect) then self:solve(); return end
  if inside(self.format_rect) then self:format(); return end
  if inside(self.answer_rect) then self:toggle_answer(); return end
  if inside(self.code_rect) then self:enter_code(); return end
  if inside(self.undo_rect) then self:stack_undo(); return end
  if inside(self.redo_rect) then self:stack_redo(); return end
  if inside(self.clear_rect) then self:stack_clear(); return end
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
