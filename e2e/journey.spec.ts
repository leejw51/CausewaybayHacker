import {
  atScreen,
  expect,
  state,
  test,
  testAccount,
  view,
  type View,
} from "./fixtures.js";

/**
 * Milestone 1, end to end, in a real browser.
 *
 *   login with a mnemonic → RUST land → BASIC → map → quest
 *   → submit a wrong answer → submit the right one → CLEARED stamp
 *   → reload → still cleared
 *
 * This is the only suite that can catch the seam. `cargo test` proves the
 * server's rules, `vitest` proves the scenes, and neither of them notices a
 * websocket frame the client does not handle, a `progress.update` that never
 * arrives, or a map that redraws itself from a stale local copy after a
 * reload. PLAN.md's definition of done for M1 is almost exactly this test.
 *
 * It runs twice, once per orientation (see `playwright.config.ts`). Both are
 * first-class on every screen per SPEC §10, so the journey is the assertion,
 * not a separate "does it look right in portrait" test.
 *
 * ## Current status: red, and honestly so
 *
 * Nothing below has ever passed. The frontend (:5291) and the backend (:5390)
 * are being written in parallel with this file. Each test skips with a reason
 * naming exactly what has to exist — see `e2e/README.md` for the checklist and
 * `docs/decisions.md` for the hook contract FE is being asked for.
 */

const RUST_BASIC_FIRST = "rust.basic.01.hello";

// SPEC §12's worked example is this quest, so its answer is knowable from the
// spec alone rather than from content that PM is still writing.
const WRONG = `fn main() {
    println!("Hello, Causewaybay!");
}
`;
const RIGHT = `fn main() {
    println!("hello, causewaybay");
}
`;

async function login(page: import("@playwright/test").Page) {
  const account = testAccount(0);
  await atScreen(page, "login");
  await page.evaluate((secret) => window.__cwb!.login(secret), account.phrase);
  return account;
}

/** The map node this journey is about, whatever order the map draws them in. */
function node(v: View, questId = RUST_BASIC_FIRST) {
  const n = v.nodes?.find((x) => x.quest_id === questId);
  if (!n) throw new Error(`no node ${questId} in ${JSON.stringify(v.nodes)}`);
  return n;
}

test.describe.configure({ mode: "serial" });

test("boots to the login screen and asks for a mnemonic", async ({ page }) => {
  await atScreen(page, "login");
  const v = await view(page);
  expect(v.address).toBeNull();
  // SPEC §3.1: the key never leaves the browser. Before login there is no
  // identity on the client either — the screen is a prompt, not a session.
  expect(v.address_eip55).toBeNull();
  expect((test.info() as unknown as { _errors: string[] })._errors).toEqual([]);
});

test("a mnemonic logs in, and the address is the one the wallet derives", async ({
  page,
}) => {
  const account = await login(page);
  await atScreen(page, "lands");
  const v = await view(page);
  // The whole of SPEC §9.1, observed from outside: this is the address
  // `CausewaybayWallet` produces for this phrase, and it is what the server
  // now has a row for. If this line ever fails, users have lost accounts.
  expect(v.address).toBe(account.lower);
  expect(v.address_eip55).toBe(account.address);
});

test("the mnemonic never crosses the wire", async ({ page }) => {
  // SPEC §3.1 in the only place it can actually be checked: the socket.
  // Not a convenience, not negotiable, and not something a unit test on
  // either side can see on its own.
  const account = testAccount(0);
  const sent: string[] = [];
  page.on("websocket", (ws) =>
    ws.on("framesent", (f) => sent.push(String(f.payload))),
  );

  await atScreen(page, "login");
  await page.evaluate((secret) => window.__cwb!.login(secret), account.phrase);
  await atScreen(page, "lands");

  const traffic = sent.join("\n");
  expect(traffic).not.toContain("abandon");
  expect(traffic).not.toContain(account.phrase);
  // Nor the key it derives to.
  for (const frame of sent) expect(frame).not.toMatch(/"(mnemonic|private_key|seed)"/);
  // Storage is checked too: §3.1 says not in localStorage unencrypted either.
  const stored = await page.evaluate(() => JSON.stringify(window.localStorage));
  expect(stored).not.toContain("abandon");
});

test("RUST → BASIC → a map with an open first node", async ({ page }) => {
  await login(page);
  await atScreen(page, "lands");
  await page.keyboard.press("Enter"); // rust is the first land
  await atScreen(page, "categories");
  await page.keyboard.press("Enter"); // basic is the first category
  await atScreen(page, "map");

  const v = await view(page);
  expect(v.land).toBe("rust");
  expect(v.category).toBe("basic");
  expect(v.nodes?.length).toBeGreaterThanOrEqual(3); // PLAN.md: three quests in M1
  // SPEC §12: `requires` empty means open from the start. Node 1 has none.
  expect(node(v).state).toBe("open");
  expect(node(v).stars).toBe(0);
  // And the rest of the map is not given away.
  const later = v.nodes!.filter((n) => n.node > 1);
  expect(later.every((n) => n.state === "locked")).toBe(true);
});

