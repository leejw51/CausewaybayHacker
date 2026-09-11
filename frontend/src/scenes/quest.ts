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
import { css, Theme } from "../engine/theme";
import { btnBox, rowsIn, clipped, fill, inRect, well, type Ctx, type Rect } from "../engine/ui";
import {
  arriving,
  Buttons,
  footer,
  frame,
  GO,
  header,
  RUST,
  titledPanel,
  type Stack,
} from "../ui/chrome";
import { CLOCK, clockPulse, reducedMotion, seconds, Tween } from "../engine/motion";
import { Editor } from "../ui/editor";
import { Overlay } from "../ui/overlay";
import { WireError } from "../net/client";
import { playerText } from "../net/protocol";
import type { Attempt, Category, Land, Quest, RunStage } from "../net/protocol";
import { LogBuffer } from "../net/logbuf";
import { blocks } from "../ui/markdown";
import { clipMessage, copyText, readText } from "../ui/clip";
import { readEnumPref, readNumberPref, writePref } from "../ui/prefs";
import { LandsScene } from "./lands";
import { locale, t, tn } from "../i18n";
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
 * Expected output with its whitespace made visible. "your answer is right but
 * has a trailing newline" is not a lesson worth teaching (SPEC §5.2), and it
 * is not one a player can even see unless the newline is drawn.
 */
function show(text: string): string {
  return JSON.stringify(text);
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
};

