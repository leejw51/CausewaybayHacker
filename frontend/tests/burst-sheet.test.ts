/**
 * The sheet roads' plans (`engine/burst.ts`), checked without a GPU.
 *
 * What is worth pinning: that a plan is the same plan under a fixed rng (the
 * visual suite steps it and compares frames); that the light trail runs
 * *against* the pointer and gets hotter with speed; that the beam sweeps
 * left to right in order and closes at the far end; that the shockwave's
 * rings grow outward in the order they are listed; and that a streak's
 * fountain is bigger for a longer streak but never past the cap — a
 * ten-streak is a show, not a frame drop.
 */
import { describe, expect, it } from "vitest";
import {
  beamPlan,
  comboPlan,
  lightTrailPlan,
  SHEET_ADVANCED,
  SHEET_BASIC,
  shockPlan,
} from "../src/engine/burst";

function rngFrom(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

describe("lightTrailPlan", () => {
  it("is deterministic under a fixed rng", () => {
    const a = lightTrailPlan(100, 100, 600, 0, SHEET_BASIC, rngFrom(7));
    const b = lightTrailPlan(100, 100, 600, 0, SHEET_BASIC, rngFrom(7));
    expect(a).toEqual(b);
  });

  it("drifts against the motion, with a body and a hot core", () => {
    const plan = lightTrailPlan(100, 100, 600, 0, SHEET_BASIC, rngFrom(1));
    expect(plan.particles.length).toBeGreaterThanOrEqual(2);
    const [body, core] = plan.particles;
    // Moving right, so the ribbon trails to the left.
    expect(body.dx).toBeLessThan(0);
    expect(core.dx).toBeLessThan(0);
    expect(body.trail).toBe(true);
    expect(body.size).toBeGreaterThan(core.size);
    expect(body.life).toBeGreaterThan(core.life);
    expect(core.color).toEqual(SHEET_BASIC.hot);
  });

  it("burns whiter the faster the pointer went, in the road's own colour", () => {
    const slow = lightTrailPlan(0, 0, 100, 0, SHEET_ADVANCED, rngFrom(3)).particles[0];
    const fast = lightTrailPlan(0, 0, 5000, 0, SHEET_ADVANCED, rngFrom(3)).particles[0];
    expect(fast.color[0]).toBeGreaterThan(slow.color[0]);
    expect(fast.size).toBeGreaterThan(slow.size);
    // The blue of the violet survives: it is ADVANCED's trail, not BASIC's.
    expect(slow.color[2]).toBe(SHEET_ADVANCED.trail[2]);
  });

  it("stands still when the pointer did", () => {
    const plan = lightTrailPlan(50, 50, 0, 0, SHEET_BASIC, rngFrom(9));
    expect(plan.particles[0].dx).toBe(0);
    expect(plan.particles[0].dy).toBe(0);
  });
});

describe("beamPlan", () => {
  const cell = [12, 22] as const;

  it("sweeps left to right: later sparks start later and further along", () => {
    const plan = beamPlan(100, 200, 400, cell, [1, 0.8, 0.2, 1], rngFrom(5));
    const sparks = plan.particles;
    for (let i = 1; i < sparks.length; i++) {
      expect(sparks[i].x).toBeGreaterThan(sparks[i - 1].x);
      expect(sparks[i].delay).toBeGreaterThanOrEqual(sparks[i - 1].delay - 0.02);
    }
    expect(sparks[0].x).toBe(100);
    expect(sparks[sparks.length - 1].x).toBe(400);
  });

  it("marks where the light is with glows in order, and closes at the far end", () => {
    const plan = beamPlan(100, 200, 400, cell, [1, 0.8, 0.2, 1], rngFrom(5));
    const glows = plan.rings.filter((r) => r.glow);
    expect(glows.length).toBe(5);
    for (let i = 1; i < glows.length; i++) {
      expect(glows[i].x).toBeGreaterThan(glows[i - 1].x);
      expect(glows[i].delay).toBeGreaterThan(glows[i - 1].delay);
    }
    const close = plan.rings[plan.rings.length - 1];
    expect(close.x).toBe(400);
    expect(close.glow).toBe(false);
    expect(close.delay).toBeGreaterThanOrEqual(glows[glows.length - 1].delay);
  });

  it("costs no more for a long line than a reasonable one", () => {
    const short = beamPlan(0, 0, 60, cell, [1, 1, 1, 1], rngFrom(1));
    const long = beamPlan(0, 0, 6000, cell, [1, 1, 1, 1], rngFrom(1));
    expect(short.particles.length).toBeGreaterThanOrEqual(6);
    expect(long.particles.length).toBeLessThanOrEqual(24);
  });
});

describe("shockPlan", () => {
  it("rings grow outward in order and the halo reaches about the radius", () => {
    const plan = shockPlan(300, 300, 120, [0, 1, 1, 1], rngFrom(2));
    expect(plan.rings.length).toBe(3);
    expect(plan.rings[0].radius).toBeLessThan(plan.rings[1].radius);
    expect(plan.rings[1].radius).toBeLessThan(plan.rings[2].radius);
    expect(plan.rings[0].glow).toBe(true);
    for (const p of plan.particles) {
      const reach = Math.hypot(p.dx, p.dy);
      expect(reach).toBeGreaterThanOrEqual(120 * 0.8 - 1e-9);
      expect(reach).toBeLessThanOrEqual(120 * 1.1 + 1e-9);
      expect(p.gravity).toBe(0);
      expect(p.trail).toBe(true);
    }
  });
});

describe("comboPlan", () => {
  it("is bigger for a longer streak, up to the cap", () => {
    const two = comboPlan(0, 0, 1, rngFrom(4));
    const five = comboPlan(0, 0, 4, rngFrom(4));
    const huge = comboPlan(0, 0, 40, rngFrom(4));
    expect(five.particles.length).toBeGreaterThan(two.particles.length);
    expect(huge.particles.length).toBeLessThanOrEqual(60);
    expect(huge.rings.length).toBeLessThanOrEqual(8);
    expect(two.rings.length).toBe(1);
    expect(five.rings.length).toBe(4);
  });

  it("is a fountain: every star is thrown upward", () => {
    const plan = comboPlan(0, 0, 3, rngFrom(8));
    for (const p of plan.particles) {
      expect(p.dy).toBeLessThan(0);
      expect(p.gravity).toBeGreaterThan(0);
      expect(p.shape).toBe(1);
    }
  });
});
