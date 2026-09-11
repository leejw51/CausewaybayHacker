import { expect, test as base, type Page } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/**
 * The seam between this suite and the game.
 *
 * ## What changed, and why this file looks different
 *
 * The original version of this suite asked FE for a driving API —
 * `view()`, `login()`, `setSource()`, `submit()`. What landed instead is
 * `frontend/src/dev/capture.ts`: a **freeze-and-capture** hook, built for
 * screenshots. It gives `scene()` (the six screen names, exactly), plus
 * `settle()`, `step()`, `freeze()`, `orient()` and `png()`.
 *
 * That turns out to be the better half. `settle()` runs the game at a fixed
 * 1/60 step until every transition is finished and then stops the loop, so a
 * canvas game becomes *deterministic* — which is the thing a browser test
 * actually cannot do for itself. The driving half is not needed at all,
 * because the game is already drivable:
 *
 * * the seed field is a real `<textarea class="cwb-field">`,
 * * the editor is CodeMirror, whose lines are real DOM,
 * * every screen is reachable by keyboard or by a click on the canvas.
 *
 * So this suite drives the game the way a person does, and **verifies on the
 * wire**: a second websocket session, opened as the same wallet, asks the
 * server what it believes. That is a stronger assertion than any view model
 * FE could have exposed — it tests the seam rather than the client's own
 * opinion of itself. A frontend that draws CLEARED over a server that never
 * heard about it fails here and passes every unit test on both sides.
 *
 * ## The keys, read out of `frontend/src`
 *
 * | key | what |
 * | --- | --- |
 * | `Ctrl/Cmd+Enter` | submit — the login field and the editor both. A bare Enter in either inserts a newline, deliberately, so a pasted phrase does not fire a login halfway through |
 * | `F1` | pin the orientation |
 * | `F3` | log out, from anywhere, including mid-quest |
 * | `←` `→` | lands: switch RUST / GO |
 * | `←` `→` `↑` `↓` | map: move between nodes |
 * | `Enter` | map: open the selected node; result: back to the map |
 * | `Escape` | back one screen |
 * | `R` | result: retry |
 *
 * Category selection is **pointer only** — `lands.key()` handles the land
 * toggle and nothing else — so `pickFirstCategory` clicks, and says so.
 */

// ---------------------------------------------------------------- the hooks

export const SCREENS = ["boot", "login", "lands", "map", "quest", "result"] as const;
export type Screen = (typeof SCREENS)[number];

/** `frontend/src/dev/capture.ts`, as this suite uses it. */
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
 * keystroke handler that FE unit-tests already cover. The key is derived at a
 * high index off the published BIP-39 all-zero mnemonic — still a published
 * phrase, still holds nothing, still somewhere no human browses.
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
  return {
    privateKey: a.private_key,
    address: a.address,
    lower: a.address_lower,
    index,
  };
}

// ------------------------------------------------------------ the driving

/**
 * Settle the game, read the screen, and hand the loop back.
 *
 * `settle()` runs the game at a fixed step until every transition has
 * finished and then **freezes** it — which is exactly right for a screenshot
 * and exactly wrong for a test that is going to carry on. A frozen app never
 * ticks again, so anything that arrives afterwards (a `quest.get` reply, and
 * with it the editor being shown) never gets drawn, and the next locator
 * waits thirty seconds for an element that is permanently hidden.
 *
 * So: settle for the determinism, then `resume()` so the game is still alive.
 * The one test that wants a still frame settles without resuming, on purpose.
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
 * `settle()` ticks 150 frames synchronously, which is the right price to pay
 * for an assertion and the wrong one to pay forty times inside a scan. The
 * name is correct either way — a scene is swapped in one go — so the only
 * thing skipping the settle costs is that a transition may still be playing,
 * which a probe does not care about.
 */
export async function sceneNow(page: Page): Promise<string | null> {
  return page.evaluate(() => window.__cwbCapture?.scene() ?? null);
}

/**
 * Wait for a screen.
 *
 * Every poll settles first, which is what stops the flake: without it the
 * check lands in the middle of a transition and reads whichever scene the
 * tween happens to be between.
 */
export async function atScreen(page: Page, want: Screen, timeout = 60_000): Promise<void> {
  await expect
    .poll(async () => scene(page), {
      timeout,
      message: `waiting for the ${want} screen`,
    })
    .toBe(want);
}

/** Type into the seed field and submit it the way the scene expects. */
export async function login(page: Page, account: Account): Promise<void> {
  await atScreen(page, "login");
  const field = page.locator("textarea.cwb-field");
  await expect(field).toBeVisible();
  await field.fill(account.privateKey);
  // A bare Enter inserts a newline on purpose (a phrase pasted across two
  // lines must not fire a login halfway through); the accelerator is the only
  // keystroke `App` forwards out of the overlay.
  await field.press("ControlOrMeta+Enter");
  await atScreen(page, "lands");
}

