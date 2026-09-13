/**
 * The quest screen: brief, editor, console.
 *
 * The one thing this screen is careful about is that it does **not** judge
 * anything. It sends `quest.submit`, watches `run.stage` and `run.log` arrive
 * as `id: null` events, and waits for the reply to its own request to say what
 * happened (SPEC §5.4). There is no local "does this look right" — the
 * compiler is on the other side of the socket and it is the only opinion.
 *
 * Layout is the same two boxes as everywhere else, so portrait works by
 * construction: brief above, editor below, with the console sharing the
 * editor's box as a drawer that opens when a run starts.
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf, width, wrap } from "../engine/text";
import { css, Theme, type RGBA } from "../engine/theme";
import { btnBox, rowsIn, clipped, fill, inRect, well, type Ctx, type Rect } from "../engine/ui";
import {
  arriving,
  Buttons,
  footer,
  frame,
  header,
  landColour,
  titledPanel,
  type Stack,
} from "../ui/chrome";
import { CLOCK, clockPulse, reducedMotion, seconds, Tween } from "../engine/motion";
import { Editor, MAIN_FILE, answerProgress, type AnswerProgress } from "../ui/editor";
import { burstPlan } from "../engine/burst";
import { Overlay } from "../ui/overlay";
import { Sparks } from "../ui/sparks";
import { WireError } from "../net/client";
import { playerText } from "../net/protocol";
import type { Attempt, Category, EditState, Land, Quest, RunStage } from "../net/protocol";
import { LogBuffer } from "../net/logbuf";
import { blocks } from "../ui/markdown";
import { clipMessage, copyText, readText } from "../ui/clip";
import { readEnumPref, readNumberPref, writePref } from "../ui/prefs";
import { LandsScene } from "./lands";
import { locale, t, tn, type Locale } from "../i18n";
import { MapScene } from "./map";
import { ResultScene } from "./result";

type Stage = "idle" | RunStage;

/**
 * How the brief and the bench sit, and how big the code is — remembered.
 *
 * This is the screen with the most dwell time in the game by a wide margin.
 * Somebody working through a hard quest is in front of it for an hour, and the
 * two things they will want to change about it are where the brief is and how
 * big the type is. A control that has to be found again every session is a
 * control that gets used once and resented after that, so both are preferences
 * and both survive a reload.
 *
 * The layout key is deliberately *not* the orientation pin on F1. F1 says what
 * shape the whole screen is; this says where the brief goes inside it, and the
 * two are different questions — which is why the button says BRIEF: SIDE and
 * BRIEF: TOP rather than H and V.
 */
const STACK_KEY = "quest.stack";
const FONT_KEY = "quest.font";
const STACKS = ["auto", "row", "column"] as const;
/** Half again down, two and a half times up, in steps somebody can feel. */
const FONT_MIN = 0.7;
const FONT_MAX = 2.4;
const FONT_STEP = 0.15;

/**
 * How long typing has to stop before the edit stack takes a copy.
 *
 * A step on the server's stack should be *a thought*, not a keystroke.
 * CodeMirror's own history is already the per-keystroke one and it is better
 * at that job than anything across a socket could be; this stack is the
 * coarse one that survives a reload and follows the player to the other
 * client, so pushing on every change would fill a hundred-entry stack with
 * half a line of typing and make UNDO useless for the thing it is for.
 */
const PUSH_IDLE_MS = 1500;

/**
 * Expected output with its whitespace made visible. "your answer is right but
 * has a trailing newline" is not a lesson worth teaching (SPEC §5.2), and it
 * is not one a player can even see unless the newline is drawn.
 */
function show(text: string): string {
  return JSON.stringify(text);
}

/**
 * What the editor opens with, in the order that respects the player's work.
 *
 * `local` is the buffer handed back by the verdict screen's TRY AGAIN — the
 * keystrokes of the last few seconds, which nothing on the wire has yet.
 * `quest.draft` (§4.8) is the source of the player's most recent run or submit
 * on this quest, kept by the server since SPEC §2.2 and returned by
 * `quest.get`; it is `null` on a quest nobody has touched and under an
 * interview, and either way the starter is then right.
 *
 * `??` and not `||`, and that is the whole reason this is a function with a
 * test: **an empty draft is a real draft**. A player who selected all, deleted,
 * pressed RUN and came back asked for an empty buffer, and `||` would hand them
 * the starter back and look like the feature silently not working.
 */
export function openingSource(
  local: string | undefined,
  quest: { draft?: string | null; starter: string },
): string {
  return local ?? quest.draft ?? quest.starter;
}

/**
 * Hints still for sale. Clamped, because `quest.solve` (§4.11b) moves
 * `hints_used` to the quest's own hint count and a server that ever moved it
 * past `hints_total` would otherwise print "-1 HINTS LEFT" at the player.
 */
export function hintsRemaining(total: number, used: number): number {
  return Math.max(0, total - used);
}

/**
 * Whether the brief panel has to say "the brief is in English".
 *
 * The server answers `text_locale` (PROTOCOL §4.8): the language the prose
 * actually arrived in, `"en"` when no translation exists for the quest. The
 * note is owed whenever that is not the language the rest of the screen is
 * in — a Korean panel with an English paragraph inside and no explanation
 * reads as a translation somebody abandoned halfway. A server too old to send
 * the field sent English, so an absent value is `"en"`, and an English UI
 * around English prose has nothing to explain.
 */
export function briefNeedsNote(textLocale: string | undefined, uiLocale: string): boolean {
  return (textLocale ?? "en") !== uiLocale;
}

/**
 * What a `quest.solve` reply means for the screen.
 *
 * Two facts and no drawing: the hint counter has moved (the server just set
 * it, and the label on the bench is that number), and the buffer is replaced
 * unless the player is already looking at exactly this text — the same case
 * PASTE calls out, because a button that correctly does nothing is
 * indistinguishable from a broken one.
 */
export function solveOutcome(
  buffer: string,
  res: { source: string; hints_used: number },
): { replace: boolean; hintsUsed: number } {
  return { replace: res.source !== buffer, hintsUsed: res.hints_used };
}

/** Which of UNDO, REDO and CLEAR STACK can be pressed. True means live. */
export interface EditControls {
  undo: boolean;
  redo: boolean;
  clear: boolean;
}

/**
 * The three buttons, from the state the server last sent.
 *
 * `null` is the case this function mostly exists for: it is what a server that
 * does not answer `edit.*` leaves behind, and the answer then is that all
 * three are dim. The screen must keep working against such a server — the
 * stack is an addition to the bench, not a thing the bench depends on — so
 * "no state" and "a state with nothing in it" both come out as "nothing to
 * press" rather than as a fault anybody is told about.
 *
 * `busy` is one call at a time, the same guard `formatting` and `solving`
 * already are: every one of the five messages rewrites the whole state, so two
 * in flight at once would apply in whichever order the replies happened to
 * land.
 */
export function editControls(state: EditState | null, busy: boolean): EditControls {
  if (!state || busy) return { undo: false, redo: false, clear: false };
  // `can_undo`/`can_redo` are the server's own answer and are not re-derived
  // from the cursor here; CLEAR has no flag of its own because there is only
  // one thing to ask — whether there is any history to throw away.
  return { undo: state.can_undo, redo: state.can_redo, clear: state.depth > 0 };
}

/**
 * What the editor should hold after an undo or a redo.
 *
 * `??` and not `||`, for the reason `openingSource` already carries a test
 * for: **an empty entry is a real entry**. A player who selected all, deleted,
 * and let the stack take a copy has an empty string on it, and `||` would hand
 * them the starter back — which reads as UNDO jumping two steps rather than
 * one. `null` is the separate case where the cursor is at the bottom of the
 * stack and there is no entry at all, and *then* the starter is right.
 */
export function editorTextFor(state: EditState, starter: string): string {
  return state.source ?? starter;
}

/**
 * What a failed *run* is called. Deliberately the plain fact of what happened
 * and never a judgement — "ACCEPTED" belongs to the verdict screen and must
 * not appear anywhere a run can reach.
 */
function verdictLine(v: Attempt["verdict"]): string {
  return t(`verdict.${v}` as "verdict.accepted");
}

/**
 * The street this quest happens on, as a painted backdrop.
 *
 * Six briefs, six places. Before this the quest screen had no backdrop at all
 * — the panels sat straight on the WebGL skyline, so Jardine's Bazaar at 06:40,
 * an MTR platform and a seminar room were the same night city. It is the screen
 * with the most dwell time in the game and it had the least sense of place.
 */
const STREET: Record<string, string> = {
  "rust/basic": "bg_street",
  "rust/advanced": "bg_room732",
  "rust/hacker": "bg_datacentre",
  "go/basic": "bg_mtr",
  "go/advanced": "bg_times",
  "go/hacker": "bg_till",
  // The two newer lands borrow plates until they have their own. C++ LAND is
  // the typhoon shelter at noon (the street), the pump room under Victoria
  // Park (the closest thing to machinery is the datacentre) and the third
  // interview in Room 7-32. PYTHON LAND is the wet market (a till is a stall
  // with a price board), the SOGO basement food hall (Times Square is the
  // nearest retail floor we have painted) and the fourth interview, same room.
  "cpp/basic": "bg_street",
  "cpp/advanced": "bg_datacentre",
  "cpp/hacker": "bg_room732",
  "python/basic": "bg_till",
  "python/advanced": "bg_times",
  "python/hacker": "bg_room732",
};

