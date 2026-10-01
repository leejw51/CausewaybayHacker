/**
 * One prompt to ASK AI is one UNDO, on the practice page and the playground.
 *
 * A fix the coder types in over a minute comes out with one press of UNDO
 * and goes back with one REDO — not one press per pause in its typing. Needs
 * `GROK_API_KEY` (a real model typing at its own pace is the thing under
 * test) and skips without.
 */
import { expect, type Page } from "@playwright/test";
import {
  atScreen,
  clickButton,
  editorText,
  freshAccount,
  login,
  openSelectedNode,
  pickCategory,
  pickLand,
  setSource,
  test,
} from "./fixtures";

const GROK = process.env.GROK_API_KEY;

/**
 * A fix in several tool calls, with the model thinking between them: the
 * pauses are what used to split one prompt into several UNDOs.
 */
const ASK =
  "고쳐줘. edit_code 를 세 번 따로 써서: 먼저 nmae 를 name 으로, 그 다음 name 변수를 who 로 바꾸고, 마지막으로 hello 를 hi 로 바꿔줘.";

const BROKEN =
  'use std::io::Read;\n\nfn main() {\n    let mut input = String::new();\n    std::io::stdin().read_to_string(&mut input).unwrap();\n    let name = input.trim();\n    println!("hello {}", nmae);\n}\n';

const buttons = (page: Page) =>
  page.evaluate(() =>
    window.__cwbCapture!.buttons().map((b) => ({ id: b.id, dim: b.dim })),
  );

const dim = async (page: Page, id: string) =>
  (await buttons(page)).find((b) => b.id === id)?.dim ?? true;

async function useGrok(page: Page): Promise<void> {
  await page.evaluate((k) => {
    localStorage.setItem("cwbhacker.ai.key.grok", k);
    localStorage.setItem("cwbhacker.ai.provider", "grok");
  }, GROK!);
}

/** Ask, and wait until the coder has changed the file and stopped. */
async function askFix(page: Page, before: string): Promise<string> {
  await clickButton(page, "agent");
  const field = page.locator("input.cwb-agent-field").first();
  await expect(field).toBeVisible();
  await field.click();
  await page.keyboard.type(ASK);
  await page.keyboard.press("Enter");
  await expect
    .poll(async () => (await editorText(page)) !== before, { timeout: 240_000 })
    .toBe(true);
  await expect.poll(() => dim(page, "stop"), { timeout: 240_000 }).toBe(true);
  // Past the practice page's idle push, so the stack has had its say.
  await page.waitForTimeout(3000);
  return editorText(page);
}

/** UNDO once, then REDO once, and say what each left in the editor. */
async function undoRedo(
  page: Page,
): Promise<{ undone: string; redone: string }> {
  await clickButton(page, "undo");
  await page.waitForTimeout(1500);
  const undone = await editorText(page);
  await clickButton(page, "redo");
  await page.waitForTimeout(1500);
  return { undone, redone: await editorText(page) };
}

test("practice page: the AI's fix is one UNDO and one REDO", async ({
  page,
}) => {
  test.skip(!GROK, "needs GROK_API_KEY");
  test.setTimeout(400_000);
  await login(page, freshAccount());
  await useGrok(page);
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await openSelectedNode(page);
  await clickButton(page, "focus");
  await setSource(page, BROKEN);
  // The person's own text on the stack before the prompt.
  await page.waitForTimeout(3000);
  const before = await editorText(page);
  const after = await askFix(page, before);
  const { undone, redone } = await undoRedo(page);
  expect(undone).toBe(before);
  expect(redone).toBe(after);
});

test("playground: the AI's fix is one UNDO and one REDO", async ({ page }) => {
  test.skip(!GROK, "needs GROK_API_KEY");
  test.setTimeout(400_000);
  await login(page, freshAccount());
  await useGrok(page);
  await clickButton(page, "playground");
  await atScreen(page, "playground");
  await expect(page.locator(".cm-content")).toBeVisible();
  await setSource(page, BROKEN);
  const before = await editorText(page);
  const after = await askFix(page, before);
  const { undone, redone } = await undoRedo(page);
  expect(undone).toBe(before);
  expect(redone).toBe(after);
});
