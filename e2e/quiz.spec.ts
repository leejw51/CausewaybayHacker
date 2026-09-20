/**
 * VERY BASIC, end to end: the quiz before the line.
 *
 * The road's whole idea is "pick one of four, then type it", so this is the
 * one test that has to walk it the way a player does: open the first node of
 * RUST × VERY BASIC, press a wrong choice and see the editor stay locked,
 * press the right one and see it open, type the line the pack's own solution
 * carries, submit, and watch the node clear. The choices come from the wire
 * (`quest.quiz`), the line from the content file — the server never sends a
 * solution before a clear, which is the point.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  atScreen,
  clickButton,
  freshAccount,
  identifyOpenQuest,
  login,
  openSelectedNode,
  pickCategory,
  pickLand,
  setSource,
  submit,
  test,
  Wire,
} from "./fixtures.js";
import { expect } from "@playwright/test";

/** The reference solution of one quest, read straight out of the pack. */
function solutionOf(land: string, category: string, id: string): string {
  const text = readFileSync(
    fileURLToPath(
      new URL(`../content/${land}/${category}.toml`, import.meta.url),
    ),
    "utf8",
  );
  const at = text.indexOf(`id          = "${id}"`);
  expect(at, `${id} is in the pack`).toBeGreaterThan(-1);
  const from = text.indexOf("solution    = '''", at);
  const to = text.indexOf("'''", from + 17);
  return text.slice(from + 17, to).replace(/^\n/, "");
}

test("a wrong choice keeps the editor locked, the right one opens it, and the typed line clears", async ({
  page,
}) => {
  const account = freshAccount();
  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  try {
    await login(page, account);
    await pickLand(page, "rust");
    await pickCategory(page, "verybasic");
    await openSelectedNode(page);
    const id = await identifyOpenQuest(page, wire, "verybasic");
    expect(id, "the quest screen says which quest it is").toBeTruthy();
    expect(id!.startsWith("rust.verybasic."), id!).toBe(true);

    const quest = (await wire.ok("quest.get", { quest_id: id }))
      .quest as Record<string, unknown>;
    const quiz = quest.quiz as { choices: string[]; answer: number };
    expect(
      quiz,
      "a VERY BASIC quest carries its quiz on the wire",
    ).toBeTruthy();
    expect(quiz.choices).toHaveLength(4);
    expect(
      quest.solution,
      "the solution is not on the wire before a clear",
    ).toBeUndefined();

    // The editor is locked behind the quiz: typing changes nothing.
    const editor = page.locator(".cm-content");
    await expect(editor).toBeVisible();
    const before = await editor.innerText();
    await editor.click();
    await page.keyboard.type("xyz");
    expect(
      await editor.innerText(),
      "the editor is locked until the quiz is answered",
    ).toBe(before);

    // A wrong choice: still locked, still on the quest.
    const wrong = (quiz.answer + 1) % 4;
    await clickButton(page, `choice:${wrong}`);
    await page.waitForTimeout(400);
    await editor.click();
    await page.keyboard.type("xyz");
    expect(await editor.innerText(), "a wrong pick does not unlock").toBe(
      before,
    );

    // The right one opens the editor; the choices stop being buttons.
    await clickButton(page, `choice:${quiz.answer}`);
    await page.waitForTimeout(400);
    const gone = await page.evaluate(
      (w) => window.__cwbCapture?.buttonAt(w) ?? null,
      `choice:${wrong}`,
    );
    expect(
      gone,
      "after the right pick the choices are no longer pressable",
    ).toBeNull();

    // Type the line — the pack's own solution — and submit.
    await setSource(page, solutionOf("rust", "verybasic", id!));
    await submit(page);
    await atScreen(page, "result");
    const history = await wire.history();
    expect(history.length).toBe(1);
    expect(history[0].verdict).toBe("accepted");
    const after = (await wire.ok("quest.get", { quest_id: id }))
      .quest as Record<string, unknown>;
    expect(after.state).toBe("cleared");
  } finally {
    wire.close();
  }
});
