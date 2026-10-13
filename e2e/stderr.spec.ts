/**
 * STDERR: a button beside AUTO-RUN, on the quest screen and the playground
 * alike. Off by default — the output is what the program printed, and the
 * compiler only when the build failed. One preference for both screens.
 *
 * The output is drawn on a canvas, so what this checks is the button: that it
 * is there, on screen, says its state, and keeps the preference.
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

const button = (page: Page) =>
  page.evaluate(() => {
    const b = window.__cwbCapture!.buttons().find((b) => b.id === "stderr");
    return b ? { label: b.label, client: b.client } : null;
  });
const pref = (page: Page) =>
  page.evaluate(() => localStorage.getItem("cwbhacker.code.stderr"));

async function offThenOn(page: Page): Promise<void> {
  await expect(page.locator(".cm-content")).toBeVisible();
  await expect.poll(async () => (await button(page))?.label).toBe("STDERR OFF");
  // Inside the window: a sixth button on a row must not be pushed off it.
  const b = (await button(page))!;
  const vp = page.viewportSize()!;
  expect(b.client[0]).toBeGreaterThanOrEqual(0);
  expect(b.client[1]).toBeGreaterThanOrEqual(0);
  expect(b.client[0] + b.client[2]).toBeLessThanOrEqual(vp.width + 1);
  expect(b.client[1] + b.client[3]).toBeLessThanOrEqual(vp.height + 1);

  await clickButton(page, "stderr");
  await expect.poll(async () => (await button(page))?.label).toBe("STDERR ON");
  await expect.poll(() => pref(page)).toBe("on");
  await clickButton(page, "stderr");
  await expect.poll(async () => (await button(page))?.label).toBe("STDERR OFF");
  await expect.poll(() => pref(page)).toBe("off");
}

test("the playground has STDERR, off by default", async ({ page }) => {
  await login(page, freshAccount());
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await expect
    .poll(() => sceneNow(page), { timeout: 30_000 })
    .toBe("playground");
  await offThenOn(page);
});

test("a quest has STDERR, off by default", async ({ page }) => {
  await login(page, freshAccount());
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await openSelectedNode(page);
  await offThenOn(page);
});
