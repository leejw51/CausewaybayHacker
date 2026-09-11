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
import { ensureFonts, printf, width } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { clipped, fill, well, type Ctx, type Rect } from "../engine/ui";
import { burstPlan, type Plan } from "../engine/burst";
import { cosine, expOut } from "../engine/ease";
import { seconds, Tween } from "../engine/motion";
import { star as starAt } from "../engine/ui";
import { Buttons, clearedStamp, footer, frame, GO, header, RUST, titledPanel } from "../ui/chrome";
import type { Attempt, Category, Land } from "../net/protocol";
import { MapScene } from "./map";
import { QuestScene } from "./quest";
import { t } from "../i18n";

function verdictText(v: Attempt["verdict"]): string {
  return t(`result.${v}` as "result.accepted");
}

export class ResultScene implements Scene {
  readonly name = "result";
  readonly mood = "result" as const;
  private t = 0;
  private readonly buttons = new Buttons();

  /**
   * The headline for this attempt.
   *
   * Go has no runner until the next milestone, and the server reports that as
   * an internal error because from its side it *is* one. Repeating that word
   * to the player would teach them to distrust a server that is working
   * exactly as built, so the one case we know about is named honestly.
   */
  private verdictWord(): string {
    if (this.attempt.verdict === "internal_error" && this.land === "go") {
      return t("result.unavailable");
    }
    return verdictText(this.attempt.verdict);
  }
  private confetti: Plan | null = null;

  /**
   * The verdict is a sequence, not a screen that appears. Word, then stars one
   * at a time, then the stamp coming down, then the panel of detail. Each
   * beat is on the arrival curve and each waits for the one before it, which
   * is what turns four facts into a moment.
   */
  private readonly word = new Tween(seconds("verdict"));
  private readonly starIn: Tween[] = [];
  private readonly stamp = new Tween(seconds("stamp"), seconds("verdict") * 0.55);
  private readonly detail = new Tween(seconds("panel"), seconds("verdict") * 0.4);
  private stampRung = false;
  private shook = false;
  /**
   * Hit-stop: seconds of the verdict sequence that are simply not played.
   *
   * The stamp travels, and then everything on the screen stands still for an
   * eighth of a second before it lands. It is the oldest trick in a fighting
   * game and it works for the same reason here — the pause is what tells the
   * eye that something is about to be *hit*, and without it the stamp arrives
   * smoothly and lands like a sticker.
   */
  private hold = 0;
  private held = false;

  /**
   * How hard the screen is hit by each way of being wrong.
   *
   * Scaled, not uniform. A program that would not compile is a wall; a wrong
   * answer on case 3 of 8 is a near miss, and shaking the screen equally for
   * both teaches the player nothing about which one they are looking at.
   */
  private trauma(): number {
    switch (this.attempt.verdict) {
      case "compile_error":
        return 0.85;
      case "runtime_error":
        return 0.75;
      case "timeout":
      case "output_limit":
        return 0.5;
      case "wrong_answer":
        return 0.42;
      default:
        // `internal_error` in the Go land is this milestone being honest about
        // itself, not the player failing at anything. It gets no impact.
        return this.land === "go" ? 0 : 0.35;
    }
  }

  constructor(
    private readonly app: App,
    readonly land: Land,
    readonly category: Category,
    readonly questId: string,
    readonly attempt: Attempt,
    /** The source that produced this verdict, carried back to TRY AGAIN. */
    private readonly source?: string,
  ) {}

  enter(): void {
    for (let i = 0; i < 3; i++) {
      this.starIn.push(
        new Tween(seconds("star"), seconds("verdict") * 0.35 + seconds("starStagger") * i),
      );
    }
    if (this.passed) {
      const { vw, vh } = this.app.layout;
      this.confetti = burstPlan(vw / 2, vh * 0.35, 90);
    }
  }

  /**
   * `Attempt.cleared` means "did *this* submission clear the node" (§5.4), so
   * a re-solve comes back accepted with `cleared: false`. The screen keys its
   * colour off the verdict and its fanfare off `cleared`.
   */
  private get passed(): boolean {
    return this.attempt.verdict === "accepted";
  }

