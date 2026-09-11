/**
 * The coach's arithmetic and the coach's vocabulary, with no canvas in it.
 *
 * Two things live here because they are the parts of the stats and AI screens
 * that can actually be *wrong*, and a drawing routine cannot be unit-tested:
 *
 *   1. **Progress towards learned.** SPEC §7.2: every submit that does not
 *      repeat a kind increments that kind's `cleared_since`, and at five the
 *      kind "is considered learned and drops out of the AI plan's priority
 *      list, without being deleted". Four-out-of-five is the single most
 *      motivating number this product has and it is one subtraction, so the
 *      subtraction gets a test rather than a comment.
 *   2. **What a drill says when it is empty.** A new player has no mistakes,
 *      which means every one of the three plans in §7.3 can legitimately come
 *      back with nothing in it. Rendering zero rows in that case would tell the
 *      player the feature is broken on the one visit where they have done
 *      nothing wrong — so each mode says which of the three different kinds of
 *      nothing it is, and points at the thing that would fill it.
 */
import type { DrillMode, MistakeStat } from "../net/protocol";

/** §7.2. Clean submits in a row before a kind is considered learned. */
export const LEARNED_AT = 5;

/** 0..1, towards `LEARNED_AT`. Clamped, because a learned kind may exceed it. */
export function tamedFraction(m: Pick<MistakeStat, "cleared_since">): number {
  const n = m.cleared_since;
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.min(1, n / LEARNED_AT);
}

export function isLearned(m: Pick<MistakeStat, "cleared_since">): boolean {
  return m.cleared_since >= LEARNED_AT;
}

/**
 * The sentence under a mistake row.
 *
 * Phrased forwards — what is left to do — rather than backwards, because
 * "1 MORE CLEAN SUBMIT" is an instruction and "cleared_since: 4" is a field
 * name. The zero case is the only one that mentions the mistake at all: a
 * player who has just made it does not need to be told how far they are from
 * five, they need to be told this is the one to go and fix.
 */
export function tamedLine(m: Pick<MistakeStat, "cleared_since">): string {
  const n = Math.max(0, Math.floor(m.cleared_since));
  if (n >= LEARNED_AT) return "LEARNED — OFF THE DRILL";
  if (n === 0) return "MADE IT ON YOUR LAST SUBMIT";
  const left = LEARNED_AT - n;
  const submits = n === 1 ? "1 CLEAN SUBMIT" : `${n} CLEAN SUBMITS`;
  return `${submits} SINCE — ${left} TO GO`;
}

/** What the stats screen puts at the top of the drill list. */
export function drillHeadline(mistakes: MistakeStat[]): string {
  const live = mistakes.filter((m) => !isLearned(m));
  if (live.length === 0) return "NOTHING IS ON THE DRILL";
  const worst = live.reduce((a, b) => (b.count > a.count ? b : a));
  return `${worst.label.toUpperCase()} — ${worst.count}×`;
}

export interface EmptyState {
  /** The headline, in the screen's own voice. */
  head: string;
  /** One or two sentences saying why it is empty and what fills it. */
  body: string;
  /** The label of the one button that does something about it. */
  action: string;
}

/** What the player has done so far, as far as an empty state needs to know. */
export interface CoachContext {
  /** Kinds with `cleared_since < LEARNED_AT`. */
  live: number;
  /** Kinds the player has beaten. */
  learned: number;
  cleared: number;
  attempts: number;
}

/**
 * A drill that came back with an empty plan, per mode.
 *
 * Each of the three plans in §7.3 is built from a different table, so each of
 * them is empty for a different reason and only one sentence out of the three
 * is ever true. Saying "no drills" for all three would be the same as saying
 * nothing.
 */
export function emptyDrill(mode: DrillMode, ctx: CoachContext): EmptyState {
  if (ctx.attempts === 0) {
    return {
      head: "THE COACH HAS NOT MET YOU YET",
      body:
        "Every plan here is built from your own record — what you failed, what you got wrong, " +
        "what you cleared and when. Go and make some. Anything you do on a street writes the " +
        "first row.",
      action: "TO THE MAPS",
    };
  }
  switch (mode) {
    case "repeat":
      return {
        head: "NOTHING TO REPEAT",
        body:
          "REPEAT is the quests you failed, hardest first. You have not failed one that is " +
          "still standing — which is the good version of an empty list. Try WEAKNESS, or go " +
          "and find a street that beats you.",
        action: "TO THE MAPS",
      };
    case "weakness":
      return ctx.learned > 0
        ? {
            head: "NO WEAK SPOT LEFT",
            body:
              `You have beaten ${ctx.learned} mistake ${ctx.learned === 1 ? "kind" : "kinds"} ` +
              `and nothing is above the line. WEAKNESS drills the kinds you are still making, ` +
              `so it fills up again the moment the compiler catches you.`,
            action: "SEE THE SHELF",
          }
        : {
            head: "NO WEAK SPOT YET",
            body:
              "WEAKNESS groups your compiler errors by kind and hands you five different " +
              "shapes of the one you make most. Nothing has been classified yet, so there is " +
              "nothing to group.",
            action: "TO THE MAPS",
          };
    case "spaced":
      return ctx.cleared === 0
        ? {
            head: "NOTHING TO COME BACK TO",
            body:
              "SPACED brings a cleared quest back before you forget it — three stars in a " +
              "fortnight, one star in two days. Clear one and it joins the queue.",
            action: "TO THE MAPS",
          }
        : {
            head: "NOTHING IS DUE",
            body:
              `All ${ctx.cleared} of your clears are still fresh. SPACED will bring them back ` +
              "on their own schedule; there is nothing useful to review today.",
            action: "TO THE MAPS",
          };
  }
}

/**
 * What the search screen says instead of a list of hits.
 *
 * §4.12: "An empty `q` returns no hits rather than everything" — so a blank box
 * and a query that matched nothing are two different screens, and the one that
 * has not been asked anything yet must not read as a failure.
 */
export function emptySearch(q: string, searched: boolean): EmptyState {
  if (q.trim() === "") {
    return {
      head: "ONE BOX, 126 STREETS",
      body:
        "Type what you half-remember — a word from the brief, a concept, the shape of the " +
        "bug. UNIFIED asks the text index and the meaning index both and fuses the two " +
        "rankings, and every hit shows you which of them found it.",
      action: "SEARCH",
    };
  }
  if (!searched) {
    return { head: "READY", body: `Press ENTER to look for “${q.trim()}”.`, action: "SEARCH" };
  }
  return {
    head: "NOTHING MATCHED",
    body:
      `No street mentions “${q.trim()}”. The meaning index is a hashed one — it is not a ` +
      "language model and will not find CONCURRENCY from PARALLEL — so a plainer word, or " +
      "one that would appear in the brief itself, usually finds it.",
    action: "CLEAR",
  };
}
