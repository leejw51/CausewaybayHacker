/**
 * The typing effects, the half of them that is arithmetic.
 *
 * `ui/codefx.ts` paints; these are the decisions it paints from. Two things
 * are pinned. The plans: every gesture throws *something*, scaled to the
 * type size, in colours that are the palette's and shapes the shader knows.
 * And the editor's reading of a keystroke: which character is which colour,
 * and — the one that matters most — when a loop counts as closed, per
 * language, because a celebration that fires on every brace is noise and one
 * that never fires is a feature nobody finds.
 */
import { EditorState } from "@codemirror/state";
import { rust } from "@codemirror/lang-rust";
import { go } from "@codemirror/lang-go";
import { cpp } from "@codemirror/lang-cpp";
import { python } from "@codemirror/lang-python";
import { describe, expect, it } from "vitest";
import {
  RUBBLE_MAX,
  dustPlan,
  keyPlan,
  linkPlan,
  loopPlan,
  ribbon,
  rubblePlan,
  trailPlan,
  type Plan,
} from "../src/engine/burst";
import { Theme } from "../src/engine/theme";
import { trim } from "../src/ui/codefx";
import { bracketPairAt, loopClosedBy, toneOf } from "../src/ui/editor";
import type { Land } from "../src/net/protocol";

/** A generator that is the same every run, so a plan is a fixed picture. */
function seeded(seed = 7): () => number {
  let r = seed >>> 0 || 1;
  return () => {
    r = (Math.imul(r, 1664525) + 1013904223) >>> 0;
    return r / 4294967296;
  };
}

const CELL = [10, 22] as const;

function finite(plan: Plan): void {
  for (const p of plan.particles) {
    for (const v of [p.x, p.y, p.dx, p.dy, p.tox, p.toy, p.liftx, p.lifty, p.life, p.size]) {
      expect(Number.isFinite(v)).toBe(true);
    }
    expect(p.life).toBeGreaterThan(0);
    expect(p.size).toBeGreaterThan(0);
    expect(p.delay).toBeGreaterThanOrEqual(0);
    expect([0, 1, 2, 3, 4, 5, 6]).toContain(p.shape);
  }
  for (const r of plan.rings) {
    expect(r.radius).toBeGreaterThan(0);
    expect(r.life).toBeGreaterThan(0);
  }
}

