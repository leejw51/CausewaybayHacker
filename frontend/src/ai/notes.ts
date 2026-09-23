/**
 * The coder's answer, as a comment in the file it is about.
 *
 * A reply in the room is read once and scrolls away; a reply in the code sits
 * next to the line it is about and is still there tomorrow, in the pad that
 * gets saved and in the draft the server keeps. So every answer can also be
 * written into the buffer as a comment block above the caret's line — the
 * place the person was looking when they asked.
 *
 * Pure, and here rather than in the coder, because the shape of it is the
 * part worth testing: a comment that opens a fence it never closes, or that
 * lets a line through unprefixed, is a file that does not compile.
 */
import type { Land } from "../net/protocol";

/** How each land spells "the rest of this line is not code". */
export const LINE_COMMENT: Record<Land, string> = {
  rust: "//",
  go: "//",
  cpp: "//",
  python: "#",
  pytorch: "#",
  typescript: "//",
};

/** The mark that says who wrote the comment, so it reads as the coder's. */
export const NOTE_MARK = "AI:";

/** Where a comment stops being a comment and becomes a margin. */
const COLS = 72;

/**
 * Wrap `text` to `cols`, on spaces, never breaking a word that is longer
 * than the line — a URL or an identifier goes over rather than in half.
 */
function wrapWords(text: string, cols: number): string[] {
  const out: string[] = [];
  for (const para of text.split(/\n+/)) {
    let line = "";
    for (const word of para.trim().split(/\s+/)) {
      if (!word) continue;
      if (!line) line = word;
      else if (line.length + 1 + word.length <= cols) line = `${line} ${word}`;
      else {
        out.push(line);
        line = word;
      }
    }
    if (line) out.push(line);
  }
  return out;
}

/**
 * The reply as comment lines, ready to be put in above a line of code.
 *
 * The first carries `AI:`; the rest are indented under it by the width of
 * that mark, so a wrapped sentence reads as one paragraph rather than as
 * several remarks. Every line is prefixed, including the blank ones a reply
 * with paragraphs would otherwise leave as bare empty lines in the middle of
 * somebody's function.
 *
 * A reply with nothing in it is no lines at all, not an empty comment: the
 * caller inserts what it gets back, and `// ` on its own is litter.
 */
export function commentLines(text: string, lang: Land, cols = COLS): string[] {
  const mark = LINE_COMMENT[lang] ?? "//";
  const body = text.replace(/\r/g, "").trim();
  if (!body) return [];
  const pad = " ".repeat(NOTE_MARK.length + 1);
  const wrapped = wrapWords(body, Math.max(16, cols - mark.length - pad.length - 1));
  return wrapped.map((line, i) =>
    i === 0 ? `${mark} ${NOTE_MARK} ${line}` : `${mark} ${pad}${line}`,
  );
}
