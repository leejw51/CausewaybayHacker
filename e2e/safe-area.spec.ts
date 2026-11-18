/**
 * The home-screen app's safe area. Opened from the home screen, iOS settles
 * the safe-area insets after launch: the three layers move and shrink by CSS
 * alone and no window `resize` fires. The canvas has to follow its own size,
 * or the game is squashed by CSS and the editor, the fields and every tap
 * land against a canvas that is not where it is drawn.
 *
 * A browser cannot be given iOS's insets, so they are put on by a style, the
 * same way the page's own CSS would move the layers. No login needed: the
 * canvas is sized from the first screen.
 */
import { expect, test } from "@playwright/test";

test("the game re-fits a grown window even when no event says so", async ({
  page,
}) => {
  // Every size event suppressed: no `resize`, no `orientationchange`, no
  // ResizeObserver. On an iPad, Safari opened from another app was measured
  // at a fraction of the screen and none of them arrived afterwards; the
  // game stayed boxed in the middle at both stretch caps.
  await page.addInitScript(() => {
    const add = window.addEventListener.bind(window);
    window.addEventListener = ((type: string, ...rest: unknown[]) => {
      if (type === "resize" || type === "orientationchange") return;
      return (add as (...a: unknown[]) => void)(type, ...rest);
    }) as typeof window.addEventListener;
    // @ts-expect-error: the observer the app would use is taken away.
    delete window.ResizeObserver;
  });
  await page.setViewportSize({ width: 260, height: 465 });
  await page.goto("/");
  await page.waitForFunction(
    () => (document.getElementById("game") as HTMLCanvasElement)?.width > 100,
  );
  await page.waitForTimeout(500);
  await page.setViewportSize({ width: 750, height: 930 });
  const sizes = () =>
    page.evaluate(() => {
      const c = document.getElementById("game") as HTMLCanvasElement;
      const r = c.getBoundingClientRect();
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      return {
        backing: [c.width, c.height],
        shown: [Math.round(r.width * dpr), Math.round(r.height * dpr)],
      };
    });
  await expect
    .poll(
      async () => {
        const s = await sizes();
        return s.backing[0] === s.shown[0] && s.backing[1] === s.shown[1];
      },
      {
        timeout: 5_000,
        message: "the backing store followed the grown window",
      },
    )
    .toBe(true);
});

test("the canvas follows its own size when the safe area changes", async ({
  page,
}) => {
  await page.goto("/");
  await page.waitForFunction(
    () => (document.getElementById("game") as HTMLCanvasElement)?.width > 300,
  );
  const sizes = () =>
    page.evaluate(() => {
      const c = document.getElementById("game") as HTMLCanvasElement;
      const r = c.getBoundingClientRect();
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      return {
        backing: [c.width, c.height],
        shown: [Math.round(r.width * dpr), Math.round(r.height * dpr)],
      };
    });
  const before = await sizes();
  expect(before.backing).toEqual(before.shown);

  await page.addStyleTag({
    content:
      "#fx,#game,#overlay{top:24px!important;bottom:20px!important;height:calc(100% - 44px)!important}",
  });
  await expect
    .poll(
      async () => {
        const s = await sizes();
        return s.backing[1] === s.shown[1] && s.shown[1] < before.shown[1];
      },
      {
        timeout: 5_000,
        message: "the backing store followed the inset canvas",
      },
    )
    .toBe(true);
});
