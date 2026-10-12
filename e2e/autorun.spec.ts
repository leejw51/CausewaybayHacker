/**
 * AUTO-RUN: a button beside RUN, on the quest screen and the playground alike.
 * On by default, it makes a plain ENTER in the editor run the code; off, ENTER
 * is only a new line again. One preference for both screens.
 *
 * Counted on the wire rather than by the answer: the request leaving the page
 * is the thing ENTER has to cause, and it needs no compiler on the server.
 */
import { expect, type Page } from "@playwright/test";
import {
  atScreen,
  clickButton,
  freshAccount,
  login,
  openSelectedNode,
  pickCategory,
  pickLand,
  sceneNow,
  test,
} from "./fixtures";

/**
 * How many requests of `method` the page has sent so far. Read from the
 * frames the `ready` fixture collects from before boot: a listener attached
 * here would miss the socket the client opened while booting.
 */
function countSent(method: string): () => number {
  return () =>
    ((test.info() as unknown as { _sent?: string[] })._sent ?? []).filter((f) =>
      f.includes(`"type":"${method}"`),
    ).length;
}

const label = (page: Page) =>
  page.evaluate(
    () =>
      window.__cwbCapture!.buttons().find((b) => b.id === "autorun")?.label ??
      null,
  );
const pref = (page: Page) =>
  page.evaluate(() => localStorage.getItem("cwbhacker.code.autoRun"));

async function enterRunsThenToggle(
  page: Page,
  runs: () => number,
): Promise<void> {
  const editor = page.locator(".cm-content");
  await expect(editor).toBeVisible();
  await expect.poll(() => label(page)).toBe("AUTO-RUN ON");

  await editor.click();
  await page.keyboard.press("End");
  const before = runs();
  await page.keyboard.press("Enter");
  await expect.poll(runs).toBeGreaterThan(before);

  // Off: ENTER is a new line and nothing else.
  await clickButton(page, "autorun");
  await expect.poll(() => label(page)).toBe("AUTO-RUN OFF");
  await expect.poll(() => pref(page)).toBe("off");
  // Any run the first ENTER queued has had time to go out.
  await page.waitForTimeout(1500);
  const settled = runs();
  await editor.click();
  await page.keyboard.press("Enter");
  await page.waitForTimeout(1500);
  expect(runs()).toBe(settled);
}

test("ENTER runs the playground while AUTO-RUN is on", async ({ page }) => {
  const runs = countSent("playground.run");
  await login(page, freshAccount());
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await expect
    .poll(() => sceneNow(page), { timeout: 30_000 })
    .toBe("playground");
  await enterRunsThenToggle(page, runs);
});

test("ENTER runs a quest while AUTO-RUN is on", async ({ page }) => {
  const runs = countSent("quest.run");
  await login(page, freshAccount());
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await openSelectedNode(page);
  await enterRunsThenToggle(page, runs);
});
