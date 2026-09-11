import { expect, test as base, type Page } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/**
 * The seam between this suite and the game.
 *
 * ## What FE shipped, and why it was the better half
 *
 * The original version of this suite asked for a driving API — `view()`,
 * `login()`, `setSource()`, `submit()`. What landed instead is
 * `frontend/src/dev/capture.ts`: a **freeze-and-capture** hook built for
 * screenshots, giving `scene()` (the six screen names, exactly), plus
 * `settle()`, `step()`, `freeze()`, `orient()` and `png()`.
 *
 * That is the half worth having. `settle()` runs the game at a fixed 1/60
 * step until every transition has finished, which makes a canvas game
 * **deterministic** — the thing a browser test genuinely cannot do for
 * itself. The driving half was not needed, because the game is already
 * drivable: the seed field is a real `<textarea class="cwb-field">`, the
 * editor is CodeMirror with real DOM lines, and every screen is reachable by
 * keyboard or by a click.
 *
 * So this suite drives the game the way a person does, and **verifies on the
 * wire** — a second websocket session, opened as the same wallet, asks the
 * server what it actually believes. That is a stronger assertion than any
 * view model could support: a frontend that draws CLEARED over a server that
 * never heard about it fails here and passes every unit test on both sides.
 *
 * ## The keys, read out of `frontend/src`
 *
 * | key | what |
 * | --- | --- |
 * | `Ctrl/Cmd+Enter` | submit — the login field and the editor both. A bare Enter in either inserts a newline, deliberately, so a phrase pasted across two lines does not fire a login halfway through |
 * | `F1` | pin the orientation |
 * | `F3` | log out, from anywhere, including mid-quest |
 * | `←` `→` | lands: toggle RUST / GO. There is no way to *set* it |
 * | `←` `→` `↑` `↓` | map: move between nodes |
 * | `Enter` | map: open the selected node; result: back to the map |
 * | `Escape` | back one screen |
 *
 * Category selection is **pointer only** — `lands.key()` handles the land
 * toggle and nothing else — so `pickFirstCategory` clicks, and says so.
 */

// ---------------------------------------------------------------- the hooks

export const SCREENS = ["boot", "login", "lands", "map", "quest", "result"] as const;
export type Screen = (typeof SCREENS)[number];

/** `frontend/src/dev/capture.ts`, as much of it as this suite uses. */
export interface CaptureApi {
  freeze(): void;
  resume(): void;
  frozen(): boolean;
  step(n?: number): number;
  settle(secs?: number): number;
  orient(mode: "landscape" | "portrait"): void;
  png(): string;
  scene(): string | null;
  orientation(): string;
  virtual(): [number, number];
  backing(): { game: [number, number]; fx: [number, number] };
  /**
   * Every button the current scene hit-tests against, with `client` in CSS
   * pixels ready for `page.mouse.click`. The rects are the same objects the
   * game checks a click against, so this cannot drift from what clicking
   * actually does.
   */
  buttons(): Array<{
    id: string;
    label: string;
    dim: boolean;
    rect: [number, number, number, number];
    client: [number, number, number, number];
  }>;
  /** The middle of one button in CSS pixels, or null if it is not on screen. */
  buttonAt(id: string): [number, number] | null;
}

declare global {
  interface Window {
    __cwbCapture?: CaptureApi;
    __cwb?: Pick<CaptureApi, "scene" | "orientation" | "virtual">;
  }
}

// ------------------------------------------------------------- the wallet

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const WALLET =
  process.env.CWBWALLET ?? `${ROOT}/../CausewaybayWallet/rustcli/target/debug/cwbwallet`;
const VECTORS = `${ROOT}/tests/vectors/addresses.json`;

export interface Account {
  /** `0x` + 64 hex. The login field takes this directly — no BIP-39 needed. */
  privateKey: string;
  /** EIP-55, the form the wire and the header use. */
  address: string;
  lower: string;
  index: number;
}

/**
 * A player nobody has been before.
 *
 * The server persists, so a suite pinned to one fixture address would assert
 * "node 1 is open" against a node a previous run already cleared — and this
 * suite runs twice per invocation (landscape then portrait, one database), so
 * it would break on its own first run.
 *
 * A **private key** rather than a mnemonic: the field takes "twelve words, or
 * 0x + 64 hex", and a key is one paste instead of twelve words through a
 * keystroke handler FE unit-tests already cover. Derived at a high index off
 * the published BIP-39 all-zero mnemonic — still a published phrase, still
 * holds nothing, still somewhere no human browses.
 */
