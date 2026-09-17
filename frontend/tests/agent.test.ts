/**
 * The Rust coder, the parts of it that are decisions.
 *
 * The sprite is painted and the panel is drawn and neither is tested; what
 * is pinned here is what they are painted *from*: the typing schedule (never
 * a paste, never a crawl), the local advice (fires on the habit, not on the
 * program), the tip picker (never the same one twice running), the flight
 * (stays in its box, goes to the caret when asked, sits still under reduced
 * motion), the keys (round-trip, and a blocked store is survivable) and the
 * tool catalogue (only what the bench can honour is offered).
 */
import { describe, expect, it } from "vitest";
import { BASE_MS, FLOOR_MS, MAX_TOTAL_MS, NEWLINE_MS, schedule } from "../src/ai/typist";
import { advise, nextTip, TIPS } from "../src/ai/tips";
import { Sprite } from "../src/ui/agent/sprite";
import {
  DEFAULT_MODEL,
  readKey,
  readModel,
  readProvider,
  writeKey,
  writeModel,
  writeProvider,
  maskKey,
  readShown,
  writeShown,
  needsKey,
  ollamaHost,
} from "../src/ai/prefs";
import { numbered, runTool, toolsFor, type Bench } from "../src/ai/tools";
import { systemPrompt, MAX_ROUNDS } from "../src/ai/session";

describe("the typing schedule", () => {
  it("never types faster than the floor", () => {
    for (const ms of schedule('fn main() {\n    println!("hi");\n}\n')) {
      expect(ms).toBeGreaterThanOrEqual(FLOOR_MS);
    }
  });

  it("breathes at a newline and after a closing brace", () => {
    const s = schedule("a\nb}c");
    // The character *after* the newline waits for it; the same after `}`.
    expect(s[2]).toBeGreaterThanOrEqual(NEWLINE_MS);
    expect(s[4]).toBeGreaterThanOrEqual(BASE_MS * 0.7 + 100);
  });

  it("rushes through indentation rather than typing four spaces", () => {
    const s = schedule("\n    x");
    expect(s[1]).toBe(FLOOR_MS + 0 || s[1]); // the first space after the newline carries the breath
    expect(s[2]).toBe(FLOOR_MS);
    expect(s[3]).toBe(FLOOR_MS);
  });

  it("is bounded for a long file", () => {
    const long = "let x = 1;\n".repeat(1500);
    const total = schedule(long).reduce((a, b) => a + b, 0);
    expect(total).toBeLessThanOrEqual(MAX_TOTAL_MS + FLOOR_MS * long.length);
    // Not a paste either: the average is well above the floor's neighbourhood.
    expect(total).toBeGreaterThan(MAX_TOTAL_MS * 0.5);
  });

  it("is deterministic", () => {
    expect(schedule("hello world")).toEqual(schedule("hello world"));
  });
});

describe("the advice", () => {
  it("says nothing about a clean program", () => {
    expect(advise("rust", 'fn main() {\n    println!("hello");\n}\n')).toEqual([]);
    expect(advise("python", 'print("hi")\n')).toEqual([]);
    expect(advise("go", "package main\nfunc main() {}\n")).toEqual([]);
    expect(advise("cpp", "#include <iostream>\nint main() { std::cout << 1; }\n")).toEqual([]);
  });

  it("counts unwraps and only complains past the limit", () => {
    const three = "a.unwrap(); b.unwrap(); c.unwrap();";
    expect(advise("rust", three).map((a) => a.id)).not.toContain("rust.unwrap");
    const four = `${three} d.unwrap();`;
    expect(advise("rust", four).map((a) => a.id)).toContain("rust.unwrap");
  });

  it("sees a clone inside a loop and not outside one", () => {
    const inside = "for x in xs {\n    let y = x.clone();\n}\n";
    expect(advise("rust", inside).map((a) => a.id)).toContain("rust.clone-loop");
    const outside = "let y = x.clone();\nfor x in xs {\n}\n";
    expect(advise("rust", outside).map((a) => a.id)).not.toContain("rust.clone-loop");
  });

  it("notices an unchecked err in Go", () => {
    const src = "f, err := os.Open(p)\nb, err := io.ReadAll(f)\nif err != nil { return }\n";
    expect(advise("go", src).map((a) => a.id)).toContain("go.err-unchecked");
    const ok = "f, err := os.Open(p)\nif err != nil { return }\n";
    expect(advise("go", ok).map((a) => a.id)).not.toContain("go.err-unchecked");
  });

  it("knows the C++ and Python classics", () => {
    expect(advise("cpp", "using namespace std;\n").map((a) => a.id)).toContain("cpp.using-std");
    expect(advise("python", "def f(xs=[]):\n    pass\n").map((a) => a.id)).toContain(
      "py.mutable-default",
    );
    expect(advise("python", "try:\n    x()\nexcept:\n    pass\n").map((a) => a.id)).toContain(
      "py.bare-except",
    );
    expect(advise("python", "if x == None:\n    pass\n").map((a) => a.id)).toContain("py.eq-none");
  });

  it("gives every finding a stable id", () => {
    const a = advise("python", "def f(xs=[]):\n    pass\n");
    const b = advise("python", "def g(ys=[]):\n    return 1\n");
    expect(a.map((x) => x.id)).toEqual(b.map((x) => x.id));
  });
});