describe("the plans", () => {
  it("a keystroke throws sparks in the token's colour, and a paste throws more", () => {
    const one = keyPlan(100, 100, CELL, Theme.grass, 1, seeded());
    const many = keyPlan(100, 100, CELL, Theme.grass, 40, seeded());
    finite(one);
    expect(one.particles.length).toBeGreaterThan(0);
    expect(many.particles.length).toBeGreaterThan(one.particles.length);
    // Most of them are the token's colour; the rest are the white-hot core.
    const green = one.particles.filter((p) => p.color === Theme.grass).length;
    expect(green).toBeGreaterThan(one.particles.length / 2);
    expect(one.rings).toHaveLength(1);
    expect(one.rings[0].glow).toBe(true);
  });

  it("a keystroke's reach scales with the type size", () => {
    const small = keyPlan(0, 0, [6, 12], Theme.cream, 1, seeded());
    const big = keyPlan(0, 0, [12, 24], Theme.cream, 1, seeded());
    const reach = (p: Plan) => Math.max(...p.particles.map((q) => Math.hypot(q.dx, q.dy)));
    expect(reach(big)).toBeCloseTo(reach(small) * 2, 5);
  });

  it("ENTER is dust: puffs that rise, in dust colours, along the new line", () => {
    const plan = dustPlan(50, 200, CELL, seeded());
    finite(plan);
    const puffs = plan.particles.filter((p) => p.shape === 5);
    expect(puffs.length).toBeGreaterThan(8);
    for (const p of puffs) {
      expect(p.gravity).toBeLessThan(0);
      expect(p.dy).toBeLessThan(0);
    }
    // Mostly to the right — that is where the line is.
    const right = puffs.filter((p) => p.dx > 0).length;
    expect(right).toBeGreaterThan(puffs.length / 2);
  });

  it("deleted characters break into bricks that fall, each in its own colour", () => {
    const one = rubblePlan([{ x: 300, y: 120, color: Theme.pink }], CELL, seeded());
    finite(one);
    const bricks = one.particles.filter((p) => p.shape === 4);
    expect(bricks).toHaveLength(3);
    for (const b of bricks) {
      expect(b.gravity).toBeGreaterThan(500);
      expect(b.trail).toBe(false);
      // A shade of pink: the red channel dominates, as in the source colour.
      expect(b.color[0]).toBeGreaterThan(b.color[1]);
      // Thrown from inside its own cell.
      expect(b.x).toBeGreaterThanOrEqual(300);
      expect(b.x).toBeLessThanOrEqual(310);
    }
    // A line of twelve: a cell each, crumbling left to right.
    const cells = Array.from({ length: 12 }, (_, i) => ({
      x: 100 + i * CELL[0],
      y: 50,
      color: i < 3 ? Theme.pink : Theme.grass,
    }));
    const line = rubblePlan(cells, CELL, seeded());
    finite(line);
    const chunks = line.particles.filter((p) => p.shape === 4);
    expect(chunks).toHaveLength(36);
    const first = Math.min(...chunks.slice(0, 3).map((p) => p.delay));
    const last = Math.min(...chunks.slice(-3).map((p) => p.delay));
    expect(last).toBeGreaterThan(first);
    // The green cells throw green, the pink ones pink.
    expect(chunks[0].color[0]).toBeGreaterThan(chunks[0].color[1]);
    expect(chunks[35].color[1]).toBeGreaterThan(chunks[35].color[0]);
    expect(line.rings).toHaveLength(1);
  });

  it("a landslide is capped: fewer chunks per cell, never more than the limit", () => {
    const many = Array.from({ length: 1000 }, (_, i) => ({ x: i * 10, y: 0, color: Theme.cream }));
    const plan = rubblePlan(many, CELL, seeded());
    const chunks = plan.particles.filter((p) => p.shape === 4);
    expect(chunks).toHaveLength(RUBBLE_MAX * 2);
    expect(rubblePlan([], CELL, seeded()).particles).toHaveLength(0);
  });

  it("the pointer's trail is one ember on the path, drifting against the motion", () => {
    const plan = trailPlan(100, 100, 800, 0, 0.1, seeded());
    finite(plan);
    expect(plan.particles).toHaveLength(1);
    const p = plan.particles[0];
    expect(p.x).toBe(100);
    expect(p.y).toBe(100);
    expect(p.dx).toBeLessThan(0);
    expect(p.dy).toBeCloseTo(0, 9);
    expect(p.gravity).toBe(0);
    expect(p.shape).toBe(6);
    // A still pointer still gets a mote, just not a directed one.
    const still = trailPlan(100, 100, 0, 0, 0, seeded());
    finite(still);
    expect(still.particles[0].dx).toBeCloseTo(0, 9);
  });

  it("the ribbon's colour moves smoothly round its cycle and comes back", () => {
    expect(ribbon(0)).toEqual([...Theme.cyan.slice(0, 3), 1]);
    expect(ribbon(1)).toEqual(ribbon(0));
    // Halfway between two stops is halfway in each channel.
    const mid = ribbon(0.125);
    for (let c = 0; c < 3; c++) {
      expect(mid[c]).toBeCloseTo((Theme.cyan[c] + Theme.pink[c]) / 2, 6);
    }
    // Neighbours along the ribbon are neighbours in colour.
    const a = ribbon(0.3);
    const b = ribbon(0.31);
    for (let c = 0; c < 3; c++) expect(Math.abs(a[c] - b[c])).toBeLessThan(0.05);
  });

  it("a bracket link runs from one bracket to the other and lights both", () => {
    const plan = linkPlan([100, 100], [300, 160], CELL, seeded());
    finite(plan);
    for (const p of plan.particles) {
      expect(p.tox).toBe(200);
      expect(p.toy).toBe(60);
      expect(p.color).toBe(Theme.cyan);
    }
    expect(plan.rings).toHaveLength(2);
    expect(plan.rings[0].x).toBe(100);
    expect(plan.rings[1].x).toBe(300);
  });

  it("a closed loop runs stars up one side and down the other, then bursts", () => {
    const plan = loopPlan([200, 100], [220, 300], CELL, seeded());
    finite(plan);
    const stars = plan.particles.filter((p) => p.shape === 1 && p.gravity === 0);
    expect(stars.length).toBe(24);
    const up = stars.filter((p) => p.toy < 0);
    const down = stars.filter((p) => p.toy > 0);
    expect(up).toHaveLength(12);
    expect(down).toHaveLength(12);
    // Opposite sides of the line, so it is a loop and not a there-and-back.
    expect(Math.sign(up[0].liftx)).toBe(-Math.sign(down[0].liftx));
    // The finale comes after both legs have run.
    const finale = plan.particles.filter((p) => p.shape === 2);
    expect(finale.length).toBeGreaterThan(0);
    for (const p of finale) expect(p.delay).toBeGreaterThanOrEqual(1.35);
  });

  it("a one-line loop still gets a visible loop", () => {
    const plan = loopPlan([200, 100], [260, 100], CELL, seeded());
    const stars = plan.particles.filter((p) => p.shape === 1 && p.gravity === 0);
    for (const p of stars) expect(Math.abs(p.lifty)).toBeGreaterThanOrEqual(CELL[1] * 2.5);
  });

  it("trim keeps the shape and drops the density, and never everything", () => {
    const plan = rubblePlan(
      Array.from({ length: 4 }, (_, i) => ({ x: i * 10, y: 0, color: Theme.brick })),
      CELL,
      seeded(),
    );
    const less = trim(plan, 0.25);
    expect(less.particles.length).toBe(Math.ceil(plan.particles.length * 0.25));
    expect(less.rings).toBe(plan.rings);
    expect(trim({ particles: plan.particles.slice(0, 1), rings: [] }, 0.01).particles).toHaveLength(
      1,
    );
  });
});

