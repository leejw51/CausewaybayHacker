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
import { clipped, fill, well, type Ctx, type Rect } from "../engine/ui";
import { Buttons, footer, frame, GO, header, RUST, titledPanel } from "../ui/chrome";
import { Editor } from "../ui/editor";
import { Overlay } from "../ui/overlay";
import { WireError } from "../net/client";
import type { Attempt, Category, Land, Quest, RunStage } from "../net/protocol";
import { LogBuffer } from "../net/logbuf";
import { MapScene } from "./map";
import { ResultScene } from "./result";

type Stage = "idle" | RunStage;

export class QuestScene implements Scene {
  readonly name = "quest";
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
      this.error = e instanceof WireError ? e.payload.message : "could not open the quest";
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
      this.error = dropped
        ? "the connection dropped — that attempt is still running on the server"
        : e instanceof WireError
          ? `${e.payload.code}: ${e.payload.message}`
          : "the run failed";
    }
  }

  private showResult(attempt: Attempt): void {
    // `cleared` is "did *this* submission clear it" (§5.4); a re-solve is
    // still accepted and still deserves the sound, just not the fanfare.
    if (attempt.verdict === "accepted") this.app.chip.clear();
    else this.app.chip.fail();
    void this.app.go(
      new ResultScene(this.app, this.land, this.category, this.questId, attempt),
    );
  }

  private async hint(): Promise<void> {
    if (!this.quest) return;
    if (this.hints.length >= this.quest.hints_total) return;
    try {
      const res = await this.app.client.request("quest.hint", {
        quest_id: this.quest.id,
        index: this.hints.length,
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
    if (name === "escape") {
      void this.app.go(new MapScene(this.app, this.land, this.category));
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
        void this.app.go(new MapScene(this.app, this.land, this.category));
        break;
    }
  }

  update(dt: number): void {
    this.t += dt;
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
      layout,
      this.quest ? `${String(this.quest.node).padStart(2, "0")} ${this.quest.title}` : "LOADING",
      this.app.addressLabel,
    );

    this.drawBrief(g, f.left, accent);
    this.drawWorkbench(g, f.right, accent);

    this.buttons.draw(g, fonts.button);
    if (this.error) {
      g.fillStyle = css(Theme.red);
      printf(g, fonts.small, this.error, f.body[0], f.body[1] + f.body[3] - fonts.small.height, f.body[2], "left");
    }
    footer(g, layout, "CTRL+ENTER  RUN      ESC  MAP      F1  ORIENTATION");
  }

  private drawBrief(g: Ctx, rect: Rect, accent: readonly [number, number, number, number]): void {
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
    const inner = titledPanel(g, rect, "THE JOB", accent);
    if (!this.quest) {
      g.fillStyle = css(Theme.dim);
      printf(g, fonts.small, "…", inner[0], inner[1], inner[2], "left");
      return;
    }
    let y = inner[1];
    if (this.quest.story) {
      g.fillStyle = css(Theme.cyan);
      y += printf(g, fonts.small, `“${this.quest.story}”`, inner[0], y, inner[2], "left") * fonts.small.height;
      y += Math.round(6 * s);
    }
    g.fillStyle = css(Theme.cream);
    clipped(g, inner[0], y, inner[2], inner[1] + inner[3] - y, () => {
      let yy = y;
      yy += printf(g, fonts.small, this.quest!.brief, inner[0], yy, inner[2], "left") * fonts.small.height;
      for (const h of this.hints) {
        yy += Math.round(6 * s);
        g.fillStyle = css(Theme.coin);
        yy += printf(g, fonts.small, `HINT: ${h}`, inner[0], yy, inner[2], "left") * fonts.small.height;
        g.fillStyle = css(Theme.cream);
      }
    });
  }

  /** The editor well, the button row, and the console drawer under them. */
  private drawWorkbench(g: Ctx, rect: Rect, accent: readonly [number, number, number, number]): void {
    const { layout } = this.app;
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    const label = this.land === "rust" ? "main.rs" : "main.go";
    const inner = titledPanel(g, rect, `${label}   ${this.stageLabel()}`, accent);

    const btnH = Math.max(layout.minTouchH(), fonts.button.height + 20);
    const consoleH = this.consoleOpen ? Math.round(inner[3] * (layout.isPortrait() ? 0.36 : 0.32)) : 0;
    const editorH = Math.max(40, inner[3] - btnH - consoleH - Math.round(16 * s));

    well(g, inner[0], inner[1], inner[2], editorH);
    const editorRect: Rect = [inner[0] + 4, inner[1] + 4, inner[2] - 8, editorH - 8];
    if (this.editor) this.overlay?.place(editorRect, fonts.codeSm.size);
    else this.overlay?.hide();

    const rowY = inner[1] + editorH + Math.round(8 * s);
    const hintsLeft = this.quest ? this.quest.hints_total - this.hints.length : 0;
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
      flat.push({ stream: "stderr", text: `[some output was lost: ${[...this.log.gaps].join(", ")}]` });
    }
    const start = Math.max(0, flat.length - rows - this.logScroll);
    clipped(g, x + pad, y + pad, w - pad * 2, h - pad * 2, () => {
      let ly = y + pad;
      for (let i = start; i < Math.min(flat.length, start + rows); i++) {
        const line = flat[i];
        g.fillStyle = css(
          line.stream === "stderr" ? Theme.red : line.stream === "compile" ? Theme.dim : Theme.grass,
        );
        printf(g, fonts.codeSm, line.text, x + pad, ly, w - pad * 2, "left");
        ly += lineH;
      }
      if (flat.length === 0) {
        g.fillStyle = css(Theme.dim);
        printf(g, fonts.codeSm, "the compiler has not said anything yet", x + pad, y + pad, w - pad * 2, "left");
      }
    });
    if (this.stage !== "idle") {
      fill(g, Theme.coin, x, y + h - 3, Math.round(w * (0.25 + 0.25 * (Math.sin(this.t * 3) + 1))), 3);
    }
  }

  resized(): void {
    /* the overlay is placed from the live layout every frame */
  }
}