/** F3, from anywhere. */
export async function logout(page: Page): Promise<void> {
  await page.keyboard.press("F3");
  await atScreen(page, "login");
}

/**
 * Click the first category row, which is BASIC.
 *
 * `lands.key()` handles the land toggle and nothing else, so a category is
 * reachable only with the pointer — and the rows are canvas-drawn, so there
 * is no selector for them. The rows are laid out top-to-bottom in the fixed
 * order `basic`, `advanced`, `hacker` in the right-hand panel, so the first
 * one that takes a click is BASIC.
 *
 * Scanning rather than hard-coding a coordinate: a hard-coded point is a test
 * that breaks the next time the panel moves by four pixels, and it fails with
 * "expected map, got lands" rather than with anything useful.
 */
export async function pickFirstCategory(page: Page): Promise<void> {
  await atScreen(page, "lands");
  const box = await page.locator("canvas#game").boundingBox();
  if (!box) throw new Error("the game canvas has no box");

  // A grid, not a column.
  //
  // The first version scanned one x at 72% of the width, which is where the
  // category panel sits in *landscape*. Portrait stacks the layout, so the
  // panel is somewhere else entirely and the scan found nothing — and the
  // failure arrived four minutes into a matrix run, in the project that runs
  // second. Two fifths of the width apart covers both shapes without caring
  // which one this is.
  //
  // Rows are scanned top-to-bottom and the first hit wins, which is BASIC:
  // the three rows are drawn in the fixed order `basic`, `advanced`,
  // `hacker`. Starting the y sweep too low silently selects ADVANCED, and
  // the only symptom is a quest that will not clear — so it starts above the
  // first row (measured at ≈0.18 in landscape) and steps finely.
  const xs = [0.72, 0.5, 0.3].map((f) => box.x + box.width * f);
  for (let i = 0; i < 46; i++) {
    const fy = 0.10 + i * 0.01;
    if (fy > 0.96) break;
    const y = box.y + box.height * fy;
    for (const x of xs) {
      await page.mouse.click(x, y);
      if ((await sceneNow(page)) === "map") {
        await atScreen(page, "map");
        return;
      }
    }
  }
  throw new Error(
    `no click anywhere on the lands screen opened a map (canvas ${box.width}×` +
      `${box.height}). The category rows are canvas-drawn and pointer-only — ` +
      "`lands.key` handles the land toggle and nothing else — so this scan is " +
      "the only way in. If the panel has moved, the scan needs to move with " +
      "it; see e2e/README.md.",
  );
}

/**
 * Open the selected node.
 *
 * Pressing Enter once is not enough. `world.map` is an async fetch, and
 * `map.key()` returns early while `this.nodes` is still empty — so an Enter
 * that arrives between the scene transition and the reply is swallowed, and
 * the test sits on the map for ever waiting for a screen that was never
 * going to change. `settle()` cannot help: it drives the render loop, not
 * the network.
 *
 * So: press, look, press again. This is also what a person does.
 */
export async function openSelectedNode(page: Page): Promise<void> {
  await atScreen(page, "map");
  for (let i = 0; i < 40; i++) {
    await page.keyboard.press("Enter");
    if ((await scene(page)) === "quest") return;
    await page.waitForTimeout(250);
  }
  throw new Error(
    "Enter never opened a node. Either the map is still empty (`world.map` " +
      "did not answer) or the selected node is locked — `map.open()` refuses " +
      "a locked node with 'clear the street before it first'.",
  );
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

export async function submit(page: Page): Promise<void> {
  await page.locator(".cm-content").click();
  await page.keyboard.press("ControlOrMeta+Enter");
}

// -------------------------------------------------------- the wire verifier

/**
 * A second opinion, from the server.
 *
 * The browser drives; this asks the server what it actually believes. It is
 * a small PROTOCOL.md client — the same idea as `tests/smoke/contract.mjs`,
 * cut down to the handful of calls this suite needs, and signing through
 * `cwbwallet` for the same reason: a fixture cannot cover a nonce the server
 * invented a moment ago.
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
    if (f.type !== `${type}.ok`)
      throw new Error(`${type} failed: ${JSON.stringify(f.payload)}`);
    return f.payload;
  }

  /** The whole rust/basic map, as the server has it for this wallet. */
  async map(): Promise<MapNode[]> {
    const p = await this.ok("world.map", { land: "rust", category: "basic" });
    return p.nodes as MapNode[];
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

  async history(): Promise<{ id: string; verdict: string }[]> {
    return (await this.ok("stats.history", { limit: 50 })).attempts as {
      id: string;
      verdict: string;
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
  state: "locked" | "open" | "cleared";
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
      (test.info() as unknown as { _errors: string[] })._errors = errors;

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
