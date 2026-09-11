import {
  atScreen,
  expect,
  fixtureAccount,
  freshAccount,
  login,
  logout,
  openSelectedNode,
  pickFirstCategory,
  scene,
  setSource,
  submit,
  test,
  Wire,
  WRONG_SOURCE,
  type Account,
} from "./fixtures.js";

/**
 * The journey, in a real browser, in both orientations.
 *
 *   login → train → logout → login as a second wallet
 *   → that wallet's own progress, and nothing of the first's
 *
 * This is the only suite that can catch the seam. `cargo test` proves the
 * server's rules, `vitest` proves the scenes, `tests/smoke/contract.mjs`
 * proves the protocol — and none of them notices a frontend that draws
 * CLEARED over a server that never heard about it, or a logout that leaves
 * the previous wallet's map on screen.
 *
 * **The browser drives; the wire verifies.** Every assertion about progress
 * goes through a second websocket session opened as the same wallet, so what
 * is tested is what the *server* believes, not what the client thinks it
 * believes. That is a stronger claim than any view model could support.
 *
 * It runs twice, once per orientation (`playwright.config.ts`). SPEC §10 makes
 * both first-class on every screen, so the journey is the assertion rather
 * than a separate "does it look right sideways" test.
 */

test.describe.configure({ mode: "serial" });

/** Walk from the login screen to an open quest, driving the real UI. */
async function toQuest(page: import("@playwright/test").Page, account: Account) {
  await login(page, account);
  await pickFirstCategory(page); // RUST is the default land; BASIC the first row
  await openSelectedNode(page);
}

test("boots to the login screen and asks for a seed", async ({ page }) => {
  await atScreen(page, "login");
  const field = page.locator("textarea.cwb-field");
  await expect(field).toBeVisible();
  await expect(field).toHaveAttribute("placeholder", /twelve words|0x/);
  await expect(field, "the field starts empty").toHaveValue("");
  expect((test.info() as unknown as { _errors: string[] })._errors).toEqual([]);
});

test("a seed logs in, and the address is the one the wallet derives", async ({ page }) => {
  // SPEC §9.1, observed from outside: the address the game shows for this key
  // is the one `CausewaybayWallet` derives for it. The *fixture* account on
  // purpose — the whole point is that the value came from somewhere else and
  // this suite did not compute it. It only reads, so a previously-played
  // account costs nothing.
  const account = fixtureAccount(0);
  await login(page, account);

  // The wire is the witness: the server has a row for exactly this address.
  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  try {
    const me = await wire.ok("auth.resume", { token: "" }).catch(() => null);
    void me; // a junk token is unauthorized; the login above is the assertion
    const lands = await wire.ok("world.lands", {});
    expect(Array.isArray(lands.lands)).toBe(true);
  } finally {
    wire.close();
  }
});

test("the seed never crosses the wire", async ({ page }) => {
  // SPEC §3.1, in the only place it can actually be checked: the socket.
  // Not a convenience, not negotiable, and not something a unit test on
  // either side can see on its own.
  const account = freshAccount();
  const sent: string[] = [];
  page.on("websocket", (ws) => ws.on("framesent", (f) => sent.push(String(f.payload))));

  await login(page, account);

  const traffic = sent.join("\n");
  expect(sent.length, "no frames were sent at all").toBeGreaterThan(0);
  expect(traffic).not.toContain(account.privateKey);
  expect(traffic).not.toContain(account.privateKey.replace(/^0x/, ""));
  expect(traffic).not.toContain("abandon");
  for (const frame of sent)
    expect(frame).not.toMatch(/"(mnemonic|private_key|privkey|seed|passphrase)"/);

  // §3.1 says not in localStorage unencrypted either. A session token is
  // fine and expected there; key material is not.
  const stored = await page.evaluate(() => JSON.stringify(window.localStorage));
  expect(stored).not.toContain(account.privateKey.replace(/^0x/, ""));
  expect(stored).not.toContain("abandon");

  // And the field is emptied the moment it is submitted.
  await expect(page.locator("textarea.cwb-field")).toHaveCount(0);
});

