/**
 * The run console scrolls, by every hand a player has: a trackpad's small
 * wheel steps, a mouse wheel's big ones, and a finger on an iPad. A compile
 * error longer than the console used to show only its last two lines —
 * `aborting due to 2 previous errors` — and a trackpad would not move it.
 *
 * In landscape the console sits beside the code, the full height of it; in
 * portrait it stays underneath.
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
  run,
  sceneNow,
  setSource,
  test,
} from "./fixtures";

const SHOTS = process.env.E2E_SHOTS;

/** Twelve unknown names: a page of `rustc` errors, far taller than the console. */
const BROKEN =
  "fn main() {\n" +
  Array.from({ length: 12 }, (_, i) => `    let a${i} = nope_${i};\n`).join(
    "",
  ) +
  "}\n";

type Box = [number, number, number, number];

/** Where the console is, how much it holds past its height, how far back. */
const consoleRect = (page: Page) =>
  page.evaluate(() => window.__cwbCapture!.consoleRect?.() ?? null);

/** RUN the broken program and wait for more output than the console shows. */
async function runBroken(page: Page): Promise<Box> {
  await setSource(page, BROKEN);
  await run(page);
  await expect
    .poll(async () => (await consoleRect(page))?.overflow ?? 0, {
      timeout: 120_000,
    })
    .toBeGreaterThan(3);
  await page.waitForTimeout(800);
  return (await consoleRect(page))!.client as Box;
}

/** Beside the code in landscape, under it in portrait. */
function placed(page: Page, r: Box, landscape: boolean): void {
  const vp = page.viewportSize()!;
  if (landscape) {
    expect(r[0]).toBeGreaterThan(vp.width * 0.45);
    expect(r[3]).toBeGreaterThan(vp.height * 0.4);
  } else {
    expect(r[1]).toBeGreaterThan(vp.height * 0.4);
  }
}

/** Trackpad, wheel and finger, each one moving the console it is over. */
async function scrolls(page: Page, r: Box): Promise<void> {
  const scroll = async () => (await consoleRect(page))!.scroll;
  const cx = r[0] + r[2] / 2;
  const cy = r[1] + r[3] / 2;
  // A finished run opens at the top — the first error, not `aborting due
  // to…` — which is as far back as it goes.
  const probe = (await consoleRect(page))!;
  expect(probe.scroll).toBe(probe.overflow);

  // A mouse wheel down to the live tail.
  await page.mouse.move(cx, cy);
  await page.mouse.wheel(0, 4000);
  await expect.poll(scroll).toBe(0);

  // A trackpad: many small steps, each one well under a line.
  for (let i = 0; i < 30; i++) await page.mouse.wheel(0, -3);
  await expect.poll(scroll).toBeGreaterThan(0);
  const afterPad = await scroll();

  // A mouse wheel: one notch back toward the live tail, then all the way.
  await page.mouse.wheel(0, 100);
  await expect.poll(scroll).toBeLessThan(afterPad);
  await page.mouse.wheel(0, 4000);
  await expect.poll(scroll).toBe(0);

  // A finger: touch down on the console and drag it down, to the past.
  const cdp = await page.context().newCDPSession(page);
  const touch = (type: string, y: number) =>
    cdp.send("Input.dispatchTouchEvent", {
      type,
      touchPoints: type === "touchEnd" ? [] : [{ x: cx, y }],
    });
  const top = r[1] + 10;
  await touch("touchStart", top);
  for (let k = 1; k <= 10; k++)
    await touch("touchMove", top + (k * (r[3] - 20)) / 10);
  await touch("touchEnd", 0);
  await expect.poll(scroll).toBeGreaterThan(0);
}

test("the quest console in CODE mode scrolls, beside the code when wide", async ({
  page,
}, info) => {
  await login(page, freshAccount());
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await openSelectedNode(page);
  await clickButton(page, "focus");
  const r = await runBroken(page);
  placed(page, r, info.project.name === "landscape");
  if (SHOTS)
    await page.screenshot({
      path: `${SHOTS}/quest-code-${info.project.name}.png`,
    });
  await scrolls(page, r);
});

for (const mode of ["framed", "code"] as const) {
  test(`the playground's output scrolls (${mode}), beside the code when wide`, async ({
    page,
  }, info) => {
    await login(page, freshAccount());
    await atScreen(page, "lands");
    await clickButton(page, "playground");
    await expect
      .poll(() => sceneNow(page), { timeout: 30_000 })
      .toBe("playground");
    if (mode === "code") await clickButton(page, "code");
    const r = await runBroken(page);
    if (SHOTS)
      await page.screenshot({
        path: `${SHOTS}/pg-${mode}-${info.project.name}.png`,
      });
    placed(page, r, info.project.name === "landscape");
    await scrolls(page, r);
  });
}