export class QuestScene implements Scene {
  readonly name = "quest";
  readonly mood = "quest" as const;
  private quest: Quest | null = null;
  /** The UI locale the current `quest` was fetched with; see `update`. */
  private askedLocale: Locale | null = null;
  private editor: Editor | null = null;
  private overlay: Overlay | null = null;
  private readonly buttons = new Buttons();
  private stage: Stage = "idle";
  private attemptId: string | null = null;
  /**
   * `run.log` chunks may split mid-line and carry a per-stream `seq`
   * (PROTOCOL §4.18), so the console reads from a buffer that reassembles
   * lines and notices a gap, rather than printing chunks as if they were
   * lines.
   */
  private log = new LogBuffer("");
  private elapsedMs = 0;
  private hints: string[] = [];
  private error = "";
  /**
   * The last `quest.run` (§4.9b), shown in the drawer rather than on the result
   * screen. A run is not a verdict and must never be dressed as one: it says
   * the sample works and nothing about the hidden cases, and taking the player
   * to the ACCEPTED screen for it would teach them that green means done.
   */
  private runResult: Attempt | null = null;
  /** One formatter call at a time. */
  private formatting = false;
  /** And one answer-key call at a time, for the same reason. */
  private solving = false;
  /**
   * The edit stack as the server last described it, or `null` when it has
   * never described it — which is also what a server without `edit.*` leaves
   * here. Nothing about the stack is modelled locally: every reply is the
   * whole state and this field is simply the latest one.
   */
  private edit: EditState | null = null;
  /** One stack call at a time; see `editControls`. */
  private editBusy = false;
  /**
   * Set once the server has said it does not have the edit stack.
   *
   * Without it the idle push would ask a server that answered `not_found` once
   * to answer it again every 1.5 seconds for as long as somebody is typing.
   * One refusal is enough: the three buttons stay dim, nothing is said to the
   * player, and the rest of the bench is untouched.
   */
  private editGone = false;
  /** The pending idle push, so typing again postpones it. */
  private pushTimer: number | null = null;
  /**
   * The source the stack most recently agreed with — what was pushed, or what
   * an undo or a redo just put in the editor. The idle push compares against
   * it so that replacing the buffer from the stack cannot immediately push it
   * straight back.
   */
  private lastPushed: string | null = null;
  /**
   * What the editor was opened with — the draft the server had, or the
   * starter. The baseline `unsaved()` measures against, and it moves every
   * time the server takes a copy (§4.8: a run or a submit is a save).
   */
  private opened = "";
  /** True when `error` is news rather than a fault; it changes the colour. */
  private notice = false;
  private t = 0;
  private consoleOpen = false;
  private logScroll = 0;
  private queued = 0;
  private briefScroll = 0;
  private briefOverflow = 0;
  private briefRect: Rect = [0, 0, 0, 0];
  private readonly briefIn = new Tween(seconds("panel"));
  /** The clock arriving, once, when a timed quest opens. */
  private readonly clockIn = new Tween(seconds("clock"), seconds("stagger") * 2);
  /**
   * Seconds since the last threshold the countdown crossed, and which one it
   * was. Frame-driven: the *value* on the clock comes from the server's
   * deadline, but the reaction to it is animation like everything else.
   */
  private clockSince = 99;
  private clockMark: "none" | "warn" | "urgent" | "out" = "none";
  private readonly benchIn = new Tween(seconds("panel"), seconds("stagger"));
  private readonly offs: Array<() => void> = [];
  /**
   * The toolbar's own button list, separate from the bench's.
   *
   * Two lists rather than one because they are drawn in two different faces —
   * the bench in the button font, the toolbar in the small station font so
   * nine controls fit on one line — and `Buttons.draw` takes one font for the
   * whole list. Both are handed to `controls()`, so the capture hook and an
   * automated run see every control on the screen regardless.
   */
  private readonly bar = new Buttons();
  private stack: Stack = readEnumPref(STACK_KEY, STACKS, "auto");
  private fontMul = readNumberPref(FONT_KEY, 1, FONT_MIN, FONT_MAX);
  /** Where the toolbar was this frame, so the panels start under it. */
  private barH = 0;
  /**
   * The narrow-touch register. On a phone the full toolbar wraps to three
   * rows and the bench's eight buttons, each a finger tall, stack one to a
   * row — and the editor, the thing the screen is for, was left one line
   * tall under them. Decided from a measurement of the toolbar rather than
   * from a device class: a phone held sideways, or a tablet, is not narrow.
   */
  private compactMode = false;
  /**
   * CODE: the editor and nothing else. On a phone the brief, the bench and
   * the toolbar leave the code four lines, and four lines is not a place to
   * write a program. In this mode the editor has the screen and one button —
   * BACK, top right — puts the furniture back. ESC does the same. Nothing
   * is run or submitted from here: this is for writing, and the bench is
   * one tap away.
   */
  private focus = false;
  /**
   * ANSWER mode: the reference solution behind what the player types.
   *
   * It is the same answer SOLVE fetches and it is priced the same way
   * (§4.11b — a star), because it is the same knowledge. What is different
   * is what happens to it: SOLVE *replaces* the buffer and the session is
   * over; ANSWER puts it behind the caret as a target and the player types
   * every character themselves. That is the difference between being told
   * and remembering, and remembering is what this game is for.
   */
  private answerText: string | null = null;
  private answerOn = false;
  private answerBusy = false;
  private answerProg: AnswerProgress = { matched: 0, wrong: 0, done: false, total: 0 };
  /**
   * Effects thrown at the caret — on their own layer *over* the editor.
   *
   * Both game canvases are under `#overlay` and the editor's face is all but
   * opaque, so a burst painted on the game canvas would land behind the code
   * and be seen by nobody. See `ui/sparks.ts`.
   */
  private sparks: Sparks | null = null;

  constructor(
    private readonly app: App,
    readonly land: Land,
    readonly category: Category,
    readonly questId: string,
    /**
     * What the player had in the editor last time, if they are coming back
     * from a verdict. TRY AGAIN used to reload the starter, which threw away
     * the attempt they had just made — the one thing on this screen that is
     * theirs. Undefined means a first visit, and then the starter is right.
     */
    private readonly draft?: string,
  ) {}

  async enter(): Promise<void> {
    // §1.3. `quest.get` below tells the server the same thing; this keeps the
    // lobby and the map in step for the rest of this window.
    this.app.land = this.land;
    this.app.category = this.category;
    this.app.questId = this.questId;
    this.offs.push(
      // §4.17–4.18: both may arrive at any time, including after the reply
      // they relate to. Filtering on `attempt_id` is what keeps a stale event
      // from a previous run out of this one's console.
      this.app.client.on("run.stage", (p) => {
        if (this.attemptId && p.attempt_id !== this.attemptId) return;
        this.attemptId = p.attempt_id;
        this.stage = p.stage;
        this.elapsedMs = p.elapsed_ms;
        this.queued = p.queued ?? 0;
        this.consoleOpen = true;
      }),
      this.app.client.on("run.log", (p) => {
        if (this.attemptId && p.attempt_id !== this.attemptId) return;
        if (!this.attemptId) {
          this.attemptId = p.attempt_id;
          this.log = new LogBuffer(p.attempt_id);
        }
        this.log.push(p.stream, p.chunk, p.seq);
      }),
    );

    try {
      // §4.8: the prose comes back in the UI language when the server has a
      // translation pack for it, and `text_locale` says which it got.
      this.askedLocale = locale();
      const res = await this.app.client.request("quest.get", {
        quest_id: this.questId,
        locale: this.askedLocale,
      });
      this.quest = res.quest;
      // §4.8. The editor opens on the player's own most recent run or submit,
      // fetched from the server with the quest itself — no local storage, no
      // save button, nothing new sent. A player who typed for ten minutes and
      // closed the tab finds what they left, on any machine they log in from.
      this.opened = openingSource(this.draft, res.quest);
      this.lastPushed = this.opened;
      // The source is read on submit and there is nothing to save locally —
      // but a change is the one moment the edit stack cares about, so it
      // starts the idle timer that eventually takes a copy.
      this.editor = new Editor(this.land, this.opened, () => this.touched());
      this.overlay = new Overlay(this.app.overlay, this.app.layout, this.editor.dom);
      // After the editor, so it is painted over it. It is empty until ANSWER
      // is on and something happens worth looking at.
      this.sparks = new Sparks(this.app.overlay, this.app.layout);
      queueMicrotask(() => this.editor?.focus());
      // Deliberately *not* inside this try. The stack is an addition to the
      // bench and a server without it must not make the quest itself look
      // broken: a failure here has to land somewhere that says nothing, not in
      // the catch below that puts "could not open the quest" on the screen.
      void this.loadEditState();
    } catch (e) {
      if (e instanceof WireError) {
        console.warn("quest.get failed:", e.payload.code, e.payload.message, e.payload.detail);
        this.error = playerText(e.payload.code);
      } else {
        this.error = t("quest.openFailed");
      }
    }
  }

  leave(): void {
    for (const off of this.offs) off();
    this.offs.length = 0;
    this.cancelPush();
    this.overlay?.destroy();
    this.sparks?.destroy();
    this.editor?.destroy();
    this.editor = null;
    this.overlay = null;
    this.sparks = null;
  }

  // -- actions -------------------------------------------------------------

  /**
   * Whether walking away throws work away. Compared against what the editor
   * was opened with rather than tracked with a dirty flag, because typing
   * something and then undoing it is not unsaved work, and being asked about
   * it would teach the player to dismiss the question without reading it.
   *
   * The baseline is `opened`, not the starter, and that is §4.8 landing here:
   * once the editor opens on the server's draft, "different from the starter"
   * is true on the first frame, and a returning player would be warned that
   * leaving throws away code the server is holding for them. It moves to the
   * buffer that was sent on every successful run and submit, because that is
   * the moment the server took its copy.
   */
  unsaved(): boolean {
    if (!this.editor) return false;
    return this.editor.source.trim() !== this.opened.trim();
  }

  private submit(): Promise<void> {
    return this.execute("quest.submit");
  }

  private run(): Promise<void> {
    return this.execute("quest.run");
  }

  /**
   * One path for both (§4.9b says the payloads are the same shape on purpose).
   *
   * The only difference is what is done with the reply: a submit goes to the
   * verdict screen, a run stays here and reports into the drawer. Both share
   * the one-execution-per-connection rule, which is why `stage !== "idle"`
   * guards the pair of them rather than one button each.
   */
  private async execute(kind: "quest.submit" | "quest.run"): Promise<void> {
    if (!this.quest || !this.editor || this.stage !== "idle") return;
    this.attemptId = null;
    this.log = new LogBuffer("");
    this.stage = "queued";
    this.consoleOpen = true;
    this.error = "";
    this.notice = false;
    this.runResult = null;
    const sent = this.editor.source;
    try {
      const res = await this.app.client.request(kind, {
        quest_id: this.quest.id,
        source: sent,
        lang: this.land,
      });
      this.stage = "idle";
      this.log.end();
      // §4.8: the server has just stored this source as the quest's draft, as
      // a side effect of judging it. Nothing is sent to say so — this line is
      // only the screen agreeing with the server about what is now saved, so
      // walking away afterwards asks no question it does not need to ask.
      this.opened = sent;
      // A run and a submit are the two moments the draft is already saved, so
      // they are the two moments the stack should have an entry — a player who
      // ran something that worked wants to be able to get back to it. Fired
      // and forgotten on purpose: `pushEdit` swallows its own failures, and a
      // rejection allowed to reach the catch below would report a successful
      // run as a failed one.
      void this.pushEdit(sent);
      if (kind === "quest.run") {
        this.runResult = res.attempt;
        this.logScroll = 0;
        // A chime, not a fanfare. The fanfare belongs to CLEARED.
        if (this.samplePassed(res.attempt)) this.app.chip.coin();
        else this.app.chip.fail();
        return;
      }
      this.showResult(res.attempt);
    } catch (e) {
      this.stage = "idle";
      this.log.end();
      this.app.chip.fail();
      // §6.6: a submission that was in flight when the socket dropped is still
      // running, and its result is durable. Telling the player to resubmit
      // would queue a second compile for an answer the server already has.
      const dropped = e instanceof WireError && e.payload.detail.disconnected === true;
      if (e instanceof WireError) {
        console.warn("submit failed:", e.payload.code, e.payload.message, e.payload.detail);
      }
      // §3.3 again: our words on screen, the server's in the console.
      const goGap = this.land === "go" && e instanceof WireError && e.payload.code === "internal";
      this.notice = goGap;
      // A server that has not caught up with §4.9b answers an unknown request
      // type with `not_found`, and "that is not there any more" sends the
      // player looking for a missing quest. Name the actual situation.
      const noRun =
        kind === "quest.run" && e instanceof WireError && e.payload.code === "not_found";
      this.notice = this.notice || noRun;
      this.error = noRun
        ? t("quest.noRun")
        : dropped
          ? t("quest.dropped")
          : goGap
            ? // The Go runner arrives in the next milestone. Reporting that as a
              // server fault teaches the player to distrust a working server.
              t("quest.goGap")
            : e instanceof WireError
              ? playerText(e.payload.code)
              : t("quest.runFailed");
    }
  }

  /** Every visible case the run actually executed came back passing. */
  private samplePassed(a: Attempt): boolean {
    return a.verdict === "accepted" && a.tests_passed === a.tests_total;
  }

