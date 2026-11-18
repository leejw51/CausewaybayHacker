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
