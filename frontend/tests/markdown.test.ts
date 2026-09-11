/**
 * `quests.brief` is markdown (SPEC §2.1) and the canvas has no renderer, so
 * the flattening is the only thing between a player and a screenful of
 * backticks. These are the cases from the real content packs.
 */
import { describe, expect, it } from "vitest";
import { blocks } from "../src/ui/markdown";

describe("brief markdown", () => {
  it("pulls a fenced block out as code", () => {
    const out = blocks("Do the thing.\n\n```\ninput:  3\noutput: 4\n```\n");
    expect(out).toEqual([
      { kind: "prose", text: "Do the thing." },
      { kind: "code", text: "input:  3\noutput: 4" },
    ]);
  });

  it("strips emphasis rather than reading it out as punctuation", () => {
    const [b] = blocks("Join them **in the order you spawned them** and print `n`.");
    expect(b.text).toBe("Join them in the order you spawned them and print n.");
  });

  it("turns headings and bullets into something a pixel font can draw", () => {
    const [b] = blocks("## Rules\n- first\n- second");
    expect(b.text).toBe("Rules\n· first\n· second");
  });

  it("keeps an unterminated fence, because that is usually the sample", () => {
    const out = blocks("Here:\n```\n3\n2 3 4");
    expect(out.map((b) => b.kind)).toEqual(["prose", "code"]);
    expect(out.find((b) => b.kind === "code")!.text).toBe("3\n2 3 4");
  });

  it("leaves plain prose exactly as written", () => {
    expect(blocks("Print `hello, causewaybay` and nothing else.")).toEqual([
      { kind: "prose", text: "Print hello, causewaybay and nothing else." },
    ]);
  });

  it("survives an empty brief", () => {
    expect(blocks("")).toEqual([]);
    expect(blocks("```\n```")).toEqual([]);
  });
});