  private showResult(attempt: Attempt): void {
    // `cleared` is "did *this* submission clear it" (§5.4); a re-solve is
    // still accepted and still deserves the sound, just not the fanfare.
    if (attempt.verdict === "accepted") this.app.chip.clear();
    else this.app.chip.fail();
    void this.app.go(
      new ResultScene(
        this.app,
        this.land,
        this.category,
        this.questId,
        attempt,
        this.editor?.source,
      ),
    );
  }

  /**
   * §4.9d: run the language's own formatter over the buffer.
   *
   * Three outcomes and three registers. Formatted: the buffer changes and the
   * caret stays where it was. Already tidy: it says so and touches nothing,
   * because replacing a buffer with an identical one makes a button feel
   * broken. Does not parse: the formatter's one-line complaint, shown *quietly*
   * — half-written code is the normal state of an editor, not a fault — and the
   * buffer is left exactly as it is.
   */
  private async format(): Promise<void> {
    if (!this.quest || !this.editor || this.formatting) return;
    this.formatting = true;
    try {
      const res = await this.app.client.request("code.format", {
        lang: this.land,
        source: this.editor.source,
      });
      if (res.problem) {
        this.error = res.problem;
        this.notice = true;
      } else if (res.changed) {
        this.editor.replaceAll(res.source);
        this.error = "";
        this.app.chip.blip();
      } else {
        this.error = t("quest.alreadyTidy");
        this.notice = true;
      }
    } catch (e) {
      this.error =
        e instanceof WireError && e.payload.code === "not_found"
          ? t("quest.noFormat")
          : e instanceof WireError
            ? playerText(e.payload.code)
            : t("quest.formatSilent");
      this.notice = true;
    } finally {
      this.formatting = false;
    }
  }

  /**
   * Re-request the quest for its prose alone, after a language change. The
   * guard is set before the await so a second frame does not ask again while
   * the first answer is in flight.
   */
  private async refetchText(): Promise<void> {
    if (!this.quest) return;
    const asked = locale();
    this.askedLocale = asked;
    try {
      const res = await this.app.client.request("quest.get", {
        quest_id: this.quest.id,
        locale: asked,
      });
      if (!this.quest || this.quest.id !== res.quest.id) return;
      this.quest.title = res.quest.title;
      this.quest.story = res.quest.story;
      this.quest.brief = res.quest.brief;
      this.quest.text_locale = res.quest.text_locale;
      // Hints already bought stay in the language they were bought in; the
      // next one is asked for in the new language.
    } catch {
      // The old prose is still on screen and still true; nothing to say.
    }
  }

  private async hint(): Promise<void> {
    if (!this.quest) return;
    if (this.quest.hints_used >= this.quest.hints_total) return;
    try {
      const res = await this.app.client.request("quest.hint", {
        quest_id: this.quest.id,
        index: this.quest.hints_used,
        locale: locale(),
      });
      this.hints.push(res.hint);
      if (this.quest) this.quest.hints_used = res.hints_used;
      this.app.chip.coin();
    } catch {
      this.app.say(t("quest.noMoreHints"));
    }
  }

  /**
   * §4.11b: the whole answer, in the editor, now.
   *
   * Priced as the largest hint there is — the server sets `hints_used` to the
   * quest's own hint count, and SPEC §6.3's cascade only ever asks whether any
   * hint was used, so a submission of the revealed answer can clear the quest
   * and can never clear it at three stars. That is the honest price and the
   * line beside the button says it before it is paid.
   *
   * **Asking records nothing.** No attempt, no history row, no mistake — the
   * player has read an answer, not run one. Only a SUBMIT afterwards writes
   * anything, and it writes what actually happened.
   *
   * Destructive to the buffer and deliberately not behind a dialogue, for the
   * same reason PASTE is not: `replaceAll` narrows the change and dispatches
   * one edit, so CodeMirror undoes the whole thing in a single CTRL+Z, and the
   * `focus()` afterwards is what makes that promise true — CodeMirror only
   * hears the keystroke when it has the focus, and pressing a canvas button
   * leaves the focus on the page.
   */
  private async solve(): Promise<void> {
    if (!this.quest || !this.editor || this.solving) return;
    this.solving = true;
    try {
      const res = await this.app.client.request("quest.solve", { quest_id: this.quest.id });
      const out = solveOutcome(this.editor.source, res);
      // The one number this call changed, on the one control that displays it.
      this.quest.hints_used = out.hintsUsed;
      if (!out.replace) {
        this.error = t("quest.solveSame");
        this.notice = true;
        return;
      }
      this.editor.replaceAll(res.source);
      this.editor.focus();
      this.error = t("quest.solved");
      this.notice = true;
      this.app.chip.coin();
    } catch (e) {
      const code = e instanceof WireError ? e.payload.code : null;
      // `not_found` is two situations with one code and an empty `detail`: an
      // interview session, where §4.11b withholds the answer on purpose, and a
      // server too old to have the message at all. They are indistinguishable
      // on the wire, so the line says the thing that is true of both rather
      // than guessing — and it is news, not a fault, so it is not painted red.
      this.error =
        code === "not_found"
          ? t("quest.noSolve")
          : code
            ? playerText(code)
            : t("quest.solveSilent");
      this.notice = code === "not_found";
      this.app.chip.fail();
    } finally {
      this.solving = false;
    }
  }

  /**
   * ANSWER on, ANSWER off. The first press pays for the answer; every press
   * after it is free, because the star is spent on knowing, not on looking.
   */
  private async toggleAnswer(): Promise<void> {
    if (!this.quest || !this.editor || this.answerBusy) return;
    if (this.answerOn) {
      this.answerOn = false;
      this.editor.setAnswer(null);
      this.app.chip.select();
      return;
    }
    if (this.answerText === null) {
      this.answerBusy = true;
      try {
        const res = await this.app.client.request("quest.solve", { quest_id: this.quest.id });
        this.quest.hints_used = res.hints_used;
        this.answerText = res.source;
      } catch (e) {
        // The same two situations `solve` distinguishes, said the same way:
        // an interview withholds the answer on purpose, and an older server
        // does not have it at all, and the wire cannot tell them apart.
        const code = e instanceof WireError ? e.payload.code : null;
        this.error =
          code === "not_found"
            ? t("quest.noSolve")
            : code
              ? playerText(code)
              : t("quest.solveSilent");
        this.notice = code === "not_found";
        this.app.chip.fail();
        return;
      } finally {
        this.answerBusy = false;
      }
    }
    this.answerOn = true;
    this.editor.setAnswer(this.answerText);
    this.answerProg = answerProgress(this.editor.source, this.answerText);
    this.editor.focus();
    this.app.chip.coin();
  }

  /**
   * What the last keystroke did to the target, as something to look at.
   *
   * Three moments, and only the *moments* — a burst on every keystroke while
   * a line is wrong would be noise, and noise is what a player stops seeing.
   * The divergence fires once, when it opens; a line fires when it closes;
   * and the whole answer fires once, at the end.
   */
  private answerTick(): void {
    if (!this.answerOn || this.answerText === null || !this.editor) return;
    const was = this.answerProg;
    const now = answerProgress(this.editor.source, this.answerText);
    this.answerProg = now;
    const at = this.caretVirtual();
    if (!at) return;
    if (now.done && !was.done) {
      // Every character, typed. The one big one.
      this.spark(at, 70, Theme.admit);
      this.app.chip.coin();
      return;
    }
    if (now.wrong > was.wrong || now.matched < was.matched) {
      // **The divergence *growing*, not merely existing.** A quest opens with
      // `// your code here` in the buffer, which is already not the answer —
      // so "wrong where it was right before" would never fire on the very
      // screen it is for. Each keystroke that takes you further from the
      // target gets its own small burst, at the caret, where the fix is.
      this.spark(at, 10, Theme.red);
      this.app.chip.fail();
      return;
    }
    if (was.wrong > 0 && now.wrong === 0) {
      // Back on the target. Worth as much as finishing a line, and the
      // moment a player most wants told.
      this.spark(at, 20, Theme.cyan);
      this.app.chip.blip();
      return;
    }
    if (now.matched > was.matched && this.answerText.slice(was.matched, now.matched).includes("\n")) {
      this.spark(at, 16, Theme.coin);
      this.app.chip.blip();
    }
  }

  private caretVirtual(): [number, number] | null {
    const c = this.editor?.caretClient();
    if (!c) return null;
    return this.app.layout.toVirtual(c[0], c[1]);
  }

  /** One burst, in one colour, at a point. */
  private spark(at: [number, number], n: number, colour: RGBA): void {
    const plan = burstPlan(at[0], at[1], n);
    for (const p of plan.particles) p.color = colour;
    for (const r of plan.rings) r.color = colour;
    this.sparks?.add(plan, this.t);
  }

  private async reset(): Promise<void> {
    if (!this.quest || !this.editor) return;
    try {
      const res = await this.app.client.request("quest.reset", { quest_id: this.quest.id });
      this.editor.load(this.land, res.starter);
      this.opened = res.starter;
    } catch {
      this.editor.load(this.land, this.quest.starter);
      this.opened = this.quest.starter;
    }
  }

  // -- the edit stack -------------------------------------------------------

  /**
   * Ask what the stack looks like, when the screen opens — and open on it.
   *
   * **The stack wins over the draft** (PROTOCOL §4.11c). `draft` is a read of
   * the last *attempt*, so it moves only when the player runs or submits,
   * while the stack also moves on the idle push and on undo and redo. A player
   * who typed for a minute and closed the tab without running has their
   * typing on the stack and not in the draft: opening on the draft would show
   * them an older text and read as work lost, which is the exact failure
   * persisting the stack exists to prevent.
   *
   * Only when the buffer is **untouched** since it opened, though. The reply
   * is a round trip away and the player may already be typing into it, and
   * nothing here is worth overwriting a live keystroke for.
   */
  private async loadEditState(): Promise<void> {
    if (!this.quest || this.editGone) return;
    try {
      const res = await this.app.client.request("edit.state", { quest_id: this.quest.id });
      // The scene may have been left while this was in flight.
      if (!this.editor) return;
      this.edit = res;
      const next = editorTextFor(res, this.quest.starter);
      if (res.depth > 0 && !this.unsaved() && next !== this.editor.source) {
        this.editor.replaceAll(next);
        this.opened = next;
        this.lastPushed = next;
      }
    } catch (e) {
      this.editFailed(e, "edit.state");
    }
  }

  /**
   * A step back or forward through the stack, into the editor.
   *
   * The gate is checked here as well as on the button because the keyboard
   * reaches this without going past a button at all, and an undo at the bottom
   * of the stack should be silence rather than a refusal on the message bar.
   */
  private async editStep(kind: "edit.undo" | "edit.redo"): Promise<void> {
    if (!this.quest || !this.editor || this.editGone) return;
    const live = editControls(this.edit, this.editBusy);
    if (!(kind === "edit.undo" ? live.undo : live.redo)) return;
    this.editBusy = true;
    try {
      const res = await this.app.client.request(kind, { quest_id: this.quest.id });
      this.applyEdit(res);
      this.app.chip.blip();
    } catch (e) {
      this.editFailed(e, kind);
    } finally {
      this.editBusy = false;
    }
  }

  /** The state the server just sent, and the text that goes with it. */
  private applyEdit(state: EditState): void {
    this.edit = state;
    if (!this.editor || !this.quest) return;
    const next = editorTextFor(state, this.quest.starter);
    // Both of these before the buffer changes, not after: `replaceAll`
    // dispatches an edit, the edit calls `touched`, and an idle push of the
    // text the stack just handed us would be a pointless round trip.
    this.lastPushed = next;
    this.cancelPush();
    this.editor.replaceAll(next);
    // The caret goes back into the editor for the same reason PASTE hands it
    // over: the player pressed a canvas button and the next thing they want to
    // do is type.
    this.editor.focus();
  }

