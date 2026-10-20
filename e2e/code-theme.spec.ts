/**
 * The code theme: a DARK / LIGHT button beside the code face, on the
 * playground — the one screen with an editor now that every quest is picked,
 * not typed (SPEC §0). The preference survives a reload, and the editor (a
 * DOM element) follows it through `<html data-code-theme>`.
 */
import { expect, type Page } from "@playwright/test";
import {
  atScreen,
  clickButton,
  freshAccount,
  login,
  sceneNow,
  test,
} from "./fixtures";

const SHOTS = process.env.E2E_SHOTS;

const pref = (page: Page) =>
  page.evaluate(() => localStorage.getItem("cwbhacker.code.theme"));
const attr = (page: Page) =>
  page.evaluate(() => document.documentElement.dataset.codeTheme ?? null);
const label = (page: Page) =>
  page.evaluate(
    () =>
      window.__cwbCapture!.buttons().find((b) => b.id === "theme")?.label ??
      null,
  );
const editorBg = (page: Page) =>
  page.evaluate(
    () => getComputedStyle(document.querySelector(".cwb-editor")!).backgroundColor,
  );
const keywordColour = (page: Page) =>
  page.evaluate(() => {
    const spans = [...document.querySelectorAll(".cm-content span")];
    const kw = spans.find((s) => /^(fn|let|use|pub)$/.test(s.textContent ?? ""));
    return kw ? getComputedStyle(kw).color : null;
  });

async function flipAndCheck(page: Page, where: string): Promise<void> {
  await expect(page.locator(".cm-content")).toBeVisible();
  expect(await attr(page)).toBe("dark");
  await expect.poll(() => label(page)).toBe("DARK");
  const darkBg = await editorBg(page);
  const darkKw = await keywordColour(page);
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/${where}-dark.png` });

  await clickButton(page, "theme");
  await expect.poll(() => attr(page)).toBe("light");
  await expect.poll(() => pref(page)).toBe("light");
  await expect.poll(() => label(page)).toBe("LIGHT");
  expect(await editorBg(page)).toBe("rgba(252, 244, 224, 0.98)");
  expect(await editorBg(page)).not.toBe(darkBg);
  if (darkKw) expect(await keywordColour(page)).not.toBe(darkKw);
  await page.waitForTimeout(400);
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/${where}-light.png` });
}

test("the playground's THEME button lights the editor, for good", async ({
  page,
}) => {
  await login(page, freshAccount());
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await expect.poll(() => sceneNow(page), { timeout: 30_000 }).toBe("playground");
  await flipAndCheck(page, "playground");

  // For good: a reload keeps it.
  await page.reload();
  await expect
    .poll(() =>
      page.evaluate(() => typeof window.__cwbCapture?.buttons === "function"),
    )
    .toBe(true);
  await expect.poll(() => attr(page)).toBe("light");
  await expect.poll(() => pref(page)).toBe("light");

  // And back, once the playground is on screen again.
  await expect.poll(() => sceneNow(page), { timeout: 60_000 }).not.toMatch(/^(boot|title|story|login)$/);
  if ((await sceneNow(page)) !== "playground") {
    await atScreen(page, "lands");
    await clickButton(page, "playground");
    await expect.poll(() => sceneNow(page), { timeout: 30_000 }).toBe("playground");
  }
  await expect(page.locator(".cm-content")).toBeVisible();
  await expect.poll(() => label(page)).toBe("LIGHT");
  await clickButton(page, "theme");
  await expect.poll(() => attr(page)).toBe("dark");
  await expect.poll(() => pref(page)).toBe("dark");
});
