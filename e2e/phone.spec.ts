/**
 * The game on a phone, both ways up. A quest is four choices and no editor
 * (SPEC §0), so what a phone has to show on the quest screen is the choices,
 * each one wide enough to press; the editor a phone has to fit is the
 * playground's, in CODE mode, where it takes the screen.
 */
import { mkdirSync } from "node:fs";
import type { Page } from "@playwright/test";
import {
  atScreen,
  choicesShown,
  clickButton,
  expect,
  freshAccount,
  login,
  openSelectedNode,
  pickCategory,
  pickLand,
  sceneNow,
  test,
} from "./fixtures.js";

const SHOTS = process.env.PHONE_SHOTS ?? "test-results/phone";
mkdirSync(SHOTS, { recursive: true });
// The server the wire checks ask. The same one the page is served from when
// `E2E_BASE_URL` points at a backend (the release build on its own port):
// without that fallback a run against an isolated server asked the default
// :5390 — a different database — and read no history for a real submit.
const BACKEND =
  process.env.E2E_BACKEND_URL ??
  process.env.E2E_BASE_URL ??
  "http://127.0.0.1:5390";

/** Where the four choices are drawn, in CSS pixels. */
const choiceRects = (page: Page) =>
  page.evaluate(() =>
    window.__cwbCapture!
      .buttons()
      .filter((b) => b.id.startsWith("choice:"))
      .map((b) => b.client),
  );

/** Inside the screen's width, and wide enough to read and press. */
function fitsAcross(page: Page, c: number[]): void {
  const vw = page.viewportSize()!.width;
  expect(c[0]).toBeGreaterThanOrEqual(0);
  expect(c[0] + c[2]).toBeLessThanOrEqual(vw + 1);
  expect(c[2]).toBeGreaterThan(vw * 0.3);
}

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
  await choicesShown(page);
  await expect(page.locator(".cm-content")).toBeHidden();
  const choices = await choiceRects(page);
  console.log(`[phone-landscape] choices ${JSON.stringify(choices)}`);
  for (const c of choices) fitsAcross(page, c);
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
  // The pick: four choices, each inside the screen's width, and no editor.
  await choicesShown(page);
  await expect(page.locator(".cm-content")).toBeHidden();
  const choices = await choiceRects(page);
  console.log(`[phone] choices ${JSON.stringify(choices)}`);
  for (const c of choices) fitsAcross(page, c);
  await page.keyboard.press("Escape");
  await atScreen(page, "map");
  await page.screenshot({ path: `${SHOTS}/04-map.png` });

  // CODE mode, on the playground: the editor takes the screen, DONE gives
  // the furniture back.
  await page.keyboard.press("Escape");
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await expect.poll(() => sceneNow(page), { timeout: 30_000 }).toBe("playground");
  await expect(page.locator(".cm-content")).toBeVisible();
  const framed = (await page.locator(".cm-editor").boundingBox())!;
  await clickButton(page, "code");
  await page.waitForTimeout(800);
  await page.screenshot({ path: `${SHOTS}/05-code-mode.png` });
  const focus = await page.evaluate(() => {
    const r = (document.querySelector(".cm-editor") as HTMLElement).getBoundingClientRect();
    return { rect: [r.x, r.y, r.width, r.height], back: window.__cwbCapture!.buttonAt("unfocus") };
  });
  console.log(`[phone] code mode ${JSON.stringify(focus)}`);
  // Taller than on the split page, and at least half the phone: the code
  // page's own toolbar (RUN, FORMAT, UNDO…) is several rows on a phone.
  expect(focus.rect[3]).toBeGreaterThan(framed.height);
  expect(focus.rect[3]).toBeGreaterThan(page.viewportSize()!.height * 0.5);
  // DONE returns to the playground — and is still *signed in*. The header
  // is not drawn in CODE mode, and its LOG OUT hit box used to outlive it in
  // exactly this corner, so the button that ends a writing session logged
  // the player out and landed them on the login screen.
  expect(focus.back).not.toBeNull();
  await page.mouse.click(focus.back![0], focus.back![1]);
  await page.waitForTimeout(900);
  expect(await sceneNow(page)).toBe("playground");
  expect(await page.evaluate(() => window.__cwbCapture!.buttonAt("code"))).not.toBeNull();
  await page.screenshot({ path: `${SHOTS}/06-back-from-code.png` });
});