  /**
   * Throw the history away, having asked first.
   *
   * The only control on this bench that is behind a dialogue, and the
   * asymmetry is deliberate. PASTE and SOLVE replace the buffer and are not
   * behind one, because CTRL+Z puts the buffer back and a dialogue nobody
   * needs is a dialogue everybody learns to click through. This throws away
   * the thing that would have put it back, on the server, for good — there is
   * nothing left to undo it with.
   */
  private async clearStack(): Promise<void> {
    if (!this.quest || this.editGone) return;
    if (!editControls(this.edit, this.editBusy).clear) return;
    const ok = await this.app.ask({
      title: t("quest.clearStack"),
      body: t("quest.clearStackAsk"),
      confirm: t("quest.clearStack"),
      cancel: t("quest.keepWriting"),
    });
    if (!ok || !this.quest) return;
    this.editBusy = true;
    try {
      // The state is taken, the buffer is not: clearing the history is not an
      // edit, and the player keeps whatever they are looking at.
      this.edit = await this.app.client.request("edit.clear", { quest_id: this.quest.id });
    } catch (e) {
      this.editFailed(e, "edit.clear");
    } finally {
      this.editBusy = false;
    }
  }

  /**
   * Typing happened. Postpone the copy rather than take one.
   *
   * See `PUSH_IDLE_MS`: the stack step is meant to be a thought, so the timer
   * restarts on every keystroke and only the pause at the end of one gets an
   * entry.
   */
  private touched(): void {
    this.answerTick();
    if (this.editGone) return;
    this.cancelPush();
    this.pushTimer = window.setTimeout(() => {
      this.pushTimer = null;
      if (!this.editor) return;
      // A pause that lands while some other `edit.*` is still in flight waits
      // rather than being dropped: `pushEdit` refuses when the stack is busy,
      // and a silently lost entry is exactly the sort of gap that makes an
      // undo history untrustworthy.
      if (this.editBusy) return this.touched();
      void this.pushEdit(this.editor.source);
    }, PUSH_IDLE_MS);
  }

  private cancelPush(): void {
    if (this.pushTimer === null) return;
    clearTimeout(this.pushTimer);
    this.pushTimer = null;
  }

  /**
   * Put one entry on the stack, quietly.
   *
   * Never throws and never says anything: this runs off a timer while
   * somebody is typing, and a message bar that filled with "the stack did not
   * answer" every second and a half would be worse than having no stack at
   * all. `lastPushed` is set before the request rather than after so that a
   * slow reply cannot let a second, identical push through behind it.
   */
  private async pushEdit(source: string): Promise<void> {
    if (!this.quest || !this.editor || this.editGone || this.editBusy) return;
    if (source === this.lastPushed) return;
    this.lastPushed = source;
    this.editBusy = true;
    try {
      const res = await this.app.client.request("edit.push", {
        quest_id: this.quest.id,
        source,
      });
      if (this.editor) this.edit = res;
    } catch (e) {
      this.editFailed(e, "edit.push");
    } finally {
      this.editBusy = false;
    }
  }

  /**
   * What a refused `edit.*` means, which is deliberately nothing on screen.
   *
   * `not_found` and `bad_request` from this family are one situation in
   * practice — a server that has not shipped the messages at all, which
   * answers an unknown type with one or the other — and the honest response is
   * to stop asking and leave the three buttons dim for the rest of the visit.
   * Anything else — a dropped socket, a busy server — is a server that *has*
   * them and is having a moment, so the state stands and the next press or the
   * next pause tries again.
   *
   * `edit.push` is the one exception, and `from` is here for it alone: it is
   * the only one of the five that carries anything but a quest id, so a
   * `bad_request` from it is the 256 KiB cap refusing one oversized source and
   * says nothing at all about whether the server has the stack. Taking the
   * feature away over that would dim UNDO and REDO over entries that exist and
   * step perfectly well.
   */
  private editFailed(
    e: unknown,
    from: "edit.state" | "edit.push" | "edit.undo" | "edit.redo" | "edit.clear",
  ): void {
    if (e instanceof WireError) {
      console.warn("edit stack:", from, e.payload.code, e.payload.message, e.payload.detail);
    }
    const absent =
      e instanceof WireError &&
      (e.payload.code === "not_found" ||
        (e.payload.code === "bad_request" && from !== "edit.push") ||
        e.payload.code === "unavailable" ||
        e.payload.code === "proto_version");
    if (!absent) return;
    this.editGone = true;
    this.edit = null;
    this.cancelPush();
  }

  // -- leaving, and the one question worth asking ---------------------------

  /**
   * Walk away, having asked first if that throws work away.
   *
   * `App.logout` has asked this question since the beginning and the two ways
   * *off this screen* did not, which meant F3 was more careful with a player's
   * code than the MAP button next to it. The check is `unsaved()` — the buffer
   * against the starter, not a dirty flag — so typing something and undoing it
   * back to the starter does not produce a question, and a question nobody
   * needs is a question everybody learns to click through.
   */
  private async leaveTo(where: "map" | "lobby"): Promise<void> {
    if (this.unsaved()) {
      const ok = await this.app.ask({
        title: where === "map" ? t("quest.leaveMapTitle") : t("quest.leaveLobbyTitle"),
        body: t("quest.leaveBody"),
        confirm: t("quest.leave"),
        cancel: t("quest.keepWriting"),
      });
      if (!ok) return;
    }
    await this.app.go(
      where === "map" ? new MapScene(this.app, this.land, this.category) : new LandsScene(this.app),
      "back",
    );
  }

  // -- the clipboard --------------------------------------------------------

  /**
   * The brief as text somebody can paste into a notebook.
   *
   * Canvas text is pixels: there is nothing on this screen to select with a
   * mouse, so this button is not a convenience, it is the only way the words
   * leave the screen at all. It is assembled rather than taken from one field
   * because the brief a player sees is four things — the job, the samples, the
   * hints they have paid for and the story line — and a copy that dropped the
   * sample output would drop the one fact SPEC §5.2 exists to guarantee.
   *
   * The hidden cases are named and never shown, here as everywhere else.
   */
  private briefText(): string {
    const q = this.quest;
    if (!q) return "";
    const out: string[] = [`${String(q.node).padStart(2, "0")}  ${q.title}`, "", q.brief.trim()];
    for (const c of q.tests.visible) {
      out.push("", t("quest.sample", { name: c.name }));
      if (c.stdin) out.push(`  ${t("quest.in")}   ${show(c.stdin)}`);
      out.push(`  ${t("quest.out")}  ${show(c.expect)}`);
    }
    if (q.tests.hidden_count > 0) {
      out.push("", tn("quest.hiddenCount", q.tests.hidden_count));
    }
    for (const h of this.hints) out.push("", t("quest.hint", { text: h }));
    if (q.story) out.push("", `“${q.story}”`);
    return out.join("\n") + "\n";
  }

  /** Everything in the console drawer, including the run report above it. */
  private consoleText(): string {
    const out: string[] = [];
    const a = this.runResult;
    if (a) {
      const ok = this.samplePassed(a);
      out.push(
        t("run.head", {
          what: ok
            ? t("verdict.accepted")
            : a.verdict === "accepted"
              ? t("verdict.wrong_answer")
              : verdictLine(a.verdict),
        }),
        t("run.counts", { passed: a.tests_passed, total: a.tests_total, notRun: "" }),
      );
      for (const c of a.cases) {
        if (c.visible && !c.passed) {
          out.push(`${c.name}: expected ${show(c.expect ?? "")} got ${show(c.got ?? "")}`);
        }
      }
      out.push("");
    }
    for (const line of this.log.lines) out.push(line.text);
    if (!this.log.complete)
      out.push(t("quest.lostOutput", { gaps: [...this.log.gaps].join(", ") }));
    return out.join("\n").trim();
  }

  /** Put a clipboard verdict on the message bar. Always says something. */
  private report(what: string, res: Awaited<ReturnType<typeof copyText>>, verb: "copy" | "paste") {
    const m = clipMessage(what, res, verb);
    this.error = m.text;
    this.notice = m.notice;
    if (res.ok) this.app.chip.blip();
    else this.app.chip.fail();
  }

  private async copy(what: "brief" | "code" | "output"): Promise<void> {
    const text =
      what === "brief"
        ? this.briefText()
        : what === "code"
          ? (this.editor?.source ?? "")
          : this.consoleText();
    const name =
      what === "brief"
        ? t("clip.theBrief")
        : what === "code"
          ? t("clip.yourCode")
          : t("clip.theOutput");
    this.report(name, await copyText(text), "copy");
  }

  /**
   * Replace the buffer with whatever is on the clipboard.
   *
   * Destructive, and deliberately **not** behind a confirmation. A dialogue in
   * front of a paste is a dialogue somebody dismisses without reading by the
   * third time, and it protects nothing that Ctrl+Z does not protect better.
   * `Editor.replaceAll` narrows the change to the span that differs and
   * dispatches it as one edit, so CodeMirror's history undoes the whole paste
   * in a single step — which is what the message on screen says it will.
   *
   * The case where the clipboard already matches the buffer is called out
   * rather than left silent: `narrowEdit` correctly does nothing, and a button
   * that correctly does nothing is indistinguishable from a broken one.
   */
  private async paste(): Promise<void> {
    if (!this.editor) return;
    const res = await readText();
    if (!res.ok) return this.report(t("clip.yourCode"), res, "paste");
    if (res.text === this.editor.source) {
      this.error = t("clip.sameAlready");
      this.notice = true;
      return;
    }
    this.editor.replaceAll(res.text);
    // The caret goes into the editor, and that is load-bearing rather than
    // polite: the message says CTRL+Z puts it back, and CodeMirror's history
    // only hears a keystroke when CodeMirror has the focus. Pressing a canvas
    // button leaves the focus on the page, so a paste that did not hand it
    // over would make the screen's own promise false.
    this.editor.focus();
    this.report(t("clip.yourCode"), res, "paste");
  }

  // -- how the screen is set up ---------------------------------------------

  /** Brief beside the bench, or above it. Remembered. */
  private cycleStack(): void {
    // Two states, not three. `auto` is where a player starts and it is a fine
    // place to stay, but somebody who has pressed this button has told us they
    // want to decide, and offering them "let the window decide again" as one
    // of three presses is a control that is wrong two times in three.
    const side = this.stack === "auto" ? !this.app.layout.isPortrait() : this.stack === "row";
    this.stack = side ? "column" : "row";
    writePref(STACK_KEY, this.stack);
  }

  /** True when the brief is beside the bench rather than above it. */
  private get side(): boolean {
    return this.stack === "auto" ? !this.app.layout.isPortrait() : this.stack === "row";
  }

  private sizeFont(by: number): void {
    const next = Math.min(
      FONT_MAX,
      Math.max(FONT_MIN, Math.round((this.fontMul + by) * 100) / 100),
    );
    if (next === this.fontMul) return;
    this.fontMul = next;
    writePref(FONT_KEY, String(next));
    this.error = t("quest.fontSize", { percent: Math.round(next * 100) });
    this.notice = true;
  }

  // -- input ---------------------------------------------------------------

