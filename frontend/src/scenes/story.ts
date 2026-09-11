/**
 * The attract sequence.
 *
 * Every cabinet in the era told you what the game was before you put a coin in,
 * and it told you in five slides over the artwork, not in a cutscene. This is
 * that: the opening of `docs/story.md` §2, in its own sentences, over three of
 * the painted backgrounds, typed a character at a time.
 *
 * Three rules it is built to:
 *
 *   - **It must never stand between a returning player and their work.** Any
 *     key, any click, at any point, goes straight to the login screen. The skip
 *     is checked before anything else in `key()` and `pointer()` and it is real:
 *     there is no beat during which the input is swallowed, because there is no
 *     state in here that has to finish. (`App` forwards keys to the scene unless
 *     the DOM overlay has focus, and this screen never creates an overlay
 *     element, so there is nothing that can eat the first keystroke.)
 *   - **It does not spoil the map.** §2 only. The two lands, the mascots, the
 *     antagonists and the shape of the thing are all in §3 and later, and none
 *     of it is here. This is the loss and the reason, which is what an opening
 *     is for.
 *   - **It ends, and it ends at the logo.** It is not a loop. A title screen
 *     that spontaneously animates away while somebody is typing twelve words
 *     into the seed field is a bug with a nice name, and the new-wallet gate
 *     makes that window long. So it plays once from boot when there is no
 *     session, finishes on the logo, and hands over. `WATCH AGAIN` on the login
 *     screen replays it on purpose.
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf, width, wrap } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { clipped, fill, neonPrint, type Ctx } from "../engine/ui";
import { footer, RUST } from "../ui/chrome";
import { expInOut, expOut } from "../engine/ease";
import { reducedMotion, seconds, Tween } from "../engine/motion";
import { LoginScene } from "./login";
import { markStorySeen } from "./title";
import { t } from "../i18n";

/** How a beat arrives over the one before it. */
type Cut = "fade" | "iris";

interface Beat {
  bg: string;
  lines: string[];
  /** Seconds the finished panel stays up before the next cut. */
  hold: number;
  cut: Cut;
  /** The colour the type is set in. Skynet gets the cold one. */
  cold?: boolean;
  /** Fire the sting on the frame this beat's first character is typed. */
  sting?: boolean;
}

/**
 * The opening, verbatim from `docs/story.md` §2 and in its order.
 *
 * Nothing here is written for the game; it is the bible's own sentences, split
 * at the points they were already punctuated at. If the story changes, it
 * changes there and is copied here — the voice is the asset and it is not
 * paraphrased on the way to the screen.
 */
/**
 * The opening, from `docs/story.md` §2 and in its order.
 *
 * The English is the bible's own sentences, split at the points they were
 * already punctuated at — the voice is the asset and it is not paraphrased on
 * the way to the screen. The other five languages are translations of *those*
 * sentences and are held to the same rule: the register is a person telling
 * you what happened, not marketing copy.
 *
 * The keys are indexed by beat and line so a translator can see the shape of
 * the panel they are writing into. A beat is two or three lines because that
 * is what fits the quiet lower fifth every one of these paintings was composed
 * with; a translation that runs to five lines would push the caption box up
 * over the art, which is why `panelRect` measures rather than assumes.
 */
const BEATS = (): Beat[] => [
  {
    bg: "open_flat",
    cut: "fade",
    hold: 1.4,
    lines: [t("story.1.1"), t("story.1.2")],
  },
  {
    bg: "open_cursor",
    cut: "fade",
    hold: 1.5,
    lines: [t("story.2.1"), t("story.2.2")],
  },
  {
    bg: "open_ghost",
    cut: "fade",
    hold: 1.7,
    lines: [t("story.3.1"), t("story.3.2")],
  },
  {
    bg: "open_face",
    cut: "fade",
    hold: 1.9,
    lines: [t("story.4.1"), t("story.4.2")],
  },
  {
    bg: "open_tills",
    cut: "fade",
    hold: 1.6,
    lines: [t("story.5.1"), t("story.5.2")],
  },
  {
    bg: "bg_datacentre",
    cut: "iris",
    hold: 1.9,
    cold: true,
    sting: true,
    lines: [t("story.6.1"), t("story.6.2"), t("story.6.3")],
  },
  {
    bg: "open_stairs",
    cut: "iris",
    hold: 1.6,
    lines: [t("story.7.1"), t("story.7.2")],
  },
  {
    bg: "open_lands",
    cut: "fade",
    hold: 1.8,
    lines: [t("story.8.1")],
  },
];

