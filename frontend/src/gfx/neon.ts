/**
 * The signs over the street, and the oldest trick in the 16-bit book.
 *
 * `neon_signs.png` is six vertical signs on one strip, and DESIGN drew them
 * that way on purpose: **each is a light tube colour over a darker face of the
 * same hue, and nothing else on the sprite carries hue at all.** Six frames
 * that differ only in colour is a palette, drawn out flat, and the thing you do
 * with a palette is cycle it.
 *
 * So the cycle here is not a filter and not a tint. Slot `k` on the rail is
 * drawn from a *different frame* of the one strip every beat, and the frames
 * are visited in the order of their measured hue rather than in the order they
 * were painted — 25°, 47°, 127°, 213°, 282°, 352° — so the colour travels along
 * the rail like a chase light instead of jumping about the wheel. That order is
 * the entire reason `art/palette.json` exists, and it is read from the file
 * rather than copied into this one: the numbers were measured out of the PNG
 * and they belong next to the PNG.
 *
 * Everything here is driven by accumulated `dt`. Nothing reads the wall clock,
 * so `__cwbCapture.settle(n)` gives the same frame every run.
 *
 * With no `palette.json` the rail still draws; the frames simply stay where
 * they are and the signs are six fixed colours, which is what the art is.
 */
import type { Assets } from "../engine/assets";
import { reducedMotion } from "../engine/motion";
import { css, Theme } from "../engine/theme";
import type { Ctx } from "../engine/ui";

/**
 * Where the six signs actually are on the strip, in source pixels.
 *
 * Measured off `art/neon_signs.png`, not divided out of its width: the signs
 * sit on a **79px pitch from x=28** and are 61 wide, while a naive
 * `512 / 6 = 85.33` grid walks two pixels further left on every frame and by
 * the sixth has sliced a tube in half. `palette.json`'s `fw: 85` is that naive
 * number and is not used for geometry here. The strip's own horizontal rails
 * are outside this window, which is what makes one frame substitutable for
 * another without a seam.
 */
const SIGN_X0 = 28;
const SIGN_PITCH = 79;
const SIGN_W = 61;
const SIGN_Y0 = 19;
const SIGN_H = 217;
const FRAMES = 6;

/** Seconds a colour stays in one slot. A cycle you can watch, not a strobe. */
const BEAT = 1.15;

export class NeonRail {
  private t = 0;
  /** Frame indices in hue order; identity until `palette.json` has landed. */
  private order: number[] | null = null;

  update(dt: number): void {
    this.t += dt;
  }

  /** The strip's frames, least hue first. Computed once, from the file. */
  private hueOrder(assets: Assets | null): number[] {
    if (this.order) return this.order;
    const p = assets?.palettes.get("neon_signs");
    const ids = p?.hues
      ?.slice()
      .sort((a, b) => a.hue_deg - b.hue_deg)
      .map((h) => h.i)
      .filter((i) => Number.isInteger(i) && i >= 0 && i < FRAMES);
    // Only trust a table that names every frame exactly once. A partial one is
    // worse than none: it would drop a sign off the rail.
    if (ids && ids.length === FRAMES && new Set(ids).size === FRAMES) this.order = ids;
    return this.order ?? [0, 1, 2, 3, 4, 5];
  }

  /**
   * Hang `count` signs across `x..x+w`, dropping from `y`.
   *
   * @param h how tall a sign is, in virtual pixels.
   * @param alpha the whole rail's strength, so a caller can fade it with
   * whatever it is hanging in front of.
   */
  draw(
    g: Ctx,
    assets: Assets | null,
    art: HTMLImageElement,
    x: number,
    y: number,
    w: number,
    h: number,
    count: number,
    alpha = 1,
  ): void {
    if (h < 6 || w < 20 || count < 1) return;
    const order = this.hueOrder(assets);
    const sw = (h * SIGN_W) / SIGN_H;
    const still = reducedMotion();
    // Which colour is in which slot. Integer, so the swap is a swap — a
    // crossfade would be a gradient, and a gradient is not a palette cycle.
    const step = Math.floor(this.t / BEAT);

    g.save();
    for (let k = 0; k < count; k++) {
      const cx = x + ((k + 0.5) * w) / count;
      // A slow pendulum, a different phase per sign, and none of it under
      // reduced motion — the signs then simply hang, which is what a sign in a
      // photograph does.
      const sway = still ? 0 : Math.sin(this.t * 0.55 + k * 1.7) * h * 0.012;
      const frame = order[(k + step) % FRAMES];
      // One sign gutters at a time, on the same beat as the colours. Neon that
      // is uniformly perfect reads as vector art.
      const gutter = !still && (step + k) % 7 === 3;
      const lit = gutter ? 0.45 + 0.3 * Math.abs(Math.sin(this.t * 21)) : 1;

      const sx = Math.round(cx - sw / 2 + sway);
      // The hanger: a short ink dropper from the wire to the sign's top, so the
      // sign is attached to something rather than floating.
      g.globalAlpha = alpha;
      g.fillStyle = css(Theme.ink, 0.75);
      g.fillRect(Math.round(cx + sway * 0.4) - 1, Math.round(y), 2, Math.round(h * 0.16) + 1);

      g.globalAlpha = alpha * lit;
      g.drawImage(
        art,
        SIGN_X0 + frame * SIGN_PITCH,
        SIGN_Y0,
        SIGN_W,
        SIGN_H,
        sx,
        Math.round(y + h * 0.16),
        Math.round(sw),
        Math.round(h),
      );
    }
    g.restore();
  }
}
