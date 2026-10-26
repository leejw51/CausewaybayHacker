import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { consoleLine } from "../src/scenes/playground";
import type { PlaygroundRun } from "../src/net/protocol";

/**
 * CONSOLE puts the whole run into one line under the monitor: OK, or the
 * first error and the line it is on. Which line of a compiler's answer that
 * is, is the part worth pinning down.
 */
const run = (over: Partial<PlaygroundRun>): PlaygroundRun => ({
  attempt_id: "a",
  lang: "rust",
  outcome: "ok",
  compile_ms: 120,
  run_ms: 3,
  exit_code: 0,
  stdout: "",
  stderr: "",
  diagnostics: [],
  ...over,
});

describe("CONSOLE's one line", () => {
  it("says it is ready before anything has run, and busy while it runs", () => {
    expect(consoleLine(null, "idle")).toBe("READY. CTRL+ENTER RUNS");
    expect(consoleLine(run({}), "compiling")).toBe("RUNNING…");
  });

  it("says OK with the timings", () => {
    expect(consoleLine(run({}), "idle")).toBe("OK  compiled 120 ms  ran 3 ms");
  });

  it("takes the first error diagnostic, past the warnings", () => {
    const r = run({
      outcome: "compile_error",
      diagnostics: [
        { kind: "warning", code: null, message: "unused variable", line: 2, col: 9 },
        { kind: "error", code: "E0425", message: "cannot find value `x`", line: 3, col: 5 },
      ],
    });
    expect(consoleLine(r, "idle")).toBe("ERROR line 3: E0425 cannot find value `x`");
  });

  it("reads rustc's stderr when there are no diagnostics", () => {
    const r = run({
      outcome: "compile_error",
      stderr:
        "\x1b[1merror[E0425]\x1b[0m: cannot find value `x` in this scope\n --> src/main.rs:3:20\n  |\n",
    });
    expect(consoleLine(r, "idle")).toBe(
      "ERROR line 3: error[E0425]: cannot find value `x` in this scope",
    );
  });

  it("reads Go's stderr, which puts the place in front", () => {
    const r = run({
      lang: "go",
      outcome: "compile_error",
      stderr: "# command-line-arguments\n./main.go:5:2: undefined: x\n",
    });
    expect(consoleLine(r, "idle")).toBe("ERROR line 5: undefined: x");
  });

  it("says a crash, a timeout and a flood in a line each", () => {
    expect(
      consoleLine(
        run({ outcome: "runtime_error", exit_code: 101, stderr: "thread 'main' panicked at src/main.rs:2:5:\nboom\n" }),
        "idle",
      ),
    ).toBe("CRASH exit 101: thread 'main' panicked at src/main.rs:2:5:");
    expect(consoleLine(run({ outcome: "timeout" }), "idle")).toMatch(/^TIMEOUT/);
    expect(consoleLine(run({ outcome: "output_limit" }), "idle")).toMatch(/^OUTPUT LIMIT/);
  });

  it("never comes out as more than one line", () => {
    const r = run({ outcome: "compile_error", stderr: "error: a\nb\nc" });
    expect(consoleLine(r, "idle")).not.toContain("\n");
  });
});

const SOURCE = readFileSync(resolve(process.cwd(), "src/scenes/playground.ts"), "utf8");
const body = (fn: string) => {
  const from = SOURCE.slice(SOURCE.indexOf(fn));
  return from.slice(0, from.indexOf("\n  }\n"));
};

describe("the CONSOLE screen", () => {
  it("puts away every field the bench and CODE place", () => {
    // DOM laid over the canvas stays where it was last put unless hidden.
    const zen = body("private drawZen(");
    for (const call of [
      "this.tools.hide()",
      "this.stdinOverlay?.hide()",
      "this.nameOverlay?.hide()",
      "this.keyOverlay?.hide()",
      "this.coder?.panel.hideFields()",
      "this.outputRect = [0, 0, 0, 0]",
    ])
      expect(zen).toContain(call);
  });

  it("does not shadow the output probe the e2e harness calls", () => {
    expect(SOURCE).toContain("  console() {");
    expect(SOURCE).not.toMatch(/private console\b/);
  });

  it("gives back a lent monitor on the way out of the screen", () => {
    const leave = SOURCE.slice(SOURCE.indexOf("this.giveBackMonitor();\n    this.zen = false;"));
    expect(leave.slice(0, 200)).toContain("showComputer(false)");
  });

  it("never writes the computer or the face it lends", () => {
    for (const fn of ["private async toggleZen(", "private giveBackMonitor("]) {
      expect(body(fn)).not.toContain("writePref");
    }
  });
});
