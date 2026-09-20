import { mkdirSync } from "node:fs";
import { expect, freshAccount, login, openSelectedNode, pickCategory, pickLand, sceneNow, test } from "./fixtures.js";

const SHOTS = process.env.PHONE_SHOTS ?? "test-results/phone";
mkdirSync(SHOTS, { recursive: true });
const BACKEND = process.env.E2E_BACKEND_URL ?? "http://127.0.0.1:5390";

// A real phone: iPhone-sized CSS viewport, DPR 3, touch. This is the shape
// the "code page is too small" report came from.
test.use({ viewport: { width: 402, height: 780 }, deviceScaleFactor: 3, hasTouch: true, isMobile: true });

test("phone, held sideways: the quest screen", async ({ page }) => {
  // A phone in landscape is still a phone: the same register, a different
  // shape. Both orientations are first class (SPEC §10), and "looks right on
  // a desktop" is not an answer for either of them.
  await page.setViewportSize({ width: 874, height: 402 });
  const account = freshAccount();
  await login(page, account);
  await page.screenshot({ path: `${SHOTS}/L1-lands.png` });
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await page.waitForTimeout(800);
  await page.screenshot({ path: `${SHOTS}/L2-map.png` });
  await openSelectedNode(page);
  await page.waitForTimeout(1200);
  await page.screenshot({ path: `${SHOTS}/L3-quest.png` });
  const box = await page.evaluate(() => {
    const r = (document.querySelector(".cm-editor") as HTMLElement).getBoundingClientRect();
    return [r.x, r.y, r.width, r.height];
  });
  console.log(`[phone-landscape] editor ${JSON.stringify(box)}`);
  expect(box[3]).toBeGreaterThan(120);
  const at = await page.evaluate(() => window.__cwbCapture!.buttonAt("focus"));
  await page.mouse.click(at![0], at![1]);
  await page.waitForTimeout(700);
  await page.screenshot({ path: `${SHOTS}/L4-code-mode.png` });
});

test("phone: the quest screen", async ({ page }) => {
  const account = freshAccount();
  await login(page, account);
  await page.screenshot({ path: `${SHOTS}/01-lands.png` });
  // Every category row is inside its panel and clear of the two buttons
  // under it — the road that used to be behind AUTO SELECT.
  const rows = await page.evaluate(() => {
    const api = window.__cwbCapture!;
    const cat = ["verybasic", "basic", "advanced", "hacker"].map((c) => api.buttonAt(`cat:${c}`));
    return { cat, auto: api.buttonAt("auto"), play: api.buttonAt("playground") };
  });
  for (const c of rows.cat) expect(c).not.toBeNull();
  for (const c of rows.cat) expect(c![1]).toBeLessThan(rows.auto![1]);
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

  // CODE mode: the editor takes the screen, BACK gives the furniture back.
  const at = await page.evaluate(() => window.__cwbCapture!.buttonAt("focus"));
  expect(at).not.toBeNull();
  await page.mouse.click(at![0], at![1]);
  await page.waitForTimeout(800);
  await page.screenshot({ path: `${SHOTS}/04-code-mode.png` });
  const focus = await page.evaluate(() => {
    const r = (document.querySelector(".cm-editor") as HTMLElement).getBoundingClientRect();
    return { rect: [r.x, r.y, r.width, r.height], back: window.__cwbCapture!.buttonAt("unfocus") };
  });
  console.log(`[phone] code mode ${JSON.stringify(focus)}`);
  expect(focus.rect[3]).toBeGreaterThan(500);
  // DONE returns to the quest screen — and is still *signed in*. The header
  // is not drawn in CODE mode, and its LOG OUT hit box used to outlive it in
  // exactly this corner, so the button that ends a writing session logged
  // the player out and landed them on the login screen.
  await page.mouse.click(focus.back![0], focus.back![1]);
  await page.waitForTimeout(900);
  expect(await sceneNow(page)).toBe("quest");
  expect(await page.evaluate(() => window.__cwbCapture!.buttonAt("focus"))).not.toBeNull();
  await page.screenshot({ path: `${SHOTS}/05-back-from-code.png` });
  await page.keyboard.press("Escape");
  await page.waitForTimeout(1500);
  await page.screenshot({ path: `${SHOTS}/06-map.png` });
});