describe("the tips", () => {
  it("has a catalogue for every land", () => {
    for (const lang of ["rust", "go", "cpp", "python"] as const) {
      expect(TIPS[lang].length).toBeGreaterThanOrEqual(10);
    }
  });

  it("never picks the same tip twice running", () => {
    for (let last = 0; last < TIPS.rust.length; last++) {
      for (const roll of [0, 0.25, 0.5, 0.75, 0.999]) {
        const next = nextTip("rust", last, roll);
        expect(next).not.toBe(last);
        expect(next).toBeGreaterThanOrEqual(0);
        expect(next).toBeLessThan(TIPS.rust.length);
      }
    }
  });
});

describe("the flight", () => {
  const box = [100, 50, 400, 300] as const;

  it("stays inside its box while wandering", () => {
    const s = new Sprite(48, () => false);
    for (let i = 0; i < 2000; i++) {
      s.update(1 / 60, box, 8);
      expect(s.x).toBeGreaterThanOrEqual(box[0]);
      expect(s.x).toBeLessThanOrEqual(box[0] + box[2]);
      expect(s.y).toBeGreaterThanOrEqual(box[1]);
      expect(s.y).toBeLessThanOrEqual(box[1] + box[3]);
    }
  });

  it("actually moves while wandering", () => {
    const s = new Sprite(48, () => false);
    s.update(1 / 60, box, 8);
    const x0 = s.x;
    for (let i = 0; i < 300; i++) s.update(1 / 60, box, 8);
    expect(Math.abs(s.x - x0)).toBeGreaterThan(5);
  });

  it("goes to the caret on a peek and comes back", () => {
    const s = new Sprite(48, () => false);
    s.caret = [150, 200];
    expect(s.peek()).toBe(true);
    expect(s.state).toBe("peek");
    for (let i = 0; i < 60; i++) s.update(1 / 60, box, 8);
    // Near the seat beside the caret: right of it, about level.
    expect(s.x).toBeGreaterThan(150);
    expect(Math.abs(s.y - 200)).toBeLessThan(48);
    for (let i = 0; i < 120; i++) s.update(1 / 60, box, 8);
    expect(s.state).toBe("wander");
  });

  it("flies to the caret slow-fast-slow, not at one speed", () => {
    const s = new Sprite(48, () => false);
    // Settle in the corner first, then set off across the box.
    for (let i = 0; i < 120; i++) s.update(1 / 60, box, 8);
    s.caret = [box[0] + 60, box[1] + box[3] - 60];
    s.typing(true);
    const steps: number[] = [];
    let lx = s.x;
    let ly = s.y;
    for (let i = 0; i < 90 && (s.flying || i === 0); i++) {
      s.update(1 / 60, box, 8);
      steps.push(Math.hypot(s.x - lx, s.y - ly));
      lx = s.x;
      ly = s.y;
    }
    expect(steps.length).toBeGreaterThan(20);
    const n = steps.length;
    const early = steps[1];
    const mid = steps[Math.floor(n / 2)];
    const late = steps[n - 2];
    expect(mid).toBeGreaterThan(early * 3);
    expect(mid).toBeGreaterThan(late * 3);
    // And it arrived where it was going.
    const [sx, sy] = s.seat(box, 8);
    expect(Math.hypot(s.x - sx, s.y - sy)).toBeLessThan(3);
  });

  it("re-plans the flight when the destination jumps mid-air, and lands there", () => {
    const s = new Sprite(48, () => false);
    for (let i = 0; i < 120; i++) s.update(1 / 60, box, 8);
    s.caret = [box[0] + 60, box[1] + 60];
    s.typing(true);
    for (let i = 0; i < 10; i++) s.update(1 / 60, box, 8);
    expect(s.flying).toBe(true);
    s.caret = [box[0] + box[2] - 60, box[1] + box[3] - 60];
    for (let i = 0; i < 120; i++) s.update(1 / 60, box, 8);
    const [sx, sy] = s.seat(box, 8);
    expect(Math.hypot(s.x - sx, s.y - sy)).toBeLessThan(3);
    expect(s.flying).toBe(false);
  });

  it("will not peek with no caret, or while typing", () => {
    const s = new Sprite(48, () => false);
    expect(s.peek()).toBe(false);
    s.caret = [150, 200];
    s.typing(true);
    expect(s.peek()).toBe(false);
    s.typing(false);
    expect(s.state).toBe("wander");
  });

  it("zooms in and rocks while typing, and settles back after", () => {
    const s = new Sprite(48, () => false);
    s.caret = [150, 200];
    for (let i = 0; i < 120; i++) s.update(1 / 60, box, 8);
    expect(Math.abs(s.scale - 1)).toBeLessThan(0.08);
    s.typing(true);
    for (let i = 0; i < 60; i++) s.update(1 / 60, box, 8);
    expect(s.scale).toBeGreaterThan(1.1);
    let rocked = false;
    for (let i = 0; i < 30; i++) {
      s.update(1 / 60, box, 8);
      if (Math.abs(s.angle) > 0.03) rocked = true;
    }
    expect(rocked).toBe(true);
    s.typing(false);
    for (let i = 0; i < 120; i++) s.update(1 / 60, box, 8);
    expect(Math.abs(s.scale - 1)).toBeLessThan(0.08);
  });

  it("pulses on a keystroke and the pulse dies away exponentially", () => {
    const s = new Sprite(48, () => false);
    s.typing(true);
    s.kick();
    expect(s.pulse).toBe(1);
    const [sx, sy] = s.squash();
    expect(sx).toBeGreaterThan(1);
    expect(sy).toBeLessThan(1);
    s.update(1 / 60, box, 8);
    const a = s.pulse;
    s.update(1 / 60, box, 8);
    const b = s.pulse;
    expect(a).toBeLessThan(1);
    expect(b).toBeLessThan(a);
    // The same ratio each frame: that is what exponential means.
    expect(a).toBeCloseTo(b / a, 2);
    for (let i = 0; i < 120; i++) s.update(1 / 60, box, 8);
    expect(s.pulse).toBe(0);
    expect(s.squash()).toEqual([1, 1]);
  });

  it("barrel-rolls exactly once round, eased in and out, and comes back level", () => {
    const s = new Sprite(48, () => false);
    for (let i = 0; i < 120; i++) s.update(1 / 60, box, 8);
    s.roll();
    expect(s.rollingNow).toBe(true);
    let turned = 0;
    let last = s.angle;
    const steps: number[] = [];
    for (let i = 0; i < 120 && s.rollingNow; i++) {
      s.update(1 / 60, box, 8);
      const d = Math.abs(s.angle - last);
      if (d < Math.PI) {
        turned += d;
        steps.push(d);
      }
      last = s.angle;
    }
    expect(s.rollingNow).toBe(false);
    expect(turned).toBeGreaterThan(Math.PI * 1.5);
    // Slow into the turn and slow out of it: the middle frames turn far
    // more than the first and last.
    const n = steps.length;
    expect(steps[Math.floor(n / 2)]).toBeGreaterThan(steps[0] * 3);
    expect(steps[Math.floor(n / 2)]).toBeGreaterThan(steps[n - 1] * 3);
    for (let i = 0; i < 90; i++) s.update(1 / 60, box, 8);
    expect(Math.abs(s.angle)).toBeLessThan(0.4);
  });

  it("leaves afterimages only while moving fast, and never more than a few", () => {
    const s = new Sprite(48, () => false);
    s.caret = [box[0] + 40, box[1] + 40];
    for (let i = 0; i < 90; i++) s.update(1 / 60, box, 8);
    expect(s.trail.length).toBe(0);
    s.caret = [box[0] + box[2] - 40, box[1] + box[3] - 40];
    s.typing(true);
    let most = 0;
    for (let i = 0; i < 20; i++) {
      s.update(1 / 60, box, 8);
      most = Math.max(most, s.trail.length);
    }
    expect(most).toBeGreaterThan(0);
    expect(most).toBeLessThanOrEqual(7);
    for (let i = 0; i < 120; i++) s.update(1 / 60, box, 8);
    expect(s.trail.length).toBe(0);
  });

  it("sits still in the corner under reduced motion", () => {
    const s = new Sprite(48, () => true);
    for (let i = 0; i < 300; i++) s.update(1 / 60, box, 8);
    const [rx, ry] = s.restPoint(box);
    expect(Math.abs(s.x - rx)).toBeLessThan(1);
    expect(Math.abs(s.y - ry)).toBeLessThan(1);
    expect(s.bob()).toBe(0);
    s.typing(true);
    s.kick();
    s.roll();
    for (let i = 0; i < 30; i++) s.update(1 / 60, box, 8);
    expect(s.scale).toBe(1);
    expect(s.angle).toBe(0);
    expect(s.squash()).toEqual([1, 1]);
    expect(s.trail).toEqual([]);
  });
});