  update(dt: number): void {
    this.t += dt;
    // The freeze eats the frame's time rather than the frame: the loop keeps
    // running, the screen keeps being drawn, and the sequence stands still.
    if (this.hold > 0) {
      this.hold -= dt;
      return;
    }
    this.word.update(dt);
    this.stamp.update(dt);
    this.detail.update(dt);
    for (const t of this.starIn) t.update(dt);
    // The chip and the glow fire on the frame the stamp lands, not on entry —
    // a fanfare that plays before the thing it is celebrating arrives is just
    // a noise.
    if (!this.stampRung && this.passed && this.stamp.raw >= 1) {
      this.stampRung = true;
      this.app.backdrop?.pulse(this.attempt.cleared ? 0xf8d030 : 0x50d8f8);
      // The stamp is an impact. It gets a small one of its own, in the same
      // currency as the failures, so a clear is not the only thing on this
      // screen with no weight.
      this.app.shake(0.3);
    }
    // A breath held just short of the landing.
    if (!this.held && this.passed && this.stamp.raw >= 0.8) {
      this.held = true;
      this.hold = 0.13;
    }
    // The hit lands with the word — but not before the screen has finished
    // arriving. The scene change is itself a movement across the whole frame,
    // and a shake underneath it is simply not visible: the first take of this
    // caught the result panel still sliding in and nothing read as impact at
    // all. So it waits for the transition to be over and then hits.
    if (!this.shook && !this.passed && this.word.raw >= 0.5 && this.t >= seconds("scene")) {
      this.shook = true;
      this.app.shake(this.trauma());
    }
  }

  key(name: string): void {
    if (name === "escape" || name === "return" || name === "kpenter") this.toMap();
    if (name === "r") this.retry();
  }

  controls(): Buttons[] {
    return [this.buttons];
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
    void this.app.go(new MapScene(this.app, this.land, this.category), "back");
  }

  private retry(): void {
    // With their code, not with the starter: "try again" means try this again.
    void this.app.go(
      new QuestScene(this.app, this.land, this.category, this.questId, this.source),
      "back",
    );
  }

  /** What the verdict plate needs, before it is drawn. */
  private leftHeight(s: number, fonts: ReturnType<typeof ensureFonts>, ok: boolean): number {
    const rows = 3 + (this.attempt.exit_code ? 1 : 0);
    return (
      Math.round(52 * s) +
      fonts.stamp.height +
      (ok ? Math.round(52 * s) + Math.min(Math.round(300 * s) * 0.42, 128 * s) : 0) +
      rows * fonts.small.height +
      Math.round(30 * s) +
      fonts.stationSm.height
    );
  }

  /**
   * What the case table needs. It mirrors the arithmetic in `draw` rather than
   * sharing it, because the drawing walks the same list in the same order —
   * the pair is checked by eye on the two screens it produces.
   */
  private rightHeight(s: number, fonts: ReturnType<typeof ensureFonts>): number {
    let h = Math.round(52 * s);
    const rowH = Math.max(fonts.small.height, fonts.stationSm.height);
    for (const c of this.attempt.cases) {
      h += fonts.small.height;
      if (c.visible && !c.passed) h += rowH * 2 + Math.round(32 * s);
    }
    if (this.attempt.mistakes.length > 0) {
      h += fonts.stationSm.height + Math.round(14 * s);
      h += this.attempt.mistakes.length * (fonts.small.height + fonts.codeSm.height);
    }
    if (this.attempt.stderr) h += fonts.codeSm.height * 2 + Math.round(8 * s);
    return h;
  }

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    const ok = this.passed;
    const accent = this.land === "rust" ? RUST : GO;
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    header(
      g,
      this.app,
      this.attempt.cleared
        ? t("result.streetCleared")
        : ok
          ? t("result.stillGood")
          : t("result.notYet"),
    );
    const full = frame(layout, 0.42, 0.05);
    // Sized to what is on it. A 50/50 split stretched to the window, holding
    // five short rows on one side and one line on the other, reads as a screen
    // that has not been finished rather than as one that is breathing.
    const want = Math.max(this.leftHeight(s, fonts, ok), this.rightHeight(s, fonts));
    const h = Math.min(full.body[3], Math.max(want, Math.round(full.body[3] * 0.45)));
    const dy = layout.isPortrait() ? 0 : Math.round((full.body[3] - h) / 2);
    const f: typeof full = layout.isPortrait()
      ? full
      : {
          ...full,
          left: [full.left[0], full.left[1] + dy, full.left[2], h],
          right: [full.right[0], full.right[1] + dy, full.right[2], h],
        };
    this.buttons.reset();