let freshN = 0;
const freshBase = 2_000_000 + Math.floor(Math.random() * 1_000_000);
export function freshAccount(): Account {
  if (!existsSync(WALLET))
    throw new Error(
      `no wallet at ${WALLET}. This suite derives a throwaway account per run ` +
        `with CausewaybayWallet rather than reusing a fixture address the ` +
        `server already has progress for. Build it, or set $CWBWALLET.`,
    );
  const index = freshBase + freshN++;
  const phrase = JSON.parse(readFileSync(VECTORS, "utf8")).mnemonics.find(
    (m: { name: string }) => m.name === "bip39-canonical",
  ).phrase;
  const out = execFileSync(
    WALLET,
    ["--json", "utils", "derive", "--mnemonic", phrase, "--index", String(index)],
    { encoding: "utf8" },
  );
  const d = JSON.parse(out).data;
  return {
    privateKey: d.private_key,
    address: d.address,
    lower: d.address.toLowerCase(),
    index,
  };
}

/** The fixture account, for the one assertion that is about the fixture. */
export function fixtureAccount(index = 0): Account {
  const m = JSON.parse(readFileSync(VECTORS, "utf8")).mnemonics[0];
  const a = m.accounts.find((x: { index: number }) => x.index === index);
  return { privateKey: a.private_key, address: a.address, lower: a.address_lower, index };
}

// ------------------------------------------------------------ the driving

/**
 * Settle the game, read the screen, and hand the loop back.
 *
 * `settle()` runs until every transition has finished and then **freezes** —
 * right for a screenshot, wrong for a test that is going to carry on. A
 * frozen app never ticks again, so anything that arrives afterwards (a
 * `quest.get` reply, and with it the editor being shown) is never drawn, and
 * the next locator waits thirty seconds for an element that is permanently
 * hidden. So: settle for the determinism, then `resume()`. The one test that
 * wants a still frame settles without resuming, on purpose.
 */
export async function scene(page: Page): Promise<string | null> {
  return page.evaluate(() => {
    const api = window.__cwbCapture;
    if (!api) return null;
    api.settle();
    const name = api.scene();
    api.resume();
    return name;
  });
}

/**
 * The screen, without settling.
 *
 * `settle()` ticks 150 frames synchronously, which is the right price for an
 * assertion and the wrong one to pay a hundred times inside a click scan. The
 * name is correct either way — a scene is swapped in one go.
 */
export async function sceneNow(page: Page): Promise<string | null> {
  return page.evaluate(() => window.__cwbCapture?.scene() ?? null);
}

/** Wait for a screen. Every poll settles first, which is what stops the flake. */
export async function atScreen(page: Page, want: Screen, timeout = 60_000): Promise<void> {
  await expect
    .poll(async () => scene(page), { timeout, message: `waiting for the ${want} screen` })
    .toBe(want);
}

/**
 * Click a button by id.
 *
 * This replaces two geometric scans and the whole class of failure they
 * produced. The scans cost four runs between them — the lands panel at the
 * wrong x, then the wrong y range, then the wrong land because a stray click
 * toggled it, then SUBMIT moving onto a second line when FORMAT was added —
 * and every one of those failed by silently doing *something else* rather
 * than by failing where the mistake was.
 *
 * `buttons()` reads the same rects the scene hit-tests against, so it cannot
 * disagree with what a click does. Nothing here is a guess any more.
 */
export async function clickButton(page: Page, id: string, timeout = 30_000): Promise<void> {
  const deadline = Date.now() + timeout;
  for (;;) {
    const found = await page.evaluate((wanted) => {
      const api = window.__cwbCapture;
      if (!api?.buttons) return { has: false, ids: [] as string[], at: null };
      const all = api.buttons();
      return {
        has: true,
        ids: all.map((b) => b.id),
        at: api.buttonAt(wanted),
      };
    }, id);

    if (!found.has)
      throw new Error(
        "the page does not expose `__cwbCapture.buttons()`. Build the e2e " +
          "bundle (`npm run build:e2e` in frontend/) — a plain `dist` does " +
          "not carry the capture hook.",
      );
    if (found.at) {
      await page.mouse.click(found.at[0], found.at[1]);
      return;
    }
    if (Date.now() > deadline)
      throw new Error(
        `no button \`${id}\` on this screen. The scene offers: ` +
          `${found.ids.join(", ") || "(none)"}. Button ids are listed per ` +
          `scene in FE's entry in docs/decisions.md.`,
      );
    await page.waitForTimeout(250);
  }
}

