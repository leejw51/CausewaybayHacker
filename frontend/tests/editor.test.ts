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
import { narrowEdit } from "../src/ui/editor";

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