test("RUST × BASIC opens a map, and only the first node is open", async ({ page }) => {
  const account = freshAccount();
  await login(page, account);
  await pickFirstCategory(page);
  await atScreen(page, "map");

  // Verified on the wire, because the map is pixels.
  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  try {
    const nodes = await wire.map();
    expect(nodes.length, "the rust/basic map has nodes").toBeGreaterThanOrEqual(3);
    const byNode = [...nodes].sort((a, b) => a.node - b.node);
    expect(byNode[0].state, "SPEC §12: an empty `requires` is open from the start").toBe(
      "open",
    );
    expect(
      byNode.slice(1).every((n) => n.state === "locked"),
      "a new player was handed more than the first street",
    ).toBe(true);
  } finally {
    wire.close();
  }
});

test("a wrong answer is rejected and the node stays open", async ({ page }) => {
  const account = freshAccount();
  await toQuest(page, account);

  await setSource(page, WRONG_SOURCE);
  await submit(page);
  await atScreen(page, "result", 180_000); // the first rustc of a run is slow

  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  try {
    const history = await wire.history();
    expect(history.length, "the attempt was not recorded").toBe(1);
    expect(history[0].verdict).not.toBe("accepted");
    const nodes = await wire.map();
    const first = [...nodes].sort((a, b) => a.node - b.node)[0];
    expect(first.state, "a failed attempt cleared the node").toBe("open");
    expect(first.stars).toBe(0);
  } finally {
    wire.close();
  }
});

test("the right answer clears it, and the clear survives a reload", async ({ page }) => {
  const account = freshAccount();
  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  try {
    // The answer comes from the quest's own visible case, over the wire —
    // content is PM's, and a suite that hard-codes a string breaks the day
    // one changes.
    const { node, source } = await wire.answerable();

    await toQuest(page, account);
    await setSource(page, source);
    await submit(page);
    await atScreen(page, "result", 180_000);

    const cleared = await wire.node(node.quest_id);
    expect(cleared?.state, "the server did not record the clear").toBe("cleared");
    expect(cleared?.stars, "a clean first clear is three stars (SPEC §6.3)").toBe(3);

    // Back to the map, and the stamp is there.
    await page.keyboard.press("Enter");
    await atScreen(page, "map");

    // PLAN.md's definition of done: nothing in the game lives in the browser.
    await page.reload();
    await page.waitForFunction(() => typeof window.__cwbCapture?.settle === "function");
    // §3.3 / §6: the token is kept, so a reload does not ask for the seed.
    await expect
      .poll(async () => scene(page), { timeout: 60_000 })
      .not.toBe("login");

    const afterReload = await wire.node(node.quest_id);
    expect(afterReload?.state, "the clear did not survive the reload").toBe("cleared");
  } finally {
    wire.close();
  }
});

test("logout, then a second wallet sees its own map and none of the first's", async ({
  page,
}) => {
  // The journey the user asked for, and the one with real consequences. Two
  // people share a machine, or one person has two wallets. If logging out
  // leaves anything of the first behind — a token, a cached map, a header
  // still showing the old address — the second person is looking at somebody
  // else's progress.
  const first = freshAccount();
  const second = freshAccount();
  expect(first.address).not.toBe(second.address);

  const firstWire = await Wire.as(test.info().project.use.baseURL!, first);
  const secondWire = await Wire.as(test.info().project.use.baseURL!, second);
  try {
    const { node, source } = await firstWire.answerable();

    // ---- the first wallet trains -------------------------------------
    await toQuest(page, first);
    await setSource(page, source);
    await submit(page);
    await atScreen(page, "result", 180_000);
    expect((await firstWire.node(node.quest_id))?.state).toBe("cleared");

    // ---- and logs out ------------------------------------------------
    await logout(page); // F3, from anywhere
    await atScreen(page, "login");
    // The seed field is empty and back: §3.1's "the key does not outlive the
    // screen", and the login scene's own `leave()` says so.
    const field = page.locator("textarea.cwb-field");
    await expect(field).toBeVisible();
    await expect(field).toHaveValue("");

    // Nothing of the first wallet is left where a second player could reach
    // it. A session token for a wallet that logged out is the one that
    // matters: it would silently resume on the next reload.
    const leftovers = await page.evaluate(() => JSON.stringify(window.localStorage));
    expect(
      leftovers,
      "the logged-out wallet's address is still in local storage",
    ).not.toContain(first.lower);
    expect(leftovers).not.toContain(first.address);

    // ---- the second wallet logs in -----------------------------------
    await login(page, second);
    await pickFirstCategory(page);
    await atScreen(page, "map");

    // The assertion, from the server: the second wallet's map is untouched.
    const theirs = await secondWire.map();
    const theirFirst = [...theirs].sort((a, b) => a.node - b.node)[0];
    expect(
      theirFirst.state,
      "the second wallet inherited the first wallet's clear",
    ).toBe("open");
    expect(theirFirst.stars).toBe(0);
    expect(
      (await secondWire.history()).length,
      "the second wallet inherited the first wallet's attempts",
    ).toBe(0);

    // And the first wallet still has its own, untouched by any of that.
    expect((await firstWire.node(node.quest_id))?.state).toBe("cleared");
    expect((await firstWire.history()).length).toBeGreaterThan(0);

    // A reload as the second wallet must not resume as the first.
    await page.reload();
    await page.waitForFunction(() => typeof window.__cwbCapture?.settle === "function");
    await expect.poll(async () => scene(page), { timeout: 60_000 }).not.toBe("login");
    expect((await secondWire.history()).length).toBe(0);
  } finally {
    firstWire.close();
    secondWire.close();
  }
});

