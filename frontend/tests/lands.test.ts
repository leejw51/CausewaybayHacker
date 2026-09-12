/**
 * The land screen's geometry, and the three bugs it shipped with.
 *
 * Every case here is a thing that was actually wrong on screen when four lands
 * replaced two, not a restatement of the implementation:
 *
 *   1. four plates split the column four ways, so each got half the height it
 *      needed, the mascot no longer fitted and was skipped entirely;
 *   2. the sentence, measured upward from the bottom of a plate too short to
 *      hold it, printed over the plate's own title bar;
 *   3. and with the plates at their full height, two of the four lands were
 *      off the bottom of a column that gave no sign it scrolled.
 *
 * `landGrid` is deliberately font-free — it takes the two candidate heights
 * already measured — so all of this is checkable without a canvas.
 */
import { describe, expect, it } from "vitest";
import { capLines, landGrid } from "../src/scenes/lands";
import { landRowAt, landRowLines } from "../src/scenes/stats";
import { LANDS } from "../src/net/protocol";

/** A roomy landscape column: 980 wide, 520 tall, which is the real case. */
const COL: [number, number, number, number] = [20, 100, 980, 520];
const GAP = 10;
const MIN_COL = 260;

/** The heights the real screen measures at that width, near enough. */
const VIABLE = 240;
const COMFORTABLE = 265;

describe("landGrid — how many columns", () => {
  it("stacks two lands in one column, which is what two lands always did", () => {
    const g = landGrid(COL, 2, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, 0);
    expect(g.cols).toBe(1);
    expect(g.rows).toBe(2);
    expect(g.pw).toBe(980);
  });

  it("puts four lands two across, so every land is on screen at once", () => {
    const g = landGrid(COL, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, 0);
    expect(g.cols).toBe(2);
    expect(g.rows).toBe(2);
    // Two plates and one gap fill the column exactly.
    expect(g.pw * 2 + GAP).toBeLessThanOrEqual(980);
    expect(g.overflow).toBe(0);
  });

  it("falls back to one column when half the width is too narrow to read", () => {
    // A phone: half of 420 is under the 260 a plate needs for its sentence.
    const g = landGrid([0, 0, 420, 900], 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, 0);
    expect(g.cols).toBe(1);
    expect(g.rows).toBe(4);
  });
});

describe("landGrid — the plate is never shorter than its contents", () => {
  it("takes the fair share when the fair share is tall enough", () => {
    const g = landGrid(COL, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, 0);
    // (520 - 10) / 2 = 255, which clears the 240 a viable mascot needs.
    expect(g.ph).toBe(255);
    expect(g.ph).toBeGreaterThanOrEqual(VIABLE);
  });

  it("takes the floor instead of squashing, which is what makes it scroll", () => {
    // A short column: the fair share is well under what a plate needs.
    const short: [number, number, number, number] = [20, 100, 980, 300];
    const g = landGrid(short, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, 0);
    expect(g.ph).toBe(COMFORTABLE);
    expect(g.overflow).toBeGreaterThan(0);
  });

  it("never returns a plate too short for a mascot — the original bug", () => {
    // Whatever the column, the plate is at least the comfortable floor or a
    // fair share that already cleared the viable one. This is the invariant
    // the four-land screen broke: 520/4 = 130, a plate with no room to draw in.
    for (const h of [200, 300, 420, 520, 700, 1000]) {
      const g = landGrid([0, 0, 980, h], 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, 0);
      expect(g.ph).toBeGreaterThanOrEqual(Math.min(VIABLE, COMFORTABLE));
    }
  });
});

describe("landGrid — scrolling, and keeping the chosen land in view", () => {
  const short: [number, number, number, number] = [20, 100, 980, 300];

  it("reports no overflow when everything fits", () => {
    const g = landGrid(COL, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, 0);
    expect(g.overflow).toBe(0);
    expect(g.scroll).toBe(0);
  });

  it("clamps a scroll past the end back to the end", () => {
    // With the selection already on the bottom row, nothing pulls the window
    // back up, so this is the clamp on its own.
    const g = landGrid(short, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 3, 99999);
    expect(g.scroll).toBe(g.overflow);
  });

  it("clamps a negative scroll back to the top", () => {
    const g = landGrid(short, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, -500);
    expect(g.scroll).toBe(0);
  });

  it("lets the selection overrule a scroll that would hide it", () => {
    // Scrolled to the bottom, then the player picks the first land with the
    // arrow keys: the window has to come back, or the highlight is off-screen.
    const g = landGrid(short, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, 99999);
    expect(g.scroll).toBe(0);
  });

  it("drags the window down when the chosen land is below the fold", () => {
    // Selecting the last land from a scroll of 0 must move the window, or the
    // arrow keys walk onto a plate the player cannot see.
    const g = landGrid(short, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 3, 0);
    expect(g.scroll).toBeGreaterThan(0);
    const last = g.origins[3];
    // Its bottom edge is inside the column.
    expect(last.y + g.ph).toBeLessThanOrEqual(short[1] + short[3] + 1);
  });

  it("drags the window back up when the chosen land is above it", () => {
    const g = landGrid(short, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, 9999);
    const first = g.origins[0];
    expect(first.y).toBeGreaterThanOrEqual(short[1] - 1);
  });
});