/** Type into the seed field and submit it the way the scene expects. */
export async function login(page: Page, account: Account): Promise<void> {
  await atScreen(page, "login");
  const field = page.locator("textarea.cwb-field");
  await expect(field).toBeVisible();
  await field.fill(account.privateKey);
  await field.press("ControlOrMeta+Enter");
  await atScreen(page, "lands");
}

/** F3, from anywhere. */
export async function logout(page: Page): Promise<void> {
  await page.keyboard.press("F3");
  await atScreen(page, "login");
}

/**
 * Click the first category row, and report where the click landed.
 *
 * `lands.key()` handles the land toggle and nothing else, so a category is
 * reachable only with the pointer — and the rows are canvas-drawn, so there
 * is no selector for them. Rows are drawn top-to-bottom in the fixed order
 * `basic`, `advanced`, `hacker`, so the first row that takes a click is
 * BASIC.
 *
 * The geometry was measured twice, because guessing cost two matrix runs:
 *   landscape — a right-hand panel, y ≈ 0.18 … 0.46
 *   portrait  — full width and low, y ≈ 0.65 … 0.80
 * The first version swept one x at 0.72 (landscape's panel) and the second
 * capped its loop at y ≈ 0.55, so portrait's rows were never reached. The
 * range is computed from the bounds now rather than from an iteration count
 * somebody has to keep in step with them.
 *
 * The hit point is returned so a retry can click the *same* place instead of
 * sweeping again — see `enterRustQuest` for why that matters.
 */
export async function pickCategory(page: Page, category = "basic"): Promise<void> {
  await atScreen(page, "lands");
  await clickButton(page, `cat:${category}`);
  await atScreen(page, "map");
}

/** Choose the land. `land:rust` / `land:go` — a click, not a blind toggle. */
export async function pickLand(page: Page, land: "rust" | "go"): Promise<void> {
  await atScreen(page, "lands");
  await clickButton(page, `land:${land}`);
}

/**
 * Open the selected node.
 *
 * Pressing Enter once is not enough. `world.map` is an async fetch, and
 * `map.key()` returns early while `this.nodes` is still empty — so an Enter
 * that arrives between the scene transition and the reply is swallowed, and
 * the test sits on the map for ever. `settle()` cannot help: it drives the
 * render loop, not the network. So: press, look, press again. This is also
 * what a person does.
 */
export async function openSelectedNode(page: Page): Promise<void> {
  await atScreen(page, "map");
  for (let i = 0; i < 40; i++) {
    await page.keyboard.press("Enter");
    if ((await sceneNow(page)) === "quest") {
      await atScreen(page, "quest");
      return;
    }
    await page.waitForTimeout(250);
  }
  throw new Error(
    "Enter never opened a node. Either the map is still empty (`world.map` " +
      "did not answer) or the node could not be opened for some other reason. " +
      "§4.7 means it will not be because it is locked: every node is playable.",
  );
}

/** Whatever the editor is showing, as text. */
export async function editorText(page: Page): Promise<string> {
  return page.evaluate(() =>
    Array.from(document.querySelectorAll(".cm-line"))
      .map((l) => (l.textContent ?? "").replace(/\u200b/g, ""))
      .join("\n"),
  );
}

/**
 * Which quest did the UI just open?
 *
 * The scan in `pickFirstCategory` clicks its way across the lands plate, and
 * some of those clicks land on the **land** buttons, which toggle RUST/GO.
 * Nothing on the page reports the current land, so the scan can arrive at a
 * perfectly good map of the wrong land — and the symptom, before this
 * existed, was a submission to `go.basic.01.package-main` while the test
 * asserted about `rust.basic.01.first-light`.
 *
 * The editor's contents are the answer: it opens with the quest's `starter`
 * (SPEC §12), and starters differ between quests and certainly between
 * languages. So ask the wire for the starters of everything open, and match.
 */
