/**
 * VERY BASIC's quiz, the part with no canvas in it (PROTOCOL §5.3 `quiz`).
 *
 * The scene draws four choices and locks the editor; what a pick *means* is
 * decided here, so it can be checked without a DOM: the right index unlocks,
 * a wrong one is a miss, anything out of range or after the unlock is
 * ignored. A cleared quest is past its quiz.
 */
import type { Quiz } from "../net/protocol";

export type Pick = "right" | "wrong" | "ignored";

/** What choosing `i` means, given whether the quiz was already answered. */
export function quizPick(quiz: Quiz | undefined, i: number, alreadyRight: boolean): Pick {
  if (!quiz || alreadyRight) return "ignored";
  if (!Number.isInteger(i) || i < 0 || i >= quiz.choices.length) return "ignored";
  return i === quiz.answer ? "right" : "wrong";
}

/** Whether a quest opens with its editor locked behind the quiz. */
export function startsLocked(quiz: Quiz | undefined, state: string): boolean {
  return !!quiz && state !== "cleared";
}

/**
 * The part of a choice's box that is inside the scrolling panel, or null
 * when none of it is: the brief scrolls, and a choice scrolled out of the
 * panel must not take a tap meant for whatever is drawn there.
 */
export function visibleBox(
  box: readonly [number, number, number, number],
  clip: readonly [number, number, number, number],
): [number, number, number, number] | null {
  const top = Math.max(box[1], clip[1]);
  const bottom = Math.min(box[1] + box[3], clip[1] + clip[3]);
  if (bottom <= top) return null;
  return [box[0], top, box[2], bottom - top];
}

/** What stands in a quiz's program where the right choice was cut out. */
export const HOLE = "____";

/** The longest program shown whole; past it, a window around the hole. */
export const PROGRAM_WHOLE = 40;

/** One line of the program as drawn: code, the hole, or a cut. */
export type ProgramLine = { kind: "code" | "hole" | "cut"; text: string };

/**
 * The program around a quiz's hole, as the brief draws it (SPEC §0: every
 * road is picked). A short one is shown whole. A long one — a HACKER
 * solution runs to eighty lines — is cut to `before` lines above the hole and
 * `after` below it, with a `⋮` where lines were left out: the four choices
 * sit under it, and a program the player must scroll past to reach them is a
 * quiz nobody answers.
 */
export function programLines(
  program: string,
  before = 22,
  after = 14,
  whole = PROGRAM_WHOLE,
): ProgramLine[] {
  const lines = program.replace(/^\n+|\n+$/g, "").split("\n");
  const hole = lines.findIndex((l) => l.trim() === HOLE);
  const as = (l: string, i: number): ProgramLine => ({
    kind: i === hole ? "hole" : "code",
    text: l,
  });
  if (lines.length <= whole || hole < 0) return lines.map(as);
  const from = Math.max(0, hole - before);
  const to = Math.min(lines.length, hole + after + 1);
  const out: ProgramLine[] = [];
  if (from > 0) out.push({ kind: "cut", text: "⋮" });
  for (let i = from; i < to; i++) out.push(as(lines[i], i));
  if (to < lines.length) out.push({ kind: "cut", text: "⋮" });
  return out;
}
