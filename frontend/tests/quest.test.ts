/**
 * The two pieces of the quest screen that are decisions rather than drawing.
 *
 * Both are one line of code in `scenes/quest.ts` and both are one line of code
 * somebody will later "simplify" into a bug that no type checker and no
 * screenshot can see — which is the entire reason they are functions with
 * names, and the entire reason this file exists.
 */
import { describe, expect, it } from "vitest";
import { hintsRemaining, openingSource, solveOutcome } from "../src/scenes/quest";

const quest = (over: { draft?: string | null; starter?: string } = {}) => ({
  starter: "fn main() {}\n",
  ...over,
});

describe("what the editor opens with (§4.8)", () => {
  it("uses the starter on a quest nobody has touched", () => {
    expect(openingSource(undefined, quest({ draft: null }))).toBe("fn main() {}\n");
  });

  it("uses the server's draft when there is one", () => {
    expect(openingSource(undefined, quest({ draft: "my own attempt" }))).toBe("my own attempt");
  });

  it("keeps an EMPTY draft rather than falling back to the starter", () => {
    // The case `||` gets wrong and `??` gets right. Selecting all, deleting,
    // pressing RUN and coming back is a player asking for an empty buffer; a
    // starter appearing instead reads as the feature not working at all.
    expect(openingSource(undefined, quest({ draft: "" }))).toBe("");
  });

  it("uses the starter when the server has not shipped the field", () => {
    // §4.8 is optional in the type for the same reason §4.8b's clock is: an
    // older server omits it, and `??` must treat that exactly like `null`.
    expect(openingSource(undefined, quest())).toBe("fn main() {}\n");
  });

  it("prefers the buffer TRY AGAIN handed back, over both", () => {
    // The verdict screen carries the keystrokes of the last few seconds. The
    // server's draft is the same submission, but this one cannot be stale.
    expect(openingSource("just typed", quest({ draft: "older draft" }))).toBe("just typed");
  });

  it("keeps an empty buffer from TRY AGAIN too", () => {
    expect(openingSource("", quest({ draft: "older draft" }))).toBe("");
  });
});

describe("the hint counter", () => {
  it("counts down", () => {
    expect(hintsRemaining(3, 1)).toBe(2);
  });

  it("never goes negative", () => {
    // `quest.solve` (§4.11b) moves `hints_used` to the quest's own hint count.
    // A server that moved it past `hints_total` must not print "-1 HINTS LEFT".
    expect(hintsRemaining(2, 3)).toBe(0);
  });
});

describe("what a quest.solve reply means (§4.11b)", () => {
  it("replaces the buffer and carries the new hint count", () => {
    const out = solveOutcome("my half-written attempt", {
      source: "the reference answer",
      hints_used: 2,
    });
    expect(out).toEqual({ replace: true, hintsUsed: 2 });
  });

  it("does not replace a buffer that is already the answer", () => {
    // Pressing SOLVE twice. `replaceAll` would correctly do nothing, and a
    // button that correctly does nothing is indistinguishable from a broken
    // one — so the screen says so instead.
    const out = solveOutcome("the reference answer", {
      source: "the reference answer",
      hints_used: 2,
    });
    expect(out.replace).toBe(false);
  });

  it("still reports the hint count when nothing is replaced", () => {
    // The star is spent either way: the server moved `hints_used` before it
    // answered, and the label on the bench is that number.
    expect(solveOutcome("same", { source: "same", hints_used: 3 }).hintsUsed).toBe(3);
  });
});