const MODE = { rust, go, cpp, python } as const;

function state(lang: Land, doc: string): EditorState {
  return EditorState.create({ doc, extensions: [MODE[lang]()] });
}

describe("toneOf: which colour a character is", () => {
  it("reads the syntax tree where it has one", () => {
    const rs = `fn main() {\n    let s = "hi";\n    let n = 42;\n    println!("{s}");\n}\n`;
    const st = state("rust", rs);
    const at = (needle: string, off = needle.length) => rs.indexOf(needle) + off;
    expect(toneOf(st, at("fn"), "n")).toBe("keyword");
    expect(toneOf(st, at("let"), "t")).toBe("keyword");
    expect(toneOf(st, at('"hi'), "i")).toBe("string");
    expect(toneOf(st, at("42"), "2")).toBe("number");
    expect(toneOf(st, at("main"), "n")).toBe("name");
  });

  it("brackets are brackets before anything else", () => {
    const st = state("go", "package main\nfunc main() {}\n");
    expect(toneOf(st, 26, "{")).toBe("bracket");
    expect(toneOf(st, 27, "}")).toBe("bracket");
  });

  it("falls back to the character when the tree does not know", () => {
    const st = state("python", "x = ");
    expect(toneOf(st, 4, " ")).toBe("plain");
    expect(toneOf(st, 4, "7")).toBe("number");
    expect(toneOf(st, 4, "+")).toBe("operator");
    expect(toneOf(st, 4, "'")).toBe("string");
  });
});

/** Type `text` into `doc` at `at`, and ask the editor's rule about it. */
function closes(lang: Land, doc: string, at: number, text: string) {
  const next = doc.slice(0, at) + text + doc.slice(at);
  return loopClosedBy(state(lang, next), lang, at, text);
}

