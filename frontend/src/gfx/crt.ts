/**
 * The tube.
 *
 * Ported in spirit from `CausewaybayGolang/love2d/src/crt.lua`, which is nine
 * lines: a dark line every other row, and one soft bright bar rolling down the
 * screen. That restraint is the whole trick — a heavy CRT filter reads as an
 * Instagram preset, and a light one reads as a television.
 *
 * Three things are added to the Lua, all of them because this runs in a browser
 * window rather than on a fixed 720p canvas:
 *
 *   - **The mask is a pattern, not four hundred `fillRect`s.** A 1×n tile is
 *     built once and stamped across the frame in a single fill. At 1600×900 the
 *     loop version is a measurable slice of a 16ms budget and this is not.
 *   - **A vignette**, cached on resize, because `createRadialGradient` per frame
 *     costs more than the gradient does.
 *   - **The scanline period follows the layout scale**, so the lines stay two
 *     *virtual* pixels apart — the same distance from the art's point of view
 *     whether the window is 800 or 2560 across.
 *
 * What it deliberately does not do is touch the editor. It is drawn onto
 * `#game`, and the DOM overlay that holds CodeMirror and the seed field is
 * stacked above `#game` by the stylesheet. The editor's glyphs are structurally
 * out of reach of this pass — not by a rule somebody has to remember, by the
 * z-order.
 *
 * No barrel distortion. Warping the frame means resampling the whole canvas
 * every frame on the CPU, and the thing it would bend most is the one thing
 * that has to stay straight: eighty columns of code.
 */
import { reducedMotion } from "../engine/motion";

/** How dark the mask rows are. The Lua uses 0.10 and it is right. */
const MASK = 0.1;
/** Rolling bar: virtual pixels per second, and how tall it is. */
const ROLL_SPEED = 36;
const ROLL_H = 6;

export class Crt {
  /** On by default. The player can turn it off and that choice is kept. */
  enabled = true;

  private t = 0;
  private pattern: CanvasPattern | null = null;
  private period = 0;
  private vignette: CanvasGradient | null = null;
  private vw = 0;
  private vh = 0;

  update(dt: number): void {
    this.t += dt;
  }

  /** Throw the cached gradient away; the next frame rebuilds it. */
  resized(): void {
    this.vignette = null;
  }

  /**
   * @param g the 2D context, in **device** coordinates with no transform.
   * @param dw,dh the backing store size.
   * @param scale device pixels per virtual pixel, from `Layout`.
   */
  draw(g: CanvasRenderingContext2D, dw: number, dh: number, scale: number): void {
    if (!this.enabled || dw < 4 || dh < 4) return;
    const period = Math.max(2, Math.round(2 * scale));
    if (period !== this.period || !this.pattern) this.buildMask(g, period);
    if (!this.vignette || dw !== this.vw || dh !== this.vh) this.buildVignette(g, dw, dh);

    g.save();
    if (this.pattern) {
      g.fillStyle = this.pattern;
      g.fillRect(0, 0, dw, dh);
    }
    if (this.vignette) {
      g.fillStyle = this.vignette;
      g.fillRect(0, 0, dw, dh);
    }
    // The roll. Someone who asked for less motion still gets the tube, just
    // without a bar travelling down it — the bar is the only part of this that
    // moves, so it is the only part that has to answer for itself.
    if (!reducedMotion()) {
      const span = dh + ROLL_H * scale * 2;
      const y = ((this.t * ROLL_SPEED * scale) % span) - ROLL_H * scale;
      g.fillStyle = "rgba(248,208,48,0.04)";
      g.fillRect(0, y, dw, ROLL_H * scale);
    }
    g.restore();
  }

  private buildMask(g: CanvasRenderingContext2D, period: number): void {
    const tile = document.createElement("canvas");
    tile.width = 1;
    tile.height = period;
    const t = tile.getContext("2d");
    if (!t) return;
    t.fillStyle = `rgba(0,0,0,${MASK})`;
    t.fillRect(0, 0, 1, Math.max(1, Math.floor(period / 2)));
    this.pattern = g.createPattern(tile, "repeat");
    this.period = period;
  }

  private buildVignette(g: CanvasRenderingContext2D, dw: number, dh: number): void {
    const r = Math.hypot(dw, dh) * 0.5;
    const grad = g.createRadialGradient(dw / 2, dh / 2, r * 0.45, dw / 2, dh / 2, r);
    grad.addColorStop(0, "rgba(0,0,0,0)");
    grad.addColorStop(1, "rgba(4,2,12,0.42)");
    this.vignette = grad;
    this.vw = dw;
    this.vh = dh;
  }
}