  key(name: string, ev: KeyboardEvent): void {
    // The console is where a compiler error lives, and a compiler error is
    // routinely taller than the drawer. Wheel-only scrollback means anyone on
    // a keyboard cannot read the top of their own error.
    if (this.consoleOpen) {
      const page = 8;
      if (name === "pageup") return void (this.logScroll += page);
      if (name === "pagedown") return void (this.logScroll = Math.max(0, this.logScroll - page));
      if (name === "home") return void (this.logScroll = 9999);
      if (name === "end") return void (this.logScroll = 0);
    }
    if (name === "escape") {
      if (this.focus) {
        this.focus = false;
        return;
      }
      void this.leaveTo("map");
      return;
    }
    if ((name === "return" || name === "kpenter") && (ev.metaKey || ev.ctrlKey)) {
      ev.preventDefault();
      // The reflex key is RUN. Submitting is the same key plus SHIFT — an
      // escalation of the one the hands already know, not a second shortcut to
      // learn, and deliberately not something a thumb finds by accident.
      //
      // It has a binding at all because a primary action reachable only with a
      // mouse is an accessibility gap. FORMAT has one; so should the button
      // that decides whether a street is cleared.
      if (ev.shiftKey) void this.submit();
      else void this.run();
    }
    // The binding people already have in their fingers, as close as this
    // plumbing allows: a keystroke only reaches a scene from inside the editor
    // when Ctrl or Cmd is held, so Shift+Alt+F could never arrive here.
    if (name === "f" && (ev.metaKey || ev.ctrlKey) && ev.shiftKey) {
      ev.preventDefault();
      void this.format();
    }
    // Two undo histories, on one keystroke, and which one answers is decided
    // by where the caret is.
    //
    // **Inside CodeMirror it is CodeMirror's**, untouched. That history is per
    // keystroke and it is the one a person means while they are typing — a
    // mistyped bracket is not a step on the server's stack and never should
    // be. An accelerator reaches a scene even while the editor has the focus
    // (that is how CTRL+ENTER works mid-thought), so this has to check rather
    // than assume, and it deliberately does not `preventDefault` on that path.
    //
    // **Outside it, it is the server's**: the coarse stack, a thought per
    // entry, the one that survives a reload and follows the player to the
    // other client — the same thing the UNDO and REDO buttons drive.
    if (name === "z" && (ev.metaKey || ev.ctrlKey) && !this.editor?.focused) {
      ev.preventDefault();
      void this.editStep(ev.shiftKey ? "edit.redo" : "edit.undo");
    }
  }

  controls(): Buttons[] {
    return [this.buttons, this.bar];
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    if (phase === "move") {
      this.buttons.hovered = this.buttons.hit(x, y)?.id ?? null;
      this.bar.hovered = this.bar.hit(x, y)?.id ?? null;
      return;
    }
    if (phase !== "down") return;
    const hit = this.buttons.hit(x, y) ?? this.bar.hit(x, y);
    if (!hit) return;
    this.app.chip.select();
    switch (hit.id) {
      case "focus":
        this.focus = true;
        break;
      case "unfocus":
        this.focus = false;
        break;
      case "answer":
        void this.toggleAnswer();
        break;
      case "run":
        void this.run();
        break;
      case "submit":
        void this.submit();
        break;
      case "hint":
        void this.hint();
        break;
      case "solve":
        void this.solve();
        break;
      case "reset":
        void this.reset();
        break;
      case "undo":
        void this.editStep("edit.undo");
        break;
      case "redo":
        void this.editStep("edit.redo");
        break;
      case "clearstack":
        void this.clearStack();
        break;
      case "console":
        this.consoleOpen = !this.consoleOpen;
        break;
      // The two ways off this screen. They live in the toolbar, hard against
      // the top of the window and a whole panel away from SUBMIT, because a
      // control that leaves the screen must not be reachable by a hand that
      // was aiming at the one that spends an attempt.
      case "back":
        void this.leaveTo("map");
        break;
      case "lobby":
        void this.leaveTo("lobby");
        break;
      case "copybrief":
        void this.copy("brief");
        break;
      case "copycode":
        void this.copy("code");
        break;
      case "copyout":
        void this.copy("output");
        break;
      case "paste":
        void this.paste();
        break;
      case "stack":
        this.cycleStack();
        break;
      case "fontdown":
        this.sizeFont(-FONT_STEP);
        break;
      case "fontup":
        this.sizeFont(FONT_STEP);
        break;
    }
  }

  update(dt: number): void {
    this.t += dt;
    if (this.quest && this.askedLocale !== null && this.askedLocale !== locale()) {
      // F7 changed the language under an open quest. The interface re-reads
      // its own strings for free; the prose came from the server in the old
      // language and has to be asked for again. Only the prose is swapped —
      // the editor, the clock and the run log are the player's and stay.
      void this.refetchText();
    }
    this.briefIn.update(dt);
    this.clockIn.update(dt);
    this.clockSince += dt;
    const left = this.secondsLeft();
    if (left !== null) {
      // One beat per line crossed, and never again for that line. The clock is
      // calm the rest of the time on purpose — somebody is reading code on
      // this screen.
      const mark =
        left <= 0 ? "out" : left <= CLOCK.urgent ? "urgent" : left <= CLOCK.warn ? "warn" : "none";
      if (mark !== this.clockMark) {
        this.clockMark = mark;
        if (mark !== "none") {
          this.clockSince = 0;
          if (mark === "out") this.app.chip.fail();
          else this.app.chip.blip();
        }
      }
    }
    this.benchIn.update(dt);
    // Clamped here rather than in the wheel handler: the overflow is only
    // known after a frame has measured the text at the current width, and the
    // width changes with the orientation.
    this.briefScroll = Math.max(0, Math.min(this.briefScroll, this.briefOverflow));
  }

  wheel(dy: number, x: number, y: number): void {
    if (inRect(x, y, this.briefRect)) {
      this.briefScroll = Math.max(0, Math.min(this.briefOverflow, this.briefScroll + dy));
    } else if (this.consoleOpen) {
      // The console scrolls backwards: positive is "further into the past".
      this.logScroll = Math.max(0, this.logScroll - Math.round(dy / 8));
    }
  }

  // -- drawing -------------------------------------------------------------

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    const accent = landColour(this.land);
    const street = this.app.assets?.picture(
      STREET[`${this.land}/${this.category}`] ?? "bg_street",
      layout.isPortrait(),
    );
    if (street) {
      // Cover, then a scrim: the place has to be legible behind the panels
      // without competing with the code in front of them.
      const scale = Math.max(layout.vw / street.naturalWidth, layout.vh / street.naturalHeight);
      const aw = street.naturalWidth * scale;
      const ah = street.naturalHeight * scale;
      g.globalAlpha = 0.85;
      clipped(g, 0, 0, layout.vw, layout.vh, () =>
        g.drawImage(street, (layout.vw - aw) / 2, (layout.vh - ah) / 2, aw, ah),
      );
      g.globalAlpha = 1;
      fill(g, Theme.void, 0, 0, layout.vw, layout.vh, 0.55);
    }
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    this.buttons.reset();
    this.bar.reset();
    if (this.focus) {
      this.drawFocus(g, s);
      return;
    }

    header(
      g,
      this.app,
      this.quest
        ? `${String(this.quest.node).padStart(2, "0")} ${this.quest.title}`
        : t("quest.loading"),
    );

    // The toolbar is measured *before* the frame is cut, and the frame is told
    // how much to give up for it. Laying the panels out against the full body
    // and subtracting afterwards is the fault this file already carries two
    // scars from: the contents are laid out against a height the panel does
    // not have, and the last thing in them lands outside it.
    const pad = Math.round(10 * s);
    const toolW = layout.vw - pad * 2;
    const fullRows = rowsIn(fonts.stationSm, this.toolLabels(false), toolW, layout.minTouchH());
    // **A phone is compact in both orientations.** Held sideways the toolbar
    // fits on one row, so "compact when it wraps" left the phone's landscape
    // exactly as crowded as its portrait was — an eighteen-pixel editor with
    // a full bench under it.
    this.compactMode = layout.isPhone() || (layout.touch && fullRows > 1);
    const toolRows = this.compactMode
      ? rowsIn(fonts.stationSm, this.toolLabels(), toolW, layout.minTouchH())
      : fullRows;
    const toolRowH = Math.max(layout.minTouchH(), fonts.stationSm.height + 20);
    const toolGap = Math.round(fonts.stationSm.size * 0.5);
    this.barH = toolRows * toolRowH + (toolRows - 1) * toolGap;

    // Beside, or above. The player's choice if they have made one, the
    // window's if they have not — and the split is different for the two,
    // because a brief above the bench is read once and a brief beside it is
    // referred back to.
    const side = this.side;
    // The connection banner is app-level and slides down out of the header —
    // straight through this toolbar's band. So the toolbar moves under it
    // while it is up rather than being painted over: the same rule as the
    // message bar at the bottom of this screen, which is part of the layout
    // rather than an overlay for exactly this reason.
    const toast = this.app.toastBand();
    const f = frame(
      layout,
      side ? 0.34 : 0.26,
      0,
      side ? "row" : "column",
      this.barH + Math.round(6 * s) + toast,
    );

    this.drawToolbar(g, [pad, Math.round(38 * s) + pad + toast, toolW, this.barH]);

    // The message bar is *part of the layout*, not an overlay: it used to be
    // painted across the bottom of the body over whatever was there, and with
    // the button row wrapped to two lines that was RESET. The panels give up
    // its height instead, so nothing is ever drawn under it.
    // The bar is as tall as the lines the message wraps to: one line's
    // height put "back" of the SOLVE note under the footer in portrait.
    const msgLines = this.error ? wrap(fonts.small, this.error, f.body[2] - Math.round(16 * s)) : [];
    const msgH = this.error ? msgLines.length * fonts.small.height + Math.round(8 * s) : 0;
    const room = msgH > 0 ? msgH + Math.round(6 * s) : 0;
    const left: Rect = [f.left[0], f.left[1], f.left[2], f.left[3] - room];
    const right: Rect = [f.right[0], f.right[1], f.right[2], f.right[3] - room];

    arriving(g, f, "left", this.briefIn, () => {
      // The clock takes the top of the brief column and the brief starts under
      // it; on an untimed quest it takes nothing and nothing moves.
      const used = this.drawClock(g, left, s);
      this.drawBrief(g, [left[0], left[1] + used, left[2], left[3] - used] as Rect, accent);
    });
    arriving(g, f, "right", this.benchIn, () => this.drawWorkbench(g, right, accent));