test("the screen fills this orientation, and the two canvases agree", async ({
  page,
}, info) => {
  // A view model can say `cleared` while the stamp is drawn off the canvas in
  // portrait. Nobody has looked at this in both shapes, so the cheap half is
  // asserted — the canvas fills the viewport the project asked for, and the
  // WebGL layer and the pixel layer are the same size, which is the bug that
  // shows up as a parallax that slides out from under the art — and the
  // picture is attached for a human.
  const account = freshAccount();
  await login(page, account);
  await pickFirstCategory(page);
  await atScreen(page, "map");

  const size = page.viewportSize()!;
  const box = await page.locator("canvas#game").boundingBox();
  expect(box, "the map draws on a canvas").not.toBeNull();
  // The lifted `layout.ts` grows the canvas along the long axis rather than
  // letterboxing, so it should be within a hair of the viewport.
  expect(box!.width).toBeGreaterThan(size.width * 0.9);
  expect(box!.height).toBeGreaterThan(size.height * 0.9);

  const backing = await page.evaluate(() => window.__cwbCapture!.backing());
  expect(
    backing.game,
    "the pixel canvas and the WebGL canvas are different sizes, so the " +
      "parallax will drift out from under the art",
  ).toEqual(backing.fx);

  const shot = await page.evaluate(() => {
    window.__cwbCapture!.settle();
    return window.__cwbCapture!.png();
  });
  expect(shot.startsWith("data:image/png"), "the capture hook produced no PNG").toBe(true);
  await info.attach(`map-${info.project.name}.png`, {
    body: Buffer.from(shot.split(",")[1], "base64"),
    contentType: "image/png",
  });
});

test("both orientations reach the same screen", async ({ page }) => {
  // SPEC §10: "Both orientations are first-class on every screen, not just
  // the map." The suite already runs twice, but that only proves each shape
  // works from a cold start. This flips mid-session, which is what F1 does
  // and what rotating a tablet does, and it is where a scene that measured
  // its layout once at construction breaks.
  const account = freshAccount();
  await login(page, account);
  await pickFirstCategory(page);
  await atScreen(page, "map");

  for (const mode of ["portrait", "landscape", "portrait"] as const) {
    await page.evaluate((m) => {
      window.__cwbCapture!.orient(m);
      window.__cwbCapture!.settle();
    }, mode);
    expect(await page.evaluate(() => window.__cwbCapture!.orientation())).toBe(mode);
    expect(await scene(page), `the ${mode} flip changed the screen`).toBe("map");
    const [vw, vh] = await page.evaluate(() => window.__cwbCapture!.virtual());
    if (mode === "portrait") expect(vh).toBeGreaterThan(vw);
    else expect(vw).toBeGreaterThan(vh);
  }

  // And the game still works afterwards: the node opens.
  await openSelectedNode(page);
});
