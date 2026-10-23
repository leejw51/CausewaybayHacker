import { describe, expect, it } from "vitest";
import { runMessage } from "../src/ui/computer";
import type { PlaygroundRun } from "../src/net/protocol";

const run = {
  outcome: "compile_error",
  stderr: "error: unknown identifier foo\n  main.rs:3:5\n",
  diagnostics: [],
} as unknown as PlaygroundRun;

describe("retro compiler messages", () => {
  for (const machine of ["msx", "apple2", "amiga"] as const) {
    it(`${machine} displays the actual compiler output`, () => {
      expect(runMessage(machine, run)).toEqual(["error: unknown identifier foo", "  main.rs:3:5"]);
      expect(runMessage(machine, { ...run, stderr: "error: missing semicolon" })).toEqual([
        "error: missing semicolon",
      ]);
    });
  }
  it("uses diagnostics when stderr is empty", () => {
    expect(
      runMessage("msx", {
        ...run,
        stderr: "",
        diagnostics: [
          { kind: "error", code: "E0425", message: "cannot find foo", line: 3, col: 5 },
        ],
      }),
    ).toEqual(["error E0425 (3:5): cannot find foo"]);
  });
  it("removes terminal color escapes", () => {
    expect(runMessage("amiga", { ...run, stderr: "\x1b[31merror\x1b[0m\r\n" })).toEqual(["error"]);
  });
  it("reports absent diagnostics without inventing a syntax error", () => {
    expect(runMessage("apple2", { ...run, stderr: "" })).toEqual([
      "Compilation failed (no compiler message returned).",
    ]);
  });
});
