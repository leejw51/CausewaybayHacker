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
import {
  answerBlanks,
  answerCompletion,
  answerIndent,
  answerProgress,
  blanksFill,
  maskBlanks,
  narrowEdit,
  solutionBlanks,
} from "../src/ui/editor";

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
 * BLANKS: the answer on the screen with holes cut in it.
 *
 * The invariant that makes the whole mode work is that the buffer is always
 * a *prefix* of the answer — everything between one hole and the next is
 * typed for the player, so the progress count, the bursts and the ghost keep
 * working unchanged. These are the rules that keep it true.
 */
describe("answerBlanks", () => {
  const answer = 'fn main() {\n    println!("hi");\n}\n';

  it("cuts holes at words, never inside one", () => {
    const words = /[A-Za-z_][A-Za-z0-9_]*|[0-9]+/g;
    const spans = new Set<string>();
    for (let m = words.exec(answer); m !== null; m = words.exec(answer)) {
      spans.add(`${m.index}:${m.index + m[0].length}`);
    }
    for (const b of answerBlanks(answer, 7)) expect(spans.has(`${b.from}:${b.to}`)).toBe(true);
  });

  it("is the same drill for the same seed, and leaves something to do", () => {
    expect(answerBlanks(answer, 3)).toEqual(answerBlanks(answer, 3));
    for (const seed of [1, 2, 3, 99, 12345]) {
      expect(answerBlanks(answer, seed).length).toBeGreaterThan(0);
    }
  });

  it("masks the holes and nothing else, keeping the line's width", () => {
    const target = { text: answer, blanks: answerBlanks(answer, 5) };
    const masked = maskBlanks(target);
    expect(masked.length).toBe(answer.length);
    for (const b of target.blanks) {
      expect(masked.slice(b.from, b.to)).toBe("_".repeat(b.to - b.from));
    }
    // Everything outside a hole is the program, untouched.
    let at = 0;
    for (const b of target.blanks) {
      expect(masked.slice(at, b.from)).toBe(answer.slice(at, b.from));
      at = b.to;
    }
  });
});

describe("blanksFill", () => {
  const answer = 'fn main() {\n    println!("hi");\n}\n';
  const target = { text: answer, blanks: [{ from: 3, to: 7 }] }; // `main`

  it("types everything up to the hole, and stops there", () => {
    expect(blanksFill("", target)).toBe("fn ");
  });

  it("gives nothing while the caret is in the hole — that part is the drill", () => {
    expect(blanksFill("fn ", target)).toBeNull();
    expect(blanksFill("fn ma", target)).toBeNull();
  });

  it("carries on the moment the hole is filled", () => {
    expect(blanksFill("fn main", target)).toBe(answer.slice(7));
  });

  it("refuses while the buffer has stopped being the answer", () => {
    expect(blanksFill("fn maim", target)).toBeNull();
  });

  it("filling and typing the holes lands exactly on the answer", () => {
    // What the player does, in miniature: the gaps between the holes arrive
    // on their own, and the holes themselves are typed.
    let typed = "";
    for (let i = 0; i < 500; i++) {
      const add = blanksFill(typed, target);
      if (add !== null) {
        typed += add;
        continue;
      }
      if (typed.length >= answer.length) break;
      typed += answer[typed.length];
    }
    expect(typed).toBe(answer);
  });
});

/**
 * What the +LINE button hands over.
 *
 * It was a TAB binding once; TAB is the editor's key and a mode that took it
 * made indenting impossible, so the same rule now sits behind a button. The
 * rule itself is unchanged and is the thing worth holding: a line at a time,
 * the next line's indent at a line's end, and never past a mistake.
 */
describe("answerCompletion", () => {
  const answer = 'fn main() {\n    println!("hi");\n}\n';

  it("gives the rest of the line you are on", () => {
    expect(answerCompletion("", answer)).toBe("fn main() {");
    expect(answerCompletion("fn ma", answer)).toBe("in() {");
  });

  it("at a line's end, gives the newline and the next line's indent", () => {
    expect(answerCompletion("fn main() {", answer)).toBe("\n    ");
    expect(answerCompletion('fn main() {\n    println!("hi");', answer)).toBe("\n");
  });

  it("refuses past a divergence, and has nothing to give once it is typed", () => {
    expect(answerCompletion("fn maim", answer)).toBeNull();
    expect(answerCompletion(answer + " ", answer)).toBeNull();
    expect(answerCompletion(answer, answer)).toBeNull();
  });

  it("pressed until it stops, it lands exactly on the answer", () => {
    let typed = "";
    for (let i = 0; i < 200; i++) {
      const next = answerCompletion(typed, answer);
      if (next === null) break;
      typed += next;
    }
    expect(typed).toBe(answer);
  });
});

