import { test, fixtureAccount, atScreen, scene } from "./fixtures.js";
test("login screen controls", async ({ page }) => {
  await atScreen(page, "login");
  console.log("BTNS", JSON.stringify(await page.evaluate(() => window.__cwbCapture!.buttons().map(b => b.id))));
  const a = fixtureAccount(0);
  await page.locator("textarea.cwb-field").fill(a.privateKey);
  await page.locator("textarea.cwb-field").press("ControlOrMeta+Enter");
  await page.waitForTimeout(4000);
  console.log("AFTER_KEY", await scene(page));
});
