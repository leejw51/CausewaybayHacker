/**
 * Just enough markdown to draw a quest brief.
 *
 * `quests.brief` is markdown (SPEC §2.1) and the canvas has no renderer, so
 * the choice is between showing the source and flattening it. Showing the
 * source means a player reads ```` ``` ```` and `**in the order**`, which is
 * worse than plain prose — the emphasis was there to help them, and raw
 * markers actively hurt.
 *
 * So: fenced blocks become an indented, monospaced run that the caller draws
 * in the code font, inline markers are stripped, and everything else is left
 * exactly as written. This is not a markdown implementation and does not want
 * to be one; a brief that needs a table is a brief that wants rewriting.
 */
export interface Block {
  kind: "prose" | "code";
  text: string;
}

/** Strip the inline markers that would otherwise be read aloud as punctuation. */
function inline(text: string): string {
  return text
    .replace(/\*\*(.+?)\*\*/gs, "$1")
    .replace(/(^|[^*])\*([^*\n]+)\*/g, "$1$2")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/^\s{0,3}#{1,6}\s+/gm, "")
    .replace(/^\s{0,3}[-*+]\s+/gm, "· ");
}

export function blocks(markdown: string): Block[] {
  const out: Block[] = [];
  let prose: string[] = [];
  let code: string[] | null = null;

  const flushProse = () => {
    if (prose.length === 0) return;
    const text = inline(prose.join("\n"))
      .replace(/\n{3,}/g, "\n\n")
      .trim();
    if (text) out.push({ kind: "prose", text });
    prose = [];
  };

  for (const line of String(markdown ?? "").split("\n")) {
    if (/^\s*```/.test(line)) {
      if (code === null) {
        flushProse();
        code = [];
      } else {
        // A fence with nothing in it is a formatting accident, not a block.
        if (code.join("\n").trim()) out.push({ kind: "code", text: code.join("\n") });
        code = null;
      }
      continue;
    }
    if (code !== null) code.push(line);
    else prose.push(line);
  }
  // An unterminated fence is still content, and losing it would lose the
  // sample input — the one part of a brief a player cannot guess.
  if (code !== null && code.join("\n").trim()) out.push({ kind: "code", text: code.join("\n") });
  flushProse();
  return out;
}
