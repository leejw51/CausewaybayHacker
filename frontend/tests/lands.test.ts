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
import { capLines, landGrid, roadColumn } from "../src/scenes/lands";
import { landRowAt, landRowLines } from "../src/scenes/stats";
import { LANDS } from "../src/net/protocol";

/** A roomy landscape column: 980 wide, 520 tall, which is the real case. */
const COL: [number, number, number, number] = [20, 100, 980, 520];
const GAP = 10;
const MIN_COL = 260;

/** The heights the real screen measures at that width, near enough. */
const VIABLE = 240;
const COMFORTABLE = 265;
/**
 * The same plate with no mascot at all — `plateHeight(s, pw, 0)`, which is
 * `COMFORTABLE` less the 76 design pixels the mascot asks for. This is the
 * last height a plate gives up before a land would go off the column.
 */
const FLOOR = 189;

describe("landGrid — how many columns", () => {
  it("stacks two lands in one column, which is what two lands always did", () => {
    const g = landGrid(COL, 2, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
    expect(g.cols).toBe(1);
    expect(g.rows).toBe(2);
    expect(g.pw).toBe(980);
  });

  it("puts four lands two across, so every land is on screen at once", () => {
    const g = landGrid(COL, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
    expect(g.cols).toBe(2);
    expect(g.rows).toBe(2);
    // Two plates and one gap fill the column exactly.
    expect(g.pw * 2 + GAP).toBeLessThanOrEqual(980);
    expect(g.overflow).toBe(0);
  });

  it("falls back to one column when half the width is too narrow to read", () => {
    // A phone: half of 420 is under the 260 a plate needs for its sentence.
    const g = landGrid([0, 0, 420, 900], 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
    expect(g.cols).toBe(1);
    expect(g.rows).toBe(4);
  });
});

describe("landGrid — the plate is never shorter than its contents", () => {
  it("takes the fair share when the fair share is tall enough", () => {
    const g = landGrid(COL, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
    // (520 - 10) / 2 = 255, which clears the 240 a viable mascot needs.
    expect(g.ph).toBe(255);
    expect(g.ph).toBeGreaterThanOrEqual(VIABLE);
  });

  it("takes the floor instead of squashing, which is what makes it scroll", () => {
    // A short column: the fair share is well under what a plate needs.
    const short: [number, number, number, number] = [20, 100, 980, 300];
    const g = landGrid(short, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
    expect(g.ph).toBe(COMFORTABLE);
    expect(g.overflow).toBeGreaterThan(0);
  });

  it("never returns a plate too short to read — the original bug", () => {
    // Whatever the column, the plate holds at least its title, its sentence
    // and its record: `FLOOR`. This is the invariant the four-land screen
    // broke outright — 520/4 = 130, a plate with no room to draw in — and it
    // is stated at `FLOOR` rather than at `VIABLE` because the mascot is now
    // allowed to shrink away before a land is pushed off the column.
    for (const h of [200, 300, 420, 520, 700, 1000]) {
      const g = landGrid([0, 0, 980, h], 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
      expect(g.ph).toBeGreaterThanOrEqual(FLOOR);
    }
  });

  it("shrinks the mascot before it hides a land", () => {
    // 420 tall, four lands, two rows: the fair share is 205 — under the 240 a
    // viable mascot wants, over the 189 the rest of the plate needs. The old
    // rule jumped to COMFORTABLE here and pushed the second row half off the
    // column for the sake of 60 pixels of mascot.
    const g = landGrid([0, 0, 980, 420], 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
    expect(g.ph).toBe(205);
    expect(g.overflow).toBe(0);
  });
});

describe("landGrid — scrolling, and keeping the chosen land in view", () => {
  const short: [number, number, number, number] = [20, 100, 980, 300];

  it("reports no overflow when everything fits", () => {
    const g = landGrid(COL, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
    expect(g.overflow).toBe(0);
    expect(g.scroll).toBe(0);
  });

  it("clamps a scroll past the end back to the end", () => {
    // With the selection already on the bottom row, nothing pulls the window
    // back up, so this is the clamp on its own.
    const g = landGrid(short, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 3, 99999);
    expect(g.scroll).toBe(g.overflow);
  });

  it("clamps a negative scroll back to the top", () => {
    const g = landGrid(short, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, -500);
    expect(g.scroll).toBe(0);
  });

  it("lets the selection overrule a scroll that would hide it", () => {
    // Scrolled to the bottom, then the player picks the first land with the
    // arrow keys: the window has to come back, or the highlight is off-screen.
    const g = landGrid(short, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 99999);
    expect(g.scroll).toBe(0);
  });

  it("drags the window down when the chosen land is below the fold", () => {
    // Selecting the last land from a scroll of 0 must move the window, or the
    // arrow keys walk onto a plate the player cannot see.
    const g = landGrid(short, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 3, 0);
    expect(g.scroll).toBeGreaterThan(0);
    const last = g.origins[3];
    // Its bottom edge is inside the column.
    expect(last.y + g.ph).toBeLessThanOrEqual(short[1] + short[3] + 1);
  });

  it("drags the window back up when the chosen land is above it", () => {
    const g = landGrid(short, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 9999);
    const first = g.origins[0];
    expect(first.y).toBeGreaterThanOrEqual(short[1] - 1);
  });
});

describe("landGrid — where the plates actually land", () => {
  it("lays four plates out left-to-right, top-to-bottom", () => {
    const g = landGrid(COL, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
    const [a, b, c, d] = g.origins;
    expect(a.y).toBe(b.y); // first row shares a baseline
    expect(c.y).toBe(d.y); // and so does the second
    expect(b.x).toBeGreaterThan(a.x); // second is to the right of the first
    expect(c.y).toBeGreaterThan(a.y); // third is below the first
    expect(c.x).toBe(a.x); // and under it, not offset
  });

  it("never overlaps two plates", () => {
    const g = landGrid(COL, 4, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
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
    const g = landGrid(COL, LANDS.length, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
    expect(g.origins).toHaveLength(LANDS.length);
  });

  it("puts a fifth land three across, not three rows down", () => {
    // PYTORCH, reported as "not visible" from a real browser. Five lands in a
    // two-wide grid is three rows; the third was below the bottom of a column
    // whose scrollbar nobody finds, so the fifth land existed, had a hit box,
    // and was invisible. 980 wide holds three plates of 320 at MIN_COL, so
    // five lands cost the same two rows four lands cost.
    const g = landGrid(COL, 5, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 4, 0);
    expect(g.origins).toHaveLength(5);
    expect(g.cols).toBe(3);
    expect(g.rows).toBe(2);
    expect(g.overflow).toBe(0);
    // Every plate, the fifth included, is inside the column.
    for (const o of g.origins) {
      expect(o.y).toBeGreaterThanOrEqual(COL[1]);
      expect(o.y + g.ph).toBeLessThanOrEqual(COL[1] + COL[3]);
    }
  });

  it("keeps the fifth land on screen where only two columns fit", () => {
    // The reported window: a portrait browser, a column too narrow for three
    // plates. Two columns and three rows then have to fit by height, which is
    // what the mascot gives way for.
    const narrow: [number, number, number, number] = [0, 0, 620, 640];
    const g = landGrid(narrow, 5, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
    expect(g.cols).toBe(2);
    expect(g.rows).toBe(3);
    expect(g.overflow).toBe(0);
    for (const o of g.origins) {
      expect(o.y + g.ph).toBeLessThanOrEqual(narrow[1] + narrow[3]);
    }
  });

  it("still scrolls when not even a mascot-less plate fits", () => {
    // The rule gives up the mascot, not the plate. Five lands in 300px is
    // 93 a row, under FLOOR, so it goes back to a readable plate and scrolls.
    const g = landGrid([0, 0, 620, 300], 5, GAP, MIN_COL, VIABLE, COMFORTABLE, FLOOR, 0, 0);
    expect(g.ph).toBe(COMFORTABLE);
    expect(g.overflow).toBeGreaterThan(0);
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

/**
 * The right-hand column: the CODE PLAYGROUND tile leads it.
 *
 * The tile used to be the last thing in the column, under the three roads and
 * under a row of buttons, at a fifth of the height — the slot for the thing a
 * screen expects nobody to want. `roadColumn` is the order and the fit, with
 * every height handed in already measured, so this is checkable without a
 * canvas.
 */
describe("roadColumn", () => {
  type R = readonly [number, number, number, number];
  const overlaps = (a: R, b: R) => a[1] < b[1] + b[3] && b[1] < a[1] + a[3];
  const within = (r: R, p: R) =>
    r[0] >= p[0] && r[1] >= p[1] && r[0] + r[2] <= p[0] + p[2] && r[1] + r[3] <= p[1] + p[3];

  /** A landscape panel at the design scale, and a portrait one. */
  const LAND: [number, number, number, number] = [660, 100, 600, 560];
  const PORT: [number, number, number, number] = [20, 420, 560, 520];
  const GAP = 8;
  const REC = 34;
  const FLOOR = 38;
  const MIN_ROW = 76;
  const PLAY = 48;
  const TILE = 168;

  it("puts the playground tile at the very top of the column", () => {
    for (const panel of [LAND, PORT]) {
      const col = roadColumn(panel, 3, GAP, REC, FLOOR, MIN_ROW, PLAY, TILE);
      expect(col.tile[1]).toBe(panel[1]);
      expect(col.tile[0]).toBe(panel[0]);
      expect(col.tile[2]).toBe(panel[2]);
      for (const r of [col.record, ...col.rows, col.buttons]) {
        expect(r[1]).toBeGreaterThan(col.tile[1] + col.tile[3]);
      }
    }
  });

  it("makes the tile the tallest single thing in the column when there is room", () => {
    for (const panel of [LAND, PORT]) {
      const col = roadColumn(panel, 3, GAP, REC, FLOOR, MIN_ROW, PLAY, TILE);
      expect(col.tight).toBe(false);
      expect(col.tile[3]).toBe(TILE);
      for (const r of [col.record, ...col.rows, col.buttons]) {
        expect(col.tile[3]).toBeGreaterThanOrEqual(r[3]);
      }
    }
  });

  it("keeps the roads in order under the record, and the buttons at the foot", () => {
    const col = roadColumn(LAND, 3, GAP, REC, FLOOR, MIN_ROW, PLAY, TILE);
    expect(col.rows).toHaveLength(3);
    expect(col.record[1]).toBeGreaterThan(col.tile[1]);
    expect(col.rows[0][1]).toBeGreaterThan(col.record[1] + col.record[3]);
    for (let i = 1; i < col.rows.length; i++) {
      expect(col.rows[i][1]).toBeGreaterThan(col.rows[i - 1][1] + col.rows[i - 1][3]);
      expect(col.rows[i][3]).toBe(col.rows[0][3]);
    }
    expect(col.buttons[1] + col.buttons[3]).toBe(LAND[1] + LAND[3]);
    expect(col.buttons[1]).toBeGreaterThan(col.rows[2][1] + col.rows[2][3]);
  });

  it("never overlaps anything and stays inside the panel", () => {
    for (const panel of [LAND, PORT, [0, 0, 400, 300] as [number, number, number, number]]) {
      const col = roadColumn(panel, 3, GAP, REC, FLOOR, MIN_ROW, PLAY, TILE);
      const all = [col.tile, col.record, ...col.rows, col.buttons];
      for (const r of all) expect(within(r, panel), `${r} in ${panel}`).toBe(true);
      for (let i = 0; i < all.length; i++) {
        for (let j = i + 1; j < all.length; j++) {
          expect(overlaps(all[i], all[j]), `${all[i]} vs ${all[j]}`).toBe(false);
        }
      }
    }
  });

  it("gives the roads a finger's height before the tile takes more", () => {
    const col = roadColumn(LAND, 3, GAP, REC, FLOOR, MIN_ROW, PLAY, TILE);
    expect(col.rows[0][3]).toBe(MIN_ROW);
  });

  it("shrinks the tile to a button's height when the roads would not fit — and keeps it on top", () => {
    // A phone held sideways: 300px for the whole column.
    const short: [number, number, number, number] = [0, 0, 400, 300];
    const col = roadColumn(short, 3, GAP, REC, FLOOR, MIN_ROW, PLAY, TILE);
    expect(col.tight).toBe(true);
    expect(col.tile[3]).toBe(PLAY);
    expect(col.tile[1]).toBe(0);
    for (const r of col.rows) expect(r[3]).toBeGreaterThanOrEqual(FLOOR);
    expect(col.buttons[1] + col.buttons[3]).toBe(300);
  });

  it("never lets a tile ask for less than the button row", () => {
    const col = roadColumn(LAND, 3, GAP, REC, FLOOR, MIN_ROW, PLAY, 10);
    expect(col.tile[3]).toBe(PLAY);
  });
});