describe("landGrid — where the plates actually land", () => {
  it("lays four plates out left-to-right, top-to-bottom", () => {
    const g = landGrid(COL, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, 0);
    const [a, b, c, d] = g.origins;
    expect(a.y).toBe(b.y); // first row shares a baseline
    expect(c.y).toBe(d.y); // and so does the second
    expect(b.x).toBeGreaterThan(a.x); // second is to the right of the first
    expect(c.y).toBeGreaterThan(a.y); // third is below the first
    expect(c.x).toBe(a.x); // and under it, not offset
  });

  it("never overlaps two plates", () => {
    const g = landGrid(COL, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, 0);
    for (let i = 0; i < g.origins.length; i++) {
      for (let j = i + 1; j < g.origins.length; j++) {
        const p = g.origins[i];
        const q = g.origins[j];
        const apart =
          p.x + g.pw <= q.x || q.x + g.pw <= p.x || p.y + g.ph <= q.y || q.y + g.ph <= p.y;
        expect(apart).toBe(true);
      }
    }
  });

  it("gives one origin per land, for however many lands there are", () => {
    const g = landGrid(COL, LANDS.length, GAP, MIN_COL, VIABLE, COMFORTABLE, 0, 0);
    expect(g.origins).toHaveLength(LANDS.length);
  });

  it("survives a fifth land without anyone touching this function", () => {
    const g = landGrid(COL, 5, GAP, MIN_COL, VIABLE, COMFORTABLE, 4, 0);
    expect(g.origins).toHaveLength(5);
    expect(g.rows).toBe(3);
  });
});

describe("capLines — the sentence that printed over the title bar", () => {
  it("leaves a short sentence alone", () => {
    expect(capLines(["one", "two"], 2)).toEqual(["one", "two"]);
  });

  it("costs exactly the number of lines budgeted for, never one more", () => {
    // The height in `plateHeight` is budgeted from this cap. If the ellipsis
    // took a line of its own the plate would be one line short, which is how
    // the sentence ended up over the title bar.
    const capped = capLines(["one", "two", "three", "four"], 2);
    expect(capped).toHaveLength(2);
  });

  it("marks the cut on the last line it keeps", () => {
    expect(capLines(["one", "two", "three"], 2)).toEqual(["one", "two…"]);
  });

  it("does not leave a space before the ellipsis", () => {
    expect(capLines(["one", "two ", "three"], 2)).toEqual(["one", "two…"]);
  });

  it("handles a cap of one", () => {
    expect(capLines(["one", "two"], 1)).toEqual(["one…"]);
  });

  it("returns nothing for a cap of zero rather than throwing", () => {
    expect(capLines(["one"], 0)).toEqual([]);
  });

  // The ellipsis has to *fit*, which is the second half of this bug and the
  // half that actually reached the screen. `wrap` returns lines that already
  // fill the column to the pixel, so adding a character makes the last one
  // wider than the column — and the caller draws with `printf`, which wraps.
  // One character silently became a third line, printed across the record
  // underneath it. The capped result must satisfy the same `fits` the caller
  // will measure it with.
  describe("and the ellipsis fits the column it is drawn in", () => {
    /** Stands in for a font: at most `n` characters fit. */
    const upTo = (n: number) => (line: string) => line.length <= n;

    it("gives back a word until the marked line fits", () => {
      const capped = capLines(["aaaa bbbb", "cccc dddd", "eeee"], 2, upTo(9));
      expect(capped).toHaveLength(2);
      expect(capped[1]).toBe("cccc…");
      expect(capped[1].length).toBeLessThanOrEqual(9);
    });

    it("never returns a line the caller would have to wrap", () => {
      // The property, over every prefix length: whatever fits, fits.
      for (const limit of [4, 6, 8, 10, 14, 20]) {
        const capped = capLines(["one two three", "four five six seven", "tail"], 2, upTo(limit));
        expect(capped).toHaveLength(2);
        expect(upTo(limit)(capped[1]), `limit ${limit}: ${capped[1]}`).toBe(true);
      }
    });

    it("ends mid-word rather than looping on a word wider than the column", () => {
      // A single unbreakable token — a long identifier in a brief, say — has
      // no word boundary to give back, and the naive loop never terminates.
      const capped = capLines(["x", "supercalifragilistic", "tail"], 2, upTo(6));
      expect(capped).toHaveLength(2);
      expect(capped[1].length).toBeLessThanOrEqual(6);
      expect(capped[1].endsWith("…")).toBe(true);
    });

    it("still caps when no width is given, for callers that do not measure", () => {
      expect(capLines(["one", "two", "three"], 2)).toEqual(["one", "two…"]);
    });
  });
});

describe("the record's land rows — the C++ line that was silently dropped", () => {
  it("puts four lands on two lines, not four", () => {
    expect(landRowLines(4)).toBe(2);
  });

  it("still gives two lands one line each way up", () => {
    expect(landRowLines(2)).toBe(1);
    expect(landRowLines(1)).toBe(1);
  });

  it("pairs them left and right, then drops to the next line", () => {
    const at = (i: number) => landRowAt(i, 0, 0, 100, 8, 30);
    expect(at(0)).toEqual({ x: 0, y: 0 });
    expect(at(1)).toEqual({ x: 108, y: 0 });
    expect(at(2)).toEqual({ x: 0, y: 30 });
    expect(at(3)).toEqual({ x: 108, y: 30 });
  });

  it("keeps every land inside the panel width", () => {
    const w = 400;
    const gap = 8;
    const cell = Math.floor((w - gap) / 2);
    for (let i = 0; i < LANDS.length; i++) {
      const { x } = landRowAt(i, 0, 0, cell, gap, 30);
      expect(x + cell).toBeLessThanOrEqual(w);
    }
  });
});