export async function identifyOpenQuest(page: Page, wire: Wire): Promise<string | null> {
  // The editor is filled by the `quest.get` reply, a round trip after the
  // scene appears. Reading it too early gets an empty box and a confident
  // `null`.
  await page
    .waitForFunction(
      () =>
        Array.from(document.querySelectorAll(".cm-line")).some(
          (l) => (l.textContent ?? "").trim().length > 0,
        ),
      null,
      { timeout: 30_000 },
    )
    .catch(() => undefined);

  // CodeMirror renders a zero-width space into an empty line and does its own
  // thing with trailing whitespace, so compare on shape rather than bytes.
  const flatten = (s: string) =>
    s
      .replace(/\u200b/g, "")
      .split("\n")
      .map((l) => l.replace(/\s+$/, ""))
      .filter((l) => l.length > 0)
      .join("\n")
      .trim();

  const shown = flatten(await editorText(page));
  if (!shown) return null;

  // The language narrows it to one land before a single `quest.get` is sent,
  // and the map opens on its first node, so the low numbers are checked
  // first and the search stops at the first match.
  //
  // This used to skip `locked` nodes, which kept the search short by
  // accident. §4.7 made every node playable, so without a cap this walks all
  // 116 quests in both lands — 116 round trips per attempt, four attempts per
  // test — and the test times out rather than failing on anything real. That
  // is what it did.
  const isGo = /^package\s+main\b/m.test(shown);
  const lands = isGo ? (["go"] as const) : (["rust"] as const);
  const LOOK_AT = 8;
  for (const land of lands) {
    const nodes = (await wire.mapOf(land)).sort((a, b) => a.node - b.node).slice(0, LOOK_AT);
    for (const node of nodes) {
      const got = await wire.ok("quest.get", { quest_id: node.quest_id });
      const starter = flatten(String((got.quest as { starter?: string }).starter ?? ""));
      if (starter && starter === shown) return node.quest_id;
    }
  }
  // No exact match within the first few nodes. The language is still a
  // strong signal, and for the retry loop — which only needs to know whether
  // to flip the land — that is enough.
  if (isGo) return "go.unknown";
  if (/\bfn\s+main\s*\(/.test(shown)) return "rust.unknown";
  return null;
}

/**
 * Reach an open RUST quest, whatever the lands scan does on the way, and
 * report which quest it actually is.
 *
 * Rather than insisting the scan lands on RUST — which it cannot be made to
 * do reliably while the category rows are canvas-drawn and the land buttons
 * sit in the sweep — this opens a quest, asks which one it is, and flips the
 * land if it is the wrong one.
 *
 * The trick is that a retry clicks **the remembered point**, not a fresh
 * sweep. A second sweep's stray clicks would toggle the land an unknown
 * number of further times and the retry would be a coin flip; one remembered
 * click toggles nothing, so `ArrowRight` is the only thing that moves the
 * land and at most one flip is ever needed.
 */
export async function enterRustQuest(page: Page, wire: Wire): Promise<string> {
  // Was a four-attempt retry loop that clicked its way across the plate and
  // flipped the land when it guessed wrong. `buttons()` makes it three
  // clicks, and the land is *chosen* rather than toggled toward.
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await openSelectedNode(page);
  const id = await identifyOpenQuest(page, wire);
  if (id && id.startsWith("rust.")) return id;
  // Still worth asking the wire rather than trusting the click: a content
  // edit can leave the editor showing a starter the map does not name.
  const first = (await wire.mapOf("rust")).sort((a, b) => a.node - b.node)[0];
  if (first) return first.quest_id;
  throw new Error("the rust/basic map is empty");
}

/** Replace the editor's contents. CodeMirror is not a `<textarea>`. */
export async function setSource(page: Page, source: string): Promise<void> {
  const editor = page.locator(".cm-content");
  await expect(editor).toBeVisible();
  await editor.click();
  await page.keyboard.press("ControlOrMeta+A");
  await page.keyboard.press("Backspace");
  // `insertText` rather than `type`: CodeMirror auto-indents and auto-closes
  // brackets, so typing a program character by character produces a different
  // program from the one the test meant to submit.
  await page.keyboard.insertText(source);
}

/**
 * Press RUN — the reflex key.
 *
 * §4.9b: a run executes the visible cases, never clears, and **stays on the
 * quest screen**. `Ctrl/Cmd+Enter` is bound to this, deliberately: "Submitting
 * is a decision and it is made with a button, not with the shortcut
 * somebody's hands press without looking" (`frontend/src/scenes/quest.ts`).
 */
export async function run(page: Page): Promise<void> {
  await page.locator(".cm-content").click();
  await page.keyboard.press("ControlOrMeta+Enter");
}

/**
 * Press SUBMIT, which is a **button** and has no keyboard shortcut.
 *
 * This helper used to send `Ctrl/Cmd+Enter`, and it worked until `quest.run`
 * landed and took that key. The symptom was the honest one — the suite waited
 * three minutes for a result screen that was never coming, because the key it
 * pressed does not navigate anywhere — and it is exactly the kind of change a
 * unit test on either side cannot notice.
 *
 * The button is canvas-drawn, so this scans for it. Unlike the lands scan,
 * this one is **self-verifying**: RUN stays on `quest` and SUBMIT goes to
 * `result`, so a click that reaches the result screen was the right click by
 * definition. A stray RUN on the way costs a compile and nothing else.
 */
export async function submit(page: Page): Promise<void> {
  // Two independent ways in, and the test takes the button because that is
  // what a player does. `Ctrl/Cmd+Shift+Enter` is the other — the RUN key
  // with SHIFT — and it exists because a primary action reachable only with
  // a mouse is an accessibility gap, not merely a test problem.
  await clickButton(page, "submit");
  // Submitting is a decision, so it asks first; `App` answers a modal with
  // Enter. Harmless when there is no modal.
  await page.keyboard.press("Enter");
  await atScreen(page, "result", 180_000);
}

/** The keyboard route to the same thing, so the binding itself is tested. */
export async function submitByKey(page: Page): Promise<void> {
  await page.locator(".cm-content").click();
  await page.keyboard.press("ControlOrMeta+Shift+Enter");
  await page.keyboard.press("Enter");
  await atScreen(page, "result", 180_000);
}

// -------------------------------------------------------- the wire verifier

/**
 * A second opinion, from the server.
 *
 * The browser drives; this asks the server what it believes. It is a small
 * PROTOCOL.md client — the same idea as `tests/smoke/contract.mjs`, cut down
 * to the calls this suite needs, signing through `cwbwallet` for the same
 * reason: a fixture cannot cover a nonce the server invented a moment ago.
 */
export class Wire {
  private ws!: WebSocket;
  private n = 0;
  private readonly pending = new Map<string, (v: WireFrame) => void>();

  static async as(url: string, account: Account): Promise<Wire> {
    const w = new Wire();
    await w.open(url);
    const ch = await w.call("auth.challenge", { address: account.address });
    const sig = JSON.parse(
      execFileSync(
        WALLET,
        [
          "--json",
          "utils",
          "sign",
          "--private-key",
          account.privateKey,
          "--message",
          String((ch.payload as { message: string }).message),
        ],
        { encoding: "utf8" },
      ),
    ).data.signature;
    const login = await w.call("auth.login", { address: account.address, signature: sig });
    if (login.type !== "auth.login.ok")
      throw new Error(`the wire could not log in: ${JSON.stringify(login.payload)}`);
    return w;
  }

  private open(url: string): Promise<void> {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(url.replace(/^http/, "ws").replace(/\/$/, "") + "/ws");
      const timer = setTimeout(() => reject(new Error(`no websocket at ${url}`)), 10_000);
      this.ws.addEventListener("open", () => (clearTimeout(timer), resolve()));
      this.ws.addEventListener("error", () => (clearTimeout(timer), reject(new Error(url))));
      this.ws.addEventListener("message", (e) => {
        const f = JSON.parse(String(e.data)) as WireFrame;
        if (f.id && this.pending.has(f.id)) {
          this.pending.get(f.id)!(f);
          this.pending.delete(f.id);
        }
      });
    });
  }

  call(type: string, payload: Record<string, unknown> = {}): Promise<WireFrame> {
    const id = `w-${++this.n}`;
    const p = new Promise<WireFrame>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`no reply to ${type}`)), 30_000);
      this.pending.set(id, (f) => (clearTimeout(timer), resolve(f)));
    });
    this.ws.send(JSON.stringify({ v: 1, id, type, payload }));
    return p;
  }

  async ok(type: string, payload: Record<string, unknown> = {}): Promise<WirePayload> {
    const f = await this.call(type, payload);
    if (f.type !== `${type}.ok`) throw new Error(`${type} failed: ${JSON.stringify(f.payload)}`);
    return f.payload;
  }

  /** The rust/basic map, as the server has it for this wallet. */
  async map(): Promise<MapNode[]> {
    return this.mapOf("rust");
  }

  async mapOf(land: "rust" | "go", category = "basic"): Promise<MapNode[]> {
    const p = await this.ok("world.map", { land, category });
    return (p.nodes ?? []) as MapNode[];
  }

  async node(questId: string): Promise<MapNode | undefined> {
    return (await this.map()).find((n) => n.quest_id === questId);
  }

  /** An open quest, and a source that answers its visible case. */
  async answerable(): Promise<{ node: MapNode; source: string }> {
    for (const node of (await this.map()).filter((n) => n.state === "open")) {
      const got = await this.ok("quest.get", { quest_id: node.quest_id });
      const visible = (got.quest as QuestShape).tests?.visible?.[0];
      const source = sourceThatPrints(visible);
      if (source) return { node, source };
    }
    throw new Error("no open quest whose visible case can be answered by printing");
  }

  async history(): Promise<{ id: string; verdict: string; quest_id: string }[]> {
    return (await this.ok("stats.history", { limit: 50 })).attempts as {
      id: string;
      verdict: string;
      quest_id: string;
    }[];
  }

  close(): void {
    try {
      this.ws.close();
    } catch {
      /* already gone */
    }
  }
}

