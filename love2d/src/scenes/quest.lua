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
local CodeFx = require("src.codefx")
local CoderM = require("src.agent.coder")
local Land = require("src.land")
local Editor = require("src.editor")
local CodePane = require("src.codepane")
local Json = require("src.json")
local runlog = require("src.net.runlog")
local Edits = require("src.net.edits")
local External = require("src.external")
local Anim = require("src.anim")
local Clock = require("src.clock")
local Ease = require("src.ease")
local Quiz = require("src.quiz")
local Celebrate = require("src.celebrate")
local Juice = require("src.juice")
local Fx = require("src.fx")
-- The art round's nine-slice frames, when they are there; every call has a
-- drawn fallback, so a checkout without them still draws the card.
local ArtFrame = (function()
  local ok, m = pcall(require, "src.artframe")
  return ok and m or nil
end)()

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
  if category == "cheatsheet" then
    -- CHEATSHEET is the print shop on every land: the sheets on the cork
    -- board are the ones the questions come from. The browser draws the
    -- same plate (frontend/src/scenes/quest.ts).
    return Assets.pick("bg_cheatsheet", "bg_street", "bg_flat")
  end
  if category == "cheatsheet_advanced" then
    -- ADVANCED is the floor above the print shop, after hours.
    return Assets.pick("bg_cheatsheet_pro", "bg_cheatsheet", "bg_street", "bg_flat")
  end
  if category == "frameworks" then
    -- FRAMEWORKS (Rust Land only) is the job: the payment path off
    -- Gloucester Road, the settlement on the machines in the back room. The
    -- browser draws the same plate (`STREET` in frontend/src/scenes/quest.ts).
    return Assets.pick("bg_datacentre", "bg_street", "bg_flat")
  end
  local advanced = category == "advanced"
  if land == "go" then
    return Assets.pick(advanced and "bg_mtr" or "bg_till", "bg_mtr", "bg_flat")
  end
  if land == "cpp" then
    return Assets.pick(advanced and "bg_datacentre" or "bg_street", "bg_street", "bg_flat")
  end
  if land == "pytorch" then
    -- PyTorch Land is the teaching cluster: the machine room on every road.
    return Assets.pick("bg_datacentre", "bg_street", "bg_flat")
  end
  if land == "python" then
    return Assets.pick(advanced and "bg_times" or "bg_till", "bg_till", "bg_flat")
  end
  if land == "typescript" then
    -- TypeScript Land is office work: the street for BASIC, the data centre
    -- the front end is served from for ADVANCED.
    return Assets.pick(advanced and "bg_datacentre" or "bg_street", "bg_street", "bg_flat")
  end
  if land == "zig" then
    -- ZIG LAND is the Cross-Harbour Tunnel toll plaza at 06:00: the street
    -- plate for BASIC, and the toll control room — the data centre — for
    -- ADVANCED, as C++'s machine room is.
    return Assets.pick(advanced and "bg_datacentre" or "bg_street", "bg_street", "bg_flat")
  end
  if land == "lua" then
    -- LUA LAND is Tai Hang on Mid-Autumn night: the lanes at night for
    -- every road but ADVANCED, which gets the square the dragon ends in.
    return Assets.pick(advanced and "bg_times" or "bg_street", "bg_street", "bg_flat")
  end
  if land == "remix" then
    -- REMIX LAND is the café on Sugar Street: the till, with its counter and
    -- its price board, is the nearest plate to a cha chaan teng.
    return Assets.pick("bg_till", "bg_street", "bg_flat")
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
    -- VERY BASIC (PROTOCOL §5.3 `quiz`): the question is the brief, the four
    -- choices are drawn under it, and the editor is locked until the right
    -- one is picked — select one, then type it. Nothing goes to the server;
    -- the record is the typed line passing the tests.
    quiz_right = true,
    quiz_wrong = nil,
    quiz_wrong_at = nil,
    -- Every line ruled out this visit (a struck row stays struck), when
    -- each was struck, when the heading last said NOT THAT ONE, when the red
    -- vignette ran, and when the right line started typing into the hole.
    wrong_picks = {},
    wrong_at = {},
    not_that_at = nil,
    vignette_at = nil,
    fill_at = nil,
    -- The header's buttons (HINT, MAP) and which one the pointer is over;
    -- the brief card's own scroll beside the quiz card's `brief_scroll`.
    hits = {},
    hover = nil,
    side_scroll = 0,
    side_overflow = 0,
    choice_hits = {},
    -- The card's moments, all on the scene clock `t`: the choice under the
    -- pointer, when the four were dealt in, the frame's flash (red for a
    -- miss, gold for a streak), the page's jolt on a miss (0..1, decaying),
    -- the "×N COMBO" over a streak, and the verdict screen held back while
    -- the right pick's fireworks play (`Quiz.HOLD`).
    choice_hover = nil,
    choice_in_at = nil,
    choice_geom = {},
    quiz_flash = nil,
    quiz_jolt = 0,
    quiz_combo = nil,
    streak_at = nil,
    result_hold = nil,
    -- How far past its panel the brief runs, as last drawn, and a finger
    -- dragging it: a press on a choice is a pick only if it comes back up
    -- without having moved.
    brief_overflow = 0,
    brief_drag = nil,
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
    -- Which drill is on: "none", "blanks" (random gaps) or "solution"
    -- (everything the quest did not give you). See `answer_blanks` and
    -- `solution_blanks`.
    drill = "none",
    blanks = nil,
    -- The typing effects, over the editor: `src/codefx.lua`. It also draws
    -- ANSWER mode's bursts, which `src/sparks.lua` used to.
    fx = CodeFx.new(),
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
  self.fx:clear()
  self.fx:attach(self.editor, self.pane)
  -- The Rust coder, with the short list of powers a graded screen may give
  -- it: it reads, edits and writes the file, and it does **not** run it and
  -- has no room to talk in. A quest's RUN is an attempt against a server that
  -- is keeping score (PROTOCOL §4.8), and an agent that could spend one is an
  -- agent that could fail a quest on your behalf.
  self.coder = CoderM.new(self.app, self:agent_host())
  self.coder:mount(self.editor)
  -- Brackets close themselves — except under the ANSWER drill, where a `}`
  -- the editor typed for you is a divergence you did not make.
  self.editor.auto_close = not self.answer_on
  -- The four deal in again on every visit.
  Juice.forget("quest:")

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
  if self.coder then self.coder:leave() end
  self.app.session:off_all(self.subscriptions)
  self.subscriptions = nil
end

--- What the coder may do on a graded screen. Compare the playground's, which
--- is the generous one.
--- How much of the foot of the screen is spoken for, so a banner does not
--- land on the coder's room. The room is only at the bottom when the window
--- is upright; beside the editor it is in nobody's way.
function Quest:toast_lift()
  local r = self.agent_rect
  if not r then return 0 end
  -- Where the banner would land, against where the room is. Beside the
  -- editor on a wide window the two never meet; upright the room is the foot
  -- of the screen and the banner would sit on its buttons.
  local band = Layout.vh - UI.footerHeight() - 60
  if r.y + r.h < band then return 0 end
  return math.max(0, (Layout.vh - UI.footerHeight()) - r.y + 8)
end

