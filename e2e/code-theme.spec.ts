/**
 * The code theme: a DARK / LIGHT button beside the code face, on the quest
 * screen and the playground alike. One preference for both, it survives a
 * reload, and the editor (a DOM element) follows it through
 * `<html data-code-theme>`.
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

test("the quest screen's THEME button lights the editor, for good", async ({
  page,
}) => {
  await login(page, freshAccount());
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await openSelectedNode(page);
  await flipAndCheck(page, "quest");

  await page.reload();
  await expect
    .poll(() =>
      page.evaluate(() => typeof window.__cwbCapture?.buttons === "function"),
    )
    .toBe(true);
  await expect.poll(() => attr(page)).toBe("light");
});

test("the playground's THEME button is the same preference", async ({
  page,
}) => {
  await login(page, freshAccount());
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await expect.poll(() => sceneNow(page), { timeout: 30_000 }).toBe("playground");
  await flipAndCheck(page, "playground");

  // And back.
  await clickButton(page, "theme");
  await expect.poll(() => attr(page)).toBe("dark");
  await expect.poll(() => pref(page)).toBe("dark");
});
