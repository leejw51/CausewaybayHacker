/**
 * The playground's pad list on an iPad, by finger, end to end: forty pads on
 * the shelf, the list scrolled by a drag, a tap that opens a pad (and a drag
 * that does not), BACKUP, and CLEAR ALL asked twice.
 *
 * Touch is driven through CDP's `Input.dispatchTouchEvent`, so the scene
 * sees the same `pointerdown / move / up` with `pointerType: "touch"` that
 * Safari on an iPad sends. Playwright's own `touchscreen` only taps.
 */
import { mkdirSync } from "node:fs";
import type { CDPSession, Download, Page } from "@playwright/test";
import {
  clickButton,
  expect,
  fixtureAccount,
  login,
  test,
  Wire,
} from "./fixtures";

test.describe.configure({ mode: "serial" });
test.use({ deviceScaleFactor: 2, hasTouch: true, isMobile: true });

const SHOTS = process.env.IPAD_SHOTS ?? "test-results/ipad";
mkdirSync(SHOTS, { recursive: true });

// Index 1 of the fixture mnemonic: no other spec signs in as it.
const ACCOUNT = fixtureAccount(1);
const PADS = 40;

type Btn = { id: string; client: [number, number, number, number] };
const buttons = (page: Page): Promise<Btn[]> =>
  page.evaluate(() =>
    window.__cwbCapture!.buttons().map((b) => ({ id: b.id, client: b.client })),
  );
const rowIds = async (page: Page) =>
  (await buttons(page))
    .filter((b) => b.id.startsWith("snip:"))
    .map((b) => b.id);

async function touch(cdp: CDPSession, type: string, x: number, y: number) {
  await cdp.send("Input.dispatchTouchEvent", {
    type,
    touchPoints: type === "touchEnd" ? [] : [{ x, y }],
  });
}

/** A finger from one point to another, in steps, as a hand moves. */
async function drag(cdp: CDPSession, x: number, y0: number, y1: number) {
  await touch(cdp, "touchStart", x, y0);
  for (let i = 1; i <= 12; i++) {
    await touch(cdp, "touchMove", x, y0 + ((y1 - y0) * i) / 12);
    await new Promise((r) => setTimeout(r, 16));
  }
  await touch(cdp, "touchEnd", x, y1);
}

async function tap(cdp: CDPSession, x: number, y: number) {
  await touch(cdp, "touchStart", x, y);
  await touch(cdp, "touchEnd", x, y);
}

const middle = (b: Btn): [number, number] => [
  b.client[0] + b.client[2] / 2,
  b.client[1] + b.client[3] / 2,
];

test("iPad: the pad list scrolls by finger, opens on a tap, backs up and clears", async ({
  page,
  ready,
}) => {
  void ready;
  await page.setViewportSize({ width: 1180, height: 820 });

  const wire = await Wire.as(test.info().project.use.baseURL!, ACCOUNT);
  for (const p of (await wire.ok("playground.list", {})).snippets as {
    id: string;
  }[])
    await wire.ok("playground.delete", { id: p.id });
  for (let i = 1; i <= PADS; i++)
    await wire.ok("playground.save", {
      name: `pad ${String(i).padStart(2, "0")}`,
      lang: "rust",
      source: `fn main() { println!("${i}"); }\n`,
    });

  await login(page, ACCOUNT);
  await clickButton(page, "playground");
  await expect
    .poll(() => page.evaluate(() => window.__cwbCapture?.scene()))
    .toBe("playground");
  await expect(page.locator(".cm-content")).toBeVisible();
  await expect.poll(async () => (await rowIds(page)).length).toBeGreaterThan(3);
  await page.waitForTimeout(800);
  await page.screenshot({ path: `${SHOTS}/playground-list-top.png` });

  const cdp = await page.context().newCDPSession(page);
  const first = await rowIds(page);
  expect(first.length).toBeLessThan(PADS); // it overflows: there is something to scroll to

  // The first row sits right under the search box: no note above it now.
  const rows0 = (await buttons(page)).filter((b) => b.id.startsWith("snip:"));
  const search = await page
    .locator("input.cwb-field, input[type=search]")
    .first()
    .boundingBox();
  if (search)
    expect(rows0[0].client[1] - (search.y + search.height)).toBeLessThan(60);

  // Drag up: later pads come into view, and nothing was opened by it.
  const heldBefore = await page.locator(".cm-content").innerText();
  const [rx, ry] = middle(rows0[Math.min(3, rows0.length - 1)]);
  await drag(cdp, rx, ry, ry - 300);
  await page.waitForTimeout(300);
  const after = await rowIds(page);
  expect(after).not.toEqual(first);
  expect(after.some((id) => !first.includes(id))).toBe(true);
  expect(await page.locator(".cm-content").innerText()).toBe(heldBefore);
  await page.screenshot({ path: `${SHOTS}/playground-list-scrolled.png` });

  // All the way to the end: the last pad is reachable.
  for (let i = 0; i < 8; i++) await drag(cdp, rx, ry, ry - 400);
  await page.waitForTimeout(300);
  const listed = (await wire.ok("playground.list", {})).snippets as {
    id: string;
  }[];
  const oldest = `snip:${listed[listed.length - 1].id}`;
  expect(await rowIds(page)).toContain(oldest);

  // A tap opens the pad it lands on — the one whose name the row shows.
  const target = (
    await page.evaluate(() => window.__cwbCapture!.buttons())
  ).find((b) => b.id === oldest)!;
  const n = Number(target.label.replace(/\D/g, ""));
  await tap(cdp, ...middle(target as Btn));
  await expect
    .poll(() => page.locator(".cm-content").innerText(), { timeout: 15_000 })
    .toContain(`println!("${n}")`);

  // BACKUP, by a finger: one zip.
  const files: Download[] = [];
  page.on("download", (d) => void files.push(d));
  const backup = (await buttons(page)).find((b) => b.id === "backup")!;
  await tap(cdp, ...middle(backup));
  await expect.poll(() => files.length, { timeout: 60_000 }).toBe(1);
  expect(files[0].suggestedFilename()).toMatch(/\.zip$/);

  // CLEAR ALL: one tap asks, the second empties the shelf.
  const clear = async () =>
    tap(
      cdp,
      ...middle((await buttons(page)).find((b) => b.id === "clearall")!),
    );
  await clear();
  await page.waitForTimeout(600);
  expect(
    ((await wire.ok("playground.list", {})).snippets as unknown[]).length,
  ).toBe(PADS);
  await clear();
  await expect
    .poll(
      async () =>
        ((await wire.ok("playground.list", {})).snippets as unknown[]).length,
      {
        timeout: 30_000,
      },
    )
    .toBe(0);
  await page.waitForTimeout(500);
  await page.screenshot({ path: `${SHOTS}/playground-cleared.png` });
  wire.close();
});
