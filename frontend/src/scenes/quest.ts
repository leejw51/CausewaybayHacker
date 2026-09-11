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
import { ensureFonts, printf, wrap } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { btnBox, rowsIn, clipped, fill, inRect, well, type Ctx, type Rect } from "../engine/ui";
import { arriving, Buttons, footer, frame, GO, header, RUST, titledPanel } from "../ui/chrome";
import { CLOCK, clockPulse, reducedMotion, seconds, Tween } from "../engine/motion";
import { Editor } from "../ui/editor";
import { Overlay } from "../ui/overlay";
import { WireError } from "../net/client";
import { playerText } from "../net/protocol";
import type { Attempt, Category, Land, Quest, RunStage } from "../net/protocol";
import { LogBuffer } from "../net/logbuf";
import { blocks } from "../ui/markdown";
import { MapScene } from "./map";
import { ResultScene } from "./result";

type Stage = "idle" | RunStage;

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
const VERDICT_LINE: Record<Attempt["verdict"], string> = {
  accepted: "THE SAMPLE WORKS",
  wrong_answer: "THE SAMPLE DOES NOT MATCH YET",
  compile_error: "IT DID NOT COMPILE",
  runtime_error: "IT CRASHED",
  timeout: "TOO SLOW",
  output_limit: "TOO MUCH OUTPUT",
  internal_error: "THE SERVER COULD NOT RUN IT",
};

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
        this.error = "could not open the quest";
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
        ? "this server does not have RUN yet — press SUBMIT"
        : dropped
          ? "the connection dropped — that attempt is still running on the server"
          : goGap
            ? // The Go runner arrives in the next milestone. Reporting that as a
              // server fault teaches the player to distrust a working server.
              "the GO land opens in the next chapter"
            : e instanceof WireError
              ? playerText(e.payload.code)
              : "the run failed";
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
        this.error = "already tidy";
        this.notice = true;
      }
    } catch (e) {
      this.error =
        e instanceof WireError && e.payload.code === "not_found"
          ? "this server does not have FORMAT yet"
          : e instanceof WireError
            ? playerText(e.payload.code)
            : "the formatter did not answer";
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
      this.app.say("no more hints");
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
      void this.app.go(new MapScene(this.app, this.land, this.category), "back");
      return;
    }
    if ((name === "return" || name === "kpenter") && (ev.metaKey || ev.ctrlKey)) {
      ev.preventDefault();
      // The reflex key is RUN. Submitting is a decision and it is made with a
      // button, not with the shortcut somebody's hands press without looking.
      void this.run();
    }
    // The binding people already have in their fingers, as close as this
    // plumbing allows: a keystroke only reaches a scene from inside the editor
    // when Ctrl or Cmd is held, so Shift+Alt+F could never arrive here.
    if (name === "f" && (ev.metaKey || ev.ctrlKey) && ev.shiftKey) {
      ev.preventDefault();
      void this.format();
    }
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    if (phase === "move") {
      this.buttons.hovered = this.buttons.hit(x, y)?.id ?? null;
      return;
    }
    if (phase !== "down") return;
    const hit = this.buttons.hit(x, y);
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
      case "back":
        void this.app.go(new MapScene(this.app, this.land, this.category), "back");
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
    // In portrait the brief is read once and the editor is lived in, so the
    // split is not the same number as landscape.
    const f = frame(layout, layout.isPortrait() ? 0.26 : 0.34);
    const s = f.scale;
    const fonts = ensureFonts(s);
    this.buttons.reset();

    header(
      g,
      this.app,
      this.quest ? `${String(this.quest.node).padStart(2, "0")} ${this.quest.title}` : "LOADING",
    );

    // The message bar is *part of the layout*, not an overlay: it used to be
    // painted across the bottom of the body over whatever was there, and with
    // the button row wrapped to two lines that was RESET. The panels give up
    // its height instead, so nothing is ever drawn under it.
    const barH = this.error ? fonts.small.height + Math.round(8 * s) : 0;
    const room = barH > 0 ? barH + Math.round(6 * s) : 0;
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
    if (this.error) {
      // A bar rather than a loose line: the message crosses both panels, and
      // bare text laid over a panel border is unreadable at the seam.
      //
      // Red is failure and only failure. "The GO land opens in the next
      // chapter" is news, not a fault, and painting news in the failure colour
      // is how a colour ends up meaning three things and therefore nothing.
      const barY = f.body[1] + f.body[3] - barH;
      const tone = this.notice ? Theme.coin : Theme.red;
      fill(g, Theme.ink, f.body[0], barY, f.body[2], barH, 0.92);
      fill(g, tone, f.body[0], barY, f.body[2], Math.max(1, Math.round(s)));
      g.fillStyle = css(this.notice ? Theme.cream : Theme.red);
      printf(g, fonts.small, this.error, f.body[0], barY + Math.round(4 * s), f.body[2], "center");
    }
    // The keys that are *only* keys. `ESC MAP` used to sit under a button that
    // already said MAP, which is the footer explaining the screen to itself.
    footer(
      g,
      layout,
      "CTRL+ENTER  RUN   CTRL+SHIFT+F  FORMAT   PGUP/PGDN  LOG   F1  ORIENTATION   F3  LOG OUT",
    );
  }

  private drawBrief(g: Ctx, rect: Rect, accent: readonly [number, number, number, number]): void {
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
    const inner = titledPanel(g, rect, "THE JOB", accent);
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
    let yy = top;
    clipped(g, inner[0], inner[1], inner[2], inner[3], () => {
      // `brief` is markdown (SPEC §2.1); the canvas draws the flattening.
      for (const b of blocks(this.quest!.brief)) {
        if (b.kind === "code") {
          const lines = wrap(fonts.code, b.text, inner[2] - Math.round(10 * s));
          const h = lines.length * fonts.code.height + Math.round(8 * s);
          fill(g, Theme.ink, inner[0], yy, inner[2], h, 0.45);
          g.fillStyle = css(Theme.grass);
          let cy = yy + Math.round(4 * s);
          for (const line of lines) {
            printf(g, fonts.code, line, inner[0] + Math.round(6 * s), cy, inner[2], "left");
            cy += fonts.code.height;
          }
          yy += h + Math.round(6 * s);
        } else {
          g.fillStyle = css(Theme.cream);
          yy += printf(g, fonts.small, b.text, inner[0], yy, inner[2], "left") * fonts.small.height;
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
        well(g, inner[0], yy, inner[2], wellH);
        const tx = inner[0] + Math.round(8 * s);
        const tw = inner[2] - Math.round(16 * s);
        let ty = yy + Math.round(8 * s);
        g.fillStyle = css(Theme.cyan);
        printf(g, fonts.stationSm, `SAMPLE · ${c.name}`, tx, ty, tw, "left");
        ty += fonts.stationSm.height + Math.round(4 * s);
        if (c.stdin) {
          g.fillStyle = css(Theme.dim);
          printf(g, fonts.code, `in   ${show(c.stdin)}`, tx, ty, tw, "left");
          ty += fonts.code.height;
        }
        g.fillStyle = css(Theme.grass);
        printf(g, fonts.code, `out  ${show(c.expect)}`, tx, ty, tw, "left");
        yy += wellH + Math.round(8 * s);
      }
      if (tests.hidden_count > 0) {
        // The count only — never the data (SPEC §5.2).
        g.fillStyle = css(Theme.dim);
        printf(g, fonts.stationSm, `+${tests.hidden_count} HIDDEN`, inner[0], yy, inner[2], "left");
        yy += fonts.stationSm.height + Math.round(8 * s);
      }

      for (const h of this.hints) {
        g.fillStyle = css(Theme.coin);
        yy +=
          printf(g, fonts.small, `HINT: ${h}`, inner[0], yy, inner[2], "left") * fonts.small.height;
        yy += Math.round(6 * s);
      }

      if (this.quest!.story) {
        // Set apart by a rule, not by size.
        yy += Math.round(6 * s);
        fill(g, Theme.dim, inner[0], yy, inner[2], 1, 0.5);
        yy += Math.round(8 * s);
        g.fillStyle = css(Theme.cyan, 0.62);
        yy +=
          printf(g, fonts.codeSm, `“${this.quest!.story}”`, inner[0], yy, inner[2], "left") *
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
    const hintLabel =
      hintsLeft === 0 ? "NO HINTS" : hintsLeft === 1 ? "1 HINT LEFT" : `${hintsLeft} HINTS LEFT`;
    // SUBMIT is laid out first and taken out of the row's width, so it sits at
    // the far end of the bench and the everyday buttons flow up to it. It is
    // the one control on this screen that spends an attempt, and a control that
    // can be hit on the way to RUN is a control that will be.
    const [subW] = btnBox(fonts.button, ["SUBMIT"], 0, fonts.button.size * 2, layout.minTouchH());
    const gap = Math.round(fonts.button.size * 1.6);
    const rowW = inner[2] - subW - gap;
    // Measured, not assumed. At 1280 across, RESET wraps onto a second line,
    // and a band sized for one row put that button straight through the run
    // report underneath it — the report lost its first line to a button.
    const rowGap = Math.round(fonts.button.size * 0.5);
    const rows = rowsIn(
      fonts.button,
      ["RUN", "FORMAT", hintLabel, this.consoleOpen ? "HIDE LOG" : "LOG", "MAP", "RESET"],
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
    if (this.editor && this.benchIn.finished) this.overlay?.place(editorRect, fonts.codeSm.size);
    else this.overlay?.hide();

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
          label: this.stage === "idle" ? "RUN" : "…",
          dim: this.stage !== "idle",
          primary: this.stage === "idle",
        },
        { id: "format", label: "FORMAT", dim: this.formatting },
        { id: "hint", label: hintLabel, dim: hintsLeft <= 0 },
        { id: "console", label: this.consoleOpen ? "HIDE LOG" : "LOG" },
        { id: "back", label: "MAP" },
        { id: "reset", label: "RESET" },
      ],
      layout.minTouchH(),
    );
    this.buttons.add({
      id: "submit",
      rect: [inner[0] + inner[2] - subW, rowY, subW, btnH],
      label: this.stage === "idle" ? "SUBMIT" : "…",
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
      ? "THE SAMPLE WORKS"
      : a.verdict === "accepted"
        ? "THE SAMPLE DOES NOT MATCH YET"
        : VERDICT_LINE[a.verdict];
    // The hidden count is on both paths. "what a run did and did not check" is
    // the whole point of the strip, and it is *more* important when the sample
    // failed — that is exactly when somebody might think they have seen the
    // worst of it.
    const notRun =
      hidden > 0 ? ` · ${hidden} hidden ${hidden === 1 ? "case" : "cases"} not run` : "";
    const detail = ok
      ? hidden > 0
        ? `${a.tests_passed}/${a.tests_total} sample cases${notRun} — press SUBMIT to check ${hidden === 1 ? "it" : "them"}`
        : `${a.tests_passed}/${a.tests_total} sample cases — press SUBMIT to record it`
      : failed
        ? `${failed.name} · expected ${show(failed.expect ?? "")} · got ${show(failed.got ?? "")}${notRun}`
        : `${a.tests_passed}/${a.tests_total} sample cases${notRun}`;

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
    printf(g, fonts.stationSm, `RUN · ${head}`, x + pad, y + pad, w - pad * 2, "left");
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
      over ? "OVERTIME" : "TIME LEFT",
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
    const queue = this.stage === "queued" && this.queued > 0 ? ` (${this.queued} AHEAD)` : "";
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
        text: `[some output was lost: ${[...this.log.gaps].join(", ")}]`,
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
        printf(
          g,
          fonts.codeSm,
          "the compiler has not said anything yet",
          x + pad,
          y + pad,
          w - pad * 2,
          "left",
        );
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
