import { describe, expect, it } from "vitest";
import { COMBO_WINDOW, Combo, FEVER_AT } from "../src/ui/combo";
import { errorAt } from "../src/scenes/playground";
import type { PlaygroundRun } from "../src/net/protocol";

/** The playground's game layer: the typing combo, and where a hit lands. */
describe("the typing combo", () => {
  it("counts keys inside the window and announces each milestone once", () => {
    const c = new Combo();
    const crossed: number[] = [];
    for (let i = 0; i < 30; i++) {
      const m = c.hit(i * 0.1);
      if (m) crossed.push(m);
    }
    expect(c.count).toBe(30);
    expect(crossed).toEqual([10, 25]);
    expect(c.tier()).toBe(2);
  });

  it("lapses after a pause, and starts over", () => {
    const c = new Combo();
    for (let i = 0; i < 12; i++) c.hit(i * 0.1);
    expect(c.tick(1.1 + COMBO_WINDOW + 0.01)).toBe(true);
    expect(c.count).toBe(0);
    expect(c.best).toBe(12);
    expect(c.hit(10)).toBe(0);
    expect(c.count).toBe(1);
  });

  it("is in FEVER only from FEVER_AT up", () => {
    const c = new Combo();
    for (let i = 0; i < FEVER_AT - 1; i++) c.hit(i * 0.05);
    expect(c.fever()).toBe(0);
    c.hit(FEVER_AT * 0.05);
    expect(c.fever()).toBeGreaterThan(0);
  });

  it("drains the window between keys", () => {
    const c = new Combo();
    c.hit(0);
    expect(c.left(0)).toBe(1);
    expect(c.left(COMBO_WINDOW / 2)).toBeCloseTo(0.5);
    expect(c.left(COMBO_WINDOW * 2)).toBe(0);
  });
});

const run = (over: Partial<PlaygroundRun>): PlaygroundRun => ({
  attempt_id: "a",
  lang: "rust",
  outcome: "compile_error",
  compile_ms: 1,
  run_ms: 0,
  exit_code: null,
  stdout: "",
  stderr: "",
  diagnostics: [],
  ...over,
});

describe("where the hit lands", () => {
  it("takes the first error diagnostic's line and code", () => {
    expect(
      errorAt(
        run({
          diagnostics: [
            { kind: "warning", code: null, message: "w", line: 2, col: 1 },
            { kind: "error", code: "E0425", message: "x", line: 7, col: 3 },
          ],
        }),
      ),
    ).toEqual({ line: 7, code: "E0425" });
  });

  it("falls back to rustc's and Go's stderr", () => {
    expect(
      errorAt(run({ stderr: "\x1b[1merror[E0308]\x1b[0m: mismatched\n --> src/main.rs:12:9\n" })),
    ).toEqual({ line: 12, code: "E0308" });
    expect(errorAt(run({ stderr: "./main.go:5:2: undefined: x\n" }))).toEqual({ line: 5, code: "" });
    expect(errorAt(run({ stderr: "boom" }))).toEqual({ line: null, code: "" });
  });
});
