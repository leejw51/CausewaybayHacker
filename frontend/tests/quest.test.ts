/**
 * The two pieces of the quest screen that are decisions rather than drawing.
 *
 * Both are one line of code in `scenes/quest.ts` and both are one line of code
 * somebody will later "simplify" into a bug that no type checker and no
 * screenshot can see — which is the entire reason they are functions with
 * names, and the entire reason this file exists.
 */
import { describe, expect, it } from "vitest";
import {
  briefNeedsNote,
  clearsForAnswer,
  editControls,
  editorTextFor,
  hintsRemaining,
  openingSource,
  ranCases,
  solveOutcome,
} from "../src/scenes/quest";
import type { EditState } from "../src/net/protocol";

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

describe("when the brief panel says the brief is in English (§4.8)", () => {
  it("says nothing when the prose arrived in the UI language", () => {
    expect(briefNeedsNote("ko", "ko")).toBe(false);
    expect(briefNeedsNote("en", "en")).toBe(false);
  });

  it("says so when the server had no translation for this quest", () => {
    // `text_locale: "en"` under a Korean interface is the case the note
    // exists for: a Korean panel with an English paragraph inside it.
    expect(briefNeedsNote("en", "ko")).toBe(true);
  });

  it("treats a server that never sent the field as English", () => {
    // An older server omits `text_locale`; what it sent was English, so an
    // English interface owes no note and a Korean one does.
    expect(briefNeedsNote(undefined, "en")).toBe(false);
    expect(briefNeedsNote(undefined, "ko")).toBe(true);
  });

  it("notes a mismatch between two translations too", () => {
    // Korean prose under a Japanese interface after an F7 mid-quest, before
    // the re-fetch lands: still two languages on one screen.
    expect(briefNeedsNote("ko", "ja")).toBe(true);
  });
});

/**
 * The edit stack, reduced to the two questions the screen actually asks of it:
 * which of the three buttons are live, and what text an undo puts in the
 * editor. Everything else about the stack lives on the server — a reply is the
 * whole state and the client never counts entries itself — which is exactly
 * why these two are worth pinning down.
 */
const state = (over: Partial<EditState> = {}): EditState => ({
  quest_id: "rust/basic/01",
  source: "fn main() {}\n",
  cursor: 2,
  depth: 3,
  can_undo: true,
  can_redo: true,
  ...over,
});

describe("which of UNDO, REDO and CLEAR STACK are live", () => {
  it("offers all three in the middle of a stack", () => {
    expect(editControls(state(), false)).toEqual({ undo: true, redo: true, clear: true });
  });

  it("offers none at all when the server has never said (the graceful case)", () => {
    // A server without `edit.*` leaves `null` here. The bench must keep
    // working around it: three dim buttons, and nothing else on the screen
    // knows or cares that the stack is missing.
    expect(editControls(null, false)).toEqual({ undo: false, redo: false, clear: false });
  });

  it("offers none while a call is in flight", () => {
    // Every one of the five messages rewrites the whole state, so two at once
    // would apply in whichever order the replies landed.
    expect(editControls(state(), true)).toEqual({ undo: false, redo: false, clear: false });
  });

  it("takes the server's word for undo and redo rather than re-deriving them", () => {
    expect(editControls(state({ can_undo: false }), false).undo).toBe(false);
    expect(editControls(state({ can_undo: false }), false).redo).toBe(true);
    expect(editControls(state({ can_redo: false }), false).redo).toBe(false);
    expect(editControls(state({ can_redo: false }), false).undo).toBe(true);
  });

  it("only offers CLEAR when there is history to throw away", () => {
    const empty = state({ cursor: 0, depth: 0, can_undo: false, can_redo: false });
    expect(editControls(empty, false).clear).toBe(false);
    // At the bottom of a stack that still has a redo tail there is nothing to
    // undo and there is still something to clear.
    const bottom = state({ cursor: 0, depth: 3, can_undo: false });
    expect(editControls(bottom, false)).toEqual({ undo: false, redo: true, clear: true });
  });
});

describe("what an undo or a redo puts in the editor", () => {
  it("uses the entry at the cursor", () => {
    expect(editorTextFor(state({ source: "older work" }), "starter")).toBe("older work");
  });

  it("uses the starter when the cursor is at the bottom", () => {
    // `null` is the one case that means "there is no entry here at all", and
    // the quest's starter is what was there before the first edit.
    expect(editorTextFor(state({ source: null, cursor: 0 }), "fn main() {}\n")).toBe(
      "fn main() {}\n",
    );
  });

  it("keeps an EMPTY entry rather than falling back to the starter", () => {
    // The `??`-not-`||` trap `openingSource` already carries a test for. Some-
    // body who selected all, deleted, and paused has an empty string on the
    // stack; handing back the starter would read as UNDO skipping a step.
    expect(editorTextFor(state({ source: "" }), "starter")).toBe("");
  });
});

/**
 * ANSWER opening on an empty page.
 *
 * The starter is boilerplate and against the answer it is wrong text, so it
 * goes — but a *draft* is the player's own writing, and the mode tidying its
 * own display is not a reason to throw that away. The line between the two is
 * the only thing this decides, so it is the thing worth holding.
 */
describe("clearsForAnswer", () => {
  const starter = "fn main() {\n    // your code here\n}\n";

  it("clears the starter the quest shipped", () => {
    expect(clearsForAnswer(starter, starter)).toBe(true);
  });

  it("ignores whitespace nobody decided on", () => {
    expect(clearsForAnswer(starter.trimEnd(), starter)).toBe(true);
    expect(clearsForAnswer(`\n${starter}  `, starter)).toBe(true);
  });

  it("never clears a draft, however small the difference", () => {
    expect(clearsForAnswer(`${starter}// mine\n`, starter)).toBe(false);
    expect(clearsForAnswer("fn main() {\n    let x = 1;\n}\n", starter)).toBe(false);
    expect(clearsForAnswer("", starter)).toBe(false);
  });

  it("does nothing when the quest shipped no starter at all", () => {
    expect(clearsForAnswer("", "")).toBe(false);
    expect(clearsForAnswer("   ", "  \n ")).toBe(false);
  });
});

/**
 * The run report's case line. After a compile error the server still lists
 * the sample, failed, with `got: ""`, and `expected "3\\n" got ""` under IT
 * DID NOT COMPILE reads as a program that printed nothing — a different
 * mistake from the one that was made.
 */
describe("whether a run's cases describe something that ran", () => {
  it("says no after a compile error, so no expected/got line is printed", () => {
    expect(ranCases({ verdict: "compile_error" })).toBe(false);
  });

  it("says no when the runner itself broke", () => {
    expect(ranCases({ verdict: "internal_error" })).toBe(false);
  });

  it("says yes for every verdict a program produced", () => {
    for (const verdict of [
      "accepted",
      "wrong_answer",
      "runtime_error",
      "timeout",
      "output_limit",
    ] as const) {
      expect(ranCases({ verdict })).toBe(true);
    }
  });
});
