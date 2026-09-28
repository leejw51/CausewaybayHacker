/**
 * 따라치기 — the ANSWER drill — in a real browser, on the real server.
 *
 * The unit suite holds the rules (`frontend/tests/editor.test.ts`); this is
 * the drill as a player meets it: the button, the keyboard, CodeMirror's own
 * input handling and the scene's fills all in one loop. Four promises:
 *
 *   * a key that is not the answer's next character does not go in, and the
 *     editor says so (it shakes);
 *   * a keyword goes in on its first letter;
 *   * retyping what the drill just put in is swallowed, not a miss;
 *   * the whole answer takes far fewer keys than it has characters.
 */
import {
  clickButton,
  enterRustQuest,
  expect,
  freshAccount,
  login,
  test,
  Wire,
} from "./fixtures.js";
import type { Page } from "@playwright/test";

test.describe.configure({ mode: "serial" });

/** The buffer, without the ghost of the answer drawn inside it. */
async function typed(page: Page): Promise<string> {
  return page.evaluate(() =>
    Array.from(document.querySelectorAll(".cm-line"))
      .map((l) => {
        const c = l.cloneNode(true) as HTMLElement;
        c.querySelectorAll(".cwb-ghost, .cwb-hint, .cm-widgetBuffer").forEach((g) =>
          g.remove(),
        );
        return (c.textContent ?? "").replace(/\u200b/g, "");
      })
      .join("\n"),
  );
}

async function shaken(page: Page): Promise<boolean> {
  return page.evaluate(
    () => document.querySelector(".cwb-editor")?.classList.contains("cwb-miss") ?? false,
  );
}

async function press(page: Page, ch: string): Promise<void> {
  if (ch === "\n") await page.keyboard.press("Enter");
  else if (ch === "\t") await page.keyboard.press("Tab");
  else await page.keyboard.type(ch);
}

test("따라치기: a wrong key is refused, a keyword comes on one letter, and the answer is short work", async ({
  page,
}) => {
  const account = freshAccount();
  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  try {
    await login(page, account);
    const questId = await enterRustQuest(page, wire);

    // CODE mode first: the drills live on its band.
    await clickButton(page, "focus");
    await clickButton(page, "answer");
    // The starter is cleared and the drill is armed when the ghost appears.
    await expect(page.locator(".cwb-ghost")).toBeVisible({ timeout: 30_000 });
    await expect.poll(() => typed(page)).toBe("");

    // Already paid for by the button, so this second ask is free.
    const res = await wire.ok("quest.solve", { quest_id: questId });
    const answer = String((res as { source: string }).source);
    expect(answer.length).toBeGreaterThan(10);

    await page.locator(".cm-content").click();

    // **A keyword on its first letter.** A Rust answer opens with `use` or
    // `fn`; either way one key should be more than one character.
    await press(page, answer[0]);
    await expect.poll(() => typed(page)).not.toBe(answer[0]);
    const first = await typed(page);
    expect(answer.startsWith(first)).toBe(true);
    expect(first.length).toBeGreaterThan(1);

    // **Habit is not a miss.** The next letter of the word that just
    // finished itself is already there; typing it changes nothing and does
    // not shake the editor.
    await press(page, first[1]);
    await page.waitForTimeout(150);
    expect(await typed(page)).toBe(first);
    expect(await shaken(page)).toBe(false);

    // **A wrong key does not go in.**
    const next = answer[first.length];
    const wrong = next === "#" ? "@" : "#";
    await press(page, wrong);
    await expect.poll(() => shaken(page)).toBe(true);
    expect(await typed(page)).toBe(first);

    // **The rest, one right key at a time.** Count them.
    let keys = 1;
    for (let guard = 0; guard < answer.length * 2; guard++) {
      const now = await typed(page);
      if (now === answer) break;
      expect(answer.startsWith(now), `buffer left the answer at ${now.length}`).toBe(true);
      await press(page, answer[now.length]);
      keys++;
    }
    await expect.poll(() => typed(page)).toBe(answer);
    test.info().annotations.push({
      type: "keys",
      description: `${keys} keys for ${answer.length} characters`,
    });
    console.log(`drill: ${keys} keys for ${answer.length} characters (${questId})`);
    expect(keys).toBeLessThan(answer.length * 0.75);
    await page.screenshot({ path: test.info().outputPath("drill-done.png") });
  } finally {
    wire.close();
  }
});