describe("the keys", () => {
  it("round-trip through the store, per provider", () => {
    writeKey("openai", "  sk-test-1234567890  ");
    expect(readKey("openai")).toBe("sk-test-1234567890");
    expect(readKey("grok")).toBe("");
    writeKey("openai", "");
    expect(readKey("openai")).toBe("");
  });

  it("fall back to the default model when none is set", () => {
    writeModel("anthropic", "");
    expect(readModel("anthropic")).toBe(DEFAULT_MODEL.anthropic);
    writeModel("anthropic", "claude-sonnet-5");
    expect(readModel("anthropic")).toBe("claude-sonnet-5");
    writeModel("anthropic", "");
  });

  it("keep the chosen provider", () => {
    writeProvider("grok");
    expect(readProvider()).toBe("grok");
    writeProvider("anthropic");
  });

  it("show the coder unless told otherwise, and remember being told", () => {
    expect(readShown()).toBe(true);
    writeShown(false);
    expect(readShown()).toBe(false);
    writeShown(true);
    expect(readShown()).toBe(true);
  });

  it("know which providers need a key, and where Ollama lives", () => {
    expect(needsKey("openai")).toBe(true);
    expect(needsKey("openrouter")).toBe(true);
    expect(needsKey("ollama")).toBe(false);
    writeKey("ollama", "");
    expect(ollamaHost()).toBe("http://localhost:11434");
    writeKey("ollama", "http://gpu-box:11434/");
    expect(ollamaHost()).toBe("http://gpu-box:11434");
    writeKey("ollama", "");
    expect(DEFAULT_MODEL.ollama).toMatch(/coder/);
    expect(DEFAULT_MODEL.openrouter).toContain("/");
  });

  it("mask a key for the screen", () => {
    expect(maskKey("")).toBe("");
    expect(maskKey("short")).toBe("•••••");
    expect(maskKey("sk-ant-api03-abcdefghijkl")).toBe("sk-ant…ijkl");
  });
});