export class QuestScene implements Scene {
  readonly name = "quest";
  readonly mood = "quest" as const;
  private quest: Quest | null = null;
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
      const res = await this.app.client.request("quest.get", { quest_id: this.questId });
      this.quest = res.quest;
      this.editor = new Editor(this.land, this.draft ?? res.quest.starter, () => {
        /* the source is read on submit; there is nothing to save locally */
      });
      this.overlay = new Overlay(this.app.overlay, this.app.layout, this.editor.dom);
      queueMicrotask(() => this.editor?.focus());
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
    this.overlay?.destroy();
    this.editor?.destroy();
    this.editor = null;
    this.overlay = null;
  }

  // -- actions -------------------------------------------------------------

  /**
   * Whether walking away throws work away. Compared against the starter rather
   * than tracked with a dirty flag, because typing something and then undoing
   * it back to the starter is not unsaved work, and being asked about it would
   * teach the player to dismiss the question without reading it.
   */
  unsaved(): boolean {
    if (!this.editor || !this.quest) return false;
    return this.editor.source.trim() !== this.quest.starter.trim();
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
    try {
      const res = await this.app.client.request(kind, {
        quest_id: this.quest.id,
        source: this.editor.source,
        lang: this.land,
      });
      this.stage = "idle";
      this.log.end();
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

  private async hint(): Promise<void> {
    if (!this.quest) return;
    if (this.quest.hints_used >= this.quest.hints_total) return;
    try {
      const res = await this.app.client.request("quest.hint", {
        quest_id: this.quest.id,
        index: this.quest.hints_used,
      });
      this.hints.push(res.hint);
      if (this.quest) this.quest.hints_used = res.hints_used;
      this.app.chip.coin();
    } catch {
      this.app.say(t("quest.noMoreHints"));
    }
  }

  private async reset(): Promise<void> {
    if (!this.quest || !this.editor) return;
    try {
      const res = await this.app.client.request("quest.reset", { quest_id: this.quest.id });
      this.editor.load(this.land, res.starter);
    } catch {
      this.editor.load(this.land, this.quest.starter);
    }
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
      case "run":
        void this.run();
        break;
      case "submit":
        void this.submit();
        break;
      case "hint":
        void this.hint();
        break;
      case "reset":
        void this.reset();
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
    const accent = this.land === "rust" ? RUST : GO;
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
    const toolRows = rowsIn(fonts.stationSm, this.toolLabels(), toolW, layout.minTouchH());
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
    const msgH = this.error ? fonts.small.height + Math.round(8 * s) : 0;
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

    this.buttons.draw(g, fonts.button);
    this.bar.draw(g, fonts.stationSm);
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
      printf(g, fonts.small, this.error, f.body[0], barY + Math.round(4 * s), f.body[2], "center");
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
  private toolItems(): Array<{ id: string; label: string; dim?: boolean }> {
    const noOutput = !this.runResult && this.log.lines.length === 0;
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
    ];
  }

  private toolLabels(): string[] {
    return this.toolItems().map((i) => i.label);
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
      // The interface is translated and the 138 briefs are not — they belong
      // to `content/` and translating them is a different, much larger job. A
      // Korean panel with an English paragraph inside it and no explanation
      // reads as a translation somebody abandoned halfway. One line saying
      // which half is which turns it into a stated fact, and it costs a line.
      if (locale() !== "en") {
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
    const label = this.land === "rust" ? "main.rs" : "main.go";
    const inner = titledPanel(g, rect, `${label}   ${this.stageLabel()}`, accent);

    const btnH = Math.max(layout.minTouchH(), fonts.button.height + 20);
    const consoleH = this.consoleOpen
      ? Math.round(inner[3] * (layout.isPortrait() ? 0.36 : 0.32))
      : 0;
    // `hints_used` comes back on `quest.get` (§5.3) and on every `quest.hint`,
    // so leaving a quest and coming back does not offer a hint already paid for.
    const hintsLeft = this.quest ? this.quest.hints_total - this.quest.hints_used : 0;
    const hintLabel = hintsLeft === 0 ? t("quest.noHints") : tn("quest.hintsLeft", hintsLeft);
    // SUBMIT is laid out first and taken out of the row's width, so it sits at
    // the far end of the bench and the everyday buttons flow up to it. It is
    // the one control on this screen that spends an attempt, and a control that
    // can be hit on the way to RUN is a control that will be.
    const [subW] = btnBox(
      fonts.button,
      [t("quest.submit")],
      0,
      fonts.button.size * 2,
      layout.minTouchH(),
    );
    const gap = Math.round(fonts.button.size * 1.6);
    const rowW = inner[2] - subW - gap;
    // Measured, not assumed. At 1280 across, RESET wraps onto a second line,
    // and a band sized for one row put that button straight through the run
    // report underneath it — the report lost its first line to a button.
    const rowGap = Math.round(fonts.button.size * 0.5);
    const rows = rowsIn(
      fonts.button,
      [
        t("quest.run"),
        t("quest.format"),
        hintLabel,
        this.consoleOpen ? t("quest.hideLog") : t("quest.log"),
        t("quest.reset"),
      ],
      rowW,
      layout.minTouchH(),
    );
    const bandH = rows * btnH + (rows - 1) * rowGap;
    const editorH = Math.max(40, inner[3] - bandH - consoleH - Math.round(16 * s));

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
    this.buttons.row(
      fonts.button,
      [inner[0], rowY, rowW, bandH],
      // RUN is filled and first; RESET is the destructive one and sits at the
      // far end, where it cannot be hit on the way to anything else. And the
      // hint button says how many are left rather than which one is next —
      // `HINT 2` reads as "hint number two", which is not what it means.
      [
        {
          id: "run",
          label: this.stage === "idle" ? t("quest.run") : "…",
          dim: this.stage !== "idle",
          primary: this.stage === "idle",
        },
        { id: "format", label: t("quest.format"), dim: this.formatting },
        { id: "hint", label: hintLabel, dim: hintsLeft <= 0 },
        { id: "console", label: this.consoleOpen ? t("quest.hideLog") : t("quest.log") },
        // MAP used to be here, one gap from SUBMIT. It is in the toolbar at
        // the top of the screen now: a control that abandons the quest has no
        // business sharing a row with the control that submits it.
        { id: "reset", label: t("quest.reset") },
      ],
      layout.minTouchH(),
    );
    this.buttons.add({
      id: "submit",
      rect: [inner[0] + inner[2] - subW, rowY, subW, btnH],
      label: this.stage === "idle" ? t("quest.submit") : "…",
      dim: this.stage !== "idle",
      strong: this.stage === "idle",
    });

    if (consoleH > 0) {
      const cy = rowY + bandH + Math.round(8 * s);
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
