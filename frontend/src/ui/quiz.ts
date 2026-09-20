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