--- The exercise, for the coder's prompt (`agent/session.lua`, and the
--- browser's `TaskBrief`).
---
--- Built on every ask rather than handed over at mount, so the run report in
--- it is the last run. Nil until `quest.get` has answered. `solution` is only
--- ever in the payload for a quest this player has already cleared (§4.8), so
--- there is no path here for an unsolved quest's answer.
function Quest:task_brief()
  local q = self.quest
  if not q then return nil end
  local tests = {}
  for _, c in ipairs((q.tests or {}).visible or {}) do
    tests[#tests + 1] = { stdin = c.stdin, expect = c.expect }
  end
  local last_run = nil
  local a = self.run_attempt
  if a then
    local failing = {}
    for _, c in ipairs(a.cases or {}) do
      if c.visible and not c.passed then
        failing[#failing + 1] = { stdin = c.stdin or "", expect = c.expect or "", got = c.got or "" }
      end
    end
    last_run = {
      verdict = a.verdict,
      passed = a.tests_passed or 0,
      total = a.tests_total or 0,
      stderr = a.stderr or "",
      failing = failing,
    }
  end
  return {
    title = q.title or "",
    brief = q.brief or "",
    story = q.story,
    tests = tests,
    hidden_count = (q.tests or {}).hidden_count or 0,
    cleared = q.state == "cleared",
    solution = q.solution,
    last_run = last_run,
  }
end

function Quest:agent_host()
  local scene = self
  return {
    lang = function() return Land.lang_of(scene.quest, scene.app.land) end,
    -- What the person was asked to do, the cases they can see, and what the
    -- last RUN said. Without it the coder on a graded screen can read the
    -- file and nothing else, which makes the one question anybody has here —
    -- "why is this wrong?" — the one it cannot answer.
    task = function() return scene:task_brief() end,
    caret = function()
      if not scene.pane then return nil end
      return scene.pane:cell(scene.editor.line, scene.editor.col)
    end,
    room_id = function() return nil end,
    room_key = function() return "quest" end,
    room_name = function() return "" end,
    ensure_room = function() return false end,
    touched = function() end,
    fx = function() return scene.fx end,
    request = nil,
    run = nil,
    format = nil,
  }
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
    -- The road this quest is on, for the screens after it (the result's
    -- NEXT asks the map by land and category): AUTO SELECT and a drive
    -- script arrive here without having walked through the map.
    if self.quest.land then self.app.land = self.quest.land end
    if self.quest.category then self.app.category = self.quest.category end
    -- The quiz comes first on VERY BASIC; a cleared quest is past it.
    self.quiz_right = not Quiz.starts_locked(self.quest.quiz, self.quest.state)
    -- CHEATSHEET is the quiz and nothing after it: the pick is the
    -- submission, so a cleared node can be answered again.
    if self:cheatsheet() then
      self.quiz_right = false
      self.focus = "brief"
    end
    -- A fresh quest deals its four in; a refresh of the same one (the
    -- language changed) does not deal them again.
    if self.quest.id ~= self.dealt_id then
      self.dealt_id = self.quest.id
      self.choice_in_at = self.t
      self.quiz_wrong = nil
      self.wrong_picks = {}
      self.wrong_at = {}
      self.fill_at = nil
      self.not_that_at = nil
      self.brief_scroll, self.side_scroll = 0, 0
      Juice.forget("quest:choice")
    end
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
function Quest:execute(mode, picked)
  if self.running_mode or not self.quest then return end
  -- Nothing on CHEATSHEET is compiled; only a pick is sent there.
  if self:cheatsheet() and not picked then return end
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
  -- A pick has no build log to show; a run or a submit does.
  self.show_log = not picked
  -- The note row holds one thing at a time, and what SOLVE said belongs to
  -- the buffer as it was before this ran.
  self.solve_note = nil
  self.stack_note = nil
  self.clear_armed = nil
  -- A pick made its own noise the moment it was made (`pick`); the
  -- server's reply to it is a confirmation, not a second event.
  if not picked then SFX.play("submit") end

  -- The stack gets a step at the two moments the buffer already leaves this
  -- machine. A run or a submit is the clearest "I meant that" a player ever
  -- gives an editor, and the server's duplicate check makes a redundant one
  -- free. A pick is not the buffer and pushes nothing.
  if not picked then self:edit_push() end

  self.app.session:request(mode, {
    quest_id = self.quest.id,
    -- §4.9: `lang` must match the quest's language — its own `lang` in
    -- REMIX LAND, its land everywhere else.
    lang = Land.lang_of(self.quest, self.app.land),
    source = picked or self.editor:text(),
  }, function(ok, payload, why)
    self.running_mode = nil
    self.stage = nil
    if not ok then
      -- A pick that reached no verdict is not taken: the four are open again.
      if picked then
        self.quiz_right = false
        self.fill_at = nil
      end
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
    if attempt.verdict == "accepted" then SFX.play("accepted")
    elseif not picked then SFX.play("rejected") end
    if picked and attempt.verdict ~= "accepted" then
      -- A wrong pick is recorded (it costs a star) and the four stay up —
      -- whatever this client made of the line, the server's word is final.
      self.quiz_right = false
      self.app.session:apply_xp(payload.xp)
      return
    end

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
    self.app.session:apply_xp(payload.xp)
    local result = {
      attempt = attempt,
      -- §4.9: what this submit was worth and where it left the player.
      xp = payload.xp,
      quest = self.quest,
      log = self.log,
      -- A pick's source is the line picked, not the editor nobody saw.
      source = picked or self.editor:text(),
    }
    if picked then
      -- The fireworks get their moment before the verdict screen takes
      -- over; `update` hands over when it is up, and a player who has
      -- already left is not pulled back (a scene that is gone is not
      -- updated).
      self.quiz_right = true
      self.result_hold = { at = self.t + Quiz.HOLD, result = result }
      return
    end
    self.app:go("result", result)
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
    lang = Land.lang_of(self.quest, self.app.land),
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

--- The question and the code, on the clipboard, in one press.
---
--- The browser's `askBlock` (`frontend/src/scenes/quest.ts`), for the person
--- whose AI is in another window rather than in this one: the brief they were
--- set, their program, and the last run's report, fenced as Markdown because
--- every chat box reads Markdown. Nothing in it is anything they cannot
--- already see — the hidden cases stay a number, and the answer is not in it.
function Quest:copy_ask()
  local q = self.quest
  if not q then return end
  local lang = Land.lang_of(q, self.app.land)
  local file = "main." .. (lang == "cpp" and "cpp" or lang == "go" and "go"
    or lang == "python" and "py" or lang == "pytorch" and "py"
    or lang == "typescript" and "ts" or lang == "zig" and "zig"
    or lang == "lua" and "lua" or "rs")
  local fence = lang == "python" and "python" or lang == "pytorch" and "python"
    or lang == "typescript" and "typescript" or lang == "zig" and "zig" or lang == "lua" and "lua"
    or lang == "cpp" and "cpp" or lang == "go" and "go" or "rust"
  local out = {}
  local function put(line) out[#out + 1] = line end

  put("## " .. I18n.t("the brief"))
  put("")
  put(("%02d  %s"):format(q.node or 0, q.title or ""))
  put("")
  put((q.brief or ""):gsub("%s+$", ""))
  local tests = (q.tests or {}).visible or {}
  for _, c in ipairs(tests) do
    put("")
    put(("%s:"):format(c.name or "case"))
    if c.stdin and c.stdin ~= "" then put("  in   " .. Json.encode(c.stdin)) end
    put("  out  " .. Json.encode(c.expect or ""))
  end
  local hidden = (q.tests or {}).hidden_count or 0
  if hidden > 0 then
    put("")
    put(("+ %d hidden case(s)"):format(hidden))
  end
  if q.story and q.story ~= "" then
    put("")
    put("“" .. q.story .. "”")
  end

  put("")
  put("## " .. file)
  put("")
  put("```" .. fence)
  put((self.editor:text()):gsub("%s+$", ""))
  put("```")

  local a = self.run_attempt
  if a then
    put("")
    put("## " .. I18n.t("the output"))
    put("")
    put("```")
    put(("%s — %d/%d"):format(a.verdict or "?", a.tests_passed or 0, a.tests_total or 0))
    for _, c in ipairs(a.cases or {}) do
      if c.visible and not c.passed then
        put(("%s: expected %s got %s"):format(c.name or "case",
          Json.encode(c.expect or ""), Json.encode(c.got or "")))
      end
    end
    if a.stderr and a.stderr ~= "" then put(a.stderr) end
    put("```")
  end

  love.system.setClipboardText(table.concat(out, "\n") .. "\n")
  SFX.play("select")
  self.app:toast(I18n.t("the question and your code, copied"))
end

function Quest:take_hint()
  if not self.quest then return end
  -- A quiz shows its hint in the brief card — but only a quest with hints
  -- authored (and not under an interview) has one to buy. The HINT button
  -- and the F7 footer hint are shown on the same condition.
  if self:cheatsheet() and not self:hints_available() then SFX.play("locked"); return end
  if self:cheatsheet() and self.hits.hint then UI.press("quest:hint", self.hits.hint, { sfx = false }) end
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

--- The answer's own indentation at the start of a line, to be filled in.
---
--- **Indentation is never the exercise, and it cannot be typed anyway.** A Go
--- answer is tab-indented (gofmt), a Rust one is four spaces (rustfmt), and
--- this editor's newline guesses `tab_width` spaces for every language — so
--- on a Go quest the space bar could never match the answer's tab, the line
--- stayed red, and no key would fix it. That was reported, and the quest was
--- unfinishable.
---
--- So the mode fills the run of spaces and tabs that starts a line, exactly
--- as the answer has it, and the player types the code.
function Quest.answer_indent(typed, answer)
  if not answer or answer == "" then return nil end
  local p = Quest.answer_progress(typed, answer)
  if #typed ~= p.matched then return nil end
  if p.matched > 0 and answer:sub(p.matched, p.matched) ~= "\n" then return nil end
  local run = answer:sub(p.matched + 1):match("^[ \t]+")
  return run
end

--- One line of the answer, for the button that asks for one.
---
--- **A line at a time, on a press.** It was a TAB binding and that was
--- wrong: TAB is the editor's key, a person writing code reaches for it to
--- indent, and a mode that quietly took it made the editor feel broken. A
--- button asks for exactly as much as it says and takes nothing away from
--- typing.
---
--- The rest of the line you are on, or — standing at a line's end — the
--- newline and the next line's indentation, because typing eight spaces from
--- memory teaches nobody anything. `nil` when the answer is typed, or when
--- the buffer has stopped being the answer: completing past a mistake would
--- bury it under correct text.
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

--- Hand over one line of the answer.
---
--- In BLANKS the line arrives with its holes filled — asking for a line is
--- asking for the whole line — and the fill carries on from there to the
--- next hole on its own.
function Quest:complete_line()
  if not self.answer_on or not self.answer_text or not self.editor then return end
  local insert = Quest.answer_completion(self.editor:text(), self.answer_text)
  if not insert then
    SFX.play("locked")
    return
  end
  self.editor:move("doc_end")
  self.editor:insert(insert)
  self:fill_blanks()
  SFX.play("move")
end

--- The closing half of a pair, typed for the player.
---
--- "Complete `()` and `""` automatically" is what every editor does, and
--- this mode cannot have it: a `)` put in after the caret is not a prefix of
--- the answer, so the drill would call the editor's own helpfulness a
--- divergence (which is why `auto_close` is off while the mode is on). So
--- the pair is closed from the *answer*, one character behind: the moment
--- what is typed is a clean prefix and the answer's next character is a
--- closer, it goes in by itself.
---
--- A quote is a closer only when it closes one: `"` opens and closes with
--- the same character, so the line's own quotes up to here are counted.
function Quest.answer_closer(typed, answer)
  local p = Quest.answer_progress(typed, answer)
  if #typed ~= p.matched then return nil end
  local ch = answer:sub(p.matched + 1, p.matched + 1)
  if ch == "" then return nil end
  if ch == ")" or ch == "]" or ch == "}" or ch == ">" then return ch end
  -- The quotes by byte rather than as literals: a lone double quote inside
  -- this file would leave `tests/test_screens.lua` pairing the rest of its
  -- string literals off by one, and that guard is worth more than the two
  -- characters it costs here. 34 is a double quote, 39 a single, 96 a
  -- backtick, 92 a backslash.
  local b = answer:byte(p.matched + 1)
  if b ~= 34 and b ~= 39 and b ~= 96 then return nil end
  local from = 1
  local nl = answer:sub(1, p.matched):find("\n[^\n]*$")
  if nl then from = nl + 1 end
  local n = 0
  for i = from, p.matched do
    if answer:byte(i) == b and answer:byte(i - 1) ~= 92 then n = n + 1 end
  end
  if n % 2 == 1 then return ch end
  return nil
end

--- The rest of a word, once the player has typed the start of it.
---
--- The drill is about remembering what the program says, not about spelling
--- `WaitGroup` by hand, so a few characters are enough: type `Wa` and the
--- word finishes itself. There is only one right continuation — the
--- answer's — so this cannot guess wrong the way a completion engine can.
--- `min` characters have to be typed first, or the whole answer would type
--- itself the moment the mode came on.
function Quest.answer_word(typed, answer, min)
  min = min or 2
  local p = Quest.answer_progress(typed, answer)
  if #typed ~= p.matched or p.matched == 0 then return nil end
  local head = answer:sub(1, p.matched):match("[%a_][%w_]*$") or
    answer:sub(1, p.matched):match("%d+$")
  if not head or #head < min then return nil end
  local rest = answer:sub(p.matched + 1):match("^[%w_]+")
  if rest and #rest > 0 then return rest end
  return nil
end

--- The words each language says over and over — its keywords and the
--- library names every answer in it reaches for. One letter of one of these
--- is enough: the answer is known, so `l` can only be `let` when the answer
--- says `let`. `frontend/src/ui/editor.ts` `COMMON` is the same list.
local function word_set(s)
  local t = {}
  for w in s:gmatch("%S+") do t[w] = true end
  return t
end
local PY = "def return if elif else for while in import from class self print range len None True False and or not with as lambda try except raise pass break continue yield input int str list dict set append split strip join"
Quest.COMMON = {
  rust = word_set("fn let mut use pub struct impl enum match for while loop return if else in as self Self crate mod trait where String Vec Option Some None Ok Err Result Box HashMap println print format vec new unwrap iter collect push len clone to_string std io collections"),
  go = word_set("func package import var const type struct interface return if else for range map chan go defer select switch case default break continue fmt Println Printf Sprintf make append len string int error nil main bufio os strings strconv"),
  cpp = word_set("include int void return if else for while auto const std vector string cout cin endl push_back size using namespace class struct template typename iostream long double bool true false main"),
  python = word_set(PY),
  pytorch = word_set(PY .. " torch nn tensor Tensor Module forward backward zeros ones randn optim grad no_grad"),
  typescript = word_set("let const function return if else for while of in new class interface type enum extends implements readonly private public async await import from export as keyof typeof number string boolean undefined null void never unknown true false console log length push map filter reduce split trim join Array Map Set Record Math require readFileSync"),
  zig = word_set("const var fn pub return if else for while switch try catch orelse defer struct enum union error comptime null undefined true false break continue and or std io gpa init print writer interface flush items append len u8 i64 usize f64 bool void anytype ArrayList AutoHashMap parseInt tokenizeAny"),
  lua = word_set("local function end return if then elseif else for while do repeat until in and or not nil true false break print io read write string table insert remove sort concat format tostring tonumber pairs ipairs setmetatable coroutine yield resume wrap math floor"),
}

--- The 0-based `i`th byte of `s` as a one-character string ("" past the end).
local function at(s, i) return s:sub(i + 1, i + 1) end
local function wordy(c) return c ~= "" and c:match("[%w_]") ~= nil end

--- Everything the answer is about to say that it has said before, once the
--- player has begun it.
---
--- **Recorded from this source, not from a dictionary.** A program repeats
--- itself — `std::collections::HashMap` twice on one line, `counts` five
--- times — and the second time is the chore, not the exercise. From the start
--- of the word the caret is in, the longest run the answer has already been
--- through goes in on the first letter, stopping at the end of the line and
--- at a token's edge; a keyword of the language (`Quest.COMMON`) goes in on
--- its first letter the first time too. `stop` caps the reach — BLANKS passes
--- the end of the hole, so a repeat never runs on into the next one. The
--- browser's `answerPattern` is the same rule.
function Quest.answer_pattern(typed, answer, lang, stop)
  stop = stop or math.huge
  local p = Quest.answer_progress(typed, answer)
  if #typed ~= p.matched or p.matched == 0 then return nil end
  local head = answer:sub(1, p.matched):match("[%a_][%w_]*$")
  if not head then return nil end
  local start = p.matched - #head
  local word_end = p.matched
  while word_end < #answer and wordy(at(answer, word_end)) do word_end = word_end + 1 end
  local nl = answer:find("\n", start + 1, true)
  local limit = math.min(nl and (nl - 1) or #answer, stop)
  local common = Quest.COMMON[lang] or Quest.COMMON.rust
  local best = common[answer:sub(start + 1, word_end)] and word_end or 0
  local first = answer:byte(start + 1)
  for j = 0, start - 1 do
    if answer:byte(j + 1) == first and (j == 0 or not wordy(at(answer, j - 1))) then
      local k = 0
      while j + k < start and start + k < limit
        and answer:byte(j + k + 1) == answer:byte(start + k + 1) do
        k = k + 1
      end
      if start + k > best then best = start + k end
    end
  end
  if best > limit then best = limit end
  -- A run that stops inside a word would leave half of one; back up to the
  -- token's edge, and leave trailing blanks for the player.
  while best > p.matched and wordy(at(answer, best - 1)) and wordy(at(answer, best)) do
    best = best - 1
  end
  while best > p.matched and at(answer, best - 1):match("[ \t]") do best = best - 1 end
  if best < word_end or best <= p.matched then return nil end
  return answer:sub(p.matched + 1, best)
end

--- How brightly the hole you are on is burning, 0..1, at `t` seconds.
---
--- **Exponential, not a sine.** A sine spends most of its time halfway,
--- which on a word you are trying to read is the worst place to be. This
--- rushes in on `1 - e^-kt`, holds at the top for the beat you read it in,
--- decays on `e^-kt`, and rests dark before coming round again.
Quest.HOLE_LOW = 0.12
--- How big a drill moment is drawn, as a share of the celebration burst. A
--- wrong character, a line closed, a hole left behind: these happen on a
--- line of code the player is reading, and the full-size shockwave covers
--- it. The finished answer is the exception and keeps its firework.
Quest.DRILL_SPARK = 0.34
function Quest.hole_glow(t, period)
  period = period or 2.8
  local u = (t % period) / period
  local k, span = 6, 1 - Quest.HOLE_LOW
  if u < 0.25 then return Quest.HOLE_LOW + span * (1 - math.exp(-k * u / 0.25)) end
  if u < 0.55 then return 1 end
  if u < 0.85 then return Quest.HOLE_LOW + span * math.exp(-k * (u - 0.55) / 0.3) end
  return Quest.HOLE_LOW
end

--- The holes BLANKS cuts in the answer, as `{ from, to }` byte offsets.
---
--- **Words, not characters.** A gap in the middle of `println` is a typing
--- exercise; a gap where `println` was is a memory one, and memory is what
--- this mode is for. Roughly a third of the identifiers and numbers, chosen
--- by a seeded generator so the same quest gives the same drill for as long
--- as it is open — a set that reshuffled every keystroke would be
--- unplayable. The rest of the program stays on the screen: that is the
--- point of the mode, and why it is a second button rather than a harder
--- ANSWER.
function Quest.answer_blanks(answer, seed)
  local words = {}
  local at = 1
  while true do
    local from, to = answer:find("[%a_][%w_]*", at)
    if not from then
      from, to = answer:find("%d+", at)
    end
    if not from then break end
    words[#words + 1] = { from = from - 1, to = to }
    at = to + 1
  end
  if #words == 0 then return {} end
  local r = (seed or 1) % 2147483647
  if r <= 0 then r = 1 end
  local function nextf()
    r = (r * 1103515245 + 12345) % 2147483648
    return r / 2147483648
  end
  local out = {}
  for _, w in ipairs(words) do
    if nextf() < 0.34 then out[#out + 1] = w end
  end
  -- Never a drill with nothing in it.
  if #out == 0 then out[1] = words[math.max(1, math.floor(#words / 2))] end
  return out
end

--- The holes for "type only the answer": everything the quest did not give.
---
--- A quest ships a starter — the imports, the `func main`, the scaffold —
--- and the answer is that with a solution written into it. Typing the
--- scaffold back out teaches nobody anything, so this cuts the holes at
--- exactly the lines the answer has and the starter does not: the scaffold
--- types itself and the player writes the part that is the actual work.
---
--- Line-based, by longest common subsequence, so a solution in two places —
--- an import up here, a loop down there — leaves the untouched middle alone
--- instead of swallowing it in one span. A hole starts after a line's
--- indentation, which the mode fills on its own.
function Quest.solution_blanks(answer, starter)
  local function split(text)
    local out = {}
    for line in ((text or "") .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    if #out > 0 then out[#out] = nil end
    return out
  end
  local a, b = split(answer), split(starter)
  -- The table is a screenful square, and what it buys is knowing which of
  -- the answer's lines are *new*.
  local t = {}
  for i = #a + 1, 1, -1 do
    t[i] = {}
    for j = #b + 1, 1, -1 do
      if i > #a or j > #b then
        t[i][j] = 0
      elseif a[i] == b[j] then
        t[i][j] = t[i + 1][j + 1] + 1
      else
        t[i][j] = math.max(t[i + 1][j], t[i][j + 1])
      end
    end
  end
  local shared = {}
  local i, j = 1, 1
  while i <= #a and j <= #b do
    if a[i] == b[j] then
      shared[i] = true
      i, j = i + 1, j + 1
    elseif t[i + 1][j] >= t[i][j + 1] then
      i = i + 1
    else
      j = j + 1
    end
  end
  -- A quest whose answer is its starter *minus* a line -- a "delete the bug"
  -- quest -- shares every line it has, and would leave the player nothing to
  -- type at all. There is no scaffold to skip there, so the honest reading is
  -- that the whole thing is theirs.
  local any = false
  for k = 1, #a do
    if not shared[k] and a[k]:match("%S") then any = true end
  end
  if not any then shared = {} end

  local out, at = {}, 0
  for k = 1, #a do
    local line = a[k]
    if not shared[k] then
      local indent = #(line:match("^[ \t]*") or "")
      -- A line that is only whitespace has nothing to type.
      if indent < #line then
        out[#out + 1] = { from = at + indent, to = at + #line }
      end
    end
    at = at + #line + 1
  end
  return out
end

--- The hole the typing is on at `at` characters in: the first one it has
--- not got past. The buffer is always a prefix of the answer, so how far in
--- is all that is needed to say which hole is live.
function Quest.hole_at(blanks, at)
  for _, b in ipairs(blanks or {}) do
    if b.to > at then return b end
  end
  return nil
end

--- The hole `at` is standing in, if any. Offsets are 0-based, as the spans.
local function blank_at(blanks, at)
  for _, b in ipairs(blanks or {}) do
    if at >= b.from and at < b.to then return b end
  end
  return nil
end

--- What the editor should type in for the player right now.
---
--- In BLANKS the answer is on the screen except for its holes, so everything
--- between one hole and the next is typed *for* you the moment you arrive at
--- it. `nil` when the caret is inside a hole (yours to type), when the buffer
--- has stopped being the answer (fix it first), or when there is nothing
--- left.
function Quest.blanks_fill(typed, answer, blanks)
  if not blanks or #blanks == 0 then return nil end
  local p = Quest.answer_progress(typed, answer)
  if #typed ~= p.matched then return nil end
  if blank_at(blanks, p.matched) then return nil end
  local upto = #answer
  for _, b in ipairs(blanks) do
    if b.from >= p.matched then upto = b.from; break end
  end
  if upto <= p.matched then return nil end
  return answer:sub(p.matched + 1, upto)
end

--- A slice of the answer, cut where the holes start and end.
---
--- The holes used to be drawn as rows of `_`, and that was the drill being
--- strict for its own sake: a player who cannot remember the word has
--- nothing to look at and no way to find out. So the word is drawn — it is
--- the answer, the same answer plain ANSWER puts on screen — and what marks
--- it as *yours to type* is that it breathes (`hole_glow`) rather than that
--- it is missing. A hint you can read is still a hint you have to type.
---
--- `from`/`to` are 0-based byte offsets into the whole answer, because the
--- ghost is drawn a line at a time and each line has to know where it sits
--- in the holes. `now` is the hole the player is on, marked so it can be
--- drawn brighter than the ones further down. Runs of the same kind merge.
function Quest.ghost_segments(answer, blanks, from, to, now)
  local out = {}
  local function push(text, hole, is_now)
    if text == "" then return end
    local last = out[#out]
    if last and last.hole == hole and last.now == is_now then
      last.text = last.text .. text
    else
      out[#out + 1] = { text = text, hole = hole, now = is_now }
    end
  end
  local at = math.max(0, from)
  local stop = math.min(to, #answer)
  for _, b in ipairs(blanks or {}) do
    if b.to > at then
      if b.from >= stop then break end
      push(answer:sub(at + 1, math.min(b.from, stop)), false, false)
      at = math.max(at, math.min(b.from, stop))
      push(answer:sub(at + 1, math.min(b.to, stop)), true, now ~= nil and b.from == now.from)
      at = math.min(b.to, stop)
    end
  end
  push(answer:sub(at + 1, stop), false, false)
  return out
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

--- The code face, cycled and remembered. One preference for both code panes:
--- how somebody likes to read code is a fact about them, not about which
--- screen they are on.
function Quest:cycle_face()
  local faces = Assets.CODE_FACES
  local at = 1
  for i, name in ipairs(faces) do
    if name == Assets.codeFace() then at = i end
  end
  local next_face = faces[(at % #faces) + 1]
  Assets.setCodeFace(next_face)
  require("src.store").set_face(next_face)
  self.solve_note = Assets.CODE_FACE_NAME[next_face]
  SFX.play("select")
end

--- What the THEME button says: the theme the pane is in now.
function Quest.theme_label()
  return Theme.codeTheme() == "light" and I18n.t("LIGHT") or I18n.t("DARK")
end

--- The code pane's light or dark, cycled and remembered — the playground's
--- preference too, like the face.
function Quest:cycle_theme()
  local themes = Theme.CODE_THEMES
  local at = 1
  for i, name in ipairs(themes) do
    if name == Theme.codeTheme() then at = i end
  end
  local next_theme = themes[(at % #themes) + 1]
  Theme.setCodeTheme(next_theme)
  require("src.store").set_code_theme(next_theme)
  self.solve_note = Quest.theme_label()
  SFX.play("select")
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
    self.editor.auto_close = true
    self.drill = "none"
    self.blanks = nil
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
  self.editor.auto_close = false
  -- Two readings of the same answer: what is drawn (holes masked) and what
  -- is compared against (the answer itself). Comparing against the mask
  -- would call a correctly typed word a divergence.
  self.blanks = self:drill_blanks()
  self.answer_lines = {}
  -- The real answer, not a masked copy: the holes are drawn in their own
  -- colour where they fall (`ghost_segments`), so the line and the thing
  -- compared against are one string again.
  for chunk in (self.answer_text .. "\n"):gmatch("(.-)\n") do
    self.answer_lines[#self.answer_lines + 1] = chunk
  end
  -- `gmatch` over `text .. "\n"` gives one trailing empty piece for a source
  -- that already ended in a newline; it is not a line of the answer.
  if self.answer_text:sub(-1) == "\n" then
    self.answer_lines[#self.answer_lines] = nil
  end
  -- Where each line of the answer starts inside it, so the draw can cut a
  -- line's ghost against holes held as whole-answer offsets.
  self.answer_starts = {}
  local at = 0
  for i, chunk in ipairs(self.answer_lines) do
    self.answer_starts[i] = at
    at = at + #chunk + 1
  end
  -- A new drill is a new run.
  self.combo, self.best_combo, self.echo, self.miss_at = 0, 0, "", nil
  self:fill_blanks()
  self.answer_prog = Quest.answer_progress(self.editor:text(), self.answer_text)
  self.answer_seen = self.editor:text()
  SFX.play("select")
end

--- The holes the drill that is on asks for.
function Quest:drill_blanks()
  if not self.answer_text then return nil end
  if self.drill == "blanks" then
    return Quest.answer_blanks(self.answer_text, Quest.blank_seed(self.quest and self.quest.id))
  end
  if self.drill == "solution" then
    -- Written out rather than folded into an `or`: `tests/test_screens.lua`
    -- guards this file against reaching for the starter as a *fallback*
    -- (§4.8 opens on `draft ?? starter`), and the guard is a text search.
    -- What is wanted here is the starter itself, to diff against.
    local starter
    if self.quest then starter = self.quest.starter end
    return Quest.solution_blanks(self.answer_text, starter)
  end
  return nil
end

--- "Type only the answer" on, off. Like BLANKS it needs the answer, so it
--- fetches it the same way — one star, once — and switches ANSWER on.
function Quest:toggle_solution()
  if not self.quest or self.answer_busy or self.solve_unsupported then
    if self.solve_unsupported then SFX.play("locked") end
    return
  end
  if self.drill == "solution" then
    self.drill = "none"
    self:arm_answer()
    SFX.play("move")
    return
  end
  if not self.answer_text then
    self.drill = "solution"
    self:toggle_answer()
    return
  end
  self.drill = "solution"
  -- From the beginning, for the reason BLANKS is: switching a drill on with
  -- the answer already typed out is a button that visibly does nothing.
  self.editor:replace_all("")
  self:arm_answer()
end

--- A seed from the quest's id, so the drill is the same for as long as the
--- screen is open rather than reshuffling under the player.
function Quest.blank_seed(id)
  -- djb2, and no bitwise operators: this file is LuaJIT's, where `~` is not
  -- one. Any spread will do — all the seed has to be is the same number for
  -- the same quest.
  local h = 5381
  for i = 1, #(id or "") do
    h = (h * 33 + id:byte(i)) % 2147483648
  end
  return h
end

--- Type the parts that are not the drill.
---
--- Looped, because filling up to one hole can leave the caret at the start of
--- the next the moment a hole is finished, and a player who typed the last
--- character of a word should not wait a keystroke for the line to catch up.
function Quest:fill_blanks()
  local none = { chars = 0, word = nil }
  if not self.answer_on or not self.editor or not self.answer_text then return none end
  local typed, word = 0, nil
  for _ = 1, 200 do
    -- The answer's own indentation, then — in BLANKS — everything up to the
    -- next hole. Indentation goes in either mode: it cannot be typed against
    -- an answer that indents differently from this editor, and it was never
    -- the thing being asked.
    -- Four things the drill types for you, in the order they come up: the
    -- answer's own indentation; in a drill, everything up to the next hole;
    -- the rest of the word you have started, because a few characters say
    -- which word you meant and there is only one it could be; and the
    -- bracket or quote that closes one you opened.
    local src = self.editor:text()
    local add = Quest.answer_indent(src, self.answer_text)
    if not add and self.drill ~= "none" and self.blanks then
      add = Quest.blanks_fill(src, self.answer_text, self.blanks)
    end
    local grown = nil
    if not add then
      -- Anything this file has said before, or a keyword, on its first
      -- letter — capped at the hole the caret is in, in a drill with holes.
      local stop = nil
      for _, b in ipairs(self.blanks or {}) do
        if #src >= b.from and #src < b.to then stop = b.to; break end
      end
      local lang = Land.lang_of(self.quest, self.app.land)
      grown = Quest.answer_pattern(src, self.answer_text, lang, stop)
        or Quest.answer_word(src, self.answer_text)
      add = grown
    end
    if not add then add = Quest.answer_closer(src, self.answer_text) end
    if not add then break end
    if add == grown then
      local head = src:match("[%w_]+$") or ""
      word = { #src - #head, #src + #add }
    end
    self.editor:move("doc_end")
    self.editor:insert(add)
    typed = typed + #add
  end
  return { chars = typed, word = word }
end

--- BLANKS on, BLANKS off. It needs the answer, so it fetches it the way
--- ANSWER does — one star, once — and switches ANSWER on with it.
function Quest:toggle_blanks()
  if not self.quest or self.answer_busy or self.solve_unsupported then
    if self.solve_unsupported then SFX.play("locked") end
    return
  end
  if self.drill == "blanks" then
    self.drill = "none"
    self:arm_answer()
    SFX.play("move")
    return
  end
  if not self.answer_text then
    -- Fetch first; the toggle comes back through `arm_answer` and the flag
    -- below is read there.
    self.drill = "blanks"
    self:toggle_answer()
    return
  end
  self.drill = "blanks"
  -- **The drill starts at the beginning.** Switching it on with the answer
  -- already typed out would otherwise be a button that visibly does nothing:
  -- every hole is behind the caret. What is in the buffer in ANSWER mode is
  -- the answer's own prefix, so nothing of the player's is lost.
  self.editor:replace_all("")
  self:arm_answer()
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
  -- Which hole was live *before* this keystroke. Read from the progress the
  -- last tick left behind, not from the buffer: by the time this runs the
  -- character is already in, so a hole finished by hand would look like a
  -- hole nobody was ever standing in.
  local was = self.answer_prog
  local hole_before = Quest.hole_at(self.blanks, was.matched)
  local before = #text
  local fill = self:fill_blanks()
  text = self.editor:text()
  self.answer_seen = text
  -- What the drill just typed on the player's behalf: keys that retype it
  -- out of habit are swallowed rather than counted as misses.
  self.echo = text:sub(before + 1)
  local now = Quest.answer_progress(text, self.answer_text)
  self.answer_prog = now
  if now.wrong == 0 and now.matched > was.matched then self:bump_combo() end
  local x, y = self:caret_xy()
  if not x then return end
  if now.done and not was.done then
    self.fx:burst(x, y, 70, Theme.admit)
    SFX.play("accepted")
  -- **What the drill typed for you, made visible.** A word that finished
  -- itself lights up along the letters that arrived; a hole left behind
  -- gets its own small burst. One or the other, never both: a word that
  -- finishes inside a hole finishes the hole too.
  elseif fill and fill.word then
    local wx, wy = self:offset_xy(fill.word[1])
    local ex, ey = self:offset_xy(fill.word[2])
    if wx and ex then
      self.fx:fill(wx, wy, ex, ey, { self:cell_size() }, Theme.coin)
    end
    SFX.play("move")
  -- A hole is behind you when the one that was live is not the live one any
  -- more — whether you typed its last character or the drill did.
  elseif hole_before and Quest.hole_at(self.blanks, now.matched) ~= hole_before then
    self.fx:burst(x, y, 16, Theme.coin, Quest.DRILL_SPARK)
    SFX.play("move")
  elseif now.wrong > was.wrong or now.matched < was.matched then
    -- **The divergence *growing*, not merely existing.** A quest opens with
    -- boilerplate in the buffer that is already not the answer, so "wrong
    -- where it was right before" would never fire on the screen it is for.
    self.fx:burst(x, y, 10, Theme.red, Quest.DRILL_SPARK)
    SFX.play("rejected")
  elseif was.wrong > 0 and now.wrong == 0 then
    self.fx:burst(x, y, 20, Theme.cyan, Quest.DRILL_SPARK)
    SFX.play("move")
  elseif now.matched > was.matched
    and self.answer_text:sub(was.matched + 1, now.matched):find("\n", 1, true) then
    self.fx:burst(x, y, 16, Theme.coin, Quest.DRILL_SPARK)
    SFX.play("move")
  end
end

--- One more key that was the answer's. Every tenth gets its own burst.
function Quest:bump_combo()
  self.combo = (self.combo or 0) + 1
  if self.combo > (self.best_combo or 0) then self.best_combo = self.combo end
  if self.combo % 10 ~= 0 then return end
  local x, y = self:caret_xy()
  if x then
    self.fx:burst(x, y, math.min(60, 14 + self.combo / 2), Theme.cyan, Quest.DRILL_SPARK * 1.6)
  end
  SFX.play("coin")
end

--- A key the drill refused. Retyping what the drill has just put in — the
--- `e` of a `use` that finished itself — is habit, not a mistake, and is
--- swallowed. Anything else missed: the count shakes (never the code — see
--- the run strip), the caret sparks red, and the combo starts over.
function Quest:drill_missed(text)
  local echo = self.echo or ""
  if #text > 0 and echo:sub(1, #text) == text then
    self.echo = echo:sub(#text + 1)
    return
  end
  self.echo = ""
  self.combo = 0
  self.miss_at = Anim.now()
  local x, y = self:caret_xy()
  if x then self.fx:burst(x, y, 10, Theme.red, Quest.DRILL_SPARK) end
  SFX.play("rejected")
end

--- Whether typing `text` at the caret keeps the buffer the answer.
---
--- **A wrong key does not go in.** A character that is not the answer's next
--- one is refused, the drill is told (`drill_missed`), and the caret stays
--- where the right key goes. Anything that leaves the buffer no further from
--- the answer than it was still goes in — a starter left in the file can be
--- fixed by hand — and so does typing over a selection.
function Quest:answer_admits(text)
  if not self.answer_on or not self.answer_text or not self.editor then return true end
  local ed = self.editor
  if ed:has_selection() then return true end
  local src = ed:text()
  local off = ed.col - 1
  for i = 1, ed.line - 1 do off = off + #ed.lines[i] + 1 end
  local after = Quest.answer_progress(src:sub(1, off) .. text .. src:sub(off + 1), self.answer_text)
  if after.wrong == 0 then return true end
  local before = Quest.answer_progress(src, self.answer_text)
  if after.wrong <= before.wrong and after.matched >= before.matched then return true end
  self:drill_missed(text)
  return false
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

--- One line of the ghost, from character `k` onward, with its holes in
--- their own colour.
---
--- The browser draws this with a span per run and two CSS variables
--- (`ui/editor.ts` `setGlow`); here it is the same two brightnesses printed
--- one run at a time. The hole the player is on breathes on `hole_glow`;
--- the ones further down sit dim and nearly steady, so the page reads as
--- one thing rather than one word twitching in a still paragraph.
function Quest:draw_ghost(want, index, k, x, y, font)
  local from = (self.answer_starts and self.answer_starts[index] or 0) + k
  local upto = from + #want - k
  local now = nil
  if self.blanks and self.editor then
    now = Quest.hole_at(self.blanks, #self.editor:text())
  end
  local segs = Quest.ghost_segments(self.answer_text or want, self.blanks, from, upto, now)
  if #segs == 0 then
    UI.setColor(Theme.pane.ghost)
    love.graphics.print(want:sub(k + 1), x, y)
    return
  end
  local g = Quest.hole_glow(self.t or 0)
  local rest = Quest.HOLE_LOW + 0.3 + 0.12 * g
  for _, seg in ipairs(segs) do
    if seg.hole then
      UI.setColor(Theme.withAlpha(Theme.pane.hole, seg.now and g or rest))
    else
      UI.setColor(Theme.pane.ghost)
    end
    love.graphics.print(seg.text, x, y)
    x = x + font:getWidth(seg.text)
  end
end

--- Where a byte offset in the document is on the screen, for an effect
--- thrown at a word rather than at the caret. `nil` when the line it is on
--- has scrolled out of the well.
function Quest:offset_xy(pos)
  local geo = self.editor_geo
  if not geo or not self.editor then return nil end
  local at, index = 0, 1
  local lines = self.editor.lines
  while index <= #lines and at + #lines[index] < pos do
    at = at + #lines[index] + 1
    index = index + 1
  end
  local row = index - self.editor.scroll
  if row < 1 or row > (self.visible_rows or 0) then return nil end
  local line = lines[index] or ""
  local x = geo.x0 + geo.gutter + geo.font:getWidth(line:sub(1, math.max(0, pos - at)))
  local y = geo.y0 + (row - 1) * geo.line_h + geo.line_h / 2
  return x, y
end

--- One character's cell: how wide a character is and how tall a line.
function Quest:cell_size()
  local geo = self.editor_geo
  if not geo then return 8, 16 end
  return math.max(4, geo.font:getWidth("M")), geo.line_h
end

function Quest:solve()
  -- `running_mode` is in the list because the button is painted `disabled`
  -- while a run or a submit is in flight, and a press that does something a
  -- greyed control says it will not do is worse than either behaviour on its
  -- own. (`Quest:format` still has that gap; it is not this round's to close.)
  if not self.quest or self.solving or self.solve_unsupported
    or self.running_mode or self:cheatsheet() then
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
  local text, err = External.edit(self.editor:text(), Land.lang_of(self.quest, self.app.land))
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
  self.fx:update(dt)
  if self.coder then
    self.coder:fly({ 0, 0, Layout.vw, Layout.vh }, self.agent_rect)
    self.coder:update(dt)
  end
  -- The land's loop keywords, for the effect a closed loop gets.
  self.editor.lang = Land.lang_of(self.quest, self.app.land)
  self:answer_tick()
  self:tick_clock()
  if self.running_mode then
    self.elapsed_ms = self.elapsed_ms + dt * 1000
  end
  self:tick_stack(dt)
  self:tick_quiz(dt)
end

--- The card's clocks: a held verdict is handed over once the burst has had
--- its moment. No toast lands on the right state meanwhile (the server's
--- CLEARED award is the one that used to): the green row is the clear.
function Quest:tick_quiz(dt)
  if self.quiz_jolt > 0 then self.quiz_jolt = math.max(0, self.quiz_jolt - dt * 2.4) end
  local hold = self.result_hold
  if hold then UI.clearToasts() end
  if hold and self.t >= hold.at then
    self.result_hold = nil
    self.app:go("result", hold.result)
  end
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
  -- The quiz (and every quest before it has arrived) wears the kit's band.
  if not self.quest or self:cheatsheet() then return UI.headerHeight() end
  return math.max(48, 8 + UI.lineHeight(13) + 2 + UI.lineHeight(7) + 8)
end

function Quest:panes()
  local vw, vh = Layout.vw, Layout.vh
  local top = self:header_h()
  local bottom = math.max(56, UI.footerHeight() + UI.lineHeight(9) + 14)
  local pad = 10
  -- CHEATSHEET: the question and its four lines are the whole screen.
  -- There is no editor to share it with, so the brief takes it and the
  -- code pane is nil — `draw` skips the well and `mousepressed` its bench.
  if self:cheatsheet() then
    return { x = pad, y = top, w = vw - pad * 2, h = vh - top - bottom }, nil
  end
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
    -- ASK AI, not AGENT: on a graded screen the press means "I have a
    -- question about this", and it lands in the question field.
    { id = "agent", label = I18n.t("ASK AI"),
      state = (self.coder and self.coder.panel.open) and "hot" or "normal" },
    -- The other way to ask, and the one that needs no key: the question and
    -- the code on the clipboard, for whatever the person has open elsewhere.
    { id = "copyask", label = I18n.t("COPY Q+CODE"),
      state = self.quest and "normal" or "disabled" },
    { id = "undo", label = I18n.t("UNDO"),
      state = (live and Edits.can_undo(self.edit)) and "normal" or "disabled" },
    { id = "redo", label = I18n.t("REDO"),
      state = (live and Edits.can_redo(self.edit)) and "normal" or "disabled" },
    { id = "answer", label = I18n.t("ANSWER"),
      state = self.answer_on and "hot"
        or ((usable and not self.solve_unsupported) and "normal" or "disabled") },
    { id = "blanks", label = I18n.t("BLANKS"),
      state = self.drill == "blanks" and "hot"
        or ((usable and not self.solve_unsupported) and "normal" or "disabled") },
    -- "Type only the answer": the quest's own scaffold types itself and what
    -- is left is the work. It needs a starter to diff against.
    { id = "solution", label = I18n.t("ANSWER ONLY"),
      state = self.drill == "solution" and "hot"
        or ((usable and not self.solve_unsupported and self.quest and self.quest.starter)
          and "normal" or "disabled") },
    -- One line of the answer, on a press. It used to be TAB, and TAB is the
    -- editor's key — a person writing code reaches for it to indent.
    { id = "complete", label = I18n.t("+LINE"),
      state = (self.answer_on and self.answer_text
        and Quest.answer_completion(self.editor:text(), self.answer_text))
        and "normal" or "disabled" },
    -- The face code is drawn in, cycled. Here rather than on the framed
    -- band, which is already the thing that took the editor's room at the
    -- largest type step.
    { id = "face", label = Assets.CODE_FACE_NAME[Assets.codeFace()], state = "normal" },
    -- Light or dark, for the code pane alone, beside the face for the same
    -- reason it is here.
    { id = "theme", label = Quest.theme_label(), state = "normal" },
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
    if self.drill == "blanks" then
      status = status .. "   " .. I18n.t("BLANKS")
    elseif self.drill == "solution" then
      status = status .. "   " .. I18n.t("ANSWER ONLY")
    end
    status = ("%s   %d / %d"):format(status, p.matched, p.total)
    if not p.done and (self.combo or 0) >= 3 then
      status = ("%s   %s x%d"):format(status, I18n.t("COMBO"), self.combo)
    elseif p.done and (self.best_combo or 0) >= 3 then
      status = ("%s   %s x%d"):format(status, I18n.t("BEST COMBO"), self.best_combo)
    end
    if p.done then
      status = status .. "   " .. I18n.t("MATCHED")
      colour = Theme.admit
    elseif p.wrong > 0 then
      status = status .. "   " .. I18n.t("FIX THE RED")
      colour = Theme.red
    else
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
  -- At the size the strip can hold it: with a drill on, this line carries a
  -- file, a mode, a count and a key, and at the larger type steps that is
  -- wider than a phone.
  -- A missed key shakes this line — the count — and not the code under it.
  local mx = 0
  if self.answer_on and self.miss_at then
    mx = Anim.shake(Anim.now() - self.miss_at, { duration = 0.22, amount = 4 })
  end
  UI.text(status, pad + 4 + mx, rowsb + 4, UI.fitSize(status, vw - pad * 2 - 8, 7, 4), colour)

  local top = strip + 6
  local body = { x = pad, y = top, w = vw - pad * 2, h = vh - top - pad }
  self:draw_editor(body, Theme.land[land] or Theme.coin, true)
  -- The room keeps clear of the footer. The editor may run under it — it is
  -- text, and the chips sit over their own plate — but the panel's buttons
  -- may not: the footer is drawn after the scene *and* takes its clicks
  -- first, so a SEND under it is a SEND that cannot be pressed.
  local room = { x = body.x, y = body.y, w = body.w,
    h = math.max(120, body.h - UI.footerHeight() - 4) }
  self.fx:draw()
  -- After the editor and after the effects: the coder is on top of the screen
  -- by being painted last, which is all "on top" can mean here.
  self.agent_rect = nil
  if self.coder then
    if self.coder.panel.open then
      local rect
      if not Layout.isPortrait() then
        local w = math.max(320, math.floor(room.w * 0.46))
        rect = { x = room.x + room.w - w, y = room.y, w = w, h = room.h }
      else
        local h = math.max(240, math.floor(room.h * 0.52))
        rect = { x = room.x, y = room.y + room.h - h, w = room.w, h = h }
      end
      self.agent_rect = rect
      self.coder:draw_panel(rect)
    end
    self.coder:draw()
  end
end

function Quest:draw()
  local vw, vh = Layout.vw, Layout.vh
  if self.code_mode then
    self:draw_code()
    self.app:footer(I18n.t("ESC done   F5 run   F2 format"))
    return
  end
  -- Every quest with a quiz is picked (SPEC §0), on the card below; the
  -- editor screen that follows is for the quests without one.
  if not self.quest or self:cheatsheet() then
    self:draw_quiz()
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
  -- A wrong pick jolts the page: the brief, which is the card, moves; the
  -- header and the footer stay where a player's eye left them.
  local jx, jy = self:jolt_offset()
  love.graphics.push()
  love.graphics.translate(jx, jy)
  self:draw_brief(brief, tint)
  love.graphics.pop()
  if code then self:draw_editor(code, tint) end

  if self:console_open() then
    self:draw_run_overlay(self.console_rect_drawn)
  end
  self.fx:draw()
  self:draw_quiz_moments()

  -- **Not** a second listing of F5, F10 and F2. Those three are printed on
  -- the buttons they belong to, a few centimetres above this line — `RUN F5`,
  -- `SUBMIT F10`, `FORMAT F2` — so repeating them here bought nothing and
  -- cost the four keys that have no button at all, which is what got clipped
  -- in portrait once the display controls took the right-hand end of the
  -- strip. What is left is exactly the keys the screen does not otherwise
  -- say out loud.
  self.app:footer(I18n.t(self:cheatsheet() and "1–4  PICK   ESC  MAP"
    or "F6 reset   F7 hint   F8 log   F9 $EDITOR   ESC map"))
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

--- Whether the quiz still stands between the player and the editor.
function Quest:quiz_locked()
  return self.quest ~= nil and self.quest.quiz ~= nil and not self.quiz_right
end

--- What picking choice `i` (1-based) means against `quiz`: "right", "wrong",
--- or nil for no such choice. `Quiz.pick`, without the "already answered"
--- half, under the name the tests have always called it by.
function Quest.pick_result(quiz, i)
  local verdict = Quiz.pick(quiz, i, false)
  if verdict == "ignored" then return nil end
  return verdict
end

--- The four wells, stacked. `Quiz.boxes`; see `src/quiz.lua`.
Quest.choice_boxes = Quiz.boxes

--- Whether the pick is the answer — on every road now (SPEC §0): a quest
--- with a quiz has no editor and nothing is typed. The name is the road it
--- started on.
function Quest:cheatsheet()
  return self.quest ~= nil and self.quest.quiz ~= nil
end

--- What stands in a quiz's program where the right choice was cut out.
Quest.HOLE = Quiz.HOLE

--- The program around a quiz's hole. `Quiz.program_lines`, the web's
--- `programLines`, line for line.
Quest.program_lines = Quiz.program_lines

-- ------------------------------------------------------------- the quiz card
--
-- Every quest with a `quiz` is picked, not typed (SPEC §0), and this is the
-- screen for it, built on the kit in `docs/love2d-ui.md` to the designer's
-- quest spec (§3.6) and the mock `SPEC-comp-neodgm.png`:
--
--   * **Header** (56, 72 upright): the title in the display role, the road
--     as a breadcrumb (`rust · cheatsheet · 01`), the clock in a slot of its
--     own, and HINT / MAP as secondary buttons on the right. Roles never
--     scale with F12, so the header cannot overprint itself at step 4.
--   * **Landscape**: two columns inside `UI.bounded()`. Left, the card the
--     screen is about (a gold top rule): the question, the code well with
--     the hole lit, PICK THE RIGHT LINE and the four choices as full-width
--     rows with their keycaps. Right: the brief card (blue rule) with the
--     story, the brief on a program quiz, the CONCEPTS chips and any hint
--     taken; under it the STARS / DIFFICULTY / HINTS card.
--   * **Upright**: one column — the quiz card first, the brief under it,
--     the stars card last — scrolled as a whole.
--   * **A program quiz** shows a window of the program round its hole in
--     the well, as many lines as the card has room for, so the hole and the
--     four answers are always seen together (review #9: the hole used to be
--     twenty lines below the fold). The full brief sits in the right card.
--   * **F12** moves the code and reading faces only. When the four would
--     not fit the card at the wanted code size the card steps the code down
--     first (to a floor of 12 px), and only then scrolls, with a fade and a
--     scrollbar; the hit boxes are cut to what is visible. The drive scripts
--     (`tests/drive/typesweep.lua`, `quiz.lua`) read `choice_hits` and
--     `brief_scroll` to prove it.
--   * **A wrong pick** stays: the row goes `redD`, its code is struck
--     through, "−1 ★" sits at its right, and its key does nothing for the
--     rest of the attempt. The row shakes, shards fly, a red vignette runs
--     round the screen for a beat (never a wash over the code), and the
--     heading reads NOT THAT ONE — n LEFT for a moment.
--   * **The right pick** goes `greenD`, the others dim and settle, the
--     answer is typed into the hole in green, stars and confetti burst
--     from the row, and the verdict screen waits `Quiz.HOLD` for it.

--- The code face for the card: the chosen code face at the code role's
--- size, which F12 moves (`Layout.codeSize`). `px` overrides it when the
--- card has had to step the code down to keep the four on the screen.
function Quest.quiz_font(px)
  px = px or Layout.codeSize(Theme.type.code)
  -- `Assets.mono` takes a size in the old VT323 register and scales each
  -- face down to match its cap height, which puts "16" at eleven pixels.
  -- The card wants the spec's sixteen: the scale is taken back out.
  local face = Assets.codeFace and Assets.codeFace() or nil
  local scale = (face and Assets.CODE_FACE_SCALE and Assets.CODE_FACE_SCALE[face]) or 1
  return Assets.mono(px / scale)
end

--- Code wrapped to `width` in `font` (the card's face by default): each line
--- keeps its indentation and a tab is four spaces. See `Quiz.code_wrap`.
function Quest.code_wrap(text, width, font)
  font = font or Quest.quiz_font()
  return Quiz.code_wrap(text, width, function(s) return font:getWidth(s) end)
end

--- One line of code in `font`, in the highlighter's colours — or all in
--- `colour` when the line is a state rather than code (dimmed, the hole).
function Quest:code_line(font, text, x, y, colour, alpha)
  love.graphics.setFont(font)
  if colour then
    UI.setColor(colour, alpha)
    love.graphics.print(text, x, y)
    love.graphics.setColor(1, 1, 1, 1)
    return
  end
  local lang = Land.lang_of(self.quest, self.app.land)
  local ok, spans = pcall(Editor.highlight, text, "code", lang)
  if not ok or type(spans) ~= "table" then
    UI.setColor(Theme.text, alpha)
    love.graphics.print(text, x, y)
    love.graphics.setColor(1, 1, 1, 1)
    return
  end
  local cx = x
  for _, span in ipairs(spans) do
    UI.setColor(Theme.code[span.kind] or Theme.text, alpha)
    love.graphics.print(span.text, cx, y)
    cx = cx + font:getWidth(span.text)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

--- The padding inside a well, and the room its text has in a well `w` wide.
local WELL_PAD = Theme.space.sm
local function well_inner(w)
  return w - WELL_PAD * 2 - 6
end

--- A fenced block's rows for a well: wrapped, the rows with the hole marked.
local function fence_rows(text, inner, font)
  local rows = {}
  for _, line in ipairs(Quest.code_wrap(text, inner, font)) do
    rows[#rows + 1] = { kind = Quiz.has_hole(line) and "hole" or "code", text = line }
  end
  return rows
end

--- A program's rows for a well: the window round the hole (`rows_max`
--- lines, or the whole program when nothing is asked), each line wrapped.
local function program_rows(program, inner, font, rows_max)
  local rows = {}
  local lines = rows_max and Quiz.window_lines(program, rows_max) or Quiz.program_lines(program)
  for _, line in ipairs(lines) do
    if line.kind == "cut" then
      rows[#rows + 1] = line
    else
      for _, piece in ipairs(Quest.code_wrap(line.text, inner, font)) do
        rows[#rows + 1] = { kind = line.kind, text = piece }
      end
    end
  end
  return rows
end

--- The hole's light, across a row of a well: a band that breathes while it
--- is a question and holds steady green once it is answered, with a bar at
--- its left edge so it reads as *the* line even in a long program.
function Quest:hole_band(x, y, w, h)
  local colour = self.quiz_right and Theme.green or Theme.gold
  UI.setColor(colour, Quiz.hole_alpha(self.t, self.quiz_right))
  love.graphics.rectangle("fill", x + 2, y, w - 4, h)
  UI.setColor(colour)
  love.graphics.rectangle("fill", x + 2, y, 4, h)
  love.graphics.setColor(1, 1, 1, 1)
  return colour
end

--- The line that fills the hole once the quiz is answered: the right
--- choice, typed in at `Quiz.TYPE_RATE` from the moment of the pick.
function Quest:hole_fill()
  local quiz = self.quest and self.quest.quiz
  if not (self.quiz_right and quiz and quiz.choices) then return nil end
  local answer = quiz.choices[(quiz.answer or 0) + 1]
  if not answer then return nil end
  local elapsed = self.fill_at and (self.t - self.fill_at) or 1e9
  return Quiz.typed(tostring(answer), elapsed) or ""
end

--- A code well: `rows` in `font`, the hole row lit. Returns the height.
function Quest:draw_well(x, y, w, rows, font)
  local lh = font:getHeight()
  local h = #rows * lh + WELL_PAD * 2
  UI.card(x, y, w, h, { variant = "well", pad = 0 })
  local cy = y + WELL_PAD
  local tx = x + WELL_PAD + 6
  local fill = self:hole_fill()
  for _, row in ipairs(rows) do
    if row.kind == "hole" then
      local colour = self:hole_band(x, cy, w, lh)
      local text = row.text
      if fill then
        -- The answer at the hole's own indentation, in green, as it types.
        local lead = row.text:match("^( *)") or ""
        text = UI.ellipsizeWith(lead .. fill, well_inner(w), font)
      end
      self:code_line(font, text, tx, cy, colour)
    elseif row.kind == "cut" then
      self:code_line(font, row.text, tx, cy, Theme.mute)
    else
      self:code_line(font, row.text, tx, cy, nil, 0.92)
    end
    cy = cy + lh
  end
  return h
end

--- The program a quiz's choices fill, with its hole lit, whole (a long one
--- cut to the web's window). Kept for the editor-path brief. Returns the y
--- after it.
function Quest:draw_program(x, y, w)
  local quiz = self.quest and self.quest.quiz
  local program = quiz and quiz.program
  if type(program) ~= "string" or program == "" then return y end
  local font = Quest.quiz_font()
  return y + self:draw_well(x, y, w, program_rows(program, well_inner(w), font), font) + Theme.space.md
end

--- A fenced block of a brief, in the code face, its hole lit. Returns the
--- y after it.
function Quest:draw_snippet(text, x, y, w)
  local font = Quest.quiz_font()
  return y + self:draw_well(x, y, w, fence_rows(text, well_inner(w), font), font) + Theme.space.md
end

--- A paragraph block in the reading face: paragraphs apart by a line gap,
--- bullets on their own lines. Returns the height; `measure` only measures.
function Quest:prose(text, x, y, w, colour, measure)
  local h = 0
  for _, para in ipairs(Quiz.blocks_lines(text)) do
    if para == "" then
      h = h + Theme.space.sm
    else
      if measure then
        h = h + (UI.readHeight(para, w))
      else
        h = h + UI.read(para, x, y + h, w, { color = colour })
      end
    end
  end
  return h
end

function Quest:prose_height(text, w)
  return self:prose(text, 0, 0, w, nil, true)
end

--- The road a streak is counted on.
function Quest:streak_key()
  local q = self.quest or {}
  return Quiz.streak_key(q.land or self.app.land, q.category or self.app.category)
end

--- Whether this quest has hints to give: authored ones, and not under an
--- interview (which takes them away, PROTOCOL §4.9e).
function Quest:hints_available()
  local q = self.quest
  return q ~= nil and (q.hints_total or 0) > 0 and not q.under_interview
end

--- How many of the four have been ruled out this visit.
function Quest:misses()
  local n = 0
  for _ in pairs(self.wrong_picks or {}) do n = n + 1 end
  return n
end

-- ----------------------------------------------------------------- the pick

--- One of the four, chosen — by its key (1–4) or by a tap on its row.
---
--- The pick is the submission (SPEC §0): the server judges it and records
--- it, a wrong one costing a star like any failed attempt. What this screen
--- adds is the moment: a wrong row goes red and stays red, struck and dead;
--- the right one goes green, the hole fills, and the verdict screen waits
--- `Quiz.HOLD` for the burst.
function Quest:pick(i)
  if not self.quest then return end
  if self:cheatsheet() and (self.running_mode or self.result_hold) then return end
  local verdict = Quiz.pick(self.quest.quiz, i, self.quiz_right, self.wrong_picks)
  if verdict == "ignored" then
    if self:cheatsheet() and self.wrong_picks[i] then SFX.play("locked") end
    return
  end
  if self:cheatsheet() then
    local geom = self.choice_geom[i]
    UI.press("quest:choice" .. i, geom and geom.rect or nil, { sfx = false })
    self:quiz_fx(verdict, i)
    if verdict == "right" then
      self.quiz_right = true
      self.quiz_wrong = nil
      self.fill_at = self.t
      SFX.play("coin")
    else
      self.wrong_picks[i] = true
      self.wrong_at[i] = self.t
      self.quiz_wrong = i
      self.quiz_wrong_at = self.t
      self.not_that_at = self.t
      self.vignette_at = self.t
      SFX.play("rejected")
    end
    self:execute("quest.submit", self.quest.quiz.choices[i])
    return
  end
  if verdict == "right" then
    self.quiz_right = true
    self.quiz_wrong = nil
    SFX.play("select")
    self.focus = "editor"
    return
  end
  self.quiz_wrong = i
  self.quiz_wrong_at = self.t
  SFX.play("locked")
end

--- The pick's moment: shards and smoke off a wrong row, stars and confetti
--- off the right one, and the streak counted (the web's `sheetFx`).
function Quest:quiz_fx(verdict, i)
  local key = self:streak_key()
  local first_try = next(self.wrong_picks) == nil
  local geom = self.choice_geom[i]
  local cx, cy
  if geom then
    cx, cy = geom.rect.x + geom.rect.w / 2, geom.rect.y + geom.rect.h / 2
  end
  if verdict == "wrong" then
    Quiz.record(key, "wrong", first_try)
    if cx then
      Fx.burst(cx, cy, "shards", { n = 1 })
      Fx.burst(cx, cy, "smoke", { n = 0.6 })
    end
    return
  end
  local streak = Quiz.record(key, "right", first_try)
  self.streak_at = self.t
  if cx then
    Fx.burst(cx, cy, "stars", { n = first_try and 1.6 or 1 })
    Fx.burst(cx, cy, "confetti", { n = first_try and 0.8 or 0.4, area = { geom.rect.w * 0.6, 4 } })
    if streak >= 2 then
      self.quiz_combo = { at = self.t, n = streak, x = cx, y = math.max(80, geom.rect.y - 24) }
    end
  end
end

-- ---------------------------------------------------------------- the rows

--- A red star, for the "−1 ★" a wrong row wears: the faces have no ★.
local function star(cx, cy, r, colour, alpha)
  UI.setColor(colour, alpha)
  love.graphics.polygon("fill", cx, cy - r, cx + r / 2.6, cy - r / 3, cx + r, cy - r / 3,
    cx + r / 2.2, cy + r / 5, cx + r / 1.6, cy + r, cx, cy + r / 2,
    cx - r / 1.6, cy + r, cx - r / 2.2, cy + r / 5, cx - r, cy - r / 3, cx - r / 2.6, cy - r / 3)
  love.graphics.setColor(1, 1, 1, 1)
end

--- The width "−1 ★" takes at the right of a row.
local function minus_star_w()
  return UI.labelWidth("-1", "title") + Theme.space.sm + 22 + Theme.space.sm
end

--- "−1 ★", right-aligned to `right`, rising into place over the first
--- third of a second after the miss and staying.
function Quest:draw_minus_star(right, y, h, alpha, i)
  local u = 1
  if self.wrong_at[i] then u = math.min(1, (self.t - self.wrong_at[i]) / 0.35) end
  local k = Juice.ease.outCubic(u)
  local dy = (1 - k) * 16
  local a = alpha * k
  local r = 11
  local sx = right - r
  star(sx, y + h / 2 + dy, r, Theme.redA, a)
  local lw = UI.labelWidth("-1", "title")
  UI.label("-1", sx - r - Theme.space.sm - lw, y + math.floor((h - UI.lead("title")) / 2) + dy, "title",
    { color = Theme.redA, alpha = a })
end

--- Each choice wrapped into a row `w` wide: the lines and the row heights.
function Quest:choice_wraps(w, font)
  local quiz = self.quest and self.quest.quiz
  local wraps, heights = {}, {}
  if not quiz or type(quiz.choices) ~= "table" then return wraps, heights end
  local lh = font:getHeight()
  local function measure(s) return font:getWidth(s) end
  local pad = Theme.space.md
  local text_x = Theme.space.md + 36 + Theme.space.lg
  local min_h = Layout.isPortrait() and 72 or 64
  for i, c in ipairs(quiz.choices) do
    local room = w - text_x - pad - (self.wrong_picks[i] and minus_star_w() or 0)
    wraps[i] = Quiz.code_wrap(tostring(c), math.max(40, room), measure)
    heights[i] = Quiz.row_height(#wraps[i], lh, pad, min_h)
  end
  return wraps, heights
end

--- The four rows' total height, stacked with `Theme.rowGap`.
function Quest:choices_height(w, font)
  local _, heights = self:choice_wraps(w, font)
  local h = 0
  for i, rh in ipairs(heights) do h = h + rh + (i > 1 and Theme.rowGap or 0) end
  return h
end

--- The four choices, one column from `y`, each row sized to its code: a
--- 36 px keycap with its number, the code at x+64, and the state's colours
--- (spec §2.9). Records the hit boxes, cut to `clip`, and the geometry the
--- burst needs. Returns the y after them.
function Quest:draw_choices(x, y, w, clip, font)
  local quiz = self.quest and self.quest.quiz
  self.choice_hits = {}
  self.choice_geom = {}
  if not quiz or type(quiz.choices) ~= "table" then return y end
  font = font or Quest.quiz_font()
  local lh = font:getHeight()
  local pad, cap = Theme.space.md, 36
  local text_x = Theme.space.md + cap + Theme.space.lg
  local wraps, heights = self:choice_wraps(w, font)
  local boxes = Quiz.boxes(x, y, w, heights, Theme.rowGap)
  local settle = Juice.follow("quest:settle", self.quiz_right and 1 or 0, { speed = 14 })
  local bottom = y
  for i, box in ipairs(boxes) do
    local right = self.quiz_right and (i - 1) == quiz.answer
    local wrong = self.wrong_picks[i] == true
    local dead = wrong or self.quiz_right or self.running_mode ~= nil
    local hover = self.choice_hover == i and not dead
    local state = right and "right" or wrong and "wrong" or (self.quiz_right and "dim")
      or (hover and "hot") or "idle"
    -- Dealt in from the right, one after another; lifted under the pointer;
    -- pushed in on the pick; shaken on a miss. The hit box is where the row
    -- rests, so a quick key is never a miss.
    local k = Juice.enter("quest:choice" .. i, { delay = Juice.stagger(i, 0.05), dur = 0.22, ease = "outBack" })
    local a = Juice.follow("quest:hot" .. i, hover and 1 or 0, { speed = 18 })
    local press = Juice.pressed("press:quest:choice" .. i)
    local dx = (1 - k) * 48
    local dy = -3 * a + 4 * press
    local alpha = math.min(1, k * 1.5)
    if state == "dim" then
      alpha = alpha * (1 - 0.6 * settle)
      dy = dy + 4 * settle
    end
    if wrong and self.wrong_at[i] then
      local sx = Anim.shake(self.t - self.wrong_at[i], { duration = Quiz.WRONG_LIFE, amount = 6 })
      dx = dx + sx
    end
    local bx, by = box.x + dx, box.y + dy
    local fill, edge, cap_fill = Theme.bar, Theme.edge, Theme.gold
    if state == "wrong" then
      fill, edge, cap_fill = Theme.redD, Theme.redA, Theme.redA
    elseif state == "right" then
      fill, edge, cap_fill = Theme.greenD, Theme.green, Theme.green
    elseif state == "dim" then
      cap_fill = Theme.mute
    end
    UI.card(bx, by, box.w, box.h, { fill = fill, edge = edge,
      hot = (state == "idle" or state == "hot") and a or 0,
      shadowDy = Theme.buttonShadowDy - 4 * press, alpha = alpha, pad = 0 })

    -- The keycap: the digit that picks it, 36 square, title-32 ink on gold.
    local cx, cy = bx + Theme.space.md, by + math.floor((box.h - cap) / 2)
    UI.setColor(Theme.edge, alpha)
    UI.rrect("fill", cx, cy + 3, cap, cap, Theme.radiusSm)
    UI.setColor(cap_fill, alpha)
    UI.rrect("fill", cx, cy, cap, cap, Theme.radiusSm)
    UI.stroke(cx, cy, cap, cap, Theme.radiusSm, Theme.withAlpha(Theme.edge, alpha))
    UI.label(Quiz.key_label(i), cx, cy + math.floor((cap - UI.lead("title")) / 2), "title",
      { width = cap, align = "center", color = Theme.edge, alpha = alpha, shadow = false })

    -- The code, struck through in red on a wrong row.
    local tx = bx + text_x
    local ty = by + math.floor((box.h - #wraps[i] * lh) / 2)
    local lines = {}
    for _, line in ipairs(wraps[i]) do
      self:code_line(font, line, tx, ty, state == "wrong" and Theme.mute or nil, alpha)
      if state == "wrong" then
        UI.setColor(Theme.redA, alpha)
        love.graphics.rectangle("fill", tx, ty + math.floor(lh / 2) - 1, font:getWidth(line), 2)
        love.graphics.setColor(1, 1, 1, 1)
      end
      lines[#lines + 1] = { x = tx, y = ty, text = line }
      ty = ty + lh
    end
    if state == "wrong" then self:draw_minus_star(bx + box.w - pad, by, box.h, alpha, i) end

    self.choice_geom[i] = {
      rect = { x = box.x, y = box.y, w = box.w, h = box.h },
      lines = lines,
      cell = { math.max(1, font:getWidth("M")), lh },
    }
    -- The hit box is the visible part: the card scrolls, and a row scrolled
    -- out of it must not take a tap meant for whatever is drawn there.
    local visible = box
    if clip then visible = Quiz.visible_box(box, clip) end
    if visible and not self.quiz_right and not wrong then self.choice_hits[i] = visible end
    bottom = math.max(bottom, box.y + box.h)
  end
  return bottom
end

--- PICK THE RIGHT LINE, in gold — RIGHT in green once it is, NOT THAT ONE
--- — n LEFT in red for a moment after a miss — with the streak at the right.
--- Returns the y after it.
function Quest:draw_quiz_heading(x, y, w)
  local quiz = self.quest.quiz
  local heading, colour = I18n.t("PICK THE RIGHT LINE"), Theme.gold
  if self.quiz_right then
    heading, colour = I18n.t("RIGHT"), Theme.green
  elseif self.not_that_at and self.t - self.not_that_at < Quiz.NOT_THAT_LIFE then
    heading = I18n.t("NOT THAT ONE · %d LEFT", Quiz.remaining(#(quiz.choices or {}), self.wrong_picks))
    colour = Theme.redA
  end
  local streak = Quiz.streak(self:streak_key())
  local sw = 0
  if streak > 0 then
    local label = I18n.t("STREAK ×%d", streak)
    local lw = UI.labelWidth(label, "label")
    sw = lw + Theme.space.lg
    -- It swells as it grows, and goes pink past five.
    local swell = 1
    if self.streak_at then
      swell = 1 + 0.5 * (1 - Ease.expOut(math.min(1, (self.t - self.streak_at) / 0.5)))
    end
    local lx, ly = x + w - lw, y + math.floor((UI.lead("title") - UI.lead("label")) / 2)
    love.graphics.push()
    love.graphics.translate(lx + lw / 2, ly + UI.lead("label") / 2)
    love.graphics.scale(swell, swell)
    love.graphics.translate(-(lx + lw / 2), -(ly + UI.lead("label") / 2))
    UI.label(label, lx, ly, "label", { color = streak >= 5 and Theme.pink or Theme.gold })
    love.graphics.pop()
  end
  UI.label(heading, x, y, "title", { width = w - sw, ellipsis = true, color = colour })
  return y + UI.lead("title")
end

-- --------------------------------------------------------------- the cards

--- The left card's blocks for a column `w` wide at code size `px`, with a
--- program window of at most `rows_max` lines: `{ kind, h, … }` in order,
--- and the total height with the gaps between them.
function Quest:left_blocks(w, px, rows_max)
  local quiz = self.quest.quiz
  local font = Quest.quiz_font(px)
  local lh = font:getHeight()
  local inner = well_inner(w)
  local blocks = {}
  local has_program = type(quiz.program) == "string" and quiz.program ~= ""
  if has_program then
    local rows = program_rows(quiz.program, inner, font, rows_max)
    blocks[#blocks + 1] = { kind = "well", rows = rows, h = #rows * lh + WELL_PAD * 2 }
  else
    for _, b in ipairs(Quiz.question_blocks(Quiz.blocks(self.quest.brief or ""))) do
      if b.kind == "code" then
        local rows = fence_rows(b.text, inner, font)
        blocks[#blocks + 1] = { kind = "well", rows = rows, h = #rows * lh + WELL_PAD * 2 }
      else
        blocks[#blocks + 1] = { kind = "read", text = b.text, h = self:prose_height(b.text, w) }
      end
    end
  end
  blocks[#blocks + 1] = { kind = "heading", h = UI.lead("title") }
  blocks[#blocks + 1] = { kind = "choices", h = self:choices_height(w, font) }
  local total = 0
  for i, b in ipairs(blocks) do total = total + b.h + (i > 1 and Theme.space.lg or 0) end
  return blocks, total, font
end

--- The code size and the program window the left card is drawn with, for a
--- column `w` wide with `room` of height (nil upright: content-sized).
---
--- The chrome gives way before the thing being read does, and the code
--- gives way before the four do: at type step 4 the wanted size is 32 px,
--- and four two-line choices under a question do not fit a 584 card. So
--- the window round the hole is as many lines as fit after the four, never
--- under three; when even that overflows, the code steps down two pixels at
--- a time to a floor of 12; and whatever is left over scrolls.
function Quest:left_fit(w, room)
  local px = Layout.codeSize(Theme.type.code)
  local quiz = self.quest.quiz
  local has_program = type(quiz.program) == "string" and quiz.program ~= ""
  local want_rows = Layout.isPortrait() and 9 or 11
  if not room then
    -- Upright: the well is capped at the spec's 420 px rather than the card.
    local lh = Quest.quiz_font(px):getHeight()
    return px, math.max(3, math.min(want_rows, math.floor((420 - WELL_PAD * 2) / lh)))
  end
  -- The spec's floor for code is 16; the smallest step authors 12.
  local floor_px = math.min(16, px)
  while true do
    local font = Quest.quiz_font(px)
    local lh = font:getHeight()
    local fixed = UI.lead("title") + Theme.space.lg + self:choices_height(w, font)
    local rows = want_rows
    if has_program then
      local free = room - fixed - Theme.space.lg - WELL_PAD * 2
      rows = math.max(3, math.min(want_rows, math.floor(free / lh)))
    end
    local _, total = self:left_blocks(w, px, rows)
    if total <= room or px <= floor_px then return px, rows end
    px = math.max(floor_px, px - 2)
  end
end

--- Back to the scissor the column is drawn under: the bounded area when
--- the whole column scrolls (upright), none otherwise. A card's own scissor
--- must never outlive its draw — one that did clipped the next frame's
--- backdrop, header and footer to the last card drawn.
function Quest:outer_scissor()
  local o = self.outer
  if o then love.graphics.setScissor(o.x, o.y, o.w, o.h) else love.graphics.setScissor() end
end

--- The quiz card: the question (or the program window), the well, the
--- heading and the four. `max_h` caps it and scrolls what does not fit
--- (`brief_scroll`); nil draws it content-sized (upright, where the column
--- scrolls as a whole). `clip` is the rect the hit boxes are cut to.
--- Returns the card's height.
function Quest:draw_left(x, y, w, max_h, clip)
  local pad = Layout.isPortrait() and Theme.space.lg or Theme.space.xl
  local cw = w - pad * 2
  local px, rows = self:left_fit(cw, max_h and (max_h - pad * 2) or nil)
  local blocks, total, font = self:left_blocks(cw, px, rows)
  local card_h = total + pad * 2
  if max_h then card_h = math.min(card_h, max_h) end
  local inner_h = card_h - pad * 2
  local scroll = 0
  if max_h then
    self.brief_overflow = math.max(0, total - inner_h)
    self.brief_scroll = math.max(0, math.min(self.brief_scroll, self.brief_overflow))
    scroll = self.brief_scroll
  end
  local cx, cy = UI.card(x, y, w, card_h, { strip = Theme.gold, pad = pad })
  -- The content is clipped to the card's inside (and to the column's clip,
  -- upright); the scissor is in canvas coordinates, as every scissor here.
  local sx, sy, sw, sh = cx - Theme.space.sm, cy - 2, cw + Theme.space.sm * 2, inner_h + 4
  if clip then
    local x2 = math.min(sx + sw, clip.x + clip.w)
    local y2 = math.min(sy + sh, clip.y + clip.h)
    sx, sy = math.max(sx, clip.x), math.max(sy, clip.y)
    sw, sh = math.max(0, x2 - sx), math.max(0, y2 - sy)
  end
  local region = { x = sx, y = sy, w = sw, h = sh }
  love.graphics.setScissor(sx, sy, sw, sh)
  local by = cy - scroll
  for i, b in ipairs(blocks) do
    if i > 1 then by = by + Theme.space.lg end
    if b.kind == "well" then
      self:draw_well(cx, by, cw, b.rows, font)
    elseif b.kind == "read" then
      self:prose(b.text, cx, by, cw, Theme.text)
    elseif b.kind == "heading" then
      self:draw_quiz_heading(cx, by, cw)
    elseif b.kind == "choices" then
      self:draw_choices(cx, by, cw, region, font)
    end
    by = by + b.h
  end
  self:outer_scissor()
  if max_h and self.brief_overflow > 0 then
    if scroll > 0 then UI.scrollFade(cx, cy, cw, Theme.card, "top") end
    if scroll < self.brief_overflow then UI.scrollFade(cx, cy + inner_h - Theme.space.xl, cw, Theme.card, "bottom") end
    UI.scrollbar(x + w - pad / 2 - 3, cy, inner_h, inner_h / total, scroll / self.brief_overflow)
  end
  return card_h
end

--- The brief card's blocks for a column `w` wide: the story (its short
--- lead in gold), the brief on a program quiz (prose and sample wells), the
--- CONCEPTS chips, and a hint once one is taken.
function Quest:side_blocks(w)
  local q = self.quest
  local blocks = {}
  local function read(text, colour)
    if text and text ~= "" then
      blocks[#blocks + 1] = { kind = "read", text = text, color = colour, h = self:prose_height(text, w) }
    end
  end
  local lead, rest = Quiz.story_lead(q.story)
  if lead then read(lead, Theme.gold) end
  read(rest, lead and Theme.text or Theme.mute)
  local quiz = q.quiz
  if quiz and type(quiz.program) == "string" and quiz.program ~= "" then
    local font = Quest.quiz_font()
    local lh = font:getHeight()
    for _, b in ipairs(Quiz.blocks(q.brief or "")) do
      if b.kind == "code" then
        local rows = fence_rows(b.text, well_inner(w), font)
        blocks[#blocks + 1] = { kind = "well", rows = rows, font = font, h = #rows * lh + WELL_PAD * 2 }
      else
        read(b.text, Theme.text)
      end
    end
  end
  if q.concepts and #q.concepts > 0 then
    -- Chips, wrapped into rows.
    local rows, row, used = 1, 0, 0
    for _, c in ipairs(q.concepts) do
      local cw = UI.chipWidth(c)
      if row > 0 and used + Theme.space.sm + cw > w then rows, used, row = rows + 1, 0, 0 end
      used = used + (row > 0 and Theme.space.sm or 0) + cw
      row = row + 1
    end
    blocks[#blocks + 1] = { kind = "concepts", rows = rows,
      h = UI.lead("label") + Theme.space.xs + rows * Theme.control.chip + (rows - 1) * Theme.space.sm }
  end
  if self.hint then
    blocks[#blocks + 1] = { kind = "hint", text = self.hint,
      h = UI.lead("label") + Theme.space.xs + self:prose_height(self.hint, w) }
  end
  local total = 0
  for i, b in ipairs(blocks) do total = total + b.h + (i > 1 and Theme.space.lg or 0) end
  return blocks, total
end

--- The brief card (blue rule). `max_h` caps and scrolls it (`side_scroll`);
--- nil draws it content-sized. Returns its height.
function Quest:draw_side(x, y, w, max_h, clip)
  local pad = Layout.isPortrait() and Theme.space.lg or Theme.space.xl
  local cw = w - pad * 2
  local blocks, total = self:side_blocks(cw)
  if #blocks == 0 then
    self.side_overflow = 0
    return 0
  end
  local card_h = total + pad * 2
  if max_h then card_h = math.min(card_h, max_h) end
  local inner_h = card_h - pad * 2
  local scroll = 0
  if max_h then
    self.side_overflow = math.max(0, total - inner_h)
    self.side_scroll = math.max(0, math.min(self.side_scroll, self.side_overflow))
    scroll = self.side_scroll
  else
    self.side_overflow = 0
  end
  local cx, cy = UI.card(x, y, w, card_h, { strip = Theme.blue, pad = pad })
  local sx, sy, sw, sh = cx - Theme.space.sm, cy - 2, cw + Theme.space.sm * 2, inner_h + 4
  if clip then
    local x2 = math.min(sx + sw, clip.x + clip.w)
    local y2 = math.min(sy + sh, clip.y + clip.h)
    sx, sy = math.max(sx, clip.x), math.max(sy, clip.y)
    sw, sh = math.max(0, x2 - sx), math.max(0, y2 - sy)
  end
  love.graphics.setScissor(sx, sy, sw, sh)
  local by = cy - scroll
  for i, b in ipairs(blocks) do
    if i > 1 then by = by + Theme.space.lg end
    if b.kind == "read" then
      self:prose(b.text, cx, by, cw, b.color)
    elseif b.kind == "well" then
      self:draw_well(cx, by, cw, b.rows, b.font)
    elseif b.kind == "concepts" then
      UI.label(I18n.t("CONCEPTS"), cx, by, "label", { color = Theme.mute, caps = true })
      local chip_y = by + UI.lead("label") + Theme.space.xs
      local used = 0
      for _, c in ipairs(self.quest.concepts) do
        local chw = UI.chipWidth(c)
        if used > 0 and used + Theme.space.sm + chw > cw then
          used = 0
          chip_y = chip_y + Theme.control.chip + Theme.space.sm
        end
        if used > 0 then used = used + Theme.space.sm end
        UI.chip(cx + used, chip_y, c, { color = Theme.blue })
        used = used + chw
      end
    elseif b.kind == "hint" then
      UI.label(I18n.t("HINT"), cx, by, "label", { color = Theme.gold, caps = true })
      self:prose(b.text, cx, by + UI.lead("label") + Theme.space.xs, cw, Theme.text)
    end
    by = by + b.h
  end
  self:outer_scissor()
  if max_h and self.side_overflow > 0 then
    if scroll > 0 then UI.scrollFade(cx, cy, cw, Theme.card, "top") end
    if scroll < self.side_overflow then UI.scrollFade(cx, cy + inner_h - Theme.space.xl, cw, Theme.card, "bottom") end
    UI.scrollbar(x + w - pad / 2 - 3, cy, inner_h, inner_h / total, scroll / self.side_overflow)
  end
  return card_h
end

--- The stars card's height: a caption row and a 40 px row of figures.
function Quest:stars_card_height()
  local pad = Layout.isPortrait() and Theme.space.lg or Theme.space.xl
  return pad * 2 + UI.lead("label") + Theme.space.xs + 40
end

--- STARS · DIFFICULTY · HINTS: what a clear is worth right now (the
--- server's cascade, SPEC §6.3 — the real count once it is cleared), the
--- difficulty as pips, and the hints taken of those authored, only when
--- there are any. A star lost to a miss drops out: smaller and grey.
function Quest:draw_stars_card(x, y, w)
  local q = self.quest
  local pad = Layout.isPortrait() and Theme.space.lg or Theme.space.xl
  local h = self:stars_card_height()
  local cx, cy, cw = UI.card(x, y, w, h, { pad = pad })
  local cols = { "stars", "difficulty" }
  if self:hints_available() then cols[#cols + 1] = "hints" end
  local col_w = math.floor(cw / #cols)
  local fy = cy + UI.lead("label") + Theme.space.xs
  local lit = q.state == "cleared" and (q.stars or 0)
    or Quiz.stars_potential(self:misses(), q.hints_used or 0)
  for i, col in ipairs(cols) do
    local ox = cx + (i - 1) * col_w
    if col == "stars" then
      UI.label(I18n.t("STARS"), ox, cy, "label", { color = Theme.mute, caps = true })
      for s = 1, 3 do
        local on = s <= lit
        local v = Juice.follow("quest:star" .. s, on and 1 or 0, { speed = 10 })
        local size = 32 * (0.6 + 0.4 * v)
        local sx, sy = ox + (s - 1) * 40 + 16, fy + 20
        if not Assets.marker("fx_star", sx, sy, size, { alpha = 0.25 + 0.75 * v }) then
          star(sx, sy, size / 2, Theme.gold, 0.25 + 0.75 * v)
        end
      end
    elseif col == "difficulty" then
      UI.label(I18n.t("DIFFICULTY"), ox, cy, "label", { color = Theme.mute, caps = true })
      UI.pips(ox, fy + 8, q.difficulty or 1, 10)
    else
      UI.label(I18n.t("HINTS"), ox, cy, "label", { color = Theme.mute, caps = true })
      UI.label(("%d / %d"):format(q.hints_used or 0, q.hints_total or 0), ox,
        fy + math.floor((40 - UI.lead("title")) / 2), "title")
    end
  end
  return h
end

-- -------------------------------------------------------------- the header

--- The road, as a breadcrumb: `rust · cheatsheet · 01`.
function Quest:breadcrumb()
  local q = self.quest or {}
  local parts = {}
  local land = q.land or self.app.land
  local category = q.category or self.app.category
  if land then parts[#parts + 1] = tostring(land) end
  if category then parts[#parts + 1] = (tostring(category):gsub("_", " ")) end
  if q.node then parts[#parts + 1] = ("%02d"):format(tonumber(q.node) or 0) end
  return table.concat(parts, " · ")
end

--- The header band: the title in the display role (title upright), the
--- breadcrumb, the clock in its own slot, and HINT / MAP on the right.
--- Laid out right to left, so nothing can print through anything else at
--- any type step (review #8: the clock was centred on `vw / 2`).
function Quest:draw_quiz_header()
  local vw = Layout.vw
  local h = UI.headerHeight()
  local g = Layout.gutter()
  local portrait = Layout.isPortrait()
  UI.card(0, 0, vw, h, { variant = "bar", pad = 0 })
  UI.setColor(Theme.edge, 0.6)
  love.graphics.rectangle("fill", 0, h - 2, vw, 2)
  love.graphics.setColor(1, 1, 1, 1)

  self.hits = {}
  local bh = Theme.control.buttonM
  local by = math.floor((h - bh) / 2)
  local right = vw - g
  local function button(id, label, key, state)
    -- Sized by the kit: a button never shrinks its label, and on a wide
    -- canvas the label face is a bigger one.
    local need_w, need_h = UI.buttonSize(label, { h = bh, key = key })
    local bw = math.max(88, need_w)
    local rh = math.max(bh, need_h)
    local r = { x = right - bw, y = math.floor((h - rh) / 2), w = bw, h = rh }
    UI.button(r.x, r.y, r.w, r.h, label, state, nil, { variant = "secondary", id = "quest:" .. id, key = key })
    self.hits[id] = r
    right = r.x - Theme.space.md
  end
  button("map", I18n.t("MAP"), "ESC", self.hover == "map" and "hot" or "normal")
  if self:hints_available() then
    local q = self.quest
    local spent = (q.hints_used or 0) >= (q.hints_total or 0)
    button("hint", I18n.t("HINT"), "F7", spent and "disabled" or (self.hover == "hint" and "hot" or "normal"))
  end

  -- The clock (PROTOCOL §4.8b), in a slot: calm for most of its life, a
  -- pulse on arrival, on a phase crossing and in the last quarter.
  local state = Clock.read(self.quest)
  if state then
    local now = Anim.now()
    local colour = ({ calm = Theme.text, warning = Theme.gold, urgent = Theme.redA, overtime = Theme.redA })[state.phase] or Theme.text
    local entrance = Ease.pulse(self.clock_arrived and (now - self.clock_arrived), 0.55)
    local crossing = Ease.pulse(self.clock_crossed and (now - self.clock_crossed), state.phase == "overtime" and 0.9 or 0.5)
    local urgency = Ease.attention(state.fraction)
    local text = Clock.format(state)
    local tw = UI.labelWidth(text, "title")
    local grow = 1 + 0.25 * crossing + 0.3 * entrance + 0.08 * urgency
    local cx, cy = right - tw / 2, h / 2
    love.graphics.push()
    love.graphics.translate(cx, cy)
    love.graphics.scale(grow, grow)
    love.graphics.translate(-cx, -cy)
    UI.label(text, right - tw, math.floor((h - UI.lead("title")) / 2), "title", { color = colour })
    love.graphics.pop()
    right = right - tw - Theme.space.xl
  end

  -- The title, in whatever language the server sent it (content is
  -- translated pack by pack, never here), and the breadcrumb beside it.
  local title = self.quest and self.quest.title or (self.error or I18n.t("loading…"))
  local role = portrait and "title" or "display"
  local room = math.max(40, right - g)
  local tw = math.min(UI.labelWidth(title, role), room)
  local crumb = self:breadcrumb()
  local crumb_w = UI.labelWidth(crumb, "label")
  local ty = math.floor((h - UI.lead(role)) / 2)
  if portrait then
    -- Two lines upright: the title, the road under it.
    local block = UI.lead(role) + UI.lead("label")
    ty = math.floor((h - block) / 2)
    UI.label(title, g, ty, role, { width = room, ellipsis = true,
      color = self.error and not self.quest and Theme.redA or Theme.gold })
    if crumb ~= "" then
      UI.label(crumb, g, ty + UI.lead(role), "label", { width = room, ellipsis = true, color = Theme.mute })
    end
    return
  end
  UI.label(title, g, ty, role, { width = tw, ellipsis = true,
    color = self.error and not self.quest and Theme.redA or Theme.gold })
  if crumb ~= "" and tw + Theme.space.xl + crumb_w <= room then
    UI.label(crumb, g + tw + Theme.space.xl, math.floor((h - UI.lead("label")) / 2), "label", { color = Theme.mute })
  end
end

-- ------------------------------------------------------------- the screen

--- The footer's keys, in priority order: the footer keeps the longest
--- prefix that fits. F7 only when there is a hint to take.
function Quest:quiz_hints()
  local items = { { key = "1-4", verb = I18n.t("pick") } }
  if self:hints_available() then items[#items + 1] = { key = "F7", verb = I18n.t("hint") } end
  items[#items + 1] = { key = "ESC", verb = I18n.t("map") }
  return items
end

--- The whole quiz screen. Also the loading and error states of every quest,
--- since the header is the same one.
function Quest:draw_quiz()
  local vw, vh = Layout.vw, Layout.vh
  local land = (self.quest and self.quest.land) or self.app.land or "rust"
  Assets.cover(Quest.backdrop(land, self.quest and self.quest.category
    or self.app.category), 0, 0, vw, vh)
  UI.setColor(Theme.felt, Layout.isPortrait() and 0.8 or 0.72)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  self:draw_quiz_header()
  local portrait = Layout.isPortrait()
  local top = UI.headerHeight() + Theme.space.lg
  local bx, by, bw, bh = UI.bounded(nil, top, vh - UI.footerHeight() - Theme.space.lg)
  self.bounds = { x = bx, y = by, w = bw, h = bh }

  if not self.quest then
    local pad = portrait and Theme.space.lg or Theme.space.xl
    local k = Juice.enter("quest:loading", { dur = Theme.motion.enter })
    local cx, cy, cw = UI.card(bx, by + (1 - k) * 24, bw, pad * 2 + UI.lead("label"),
      { strip = self.error and Theme.redA or Theme.gold, pad = pad, alpha = math.min(1, k * 1.5) })
    UI.label(self.error or I18n.t("asking the server…"), cx, cy, "label",
      { width = cw, ellipsis = true, color = self.error and Theme.redA or Theme.mute })
    self.choice_hits = {}
    self.app:footer(self:quiz_hints())
    return
  end

  if portrait then
    -- One column, scrolled as a whole: the quiz card, the brief, the stars.
    local clip = self.bounds
    self.outer = clip
    love.graphics.setScissor(bx, by, bw, bh)
    local y = by - self.brief_scroll
    y = y + self:draw_left(bx, y, bw, nil, clip)
    local side = self:draw_side(bx, y + Theme.gap, bw, nil, clip)
    if side > 0 then y = y + Theme.gap + side end
    y = y + Theme.gap + self:draw_stars_card(bx, y + Theme.gap, bw)
    love.graphics.setScissor()
    self.outer = nil
    local total = y + self.brief_scroll - by
    self.brief_overflow = math.max(0, math.floor(total - bh))
    self.brief_scroll = math.max(0, math.min(self.brief_scroll, self.brief_overflow))
    if self.brief_overflow > 0 then
      if self.brief_scroll > 0 then UI.scrollFade(bx, by, bw, Theme.felt, "top") end
      if self.brief_scroll < self.brief_overflow then UI.scrollFade(bx, by + bh - Theme.space.xl, bw, Theme.felt, "bottom") end
      UI.scrollbar(bx + bw - 6, by, bh, bh / total, self.brief_scroll / self.brief_overflow)
    end
  else
    -- Two columns: the quiz card (744 of 1232), the brief and the stars.
    local gap = Theme.space.xl
    local lw = math.floor((bw - gap) * 0.617)
    local rx, rw = bx + lw + gap, bw - lw - gap
    self.left_rect = { x = bx, y = by, w = lw, h = bh }
    self.side_rect = { x = rx, y = by, w = rw, h = bh }
    self:draw_left(bx, by, lw, bh, self.left_rect)
    local sh = self:stars_card_height()
    local side = self:draw_side(rx, by, rw, bh - sh - Theme.gap, self.side_rect)
    self:draw_stars_card(rx, by + (side > 0 and side + Theme.gap or 0), rw)
  end

  self:draw_quiz_moments()
  self.app:footer(self:quiz_hints())
end

--- The page's jolt, in virtual pixels — the editor path's brief still asks;
--- the quiz card no longer jolts the page (spec §4: an edge, not a wash).
function Quest:jolt_offset()
  local j = self.quiz_jolt or 0
  if j <= 0.001 then return 0, 0 end
  local k = j * j * 18
  return math.floor(math.sin(self.t * 41.3) * k + 0.5), math.floor(math.sin(self.t * 57.9) * k * 0.7 + 0.5)
end

--- The card's screen-wide moments, over everything: the red vignette of a
--- miss (an edge, never a wash over the code) and the "×N COMBO" of a
--- streak, zooming in from far too big over the row that was right.
function Quest:draw_quiz_moments()
  local vw, vh = Layout.vw, Layout.vh
  if self.vignette_at then
    local u = (self.t - self.vignette_at) / 0.3
    if u < 1 then
      local a = 1 - u
      love.graphics.setLineWidth(3)
      for i = 0, 5 do
        UI.setColor(Theme.redA, a * (0.9 - 0.14 * i))
        love.graphics.rectangle("line", 1.5 + i * 3, 1.5 + i * 3, vw - 3 - i * 6, vh - 3 - i * 6)
      end
      love.graphics.setLineWidth(1)
      love.graphics.setColor(1, 1, 1, 1)
    else
      self.vignette_at = nil
    end
  end
  local combo = self.quiz_combo
  if combo then
    local hold = 0.6
    local u = (self.t - combo.at) / hold
    if u > 2.2 then self.quiz_combo = nil; return end
    local scale, alpha = 1, 1
    if u < 1 then scale, alpha = Celebrate.zoom_in(u)
    elseif u >= 1.6 then scale, alpha = Celebrate.zoom_out((u - 1.6) / 0.6) end
    local label = I18n.t("×%d COMBO", combo.n)
    local lw = UI.labelWidth(label, "display")
    love.graphics.push()
    love.graphics.translate(combo.x, combo.y)
    love.graphics.scale(scale, scale)
    UI.label(label, -lw / 2, -UI.lead("display") / 2, "display",
      { color = combo.n >= 5 and Theme.pink or Theme.gold, alpha = alpha })
    love.graphics.pop()
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
  local prose = UI.fitSize(("M"):rep(14), column, self:cheatsheet() and 7 or 8, 5)
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
    -- The story line is scenery. On a picked quest it goes under the
    -- choices, so the question and its four answers come first — at the
    -- largest type step the story alone was most of the panel.
    local function story()
      if self.quest.story and self.quest.story ~= "" then
        for _, line in ipairs(UI.wrap(self.quest.story, column, prose)) do
          y = y + UI.text(line, x, y, prose, Theme.withAlpha(Theme.coin, 0.9)) + 3
        end
        y = y + 8
      end
    end
    local picked = self:cheatsheet()
    if not picked then story() end
    -- The brief is markdown (SPEC §2.1): its fences are drawn as code, in
    -- the code face, and its `**` and backticks are taken out rather than
    -- read aloud as punctuation (`Quiz.blocks`).
    --
    -- Wide and landscape, with a program to show, the panel is two columns
    -- as on the web: the question and the program on the left, the four
    -- choices at the top of the right with everything else under them. One
    -- column put the fourth choice under the fold on a ten-line program,
    -- and a HACKER program is eighty. The width it takes is measured: both
    -- halves must hold a line of code at the card's own size.
    local quiz = self.quest.quiz
    local has_program = quiz ~= nil and type(quiz.program) == "string" and quiz.program ~= ""
    local gutter = 16
    local code_font = Quest.quiz_font()
    local two = Quiz.two_columns(has_program, Layout.isPortrait(), column,
      math.floor(code_font:getWidth(("M"):rep(40)) / 0.42) + gutter)
    local left_w = two and math.floor((column - gutter) * 0.58) or column
    local col_top = y
    local left_end = 0
    local wide = column
    column = left_w
    local choices_drawn = false
    -- Portrait, with a program: the card comes first and the brief under
    -- it. One column cannot hold a HACKER brief, its program and four
    -- choices on one screen, and of the three the brief is the one a player
    -- reads once — the hole and the four are what they look back and forth
    -- between, so those are the two that share the screen.
    local card_first = quiz ~= nil and has_program and Layout.isPortrait()
    local function pick_up()
      y = self:draw_program(x, y, column)
      if two then
        left_end = y
        x = x + left_w + gutter
        column = wide - left_w - gutter
        indent = column - 10
        y = col_top
      end
      y = self:draw_choices(x, y, column, rect)
      choices_drawn = true
    end
    if card_first then pick_up(); y = y + 4 end
    for _, block in ipairs(Quiz.blocks(self.quest.brief or "")) do
      if block.kind == "code" then
        -- A sheet question's snippet with the hole in it is part of the
        -- question, and the four follow the question ("Which line is it?")
        -- under it. Any other fence is a worked example, and a sheet's four
        -- go *before* it, so a phone sees them without a scroll (the web's
        -- rule, which put them before the snippet with the hole too).
        local holed = Quiz.has_hole(block.text)
        if quiz and not has_program and not choices_drawn and not holed then pick_up() end
        y = self:draw_snippet(block.text, x, y, column)
      else
        for _, para in ipairs(Quiz.blocks_lines(block.text)) do
          if para == "" then
            y = y + 6
          else
            for _, line in ipairs(UI.wrap(para, column, prose)) do
              y = y + UI.text(line, x, y, prose, Theme.cream) + 3
            end
          end
        end
        y = y + 8
      end
    end
    y = y + 2
    -- The question was the brief; here is the program with its hole, and
    -- the four things that might go in it.
    if quiz and not choices_drawn then pick_up() end
    if picked then story() end

    if self.quest.concepts and #self.quest.concepts > 0 then
      y = y + UI.text(I18n.t("CONCEPTS"), x, y, 8, Theme.withAlpha(Theme.cream, 0.6)) + 4
      for _, line in ipairs(UI.wrap(table.concat(self.quest.concepts, ", "), column, 8)) do
        y = y + UI.text(line, x, y, 8, tint) + 3
      end
      y = y + 8
    end

    local tests = self.quest.tests or {}
    -- On a picked quest with nothing to show, the line is noise: a sheet
    -- question has no tests at all, and "0 hidden" told nobody anything.
    if not (picked and #(tests.visible or {}) == 0 and (tests.hidden_count or 0) == 0) then
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
    y = y + UI.text(hints, x, y, 7, Theme.withAlpha(Theme.cream, 0.5))
    y = math.max(y, left_end)
  end
  love.graphics.setScissor()

  -- How far the brief runs past its panel, and a scrollbar when it does: a
  -- panel that can scroll and does not say so is a panel whose bottom half
  -- nobody finds. The scroll is held inside it, so a wheel spun past the
  -- end does not leave the next spin a page of nothing to climb back.
  local content = y + self.brief_scroll - (rect.y + 10)
  self.brief_overflow = math.max(0, math.floor(content - (rect.h - 20)))
  self.brief_scroll = math.max(0, math.min(self.brief_scroll, self.brief_overflow))
  if self.brief_overflow > 0 then
    local track = rect.h - 16
    local thumb = math.max(16, track * track / (track + self.brief_overflow))
    local u = self.brief_scroll / self.brief_overflow
    UI.setColor(Theme.ink, 0.5)
    love.graphics.rectangle("fill", rect.x + rect.w - 9, rect.y + 8, 4, track)
    UI.setColor(Theme.coin)
    love.graphics.rectangle("fill", rect.x + rect.w - 9, rect.y + 8 + (track - thumb) * u, 4, thumb)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

--- Where the seven buttons stand, and how much of the well they stand in.
---
--- Its own function because `draw_editor` has to know the answer *before* it
--- decides how many rows of code fit. The band is two rows deep in English
--- now, and the editor was still being told the well ran all the way to the
--- bottom — which put the last lines of a long program, and the caret with
--- them, behind the SOLVE button. It was one row's worth of hidden text
--- before this round and would have been three.
function Quest:button_band(rect, drop)
  -- `drop` shrinks every label a step at a time. **Chrome gives way before
  -- the thing being typed into does**: at type step 4 in a 562-tall landscape
  -- window this band wanted three rows and 204 pixels of an editor pane 214
  -- tall, which left the code pane with -2 and the editor showing one line.
  drop = drop or 0
  local b9 = math.max(5, 9 - drop)
  local b8 = math.max(5, 8 - drop)
  local b7 = math.max(5, 7 - drop)
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
  local bh = math.max(28, UI.lineHeight(b9) + 12)
  local gap = 22
  local want = math.max(UI.textWidth(run_label, b9), UI.textWidth(submit_label, b9)) + 20
  -- A label wider than its button is printed through the neighbour. When
  -- the pair cannot have the width their full labels want, the key comes
  -- off — `RUN` and `SUBMIT` — rather than the word: the keys are in the
  -- footer's hint as well, and the word is what the button is.
  local function bare(label) return (label:gsub("%s%s+.*$", "")) end
  local room_pair = math.floor((rect.w - 30 - gap - 100 - 10) / 2)
  if want > room_pair then
    run_label = self.running_mode == "quest.run" and run_label or bare(run_label)
    submit_label = self.running_mode == "quest.submit" and submit_label or bare(submit_label)
    want = math.max(UI.textWidth(run_label, b9), UI.textWidth(submit_label, b9)) + 20
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
  local cap = UI.lineHeight(b7) + 3
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
  local sw = UI.textWidth(solve_label, b8) + 16
  local fw = UI.textWidth(format_label, b8) + 16
  -- ANSWER and CODE join the cluster that only ever changes the *buffer*.
  -- Neither writes an attempt, and neither must read as another way to
  -- submit — the same rule SOLVE and FORMAT are here under.
  local answer_label = I18n.t("ANSWER")
  local blanks_label = I18n.t("BLANKS")
  local code_label = I18n.t("CODE")
  local aw = UI.textWidth(answer_label, b8) + 16
  local blw = UI.textWidth(blanks_label, b8) + 16
  local cdw = UI.textWidth(code_label, b8) + 16
  local uw = UI.textWidth(undo_label, b8) + 16
  local rw = UI.textWidth(redo_label, b8) + 16
  local cw = UI.textWidth(clear_label, b8) + 16
  -- A whole row of the well, which is the most any cluster can ever have.
  local row = rect.w - 20
  -- The same rule for the left pair: when SOLVE and FORMAT with their keys
  -- do not fit a row of the well, the keys go.
  if sw + left_gap + fw + left_gap + aw + left_gap + blw + left_gap + cdw > row then
    solve_label = self.solving and solve_label or bare(solve_label)
    format_label = self.formatting and format_label or bare(format_label)
    sw = UI.textWidth(solve_label, b8) + 16
    fw = UI.textWidth(format_label, b8) + 16
  end
  local buffer_w = sw + left_gap + fw + left_gap + aw + left_gap + blw + left_gap + cdw
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
    cw = UI.textWidth(clear_label, b8) + 16
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
    local scale = (buffer_room - 4 * left_gap) / (sw + fw + aw + blw + cdw)
    sw = math.max(36, math.floor(sw * scale))
    fw = math.max(36, math.floor(fw * scale))
    aw = math.max(36, math.floor(aw * scale))
    blw = math.max(36, math.floor(blw * scale))
    cdw = math.max(36, math.floor(cdw * scale))
    buffer_w = sw + left_gap + fw + left_gap + aw + left_gap + blw + left_gap + cdw
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
  local blx = ax + aw + left_gap
  local cdx = blx + blw + left_gap
  -- The stack follows the buffer pair when they share a row, and otherwise
  -- starts at the left margin of its own.
  local ux = (uy == ly) and (vx + buffer_w + left_gap) or (rect.x + 10)
  local rdx = ux + uw + left_gap
  local clx = rdx + rw + left_gap
  return {
    run_label = run_label, submit_label = submit_label,
    format_label = format_label, solve_label = solve_label,
    answer_label = answer_label, blanks_label = blanks_label, code_label = code_label,
    ax = ax, blx = blx, cdx = cdx, aw = aw, blw = blw, cdw = cdw,
    undo_label = undo_label, redo_label = redo_label, clear_label = clear_label,
    bh = bh, cap = cap, bw = bw,
    b9 = b9, b8 = b8, b7 = b7,
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
  -- **The band gives way before the code does.** Measured at the player's own
  -- step first, and shrunk a step at a time only while it is taking more than
  -- half the pane — which at type step 4 in a 562-tall landscape window it
  -- was: 204 pixels of an editor 214 tall, leaving the code -2 and one line
  -- on screen. Four steps is as far as it goes; past that the window is too
  -- small for this screen and saying so beats drawing chrome nobody can use.
  local band = self:button_band(rect)
  for drop = 1, 4 do
    if band.reserve <= rect.h * 0.55 then break end
    band = self:button_band(rect, drop)
  end
  -- The console — the run's stages, its log and what it came back with —
  -- is **part of the layout, not a float**. It used to be a panel pinned to
  -- the bottom of the screen at a fixed 300 px, which in portrait sat on top
  -- of the button band and its captions: the very buttons a player needs
  -- after reading "does not compile" were under the compiler's output. The
  -- browser client subtracts a console height from the editor before laying
  -- anything out (`consoleH` in `frontend/src/scenes/quest.ts`), and this is
  -- the same rule: the code rows give up the space, the band keeps its row.
  local console = bare and { open = false, reserve = 0 } or self:console_rect(rect, band)
  -- **A type step is a preference; one line of code is not a code pane.** At
  -- step 4 the line height is 45 px, and a landscape window 562 tall has room
  -- for exactly one of them once the band and the console have taken theirs
  -- — which `math.max(1, …)` then presents as a working editor showing a
  -- single line. The band and the console are measured against the step's own
  -- size first, which over-states what they need when the code then shrinks,
  -- and over-stating is the safe side of this.
  local room = rect.h - 12 - (bare and 0 or band.reserve) - console.reserve
  font = Assets.mono(Layout.codeSizeFor(18, room, 6))
  local line_h = font:getHeight()
  -- The trailing space is not decoration: `%4d` right-aligns, so without
  -- it the last digit of the line number touches the first character of an
  -- unindented line and `1` reads as part of `fn`.
  local gutter = font:getWidth("0000 ")
  local rows = math.max(1, math.floor(room / line_h))
  self.editor:ensure_visible(rows)
  -- And across: a line wider than the pane used to take the caret off the
  -- right edge with it, which is most visible when the coder is writing.
  self.editor:ensure_visible_across(function(t) return font:getWidth(t) end,
    rect.w - gutter - 20)
  local shift = self.editor.scroll_x or 0
  self.visible_rows = rows
  self.editor_rect = rect
  self.console_rect_drawn = console.open and console or nil
  self.line_h = line_h
  self.gutter = gutter
  self.mono_font = font

  love.graphics.setScissor(rect.x + 3, rect.y + 3, rect.w - 6, rect.h - 6)
  -- The light theme's page, under the code rows and not the band or the
  -- console: those are the game's, and stay the game's colour.
  if Theme.pane.paper then
    UI.setColor(Theme.pane.paper)
    love.graphics.rectangle("fill", rect.x + 3, rect.y + 3, rect.w - 6, room + 6)
  end
  love.graphics.setFont(font)

  -- **The leftover goes above the text, not below it.** A pane is a whole
  -- number of lines and a rectangle is not, so up to a line's worth of height
  -- is left over. Left at the bottom it is an empty row under the last line —
  -- while a line is hidden off the top, because the scroll counts only whole
  -- rows. What a person sees is a page that moved one line before it had to.
  -- Given to the top instead, a scrolled pane fills to its bottom border and
  -- the slack reads as the margin it is. A file that fits the pane is not
  -- scrolled and keeps its slack at the foot, where an unstarted page wants
  -- it.
  local slack = math.max(0, room - rows * line_h)
  local x0 = rect.x + 8
  local y0 = rect.y + 6 + (self.editor.scroll > 0 and slack or 0)
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
    _, state = Editor.highlight(self.editor.lines[i] or "", state, self.editor.lang)
  end

  local sel_l1, sel_c1, sel_l2, sel_c2 = self.editor:selection()

  for row = 1, rows do
    local index = self.editor.scroll + row
    local line = self.editor.lines[index]
    if not line then break end
    local y = y0 + (row - 1) * line_h

    if index == self.editor.line then
      UI.setColor(Theme.pane.active)
      love.graphics.rectangle("fill", rect.x + 3, y, rect.w - 6, line_h)
    end

    -- Selection, one band per line.
    if sel_l1 and index >= sel_l1 and index <= sel_l2 then
      local from = (index == sel_l1) and sel_c1 or 1
      local to = (index == sel_l2) and sel_c2 or (#line + 1)
      local sx = x0 + gutter - shift + font:getWidth(line:sub(1, from - 1))
      local sw = font:getWidth(line:sub(from, to - 1))
      if to > #line and index < sel_l2 then sw = sw + font:getWidth(" ") end
      UI.setColor(Theme.pane.select)
      love.graphics.rectangle("fill", sx, y, math.max(2, sw), line_h)
    end

    -- A line number in `brick` means that line holds a bracket that never
    -- closed — said in the gutter as well as on the bracket, because the
    -- bracket itself may have scrolled off to the right.
    -- The ruler stays put while the text slides under it.
    UI.setColor(Theme.pane.gutter)
    love.graphics.rectangle("fill", rect.x + 3, y, gutter + 5, line_h)
    UI.setColor(self.pane:gutter_color(index))
    love.graphics.print(("%4d"):format(index), x0, y)

    local spans
    spans, state = Editor.highlight(line, state, self.editor.lang)
    local cx = x0 + gutter - shift
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
          local wx = x0 + gutter - shift + font:getWidth(line:sub(1, k))
          UI.setColor(Theme.red, 0.3)
          love.graphics.rectangle("fill", wx, y,
            math.max(2, font:getWidth(line:sub(k + 1))), line_h)
        end
        if k < #want then
          self:draw_ghost(want, index, k, x0 + gutter - shift + typed_w, y, font)
        end
      elseif #line > 0 then
        -- Typed past the end of the answer: all of this line is divergence.
        UI.setColor(Theme.red, 0.3)
        love.graphics.rectangle("fill", x0 + gutter - shift, y, math.max(2, typed_w), line_h)
      end
      love.graphics.setColor(1, 1, 1, 1)
    end

    if index == self.editor.line and self.focus == "editor" then
      local caret = x0 + gutter - shift + font:getWidth(line:sub(1, self.editor.col - 1))
      if (love.timer.getTime() * 2) % 2 < 1.2 then
        UI.setColor(Theme.pane.caret)
        love.graphics.rectangle("fill", caret, y, 2, line_h)
      end
    end
  end
  -- The lines of the answer the document has not reached yet, under the last
  -- one it has, for as many rows as the well still has.
  if self.answer_on and self.answer_lines then
    local after = self.editor:line_count()
    local row = after - self.editor.scroll + 1
    for i = after + 1, #self.answer_lines do
      if row > rows then break end
      self:draw_ghost(self.answer_lines[i], i, 0, x0 + gutter - shift,
        y0 + (row - 1) * line_h, font)
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
    UI.setColor(Theme.pane.scroll)
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
    (usable and not self.solve_unsupported) and "normal" or "disabled", band.b8)
  self.solve_rect = { x = vx, y = ly, w = sw, h = bh }
  UI.button(fx, ly, fw, bh, format_label,
    (usable and not self.format_unsupported) and "normal" or "disabled", band.b8)
  self.format_rect = { x = fx, y = ly, w = fw, h = bh }
  -- ANSWER wears `hot` while it is on: the screen is in a mode, and a mode
  -- that does not say so is a mode a player forgets they are in.
  UI.button(band.ax, ly, band.aw, bh, band.answer_label,
    self.answer_on and "hot"
      or ((usable and not self.solve_unsupported) and "normal" or "disabled"), band.b8)
  self.answer_rect = { x = band.ax, y = ly, w = band.aw, h = bh }
  UI.button(band.blx, ly, band.blw, bh, band.blanks_label,
    self.drill == "blanks" and "hot"
      or ((usable and not self.solve_unsupported) and "normal" or "disabled"), band.b8)
  self.blanks_rect = { x = band.blx, y = ly, w = band.blw, h = bh }
  UI.button(band.cdx, ly, band.cdw, bh, band.code_label,
    self.quest and "normal" or "disabled", band.b8)
  self.code_rect = { x = band.cdx, y = ly, w = band.cdw, h = bh }

  -- The stack's three, drawn from the state the server last sent and from
  -- nothing else. `src/net/edits.lua` owns the three predicates so that the
  -- greyness of a button and the `stack 3/5` caption under it cannot come to
  -- different conclusions about the same numbers.
  local stack = self.edit
  local live = usable and not self.edit_unsupported
  UI.button(ux, uy, uw, bh, band.undo_label,
    (live and Edits.can_undo(stack)) and "normal" or "disabled", band.b8)
  self.undo_rect = { x = ux, y = uy, w = uw, h = bh }
  UI.button(rdx, uy, rw, bh, band.redo_label,
    (live and Edits.can_redo(stack)) and "normal" or "disabled", band.b8)
  self.redo_rect = { x = rdx, y = uy, w = rw, h = bh }
  UI.button(clx, uy, cw, bh, band.clear_label,
    (live and Edits.can_clear(stack)) and "normal" or "disabled", band.b8)
  self.clear_rect = { x = clx, y = uy, w = cw, h = bh }

  UI.button(rx, by, bw, bh, run_label,
    (usable and not self.run_unsupported) and "normal" or "disabled", band.b9)
  UI.button(sx, by, bw, bh, submit_label, usable and "hot" or "disabled", band.b9)
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
  if UI.textWidth(price, band.b7) <= sw then
    UI.text(price, vx, ly - cap, band.b7,
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
  if UI.textWidth(stack_caption, band.b7) <= band.stack_w then
    UI.text(stack_caption, ux, uy - cap, band.b7,
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
  if self.coder and self.coder:textinput(text) then return end
  -- The quiz first: a digit picks, anything else is refused until it is right.
  if self:quiz_locked() then
    local n = tonumber(text)
    if n and n >= 1 and n <= 4 then self:pick(n) else SFX.play("locked") end
    return
  end
  if self.focus == "editor" then
    if not self:answer_admits(text) then return end
    self.editor:textinput(text)
    SFX.play("type")
  end
end

function Quest:keypressed(key, mods)
  mods = mods or {}
  -- Ctrl/Cmd-Shift-A opens and closes the coder, the browser's accelerator,
  -- and then the panel takes what it is holding a field for.
  if key == "a" and (mods.ctrl or mods.gui) and mods.shift then
    if self.coder then self.coder:toggle() end
    return true
  end
  if self.coder and self.coder:keypressed(key, mods) then return true end
  -- ESC ends the writing session before it ends the quest: a player in CODE
  -- pressing it means "put the furniture back", and taking them to the map
  -- would throw away the thing they were doing.
  if self.code_mode and key == "escape" then
    self.code_mode = false
    SFX.play("back")
    return true
  end
  -- CHEATSHEET has no editor: the keys that drive one (run, submit, reset,
  -- format, hint, solve, log, $EDITOR, the stack, the pane switch) do
  -- nothing here, and say so rather than fall through to a hidden buffer.
  if self:cheatsheet() then
    local fkey = key == "f2" or key == "f5" or key == "f6"
      or key == "f8" or key == "f9" or key == "f10"
    local chord = (mods.ctrl or mods.gui) and (key == "return" or key == "kpenter"
      or key == "f" or key == "z" or key == "tab")
    -- Shift-F7 is SOLVE: the whole answer into an editor a quiz does not
    -- have, priced as the largest hint. Plain F7 (a hint) stays open.
    local solve = key == "f7" and mods.shift
    if fkey or chord or solve or key == "tab" then
      SFX.play("locked")
      return true
    end
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
  -- **ENTER is a plain newline while the mode is on.** `Editor:newline`
  -- guesses an indent — `tab_width` spaces — and against an answer indented
  -- any other way that guess is a divergence the player did not type and
  -- cannot remove by typing. `fill_blanks` puts the answer's own indentation
  -- in a moment later, so the editor must not put its guess in first.
  if self.answer_on and self.focus == "editor" and self.editor
    and (key == "return" or key == "kpenter") and not cmd then
    if self:answer_admits("\n") then self.editor:insert("\n") end
    return true
  end
  -- TAB is the editor's key and keeps indenting — but in the drill an indent
  -- the answer does not have is a wrong key like any other, and the drill
  -- puts the answer's own indentation in by itself (`fill_blanks`).
  if self.answer_on and self.focus == "editor" and self.editor and key == "tab"
    and not cmd and not mods.shift and not self.editor:has_selection() then
    local ed = self.editor
    local spaces = ed.tab_width - (Editor.char_count(ed.lines[ed.line]:sub(1, ed.col - 1)) % ed.tab_width)
    if not self:answer_admits(string.rep(" ", spaces)) then return true end
  end

  if self:quiz_locked() then
    -- The keypad's digits with NUM LOCK off send no text; they pick too.
    local kp = key:match("^kp([1-4])$")
    if kp and not love.keyboard.hasTextInput() then self:pick(tonumber(kp)); return true end
    -- Digits arrive through `textinput`; the editing keys are refused while
    -- the editor is locked, and the rest (scroll, panes) still work.
    if key == "return" or key == "kpenter" or key == "backspace" or key == "delete"
      or key == "tab" then
      SFX.play("locked")
      return true
    end
    if key == "up" then self.brief_scroll = math.max(0, self.brief_scroll - 24); return true end
    if key == "down" then self.brief_scroll = self.brief_scroll + 24; return true end
    return false
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
  if self.coder then
    local vx, vy = Layout.toVirtual(love.mouse.getPosition())
    if self.coder:wheelmoved(dy, vx, vy) then return end
  end
  if self:cheatsheet() or not self.quest then
    -- The column under the pointer scrolls: the brief card has its own
    -- scroll beside the quiz card's in landscape.
    local vx, vy = Layout.toVirtual(love.mouse.getPosition())
    if self.side_rect and vx and UI.inside(self.side_rect, vx, vy) and not Layout.isPortrait() then
      self.side_scroll = math.max(0, math.min(self.side_overflow or 0, self.side_scroll - dy * 30))
    else
      self.brief_scroll = math.max(0, math.min(self.brief_overflow or 0, self.brief_scroll - dy * 30))
    end
    return
  end
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
  -- The coder first: its panel owns what is under it, and a press on the
  -- sprite holds it still.
  if self.coder and self.coder:mousepressed(x, y, button) then return end
  if self.code_mode then
    if inside(self.code_done_rect) then
      self.code_mode = false
      SFX.play("back")
      return
    end
    local r = self.code_rects or {}
    if inside(r.agent) then
      -- Open: straight into the question. Already open: the same press puts
      -- it away, which is what a lit button means everywhere else here.
      if self.coder.panel.open then self.coder:toggle() else self.coder:open_ask() end
      return
    end
    if inside(r.copyask) then self:copy_ask(); return end
    if inside(r.run) then self:run(); return end
    if inside(r.format) then self:format(); return end
    if inside(r.undo) then self:stack_undo(); return end
    if inside(r.redo) then self:stack_redo(); return end
    if inside(r.answer) then self:toggle_answer(); return end
    if inside(r.blanks) then self:toggle_blanks(); return end
    if inside(r.solution) then self:toggle_solution(); return end
    if inside(r.complete) then self:complete_line(); return end
    if inside(r.face) then self:cycle_face(); return end
    if inside(r.theme) then self:cycle_theme(); return end
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
  if self:cheatsheet() or not self.quest then
    -- No bench and no editor on this road: the header's two buttons, the
    -- four rows and the cards are all there is to press. A finger on a
    -- column that scrolls is a drag until it lifts: a press there is a
    -- pick only if it comes back up without having moved, or a tablet could
    -- never scroll past a choice.
    self.focus = "brief"
    local hits = self.hits or {}
    if inside(hits.map) then
      UI.press("quest:map", hits.map, { sfx = false })
      self.app:back()
      return
    end
    if inside(hits.hint) then self:take_hint(); return end
    local column = Layout.isPortrait() and self.bounds or self.left_rect
    if self.brief_overflow > 0 and inside(column) then
      self.brief_drag = { y = y, scroll = self.brief_scroll, moved = false }
      return
    end
    for i, r in pairs(self.choice_hits or {}) do
      if inside(r) then self:pick(i); return end
    end
    return
  end
  if inside(self.solve_rect) then self:solve(); return end
  if inside(self.format_rect) then self:format(); return end
  if inside(self.answer_rect) then self:toggle_answer(); return end
  if inside(self.blanks_rect) then self:toggle_blanks(); return end
  if inside(self.code_rect) then self:enter_code(); return end
  if inside(self.undo_rect) then self:stack_undo(); return end
  if inside(self.redo_rect) then self:stack_redo(); return end
  if inside(self.clear_rect) then self:stack_clear(); return end
  if inside(self.run_rect) then self:run(); return end
  if inside(self.submit_rect) then self:submit(); return end
  for i, r in pairs(self.choice_hits or {}) do
    if inside(r) then self:pick(i); return end
  end
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
  local drag = self.brief_drag
  if drag then
    if math.abs(y - drag.y) > 8 then drag.moved = true end
    if drag.moved then
      self.brief_scroll = math.max(0, math.min(self.brief_overflow, drag.scroll - (y - drag.y)))
    end
  end
  -- The choice under the pointer, lit.
  local hover = nil
  for i, r in pairs(self.choice_hits or {}) do
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then hover = i end
  end
  if hover ~= self.choice_hover and hover and not self.quiz_right then SFX.play("move") end
  self.choice_hover = hover
  -- And the header's buttons.
  local hits = self.hits or {}
  self.hover = (UI.inside(hits.hint, x, y) and "hint") or (UI.inside(hits.map, x, y) and "map") or nil
  if self.coder then self.coder:mousemoved(x, y) end
  if self.pane then self.pane:mousemoved(x, y) end
  self.fx:pointer(x, y)
end

function Quest:mousereleased(x, y)
  local drag = self.brief_drag
  self.brief_drag = nil
  if drag and not drag.moved and x then
    for i, r in pairs(self.choice_hits or {}) do
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        self:pick(i)
        break
      end
    end
  end
  if self.pane then self.pane:mousereleased() end
end

return Quest
