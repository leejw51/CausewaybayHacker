/**
 * The whole-game redesign, walked end to end in a real browser, in both
 * orientations: the title card, every land on the lands screen at once
 * (landscape), a level's map, a cheatsheet quest cleared by its right line,
 * the CLEARED screen over the harbour, THE RECORD — and not one error in the
 * page on the way. A screenshot of each screen is kept with the run.
 */
import {
  atScreen,
  clickButton,
  freshAccount,
  login,
  openSelectedNode,
  pickCategory,
  pickLand,
  revealChoice,
  sceneNow,
  test,
  Wire,
} from "./fixtures.js";
import { expect, type Page } from "@playwright/test";

const ids = (page: Page) =>
  page.evaluate(() => (window.__cwbCapture?.buttons() ?? []).map((b) => b.id));

test("the redesign: title, lands, map, quest, cleared, record", async ({ page }, info) => {
  test.setTimeout(240_000);
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  const shot = async (name: string) => {
    await page.waitForTimeout(800);
    await page.screenshot({ path: info.outputPath(`${name}.png`) });
  };
  const landscape = info.project.name === "landscape";

  // Title: the start key and the six languages, before anything else.
  await page.goto("/");
  await expect.poll(async () => sceneNow(page), { timeout: 30_000 }).toBe("title");
  const title = await ids(page);
  expect(title).toContain("start");
  expect(title.filter((id) => id.startsWith("lang:"))).toHaveLength(6);
  await shot("1-title");

  const account = freshAccount();
  const wire = await Wire.as(info.project.use.baseURL!, account);
  try {
    await login(page, account);
    await atScreen(page, "lands");
    // Landscape shows every land at once — nine plates, three by three —
    // so every one of them is a button without scrolling.
    if (landscape) {
      const lands = (await ids(page)).filter((id) => id.startsWith("land:"));
      expect(lands.sort()).toEqual(
        ["cpp", "go", "lua", "python", "pytorch", "remix", "rust", "typescript", "zig"]
          .map((l) => `land:${l}`)
          .sort(),
      );
    }
    // Every level of the chosen land is a tile.
    const cats = (await ids(page)).filter((id) => id.startsWith("cat:"));
    expect(cats).toEqual(expect.arrayContaining(["cat:cheatsheet", "cat:basic", "cat:hacker"]));
    await shot("2-lands");

    await pickLand(page, "rust");
    await pickCategory(page, "cheatsheet");
    await shot("3-map");

    // A cheatsheet quest: the pick is the answer, so the right line clears it.
    await openSelectedNode(page);
    const first = (await wire.mapOf("rust", "cheatsheet")).sort((a, b) => a.node - b.node)[0];
    const quest = (await wire.ok("quest.get", { quest_id: first.quest_id })).quest as {
      quiz: { answer: number };
    };
    expect(await ids(page)).toEqual(
      expect.arrayContaining(["choice:0", "choice:1", "choice:2", "choice:3"]),
    );
    await shot("4-quest");
    await revealChoice(page, quest.quiz.answer);
    await clickButton(page, `choice:${quest.quiz.answer}`);
    await atScreen(page, "result");
    expect(await ids(page)).toEqual(expect.arrayContaining(["next", "map"]));
    await shot("5-cleared");

    // THE RECORD, through the map's menu.
    await clickButton(page, "map");
    await atScreen(page, "map");
    await clickButton(page, "menu");
    await clickButton(page, "aux:stats");
    await expect.poll(async () => sceneNow(page)).toBe("stats");
    await shot("6-record");
  } finally {
    await wire.close();
  }
  expect(errors, "errors in the page").toEqual([]);
});
