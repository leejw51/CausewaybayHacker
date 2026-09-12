import { atScreen, expect, freshAccount, login, pickLand, test, type Land } from "./fixtures.js";
import type { Page } from "@playwright/test";

/**
 * What the composed frame actually looks like, sampled rather than snapshotted.
 *
 * ## Why there are no baseline images here
 *
 * The obvious thing — `toHaveScreenshot` on each screen — was built, run, and
 * thrown away, and it is worth saying why so the next person does not spend
 * the afternoon again.
 *
 * The city behind every screen is a continuously animated layer driven by time
 * accumulated since the page loaded, and the number of real frames before a
 * capture varies with network timing. Two captures of the *identical* screen,
 * taken on two loads of the same account, were measured differing in **16% of
 * their pixels**; disabling WebGL so the flat fallback draws instead made it
 * **20%**, because that path animates too. `__cwbCapture.settle()` is
 * deterministic in the sense it advertises — a fixed count of fixed-size steps
 * — but it advances the clock rather than pinning it, so two loads settle from
 * different starting phases.
 *
 * A tolerance wide enough to absorb a fifth of the frame would absorb anything
 * worth catching, and a baseline that flaps is worse than none: it teaches
 * people to run `--update-snapshots` without looking, which launders a
 * regression into the expected result.
 *
 * ## What is checked instead
 *
 * The pixels that *are* stable: opaque interface chrome, sampled at points
 * derived from the game's own hit rectangles rather than from guessed
 * coordinates. A land's plate is drawn with that land's accent colour, and a
 * land wearing its neighbour's colour is a real bug that no arithmetic test
 * can see. Sampling one pixel of the title bar catches it and does not care
 * what phase the mascot's idle bob is on.
 *
 * The art itself — four distinct mascots, alpha channels intact, the manifest
 * agreeing with the directory — is checked in `frontend/tests/art.test.ts`,
 * which needs no browser and runs in the ordinary suite.
 */

/** One pixel of the game canvas, in virtual coordinates. */
async function pixelAt(page: Page, vx: number, vy: number): Promise<[number, number, number]> {
  return page.evaluate(
    ([x, y]) => {
      const canvas = document.getElementById("game") as HTMLCanvasElement;
      const virtual = window.__cwbCapture?.virtual();
      if (!virtual) throw new Error("no capture hook");
      // The canvas is sized in device pixels and the game thinks in virtual
      // ones; the ratio is the only thing needed to cross between them.
      const scale = canvas.width / virtual[0];
      const g = canvas.getContext("2d");
      if (!g) throw new Error("no 2d context");
      const d = g.getImageData(Math.round(x * scale), Math.round(y * scale), 1, 1).data;
      return [d[0], d[1], d[2]] as [number, number, number];
    },
    [vx, vy],
  );
}

/**
 * The colour of the chosen land's plate title bar.
 *
 * The bar's position comes from the land button's own hit rectangle, which is
 * the rectangle the game itself tests clicks against, so this cannot drift
 * from where the plate really is. `titledPanel` insets the bar 8px from the
 * top of the panel and it is about twenty tall, so fourteen down is inside it
 * at every type step.
 */
async function plateBarColour(page: Page, land: Land): Promise<[number, number, number]> {
  const rect = await page.evaluate((id) => {
    const b = window.__cwbCapture?.buttons().find((x) => x.id === id);
    return b ? b.rect : null;
  }, `land:${land}`);
  if (!rect) throw new Error(`no land button for ${land} on screen`);
  const [x, y, w] = rect;
  return pixelAt(page, x + w / 2, y + 14);
}

/** How far apart two colours are, as plain Euclidean distance in RGB. */
function apart(a: [number, number, number], b: [number, number, number]): number {
  return Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
}

