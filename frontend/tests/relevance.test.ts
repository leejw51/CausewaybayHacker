/**
 * *Why* something matched, which is the only reason §4.12 sends the components.
 *
 * Two judgements are worth pinning, and they are both places where drawing the
 * obvious thing would lie to the player:
 *
 *   - **A missing component is not a zero.** §5.5 says `bm25` and `cosine` are
 *     "null if not in that ranking". A bar that drew null as an empty bar would
 *     say "this index hated it" when what happened is that this index never saw
 *     it, and under RRF those two produce completely different fused scores.
 *   - **BM25 and cosine do not share a scale.** §8.3 chose reciprocal-rank
 *     fusion precisely because "BM25 scores and cosine similarities are not on
 *     the same scale and pretending they are produces a ranking that is
 *     neither", so each column is normalised inside itself and never against
 *     the other.
 *
 * The direction of the BM25 column is the part that will actually break one
 * day: SQLite's `bm25()` is negative-is-better, and a server that normalised it
 * before sending would be positive-is-better. PROTOCOL calls the field only
 * "component", so the orientation is detected from the values and the detection
 * is what gets the test.
 */
import { describe, expect, it } from "vitest";
import type { SearchHit } from "../src/net/protocol";
import { component, foundBy, foundLine, normalise, snippetRuns } from "../src/ui/relevance";

const hit = (bm25: number | null, cosine: number | null): Pick<SearchHit, "bm25" | "cosine"> => ({
  bm25,
  cosine,
});

describe("which index found it", () => {
  it("tells the four cases apart", () => {
    expect(foundBy(hit(-3.2, 0.81))).toBe("both");
    expect(foundBy(hit(-3.2, null))).toBe("text");
    expect(foundBy(hit(null, 0.81))).toBe("meaning");
    expect(foundBy(hit(null, null))).toBe("neither");
  });

  it("says agreement out loud, because RRF is why it matters", () => {
    expect(foundLine(hit(-3.2, 0.81), "unified")).toBe("BOTH INDEXES AGREE");
    expect(foundLine(hit(-3.2, null), "unified")).toBe("WORDS ONLY");
    expect(foundLine(hit(null, 0.81), "unified")).toBe("MEANING ONLY");
  });

  it("does not claim a fusion the server did not do", () => {
    // A single-index answer must not be captioned as if two rankings agreed.
    expect(foundLine(hit(-3.2, null), "bm25")).toBe("WORD MATCH");
    expect(foundLine(hit(null, 0.81), "semantic")).toBe("MEANING MATCH");
  });
});

describe("the component bars", () => {
  it("keeps null as null rather than as the bottom of the bar", () => {
    const bars = normalise([hit(-1, 0.9), hit(null, 0.5), hit(-9, null)]);
    expect(bars[1].bm25).toBeNull();
    expect(bars[2].cosine).toBeNull();
    // And the ones that are present are still scaled against each other —
    // negatives, so the most negative is the best match and draws full.
    expect(bars[0].bm25).toBe(0);
    expect(bars[2].bm25).toBe(1);
  });

  it("reads a negative BM25 column as lower-is-better", () => {
    // SQLite's `bm25()` convention (§8.1): the best match is the most negative.
    const bars = normalise([hit(-9.4, null), hit(-1.1, null), hit(-5.2, null)]);
    expect(bars[0].bm25).toBe(1);
    expect(bars[1].bm25).toBe(0);
    expect(bars[2].bm25).toBeGreaterThan(0);
    expect(bars[2].bm25).toBeLessThan(1);
  });

  it("reads a positive BM25 column as higher-is-better", () => {
    const bars = normalise([hit(9.4, null), hit(1.1, null)]);
    expect(bars[0].bm25).toBe(1);
    expect(bars[1].bm25).toBe(0);
  });

  it("never flips the cosine column", () => {
    // A cosine over L2-normalised vectors (§8.2) is higher-is-better by
    // construction, whatever the other column happens to look like.
    const bars = normalise([hit(-1, 0.2), hit(-2, 0.9)]);
    expect(bars[1].cosine).toBe(1);
    expect(bars[0].cosine).toBe(0);
  });

  it("draws a lone result full rather than empty", () => {
    // One hit has nothing to be compared against. An empty bar would read as
    // "this barely matched", which is a claim the data does not support.
    expect(normalise([hit(-4.2, 0.66)])[0]).toEqual({ bm25: 1, cosine: 1 });
    expect(normalise([hit(-4, 0.5), hit(-4, 0.5)])[0]).toEqual({ bm25: 1, cosine: 1 });
  });

  it("survives an empty result set and non-finite values", () => {
    expect(normalise([])).toEqual([]);
    const bars = normalise([hit(Number.NaN, Number.POSITIVE_INFINITY), hit(-1, 0.5)]);
    expect(bars[0]).toEqual({ bm25: null, cosine: null });
    expect(bars[1]).toEqual({ bm25: 1, cosine: 1 });
  });
});

describe("the printed number", () => {
  it("is short, and an absent component says so", () => {
    expect(component(null)).toBe("—");
    expect(component(undefined)).toBe("—");
    expect(component(0.8123)).toBe("0.812");
    expect(component(-4.267)).toBe("-4.27");
    expect(component(1234.5)).toBe("1235");
  });
});

describe("the FTS5 snippet", () => {
  it("splits the marked terms out so they can be drawn in another colour", () => {
    expect(snippetRuns("the <b>borrow</b> checker")).toEqual([
      { text: "the ", hit: false },
      { text: "borrow", hit: true },
      { text: " checker", hit: false },
    ]);
  });

  it("decodes the entities FTS5 escapes", () => {
    expect(snippetRuns("Vec&lt;T&gt; &amp; friends")).toEqual([
      { text: "Vec<T> & friends", hit: false },
    ]);
  });

  it("keeps markup it does not know as text", () => {
    // A brief is full of angle brackets that are not markup: `Vec<T>` must not
    // be eaten by a parser looking for tags.
    expect(snippetRuns("impl<T> Trait")).toEqual([{ text: "impl<T> Trait", hit: false }]);
  });

  it("does not break on an unbalanced tag", () => {
    expect(snippetRuns("<b>open and never closed")).toEqual([
      { text: "open and never closed", hit: true },
    ]);
    expect(snippetRuns("</b>closed first")).toEqual([{ text: "closed first", hit: false }]);
    expect(snippetRuns("")).toEqual([]);
  });
});
