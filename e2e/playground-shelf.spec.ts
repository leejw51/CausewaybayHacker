/**
 * The playground's shelf: BACKUP writes one zip of every pad, CLEAR ALL asks
 * once and then empties it, and `playground.list` carries the limit the
 * capacity bar is drawn against.
 *
 * The zip is read back with Python's `zipfile`, which honours the UTF-8 name
 * flag the way Finder and Windows do.
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Download, Page } from "@playwright/test";
import {
  clickButton,
  expect,
  fixtureAccount,
  login,
  pressWhenStill,
  receivedFrames,
  setSource,
  test,
} from "./fixtures";

test.describe.configure({ mode: "serial" });

// Index 4 of the fixture mnemonic: no other spec signs in as it.
const ACCOUNT = fixtureAccount(4);
const RUN = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;
const PROGRAM = `fn main() {\n    println!("shelf ${RUN}");\n}\n`;

async function toPlayground(page: Page) {
  await login(page, ACCOUNT);
  await clickButton(page, "playground");
  await expect
    .poll(() => page.evaluate(() => window.__cwbCapture?.scene()))
    .toBe("playground");
  await expect(page.locator(".cm-content")).toBeVisible();
}

/** The last `playground.list` answer the page received. */
function lastList(): { snippets: { id: string }[]; limit?: number } | null {
  for (const f of [...receivedFrames()].reverse()) {
    try {
      const m = JSON.parse(f.text);
      if (m.payload && Array.isArray(m.payload.snippets)) return m.payload;
    } catch {
      /* not JSON */
    }
  }
  return null;
}

test("BACKUP zips every pad; CLEAR ALL asks, then empties the shelf", async ({
  page,
  ready,
}, info) => {
  void ready;
  await toPlayground(page);
  await setSource(page, PROGRAM);

  // Saved, so the shelf has a pad and the list says so, with its limit.
  const files: Download[] = [];
  page.on("download", (d) => void files.push(d));
  await pressWhenStill(page, "backup");
  await expect.poll(() => files.length, { timeout: 60_000 }).toBe(1);
  expect(files[0].suggestedFilename()).toMatch(
    /^causewaybay-pads-\d{8}-\d{4}\.zip$/,
  );
  await expect
    .poll(() => lastList()?.snippets.length ?? 0)
    .toBeGreaterThanOrEqual(1);
  expect(lastList()?.limit).toBe(1000);

  const dir = mkdtempSync(join(tmpdir(), "shelf-"));
  const zipPath = join(dir, "pads.zip");
  await files[0].saveAs(zipPath);
  const listing = JSON.parse(
    execFileSync(
      "python3",
      [
        "-I",
        "-c",
        "import json, sys, zipfile\n" +
          "z = zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None\n" +
          "print(json.dumps({n: z.read(n).decode() for n in z.namelist()}))",
        zipPath,
      ],
      { encoding: "utf8" },
    ),
  ) as Record<string, string>;
  info.attach("zip names", { body: Object.keys(listing).join("\n") });
  expect(Object.keys(listing).slice(0, 3)).toEqual([
    "pads.jsonl",
    "pads.csv",
    "pads.md",
  ]);
  const pads = listing["pads.jsonl"]
    .trim()
    .split("\n")
    .map((l) => JSON.parse(l));
  expect(pads.some((p) => p.source === PROGRAM)).toBe(true);
  expect(listing["pads.csv"]).toContain(`shelf ${RUN}`);
  expect(listing["pads.md"]).toContain("```rust\n" + PROGRAM.trimEnd());
  expect(
    Object.entries(listing).some(
      ([n, v]) => n.endsWith("/main.rs") && v === PROGRAM,
    ),
  ).toBe(true);

  // One press only asks: nothing is deleted.
  const before = lastList()!.snippets.length;
  const deletes = () =>
    ((info as unknown as { _sent: string[] })._sent ?? []).filter((s) =>
      s.includes('"playground.delete"'),
    ).length;
  const sentBefore = deletes();
  await clickButton(page, "clearall");
  await page.waitForTimeout(800);
  expect(deletes()).toBe(sentBefore);

  // The second press, within the window, deletes every pad.
  await clickButton(page, "clearall");
  await expect
    .poll(() => deletes() - sentBefore, { timeout: 30_000 })
    .toBe(before);
  await expect
    .poll(() => lastList()?.snippets.length, { timeout: 30_000 })
    .toBe(0);
  readFileSync(zipPath); // the backup outlives the shelf
});