/** How many beats there are. Fixed, and independent of the language. */
const BEAT_COUNT = 8;

/** Characters a second. Fast enough to read with, slow enough to be typing. */
const CPS = 46;
/** How long a cut takes. */
const CUT = 0.62;
/** How long the logo card is held at the end before the login screen. */
const LOGO_HOLD = 2.6;

export class StoryScene implements Scene {
  readonly name = "story";
  readonly mood = "title" as const;

  private i = 0;
  private t = 0;
  /** Seconds into the current beat, including its cut. */
  private beatT = 0;
  private typed = 0;
  /** When the last character landed, in beat seconds. Negative until it has. */
  private finishedAt = -1;
  private stung = false;
  private leaving = false;
  private lastTick = 0;
  private readonly logoIn = new Tween(seconds("scene"));

  /**
   * @param replay true when the player asked for it from the login screen, in
   * which case leaving goes *back* to where they came from rather than forward
   * into a screen they have never seen.
   */
  constructor(
    private readonly app: App,
    private readonly replay = false,
  ) {}

  enter(): void {
    this.app.chip.music("title");
    // The three paintings are lazily fetched backgrounds. Asking for all of
    // them on the first frame means the cut to the datacentre is a cut and not
    // a black rectangle with type on it.
    for (const b of BEATS()) this.app.assets?.prefetch(b.bg, this.app.layout.isPortrait());
  }

  leave(): void {
    this.app.chip.music("stop");
  }

  // -- the skip ------------------------------------------------------------

  /**
   * Out, now, whatever is on screen.
   *
   * Guarded so that a key and a click in the same frame do not start two scene
   * changes; that is the only thing in here that could swallow an input, and it
   * cannot, because by the time it is set the screen is already leaving.
   */
  private out(): void {
    if (this.leaving) return;
    this.leaving = true;
    // Watched or skipped, it has had its chance: the title card hands a second
    // visit straight to the login screen rather than offering the opening
    // again. Skipping counts on purpose — somebody who pressed a key to get
    // out of it is exactly the person who must not be shown it twice.
    markStorySeen();
    void this.app.go(new LoginScene(this.app), this.replay ? "back" : "forward");
  }

  key(): void {
    this.out();
  }

  pointer(_x: number, _y: number, phase: "down" | "move" | "up"): void {
    if (phase === "down") this.out();
  }

  // -- the sequence --------------------------------------------------------

  private beat(): Beat | null {
    return this.i < BEAT_COUNT ? BEATS()[this.i] : null;
  }

  /** The beat's text, wrapped to the panel, as one flat list of lines. */
  private linesFor(b: Beat, w: number): string[] {
    const f = ensureFonts(this.app.layout.uiScale()).small;
    const out: string[] = [];
    for (const line of b.lines) out.push(...wrap(f, line, w));
    return out;
  }

  update(dt: number): void {
    this.t += dt;
    this.beatT += dt;
    const b = this.beat();
    if (!b) {
      this.logoIn.update(dt);
      // The logo is the end of the sequence, not a new loop of it. When it has
      // been up long enough the screen simply hands over.
      if (this.beatT > LOGO_HOLD + CUT) this.out();
      return;
    }
    if (this.beatT < CUT) return;

    const total = this.beatText(b).length;
    const before = Math.floor(this.typed);
    // Reduced motion does not mean "no story", it means "less performance":
    // the type lands four times faster and the holds are already scaled by
    // `seconds()` elsewhere. The words are still the point.
    this.typed = Math.min(total, this.typed + dt * CPS * (reducedMotion() ? 4 : 1));
    if (b.sting && !this.stung && this.typed > 0) {
      this.stung = true;
      this.app.chip.stinger();
    }
    // Every fourth character, not every character: a key click per glyph at
    // forty-six a second is a buzz, not typing.
    const now = Math.floor(this.typed);
    if (now > before && now - this.lastTick >= 4) {
      this.lastTick = now;
      this.app.chip.type();
    }
    if (this.typed >= total) {
      if (this.finishedAt < 0) this.finishedAt = this.beatT;
      // The hold is reading time, not animation, so it is *not* cut by the
      // reduced-motion scale. Somebody who asked for less movement asked for
      // less movement, not for three sentences to be taken away faster than
      // they can be read.
      if (this.beatT > this.finishedAt + b.hold) this.next();
    }
  }

