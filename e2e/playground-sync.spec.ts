/**
 * The playground's draft, kept and shared.
 *
 *   * The draft is mirrored into `localStorage`, so it survives not only a
 *     reload but a closed tab — which is what an iPad does to a page it
 *     throws away in the background. A reload alone would pass with
 *     `sessionStorage` too, so the check here is a **new page in the same
 *     context**: same browser storage, a fresh session store.
 *   * A save on one device reaches the other (`playground.updated`, PROTOCOL
 *     §4.22). A clean pad takes it; a pad with unsaved typing asks — TAKE
 *     THEIRS or KEEP MINE — and nothing is saved from it until it is answered.
 *
 * Two browser contexts are two devices: separate storage, separate sockets,
 * one account. The account is a published fixture key typed into the login
 * card, so nothing here needs the CausewaybayWallet binary, and the suite can
 * run in CI (`make test-sync`, which starts its own server).
 */
import type { Browser, Page, ViewportSize } from "@playwright/test";
import {
  atScreen,
  clickButton,
  editorText,
  expect,
  fixtureAccount,
  sceneNow,
  setSource,
  test,
  type Account,
} from "./fixtures";

/** The project's orientation, for the extra contexts a test opens itself. */
type Viewport = ViewportSize | null;

// Index 3 of the fixture mnemonic: no other spec signs in as it.
const ACCOUNT = fixtureAccount(3);
const MIRROR = `cwbhacker.playground.${ACCOUNT.lower}`;

/** A marker per run, so a server that outlives one run cannot pass the next. */
const RUN = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;
const program = (what: string) =>
  `fn main() {\n    println!("${what} ${RUN}");\n}\n`;

/** A device: its own context (its own storage), on the playground, signed in. */
async function device(
  browser: Browser,
  baseURL: string,
  viewport: Viewport,
): Promise<Page> {
  const context = await browser.newContext({ baseURL, viewport });
  const page = await context.newPage();
  await openPlayground(page, ACCOUNT);
  return page;
}

/**
 * From a fresh page load to the playground. The session is kept per browser,
 * so a second page in the same context may resume straight onto the lands
 * screen; the login card is only filled when it is shown.
 */
async function openPlayground(
  page: Page,
  account: Account,
  editorShown = true,
): Promise<void> {
  await page.goto("/");
  await page.waitForFunction(
    () => typeof window.__cwbCapture?.settle === "function",
    null,
    {
      timeout: 30_000,
    },
  );
  await expect
    .poll(async () => sceneNow(page), {
      timeout: 90_000,
      message: "login or lands",
    })
    .toMatch(/^(login|lands)$/);
  if ((await sceneNow(page)) === "login") {
    const field = page.locator("textarea.cwb-field");
    await field.fill(account.privateKey);
    await field.press("ControlOrMeta+Enter");
  }
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await expect
    .poll(async () => sceneNow(page), { timeout: 30_000 })
    .toBe("playground");
  // Not when the screen opens on the conflict question, which puts the fields away.
  if (editorShown) await expect(page.locator(".cm-content")).toBeVisible();
}

/** Every button the scene would take a click on right now. */
async function buttonIds(page: Page): Promise<string[]> {
  return page.evaluate(() =>
    (window.__cwbCapture?.buttons() ?? []).map((b) => b.id),
  );
}

/** What this browser keeps for the account's open pad. */
async function mirror(page: Page, store: "localStorage" | "sessionStorage") {
  return page.evaluate(
    ([key, which]) => {
      const raw =
        window[which as "localStorage" | "sessionStorage"].getItem(key);
      return raw
        ? (JSON.parse(raw) as {
            id: string | null;
            source: string;
            dirty?: boolean;
          })
        : null;
    },
    [MIRROR, store] as const,
  );
}

/** Save now, with the player's own key, and wait until the pad has an id and is clean. */
async function saveNow(page: Page): Promise<string> {
  await page.locator(".cm-content").click();
  await page.keyboard.press("ControlOrMeta+S");
  await expect
    .poll(async () => {
      const m = await mirror(page, "localStorage");
      return m && m.id && m.dirty === false ? m.id : null;
    })
    .not.toBeNull();
  return (await mirror(page, "localStorage"))!.id!;
}

/**
 * Stop the clock on a page, so its autosave cannot fire. Events still arrive
 * (they are socket callbacks, not frames), which is exactly what the conflict
 * needs: unsaved typing here while a save lands from over there.
 */
async function freeze(page: Page): Promise<void> {
  // After a question is answered the editor comes back on the next frame;
  // stopping the clock before that frame would leave it put away.
  await expect(page.locator(".cm-content")).toBeVisible();
  await page.evaluate(() => window.__cwbCapture?.freeze());
}
async function resume(page: Page): Promise<void> {
  await page.evaluate(() => window.__cwbCapture?.resume());
}

test.describe.configure({ mode: "serial" });

test("an unsaved draft survives the tab being closed", async ({
  browser,
  baseURL,
  viewport,
  ready,
}) => {
  void ready;
  const context = await browser.newContext({ baseURL, viewport });
  const first = await context.newPage();
  await openPlayground(first, ACCOUNT);

  const draft = program("kept");
  await freeze(first); // no autosave: the draft must come back from the browser, not the server
  await setSource(first, draft);
  await expect
    .poll(async () => (await mirror(first, "localStorage"))?.source)
    .toBe(draft);
  const kept = await mirror(first, "localStorage");
  expect(kept?.dirty, "the mirror says the text never reached the server").toBe(
    true,
  );
  expect(
    await mirror(first, "sessionStorage"),
    "nothing is kept per tab any more",
  ).toBeNull();
  await first.close();

  // A new tab: the same browser storage, an empty session store.
  const second = await context.newPage();
  await openPlayground(second, ACCOUNT);
  await expect.poll(async () => editorText(second)).toContain(`kept ${RUN}`);

  // And a reload of that tab, for good measure.
  await second.reload();
  await openPlayground(second, ACCOUNT);
  await expect.poll(async () => editorText(second)).toContain(`kept ${RUN}`);
  await context.close();
});

