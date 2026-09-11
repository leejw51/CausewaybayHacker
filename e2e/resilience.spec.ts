import { atScreen, expect, freshAccount, test, view } from "./fixtures.js";

/**
 * The connection rules of SPEC §6.4, from the browser.
 *
 * §9 does not list any of these, and all three are things a player hits on
 * their first evening: a double-tapped submit, a laptop lid, a server
 * restart. The wire-level versions live in `tests/smoke/` (which can forge
 * frames a browser client would never send); these are the ones where what
 * is being tested is that *the frontend copes*, not that the server answers.
 */

async function toQuest(page: import("@playwright/test").Page) {
  // A player nobody has been before: the server persists, and these tests
  // submit. See `freshAccount` in fixtures.ts.
  const { phrase, index } = freshAccount();
  await atScreen(page, "login");
  await page.evaluate(([s, i]) => window.__cwb!.login(s as string, i as number), [
    phrase,
    index,
  ] as const);
  await atScreen(page, "lands");
  // ONE Enter, not two: land select and category select are one `LandsScene`
  // (a 2×3 grid) since SPEC §10 was amended. RUST × BASIC is the first cell.
  await page.keyboard.press("Enter");
  await atScreen(page, "map");
  await page.keyboard.press("Enter"); // open node 1
  await atScreen(page, "quest");
}

/** The answer, composed from the quest's own visible case. */
async function rightAnswer(page: import("@playwright/test").Page): Promise<string> {
  const v = await view(page);
  const expected = v.quest?.tests?.visible?.[0]?.expect;
  if (!expected)
    throw new Error("the quest screen exposes no visible case to compose an answer from");
  const body = expected
    .replace(/\n$/, "")
    .split("\n")
    .map((l) => `    println!("${l}");`)
    .join("\n");
  return `fn main() {\n${body}\n}\n`;
}

test("a second submit while one is in flight is refused, not queued", async ({
  page,
}) => {
  // SPEC §6.4: one in-flight `quest.submit` per connection; a second is
  // `busy`. What matters in the browser is that the player sees that and the
  // first attempt still finishes — a client that swallows `busy` and waits
  // forever looks identical to a hung server.
  await toQuest(page);
  await page.evaluate((s) => window.__cwb!.setSource(s), await rightAnswer(page));
  await page.evaluate(() => {
    window.__cwb!.submit();
    window.__cwb!.submit();
  });
  await atScreen(page, "result", 120_000);

  const v = await view(page);
  expect(v.attempt?.verdict).toBe("accepted");
  // The refusal is visible to the client, with the code SPEC §6.1 closes over.
  expect(v.errors?.map((e) => e.code)).toContain("busy");
});

test("a dropped socket reconnects and the session survives it", async ({ page }) => {
  // SPEC §6.4: "a reconnect resumes with the token; nothing in the game is
  // lost by a reload, because nothing in the game lives in the browser."
  // The reload half is in journey.spec.ts; this is the half where the socket
  // dies underneath a page that is still open, which is what a sleeping
  // laptop actually does.
  await toQuest(page);
  const before = await view(page);

  await page.evaluate(() => {
    // Reach into the live socket rather than going through the UI: there is
    // no button for "your wifi died", and that is the case being tested.
    const ws = (window as unknown as { __cwbSocket?: WebSocket }).__cwbSocket;
    if (!ws) throw new Error("window.__cwbSocket is not exposed — see e2e/README.md");
    // 1006 is reserved and cannot be *sent* by an endpoint; 4000-4999 is the
    // private-use range, and a close with no `server.bye` first is what a
    // sleeping laptop actually looks like.
    ws.close(4000, "simulated drop");
  });

  // No mnemonic prompt, no lost place: `auth.resume` does it with the token.
  await expect
    .poll(async () => (await view(page)).state, { timeout: 60_000 })
    .not.toBe("login");
  const after = await view(page);
  expect(after.address).toBe(before.address);
  expect(after.quest?.quest_id).toBe(before.quest?.quest_id);
});

test("an unknown protocol version does not kill the page", async ({ page }) => {
  // SPEC §6.1: a frame with an unknown `v` is answered with `proto_version`
  // and **the connection stays open**. The browser half of this is that a
  // client which receives an error for a frame it did not send carries on.
  await toQuest(page);
  await page.evaluate(() => {
    const ws = (window as unknown as { __cwbSocket?: WebSocket }).__cwbSocket;
    if (!ws) throw new Error("window.__cwbSocket is not exposed — see e2e/README.md");
    ws.send(JSON.stringify({ v: 99, id: "c-e2e-1", type: "ping", payload: {} }));
  });

  await expect
    .poll(async () => (await view(page)).errors?.map((e) => e.code) ?? [], {
      timeout: 20_000,
    })
    .toContain("proto_version");
  // Still connected, still on the quest, still able to do the next thing.
  expect((await view(page)).state).toBe("quest");
  await page.evaluate((s) => window.__cwb!.setSource(s), await rightAnswer(page));
  await page.evaluate(() => window.__cwb!.submit());
  await atScreen(page, "result", 120_000);
  expect((await view(page)).attempt?.verdict).toBe("accepted");
});