  private next(): void {
    this.i++;
    this.beatT = 0;
    this.typed = 0;
    this.finishedAt = -1;
    this.stung = false;
    this.lastTick = 0;
  }

  private beatText(b: Beat): string {
    const { layout } = this.app;
    const s = layout.uiScale();
    const w = this.panelRect()[2] - Math.round(24 * s);
    return this.linesFor(b, w).join("\n");
  }

  /**
   * The caption box.
   *
   * Bottom-anchored, deliberately. Every one of the fourteen `open_*` panels was
   * composed with its **lower fifth left quiet** — plain floor, plain ground,
   * plain shadow — so that a caption has somewhere to live in both orientations
   * without covering the picture. A box measured down from a fraction of the
   * height would drift out of that band as the canvas grows; a box that grows
   * upward from a fixed foot stays in it.
   */
  private panelRect(): [number, number, number, number] {
    const { layout } = this.app;
    const s = layout.uiScale();
    const w = Math.min(layout.vw - Math.round(40 * s), Math.round(920 * s));
    const x = Math.round((layout.vw - w) / 2);
    const foot = layout.vh - Math.round(58 * s);
    const lines = this.beat() ? this.linesFor(this.beat() as Beat, w - Math.round(24 * s)) : [];
    const h = Math.max(
      Math.round(60 * s),
      lines.length * ensureFonts(s).small.height + Math.round(26 * s),
    );
    return [x, foot - h, w, h];
  }

  // -- drawing -------------------------------------------------------------

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    const s = layout.uiScale();
    const b = this.beat();
    const prev = this.i > 0 ? BEATS()[this.i - 1] : null;
    const cutT = Math.min(1, this.beatT / CUT);

    if (b) {
      // The outgoing painting stays until the incoming one has covered it, so
      // there is never a frame of nothing between two beats.
      if (prev && cutT < 1) this.drawBg(g, prev.bg, 1, 1);
      if (b.cut === "iris" && cutT < 1) {
        const reach = Math.hypot(layout.vw, layout.vh) * 0.55;
        const r = reach * expInOut(cutT);
        clipped(g, 0, 0, layout.vw, layout.vh, () => {
          g.save();
          g.beginPath();
          g.arc(layout.vw / 2, layout.vh * 0.42, r, 0, Math.PI * 2);
          g.clip();
          this.drawBg(g, b.bg, 1, this.ken());
          g.restore();
          if (r > 2) {
            g.strokeStyle = css(Theme.coin, 0.4);
            g.lineWidth = 2 * s;
            g.beginPath();
            g.arc(layout.vw / 2, layout.vh * 0.42, r, 0, Math.PI * 2);
            g.stroke();
            g.lineWidth = 1;
          }
        });
      } else {
        this.drawBg(g, b.bg, b.cut === "fade" ? expOut(cutT) : 1, this.ken());
      }
    } else {
      this.drawBg(g, "title_bg", 1, 0.2);
    }

    // A void gradient into the lower half, so type over a bright morning
    // street is type on something rather than type in front of something.
    // A light one. The panels were composed with a quiet lower fifth, so the
    // scrim only has to take the edge off it — anything heavier and the art
    // that was made for this sequence is behind a curtain.
    const grad = g.createLinearGradient(0, layout.vh * 0.52, 0, layout.vh);
    grad.addColorStop(0, "rgba(20,28,72,0)");
    grad.addColorStop(1, "rgba(20,28,72,0.72)");
    g.fillStyle = grad;
    g.fillRect(0, 0, layout.vw, layout.vh);

    if (b) this.drawPanel(g, b, cutT);
    else this.drawLogo(g);

    // The pips: where you are in five beats. A sequence with no visible end
    // is a sequence people skip on principle.
    const pipY = Math.round(layout.vh - 46 * s);
    const pipW = Math.round(14 * s);
    const pipsX = Math.round((layout.vw - (BEAT_COUNT + 1) * pipW) / 2);
    for (let k = 0; k <= BEAT_COUNT; k++) {
      fill(g, k === this.i ? Theme.coin : Theme.dim, pipsX + k * pipW, pipY, Math.round(8 * s), 3);
    }

