/**
 * STOP in the playground (PROTOCOL `run.cancel`), end to end: a program that
 * prints a line and then sleeps is started with RUN; once the line is back,
 * the same button — STOP now — ends it, the run answers `cancelled` well
 * inside its five-second clock, and the next RUN runs.
 */
import { mkdirSync } from "node:fs";
import type { Page } from "@playwright/test";
import {
  atScreen,
  clickButton,
  expect,
  freshAccount,
  login,
  pressWhenStill,
  sceneNow,
  setSource,
  test,
} from "./fixtures.js";

const SHOTS = process.env.STOP_SHOTS ?? "test-results/stop";
mkdirSync(SHOTS, { recursive: true });

const SLEEPER = `use std::io::Write;
fn main() {
    println!("before the nap");
    std::io::stdout().flush().unwrap();
    std::thread::sleep(std::time::Duration::from_secs(4));
    println!("after the nap");
}
`;

async function toPlayground(page: Page): Promise<void> {
  for (let i = 0; i < 200 && (await sceneNow(page)) !== "login"; i++) {
    const s = await sceneNow(page);
    if (s === "title" || s === "story") await page.keyboard.press("Space");
    await page.waitForTimeout(300);
  }
  await login(page, freshAccount());
  await expect
    .poll(async () => sceneNow(page), { timeout: 60_000 })
    .not.toMatch(/^(boot|login|title|story)$/);
  if ((await sceneNow(page)) !== "lands") {
    await page.keyboard.press("Escape");
    await page.waitForTimeout(500);
    if ((await sceneNow(page)) === "map") await clickButton(page, "menu");
  }
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await expect.poll(async () => sceneNow(page), { timeout: 60_000 }).toBe("playground");
}

const runLabel = (page: Page) =>
  page.evaluate(() => window.__cwbCapture!.buttons().find((b) => b.id === "run")?.label ?? null);

test("STOP ends a playground run, and RUN works after it", async ({ page }) => {
  const frames: Array<Record<string, unknown>> = [];
  page.on("websocket", (ws) =>
    ws.on("framereceived", (f) => {
      try {
        frames.push(JSON.parse(String(f.payload)));
      } catch {
        // not JSON: not ours
      }
    }),
  );
  // The fixture has already opened the page; reload so its socket is the
  // one this listener hears.
  await page.reload();
  await page.waitForFunction(() => typeof window.__cwbCapture?.settle === "function");
  await toPlayground(page);
  await page.waitForTimeout(1000);
  await setSource(page, SLEEPER);
  await pressWhenStill(page, "run");

  // Into the nap: its first line has streamed back.
  await expect
    .poll(
      () =>
        frames.some(
          (f) =>
            f.type === "run.log" &&
            String((f.payload as { chunk?: string }).chunk ?? "").includes("before the nap"),
        ),
      { timeout: 120_000, message: "the program printed its first line" },
    )
    .toBe(true);
  expect(await runLabel(page), "RUN says STOP while the run is out").toBe("STOP");
  await page.screenshot({ path: `${SHOTS}/${test.info().project.name}-1-running.png` });

  const t0 = Date.now();
  await clickButton(page, "run");
  const reply = () =>
    frames.find((f) => f.type === "playground.run.ok") as
      | { payload: { run: { outcome: string; stdout: string } } }
      | undefined;
  await expect.poll(() => reply()?.payload.run.outcome ?? null, { timeout: 10_000 }).toBe(
    "cancelled",
  );
  const took = Date.now() - t0;
  expect(took, `stopped in ${took} ms`).toBeLessThan(3_000);
  expect(reply()!.payload.run.stdout).toContain("before the nap");
  expect(reply()!.payload.run.stdout).not.toContain("after the nap");
  await expect.poll(() => runLabel(page), { timeout: 5_000 }).toBe("RUN");
  await page.waitForTimeout(600);
  await page.screenshot({ path: `${SHOTS}/${test.info().project.name}-2-stopped.png` });

  // And the next RUN runs.
  frames.length = 0;
  await setSource(page, 'fn main() { println!("after the stop"); }\n');
  await pressWhenStill(page, "run");
  await expect
    .poll(() => reply()?.payload.run.outcome ?? null, { timeout: 120_000 })
    .toBe("ok");
  expect(reply()!.payload.run.stdout).toBe("after the stop\n");
});