test.describe("the lands are drawn in their own colours", () => {
  test("each land's plate wears a different accent", async ({ page, ready }) => {
    void ready;
    await page.goto("/");
    await login(page, freshAccount());
    await atScreen(page, "lands");

    const seen: Record<string, [number, number, number]> = {};
    for (const land of ["rust", "go", "cpp", "python"] as Land[]) {
      await pickLand(page, land);
      // Settle so the plate's open/close tween has finished and the bar is at
      // full strength rather than mid-fade.
      await page.evaluate(() => window.__cwbCapture?.settle(1.5));
      seen[land] = await plateBarColour(page, land);
      await page.evaluate(() => window.__cwbCapture?.resume());
    }

    // Every pair is visibly different. The failure this catches is a land
    // drawn with a neighbour's tint, which looks completely fine in isolation
    // and is why `TRACK_COL` gaining a key without the scene reading it would
    // otherwise go unnoticed.
    const lands = Object.keys(seen);
    for (let i = 0; i < lands.length; i++) {
      for (let j = i + 1; j < lands.length; j++) {
        const d = apart(seen[lands[i]], seen[lands[j]]);
        expect(d, `${lands[i]} vs ${lands[j]} are the same colour`).toBeGreaterThan(24);
      }
    }
  });

  test("C++ is blue and Python is gold, not merely different", async ({ page, ready }) => {
    void ready;
    await page.goto("/");
    await login(page, freshAccount());
    await atScreen(page, "lands");

    await pickLand(page, "cpp");
    await page.evaluate(() => window.__cwbCapture?.settle(1.5));
    const cpp = await plateBarColour(page, "cpp");
    await page.evaluate(() => window.__cwbCapture?.resume());

    await pickLand(page, "python");
    await page.evaluate(() => window.__cwbCapture?.settle(1.5));
    const python = await plateBarColour(page, "python");
    await page.evaluate(() => window.__cwbCapture?.resume());

    // ISO C++ blue is #00599C: blue dominates and red is nearly absent.
    expect(cpp[2], `cpp bar ${cpp} is not blue`).toBeGreaterThan(cpp[0]);
    // Python gold is #FFD43B: red and green dominate, blue trails.
    expect(python[0], `python bar ${python} is not gold`).toBeGreaterThan(python[2]);
    expect(python[1], `python bar ${python} is not gold`).toBeGreaterThan(python[2]);
  });
});

test.describe("the capture hook tells the truth about the screen", () => {
  test("both canvases are the same size, so nothing is drawn at half scale", async ({
    page,
    ready,
  }) => {
    void ready;
    await page.goto("/");
    await login(page, freshAccount());
    await atScreen(page, "lands");
    const backing = await page.evaluate(() => window.__cwbCapture?.backing());
    expect(backing).toBeTruthy();
    // The city is drawn on `#fx` and the game on `#game`. They are stacked, so
    // a mismatch puts the backdrop in the wrong place at the wrong resolution
    // — which has happened, and is invisible until somebody looks closely.
    expect(backing!.fx).toEqual(backing!.game);
  });

  test("every land plate is on screen and none is off the bottom", async ({ page, ready }) => {
    void ready;
    await page.goto("/");
    await login(page, freshAccount());
    await atScreen(page, "lands");
    await page.evaluate(() => window.__cwbCapture?.settle(2.5));

    const virtual = await page.evaluate(() => window.__cwbCapture?.virtual());
    const rects = await page.evaluate(() =>
      (window.__cwbCapture?.buttons() ?? [])
        .filter((b) => b.id.startsWith("land:"))
        .map((b) => ({ id: b.id, rect: b.rect })),
    );

    expect(rects).toHaveLength(4);
    for (const { id, rect } of rects) {
      const [x, y, w, h] = rect;
      // A plate whose hit box starts below the screen is a land the player
      // cannot reach — the state this screen was in when four lands first
      // arrived and two of them fell off the bottom of the column.
      expect(y, `${id} starts below the screen`).toBeLessThan(virtual![1]);
      expect(y + h, `${id} ends above the screen`).toBeGreaterThan(0);
      expect(x + w, `${id} is off the left edge`).toBeGreaterThan(0);
      expect(x, `${id} is off the right edge`).toBeLessThan(virtual![0]);
    }
  });
});
