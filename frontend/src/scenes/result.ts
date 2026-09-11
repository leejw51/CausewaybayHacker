/**
 * The verdict.
 *
 * Everything on this screen came out of one `quest.submit` reply — the stars,
 * the case table, the classified mistakes. None of it is recomputed here, and
 * that is the point: the browser found out the same way the database did.
 *
 * A clear gets the confetti from `engine/burst.ts` and the stamp; a failure
 * gets the compiler's own words and the mistake kinds, because "you moved it
 * and then used it" is the lesson and `E0382` is the handle the server will
 * drill you on later (SPEC §7).
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { clipped, fill, type Ctx, type Rect } from "../engine/ui";
import { burstPlan, type Plan } from "../engine/burst";
import { cosine, expOut } from "../engine/ease";
import { Buttons, clearedStamp, footer, frame, GO, header, RUST, stars as drawStars, titledPanel } from "../ui/chrome";
import type { Attempt, Category, Land } from "../net/protocol";
import { MapScene } from "./map";
import { QuestScene } from "./quest";

const VERDICT_TEXT: Record<Attempt["verdict"], string> = {
  accepted: "ACCEPTED",
  wrong_answer: "WRONG ANSWER",
  compile_error: "IT DID NOT COMPILE",
  runtime_error: "IT CRASHED",
  timeout: "TOO SLOW",
  output_limit: "TOO MUCH OUTPUT",
  internal_error: "THE SERVER FELL OVER",
};

export class ResultScene implements Scene {
  readonly name = "result";
  private t = 0;
  private readonly buttons = new Buttons();
  private confetti: Plan | null = null;

  constructor(
    private readonly app: App,
    readonly land: Land,
    readonly category: Category,
    readonly questId: string,
    readonly attempt: Attempt,
    readonly log: string[],
  ) {}

  enter(): void {
    if (this.attempt.cleared) {
      const { vw, vh } = this.app.layout;
      this.confetti = burstPlan(vw / 2, vh * 0.35, 90);
    }
  }

  update(dt: number): void {
    this.t += dt;
  }

  key(name: string): void {
    if (name === "escape" || name === "return" || name === "kpenter") this.toMap();
    if (name === "r") this.retry();
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
    if (hit.id === "map") this.toMap();
    if (hit.id === "retry") this.retry();
  }

  private toMap(): void {
    void this.app.go(new MapScene(this.app, this.land, this.category));
  }

  private retry(): void {
    void this.app.go(new QuestScene(this.app, this.land, this.category, this.questId));
  }

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    const ok = this.attempt.cleared;
    const accent = this.land === "rust" ? RUST : GO;
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    header(g, layout, ok ? "STREET CLEARED" : "NOT YET", this.app.addressLabel);
    const f = frame(layout, layout.isPortrait() ? 0.42 : 0.42);
    this.buttons.reset();

    // --- the verdict plate --------------------------------------------------
    const left = titledPanel(g, f.left, "VERDICT", ok ? Theme.admit : Theme.red);
    let y = left[1];
    g.fillStyle = css(ok ? Theme.admit : Theme.red);
    y += printf(g, fonts.title, VERDICT_TEXT[this.attempt.verdict], left[0], y, left[2], "center") * fonts.title.height;
    y += Math.round(8 * s);

    if (ok) {
      drawStars(
        g,
        left[0] + left[2] / 2 - Math.round(24 * s),
        y + Math.round(14 * s),
        Math.round(11 * s),
        this.attempt.stars,
        3,
      );
      y += Math.round(34 * s);
      clearedStamp(g, left[0] + left[2] / 2, y + Math.round(28 * s), Math.min(left[2] * 0.7, 260 * s), -0.12);
      y += Math.round(70 * s);
    }

    g.fillStyle = css(Theme.cream);
    printf(
      g,
      fonts.small,
      [
        `tests   ${this.attempt.tests_passed}/${this.attempt.tests_total}`,
        `compile ${this.attempt.compile_ms} ms`,
        `run     ${this.attempt.run_ms} ms`,
        `attempt ${this.attempt.id}`,
      ].join("\n"),
      left[0],
      y,
      left[2],
      "left",
    );

    // --- what went wrong ----------------------------------------------------
    const right = titledPanel(g, f.right, ok ? "THE RUN" : "WHAT WENT WRONG", accent);
    clipped(g, right[0], right[1], right[2], right[3], () => {
      let ry = right[1];
      const lineH = fonts.small.height;

      for (const c of this.attempt.cases) {
        g.fillStyle = css(c.passed ? Theme.admit : Theme.red);
        printf(g, fonts.small, `${c.passed ? "PASS" : "FAIL"}  ${c.name}`, right[0], ry, right[2], "left");
        ry += lineH;
        // Hidden cases report pass/fail and nothing else (SPEC §5.2), so there
        // is deliberately no `else` branch printing the data.
        if (c.visible && !c.passed) {
          g.fillStyle = css(Theme.dim);
          ry += printf(g, fonts.codeSm, `expected ${JSON.stringify(c.expect ?? "")}`, right[0], ry, right[2], "left") * fonts.codeSm.height;
          ry += printf(g, fonts.codeSm, `got      ${JSON.stringify(c.got ?? "")}`, right[0], ry, right[2], "left") * fonts.codeSm.height;
        }
      }

      if (this.attempt.mistakes.length > 0) {
        ry += Math.round(8 * s);
        g.fillStyle = css(Theme.coin);
        printf(g, fonts.stationSm, "THE COMPILER'S OWN WORDS", right[0], ry, right[2], "left");
        ry += fonts.stationSm.height + Math.round(6 * s);
        for (const m of this.attempt.mistakes) {
          g.fillStyle = css(Theme.pink);
          printf(g, fonts.small, `${m.kind}${m.code ? ` (${m.code})` : ""}`, right[0], ry, right[2], "left");
          ry += lineH;
          g.fillStyle = css(Theme.cream);
          ry += printf(g, fonts.codeSm, m.message, right[0], ry, right[2], "left") * fonts.codeSm.height;
        }
      }

      if (this.attempt.stderr) {
        ry += Math.round(8 * s);
        g.fillStyle = css(Theme.red);
        ry += printf(g, fonts.codeSm, this.attempt.stderr, right[0], ry, right[2], "left") * fonts.codeSm.height;
      }
    });

    this.drawConfetti(g);

    const btnRect: Rect = [
      f.body[0],
      layout.vh - Math.round(26 * s) - Math.max(layout.minTouchH(), fonts.button.height + 20) - Math.round(6 * s),
      f.body[2],
      Math.max(layout.minTouchH(), fonts.button.height + 20),
    ];
    fill(g, Theme.void, btnRect[0], btnRect[1] - 4, btnRect[2], btnRect[3] + 8, 0.8);
    this.buttons.row(
      fonts.button,
      btnRect,
      [
        { id: "retry", label: ok ? "AGAIN" : "TRY AGAIN" },
        { id: "map", label: "BACK TO THE MAP" },
      ],
      layout.minTouchH(),
    );
    this.buttons.draw(g, fonts.button);
    footer(g, layout, "ENTER  MAP      R  TRY AGAIN      F1  ORIENTATION");
  }

  /**
   * `engine/burst.ts` plans the particles; this is the paint. The plan is a
   * closed-form path — a throw that eases out, an optional second leg that
   * eases in and out, an arc, and gravity — so a particle's position is a
   * function of its age and nothing is integrated frame to frame. That is why
   * the confetti looks the same on a 60 Hz screen and a 144 Hz one.
   */
  private drawConfetti(g: Ctx): void {
    const plan = this.confetti;
    if (!plan) return;
    const t = this.t;

    for (const r of plan.rings) {
      const age = t - r.delay;
      if (age < 0 || age > r.life) continue;
      const u = age / r.life;
      const rad = r.radius * expOut(u);
      g.globalAlpha = (1 - u) * (r.glow ? 0.35 : 0.8);
      g.strokeStyle = css(r.color);
      g.lineWidth = Math.max(1, r.radius * 0.06 * (1 - u));
      g.beginPath();
      g.arc(r.x, r.y, rad, 0, Math.PI * 2);
      g.stroke();
      g.globalAlpha = 1;
      g.lineWidth = 1;
    }

    for (const p of plan.particles) {
      const age = t - p.delay;
      if (age < 0 || age > p.life) continue;
      const u = age / p.life;
      const out = expOut(u);
      const leg = cosine(u);
      const lift = Math.sin(Math.PI * u);
      const x = p.x + p.dx * out + p.tox * leg + p.liftx * lift;
      const y = p.y + p.dy * out + p.toy * leg + p.lifty * lift + 0.5 * p.gravity * age * age;
      const alpha = Math.max(0, 1 - u * u);
      g.globalAlpha = alpha;
      g.fillStyle = css(p.color, 1);
      // A coin is drawn as a rectangle whose width is a cosine of its spin;
      // a scrap of paper tumbles the same way but keeps its colour flat.
      const spin = Math.cos(age * (4 + p.seed * 6));
      const w = p.shape === 3 || p.shape === 2 ? Math.max(1, p.size * Math.abs(spin)) : p.size;
      if (p.shape === 1) {
        g.fillRect(x - p.size / 2, y - p.size / 6, p.size, p.size / 3);
        g.fillRect(x - p.size / 6, y - p.size / 2, p.size / 3, p.size);
      } else {
        g.fillRect(x - w / 2, y - p.size / 2, w, p.size);
      }
      g.globalAlpha = 1;
    }
  }
}
