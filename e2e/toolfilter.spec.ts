/**
 * The FILTER box at the head of every menu-button band.
 *
 * Twenty touch-sized buttons were most of the screen they are the tools for,
 * so each band carries a text box: type part of a label (or an id) and only
 * the buttons that match stay drawn — and stay clickable. Several words keep
 * a button that matches any of them. Empty, every button is back. This walks
 * the three bands a player meets: the practice page's toolbar (short now —
 * a quest is picked, not typed, so it is BACK, LOBBY, COPY BRIEF and the text
 * size; SPEC §0), the playground's split page and the playground's code page.
 *
 * A fixture account rather than a fresh one: nothing here records progress,
 * and the fresh path needs the CausewaybayWallet binary built beside this
 * repo.
 */
import {
  atScreen,
  choicesShown,
  clickButton,
  expect,
  fixtureAccount,
  login,
  openSelectedNode,
  pickCategory,
  pickLand,
  test,
} from "./fixtures.js";
import type { Page } from "@playwright/test";

/** Every button the scene would answer a click on, quiz choices aside. */
const ids = (page: Page) =>
  page.evaluate(() =>
    window.__cwbCapture!.buttons()
      .map((b) => b.id)
      .filter((id) => !id.startsWith("choice:")),
  );

/** Type into the filter and wait for the band to be redrawn. */
async function narrow(page: Page, query: string): Promise<string[]> {
  await page.locator("input.cwb-field:visible").and(page.locator('[placeholder="FILTER"]')).fill(query);
  await page.waitForTimeout(400);
  return ids(page);
}

test("the filter narrows the menu buttons on the practice page and the playground", async ({
  page,
}) => {
  await login(page, fixtureAccount(2));
  await pickLand(page, "rust");
  await pickCategory(page, "verybasic");
  await openSelectedNode(page);
  await choicesShown(page);
  await expect(page.locator(".cm-content")).toBeHidden();
  await page.waitForTimeout(1000);

  // The practice page's toolbar: the pick's own few buttons.
  const quest = await ids(page);
  expect(quest).toEqual(
    expect.arrayContaining(["back", "lobby", "copybrief", "fontdown", "fontup"]),
  );
  const copies = await narrow(page, "copy");
  expect(copies).toContain("copybrief");
  expect(copies, "a button that does not match is gone").not.toContain("fontup");
  expect(copies.length).toBeLessThan(quest.length);
  // Several words keep every button that matches any one of them.
  const several = await narrow(page, "copy font");
  expect(several).toEqual(expect.arrayContaining(["copybrief", "fontup", "fontdown"]));
  expect(several, "a button that matches none of the words is gone").not.toContain("lobby");
  // Empty puts every button back.
  expect(await narrow(page, "")).toEqual(quest);

  // The playground, split page.
  await clickButton(page, "back");
  await page.waitForTimeout(800);
  await page.keyboard.press("Escape");
  await page.waitForTimeout(500);
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await expect(page.locator(".cm-content")).toBeVisible();
  await page.waitForTimeout(1500);
  const split = await ids(page);
  expect(split).toContain("rust");
  expect(split).toContain("run");
  const pythons = await narrow(page, "python");
  expect(pythons).toContain("python");
  expect(pythons).not.toContain("rust");
  expect(pythons).not.toContain("run");
  // Symbolic: a concept, Korean initials and an abbreviation, together.
  const sym = await narrow(page, "font ㅈㅈ cpcd");
  expect(sym).toEqual(expect.arrayContaining(["fontup", "fontdown", "face"]));
  expect(sym).not.toContain("rust");
  await narrow(page, "");

  // The playground, code page.
  await clickButton(page, "code");
  await page.waitForTimeout(1200);
  const code = await ids(page);
  expect(code).toContain("copycode");
  const pastes = await narrow(page, "paste");
  expect(pastes).toEqual(expect.arrayContaining(["pastecode", "pastein"]));
  expect(pastes).not.toContain("copycode");
  // DONE is not a menu button: the way out stays whatever is typed.
  expect(pastes).toContain("unfocus");
  // And a kept button still works: DONE takes the code page away.
  await narrow(page, "");
  await clickButton(page, "unfocus");
  await page.waitForTimeout(800);
  expect(await ids(page)).toContain("rust");
});