test("a wrong answer is rejected, and the node stays open", async ({ page }) => {
  await login(page);
  await page.keyboard.press("Enter");
  await page.keyboard.press("Enter");
  await atScreen(page, "map");
  await page.keyboard.press("Enter"); // open node 1
  await atScreen(page, "quest");

  const before = await view(page);
  expect(before.quest?.quest_id).toBe(RUST_BASIC_FIRST);
  // SPEC §12: the editor opens with the quest's `starter`, which must not
  // itself pass (§9.5) — so what is in the box right now is not the answer.
  expect(before.quest?.source.length).toBeGreaterThan(0);

  await page.evaluate((s) => window.__cwb!.setSource(s), WRONG);
  await page.evaluate(() => window.__cwb!.submit());
  await atScreen(page, "result", 120_000); // first rustc of the session is slow

  const v = await view(page);
  expect(v.attempt?.verdict).toBe("wrong_answer");
  expect(v.attempt?.cleared).toBe(false);
  expect(v.attempt?.tests_passed).toBeLessThan(v.attempt!.tests_total);
  // SPEC §5.2: the visible case shows its expected output, so the player is
  // never guessing blind. A hidden one would not.
  expect(v.attempt?.tests_total).toBeGreaterThan(0);
});

test("the right answer clears it, stamps it, and it survives a reload", async ({
  page,
}) => {
  await login(page);
  await page.keyboard.press("Enter");
  await page.keyboard.press("Enter");
  await atScreen(page, "map");
  await page.keyboard.press("Enter");
  await atScreen(page, "quest");

  await page.evaluate((s) => window.__cwb!.setSource(s), RIGHT);
  await page.evaluate(() => window.__cwb!.submit());
  await atScreen(page, "result", 120_000);

  const v = await view(page);
  expect(v.attempt?.verdict).toBe("accepted");
  expect(v.attempt?.cleared).toBe(true);
  expect(v.attempt?.tests_passed).toBe(v.attempt!.tests_total);
  // SPEC §6.3: three stars only with no failed attempt and no hint. The
  // wrong answer above was this account's first go at this quest, so this is
  // at most two — and asserting that is what proves the star rule is the
  // server's and not a constant the frontend prints.
  expect(v.attempt?.stars).toBeGreaterThanOrEqual(1);
  expect(v.attempt?.stars).toBeLessThanOrEqual(2);

  // Back to the map: the stamp.
  await page.keyboard.press("Enter");
  await atScreen(page, "map");
  expect(node(await view(page)).state).toBe("cleared");
  // And the next node is no longer locked (SPEC §12: `requires` satisfied).
  const after = await view(page);
  const second = after.nodes!.find((n) => n.node === 2);
  if (second) expect(second.state).toBe("open");

  // The whole point of a server-owned world (PLAN.md's M1 done-ness): a
  // reload keeps nothing and loses nothing.
  await page.reload();
  await page.waitForFunction(() => typeof window.__cwb?.view === "function");
  // SPEC §3.3: `auth.resume` trades the stored token for a live connection
  // without touching key material — so the reload does NOT ask for the
  // mnemonic again.
  await atScreen(page, "lands", 60_000);
  await page.keyboard.press("Enter");
  await page.keyboard.press("Enter");
  await atScreen(page, "map");
  expect(node(await view(page)).state).toBe("cleared");
});

test("the CLEARED stamp is on screen in this orientation", async ({ page }, info) => {
  // The view model can say `cleared` while the sprite is drawn off the
  // canvas in portrait. A screenshot is the only witness for that, and a
  // human has to look at it — so this test asserts the cheap half (the
  // viewport is the one the project asked for, the canvas fills it) and
  // attaches the picture for the other half.
  await login(page);
  await page.keyboard.press("Enter");
  await page.keyboard.press("Enter");
  await atScreen(page, "map");

  const size = page.viewportSize()!;
  const box = await page.locator("canvas").first().boundingBox();
  expect(box, "the map draws on a canvas").not.toBeNull();
  // The lifted `layout.ts` grows the canvas along the long axis rather than
  // letterboxing, so it should be within a hair of the viewport, not a
  // 4:3 box sitting in the middle of a phone-shaped window.
  expect(box!.width).toBeGreaterThan(size.width * 0.9);
  expect(box!.height).toBeGreaterThan(size.height * 0.9);
  await info.attach(`map-${info.project.name}.png`, {
    body: await page.screenshot(),
    contentType: "image/png",
  });
});
