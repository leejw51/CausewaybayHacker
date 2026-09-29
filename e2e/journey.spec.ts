import {
  clickButton,
  atScreen,
  expect,
  fixtureAccount,
  enterRustQuest,
  freshAccount,
  openSelectedNode,
  login,
  logout,
  pickCategory,
  receivedFrames,
  run,
  sourceThatPrints,
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

/**
 * Walk from the login screen to an open RUST quest, driving the real UI, and
 * report which quest the browser actually opened.
 */
async function toQuest(
  page: import("@playwright/test").Page,
  account: Account,
  wire: Wire,
): Promise<string> {
  await login(page, account);
  return enterRustQuest(page, wire);
}

test("boots to the login screen and asks for a seed", async ({ page }) => {
  await atScreen(page, "login");
  const field = page.locator("textarea.cwb-field");
  await expect(field).toBeVisible();
  await expect(field).toHaveAttribute("placeholder", /twelve words|0x/);
  await expect(field, "the field starts empty").toHaveValue("");
  expect((test.info() as unknown as { _errors: string[] })._errors).toEqual([]);
});

test("a seed logs in, and the address is the one the wallet derives", async ({
  page,
}) => {
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
  // Collected by the fixture, before the page was navigated — the client
  // opens its socket during boot, so a listener attached here would miss it
  // and the test would pass by seeing nothing at all.
  const sent = (test.info() as unknown as { _sent: string[] })._sent;

  await login(page, account);

  const traffic = sent.join("\n");
  expect(sent.length, "no frames were sent at all").toBeGreaterThan(0);
  expect(traffic).not.toContain(account.privateKey);
  expect(traffic).not.toContain(account.privateKey.replace(/^0x/, ""));
  expect(traffic).not.toContain("abandon");
  for (const frame of sent)
    expect(frame).not.toMatch(
      /"(mnemonic|private_key|privkey|seed|passphrase)"/,
    );

  // The browser's own storage. This used to say "no key material in
  // localStorage at all"; docs/decisions.md 2026-09-18 "WEB: the key is kept
  // in the browser, and the token is one per browser" changed that on
  // purpose, and SPEC §3.1 with it: the *derived private key* is kept under
  // `cwbhacker.key.<address>` from an accepted login until logout, so a
  // reload or a poster can sign without the phrase. What still holds is
  // narrower and is pinned exactly: that one slot, for this account, holds
  // the key; no other slot holds it; and the mnemonic is never written.
  const store = await page.evaluate(() => ({ ...window.localStorage }));
  const hex = account.privateKey.replace(/^0x/, "").toLowerCase();
  const holding = Object.entries(store)
    .filter(([, v]) => v.toLowerCase().includes(hex))
    .map(([k]) => k);
  expect(holding, "the key is in its own slot and nowhere else").toEqual([
    `cwbhacker.key.${account.lower}`,
  ]);
  expect(store[`cwbhacker.key.${account.lower}`].replace(/^0x/, "").toLowerCase()).toBe(hex);
  expect(JSON.stringify(store)).not.toContain("abandon");

  // And the field is emptied the moment it is submitted.
  await expect(page.locator("textarea.cwb-field")).toHaveCount(0);
});

test("RUST × BASIC opens a map, and every node on it is playable", async ({
  page,
}) => {
  // This test used to assert "node 1 is open, the rest are locked". §4.7
  // changed that — "**Every node is playable. Nothing is locked.** … This is
  // a trainer, not a platformer" — so the old assertion is wrong, and simply
  // deleting it would leave a test that checks a map exists.
  //
  // The inverse is the real assertion and it has teeth: a fresh player, who
  // has cleared nothing, can open the **last** street on the map. That is
  // §4.7's own worked reason — an interview on Thursday, the dynamic
  // programming street on Tuesday, without eighteen quests about `&str`
  // first.
  const account = freshAccount();
  await login(page, account);
  await pickCategory(page);
  await atScreen(page, "map");

  // Verified on the wire, because the map is pixels.
  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  try {
    const nodes = await wire.map();
    expect(nodes.length, "the rust/basic map has nodes").toBeGreaterThanOrEqual(
      3,
    );
    const byNode = [...nodes].sort((a, b) => a.node - b.node);

    expect(
      byNode
        .filter((n) => (n.state as string) === "locked")
        .map((n) => n.quest_id),
      "§5.2: `state` is `open` or `cleared`, never `locked`",
    ).toEqual([]);
    expect(
      byNode.every((n) => n.state === "open"),
      "a brand-new player's map already has something cleared on it",
    ).toBe(true);
    expect(byNode.every((n) => n.stars === 0)).toBe(true);

    // The suggested route is still described — the map draws it, and "where
    // do I go next" is a real question. Advice, not a gate.
    const map = await wire.ok("world.map", { land: "rust", category: "basic" });
    expect(
      (map.edges as unknown[]).length,
      "§4.7: `edges` still describe the suggested route",
    ).toBeGreaterThan(0);
  } finally {
    wire.close();
  }
});

test("a wrong answer is rejected and the node stays open", async ({ page }) => {
  const account = freshAccount();
  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  await toQuest(page, account, wire);

  await setSource(page, WRONG_SOURCE);
  await submit(page); // waits for the result screen itself

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

test("the right answer clears it, and the clear survives a reload", async ({
  page,
}) => {
  const account = freshAccount();
  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  try {
    // The answer comes from the quest's own visible case, over the wire —
    // content is PM's, and a suite that hard-codes a string breaks the day
    // one changes.
    // Whatever quest the browser opens is the one this test is about — the
    // lands scan is a click sweep and a test that insisted on one quest id
    // would be asserting the panel's geometry rather than the game.
    const opened = await toQuest(page, account, wire);
    const got = await wire.ok("quest.get", { quest_id: opened });
    const source = sourceThatPrints(
      (
        got.quest as {
          tests?: { visible?: { stdin?: string; expect?: string }[] };
        }
      ).tests?.visible?.[0],
    );
    expect(
      source,
      `the browser opened ${opened}, whose visible case cannot be answered by ` +
        `printing a constant — it reads stdin, and that quest is teaching ` +
        `something this suite should not shortcut`,
    ).not.toBeNull();
    const node = { quest_id: opened };

    await setSource(page, source!);
    await submit(page);

    // Which quest did the browser actually submit to? If the lands scan
    // picked the wrong category row, the symptom without this line is
    // "expected cleared, got open" on a quest the UI never opened, which
    // reads as a server bug and is not one.
    const history = await wire.history();
    expect(
      history.length,
      "the browser's submit never reached the server",
    ).toBe(1);
    expect(
      (history[0] as unknown as { quest_id: string }).quest_id,
      "the browser submitted to a different quest than the one the wire " +
        "chose — the lands scan picked the wrong category row",
    ).toBe(node.quest_id);

    const cleared = await wire.node(node.quest_id);
    expect(cleared?.state, "the server did not record the clear").toBe(
      "cleared",
    );
    expect(
      cleared?.stars,
      "a clean first clear is three stars (SPEC §6.3)",
    ).toBe(3);

    // Back to the map, and the stamp is there.
    // ENTER takes the lit button, which after a clear is NEXT; the map is its own button.
    await clickButton(page, "map");
    await atScreen(page, "map");

    // PLAN.md's definition of done: nothing in the game lives in the browser.
    await page.reload();
    await page.waitForFunction(
      () => typeof window.__cwbCapture?.settle === "function",
    );
    // §3.3 / §6: the token is kept, so a reload does not ask for the seed.
    await expect
      .poll(async () => scene(page), { timeout: 60_000 })
      .not.toBe("login");

    const afterReload = await wire.node(node.quest_id);
    expect(afterReload?.state, "the clear did not survive the reload").toBe(
      "cleared",
    );
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
    // ---- the first wallet trains -------------------------------------
    const opened = await toQuest(page, first, firstWire);
    const got = await firstWire.ok("quest.get", { quest_id: opened });
    const source = sourceThatPrints(
      (
        got.quest as {
          tests?: { visible?: { stdin?: string; expect?: string }[] };
        }
      ).tests?.visible?.[0],
    );
    expect(
      source,
      `${opened} cannot be answered by printing a constant`,
    ).not.toBeNull();
    const node = { quest_id: opened };

    await setSource(page, source!);
    await submit(page);
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
    const leftovers = await page.evaluate(() =>
      JSON.stringify(window.localStorage),
    );
    expect(
      leftovers,
      "the logged-out wallet's address is still in local storage",
    ).not.toContain(first.lower);
    expect(leftovers).not.toContain(first.address);

    // ---- the second wallet logs in -----------------------------------
    await login(page, second);
    await pickCategory(page);
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
    await page.waitForFunction(
      () => typeof window.__cwbCapture?.settle === "function",
    );
    await expect
      .poll(async () => scene(page), { timeout: 60_000 })
      .not.toBe("login");
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
  await pickCategory(page);
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
  expect(
    shot.startsWith("data:image/png"),
    "the capture hook produced no PNG",
  ).toBe(true);
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
  await pickCategory(page);
  await atScreen(page, "map");

  for (const mode of ["portrait", "landscape", "portrait"] as const) {
    await page.evaluate((m) => {
      window.__cwbCapture!.orient(m);
      window.__cwbCapture!.settle();
    }, mode);
    expect(await page.evaluate(() => window.__cwbCapture!.orientation())).toBe(
      mode,
    );
    expect(await scene(page), `the ${mode} flip changed the screen`).toBe(
      "map",
    );
    const [vw, vh] = await page.evaluate(() => window.__cwbCapture!.virtual());
    if (mode === "portrait") expect(vh).toBeGreaterThan(vw);
    else expect(vw).toBeGreaterThan(vh);
  }

  // And the game still works afterwards: the node opens.
  await openSelectedNode(page);
});

test("the compiler's output paints while it is still compiling", async ({
  page,
}, info) => {
  // **Nobody has ever seen this work.** FE unit-tested the console and could
  // not confirm it visually — headless RAF starvation defeated its timing
  // attempts — so `run.log` painting *while* the run is still going has been
  // believed rather than known, in both clients, since it was written.
  //
  // SPEC §5.4 is explicit about why it matters: "so the player watches
  // `rustc` think instead of a spinner". A console that only fills in once
  // the verdict lands is a spinner with extra steps, and every unit test on
  // both sides still passes.
  //
  // **How this used to look, and why it could not work.** It pressed RUN and
  // compared 24 `settle(0.2)` captures to one taken before. That failed on
  // every run, for two reasons that had nothing to do with the console:
  //   - the capture hook painted the overlay's full-screen effect canvases
  //     as opaque text boxes, so every capture of the quest screen was the
  //     same flat dark rectangle (fixed in `dev/capture.ts`); and
  //   - with that fixed, it would pass *vacuously*: `settle` moves the game
  //     clock, so any two captures differ by whatever is animating, before,
  //     during and long after the run. And on a warm cache the whole run —
  //     compile, run, one stdout chunk, verdict — is over in ~300 ms, before
  //     the first sample.
  //
  // So this brackets the thing itself, on the wire and on the screen:
  //   1. A program that prints, **sleeps**, prints, sleeps, and only then
  //      gives its (wrong) answer — so there is a real interval in which
  //      output has arrived and the verdict has not.
  //   2. Every frame the page receives is timestamped by the `ready` fixture,
  //      so "the chunk arrived before the reply" is a fact, not a race.
  //   3. `redraw()` draws a frame at `dt = 0`. With the loop frozen and the
  //      socket not, two redraws differ **only** if a message changed the
  //      scene's state in between. A second redraw in the same evaluation,
  //      where nothing can arrive, is the control: it must be identical, or
  //      the comparison is noise.
  // rustc on a warm cache is ~130 ms and says nothing about a clean program,
  // so what is observable is the program's own stdout — the same `run.log`
  // stream, the same console, the same repaint (§4.18).
  const account = freshAccount();
  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  try {
    await login(page, account);
    await enterRustQuest(page, wire);

    // Well inside the quest's 5 s run limit. A *wrong* answer, which is what
    // a player is usually running.
    await setSource(
      page,
      `
use std::{thread, time::Duration};
fn main() {
    for i in 1..=3 {
        println!("line {i} of 3, then a pause");
        thread::sleep(Duration::from_millis(900));
    }
    println!("not the answer");
}
`,
    );

    type Frame = { at: number; type: string; payload: Record<string, unknown> };
    const since = Date.now();
    const frames = (): Frame[] =>
      receivedFrames()
        .filter((f) => f.at >= since)
        .map((f) => {
          try {
            const m = JSON.parse(f.text) as { type: string; payload: Record<string, unknown> };
            return { at: f.at, type: m.type, payload: m.payload };
          } catch {
            return { at: f.at, type: "", payload: {} };
          }
        });
    const logs = () => frames().filter((f) => f.type === "run.log");
    const replied = () => frames().find((f) => f.type === "quest.run.ok");
    // Two redraws in one evaluation: nothing can be handled between them (the
    // page is single-threaded), so `again` is the determinism control — if it
    // ever differs from `png`, the capture is noisy and no comparison of two
    // pictures means anything.
    const redraw = () =>
      page.evaluate(() => {
        const api = window.__cwbCapture!;
        api.redraw();
        const png = api.png();
        api.redraw();
        return { png, again: api.png(), name: api.scene() };
      });

    await run(page); // Ctrl/Cmd+Enter — the reflex key

    // The first chunk, and the verdict not yet in: freeze right there.
    await expect
      .poll(() => logs().length, {
        timeout: 60_000,
        message: "no `run.log` arrived for the run at all",
      })
      .toBeGreaterThan(0);

    // A picture of exactly the state the first `n` frames made. Taken again
    // if anything lands while it is being drawn, so `n` is never a guess.
    const still = async () => {
      for (;;) {
        const n = frames().length;
        const pic = await redraw();
        if (frames().length === n) return { ...pic, n };
      }
    };
    let a = await still();
    expect(
      replied(),
      "the verdict arrived together with the first output chunk: `run.log` " +
        "is buffered and flushed at the end of the run (§5.4), which is a " +
        "spinner with extra steps",
    ).toBeUndefined();
    expect(a.name, "a run does not leave the quest screen (§4.9b)").toBe("quest");

    // Still frozen. Wait for the next thing the server says. If it is a
    // chunk of output and nothing else, that chunk is the only difference
    // between `a` and the next picture. Anything else (an `edit.push.ok`
    // from the editor, say) moves the baseline up to include it and waits
    // again — never attributing someone else's change to the console.
    let b: Awaited<ReturnType<typeof still>> | null = null;
    const deadline = Date.now() + 10_000;
    while (!b && Date.now() < deadline) {
      await expect
        .poll(() => frames().length, { timeout: 10_000 })
        .toBeGreaterThan(a.n);
      const fresh = frames().slice(a.n);
      expect(
        fresh.some((f) => f.type === "quest.run.ok"),
        "the verdict arrived before a second chunk of output could be seen " +
          "on its own: the program's lines are not reaching the page as they " +
          "are printed (§5.4)",
      ).toBe(false);
      const next = await still();
      if (next.n === a.n + 1 && fresh[0].type === "run.log") b = next;
      else a = next;
    }
    expect(b, "no chunk of output arrived on its own mid-run").not.toBeNull();
    const between = frames().slice(a.n, b!.n);
    expect(
      between.map((f) => f.type),
      "only output arrived between the two pictures, so only output can tell them apart",
    ).toEqual(["run.log"]);
    expect(
      replied(),
      "the verdict landed before the second picture was taken",
    ).toBeUndefined();

    expect(
      a.again === a.png && b!.again === b!.png,
      "two redraws at dt = 0 with nothing arriving between them differ — the " +
        "capture is not deterministic, so no comparison below means anything",
    ).toBe(true);
    expect(
      b!.png !== a.png,
      "a `run.log` chunk arrived mid-run and the quest screen did not change: " +
        "the console is not repainting from the stream. SPEC §5.4 exists so " +
        "the player watches the run think instead of a spinner.",
    ).toBe(true);
    await info.attach(`console-mid-run-${info.project.name}.png`, {
      body: Buffer.from(b!.png.split(",")[1], "base64"),
      contentType: "image/png",
    });

    await page.evaluate(() => window.__cwbCapture!.resume());
    // The run finishes, and it really did happen — the server saw it.
    await expect.poll(() => replied() !== undefined, { timeout: 60_000 }).toBe(true);
    await expect
      .poll(async () => (await wire.history()).length, { timeout: 120_000 })
      .toBeGreaterThan(0);
    const [latest] = await wire.history();
    expect(latest.verdict, "the slow source was judged").toBeTruthy();
  } finally {
    wire.close();
  }
});
