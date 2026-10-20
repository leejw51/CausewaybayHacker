/**
 * The quiz's rules, without a scene. The three that matter: the right index
 * and only the right index unlocks; a wrong pick is a miss and not a crash;
 * and once it is answered, nothing a second tap does can change that — a
 * player who found the line and then fat-fingers 3 keeps the editor.
 */
import { describe, expect, it } from "vitest";
import { quizPick, startsLocked, visibleBox, programLines, HOLE } from "../src/ui/quiz";

const quiz = { choices: ["a", "b", "c", "d"], answer: 2 };

describe("quizPick", () => {
  it("only the answer is right", () => {
    expect(quizPick(quiz, 2, false)).toBe("right");
    expect(quizPick(quiz, 0, false)).toBe("wrong");
    expect(quizPick(quiz, 1, false)).toBe("wrong");
    expect(quizPick(quiz, 3, false)).toBe("wrong");
  });

  it("ignores picks outside the four, and everything after the unlock", () => {
    expect(quizPick(quiz, 4, false)).toBe("ignored");
    expect(quizPick(quiz, -1, false)).toBe("ignored");
    expect(quizPick(quiz, 1.5, false)).toBe("ignored");
    expect(quizPick(quiz, 0, true)).toBe("ignored");
    expect(quizPick(quiz, 2, true)).toBe("ignored");
  });

  it("does nothing on a quest without a quiz", () => {
    expect(quizPick(undefined, 0, false)).toBe("ignored");
  });
});

describe("startsLocked", () => {
  it("locks an open quiz quest and nothing else", () => {
    expect(startsLocked(quiz, "open")).toBe(true);
    expect(startsLocked(quiz, "cleared")).toBe(false);
    expect(startsLocked(undefined, "open")).toBe(false);
  });
});

describe("visibleBox", () => {
  const clip: [number, number, number, number] = [0, 100, 300, 200];
  it("keeps a box that is inside the panel", () => {
    expect(visibleBox([0, 120, 300, 40], clip)).toEqual([0, 120, 300, 40]);
  });
  it("cuts a box that straddles the panel's edge to the visible part", () => {
    expect(visibleBox([0, 80, 300, 40], clip)).toEqual([0, 100, 300, 20]);
    expect(visibleBox([0, 280, 300, 40], clip)).toEqual([0, 280, 300, 20]);
  });
  it("drops a box scrolled entirely out of the panel", () => {
    expect(visibleBox([0, 20, 300, 40], clip)).toBeNull();
    expect(visibleBox([0, 320, 300, 40], clip)).toBeNull();
  });
});

describe("programLines", () => {
  it("shows a short program whole and marks the hole", () => {
    const lines = programLines("a\n\t____\nb\n");
    expect(lines.map((l) => l.kind)).toEqual(["code", "hole", "code"]);
    expect(lines[1].text).toBe("\t____");
  });

  it("cuts a long program to a window around the hole", () => {
    const body = Array.from({ length: 100 }, (_, i) => (i === 60 ? "  ____" : `line ${i}`));
    const lines = programLines(body.join("\n"), 5, 3);
    expect(lines[0]).toEqual({ kind: "cut", text: "⋮" });
    expect(lines.at(-1)).toEqual({ kind: "cut", text: "⋮" });
    expect(lines.filter((l) => l.kind === "hole")).toHaveLength(1);
    expect(lines[1].text).toBe("line 55");
    expect(lines.at(-2)!.text).toBe("line 63");
  });

  it("keeps the edge it does not need to cut", () => {
    const body = Array.from({ length: 60 }, (_, i) => (i === 2 ? HOLE : `x${i}`));
    const lines = programLines(body.join("\n"), 5, 3);
    expect(lines[0].text).toBe("x0");
    expect(lines.at(-1)!.kind).toBe("cut");
  });
});