    // --- the verdict plate --------------------------------------------------
    const left = titledPanel(g, f.left, t("result.verdict"), ok ? Theme.admit : Theme.red);
    let y = left[1];
    // Half the size it was. The coloured title bar above already carries the
    // verdict, so a 40px headline was saying it a second time and pushing the
    // thing the player actually needs — what went wrong — down the screen.
    const wordFont = fonts.stamp;
    const wordScale = 1 + (1 - this.word.out) * 1.4;
    g.save();
    g.globalAlpha = Math.min(1, this.word.raw * 2);
    g.translate(left[0] + left[2] / 2, y + wordFont.height / 2);
    g.scale(wordScale, wordScale);
    g.translate(-(left[0] + left[2] / 2), -(y + wordFont.height / 2));
    // A win gets the ribbon behind its word: in this register a headline is
    // framed or it is not a headline. A failure does not — a banner around
    // "WRONG ANSWER" would be celebrating it.
    const ribbon = ok ? (this.app.assets?.picture("fx_ribbon") ?? null) : null;
    if (ribbon) {
      // Sized to the word, not to the column. The cloth between the sprite's
      // two tails is about two thirds of its width, so a banner cut to the
      // column leaves the word hanging off both ends of its own ribbon.
      const rw = Math.min(left[2], width(wordFont, this.verdictWord()) / 0.6 + 24);
      const rh = (rw * ribbon.naturalHeight) / ribbon.naturalWidth;
      g.drawImage(ribbon, left[0] + (left[2] - rw) / 2, y + wordFont.height / 2 - rh / 2, rw, rh);
    }
    g.fillStyle = css(ribbon ? Theme.ink : ok ? Theme.admit : Theme.red);
    const lines = printf(g, wordFont, this.verdictWord(), left[0], y, left[2], "center");
    g.restore();
    y += lines * wordFont.height;
    y += Math.round(10 * s);

    if (ok) {
      const r = Math.round(11 * s);
      for (let i = 0; i < 3; i++) {
        const pop = this.starIn[i]?.out ?? 1;
        if (pop <= 0.001) continue;
        starAt(
          g,
          left[0] + left[2] / 2 - Math.round(24 * s) + i * r * 2.4,
          y + Math.round(14 * s),
          r * pop,
          i < this.attempt.stars ? Theme.coin : Theme.dim,
        );
      }
      // The medal is for three of three and nothing else. An award handed out
      // for every pass is not an award.
      const medal = this.attempt.stars >= 3 ? (this.app.assets?.picture("fx_medal") ?? null) : null;
      if (medal) {
        const d = Math.round(46 * s);
        g.drawImage(medal, left[0] + left[2] / 2 + Math.round(44 * s), y - d * 0.2, d, d);
      }
      y += Math.round(38 * s);
      // Three times the size, falling to one: a stamp is an impact, and expo
      // spends almost all of its time at the two ends of that.
      //
      // It gets its own row. Landing it on the stars was the review's point:
      // the payoff of the loop read as a collision between two of its parts.
      const stampW = Math.min(left[2] * 0.42, 128 * s);
      const land = this.stamp.out;
      if (this.stamp.raw > 0) {
        g.save();
        g.globalAlpha = Math.min(1, this.stamp.raw * 3);
        const cx = left[0] + left[2] / 2;
        const cy = y + stampW / 2;
        const k = 1 + (1 - land) * 2;
        g.translate(cx, cy);
        g.scale(k, k);
        g.translate(-cx, -cy);
        clearedStamp(g, this.app, cx, cy, stampW, -0.12 - (1 - land) * 0.5);
        g.restore();
      }
      y += stampW + Math.round(14 * s);
    }

    // Four facts, and only the ones that are facts about *this* run. `exit`
    // appears when it is not zero, because on a screen whose headline is that
    // something went wrong, "exit 0" is noise that contradicts the headline.
    const rows = [
      `${t("result.tests")}   ${this.attempt.tests_passed}/${this.attempt.tests_total}`,
      `${t("result.compileMs")} ${this.attempt.compile_ms} ms`,
      `${t("result.runMs")}     ${this.attempt.run_ms} ms`,
    ];
    if (this.attempt.exit_code !== null && this.attempt.exit_code !== 0) {
      rows.push(`${t("result.exit")}    ${this.attempt.exit_code}`);
    }
    g.fillStyle = css(Theme.cream);
    printf(g, fonts.small, rows.join("\n"), left[0], y, left[2], "left");

    // The attempt id is a log handle, not a result. It sits at the foot of the
    // panel in the smallest type on the screen, where somebody who needs it can
    // find it and nobody else has to read it at the moment of winning.
    g.fillStyle = css(Theme.dim);
    printf(
      g,
      fonts.stationSm,
      this.attempt.id,
      left[0],
      left[1] + left[3] - fonts.stationSm.height,
      left[2],
      "left",
    );

