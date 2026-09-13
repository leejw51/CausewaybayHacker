import { expect, freshAccount, login, openSelectedNode, pickCategory, pickLand, test } from "./fixtures.js";
const OUT = process.env.SPARK_SHOTS ?? "test-results/spark";
test("a burst is painted where the mistake is", async ({ page }) => {
  await login(page, freshAccount());
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await openSelectedNode(page);
  const code = await page.evaluate(() => window.__cwbCapture!.buttonAt("focus"));
  await page.mouse.click(code![0], code![1]);
  await page.waitForTimeout(600);
  const ans = await page.evaluate(() => window.__cwbCapture!.buttonAt("answer"));
  await page.mouse.click(ans![0], ans![1]);
  await expect
    .poll(async () => page.evaluate(() => document.querySelectorAll(".cwb-ghost").length))
    .toBeGreaterThan(0);
  // Type a character that is not the answer, then look immediately — no
  // settle, because settling ages the particles past their life.
  await page.keyboard.press("Control+Home");
  await page.keyboard.type("q");
  await page.waitForTimeout(260);
  await page.screenshot({ path: `${OUT}/wrong.png` });
  const painted = await page.evaluate(() => {
    const c = document.querySelector(".cwb-sparks") as HTMLCanvasElement;
    const g = c.getContext("2d")!;
    const d = g.getImageData(0, 0, c.width, c.height).data;
    let lit = 0;
    for (let i = 3; i < d.length; i += 4) if (d[i] > 8) lit++;
    return { lit, w: c.width, h: c.height };
  });
  console.log(`[spark] ${JSON.stringify(painted)}`);
  expect(painted.lit).toBeGreaterThan(0);
});
