/**
 * The tube covers the whole window, whatever transform the caller left behind.
 *
 * This is a regression test for a fault that was on screen for several rounds
 * and was reported as "a dark rectangle roughly 0.6 x 0.6 of the canvas in the
 * top-left of `#game` after an orientation change".
 *
 * `App.render` finishes with the context in *virtual* coordinates. `Crt.draw`
 * fills `(0, 0, dw, dh)` with `dw`/`dh` in *device* pixels, so under the
 * virtual transform `(s,0,0,s,ox,oy)` it covered the device rectangle
 * `[ox, ox + dw·s] x [oy, oy + dh·s]` — a patch exactly `scale` by `scale` of
 * the canvas — and left the rest of the window untreated. At the design size
 * `scale` is 1, the two rectangles coincide, and nothing is visible; the bug
 * only appears when a layout is put into a window it does not fit, which is
 * precisely what an orientation change does.
 *
 * So the assertion is not "it looks right". It is: the device rectangle the
 * tube fills does not depend on the transform it was handed, and it is the
 * whole backing store.
 */
import { describe, expect, it } from "vitest";
import { Crt } from "../src/gfx/crt";

type Rect = { x: number; y: number; w: number; h: number };

/**
 * A 2D context that remembers where a fill actually landed.
 *
 * Only the six-number affine form is needed: nothing in this file rotates or
 * skews, and a fake that pretended to would be testing the fake.
 */
function fakeCtx() {
  let m = [1, 0, 0, 1, 0, 0];
  const stack: number[][] = [];
  const rects: Rect[] = [];
  const ctx = {
    fillStyle: "" as string | CanvasPattern | CanvasGradient,
    save() {
      stack.push(m.slice());
    },
    restore() {
      m = stack.pop() ?? m;
    },
    setTransform(a: number, b: number, c: number, d: number, e: number, f: number) {
      m = [a, b, c, d, e, f];
    },
    translate(x: number, y: number) {
      m[4] += m[0] * x;
      m[5] += m[3] * y;
    },
    fillRect(x: number, y: number, w: number, h: number) {
      rects.push({ x: m[0] * x + m[4], y: m[3] * y + m[5], w: m[0] * w, h: m[3] * h });
    },
    createPattern: () => ({}) as CanvasPattern,
    createRadialGradient: () => ({ addColorStop() {} }) as unknown as CanvasGradient,
  };
  return {
    g: ctx as unknown as CanvasRenderingContext2D,
    rects,
    /** Put the context into the virtual coordinates `App.render` leaves behind. */
    virtual(scale: number, ox: number, oy: number) {
      m = [scale, 0, 0, scale, ox, oy];
    },
    transform: () => m.slice(),
  };
}

/** The device rectangle every full-canvas pass of the tube covered. */
function passes(scale: number, ox: number, oy: number, dw: number, dh: number): Rect[] {
  const crt = new Crt();
  crt.update(0.4);
  const f = fakeCtx();
  f.virtual(scale, ox, oy);
  const before = f.transform();
  crt.draw(f.g, dw, dh, scale);
  // The caller's transform is the caller's: an overlay that left the identity
  // behind would break whatever `App.render` draws after it.
  expect(f.transform()).toEqual(before);
  return f.rects;
}

describe("the tube", () => {
  it("covers the whole backing store whatever transform it is handed", () => {
    // 1280x800 turned to portrait: scale 0.625, a 302px band down each side.
    // Before the fix the first fill landed at (302, 0, 800, 500) — the 0.63 by
    // 0.63 patch in the report.
    const rects = passes(0.625, 302, 0, 1280, 800);
    expect(rects.length).toBeGreaterThan(0);
    expect(rects[0]).toEqual({ x: 0, y: 0, w: 1280, h: 800 });
  });

  it("fills the same device rectangle at every scale", () => {
    const shapes: Array<[number, number, number]> = [
      [1, 0, 0],
      [0.625, 302, 0],
      [0.84375, 0, 419],
      [2, 0, 0],
    ];
    for (const [scale, ox, oy] of shapes) {
      const rects = passes(scale, ox, oy, 1080, 1750);
      expect(rects[0]).toEqual({ x: 0, y: 0, w: 1080, h: 1750 });
    }
  });

  it("spans the full width with every pass it makes", () => {
    for (const r of passes(0.625, 302, 0, 1280, 800)) {
      // The rolling bar is a band rather than a fill, so its height is its
      // own; its width is the window's, and so is everything else's.
      expect(r.x).toBe(0);
      expect(r.w).toBe(1280);
    }
  });

  it("draws nothing at all when it is switched off", () => {
    const crt = new Crt();
    crt.enabled = false;
    const f = fakeCtx();
    f.virtual(0.625, 302, 0);
    crt.draw(f.g, 1280, 800, 0.625);
    expect(f.rects).toEqual([]);
  });
});
