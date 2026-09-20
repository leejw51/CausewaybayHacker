/**
 * The clear celebration, checked without a canvas.
 *
 * What is worth pinning: that the plan is deterministic under a fixed rng
 * (the visual suite steps it and compares frames), that every streak stays
 * inside the reach it was given, that a head is bright at birth and gone at
 * the end of its life, that a tail is where the head *was* and never ahead
 * of it, and that the zoom and the count land exactly on their targets — a
 * number that settles on 149 when the server said 150 is a bug you can see.
 */
import { describe, expect, it } from "vitest";
import {
  celebrationPlan,
  cometAt,
  cometTrail,
  countUp,
  flashAlpha,
  zoomIn,
  zoomOut,
} from "../src/engine/celebrate";

/** A tiny LCG, so two plans from the same seed are the same plan. */
function rngFrom(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

describe("celebrationPlan", () => {
  it("is the same plan for the same seed, and a different one for another", () => {
    const a = celebrationPlan(400, 300, 260, 24, rngFrom(7));
    const b = celebrationPlan(400, 300, 260, 24, rngFrom(7));
    const c = celebrationPlan(400, 300, 260, 24, rngFrom(8));
    expect(a).toEqual(b);
    expect(a).not.toEqual(c);
  });

  it("makes as many comets as asked, spread round the whole circle", () => {
    const plan = celebrationPlan(0, 0, 200, 16, rngFrom(1));
    expect(plan.comets).toHaveLength(16);
    const angles = plan.comets.map((c) => ((c.a0 % (Math.PI * 2)) + Math.PI * 2) % (Math.PI * 2));
    // Four quadrants, none empty.
    for (let q = 0; q < 4; q++) {
      expect(angles.some((a) => a >= (q * Math.PI) / 2 && a < ((q + 1) * Math.PI) / 2)).toBe(true);
    }
  });

  it("keeps every streak inside its reach for its whole life", () => {
    const reach = 240;
    const plan = celebrationPlan(500, 400, reach, 32, rngFrom(3));
    for (const c of plan.comets) {
      expect(c.life).toBeGreaterThan(0);
      expect(c.delay).toBeGreaterThanOrEqual(0);
      for (let k = 0; k <= 40; k++) {
        const { x, y } = cometAt(c, (c.life * k) / 40);
        expect(Math.hypot(x - 500, y - 400)).toBeLessThanOrEqual(reach + 1e-6);
      }
    }
  });

  it("sends half the comets off at once so the burst has a leading edge", () => {
    const plan = celebrationPlan(0, 0, 200, 20, rngFrom(5));
    expect(plan.comets.filter((c) => c.delay === 0).length).toBe(10);
  });

  it("carries two rings and a flash", () => {
    const plan = celebrationPlan(10, 20, 100, 4, rngFrom(2));
    expect(plan.rings).toHaveLength(2);
    expect(plan.rings.every((r) => r.x === 10 && r.y === 20 && r.life > 0)).toBe(true);
    expect(plan.flash).toBeGreaterThan(0);
  });
});

describe("a comet's head", () => {
  const c = celebrationPlan(100, 100, 200, 1, rngFrom(9)).comets[0];

  it("is bright at birth, gone at the end, and dark before it sets off", () => {
    expect(cometAt(c, 0).alpha).toBe(1);
    expect(cometAt(c, c.life).alpha).toBe(0);
    expect(cometAt(c, -0.01).alpha).toBe(0);
    expect(cometAt(c, c.life + 0.01).alpha).toBe(0);
  });

  it("starts at the inner radius and ends at the outer one", () => {
    const at = (t: number) => {
      const { x, y } = cometAt(c, t);
      return Math.hypot(x - 100, y - 100);
    };
    expect(at(0)).toBeCloseTo(c.r0, 6);
    expect(at(c.life)).toBeCloseTo(c.r1, 6);
  });

  it("only ever moves outward", () => {
    let last = -1;
    for (let k = 0; k <= 50; k++) {
      const { x, y } = cometAt(c, (c.life * k) / 50);
      const r = Math.hypot(x - 100, y - 100);
      expect(r).toBeGreaterThanOrEqual(last - 1e-9);
      last = r;
    }
  });

  it("does most of its travel in the first third — the expo shape", () => {
    const r = (t: number) => {
      const { x, y } = cometAt(c, t);
      return Math.hypot(x - 100, y - 100);
    };
    const third = (r(c.life / 3) - c.r0) / (c.r1 - c.r0);
    expect(third).toBeGreaterThan(0.85);
  });
});

describe("a comet's tail", () => {
  const c = celebrationPlan(0, 0, 300, 1, rngFrom(11)).comets[0];

  it("ends at the head and reads oldest-first", () => {
    const age = 0.5;
    const pts = cometTrail(c, age, 8, 0.2);
    expect(pts).toHaveLength(8);
    const head = cometAt(c, age);
    expect(pts[7][0]).toBeCloseTo(head.x, 9);
    expect(pts[7][1]).toBeCloseTo(head.y, 9);
    // Each earlier point is where the head was earlier: no further out.
    let last = Infinity;
    for (let i = pts.length - 1; i >= 0; i--) {
      const r = Math.hypot(pts[i][0], pts[i][1]);
      expect(r).toBeLessThanOrEqual(last + 1e-9);
      last = r;
    }
  });

  it("has no length at birth rather than reaching back to nowhere", () => {
    const pts = cometTrail(c, 0, 6, 0.2);
    for (const p of pts) {
      expect(p[0]).toBeCloseTo(pts[5][0], 9);
      expect(p[1]).toBeCloseTo(pts[5][1], 9);
    }
  });
});

describe("zoom, count and flash", () => {
  it("zoomIn arrives from far too big and lands exactly at its own size", () => {
    expect(zoomIn(0).scale).toBeGreaterThan(3);
    expect(zoomIn(0).alpha).toBe(0);
    expect(zoomIn(1).scale).toBe(1);
    expect(zoomIn(1).alpha).toBe(1);
    // Most of the shrink is over by a third of the way.
    expect(zoomIn(1 / 3).scale).toBeLessThan(1.4);
  });

  it("zoomOut hangs, then swells and goes", () => {
    expect(zoomOut(0).scale).toBe(1);
    expect(zoomOut(0).alpha).toBe(1);
    expect(zoomOut(0.5).scale).toBeLessThan(1.15);
    expect(zoomOut(1).alpha).toBe(0);
  });

  it("countUp lands on the exact number and never overshoots", () => {
    expect(countUp(0, 150, 0)).toBe(0);
    expect(countUp(0, 150, 1)).toBe(150);
    expect(countUp(100, 250, 1)).toBe(250);
    let last = -1;
    for (let k = 0; k <= 100; k++) {
      const v = countUp(0, 150, k / 100);
      expect(v).toBeGreaterThanOrEqual(last);
      expect(v).toBeLessThanOrEqual(150);
      last = v;
    }
  });

  it("flashAlpha is brightest at the clear and gone by the end", () => {
    expect(flashAlpha(0, 0.5)).toBeGreaterThan(0.8);
    expect(flashAlpha(0.25, 0.5)).toBeLessThan(flashAlpha(0, 0.5));
    expect(flashAlpha(0.5, 0.5)).toBe(0);
    expect(flashAlpha(-1, 0.5)).toBe(0);
  });
});