describe("loopClosedBy: when a loop counts as finished", () => {
  it("rust: the brace that closes a for, while or loop — and not a fn", () => {
    const body = 'fn main() {\n    for i in 0..3 {\n        println!("{i}");\n    ';
    const r = closes("rust", body + "\n}\n", body.length, "}");
    expect(r).not.toBeNull();
    expect(body.slice(r!.from, r!.from + 3)).toBe("for");
    expect(r!.to).toBe(body.length + 1);

    const w = "fn main() {\n    while true { break; ";
    expect(closes("rust", w + "\n}\n", w.length, "}")).not.toBeNull();
    const l = "fn main() {\n    loop { break; ";
    expect(closes("rust", l + "\n}\n", l.length, "}")).not.toBeNull();

    // The function's own brace is not a loop.
    const f = "fn main() {\n    let x = 1;\n";
    expect(closes("rust", f, f.length, "}")).toBeNull();
    // Nor is an `if`.
    const i = "fn main() {\n    if true { ";
    expect(closes("rust", i + "\n}\n", i.length, "}")).toBeNull();
  });

  it("a brace inside an unfinished string is a character, not a closer", () => {
    // Typing `println!("{i}")` one key at a time passes through `"{i}` —
    // and at that moment everything unfinished above ends at the caret.
    const s = 'fn extra() {\n    for i in 0..3 {\n        println!("{i';
    expect(closes("rust", s, s.length, "}")).toBeNull();
    // The same brace once the string is closed and the body is done: yes.
    const done = 'fn extra() {\n    for i in 0..3 {\n        println!("{i}");\n    ';
    expect(closes("rust", done + "\n}\n", done.length, "}")).not.toBeNull();
  });

  it("a loop with a parse error in its body is not finished", () => {
    const broken = "fn main() {\n    for i in 0..3 {\n        let = ;\n    ";
    expect(closes("rust", broken + "\n}\n", broken.length, "}")).toBeNull();
  });

  it("go: the brace that closes a for", () => {
    const body = "package main\nfunc main() {\n\tfor i := 0; i < 3; i++ {\n\t\tprintln(i)\n\t";
    const r = closes("go", body + "\n}\n", body.length, "}");
    expect(r).not.toBeNull();
    expect(body.slice(r!.from, r!.from + 3)).toBe("for");
    const f = "package main\nfunc main() {\n\tx := 1\n";
    expect(closes("go", f, f.length, "}")).toBeNull();
  });

  it("cpp: for, while, range-for close on their brace; do-while on its semicolon", () => {
    const f = "int main() {\n  for (int i = 0; i < 3; i++) {\n    x++;\n  ";
    expect(closes("cpp", f + "\n}\n", f.length, "}")).not.toBeNull();
    const w = "int main() {\n  while (x < 3) { x++; ";
    expect(closes("cpp", w + "\n}\n", w.length, "}")).not.toBeNull();
    const rf = "int main() {\n  for (auto v : xs) { ";
    expect(closes("cpp", rf + "\n}\n", rf.length, "}")).not.toBeNull();
    const dw = "int main() {\n  do { x++; } while (x < 3)";
    const r = closes("cpp", dw + "\n}\n", dw.length, ";");
    expect(r).not.toBeNull();
    expect(dw.slice(r!.from, r!.from + 2)).toBe("do");
    // A plain statement's semicolon is not a loop.
    const s = "int main() {\n  int x = 1";
    expect(closes("cpp", s + "\n}\n", s.length, ";")).toBeNull();
  });

  it("python: ENTER at the end of the first body line, and only that line", () => {
    const header = "for i in range(3):";
    // ENTER after the header: the loop has no body yet.
    expect(closes("python", header + "\n", header.length, "\n    ")).toBeNull();
    // ENTER after the first body line: done.
    const first = header + "\n    print(i)";
    const r = closes("python", first + "\n", first.length, "\n    ");
    expect(r).not.toBeNull();
    expect(r!.from).toBe(0);
    expect(r!.to).toBe(first.length);
    // ENTER after the second: already celebrated, nothing more.
    const second = first + "\n    print(i * 2)";
    expect(closes("python", second + "\n", second.length, "\n    ")).toBeNull();
    // A while loop counts the same way.
    const w = "while x:\n    x -= 1";
    expect(closes("python", w + "\n", w.length, "\n    ")).not.toBeNull();
    // ENTER in the middle of a line is a split, not a finish.
    expect(closes("python", first + "\n", first.length - 3, "\n")).toBeNull();
    // A plain character never closes anything.
    expect(closes("python", first, first.length, ")")).toBeNull();
  });

  it("nothing at all is nothing", () => {
    expect(closes("rust", "fn main() {}", 11, "")).toBeNull();
    expect(closes("go", "package main", 12, "x")).toBeNull();
  });
});

describe("bracketPairAt", () => {
  it("finds the pair on either side of the caret, open first", () => {
    const st = state("rust", "fn main() { (1 + 2) }");
    // Caret just after `(`: the open bracket is to its left.
    expect(bracketPairAt(st, 13)).toEqual([12, 18]);
    // Caret just before `)`.
    expect(bracketPairAt(st, 18)).toEqual([12, 18]);
    // Caret in the middle of the expression: no bracket beside it.
    expect(bracketPairAt(st, 15)).toBeNull();
  });
});
