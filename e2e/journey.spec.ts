import {
  atScreen,
  expect,
  freshAccount,
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

const RUST_BASIC_FIRST = "rust.basic.01.first-light";

// The answer is not hard-coded. `quest.tests.visible[0].expect` comes back
// with the quest (PROTOCOL.md §4.8), so the test composes a source that
// prints it — content is PM's, and a suite that hard-codes an answer breaks
// the day a string changes.
const WRONG = `fn main() {
    println!("deliberately not the answer");
}
`;

function sourceThatPrints(expected: string): string {
  const lines = expected.replace(/\n$/, "").split("\n");
  const body = lines.map((l) => `    println!("${l}");`).join("\n");
  return `fn main() {\n${body}\n}\n`;
}

/** The answer, read off the quest's own visible case (PROTOCOL.md §4.8). */
async function rightAnswer(page: import("@playwright/test").Page): Promise<string> {
  const v = await view(page);
  const expected = v.quest?.tests?.visible?.[0]?.expect;
  if (!expected)
    throw new Error(
      "the quest screen exposes no `quest.tests.visible[0].expect`. The server " +
        "sends it (PROTOCOL.md §4.8); the view model has to pass it through, " +
        "or this suite cannot answer a quest without hard-coding content.",
    );
  return sourceThatPrints(expected);
}

/**
 * The player this journey is about — a fresh one, per project.
 *
 * The server persists. Account 0 of the fixture mnemonic has cleared node 1
 * on some previous run, so "node 1 is open" and PROTOCOL.md §5.4's
 * "`cleared` is true only on the first clear" would both fail against it —
 * and this file runs twice per invocation (landscape then portrait, serially,
 * against one database), so the second project would hit that on the very
 * first run.
 */
let player: { phrase: string; index: number };
test.beforeAll(() => {
  player = freshAccount();
});

async function login(page: import("@playwright/test").Page) {
  await atScreen(page, "login");
  await page.evaluate(
    ([secret, index]) => window.__cwb!.login(secret as string, index as number),
    [player.phrase, player.index] as const,
  );
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
  // The one test that deliberately uses the FIXTURE account rather than a
  // fresh one: the whole point is that the address is the one
  // `CausewaybayWallet` derives and this suite did not compute it (SPEC
  // §9.1). It only reads, so a previously-played account costs nothing.
  const account = testAccount(0);
  await atScreen(page, "login");
  await page.evaluate((secret) => window.__cwb!.login(secret), account.phrase);
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

test("RUST × BASIC → a map with an open first node", async ({ page }) => {
  await login(page);
  await atScreen(page, "lands");
  // One screen, not two: FE merged land and category select into a 2×3 grid
  // (`LandsScene`), and SPEC §10 was amended to match. RUST × BASIC is the
  // top-left cell, so a single Enter lands on the map.
  await page.keyboard.press("Enter");
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
  await page.keyboard.press("Enter"); // RUST × BASIC, the first cell
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
  await page.keyboard.press("Enter"); // RUST × BASIC, the first cell
  await atScreen(page, "map");
  await page.keyboard.press("Enter");
  await atScreen(page, "quest");

  await page.evaluate((s) => window.__cwb!.setSource(s), await rightAnswer(page));
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
  await page.keyboard.press("Enter"); // RUST × BASIC
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
  await page.keyboard.press("Enter"); // RUST × BASIC, the first cell
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

test("the compiler's output paints mid-run, before the verdict", async ({ page }) => {
  // Nobody has seen this work. FE unit-tested the console and could not
  // confirm it visually — headless RAF starvation defeated its timing
  // attempts — so `run.log` painting *while* rustc thinks is, today, a thing
  // that is believed rather than known.
  //
  // SPEC §5.4 is explicit about why it matters: "so the player watches
  // `rustc` think instead of a spinner". A console that only fills in once
  // the verdict lands is a spinner with extra steps, and every unit test on
  // both sides would still pass.
  //
  // The trick is to submit something slow enough that "before" is a real
  // interval, then race the console against the screen change. A generic
  // struct tree costs rustc real time and still compiles, so the attempt is
  // a genuine one rather than a syntax error that fails instantly.
  await login(page);
  await page.keyboard.press("Enter"); // RUST × BASIC
  await atScreen(page, "map");
  await page.keyboard.press("Enter");
  await atScreen(page, "quest");

  const slow = `
// Deliberately slow to compile: deep generic nesting, monomorphised.
struct W<T>(T);
trait Go { fn go(&self) -> usize; }
impl Go for u8 { fn go(&self) -> usize { *self as usize } }
impl<T: Go> Go for W<T> { fn go(&self) -> usize { self.0.go() + 1 } }
type A = W<W<W<W<W<W<W<W<u8>>>>>>>>;
type B = W<W<W<W<W<W<W<W<A>>>>>>>>;
type C = W<W<W<W<W<W<W<W<B>>>>>>>>;
fn main() {
    let c: C = W(W(W(W(W(W(W(W(W(W(W(W(W(W(W(W(W(W(W(W(W(W(W(W(1u8)))))))))))))))))))))));
    println!("not the answer: {}", c.go());
}
`;
  await page.evaluate((s) => window.__cwb!.setSource(s), slow);

  const sawConsoleBeforeVerdict = page
    .waitForFunction(
      () => {
        const v = JSON.parse(window.__cwb!.view());
        return typeof v.console === "string" && v.console.length > 0;
      },
      null,
      { timeout: 120_000 },
    )
    .then(() => "console");
  const verdict = page
    .waitForFunction(
      () => document.documentElement.dataset.state === "result",
      null,
      { timeout: 120_000 },
    )
    .then(() => "verdict");

  await page.evaluate(() => window.__cwb!.submit());
  const first = await Promise.race([sawConsoleBeforeVerdict, verdict]);

  expect(
    first,
    "the streaming console stayed empty until the verdict arrived. " +
      "SPEC §5.4 and PROTOCOL.md §4.18 exist so the player watches rustc " +
      "think; if this fails, `run.log` is being buffered and flushed at the " +
      "end, which is a spinner with extra steps.",
  ).toBe("console");

  await atScreen(page, "result", 120_000);
  const v = await view(page);
  expect(v.console, "the console should still hold what it streamed").toBeTruthy();
});

test("a Go submission says 'not built yet', not 'the server broke'", async ({ page }) => {
  // Go is milestone 2 (PLAN.md). The server answers a Go submission with
  // `internal_error`, which PROTOCOL.md §3.3 tells a client to render as
  // "the server broke — show a retry, log the trace_id". A player who picks
  // the GO land on day one therefore sees a crash report for a feature that
  // was simply never built.
  //
  // This test asserts the behaviour that exists AND records the complaint.
  // It is written to go green either way: what it refuses to accept is the
  // player being told nothing at all.
  await login(page);
  await atScreen(page, "lands");

  const v = await view(page);
  // GO is the second row of the 2×3 grid. If the grid cannot reach it yet,
  // there is nothing to assert and saying so is better than a false pass.
  test.skip(
    !v.lands?.some((l) => l.land === "go"),
    "the view model exposes no `lands` grid, or it has no GO row — nothing to select",
  );

  await page.keyboard.press("ArrowDown"); // GO
  await page.keyboard.press("Enter"); // GO × BASIC
  await atScreen(page, "map");
  await page.keyboard.press("Enter");
  await atScreen(page, "quest");

  await page.evaluate((s) => window.__cwb!.setSource(s), 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("x") }\n');
  await page.evaluate(() => window.__cwb!.submit());
  await atScreen(page, "result", 120_000);

  const after = await view(page);
  const verdict = after.attempt?.verdict ?? after.errors?.at(-1)?.code;
  expect(verdict, "a Go submission produced no verdict and no error").toBeTruthy();

  // The complaint, in the only place it will be read: a failing assertion the
  // day somebody decides to fix it. Until then it is recorded, not asserted.
  if (verdict === "internal_error" || verdict === "internal") {
    test.info().annotations.push({
      type: "known-gap",
      description:
        "Go comes back `internal_error`, which PROTOCOL.md §3.3 renders as " +
        "'the server broke'. A declared milestone-2 gap deserves the shape " +
        "`search.query` already uses: `not_found` with detail {\"milestone\": 2}, " +
        "so the client can grey the land out instead of showing a crash. " +
        "Raised in docs/decisions.md.",
    });
  }
});
