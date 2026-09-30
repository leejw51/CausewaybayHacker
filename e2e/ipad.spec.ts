import { mkdirSync } from "node:fs";
import {
  expect,
  freshAccount,
  login,
  pickCategory,
  pickLand,
  test,
} from "./fixtures.js";

const SHOTS = process.env.IPAD_SHOTS ?? "test-results/ipad";
mkdirSync(SHOTS, { recursive: true });

// A desktop keeps its full bar, and gains FIND on it.
test.describe("desktop", () => {
  test("the map keeps its bar and gains FIND", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await login(page, freshAccount());
    await pickLand(page, "remix");
    await pickCategory(page, "basic");
    await page.waitForTimeout(1200);
    await page.screenshot({ path: `${SHOTS}/desktop-map.png` });
    const ids = await page.evaluate(() =>
      window.__cwbCapture!.buttons().map((b) => b.id),
    );
    expect(ids).toContain("land:rust");
    expect(ids).toContain("find");
  });
});

// An iPad: touch, DPR 2, and not a phone. REMIX × BASIC is the road with the
// most streets on it (57), which is where tapping a coin was hardest.
test.describe("iPad", () => {
  test.use({ deviceScaleFactor: 2, hasTouch: true, isMobile: true });

  for (const [name, size] of [
    ["landscape", { width: 1180, height: 820 }],
    ["portrait", { width: 820, height: 1180 }],
    ["pro-landscape", { width: 1366, height: 1024 }],
  ] as const) {
    test(`iPad ${name}: the map`, async ({ page }) => {
      await page.setViewportSize(size);
      await login(page, freshAccount());
      await pickLand(page, "remix");
      await pickCategory(page, "basic");
      await page.waitForTimeout(1200);
      await page.screenshot({ path: `${SHOTS}/${name}-map.png` });
      // One row of chips on a touch screen, whatever its size: MENU, the roads,
      // FIND. The land chips and the ways out are behind MENU.
      const ids = await page.evaluate(() =>
        window.__cwbCapture!.buttons().map((b) => b.id),
      );
      expect(ids).toContain("menu");
      expect(ids).toContain("find");
      expect(ids).not.toContain("land:rust");

      // FIND: a number keeps the streets whose number starts with it.
      const field = page.locator("textarea.cwb-field");
      await expect(field).toBeVisible();
      await field.tap();
      await field.fill("3");
      await page.waitForTimeout(400);
      await page.screenshot({ path: `${SHOTS}/${name}-find-3.png` });
      await field.fill("string");
      await page.waitForTimeout(400);
      await page.screenshot({ path: `${SHOTS}/${name}-find-word.png` });
      // Font at least 16px, or iOS zooms the page into the field.
      const px = await field.evaluate((el) =>
        parseFloat(getComputedStyle(el).fontSize),
      );
      expect(px).toBeGreaterThanOrEqual(16);
    });
  }
});
