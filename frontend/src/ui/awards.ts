/**
 * The shelf: which badge an award wears, and which sockets are still empty.
 *
 * DESIGN drew eight badge families plus the level chevron — nine shapes — and
 * within a family the tiers differ by colour and number only, because the
 * binding constraint is telling them apart at 48px rather than admiring them at
 * 256 (`docs/decisions.md`, BE's badge set). So the mapping from an award id to
 * a picture is a small table of families and three prefixes, and it lives here
 * rather than in the drawing code because it is the part that can be wrong.
 *
 * DESIGN also drew `badge_slot`: an empty recessed socket. That is the whole
 * reason `SHELF` exists. `stats.awards` (§4.14b) returns only what the player
 * *has*, so a screen built from the response alone shows a new player nothing
 * at all — and nothing reads as "this feature is not for you". A row of empty
 * sockets with names under them reads as a list of things you can go and get,
 * which is the opposite feeling for the same data.
 *
 * The catalogue is only the awards that are **one fixed thing**. The three
 * open-ended families — `cleared-<land>-<category>`, `tamed-<kind>`,
 * `level-<n>` — have no fixed count, so they are never drawn as sockets: they
 * appear on the shelf when they are earned and not before. A socket labelled
 * "LEVEL 37" would be a promise this client has no business making.
 */
import type { Award } from "../net/protocol";
import { t } from "../i18n";

/** The nine shapes, by the art name in `public/art/manifest.json`. */
export type Family =
  | "badge_stamp"
  | "badge_star"
  | "badge_flame"
  | "badge_flame_7"
  | "badge_flame_30"
  | "badge_chain"
  | "badge_chain_10"
  | "badge_chain_25"
  | "badge_watch"
  | "badge_shackle"
  | "badge_flags"
  | "badge_tally"
  | "badge_chevron"
  | "badge_cleared";

/** Exact ids, where the tier has its own picture. */
const EXACT: Record<string, Family> = {
  "first-clear": "badge_stamp",
  "quarter-century": "badge_stamp",
  perfectionist: "badge_star",
  "no-hints": "badge_star",
  "streak-3": "badge_flame",
  "streak-7": "badge_flame_7",
  "streak-30": "badge_flame_30",
  "combo-5": "badge_chain",
  "combo-10": "badge_chain_10",
  "combo-25": "badge_chain_25",
  "beat-the-clock": "badge_watch",
  "interview-ready": "badge_watch",
  polyglot: "badge_flags",
  "big-o": "badge_flags",
  century: "badge_tally",
  iterator: "badge_tally",
};

/** The open-ended families, matched on their prefix. */
const PREFIX: Array<[string, Family]> = [
  ["tamed-", "badge_shackle"],
  ["level-", "badge_chevron"],
  ["cleared-", "badge_cleared"],
];

/**
 * Which picture an award wears.
 *
 * An id this client has never heard of still gets a badge rather than a hole:
 * the server is allowed to grow the set (that is the whole design of the
 * families) and a shelf that dropped an award it could not name would hide the
 * player's own achievement behind a client that was out of date.
 */
export function badgeArt(id: string): Family {
  const exact = EXACT[id];
  if (exact) return exact;
  for (const [prefix, family] of PREFIX) {
    if (id.startsWith(prefix) && id.length > prefix.length) return family;
  }
  return "badge_stamp";
}

export interface Slot {
  id: string;
  /** The name on the socket, and the fallback when the server sends no title. */
  title: string;
  /** What earns it, in one line, from BE's table. */
  hint: string;
  art: Family;
  /** The award, once the player has it. */
  award: Award | null;
}

/**
 * Every award that is a single fixed thing, in the order DESIGN's families run
 * — progress, craft, streak, combo, clock, reach, volume.
 *
 * A function rather than a constant, because the titles and hints are
 * translated: a module-level array is built once at import time and would keep
 * whatever language the game started in for the rest of the session. It is
 * rebuilt per call, which is per frame, and sixteen `t()` lookups is a map
 * read — nothing this screen does is measured against it.
 *
 * The keys are derived from the id (`beat-the-clock` → `award.beatTheClock`,
 * plus `…Note` for the hint) so there is one name per award rather than three.
 *
 * Mastery (`tamed-*`) is missing on purpose even though it is the family this
 * game should be proudest of: there are sixteen taxonomy kinds and a shelf of
 * sixteen empty shackles would drown the seventeen sockets a player can
 * actually plan for. The stats screen makes that promise where it belongs, on
 * the mistake row itself, counting towards five.
 */
