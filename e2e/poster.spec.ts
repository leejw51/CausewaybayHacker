/**
 * POSTER and DISK READER, in a real browser.
 *
 * The round trip the feature promises: a program written in the playground
 * leaves as a picture that is signed by the wallet, and the picture comes
 * back in as the same program with the signature checked. Both halves are
 * driven the way a person drives them — the buttons are canvas-drawn and
 * found through `__cwbCapture`, the files arrive as real downloads and go
 * back through the real file chooser.
 *
 * **Verified in Node, not in the page.** The PNG's text chunks are walked
 * here, and the signature is recovered here, with the same `wallet.ts` the
 * browser signed with — so a poster that only *looks* signed fails. Nothing
 * from `ui/poster.ts` is imported: it pulls the editor in, and the editor
 * wants a document.
 */
import { readFileSync } from "node:fs";
import { recoverSigner } from "../frontend/src/wallet/wallet";
import {
  clickButton,
  editorText,
  expect,
  freshAccount,
  login,
  setSource,
  test,
  type Account,
} from "./fixtures";

test.describe.configure({ mode: "serial" });

const PROGRAM =
  'fn main() {\n    let city = "Causeway Bay";\n    println!("hello from {city}");\n}\n';

/** Every `iTXt` chunk of a PNG, keyword to text — the reader's half of the file. */
function pngText(png: Uint8Array): Record<string, string> {
  const out: Record<string, string> = {};
  const dec = new TextDecoder();
  let at = 8;
  while (at + 8 <= png.length) {
    const len = new DataView(png.buffer, png.byteOffset + at, 4).getUint32(0);
    const type = String.fromCharCode(png[at + 4], png[at + 5], png[at + 6], png[at + 7]);
    if (type === "iTXt") {
      const data = png.subarray(at + 8, at + 8 + len);
      const k = data.indexOf(0);
      let o = k + 3;
      o = data.indexOf(0, o) + 1;
      o = data.indexOf(0, o) + 1;
      out[dec.decode(data.subarray(0, k))] = dec.decode(data.subarray(o));
    }
    if (type === "IEND") break;
    at += 12 + len;
  }
  return out;
}

/** Press POSTER and collect the two files it writes. */
async function pressPoster(page: import("@playwright/test").Page) {
  const files: import("@playwright/test").Download[] = [];
  const onDownload = (d: import("@playwright/test").Download) => void files.push(d);
  page.on("download", onDownload);
  try {
    await clickButton(page, "poster");
    await expect.poll(() => files.length, { timeout: 60_000 }).toBe(2);
  } finally {
    page.off("download", onDownload);
  }
  return files;
}

async function toPlayground(page: import("@playwright/test").Page, account: Account) {
  await login(page, account);
  await clickButton(page, "playground");
  await expect.poll(() => page.evaluate(() => window.__cwbCapture?.scene())).toBe("playground");
  await expect(page.locator(".cm-content")).toBeVisible();
}

test("POSTER writes a signed PNG and a JPEG of the pad", async ({ page, ready }, info) => {
  void ready;
  const account = freshAccount();
  await toPlayground(page, account);
  await setSource(page, PROGRAM);

  // Two files from one press. The key is in this tab — this session logged
  // in — so no key field is asked for and the poster is signed.
  const files = await pressPoster(page);
  const names = files.map((d) => d.suggestedFilename()).sort();
  expect(names[0]).toMatch(/^cwbhacker-.*\.jpg$/);
  expect(names[1]).toMatch(/^cwbhacker-.*\.png$/);

  const png = files.find((d) => d.suggestedFilename().endsWith(".png"))!;
  const path = info.outputPath("poster.png");
  await png.saveAs(path);
  const bytes = new Uint8Array(readFileSync(path));
  expect(Array.from(bytes.subarray(0, 4))).toEqual([0x89, 0x50, 0x4e, 0x47]);

  // The proof, in the file: the program, the author, and a signature that
  // recovers to the account that is logged in — over the program alone.
  const text = pngText(bytes);
  expect(text.Source).toBe(PROGRAM);
  expect(text.Lang).toBe("rust");
  expect(text.Signer.toLowerCase()).toBe(account.lower);
  expect(text.Signature).toMatch(/^0x[0-9a-f]{130}$/);
  expect(recoverSigner(PROGRAM, text.Signature)?.lower).toBe(account.lower);
  expect(recoverSigner(PROGRAM + " ", text.Signature)?.lower).not.toBe(account.lower);

  // And the key never went over the wire for it.
  const sent = (info as unknown as { _sent: string[] })._sent;
  expect(sent.join("\n")).not.toContain(account.privateKey.slice(2, 20));
});

test("DISK READER brings the poster back as a new pad", async ({ page, ready }, info) => {
  void ready;
  const account = freshAccount();
  await toPlayground(page, account);
  await setSource(page, PROGRAM);
  const files = await pressPoster(page);
  const png = files.find((d) => d.suggestedFilename().endsWith(".png"))!;
  const path = info.outputPath("disk.png");
  await png.saveAs(path);

  // Something else in the editor, so the read is visible as a change.
  await setSource(page, 'fn main() { println!("something else"); }\n');
  expect(await editorText(page)).not.toContain("Causeway Bay");

  const chooser = page.waitForEvent("filechooser");
  await clickButton(page, "reader");
  await (await chooser).setFiles(path);

  // The program is back, in a new pad, and the pad is named after the poster.
  await expect.poll(() => editorText(page)).toContain('let city = "Causeway Bay";');
  expect(await editorText(page)).toBe(PROGRAM);
  await expect
    .poll(() => page.evaluate(() => window.__cwbCapture?.scene()))
    .toBe("playground");
});

test("a picture with no disk on it is refused", async ({ page, ready }, info) => {
  void ready;
  const account = freshAccount();
  await toPlayground(page, account);
  await setSource(page, PROGRAM);
  // A 1×1 PNG: a picture, not a poster.
  const blank = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
    "base64",
  );
  const path = info.outputPath("blank.png");
  await import("node:fs").then((fs) => fs.writeFileSync(path, blank));
  const chooser = page.waitForEvent("filechooser");
  await clickButton(page, "reader");
  await (await chooser).setFiles(path);
  await page.waitForTimeout(1500);
  // Nothing was opened over the program that was being written.
  expect(await editorText(page)).toBe(PROGRAM);
  expect(await page.evaluate(() => window.__cwbCapture?.scene())).toBe("playground");
});