function bench(over: Partial<Bench> = {}): Bench {
  let source = 'fn main() {\n    println!("hi");\n}\n';
  return {
    lang: "rust",
    file: "main.rs",
    read: () => source,
    write: async (s) => {
      source = s;
      return { typed: s.length, total: s.length, stopped: false };
    },
    insert: async (s) => {
      source += s;
      return { typed: s.length, total: s.length, stopped: false };
    },
    edit: async (find, replace) => {
      const at = source.indexOf(find);
      if (at < 0) return { ok: false, why: "not there" };
      source = source.slice(0, at) + replace + source.slice(at + find.length);
      return { ok: true };
    },
    run: null,
    format: null,
    search: null,
    image: null,
    ...over,
  };
}

describe("the tools", () => {
  it("offers only what the bench can honour", () => {
    const names = (b: Bench) => toolsFor(b).map((t) => t.name);
    expect(names(bench())).toEqual(["read_code", "edit_code", "write_code", "insert_code"]);
    expect(
      names(
        bench({
          run: async () => ({
            outcome: "ok",
            stdout: "",
            stderr: "",
            compile_ms: 0,
            run_ms: 0,
            exit_code: 0,
          }),
        }),
      ),
    ).toContain("run_code");
    expect(names(bench({ image: async () => "ok" }))).toContain("make_image");
  });

  it("numbers the lines the way a reviewer reads them", () => {
    expect(numbered("a\nb")).toBe("1| a\n2| b");
    expect(numbered("x\n".repeat(10)).split("\n")[0]).toBe(" 1| x");
  });

  it("answers an edit that misses with a sentence, not a throw", async () => {
    const r = await runTool(bench(), "edit_code", { find: "nope", replace: "x" });
    expect(r.error).toBe(true);
    expect(r.text).toMatch(/not/);
  });

  it("writes and reads back", async () => {
    const b = bench();
    await runTool(b, "write_code", { source: "fn main() {}\n" });
    const r = await runTool(b, "read_code", {});
    expect(r.text).toContain("1| fn main() {}");
  });

  it("refuses a run where there is none", async () => {
    const r = await runTool(bench(), "run_code", {});
    expect(r.error).toBe(true);
  });

  it("puts the file and the rules in the system prompt", () => {
    const p = systemPrompt(bench(), false);
    expect(p).toContain("main.rs");
    expect(p).toContain('println!("hi")');
    expect(p).toContain("cannot run code");
    expect(systemPrompt(bench(), true)).toContain("run_code");
    expect(MAX_ROUNDS).toBeGreaterThan(3);
  });
});