const CATALOGUE = (): ReadonlyArray<Omit<Slot, "award">> => [
  {
    id: "first-clear",
    title: t("award.firstClear" as "award.firstClear"),
    hint: t("award.firstClearNote" as "award.firstClearNote"),
    art: "badge_stamp",
  },
  {
    id: "quarter-century",
    title: t("award.quarterCentury" as "award.firstClear"),
    hint: t("award.quarterCenturyNote" as "award.firstClearNote"),
    art: "badge_stamp",
  },
  {
    id: "perfectionist",
    title: t("award.perfectionist" as "award.firstClear"),
    hint: t("award.perfectionistNote" as "award.firstClearNote"),
    art: "badge_star",
  },
  {
    id: "no-hints",
    title: t("award.noHints" as "award.firstClear"),
    hint: t("award.noHintsNote" as "award.firstClearNote"),
    art: "badge_star",
  },
  {
    id: "streak-3",
    title: t("award.streak3" as "award.firstClear"),
    hint: t("award.streak3Note" as "award.firstClearNote"),
    art: "badge_flame",
  },
  {
    id: "streak-7",
    title: t("award.streak7" as "award.firstClear"),
    hint: t("award.streak7Note" as "award.firstClearNote"),
    art: "badge_flame_7",
  },
  {
    id: "streak-30",
    title: t("award.streak30" as "award.firstClear"),
    hint: t("award.streak30Note" as "award.firstClearNote"),
    art: "badge_flame_30",
  },
  {
    id: "combo-5",
    title: t("award.combo5" as "award.firstClear"),
    hint: t("award.combo5Note" as "award.firstClearNote"),
    art: "badge_chain",
  },
  {
    id: "combo-10",
    title: t("award.combo10" as "award.firstClear"),
    hint: t("award.combo10Note" as "award.firstClearNote"),
    art: "badge_chain_10",
  },
  {
    id: "combo-25",
    title: t("award.combo25" as "award.firstClear"),
    hint: t("award.combo25Note" as "award.firstClearNote"),
    art: "badge_chain_25",
  },
  {
    id: "beat-the-clock",
    title: t("award.beatTheClock" as "award.firstClear"),
    hint: t("award.beatTheClockNote" as "award.firstClearNote"),
    art: "badge_watch",
  },
  {
    id: "interview-ready",
    title: t("award.interviewReady" as "award.firstClear"),
    hint: t("award.interviewReadyNote" as "award.firstClearNote"),
    art: "badge_watch",
  },
  {
    id: "polyglot",
    title: t("award.polyglot" as "award.firstClear"),
    hint: t("award.polyglotNote" as "award.firstClearNote"),
    art: "badge_flags",
  },
  {
    id: "big-o",
    title: t("award.bigO" as "award.firstClear"),
    hint: t("award.bigONote" as "award.firstClearNote"),
    art: "badge_flags",
  },
  {
    id: "century",
    title: t("award.century" as "award.firstClear"),
    hint: t("award.centuryNote" as "award.firstClearNote"),
    art: "badge_tally",
  },
  {
    id: "iterator",
    title: t("award.iterator" as "award.firstClear"),
    hint: t("award.iteratorNote" as "award.firstClearNote"),
    art: "badge_tally",
  },
];

/**
 * The shelf, earned first and then the empty sockets.
 *
 * Earned-first because the shelf is the player's, not the catalogue's: opening
 * it on sixteen things you have not done is a to-do list, and opening it on
 * what you have done with the rest waiting underneath is a trophy cabinet.
 * Awards outside the catalogue — a level, a tamed kind, a cleared map — keep
 * their server-given `title` and sit with the rest of the earned ones, newest
 * first, which is the order §4.14b hands them over in.
 */
export function shelf(awards: readonly Award[]): Slot[] {
  const byId = new Map(awards.map((a) => [a.id, a]));
  const earned: Slot[] = [];
  const empty: Slot[] = [];
  for (const a of awards) {
    const known = CATALOGUE().find((s) => s.id === a.id);
    earned.push({
      id: a.id,
      title: a.title || known?.title || a.id.toUpperCase(),
      hint: known?.hint ?? "",
      art: badgeArt(a.id),
      award: a,
    });
  }
  for (const slot of CATALOGUE()) {
    if (!byId.has(slot.id)) empty.push({ ...slot, award: null });
  }
  return [...earned, ...empty];
}

/** "3 OF 16" — the line over the shelf. How many of the nameable ones are in. */
export function shelfCount(awards: readonly Award[]): { have: number; of: number } {
  const ids = new Set(awards.map((a) => a.id));
  let have = 0;
  for (const slot of CATALOGUE()) if (ids.has(slot.id)) have++;
  return { have, of: CATALOGUE().length };
}
