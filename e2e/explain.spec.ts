/**
 * ASK AI on the practice screen does what it is asked.
 *
 * Asked to explain, the coder leaves `AI:` comments by the lines and every
 * line of the program is still the person's: take the comments out and it is
 * the program they ran. Asked to fix it, it fixes it. Needs `GROK_API_KEY`
 * (a real model is the thing under test) and skips without.
 */
import { expect, type Page } from "@playwright/test";
import {
  clickButton,
  editorText,
  freshAccount,
  login,
  openSelectedNode,
  pickCategory,
  pickLand,
  run,
  setSource,
  test,
} from "./fixtures";

const GROK = process.env.GROK_API_KEY;
const SHOTS = process.env.E2E_SHOTS;

const BROKEN =
  'use std::io::Read;\n\nfn main() {\n    let mut input = String::new();\n    std::io::stdin().read_to_string(&mut input).unwrap();\n    let name = input.trim();\n    println!("hello {}", nmae);\n}\n';

const buttons = (page: Page) =>
  page.evaluate(() =>
    window.__cwbCapture!.buttons().map((b) => ({ id: b.id, dim: b.dim })),
  );

/** Comments out, trailing blank lines evened up: the program itself. */
const program = (src: string) =>
  src
    .split("\n")
    .filter((l) => !l.trim().startsWith("//"))
    .join("\n")
    .trimEnd();

/** A quest's CODE page with the broken program run, and ASK AI open. */
async function askReady(page: Page): Promise<string> {
  await login(page, freshAccount());
  await page.evaluate((k) => {
    localStorage.setItem("cwbhacker.ai.key.grok", k);
    localStorage.setItem("cwbhacker.ai.provider", "grok");
  }, GROK!);
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await openSelectedNode(page);
  await clickButton(page, "focus");
  await setSource(page, BROKEN);
  await run(page);
  await page.waitForTimeout(8000);
  // On the code page's own bar, not only on the bench.
  expect((await buttons(page)).map((b) => b.id)).toContain("agent");
  await clickButton(page, "agent");
  await expect(page.locator("input.cwb-agent-field").first()).toBeVisible();
  return editorText(page);
}

/** Ask, and wait until the coder has changed the file and stopped. */
async function ask(page: Page, text: string, before: string): Promise<string> {
  const field = page.locator("input.cwb-agent-field").first();
  await field.click();
  await page.keyboard.type(text);
  await page.keyboard.press("Enter");
  await expect
    .poll(async () => (await editorText(page)) !== before, { timeout: 240_000 })
    .toBe(true);
  await expect
    .poll(
      async () =>
        (await buttons(page)).find((b) => b.id === "stop")?.dim ?? true,
      { timeout: 240_000 },
    )
    .toBe(true);
  await page.waitForTimeout(1500);
  const after = await editorText(page);
  console.log(after);
  return after;
}

test("asked to explain, ASK AI comments and leaves the code alone", async ({
  page,
}, info) => {
  test.skip(!GROK, "needs GROK_API_KEY");
  test.setTimeout(400_000);
  const before = await askReady(page);
  const after = await ask(
    page,
    "왜 컴파일 에러가 나? 주석으로 설명해줘",
    before,
  );
  if (SHOTS)
    await page.screenshot({
      path: `${SHOTS}/explain-${info.project.name}.png`,
    });
  expect(after).toContain("AI:");
  expect(program(after)).toBe(program(before));
  expect(after).toContain("nmae");
});

test("asked to fix, ASK AI fixes it", async ({ page }, info) => {
  test.skip(!GROK, "needs GROK_API_KEY");
  test.setTimeout(400_000);
  const before = await askReady(page);
  const after = await ask(page, "고쳐줘", before);
  if (SHOTS)
    await page.screenshot({ path: `${SHOTS}/fix-${info.project.name}.png` });
  // Fixed: the program is not the one they ran, and the error is gone —
  // whether by the one-word fix or by solving the exercise outright, which
  // is what "fix it" means to a program that does not do the exercise.
  expect(program(after)).not.toBe(program(before));
  expect(program(after)).not.toContain("nmae");
});
