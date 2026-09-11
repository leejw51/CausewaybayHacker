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
import { clipped, fill, inRect, well, type Ctx, type Rect } from "../engine/ui";
import { arriving, Buttons, footer, frame, GO, header, RUST, titledPanel } from "../ui/chrome";
import { seconds, Tween } from "../engine/motion";
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
  private t = 0;
  private consoleOpen = false;
  private logScroll = 0;
  private queued = 0;
  private briefScroll = 0;
  private briefOverflow = 0;
  private briefRect: Rect = [0, 0, 0, 0];
  private readonly briefIn = new Tween(seconds("panel"));
  private readonly benchIn = new Tween(seconds("panel"), seconds("stagger"));
  private readonly offs: Array<() => void> = [];

  constructor(
    private readonly app: App,
    readonly land: Land,
    readonly category: Category,
    readonly questId: string,
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
      this.editor = new Editor(this.land, res.quest.starter, () => {
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

  private async submit(): Promise<void> {
    if (!this.quest || !this.editor || this.stage !== "idle") return;
    this.attemptId = null;
    this.log = new LogBuffer("");
    this.stage = "queued";
    this.consoleOpen = true;
    this.error = "";
    try {
      const res = await this.app.client.request("quest.submit", {
        quest_id: this.quest.id,
        source: this.editor.source,
        lang: this.land,
      });
      this.stage = "idle";
      this.log.end();
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
      this.error = dropped
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

  private showResult(attempt: Attempt): void {
    // `cleared` is "did *this* submission clear it" (§5.4); a re-solve is
    // still accepted and still deserves the sound, just not the fanfare.
    if (attempt.verdict === "accepted") this.app.chip.clear();
    else this.app.chip.fail();
    void this.app.go(new ResultScene(this.app, this.land, this.category, this.questId, attempt));
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
      void this.submit();
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

    arriving(g, f, "left", this.briefIn, () => this.drawBrief(g, f.left, accent));
    arriving(g, f, "right", this.benchIn, () => this.drawWorkbench(g, f.right, accent));

    this.buttons.draw(g, fonts.button);
    if (this.error) {
      g.fillStyle = css(Theme.red);
      printf(
        g,
        fonts.small,
        this.error,
        f.body[0],
        f.body[1] + f.body[3] - fonts.small.height,
        f.body[2],
        "left",
      );
    }
    footer(
      g,
      layout,
      "CTRL+ENTER  RUN   ESC  MAP   PGUP/PGDN  LOG   F1  ORIENTATION   F3  LOG OUT",
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
    const top = inner[1] - this.briefScroll;
    let yy = top;
    clipped(g, inner[0], inner[1], inner[2], inner[3], () => {
      if (this.quest!.story) {
        g.fillStyle = css(Theme.cyan);
        yy +=
          printf(g, fonts.small, `“${this.quest!.story}”`, inner[0], yy, inner[2], "left") *
          fonts.small.height;
        yy += Math.round(6 * s);
      }

      // `brief` is markdown (SPEC §2.1); the canvas draws the flattening.
      for (const b of blocks(this.quest!.brief)) {
        if (b.kind === "code") {
          const lines = wrap(fonts.codeSm, b.text, inner[2] - Math.round(10 * s));
          const h = lines.length * fonts.codeSm.height + Math.round(8 * s);
          fill(g, Theme.ink, inner[0], yy, inner[2], h, 0.45);
          g.fillStyle = css(Theme.grass);
          let cy = yy + Math.round(4 * s);
          for (const line of lines) {
            printf(g, fonts.codeSm, line, inner[0] + Math.round(6 * s), cy, inner[2], "left");
            cy += fonts.codeSm.height;
          }
          yy += h + Math.round(6 * s);
        } else {
          g.fillStyle = css(Theme.cream);
          yy += printf(g, fonts.small, b.text, inner[0], yy, inner[2], "left") * fonts.small.height;
          yy += Math.round(6 * s);
        }
      }

      // SPEC §5.2 and §12: at least one case is `visible` precisely so "a
      // player is never guessing blind about the output format".
      const tests = this.quest!.tests;
      for (const c of tests.visible) {
        g.fillStyle = css(Theme.cyan);
        printf(g, fonts.stationSm, `SAMPLE · ${c.name}`, inner[0], yy, inner[2], "left");
        yy += fonts.stationSm.height + Math.round(3 * s);
        if (c.stdin) {
          g.fillStyle = css(Theme.dim);
          yy +=
            printf(g, fonts.codeSm, `in   ${show(c.stdin)}`, inner[0], yy, inner[2], "left") *
            fonts.codeSm.height;
        }
        g.fillStyle = css(Theme.grass);
        yy +=
          printf(g, fonts.codeSm, `out  ${show(c.expect)}`, inner[0], yy, inner[2], "left") *
          fonts.codeSm.height;
        yy += Math.round(6 * s);
      }
      if (tests.hidden_count > 0) {
        // The count only — never the data (SPEC §5.2).
        g.fillStyle = css(Theme.dim);
        printf(g, fonts.stationSm, `+${tests.hidden_count} HIDDEN`, inner[0], yy, inner[2], "left");
        yy += fonts.stationSm.height + Math.round(6 * s);
      }

      for (const h of this.hints) {
        g.fillStyle = css(Theme.coin);
        yy +=
          printf(g, fonts.small, `HINT: ${h}`, inner[0], yy, inner[2], "left") * fonts.small.height;
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
    const editorH = Math.max(40, inner[3] - btnH - consoleH - Math.round(16 * s));

    well(g, inner[0], inner[1], inner[2], editorH);
    const editorRect: Rect = [inner[0] + 4, inner[1] + 4, inner[2] - 8, editorH - 8];
    // CodeMirror is a DOM element outside the canvas transform, so it waits
    // for its well to land rather than hanging in the air while the panel
    // slides in underneath it.
    if (this.editor && this.benchIn.finished) this.overlay?.place(editorRect, fonts.codeSm.size);
    else this.overlay?.hide();

    const rowY = inner[1] + editorH + Math.round(8 * s);
    // `hints_used` comes back on `quest.get` (§5.3) and on every `quest.hint`,
    // so leaving a quest and coming back does not offer a hint already paid for.
    const hintsLeft = this.quest ? this.quest.hints_total - this.quest.hints_used : 0;
    this.buttons.row(
      fonts.button,
      [inner[0], rowY, inner[2], btnH],
      [
        { id: "run", label: this.stage === "idle" ? "RUN" : "…", dim: this.stage !== "idle" },
        { id: "hint", label: `HINT ${hintsLeft}`, dim: hintsLeft <= 0 },
        { id: "reset", label: "RESET" },
        { id: "console", label: this.consoleOpen ? "HIDE LOG" : "LOG" },
        { id: "back", label: "MAP" },
      ],
      layout.minTouchH(),
    );

    if (consoleH > 0) {
      const cy = rowY + btnH + Math.round(8 * s);
      const ch = Math.max(24, inner[1] + inner[3] - cy);
      this.drawConsole(g, [inner[0], cy, inner[2], ch]);
    }
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
    const [x, y, w, h] = rect;
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
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
