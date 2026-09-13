import { mkdirSync } from "node:fs";
import { expect, freshAccount, login, openSelectedNode, pickCategory, pickLand, test } from "./fixtures.js";

const SHOTS = process.env.PHONE_SHOTS ?? "test-results/phone";
mkdirSync(SHOTS, { recursive: true });
const BACKEND = process.env.E2E_BACKEND_URL ?? "http://127.0.0.1:5390";

// A real phone: iPhone-sized CSS viewport, DPR 3, touch. This is the shape
// the "code page is too small" report came from.
test.use({ viewport: { width: 402, height: 780 }, deviceScaleFactor: 3, hasTouch: true, isMobile: true });

test("phone: the quest screen", async ({ page }) => {
  const account = freshAccount();
  await login(page, account);
  await page.screenshot({ path: `${SHOTS}/01-lands.png` });
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await page.waitForTimeout(800);
  await page.screenshot({ path: `${SHOTS}/02-map.png` });
  await openSelectedNode(page);
  await page.waitForTimeout(1200);
  await page.screenshot({ path: `${SHOTS}/03-quest.png` });
  const info = await page.evaluate(() => {
    const cm = document.querySelector(".cm-editor") as HTMLElement | null;
    const r = cm?.getBoundingClientRect();
    const fs = cm ? getComputedStyle(cm.querySelector(".cm-content") as Element).fontSize : null;
    return { rect: r ? [r.x, r.y, r.width, r.height] : null, fontSize: fs, vw: innerWidth, vh: innerHeight };
  });
  console.log(`[phone] editor ${JSON.stringify(info)}`);
});
