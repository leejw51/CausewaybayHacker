/**
 * The house curve, and the thing that makes it screenshot-able.
 *
 * Two properties are worth pinning. The first is the shape: exponential easing
 * is almost still, then very fast, then almost still, and a regression that
 * quietly swapped it for a cubic would look *fine* while losing the character
 * the whole game's timing was tuned against.
 *
 * The second is that nothing here reads the wall clock. Every tween is driven
 * by the `dt` it is handed, which is what lets `dev/capture.ts` step the game
 * at a fixed 1/60 and get the same frame every run — the difference between a
 * visual regression suite and a pile of nearly-identical pictures.
 */
import { describe, expect, it } from "vitest";
import { expInOut, expOut } from "../src/engine/ease";
import { Chase, seconds, Tween } from "../src/engine/motion";

describe("the expo curves", () => {
  it("pins both ends exactly", () => {
    expect(expInOut(0)).toBe(0);
    expect(expInOut(1)).toBe(1);
    expect(expOut(0)).toBe(0);
    expect(expOut(1)).toBe(1);
    expect(expInOut(0.5)).toBeCloseTo(0.5, 6);
  });

  it("clamps rather than extrapolating", () => {
    expect(expInOut(-1)).toBe(0);
    expect(expInOut(2)).toBe(1);
    expect(expOut(-0.5)).toBe(0);
    expect(expOut(9)).toBe(1);
  });

  it("is almost still at the start and end, and fast in the middle", () => {
    // The signature of expo: the first and last tenth of the time cover almost
    // none of the distance, and the middle fifth covers most of it.
    const firstTenth = expInOut(0.1) - expInOut(0);
    const middleFifth = expInOut(0.6) - expInOut(0.4);
    const lastTenth = expInOut(1) - expInOut(0.9);
    expect(firstTenth).toBeLessThan(0.01);
    expect(lastTenth).toBeLessThan(0.01);
    expect(middleFifth).toBeGreaterThan(0.6);
    // A cubic would put roughly a third of the distance in that middle fifth.
    expect(middleFifth).toBeGreaterThan(3 * firstTenth);
  });

  it("only arrives, for expOut: most of the distance is covered early", () => {
    expect(expOut(0.2)).toBeGreaterThan(0.7);
    expect(expOut(0.5)).toBeGreaterThan(0.95);
  });

  it("never goes backwards", () => {
    for (let i = 1; i <= 100; i++) {
      expect(expInOut(i / 100)).toBeGreaterThanOrEqual(expInOut((i - 1) / 100));
      expect(expOut(i / 100)).toBeGreaterThanOrEqual(expOut((i - 1) / 100));
    }
  });
});

describe("Tween", () => {
  it("runs on the dt it is handed, not on the clock", () => {
    const t = new Tween(1);
    expect(t.raw).toBe(0);
    for (let i = 0; i < 30; i++) t.update(1 / 60);
    expect(t.raw).toBeCloseTo(0.5, 6);
    for (let i = 0; i < 30; i++) t.update(1 / 60);
    expect(t.finished).toBe(true);
    expect(t.raw).toBe(1);
  });

  it("gives the same answer for the same steps, every time", () => {
    // This is what makes a screenshot reproducible.
    const run = () => {
      const t = new Tween(0.62, 0.07);
      const seen: number[] = [];
      for (let i = 0; i < 45; i++) {
        t.update(1 / 60);
        seen.push(t.out);
      }
      return seen;
    };
    expect(run()).toEqual(run());
  });

  it("holds at zero through its delay", () => {
    const t = new Tween(0.5, 0.25);
    t.update(0.2);
    expect(t.raw).toBe(0);
    t.update(0.1);
    expect(t.raw).toBeGreaterThan(0);
  });

  it("can start finished, for a screen being returned to rather than entered", () => {
    expect(new Tween(1, 0, true).finished).toBe(true);
    expect(new Tween(1, 0, true).out).toBe(1);
  });

  it("treats a zero duration as already done rather than dividing by it", () => {
    const t = new Tween(0);
    expect(t.raw).toBe(1);
    expect(t.finished).toBe(true);
  });
});

describe("Chase", () => {
  it("eases to a new target from wherever it currently is", () => {
    const c = new Chase(0);
    expect(c.value).toBe(0);
    c.to(10);
    for (let i = 0; i < 6; i++) c.update(1 / 60);
    const partway = c.value;
    expect(partway).toBeGreaterThan(0);
    expect(partway).toBeLessThan(10);
    // Re-aiming mid-flight starts from here, so the value never jumps.
    c.to(-5);
    expect(c.value).toBeCloseTo(partway, 6);
    for (let i = 0; i < 120; i++) c.update(1 / 60);
    expect(c.value).toBeCloseTo(-5, 4);
  });

  it("ignores a target it is already aimed at", () => {
    const c = new Chase(3);
    c.to(3);
    expect(c.value).toBe(3);
  });

  it("snaps without animating, for a screen that has just been rebuilt", () => {
    const c = new Chase(0);
    c.to(100);
    c.snap(7);
    expect(c.value).toBe(7);
  });
});

describe("the house durations", () => {
  it("gives every beat a positive length", () => {
    for (const beat of ["scene", "panel", "node", "camera", "stamp", "verdict", "star"] as const) {
      expect(seconds(beat)).toBeGreaterThan(0);
    }
  });

  it("makes a whole-screen change the longest thing that happens", () => {
    expect(seconds("scene")).toBeGreaterThan(seconds("panel"));
    expect(seconds("scene")).toBeGreaterThan(seconds("stamp"));
    // The stamp is an impact and is deliberately the quickest of the arrivals.
    expect(seconds("stamp")).toBeLessThan(seconds("verdict"));
  });
});