test("a save on one device reaches the other, and a dirty pad asks which to keep", async ({
  browser,
  baseURL,
  viewport,
  ready,
}) => {
  void ready;
  const url = baseURL ?? "http://127.0.0.1:5390";
  const laptop = await device(browser, url, viewport);
  const ipad = await device(browser, url, viewport);

  // The laptop saves a pad; the iPad opens it from the list.
  await setSource(laptop, program("laptop one"));
  const id = await saveNow(laptop);
  await expect
    .poll(async () => buttonIds(ipad), { timeout: 30_000 })
    .toContain(`snip:${id}`);
  await clickButton(ipad, `snip:${id}`);
  await expect
    .poll(async () => editorText(ipad))
    .toContain(`laptop one ${RUN}`);

  // 1. Clean on the iPad: the laptop's next save simply arrives.
  await setSource(laptop, program("laptop two"));
  await saveNow(laptop);
  await expect
    .poll(async () => editorText(ipad))
    .toContain(`laptop two ${RUN}`);
  expect(await buttonIds(ipad)).not.toContain("conflict-theirs");

  // 2. Dirty on the iPad, the laptop saves: the iPad asks. TAKE THEIRS.
  await freeze(ipad);
  await setSource(ipad, program("ipad draft"));
  await setSource(laptop, program("laptop three"));
  await saveNow(laptop);
  await resume(ipad);
  await expect
    .poll(async () => buttonIds(ipad), { timeout: 30_000 })
    .toContain("conflict-theirs");
  // Modal: the two answers are the only buttons on the bench.
  const bench = await buttonIds(ipad);
  expect(bench).toContain("conflict-mine");
  expect(bench).not.toContain("save");
  expect(bench).not.toContain("run");
  // The question holds: the iPad's text is still its own and nothing was saved over the laptop's.
  expect(await editorText(ipad)).toContain(`ipad draft ${RUN}`);
  await ipad.waitForTimeout(3_500); // longer than the 2.5 s autosave
  expect(await editorText(laptop)).toContain(`laptop three ${RUN}`);
  await clickButton(ipad, "conflict-theirs");
  await expect
    .poll(async () => editorText(ipad))
    .toContain(`laptop three ${RUN}`);
  expect(await editorText(ipad)).not.toContain("ipad draft");
  await expect
    .poll(async () => (await mirror(ipad, "localStorage"))?.dirty)
    .toBe(false);

  // 3. Again, and this time KEEP MINE: the iPad's text is saved and reaches the laptop.
  await freeze(ipad);
  await setSource(ipad, program("ipad wins"));
  await setSource(laptop, program("laptop four"));
  await saveNow(laptop);
  await resume(ipad);
  await expect
    .poll(async () => buttonIds(ipad), { timeout: 30_000 })
    .toContain("conflict-mine");
  await clickButton(ipad, "conflict-mine");
  await expect
    .poll(async () => editorText(laptop), { timeout: 30_000 })
    .toContain(`ipad wins ${RUN}`);
  expect(await editorText(ipad)).toContain(`ipad wins ${RUN}`);
  await expect
    .poll(async () => (await mirror(ipad, "localStorage"))?.dirty)
    .toBe(false);

  await laptop.context().close();
  await ipad.context().close();
});

test("a draft left dirty while the other device saved asks on the way back in", async ({
  browser,
  baseURL,
  viewport,
  ready,
}) => {
  void ready;
  const url = baseURL ?? "http://127.0.0.1:5390";
  const laptop = await device(browser, url, viewport);
  const ipadContext = await browser.newContext({ baseURL: url, viewport });
  let ipad = await ipadContext.newPage();
  await openPlayground(ipad, ACCOUNT);

  await setSource(laptop, program("before"));
  const id = await saveNow(laptop);
  await expect
    .poll(async () => buttonIds(ipad), { timeout: 30_000 })
    .toContain(`snip:${id}`);
  await clickButton(ipad, `snip:${id}`);
  await expect.poll(async () => editorText(ipad)).toContain(`before ${RUN}`);

  // The iPad types and is closed before it saves; the laptop saves meanwhile.
  await freeze(ipad);
  await setSource(ipad, program("offline edit"));
  await expect
    .poll(async () => (await mirror(ipad, "localStorage"))?.dirty)
    .toBe(true);
  await ipad.close();
  await setSource(laptop, program("while you were away"));
  await saveNow(laptop);

  // Back on the iPad: the draft is there, and so is the question.
  ipad = await ipadContext.newPage();
  await openPlayground(ipad, ACCOUNT, false);
  await expect
    .poll(async () => buttonIds(ipad), { timeout: 30_000 })
    .toContain("conflict-theirs");
  expect(await editorText(ipad)).toContain(`offline edit ${RUN}`);
  await expect(
    ipad.locator(".cm-content"),
    "the question puts the editor away",
  ).toBeHidden();
  await clickButton(ipad, "conflict-theirs");
  await expect
    .poll(async () => editorText(ipad))
    .toContain(`while you were away ${RUN}`);
  await expect(ipad.locator(".cm-content")).toBeVisible();

  await laptop.context().close();
  await ipadContext.close();
});