/**
 * Indentation, which the player must never have to type.
 *
 * A Go answer is tab-indented and a Rust one is four spaces; the editor's
 * auto-indent guesses one width of spaces for every language. Against a tab
 * that guess is a divergence the player did not type and cannot fix by
 * typing — the line stays red and the quest cannot be finished. It was
 * reported exactly that way.
 */
describe("answerIndent", () => {
  const tabs = "func main() {\n\tswitch {\n\tcase 1:\n\t}\n}\n";
  const spaces = "fn main() {\n    println!(\"hi\");\n}\n";

  it("gives the answer's own indentation, whatever it is made of", () => {
    expect(answerIndent("func main() {\n", tabs)).toBe("\t");
    expect(answerIndent("fn main() {\n", spaces)).toBe("    ");
  });

  it("only at the start of a line", () => {
    expect(answerIndent("func main() {", tabs)).toBeNull();
    expect(answerIndent("func main() {\n\tswi", tabs)).toBeNull();
  });

  it("nothing when the line does not start with any", () => {
    expect(answerIndent("", spaces)).toBeNull();
    expect(answerIndent("fn main() {\n    println!(\"hi\");\n", spaces)).toBeNull();
  });

  it("refuses past a divergence, like everything else in the mode", () => {
    expect(answerIndent("func maim() {\n", tabs)).toBeNull();
  });

  it("with it, the answer is typed without the player ever typing a tab", () => {
    // The player types the code; the mode puts the indentation in. This is
    // the property that was broken: on a tab-indented answer there was no
    // key at all that advanced the count.
    let typed = "";
    const byHand: string[] = [];
    for (let i = 0; i < 400; i++) {
      const indent = answerIndent(typed, tabs);
      if (indent !== null) {
        typed += indent;
        continue;
      }
      if (typed.length >= tabs.length) break;
      const ch = tabs[typed.length];
      byHand.push(ch);
      typed += ch;
    }
    expect(typed).toBe(tabs);
    expect(byHand).not.toContain("\t");
  });
});

/**
 * "Type only the answer": the holes are what the quest did not give you.
 *
 * A quest ships a starter — imports, `func main`, the scaffold — and the
 * answer is that with a solution written into it. Typing the scaffold back
 * out teaches nobody anything, so the scaffold types itself and the holes
 * fall exactly on the lines the answer has and the starter does not.
 */
describe("solutionBlanks", () => {
  const starter = "package main\n\nfunc main() {\n\t// your code here\n}\n";
  const answer = 'package main\n\nfunc main() {\n\tfmt.Println("hi")\n}\n';

  it("holes only the lines the starter does not have", () => {
    const holes = solutionBlanks(answer, starter);
    expect(holes.length).toBe(1);
    expect(answer.slice(holes[0].from, holes[0].to)).toBe('fmt.Println("hi")');
  });

  it("leaves a line's indentation out of the hole — the mode fills that", () => {
    const [hole] = solutionBlanks(answer, starter);
    expect(answer[hole.from - 1]).toBe("\t");
  });

  it("keeps an untouched middle out of it when the solution is in two places", () => {
    const s2 = "import a\n\nfunc main() {\n}\n";
    const a2 = "import a\nimport b\n\nfunc main() {\n\tgo()\n}\n";
    const holes = solutionBlanks(a2, s2);
    const cut = holes.map((h) => a2.slice(h.from, h.to));
    expect(cut).toEqual(["import b", "go()"]);
  });

  it("hands over the whole thing when the answer is the starter", () => {
    // Nothing is new, so nothing would be left to type — the drill is worth
    // more as plain ANSWER than as an empty one.
    const holes = solutionBlanks(starter, starter);
    const cut = holes.map((h) => starter.slice(h.from, h.to));
    expect(cut).toContain("package main");
  });

  it("holes everything when the quest shipped no starter at all", () => {
    const holes = solutionBlanks(answer, "");
    const cut = holes.map((h) => answer.slice(h.from, h.to));
    expect(cut).toContain("package main");
    expect(cut).toContain('fmt.Println("hi")');
  });

  it("the drill, played out, is the answer", () => {
    const target = { text: answer, blanks: solutionBlanks(answer, starter) };
    let typed = "";
    for (let i = 0; i < 500; i++) {
      const add = blanksFill(typed, target);
      if (add !== null) {
        typed += add;
        continue;
      }
      if (typed.length >= answer.length) break;
      typed += answer[typed.length];
    }
    expect(typed).toBe(answer);
  });
  it("gives the whole answer when the starter only loses a line", () => {
    // A "delete the bug" quest shares every line the answer has; the player
    // would otherwise have nothing at all to type.
    const starter = "package main\n\nfunc f() {\n\tbad()\n\tgood()\n}\n";
    const answer = "package main\n\nfunc f() {\n\tgood()\n}\n";
    const holes = solutionBlanks(answer, starter);
    expect(holes.length).toBe(4);
    expect(answer.slice(holes[0].from, holes[0].to)).toBe("package main");
    expect(answer.slice(holes[2].from, holes[2].to)).toBe("good()");
  });
});
