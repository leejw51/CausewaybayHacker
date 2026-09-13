/**
 * The half of "FORMAT keeps your caret" that belongs to us.
 *
 * CodeMirror maps a selection through an edit — that is its guarantee, not
 * ours. Ours is that the edit is as small as the change actually is, because a
 * whole-document replacement is a legal edit that moves every caret in the
 * file. These cases are the ones a formatter really produces: a change at the
 * top with the rest untouched, a change at the bottom, an interior change, and
 * source that was already tidy.
 */
import { describe, expect, it } from "vitest";
import { answerCompletion, answerProgress, narrowEdit } from "../src/ui/editor";

const apply = (cur: string, e: { from: number; to: number; insert: string }) =>
  cur.slice(0, e.from) + e.insert + cur.slice(e.to);

describe("narrowEdit", () => {
  it("does nothing at all when the source is already tidy", () => {
    expect(narrowEdit("fn main() {}\n", "fn main() {}\n")).toBeNull();
  });

  it("touches only the first line when only the first line changed", () => {
    const cur = "fn   main(  ) {\n    let a = 1;\n}\n";
    const next = "fn main() {\n    let a = 1;\n}\n";
    const e = narrowEdit(cur, next)!;
    expect(apply(cur, e)).toBe(next);
    // the edit ends before the second line, so a caret on it cannot move
    expect(e.to).toBeLessThanOrEqual(cur.indexOf("\n    let a"));
  });

  it("touches only the last line when only the last line changed", () => {
    const cur = "fn main() {\n    let a=1;\n}\n";
    const next = "fn main() {\n    let a = 1;\n}\n";
    const e = narrowEdit(cur, next)!;
    expect(apply(cur, e)).toBe(next);
    // and it starts after the first line, so a caret up there cannot move
    expect(e.from).toBeGreaterThan(cur.indexOf("\n"));
  });

  it("narrows an interior change to the interior", () => {
    const cur = "a\nBBB\nc\n";
    const next = "a\nB\nc\n";
    const e = narrowEdit(cur, next)!;
    expect(apply(cur, e)).toBe(next);
    // "a\nB" is common, so the edit is the two surplus Bs and nothing else
    expect(e.from).toBe(3);
    expect(e.to).toBe(5);
    expect(e.insert).toBe("");
  });

  it("handles a total rewrite without losing a character", () => {
    const cur = "package main";
    const next = "fn main() {}";
    const e = narrowEdit(cur, next)!;
    expect(apply(cur, e)).toBe(next);
  });

  it("handles growth and shrinkage at the very end", () => {
    for (const [cur, next] of [
      ["fn main() {}", "fn main() {}\n"],
      ["fn main() {}\n\n\n", "fn main() {}\n"],
      ["", "fn main() {}\n"],
    ] as Array<[string, string]>) {
      const e = narrowEdit(cur, next)!;
      expect(apply(cur, e)).toBe(next);
    }
  });
});

/**
 * ANSWER mode's arithmetic.
 *
 * The rule is a *prefix*: the mode is a typing target read from the top, and
 * what a player needs pointed at is the first place their text stops being
 * the answer. Everything the screen does — the count, the red mark, the three
 * bursts — is read off these three numbers, so they are the thing worth
 * holding still.
 */
describe("answerProgress", () => {
  const answer = "fn main() {\n    println!(\"hi\");\n}\n";

  it("an empty buffer has typed none of it and got none of it wrong", () => {
    const p = answerProgress("", answer);
    expect(p).toEqual({ matched: 0, wrong: 0, done: false, total: answer.length });
  });

  it("counts the characters that are the answer, from the start", () => {
    expect(answerProgress("fn main", answer).matched).toBe(7);
    expect(answerProgress("fn main", answer).wrong).toBe(0);
    expect(answerProgress("fn main", answer).done).toBe(false);
  });

  it("stops counting at the divergence and calls the rest wrong", () => {
    const p = answerProgress("fn maim() {", answer);
    expect(p.matched).toBe(6);
    expect(p.wrong).toBe(5);
  });

  it("is done only on every character, exactly", () => {
    expect(answerProgress(answer, answer).done).toBe(true);
    expect(answerProgress(answer.trimEnd(), answer).done).toBe(false);
    expect(answerProgress(answer + " ", answer).done).toBe(false);
    expect(answerProgress(answer + " ", answer).wrong).toBe(1);
  });

  it("a line finished is a newline crossing, which is what the effect fires on", () => {
    const before = answerProgress("fn main() {", answer);
    const after = answerProgress("fn main() {\n", answer);
    expect(after.matched).toBeGreaterThan(before.matched);
    expect(answer.slice(before.matched, after.matched)).toContain("\n");
  });
});

/**
 * What TAB gives you in ANSWER mode.
 *
 * The pedal has to be honest about two things: it never completes past a
 * mistake (that would bury the divergence under correct text), and at the end
 * of a line it gives the next line's indentation rather than its content —
 * typing the solution is the exercise, typing eight spaces is not.
 */
describe("answerCompletion", () => {
  const answer = 'fn main() {\n    println!("hi");\n}\n';

  it("completes the rest of the line you are on", () => {
    expect(answerCompletion("", answer)).toBe("fn main() {");
    expect(answerCompletion("fn ma", answer)).toBe("in() {");
  });

  it("at a line's end, gives the newline and the next line's indent", () => {
    expect(answerCompletion("fn main() {", answer)).toBe("\n    ");
    expect(answerCompletion('fn main() {\n    println!("hi");', answer)).toBe("\n");
  });

  it("refuses to complete past a divergence", () => {
    expect(answerCompletion("fn maim", answer)).toBeNull();
    expect(answerCompletion("zzz", answer)).toBeNull();
    expect(answerCompletion(answer + " ", answer)).toBeNull();
  });

  it("has nothing to give once the answer is typed", () => {
    expect(answerCompletion(answer, answer)).toBeNull();
  });

  it("typed end to end, it lands exactly on the answer", () => {
    let typed = "";
    for (let i = 0; i < 200; i++) {
      const next = answerCompletion(typed, answer);
      if (next === null) break;
      typed += next;
    }
    expect(typed).toBe(answer);
  });
});