    footer(g, layout, layout.touch ? t("story.skipTap") : t("story.skipKey"));
  }

  /** Slow push, dt-driven. Zero for anyone who asked for less of it. */
  private ken(): number {
    if (reducedMotion()) return 0;
    return Math.min(1, this.beatT / 7);
  }

  private drawBg(g: Ctx, name: string, alpha: number, ken: number): void {
    const { layout } = this.app;
    const img = this.app.assets?.picture(name, layout.isPortrait());
    if (!img) {
      fill(g, Theme.navy, 0, 0, layout.vw, layout.vh, alpha);
      return;
    }
    const zoom = 1 + ken * 0.07;
    const scale = Math.max(layout.vw / img.naturalWidth, layout.vh / img.naturalHeight) * zoom;
    const aw = img.naturalWidth * scale;
    const ah = img.naturalHeight * scale;
    g.save();
    g.globalAlpha = alpha;
    clipped(g, 0, 0, layout.vw, layout.vh, () =>
      g.drawImage(img, (layout.vw - aw) / 2, (layout.vh - ah) / 2 - ken * 6, aw, ah),
    );
    g.restore();
  }

  private drawPanel(g: Ctx, b: Beat, cutT: number): void {
    const { layout } = this.app;
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    const [x, y, w] = this.panelRect();
    const inner = w - Math.round(24 * s);
    const lines = this.linesFor(b, inner);
    const lh = fonts.small.height;
    const h = this.panelRect()[3];

    // The plate itself arrives with the cut rather than after it, so the beat
    // is one movement instead of a picture and then a box.
    const k = expOut(cutT);
    g.save();
    g.globalAlpha = k;
    g.translate(0, (1 - k) * Math.round(18 * s));
    fill(g, Theme.ink, x, y, w, h, 0.82);
    fill(g, b.cold ? Theme.cyan : Theme.coin, x, y, Math.round(4 * s), h);
    fill(g, Theme.dim, x, y + h - 1, w, 1, 0.5);

    let left = Math.floor(this.typed);
    let ly = y + Math.round(13 * s);
    const colour = b.cold ? Theme.cyan : Theme.cream;
    for (const line of lines) {
      const take = Math.max(0, Math.min(line.length, left));
      const shown = line.slice(0, take);
      left -= line.length + 1;
      if (shown) {
        g.fillStyle = css(colour);
        printf(g, fonts.small, shown, x + Math.round(14 * s), ly, inner, "left");
      }
      // The caret sits at the end of whatever is being typed right now, and
      // blinks on the beat clock — never on `Date.now()`, or a captured frame
      // would differ from run to run.
      if (take > 0 && take < line.length) {
        const cw = width(fonts.small, shown);
        if (Math.floor(this.beatT * 3) % 2 === 0) {
          fill(
            g,
            colour,
            x + Math.round(14 * s) + cw,
            ly + Math.round(2 * s),
            Math.round(7 * s),
            lh - Math.round(6 * s),
          );
        }
      }
      ly += lh;
    }
    g.restore();
  }

  private drawLogo(g: Ctx): void {
    const { layout } = this.app;
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    const k = this.logoIn.out;
    const cy = Math.round(layout.vh * 0.38);
    g.save();
    g.globalAlpha = Math.min(1, this.logoIn.raw * 2);
    g.translate(0, (1 - k) * Math.round(20 * s));
    neonPrint(
      g,
      fonts.title,
      "CAUSEWAYBAY",
      cy - fonts.title.height,
      layout.vw,
      Theme.cyan,
      this.t,
    );
    neonPrint(
      g,
      fonts.title,
      "HACKER",
      cy + Math.round(fonts.title.height * 0.2),
      layout.vw,
      RUST,
      this.t + 0.6,
    );
    g.fillStyle = css(Theme.coin, 0.55 + 0.45 * Math.sin(this.t * 4));
    printf(
      g,
      fonts.stationSm,
      t("story.pressAnyKey"),
      0,
      Math.round(layout.vh * 0.62),
      layout.vw,
      "center",
    );
    g.restore();
  }
}
