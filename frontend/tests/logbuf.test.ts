/**
 * PROTOCOL §4.18 and conformance §8.8: `run.log` chunks split anywhere,
 * including mid-line, and `seq` counts from 0 per stream per attempt.
 *
 * A client that printed chunks as lines looks perfectly correct against a
 * server that happens to send whole lines, and falls apart the first time a
 * compiler error lands across a buffer boundary. So the cases below split in
 * the places that matter.
 */
import { describe, expect, it } from "vitest";
import { LogBuffer } from "../src/net/logbuf";

describe("run.log reassembly", () => {
  it("joins a line that arrived in pieces", () => {
    const b = new LogBuffer("att_1");
    b.push("compile", "error[E0382]: borrow of ", 0);
    b.push("compile", "moved value: `s`\n", 1);
    expect(b.lines).toEqual([
      { stream: "compile", text: "error[E0382]: borrow of moved value: `s`" },
    ]);
  });

  it("holds back a line that has no newline yet", () => {
    const b = new LogBuffer("att_1");
    b.push("stdout", "half a line", 0);
    expect(b.lines).toEqual([]);
    b.push("stdout", " and the rest\n", 1);
    expect(b.lines.map((l) => l.text)).toEqual(["half a line and the rest"]);
  });

  it("emits the un-newlined tail when the attempt ends", () => {
    // A compiler's last line often has no trailing newline, and that is
    // frequently the one the player needed to read.
    const b = new LogBuffer("att_1");
    b.push("stderr", "thread 'main' panicked", 0);
    expect(b.lines).toEqual([]);
    b.end();
    expect(b.lines.map((l) => l.text)).toEqual(["thread 'main' panicked"]);
    b.end(); // idempotent
    expect(b.lines).toHaveLength(1);
  });

  it("splits a chunk that carries several lines at once", () => {
    const b = new LogBuffer("att_1");
    b.push("compile", "one\ntwo\nthree\n", 0);
    expect(b.lines.map((l) => l.text)).toEqual(["one", "two", "three"]);
  });

  it("counts seq per stream, so interleaved streams do not look like gaps", () => {
    const b = new LogBuffer("att_1");
    expect(b.push("compile", "c0\n", 0)).toBe(true);
    expect(b.push("stdout", "o0\n", 0)).toBe(true);
    expect(b.push("compile", "c1\n", 1)).toBe(true);
    expect(b.push("stdout", "o1\n", 1)).toBe(true);
    expect(b.complete).toBe(true);
    expect(b.lines.map((l) => `${l.stream}:${l.text}`)).toEqual([
      "compile:c0",
      "stdout:o0",
      "compile:c1",
      "stdout:o1",
    ]);
  });

  it("notices a gap, names the stream, and keeps going", () => {
    const b = new LogBuffer("att_1");
    b.push("stdout", "first\n", 0);
    expect(b.push("stdout", "third\n", 2)).toBe(false);
    expect(b.complete).toBe(false);
    expect([...b.gaps]).toEqual(["stdout"]);
    // Refusing the chunk would lose more than accepting it, so the buffer
    // resynchronises on whatever the server actually sent.
    expect(b.push("stdout", "fourth\n", 3)).toBe(true);
    expect(b.lines.map((l) => l.text)).toEqual(["first", "third", "fourth"]);
  });

  it("keeps only the tail, because the full text is on the server", () => {
    const b = new LogBuffer("att_1", 10);
    for (let i = 0; i < 50; i++) b.push("stdout", `line ${i}\n`, i);
    expect(b.lines).toHaveLength(10);
    expect(b.lines[0].text).toBe("line 40");
    expect(b.lines[9].text).toBe("line 49");
  });

  it("survives a chunk that is only a newline, and an empty one", () => {
    const b = new LogBuffer("att_1");
    b.push("stdout", "", 0);
    b.push("stdout", "\n", 1);
    expect(b.lines.map((l) => l.text)).toEqual([""]);
  });
});