    this.buttons.draw(g, this.compactMode ? fonts.stationSm : fonts.button);
    this.bar.draw(g, fonts.stationSm);
    this.sparks?.draw(this.t);
    if (this.error) {
      // A bar rather than a loose line: the message crosses both panels, and
      // bare text laid over a panel border is unreadable at the seam.
      //
      // Red is failure and only failure. "The GO land opens in the next
      // chapter" is news, not a fault, and painting news in the failure colour
      // is how a colour ends up meaning three things and therefore nothing.
      const barY = f.body[1] + f.body[3] - msgH;
      const tone = this.notice ? Theme.coin : Theme.red;
      fill(g, Theme.ink, f.body[0], barY, f.body[2], msgH, 0.92);
      fill(g, tone, f.body[0], barY, f.body[2], Math.max(1, Math.round(s)));
      g.fillStyle = css(this.notice ? Theme.cream : Theme.red);
      let my = barY + Math.round(4 * s);
      for (const line of msgLines) {
        printf(g, fonts.small, line, f.body[0], my, f.body[2], "center");
        my += fonts.small.height;
      }
    }
    // The keys that are *only* keys. `ESC MAP` used to sit under a button that
    // already said MAP, which is the footer explaining the screen to itself.
    footer(g, layout, t("quest.footer"));
  }

  /**
   * The toolbar's labels, in the order they are laid out.
   *
   * Shared by the measurement and the drawing so the two cannot disagree about
   * how many lines it wraps onto — the exact fault that put ALL MAPS on top of
   * PLAYGROUND on the map screen, recorded in decisions.md as a class rather
   * than as one bug.
   */
  private toolItems(compact = this.compactMode): Array<{ id: string; label: string; dim?: boolean }> {
    const noOutput = !this.runResult && this.log.lines.length === 0;
    // In the compact register the clipboard chips and LOBBY go: on a phone
    // the keyboard has its own paste, the map is one tap away, and three
    // rows of toolbar were the editor's rows.
    const keep = (id: string) =>
      !compact ||
      id === "back" ||
      id === "stack" ||
      id === "fontdown" ||
      id === "fontup" ||
      id === "focus";
    return [
      // Leaving, first and leftmost: the top-left of a screen is where a
      // person looks for the way back out of it.
      { id: "back", label: t("quest.backToMap") },
      { id: "lobby", label: t("quest.lobby") },
      // The clipboard. Canvas text cannot be selected, so these are not a
      // convenience — they are the only way any of it leaves the screen.
      { id: "copybrief", label: t("quest.copyBrief"), dim: !this.quest },
      { id: "copycode", label: t("quest.copyCode"), dim: !this.editor },
      { id: "copyout", label: t("quest.copyOutput"), dim: noOutput },
      { id: "paste", label: t("quest.paste"), dim: !this.editor },
      // How the screen is set up, and it says what it controls rather than
      // which axis it is: F1 is already the orientation and two buttons that
      // both read as "vertical" are two buttons nobody can tell apart.
      { id: "stack", label: this.side ? t("quest.briefSide") : t("quest.briefTop") },
      { id: "fontdown", label: t("quest.fontDown"), dim: this.fontMul <= FONT_MIN + 0.001 },
      { id: "fontup", label: t("quest.fontUp"), dim: this.fontMul >= FONT_MAX - 0.001 },
      { id: "focus", label: t("quest.code") },
    ].filter((i) => keep(i.id));
  }

  private toolLabels(compact = this.compactMode): string[] {
    return this.toolItems(compact).map((i) => i.label);
  }

  /**
   * The bench's own row, in the order it is laid out.
   *
   * RUN is filled and first; the hint button says how many are left rather
   * than which one is next — `HINT 2` reads as "hint number two", which is not
   * what it means. MAP used to be here, one gap from SUBMIT; it is in the
   * toolbar at the top of the screen now, because a control that abandons the
   * quest has no business sharing a row with the control that submits it.
   *
   * UNDO and REDO sit beside FORMAT because that is where the everyday
   * housekeeping of a buffer lives. The two irreversible controls share the
   * far end instead: RESET throws the buffer away and CLEAR STACK throws the
   * way back to it away, and neither can be hit by a hand that was aiming at
   * RUN. All three of the stack's buttons are drawn dim and are unhittable —
   * `Buttons.hit` skips a dim button — whenever the server has not told us
   * there is anything to step through, which includes a server that does not
   * have the edit stack at all.
   */
  private benchItems(): Array<{
    id: string;
    label: string;
    dim?: boolean;
    primary?: boolean;
  }> {
    // `hints_used` comes back on `quest.get` (§5.3) and on every `quest.hint`,
    // so leaving a quest and coming back does not offer a hint already paid for.
    const hintsLeft = this.quest
      ? hintsRemaining(this.quest.hints_total, this.quest.hints_used)
      : 0;
    const hintLabel = hintsLeft === 0 ? t("quest.noHints") : tn("quest.hintsLeft", hintsLeft);
    const steps = editControls(this.edit, this.editBusy);
    return [
      {
        id: "run",
        label: this.stage === "idle" ? t("quest.run") : "…",
        dim: this.stage !== "idle",
        primary: this.stage === "idle",
      },
      { id: "format", label: t("quest.format"), dim: this.formatting },
      { id: "undo", label: t("quest.undo"), dim: !steps.undo },
      { id: "redo", label: t("quest.redo"), dim: !steps.redo },
      { id: "hint", label: hintLabel, dim: hintsLeft <= 0 },
      { id: "console", label: this.consoleOpen ? t("quest.hideLog") : t("quest.log") },
      { id: "reset", label: t("quest.reset") },
      { id: "clearstack", label: t("quest.clearStack"), dim: !steps.clear },
      // **On a phone SOLVE is a chip on the bench, not a line of its own.**
      // Its own row plus the price beside it is a fifth of a sideways
      // phone's screen, and that fifth belongs to the editor. It goes last —
      // the far end of the last row, which is as far from RUN as this bench
      // has — and the price still arrives, in the note the press puts up.
      ...(this.compactMode
        ? [{ id: "solve", label: t("quest.solve"), dim: !this.quest || this.solving }]
        : []),
    ];
  }

  /**
   * CODE mode: the editor, edge to edge, and DONE in the top right corner.
   *
   * **DONE, not BACK.** The button has always returned to the quest screen —
   * the brief, the bench, RUN and SUBMIT — but "BACK" on a screen whose only
   * other exit leads to the map reads as leaving the quest, and nobody
   * presses a button they think will throw their work away. The word names
   * what it does: the writing is finished, put the tools back.
   */
  private drawFocus(g: Ctx, s: number): void {
    const { layout } = this.app;
    const fonts = ensureFonts(s);
    // **The header is not drawn here, so its hit box must not survive.**
    // `header()` is what clears and re-sets `logoutRect`, and `App`'s pointer
    // handler tests that rect *before* the scene sees the press. Left over
    // from the last framed frame it sits exactly where DONE is — the top
    // right corner — so the button that ends a writing session was logging
    // the player out and landing them on the login screen.
    this.app.logoutRect = null;
    this.app.logoutHover = false;
    const pad = Math.round(6 * s);
    const f = fonts.stationSm;
    const done = t("quest.codeDone");
    const [dw, dh] = btnBox(f, [done], 0, f.size * 2, layout.minTouchH());
    const bx = layout.vw - pad - dw;

    // The four controls the hands actually use while writing, and ANSWER.
    // Everything else this screen has — the brief, the log, the two
    // irreversible ones — is one tap away on the quest screen. CODE is for
    // writing, and a row that carried all twelve would be the crowding this
    // mode exists to escape.
    const steps = editControls(this.edit, this.editBusy);
    const items = [
      {
        id: "run",
        label: this.stage === "idle" ? t("quest.run") : "…",
        dim: this.stage !== "idle",
        primary: this.stage === "idle",
      },
      { id: "format", label: t("quest.format"), dim: this.formatting },
      { id: "undo", label: t("quest.undo"), dim: !steps.undo },
      { id: "redo", label: t("quest.redo"), dim: !steps.redo },
      // `strong` while it is on: a different colour rather than a louder one,
      // because ANSWER is a *mode* the screen is in, not the thing to press.
      { id: "answer", label: t("quest.answer"), dim: this.answerBusy, strong: this.answerOn },
    ];
    const rowW = Math.max(f.size * 4, bx - pad * 2);
    const rows = rowsIn(
      f,
      items.map((i) => i.label),
      rowW,
      layout.minTouchH(),
    );
    const rowGap = Math.round(f.size * 0.5);
    const bandH = rows * dh + (rows - 1) * rowGap;
    // The strip these sit on. Same treatment as the quest screen's toolbar
    // and for the same reason: this is a row of small controls over a
    // photograph of a street, and a lit window behind a label is a label
    // nobody can read.
    const strip = pad + Math.max(bandH, dh) + Math.round(3 * s) + f.height + Math.round(4 * s);
    fill(g, Theme.ink, 0, 0, layout.vw, strip, 0.82);
    fill(g, Theme.dim, 0, strip, layout.vw, 1, 0.5);
    this.bar.row(f, [pad, pad, rowW, bandH], items, layout.minTouchH());
    this.bar.add({ id: "unfocus", rect: [bx, pad, dw, dh], label: done });
    this.bar.draw(g, f);

    // The file — and, in ANSWER mode, how much of it is already yours. The
    // count is the whole scoreboard: characters you have typed that *are*
    // the answer, out of the answer.
    const statusY = pad + Math.max(bandH, dh) + Math.round(3 * s);
    const prog = this.answerProg;
    const on = this.answerOn && this.answerText !== null;
    const tail = !on
      ? ""
      : prog.done
        ? `   ${t("quest.answerMatched")}`
        : prog.wrong > 0
          ? `   ${t("quest.answerDiverged")}`
          : "";
    const status = on
      ? `${MAIN_FILE[this.land]}   ${prog.matched} / ${prog.total}${tail}`
      : MAIN_FILE[this.land];
    g.fillStyle = css(
      !on ? Theme.dim : prog.done ? Theme.admit : prog.wrong > 0 ? Theme.red : Theme.coin,
    );
    printf(g, f, status, pad + Math.round(8 * s), statusY, layout.vw - pad * 2, "left");

    const top = strip + Math.round(6 * s);
    well(g, pad, top, layout.vw - pad * 2, layout.vh - top - pad);
    const editorRect: Rect = [pad + 4, top + 4, layout.vw - pad * 2 - 8, layout.vh - top - pad - 8];
    if (this.editor) this.overlay?.place(editorRect, fonts.codeSm.size * this.fontMul);
    else this.overlay?.hide();
    this.sparks?.draw(this.t);
  }

  /**
   * The strip between the header and the panels.
   *
   * It gets its own plate for the same reason the message bar does: this sits
   * over a photograph of a street, and a row of small controls with a lit
   * window behind them is a row of small controls nobody can read.
   */
  private drawToolbar(g: Ctx, rect: Rect): void {
    const { layout } = this.app;
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    const [x, y, w, h] = rect;
    fill(g, Theme.ink, x - 4, y - 3, w + 8, h + 6, 0.82);
    fill(g, Theme.dim, x - 4, y + h + 3, w + 8, 1, 0.5);
    this.bar.row(fonts.stationSm, [x, y, w, h], this.toolItems(), layout.minTouchH());
  }

  private drawBrief(g: Ctx, rect: Rect, accent: readonly [number, number, number, number]): void {
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
    const inner = titledPanel(g, rect, t("quest.job"), accent);
    this.briefRect = inner;
    if (!this.quest) {
      g.fillStyle = css(Theme.dim);
      printf(g, fonts.small, "…", inner[0], inner[1], inner[2], "left");
      return;
    }

    // A brief is longer than the panel on most quests and in every portrait
    // window, so it scrolls rather than being silently cut off — a clipped
    // sample case is the one thing a player cannot work around.
    //
    // The order is the order somebody *working* needs, which is the reverse of
    // the order it used to be in. The job first, the sample output in the
    // panel's only well, then the hints, and the story line last: it is good
    // writing and it earns its place, but it does not earn being the loudest
    // thing on a screen a player is trying to code in.
    const top = inner[1] - this.briefScroll;
    // A permanent gutter for the scrollbar. Reserved whether or not it is
    // showing: a width that changed when the bar appeared would reflow the
    // text that decided whether the bar appears.
    const textW = inner[2] - Math.round(8 * s);
    let yy = top;
    clipped(g, inner[0], inner[1], inner[2], inner[3], () => {
      // The one place a mixed-language screen has to be honest about itself.
      //
      // The interface is translated here; the briefs are translated in
      // `content/i18n/` (SPEC §12.1), pack by pack, and the server says with
      // `text_locale` which language this one actually arrived in. When that
      // is not the language on screen — no pack for it yet, or a quest the
      // pack has not reached — a Korean panel with an English paragraph
      // inside it and no explanation reads as a translation somebody
      // abandoned halfway. One line saying which half is which turns it into
      // a stated fact, and it costs a line. See `briefNeedsNote`.
      if (briefNeedsNote(this.quest!.text_locale, locale())) {
        g.fillStyle = css(Theme.cyan, 0.7);
        // Line by line rather than one `printf`, for the leading. Press Start
        // 2P has no room above its capitals, so when this wraps in Czech the
        // caron of `přeložené` lands in the baseline of the line above it —
        // visible in the first Czech quest shot. Three virtual pixels is the
        // whole fix, and it stays local to the one short label on this screen
        // that is allowed to wrap.
        const lead = fonts.stationSm.height + Math.round(3 * s);
        for (const line of wrap(fonts.stationSm, t("quest.briefEnglish"), textW)) {
          printf(g, fonts.stationSm, line, inner[0], yy, textW, "left");
          yy += lead;
        }
        yy += Math.round(5 * s);
      }
      // `brief` is markdown (SPEC §2.1); the canvas draws the flattening.
      for (const b of blocks(this.quest!.brief)) {
        if (b.kind === "code") {
          const lines = wrap(fonts.code, b.text, textW - Math.round(10 * s));
          const h = lines.length * fonts.code.height + Math.round(8 * s);
          fill(g, Theme.ink, inner[0], yy, textW, h, 0.45);
          g.fillStyle = css(Theme.grass);
          let cy = yy + Math.round(4 * s);
          for (const line of lines) {
            printf(g, fonts.code, line, inner[0] + Math.round(6 * s), cy, textW, "left");
            cy += fonts.code.height;
          }
          yy += h + Math.round(6 * s);
        } else {
          g.fillStyle = css(Theme.cream);
          yy += printf(g, fonts.small, b.text, inner[0], yy, textW, "left") * fonts.small.height;
          yy += Math.round(6 * s);
        }
      }

      // SPEC §5.2 and §12: at least one case is `visible` precisely so "a
      // player is never guessing blind about the output format". It was the
      // smallest type on the panel; it is the most load-bearing fact on it.
      const tests = this.quest!.tests;
      for (const c of tests.visible) {
        const rows = (c.stdin ? 1 : 0) + 1;
        const wellH = fonts.stationSm.height + rows * fonts.code.height + Math.round(20 * s);
        well(g, inner[0], yy, textW, wellH);
        const tx = inner[0] + Math.round(8 * s);
        const tw = textW - Math.round(16 * s);
        let ty = yy + Math.round(8 * s);
        g.fillStyle = css(Theme.cyan);
        printf(g, fonts.stationSm, t("quest.sample", { name: c.name }), tx, ty, tw, "left");
        ty += fonts.stationSm.height + Math.round(4 * s);
        // IN and OUT line up on a measured column, not on spaces: 輸入 and
        // 輸出 are the same width as each other but not as `in`/`out`, and
        // Czech `vstup`/`výstup` differ from each other by a character.
        const labW =
          Math.max(width(fonts.code, t("quest.in")), width(fonts.code, t("quest.out"))) +
          Math.round(10 * s);
        if (c.stdin) {
          g.fillStyle = css(Theme.dim);
          printf(g, fonts.code, t("quest.in"), tx, ty, labW, "left");
          printf(g, fonts.code, show(c.stdin), tx + labW, ty, tw - labW, "left");
          ty += fonts.code.height;
        }
        g.fillStyle = css(Theme.grass);
        printf(g, fonts.code, t("quest.out"), tx, ty, labW, "left");
        printf(g, fonts.code, show(c.expect), tx + labW, ty, tw - labW, "left");
        yy += wellH + Math.round(8 * s);
      }
      if (tests.hidden_count > 0) {
        // The count only — never the data (SPEC §5.2).
        g.fillStyle = css(Theme.dim);
        printf(
          g,
          fonts.stationSm,
          tn("quest.hiddenCount", tests.hidden_count),
          inner[0],
          yy,
          textW,
          "left",
        );
        yy += fonts.stationSm.height + Math.round(8 * s);
      }

      for (const h of this.hints) {
        g.fillStyle = css(Theme.coin);
        yy +=
          printf(g, fonts.small, t("quest.hint", { text: h }), inner[0], yy, textW, "left") *
          fonts.small.height;
        yy += Math.round(6 * s);
      }

      if (this.quest!.story) {
        // Set apart by a rule, not by size.
        yy += Math.round(6 * s);
        fill(g, Theme.dim, inner[0], yy, textW, 1, 0.5);
        yy += Math.round(8 * s);
        g.fillStyle = css(Theme.cyan, 0.62);
        yy +=
          printf(g, fonts.codeSm, `“${this.quest!.story}”`, inner[0], yy, textW, "left") *
          fonts.codeSm.height;
        yy += Math.round(6 * s);
      }
    });

    this.briefOverflow = Math.max(0, yy - top - inner[3]);
    if (this.briefOverflow > 0) {
      // A scrollbar, because a panel that can scroll and does not say so is a
      // panel whose bottom half nobody finds.
      const trackH = inner[3];
      const thumbH = Math.max(12, (trackH * trackH) / (trackH + this.briefOverflow));
      const t = this.briefScroll / this.briefOverflow;
      fill(g, Theme.ink, inner[0] + inner[2] - 4, inner[1], 4, trackH, 0.5);
      fill(g, Theme.coin, inner[0] + inner[2] - 4, inner[1] + (trackH - thumbH) * t, 4, thumbH);
    }
  }

  /** The editor well, the button row, and the console drawer under them. */
  private drawWorkbench(
    g: Ctx,
    rect: Rect,
    accent: readonly [number, number, number, number],
  ): void {
    const { layout } = this.app;
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    // The bench's face: the button face, or the smaller chrome face in the
    // compact register, where eight labels a finger tall each took a row.
    const bench = this.compactMode ? fonts.stationSm : fonts.button;
    const label = MAIN_FILE[this.land];
    const inner = titledPanel(g, rect, `${label}   ${this.stageLabel()}`, accent);

    const btnH = Math.max(layout.minTouchH(), bench.height + 20);
    const consoleH = this.consoleOpen
      ? Math.round(inner[3] * (layout.isPortrait() ? 0.36 : 0.32))
      : 0;
    // SUBMIT is laid out first and taken out of the row's width, so it sits at
    // the far end of the bench and the everyday buttons flow up to it. It is
    // the one control on this screen that spends an attempt, and a control that
    // can be hit on the way to RUN is a control that will be.
    const [subW] = btnBox(
      bench,
      [t("quest.submit")],
      0,
      bench.size * 2,
      layout.minTouchH(),
    );
    const gap = Math.round(bench.size * 1.6);
    const rowW = inner[2] - subW - gap;
    // Measured, not assumed. At 1280 across, RESET wraps onto a second line,
    // and a band sized for one row put that button straight through the run
    // report underneath it — the report lost its first line to a button.
    const rowGap = Math.round(bench.size * 0.5);
    // The row's labels, in order, written once. The measurement below and the
    // layout further down are handed the *same* list for the reason this file
    // already carries a scar for: two lists that can disagree about how many
    // lines they wrap onto will eventually disagree, and the button that lands
    // past the band is drawn over whatever was under it. Three more controls
    // makes this the most crowded row on the screen, so it matters more now
    // than it did when there were five.
    const rowItems = this.benchItems();
    const rows = rowsIn(
      bench,
      rowItems.map((i) => i.label),
      rowW,
      layout.minTouchH(),
    );
    let bandH = rows * btnH + (rows - 1) * rowGap;
    // **The editor wins the argument on a phone.** The bench is a row of
    // controls; the editor is the screen's purpose. Where the two cannot both
    // have what they want — a 402-pixel-tall window held sideways — the
    // buttons come down to their labels plus air rather than the code coming
    // down to one line. `minTouchH` is a floor for a finger, and a finger
    // that cannot see the code has nothing to aim at.
    let benchBtnH = btnH;
    if (this.compactMode) {
      const cap = Math.round(inner[3] * (layout.isPortrait() ? 0.42 : 0.34));
      if (bandH > cap) {
        benchBtnH = Math.max(bench.height + 8, Math.floor((cap - (rows - 1) * rowGap) / rows));
        bandH = rows * benchBtnH + (rows - 1) * rowGap;
      }
    }

    // The answer key gets its own line under the bench, and the reasons are
    // the same two the RUN/SUBMIT pair already established here.
    //
    // *Placement*: it fills the editor with the reference solution, so it must
    // not be reachable by a hand aiming at RUN, and it costs a star, so it
    // must not be reachable by one aiming at SUBMIT. A sixth button in the
    // bench row would be neither — the row wraps at 1280 (that is what put a
    // button through the run report once already), and a wrapped SOLVE lands
    // wherever the wrap leaves it, which on one width is directly under RUN.
    // A line of its own is a position that cannot move.
    //
    // *The sentence beside it*: revealing the answer is the one thing on this
    // screen that costs something and does not look like it costs something.
    // It is drawn next to the button rather than shown after the press,
    // because a price a player reads afterwards is not a price they agreed to.
    // Wrapped, measured, and paid for out of the editor's height **before** the
    // editor is laid out — the fault this file carries two scars from is
    // sizing a band after the split and drawing into a height it does not have.
    // Twice the gap between the bench's own wrapped rows, measured rather than
    // guessed: at 1280 the rows sit 12 virtual pixels apart, and a control that
    // wipes the editor must not be one slip below HINT either.
    const solveGap = this.compactMode ? 0 : Math.round(fonts.button.size);
    const [solveW, solveBtnH] = btnBox(
      fonts.stationSm,
      [t("quest.solve")],
      0,
      fonts.stationSm.size * 2,
      layout.minTouchH(),
    );
    const noteX = inner[0] + solveW + Math.round(10 * s);
    const noteW = Math.max(1, inner[0] + inner[2] - noteX);
    // The price beside SOLVE is two lines of prose. On a phone those two
    // lines are a tenth of the screen spent on a sentence that the press
    // itself puts up anyway, so there the button stands alone and the
    // sentence arrives when it is relevant.
    const noteLines = this.compactMode ? [] : wrap(fonts.stationSm, t("quest.solveNote"), noteW);
    const noteH = this.compactMode
      ? 0
      : Math.max(solveBtnH, noteLines.length * fonts.stationSm.height);

    const editorH = Math.max(
      40,
      inner[3] - bandH - solveGap - noteH - consoleH - Math.round(16 * s),
    );

    well(g, inner[0], inner[1], inner[2], editorH);
    const editorRect: Rect = [inner[0] + 4, inner[1] + 4, inner[2] - 8, editorH - 8];
    // CodeMirror is a DOM element outside the canvas transform, so it waits
    // for its well to land rather than hanging in the air while the panel
    // slides in underneath it.
    // The editor's type is the player's to set — `A-` / `A+` in the toolbar,
    // remembered between sessions. Everything else on the screen keeps the UI
    // scale: the panels are furniture and the code is the work.
    if (this.editor && this.benchIn.finished) {
      this.overlay?.place(editorRect, fonts.codeSm.size * this.fontMul);
    } else this.overlay?.hide();

    const rowY = inner[1] + editorH + Math.round(8 * s);
    this.buttons.row(bench, [inner[0], rowY, rowW, bandH], rowItems, benchBtnH);
    this.buttons.add({
      id: "submit",
      rect: [inner[0] + inner[2] - subW, rowY, subW, benchBtnH],
      label: this.stage === "idle" ? t("quest.submit") : "…",
      dim: this.stage !== "idle",
      strong: this.stage === "idle",
    });

    const solveY = rowY + bandH + solveGap;
    if (!this.compactMode) {
      this.bar.add({
        id: "solve",
        rect: [inner[0], solveY, solveW, solveBtnH],
        label: t("quest.solve"),
        dim: !this.quest || this.solving,
      });
    }
    // Coin, not red and not dim: this is what a star costs, and stars on this
    // screen and on the map are already that colour. Dim would read as small
    // print, which is exactly the wrong register for a price.
    g.fillStyle = css(Theme.coin, 0.72);
    let ny = solveY + Math.round((noteH - noteLines.length * fonts.stationSm.height) / 2);
    for (const line of noteLines) {
      printf(g, fonts.stationSm, line, noteX, ny, noteW, "left");
      ny += fonts.stationSm.height;
    }

    if (consoleH > 0) {
      const cy = solveY + noteH + Math.round(8 * s);
      const ch = Math.max(24, inner[1] + inner[3] - cy);
      this.drawConsole(g, [inner[0], cy, inner[2], ch]);
    }
  }

  /**
   * What a run found, in the drawer, in language that is not a verdict.
   *
   * §4.9b: a run executes the **visible** cases only, so "it passed" means the
   * sample works and says nothing at all about the hidden ones. The strip says
   * both halves of that, every time, because a player who learns that green
   * here means done will be contradicted by SUBMIT and will trust neither.
   *
   * And it never claims a run was free. A run does not count against the
   * node's attempts or the player's stars — but it *is* recorded and its
   * mistakes do feed the drills, so the line says what is true.
   *
   * @returns the height it used.
   */
  private drawRunReport(g: Ctx, rect: Rect): number {
    const a = this.runResult;
    if (!a) return 0;
    const [x, y, w] = rect;
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
    const pad = Math.round(8 * s);
    const hidden = this.quest?.tests.hidden_count ?? 0;
    const ok = this.samplePassed(a);
    const failed = a.cases.find((c) => c.visible && !c.passed);

    const head = ok
      ? t("verdict.accepted")
      : a.verdict === "accepted"
        ? t("verdict.wrong_answer")
        : verdictLine(a.verdict);
    // The hidden count is on both paths. "what a run did and did not check" is
    // the whole point of the strip, and it is *more* important when the sample
    // failed — that is exactly when somebody might think they have seen the
    // worst of it.
    const notRun = hidden > 0 ? tn("run.notRun", hidden) : "";
    const detail = ok
      ? hidden > 0
        ? tn("run.passCheck", hidden, {
            passed: a.tests_passed,
            total: a.tests_total,
            notRun,
          })
        : t("run.passRecord", { passed: a.tests_passed, total: a.tests_total })
      : failed
        ? t("run.failDetail", {
            name: failed.name,
            expect: show(failed.expect ?? ""),
            got: show(failed.got ?? ""),
            notRun,
          })
        : t("run.counts", { passed: a.tests_passed, total: a.tests_total, notRun });

    // Clamped, twice. `expect` and `got` are arbitrary program output: a
    // program that prints a paragraph wraps to six lines here, and an
    // unclamped strip would paint straight over the button row it sits above
    // — the same failure a card sized for one row and drawn with two has.
    // Three lines, and never more than three fifths of the drawer.
    const all = wrap(fonts.codeSm, detail, w - pad * 2);
    const room = Math.max(
      1,
      Math.floor(
        (rect[3] * 0.6 - pad * 2 - fonts.stationSm.height - Math.round(4 * s)) /
          fonts.codeSm.height,
      ),
    );
    const lines = all.slice(0, Math.max(1, Math.min(3, room)));
    if (all.length > lines.length && lines.length > 0) {
      lines[lines.length - 1] = lines[lines.length - 1].replace(/.{0,2}$/u, "…");
    }
    const h =
      pad * 2 + fonts.stationSm.height + Math.round(4 * s) + lines.length * fonts.codeSm.height;
    const accent = ok ? Theme.cyan : Theme.red;
    fill(g, Theme.ink, x, y, w, h, 0.92);
    fill(g, accent, x, y, Math.round(3 * s), h);
    fill(g, Theme.dim, x, y + h - 1, w, 1, 0.5);
    g.fillStyle = css(accent);
    printf(
      g,
      fonts.stationSm,
      t("run.head", { what: head }),
      x + pad,
      y + pad,
      w - pad * 2,
      "left",
    );
    g.fillStyle = css(Theme.cream, 0.85);
    let ly = y + pad + fonts.stationSm.height + Math.round(4 * s);
    for (const line of lines) {
      printf(g, fonts.codeSm, line, x + pad, ly, w - pad * 2, "left");
      ly += fonts.codeSm.height;
    }
    return h + Math.round(4 * s);
  }

  /**
   * How long is left, from the server's deadline and the app's clock.
   *
   * Derived every frame rather than decremented: a backgrounded tab stops
   * getting frames, and a counter that had been ticking down locally would come
   * back wrong by exactly the time the player was away. Negative means
   * overtime, which is a real state here — the clock keeps going and the quest
   * stays open (§4.8b).
   */
  private secondsLeft(): number | null {
    const at = this.quest?.deadline_at;
    if (!at) return null;
    const ms = Date.parse(at);
    if (Number.isNaN(ms)) return null;
    return (ms - this.app.now()) / 1000;
  }

  /**
   * The countdown, if this quest has one.
   *
   * It blocks nothing and it is never a punishment: past the line it keeps
   * counting, in its own colour, and SUBMIT stays exactly as live as it was.
   * The server records `within_limit`; the screen records nothing.
   *
   * @returns the height it used, so the brief starts underneath it.
   */
  private drawClock(g: Ctx, rect: Rect, s: number): number {
    const left = this.secondsLeft();
    if (left === null) return 0;
    const fonts = ensureFonts(s);
    const [x, y, w] = rect;
    const over = left < 0;
    const secs = Math.max(0, Math.floor(Math.abs(left)));
    const text = `${over ? "+" : ""}${String(Math.floor(secs / 60)).padStart(2, "0")}:${String(
      secs % 60,
    ).padStart(2, "0")}`;
    const col = over
      ? Theme.brick
      : left <= CLOCK.urgent
        ? Theme.red
        : left <= CLOCK.warn
          ? Theme.coin
          : Theme.cyan;
    const h = fonts.code.height + Math.round(18 * s);

    // Arrival: it drops the last few pixels into place on the expo curve and
    // settles, rather than being there on frame one like a label.
    const k = this.clockIn.out;
    const drop = (1 - k) * Math.round(18 * s);
    const pulse = clockPulse(left, this.clockSince) * (reducedMotion() ? 0.5 : 1);
    g.save();
    g.globalAlpha = Math.min(1, this.clockIn.raw * 2.4);
    g.translate(0, -drop);
    // The pulse is a swell of the plate, not a shake of the digits: the number
    // has to stay readable at a glance the whole time.
    const grow = Math.round(pulse * 3 * s);
    const px = x - grow;
    const py = y - grow;
    const pw = w + grow * 2;
    const ph = h + grow * 2;
    // A plate, not floating text: this sits over a photograph of a street and
    // a number with nothing under it is unreadable the moment the street has a
    // bright window in it.
    fill(g, Theme.ink, px, py, pw, ph, 0.88);
    fill(g, col, px, py, pw, Math.round(2 * s), 0.55 + 0.45 * pulse);
    fill(g, col, px, py + ph - Math.round(2 * s), pw, Math.round(2 * s), 0.25 + 0.35 * pulse);
    g.fillStyle = css(Theme.dim);
    printf(
      g,
      fonts.stationSm,
      over ? t("quest.overtime") : t("quest.timeLeft"),
      x + Math.round(8 * s),
      y + Math.round(6 * s),
      w,
      "left",
    );
    g.fillStyle = css(col, 0.75 + 0.25 * Math.min(1, k + pulse));
    printf(g, fonts.code, text, x, y + Math.round(5 * s), w - Math.round(8 * s), "right");
    // The bar is the same fact in a shape you can read without counting: it
    // fills as the limit is spent, and stays full in overtime.
    const limit = this.quest?.time_limit_s ?? 0;
    if (limit > 0) {
      const spent = Math.min(1, Math.max(0, 1 - left / limit));
      const inset = Math.round(8 * s);
      const by = y + h - Math.round(7 * s);
      fill(g, Theme.dim, x + inset, by, w - inset * 2, Math.round(3 * s), 0.35);
      fill(
        g,
        col,
        x + inset,
        by,
        Math.round((w - inset * 2) * (over ? 1 : spent)),
        Math.round(3 * s),
        0.9,
      );
    }
    g.restore();
    return h + Math.round(8 * s);
  }

  private stageLabel(): string {
    if (this.stage === "idle") return "";
    const dots = ".".repeat(1 + (Math.floor(this.t * 3) % 3));
    const queue =
      this.stage === "queued" && this.queued > 0 ? t("quest.queued", { n: this.queued }) : "";
    const secs = this.elapsedMs > 1500 ? ` ${(this.elapsedMs / 1000).toFixed(1)}S` : "";
    return `${this.stage.toUpperCase()}${dots}${queue}${secs}`;
  }

  /**
   * The compile output, as it arrives. `rustc` thinking out loud is a better
   * progress bar than a spinner, and it is the only place the player sees the
   * error message that the mistake taxonomy is about to be built from.
   */
  private drawConsole(g: Ctx, rect: Rect): void {
    let [x, y, w, h] = rect;
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
    if (this.runResult) {
      const used = this.drawRunReport(g, [x, y, w, h]);
      y += used;
      h -= used;
      if (h < fonts.codeSm.height * 2) return;
    }
    well(g, x, y, w, h, [0.04, 0.03, 0.1, 0.98]);
    const pad = Math.round(6 * s);
    const lineH = fonts.codeSm.height;
    const rows = Math.max(1, Math.floor((h - pad * 2) / lineH));
    const flat: Array<{ stream: string; text: string }> = [];
    for (const line of this.log.lines) {
      for (const piece of wrap(fonts.codeSm, line.text, w - pad * 2)) {
        flat.push({ stream: line.stream, text: piece });
      }
    }
    if (!this.log.complete) {
      flat.push({
        stream: "stderr",
        text: t("quest.lostOutput", { gaps: [...this.log.gaps].join(", ") }),
      });
    }
    const start = Math.max(0, flat.length - rows - this.logScroll);
    clipped(g, x + pad, y + pad, w - pad * 2, h - pad * 2, () => {
      let ly = y + pad;
      for (let i = start; i < Math.min(flat.length, start + rows); i++) {
        const line = flat[i];
        g.fillStyle = css(
          line.stream === "stderr"
            ? Theme.red
            : line.stream === "compile"
              ? Theme.dim
              : Theme.grass,
        );
        printf(g, fonts.codeSm, line.text, x + pad, ly, w - pad * 2, "left");
        ly += lineH;
      }
      if (flat.length === 0) {
        g.fillStyle = css(Theme.dim);
        printf(g, fonts.codeSm, t("quest.silentCompiler"), x + pad, y + pad, w - pad * 2, "left");
      }
    });
    if (this.stage !== "idle") {
      fill(
        g,
        Theme.coin,
        x,
        y + h - 3,
        Math.round(w * (0.25 + 0.25 * (Math.sin(this.t * 3) + 1))),
        3,
      );
    }
  }

  resized(): void {
    /* the overlay is placed from the live layout every frame */
  }
}
