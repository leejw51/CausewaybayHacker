/**
 * *Why* a street matched, worked out from the three numbers `SearchHit` sends.
 *
 * SPEC §8.3 fuses two rankings with reciprocal-rank fusion — `1 / (60 + rank)`
 * summed over BM25 and cosine — "rather than a weighted sum of scores because
 * BM25 scores and cosine similarities are not on the same scale and pretending
 * they are produces a ranking that is neither". The response then carries the
 * components as well as the fused score for one stated reason: "so the search
 * screen can show *why* something matched".
 *
 * That is the most interesting thing in the payload and it is the thing this
 * module exists to make drawable. Nothing here touches a canvas, because the
 * two judgements below are the ones that can be wrong:
 *
 *   - which of the two indexes actually found a hit, which is a null check and
 *     nothing more (§5.5: a component is "null if not in that ranking");
 *   - how to put two incomparable numbers on the same bar without implying they
 *     are comparable — see `normalise`.
 */
import type { SearchHit, SearchMode } from "../net/protocol";

/** Which index or indexes produced this hit. */
export type Found = "both" | "text" | "meaning" | "neither";

export function foundBy(hit: Pick<SearchHit, "bm25" | "cosine">): Found {
  const text = hit.bm25 !== null && hit.bm25 !== undefined;
  const meaning = hit.cosine !== null && hit.cosine !== undefined;
  if (text && meaning) return "both";
  if (text) return "text";
  if (meaning) return "meaning";
  return "neither";
}

/**
 * The line beside a hit. It names the *index*, not the score.
 *
 * "BOTH INDEXES AGREE" is the one worth reading: under RRF a document that
 * appears in both rankings gets two contributions and one that appears in
 * neither cannot be here at all, so agreement is the whole reason the fused
 * order differs from either input order.
 */
export function foundLine(hit: Pick<SearchHit, "bm25" | "cosine">, mode: SearchMode): string {
  const found = foundBy(hit);
  if (mode === "bm25") return "WORD MATCH";
  if (mode === "semantic") return "MEANING MATCH";
  switch (found) {
    case "both":
      return "BOTH INDEXES AGREE";
    case "text":
      return "WORDS ONLY";
    case "meaning":
      return "MEANING ONLY";
    case "neither":
      // Not reachable from a server that fills the components in, and drawn
      // rather than hidden if it happens: a hit with no explanation is still a
      // hit, and pretending it is not is worse than admitting we cannot say.
      return "FUSED";
  }
}

/** One hit's two components, each 0..1 within this result set, or null. */
export interface Bars {
  bm25: number | null;
  cosine: number | null;
}

/**
 * The components, scaled so they can be drawn side by side.
 *
 * Each component is normalised **within its own column and within this one
 * response**: the best BM25 in the list draws full and the worst draws empty,
 * and the same for cosine, independently. It is deliberately not a shared
 * scale — §8.3 says outright that these two numbers are not on one — so the
 * bars answer "which of these hits did this index like most" and never "is the
 * text score bigger than the meaning score".
 *
 * **Direction is detected, not assumed.** §8.1 uses SQLite's `bm25()`, which
 * returns a *negative* number where more negative is a better match, but
 * PROTOCOL §5.5 only calls the field "component" and a server that normalised
 * it before sending would send positives. So: if every value present is ≤ 0 the
 * column is read as lower-is-better, otherwise higher-is-better. Cosine is
 * never flipped — §8.2's vectors are L2-normalised and a cosine is
 * higher-is-better by construction.
 *
 * A column where every hit has the same value draws full rather than empty. One
 * hit is the common case of that, and an only result with an empty bar reads as
 * "this barely matched" when what happened is that there was nothing to compare
 * it against.
 */
export function normalise(hits: ReadonlyArray<Pick<SearchHit, "bm25" | "cosine">>): Bars[] {
  const column = (
    values: Array<number | null>,
    lowerIsBetter: boolean | "detect",
  ): Array<number | null> => {
    const present = values.filter((v): v is number => v !== null && Number.isFinite(v));
    if (present.length === 0) return values.map(() => null);
    const flip = lowerIsBetter === "detect" ? present.every((v) => v <= 0) : lowerIsBetter;
    const min = Math.min(...present);
    const max = Math.max(...present);
    const span = max - min;
    return values.map((v) => {
      if (v === null || !Number.isFinite(v)) return null;
      if (span === 0) return 1;
      const t = (v - min) / span;
      return flip ? 1 - t : t;
    });
  };
  const clean = (v: number | null | undefined): number | null =>
    v === null || v === undefined || !Number.isFinite(v) ? null : v;
  const bm25 = column(
    hits.map((h) => clean(h.bm25)),
    "detect",
  );
  const cosine = column(
    hits.map((h) => clean(h.cosine)),
    false,
  );
  return hits.map((_, i) => ({ bm25: bm25[i], cosine: cosine[i] }));
}

/** A number as the screen prints it: short, and honest about being absent. */
export function component(v: number | null | undefined): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return "—";
  const a = Math.abs(v);
  return a >= 100 ? v.toFixed(0) : a >= 1 ? v.toFixed(2) : v.toFixed(3);
}

/** A run of snippet text, and whether FTS5 marked it as the matched term. */
export interface Run {
  text: string;
  hit: boolean;
}

/**
 * `SearchHit.snippet` comes from FTS5's `snippet()` and "may contain `<b>…</b>`"
 * (§5.5). Split into runs so the matched words can be drawn in the coin colour
 * — which is the cheapest possible way of showing *where* in the text the
 * index looked, and the reason the server bothers to mark them at all.
 *
 * Everything that is not a `<b>` or `</b>` is text, entities included: the
 * snippet is drawn onto a canvas, not into a document, so `&amp;` is decoded
 * here rather than by a parser that is not there. An unbalanced tag cannot
 * break it — the state machine only ever opens and closes, and unknown markup
 * is kept as literal text rather than silently eaten, because a quest brief is
 * full of angle brackets (`Vec<T>`) that are not markup at all.
 */
export function snippetRuns(snippet: string): Run[] {
  const runs: Run[] = [];
  let hit = false;
  let buf = "";
  let i = 0;
  const flush = () => {
    if (buf !== "") runs.push({ text: decode(buf), hit });
    buf = "";
  };
  while (i < snippet.length) {
    if (snippet.startsWith("<b>", i)) {
      flush();
      hit = true;
      i += 3;
    } else if (snippet.startsWith("</b>", i)) {
      flush();
      hit = false;
      i += 4;
    } else {
      buf += snippet[i];
      i += 1;
    }
  }
  flush();
  return runs;
}

const ENTITIES: Record<string, string> = {
  "&amp;": "&",
  "&lt;": "<",
  "&gt;": ">",
  "&quot;": '"',
  "&#39;": "'",
  "&apos;": "'",
};

function decode(s: string): string {
  return s.replace(/&(?:amp|lt|gt|quot|apos|#39);/g, (m) => ENTITIES[m] ?? m);
}
