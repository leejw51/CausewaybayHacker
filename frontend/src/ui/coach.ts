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
import { t, tn } from "../i18n";

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
  if (n >= LEARNED_AT) return t("coach.learned");
  if (n === 0) return t("coach.learnedLast");
  const left = LEARNED_AT - n;
  return t("coach.since", { since: tn("coach.cleanSubmits", n), left });
}

/** What the stats screen puts at the top of the drill list. */
export function drillHeadline(mistakes: MistakeStat[]): string {
  const live = mistakes.filter((m) => !isLearned(m));
  if (live.length === 0) return t("coach.nothingOnDrill");
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
      head: t("coach.noRecordHead"),
      body: t("coach.noRecordBody"),
      action: t("coach.toTheMaps"),
    };
  }
  switch (mode) {
    case "repeat":
      return {
        head: t("coach.noRepeatHead"),
        body: t("coach.noRepeatBody"),
        action: t("coach.toTheMaps"),
      };
    case "weakness":
      return ctx.learned > 0
        ? {
            head: t("coach.noWeakLeftHead"),
            body: tn("coach.noWeakLeftBody", ctx.learned),
            action: t("coach.seeShelf"),
          }
        : {
            head: t("coach.noWeakYetHead"),
            body: t("coach.noWeakYetBody"),
            action: t("coach.toTheMaps"),
          };
    case "spaced":
      return ctx.cleared === 0
        ? {
            head: t("coach.noSpacedHead"),
            body: t("coach.noSpacedBody"),
            action: t("coach.toTheMaps"),
          }
        : {
            head: t("coach.nothingDueHead"),
            body: t("coach.nothingDueBody", { n: ctx.cleared }),
            action: t("coach.toTheMaps"),
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
      head: t("search.emptyHead", { n: 126 }),
      body: t("search.emptyBody"),
      action: t("search.search"),
    };
  }
  if (!searched) {
    return {
      head: t("search.readyHead"),
      body: t("search.readyBody", { q: q.trim() }),
      action: t("search.search"),
    };
  }
  return {
    head: t("search.noneHead"),
    body: t("search.noneBody", { q: q.trim() }),
    action: t("search.clear"),
  };
}
