/**
 * ASK AI on the practice screen explains in comments and does not fix.
 *
 * Asked outright to fix a program that does not compile, the coder leaves
 * `AI:` comments by the lines and every line of the program is still the
 * person's: take the comments out and it is the program they ran. Needs
 * `GROK_API_KEY` (a real model is the thing under test) and skips without.
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

test("ASK AI on the code page explains in comments and leaves the code alone", async ({
  page,
}, info) => {
  test.skip(!GROK, "needs GROK_API_KEY");
  test.setTimeout(400_000);
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
  const before = await editorText(page);

  // On the code page's own bar now, not only on the bench.
  expect((await buttons(page)).map((b) => b.id)).toContain("agent");
  await clickButton(page, "agent");
  const field = page.locator("input.cwb-agent-field").first();
  await expect(field).toBeVisible();
  // No WRITE here: the coder on this screen does not write programs.
  expect((await buttons(page)).map((b) => b.id)).not.toContain("write");
  await field.click();
  await page.keyboard.type("왜 컴파일 에러가 나? 고쳐줘");
  await page.keyboard.press("Enter");

  // Until the coder has written something and stopped.
  await expect
    .poll(async () => (await editorText(page)).includes("AI:"), {
      timeout: 240_000,
    })
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
  if (SHOTS)
    await page.screenshot({
      path: `${SHOTS}/explain-${info.project.name}.png`,
    });
  console.log(after);
  // Commented, and not fixed: the typo is still the person's to find.
  expect(after).toContain("AI:");
  expect(program(after)).toBe(program(before));
  expect(after).toContain("nmae");
});