    // --- what went wrong ----------------------------------------------------
    const right = titledPanel(
      g,
      f.right,
      ok ? t("result.theRun") : t("result.whatWentWrong"),
      accent,
    );
    clipped(g, right[0], right[1], right[2], right[3], () => {
      let ry = right[1];
      const lineH = fonts.small.height;

      for (const c of this.attempt.cases) {
        g.fillStyle = css(c.passed ? Theme.admit : Theme.red);
        printf(
          g,
          fonts.small,
          `${c.passed ? t("result.pass") : t("result.fail")}  ${c.name}`,
          right[0],
          ry,
          right[2],
          "left",
        );
        ry += lineH;
        // Hidden cases report pass/fail and nothing else (SPEC §5.2), so there
        // is deliberately no `else` branch printing the data.
        //
        // This pair *is* the failure. It used to be set in the dimmest colour
        // on the screen, smaller than the decoration above it, which meant the
        // screen shouted that something had happened and whispered what.
        if (c.visible && !c.passed) {
          const want = JSON.stringify(c.expect ?? "");
          const got = JSON.stringify(c.got ?? "");
          const labelW = width(fonts.stationSm, t("result.expected")) + Math.round(10 * s);
          const rowH = Math.max(fonts.small.height, fonts.stationSm.height);
          const wellH = rowH * 2 + Math.round(24 * s);
          well(g, right[0], ry, right[2], wellH);
          const tx = right[0] + Math.round(10 * s);
          const ty = ry + Math.round(10 * s);
          const tw = right[2] - Math.round(20 * s);
          g.fillStyle = css(Theme.dim);
          printf(
            g,
            fonts.stationSm,
            t("result.expected"),
            tx,
            ty + Math.round(4 * s),
            labelW,
            "left",
          );
          printf(
            g,
            fonts.stationSm,
            t("result.got"),
            tx,
            ty + rowH + Math.round(4 * s),
            labelW,
            "left",
          );
          g.fillStyle = css(Theme.cream);
          printf(g, fonts.small, want, tx + labelW, ty, tw - labelW, "left");
          // The one that is wrong is the one that is coloured.
          g.fillStyle = css(Theme.red);
          printf(g, fonts.small, got, tx + labelW, ty + rowH, tw - labelW, "left");
          ry += wellH + Math.round(8 * s);
        }
      }

      if (this.attempt.mistakes.length > 0) {
        ry += Math.round(8 * s);
        g.fillStyle = css(Theme.coin);
        // The taxonomy carries more than compiler diagnostics — a wrong answer
        // lands here too — so the heading has to match what is under it.
        const heading =
          this.attempt.verdict === "compile_error"
            ? t("result.compilerWords")
            : t("result.runnerSaw");
        printf(g, fonts.stationSm, heading, right[0], ry, right[2], "left");
        ry += fonts.stationSm.height + Math.round(6 * s);
        for (const m of this.attempt.mistakes) {
          g.fillStyle = css(Theme.pink);
          printf(
            g,
            fonts.small,
            `${m.kind}${m.code ? ` (${m.code})` : ""}`,
            right[0],
            ry,
            right[2],
            "left",
          );
          ry += lineH;
          g.fillStyle = css(Theme.cream);
          ry +=
            printf(g, fonts.codeSm, m.message, right[0], ry, right[2], "left") *
            fonts.codeSm.height;
        }
      }

      if (this.attempt.stderr) {
        ry += Math.round(8 * s);
        g.fillStyle = css(Theme.red);
        ry +=
          printf(g, fonts.codeSm, this.attempt.stderr, right[0], ry, right[2], "left") *
          fonts.codeSm.height;
      }
    });

    this.drawConfetti(g);

    const btnRect: Rect = [
      f.body[0],
      layout.vh -
        Math.round(26 * s) -
        Math.max(layout.minTouchH(), fonts.button.height + 20) -
        Math.round(6 * s),
      f.body[2],
      Math.max(layout.minTouchH(), fonts.button.height + 20),
    ];
    fill(g, Theme.void, btnRect[0], btnRect[1] - 4, btnRect[2], btnRect[3] + 8, 0.8);
    this.buttons.row(
      fonts.button,
      btnRect,
      [
        { id: "retry", label: ok ? t("result.again") : t("result.tryAgain") },
        { id: "map", label: t("result.backToMap") },
      ],
      layout.minTouchH(),
    );
    this.buttons.draw(g, fonts.button);
    footer(g, layout, t("result.footer"));
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