export type WirePayload = Record<string, unknown>;
export interface WireFrame {
  v: number;
  id: string | null;
  type: string;
  payload: WirePayload;
}
export interface MapNode {
  quest_id: string;
  node: number;
  title: string;
  /** §5.2: `open` or `cleared`. Never `locked` — §4.7, every node is playable. */
  state: "open" | "cleared";
  stars: 0 | 1 | 2 | 3;
}
interface QuestShape {
  tests?: { visible?: { name: string; stdin: string; expect: string }[] };
}

/**
 * A Rust source that prints exactly what a visible case expects.
 *
 * Content is PM's; a suite that hard-codes an answer breaks the day a string
 * changes. A case that reads stdin cannot be answered by printing a constant
 * and is skipped — that quest is teaching something, which is the point.
 */
export function sourceThatPrints(
  visible: { stdin?: string; expect?: string } | undefined,
): string | null {
  if (!visible?.expect || visible.stdin) return null;
  if (!visible.expect.endsWith("\n")) return null;
  const lines = visible.expect.slice(0, -1).split("\n");
  if (lines.some((l) => /["\\{}]/.test(l))) return null;
  return `fn main() {\n${lines.map((l) => `    println!("${l}");`).join("\n")}\n}\n`;
}

export const WRONG_SOURCE = 'fn main() { println!("deliberately not the answer"); }\n';

// ------------------------------------------------------------- the fixture

export const BLOCKED = {
  server: (url: string, why: string) =>
    `${url} is ${why}. This suite never starts a server — see playwright.config.ts. ` +
    `Start one with the e2e bundle:\n` +
    `  cd frontend && npm run build:e2e\n` +
    `  cd backend && cargo run -p cwbhacker -- serve --static ../frontend/dist-e2e --home <tmp>\n` +
    `or run the whole matrix: node tests/run-all.mjs`,
  hook:
    "the page does not expose `window.__cwbCapture`. It is dev-and-e2e only " +
    "(`frontend/src/dev/capture.ts`, gated on `import.meta.env.DEV || " +
    "VITE_E2E === '1'`), so a plain `npm run build` bundle will not have it. " +
    "Build with `npm run build:e2e` and serve `frontend/dist-e2e`.",
} as const;

export const test = base.extend<{ ready: void }>({
  ready: [
    async ({ page, baseURL }, use) => {
      const url = baseURL ?? "http://127.0.0.1:5390";
      const state = process.env.E2E_SERVER_STATE ?? "down (no preflight)";
      test.skip(state !== "up", BLOCKED.server(url, state));

      const errors: string[] = [];
      page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
      page.on("pageerror", (e) => errors.push(String(e)));

      // Every websocket frame the page sends, collected **before** the page
      // is navigated.
      //
      // `page.on("websocket")` fires when a socket is *created*. The client
      // connects during boot, so a listener attached inside a test body
      // misses that socket entirely and the test sees zero frames — which,
      // for the "no key material on the wire" check, is a pass by vacuum.
      // It cost one confusing red before it was caught, and it would have
      // cost far more as a silent green.
      const sent: string[] = [];
      page.on("websocket", (ws) => ws.on("framesent", (f) => sent.push(String(f.payload))));

      const info = test.info() as unknown as { _errors: string[]; _sent: string[] };
      info._errors = errors;
      info._sent = sent;

      await page.goto("/");
      await page
        .waitForFunction(() => typeof window.__cwbCapture?.settle === "function", null, {
          timeout: 30_000,
        })
        .catch(() => undefined);
      const hooked = await page.evaluate(
        () => typeof window.__cwbCapture?.settle === "function",
      );
      test.skip(!hooked, BLOCKED.hook);

      await use();
    },
    { auto: true },
  ],
});

export { expect };
