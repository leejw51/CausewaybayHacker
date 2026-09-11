import { expect, test as base, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/**
 * The seam between this suite and the frontend.
 *
 * A 16-bit game is drawn on a canvas, so there are no DOM nodes to click and
 * no text to read: Playwright cannot see a sprite. The sibling repo
 * (`CausewaybayGolang/typescript`) solved this by publishing the current
 * screen on `<html data-state>` and the whole view model through a
 * `window.__view()` accessor, and that suite is readable because of it.
 *
 * The same convention, named here, is what this suite needs from FE. It is
 * proposed in `docs/decisions.md` (2026-09-11, "the e2e hook contract") — FE
 * owns `frontend/**` and takes it. Until it lands, every test below skips
 * with a reason naming the missing hook, so a red suite reads as a work
 * order rather than as a mystery.
 *
 * Nothing here asks the frontend to *do* less or differently. The hooks
 * observe and drive; the game is the same game with or without them. FE
 * should gate them on `import.meta.env.DEV || location.search.includes("e2e=1")`
 * so a shipped bundle does not carry a "log me in" function.
 */

// ---------------------------------------------------------------- the hooks

/**
 * Six, not SPEC §10's original seven.
 *
 * FE merged land select and category select into one `LandsScene` — a 2×3
 * grid, lands down and categories across in the fixed order `basic`,
 * `advanced`, `hacker` — and SPEC §10 has been amended to match. There is no
 * `categories` screen; a test that waits for one waits forever.
 */
export const SCREENS = [
  "boot",
  "login",
  "lands",
  "map",
  "quest",
  "result",
] as const;
export type Screen = (typeof SCREENS)[number];

export interface CwbHooks {
  /** The whole view model, as the scene sees it, JSON-stringified. */
  view(): string;
  /**
   * Log in with a mnemonic or a `0x…` private key: derive on
   * `m/44'/60'/0'/0/<index>` (default 0), `auth.challenge`, sign,
   * `auth.login`, land on the lands screen. Resolves when the session is
   * live.
   *
   * This exists because typing twelve words into a canvas one
   * `keyboard.press` at a time is a test of the keyboard handler, not of the
   * login, and FE's own unit tests already cover that. The `index` argument
   * exists because the server persists and a suite that always logs in as
   * account 0 can only be run once.
   */
  login(secret: string, index?: number): Promise<void>;
  /** Replace the editor's contents. CodeMirror is not a `<textarea>`. */
  setSource(source: string): void;
  /** Fire `quest.submit` with whatever is in the editor. */
  submit(): void;
  /** Forget the session token, as a logout would. */
  forget(): void;
}

declare global {
  interface Window {
    __cwb?: CwbHooks;
  }
}

/** What the view model has to carry for this suite to assert anything. */
export interface View {
  state: Screen;
  /** lowercase 0x hex, 42 chars — SPEC §3.4. Null before login. */
  address: string | null;
  address_eip55: string | null;
  land: "rust" | "go" | null;
  /** Categories are drawn in this fixed order on the lands grid. */
  category: "basic" | "advanced" | "hacker" | null;
  /** Present on the map screen. Mirrors `MapNode` from SPEC §6.3. */
  nodes?: {
    quest_id: string;
    node: number;
    title: string;
    state: "locked" | "open" | "cleared";
    stars: 0 | 1 | 2 | 3;
  }[];
  /** Present on the lands screen: the 2×3 grid, as `world.lands` gave it. */
  lands?: {
    land: "rust" | "go";
    categories: { category: string; total: number; cleared: number; open: boolean }[];
  }[];
  /**
   * Present on the quest screen.
   *
   * `tests.visible` is the shape the server sends (PROTOCOL.md §4.8 —
   * `visible[]` plus `hidden_count`, and **no `cases` key**), so passing the
   * server's `Quest` straight through is the least work and the most correct.
   * The suite needs it because it composes the right answer from
   * `visible[0].expect` rather than hard-coding a string PM owns.
   */
  quest?: {
    quest_id: string;
    title: string;
    /** whatever is in the editor right now, starter or edited */
    source: string;
    tests?: {
      visible: { name: string; stdin: string; expect: string }[];
      hidden_count: number;
    };
  };
  /** Present on the result screen. Mirrors `Attempt` from PROTOCOL.md §5.4. */
  attempt?: {
    id: string;
    verdict: string;
    tests_passed: number;
    tests_total: number;
    cleared: boolean;
    stars: 0 | 1 | 2 | 3;
  };
  /** Every error frame the client has received, newest last. */
  errors?: { code: string; message: string; detail?: Record<string, unknown> }[];
  /**
   * The streaming console's text so far — everything `run.log` has delivered
   * for the attempt in flight, concatenated. Needed by the one test that can
   * prove the console paints *during* a compile rather than after it.
   */
  console?: string;
}

// ------------------------------------------------------------- the fixtures

const here = fileURLToPath(new URL(".", import.meta.url));

const vectors = () =>
  JSON.parse(
    readFileSync(new URL("../tests/vectors/addresses.json", import.meta.url), "utf8"),
  );

/**
 * A fixture account with a known address — for the conformance assertion
 * (SPEC §9.1), where the whole point is that the address is the one
 * `CausewaybayWallet` derives and this suite did not compute it.
 */
export function testAccount(index = 0): { phrase: string; address: string; lower: string } {
  const m = vectors().mnemonics[0];
  const a = m.accounts.find((x: { index: number }) => x.index === index);
  if (!a) throw new Error(`no account ${index} in addresses.json`);
  return { phrase: m.phrase, address: a.address, lower: a.address_lower };
}

/**
 * A player nobody has been before.
 *
 * The server persists — `~/.causewaybayhacker/hacker.db` remembers that the
 * fixture address cleared node 1 — so a journey pinned to one address asserts
 * "node 1 is open" against a node that is already cleared, and `cleared: true`
 * against PROTOCOL.md §5.4's "true only on the *first* clear". This suite
 * runs twice per invocation (landscape then portrait, serially, against one
 * database), so the second project would hit that on the very first run.
 *
 * The derivation path is the same one the player uses. Index 1_000_000+ off
 * the published BIP-39 all-zero mnemonic is still a published phrase, still
 * holds nothing, and is somewhere no human ever browses. Unique per worker
 * *and* per test, so nothing in the suite shares a map with anything else.
 */
let freshN = 0;
const freshBase = 1_000_000 + Math.floor(Math.random() * 1_000_000);
export function freshAccount(): { phrase: string; index: number } {
  return { phrase: vectors().mnemonics[0].phrase, index: freshBase + freshN++ };
}

export async function isUp(url: string): Promise<boolean> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(3_000) });
    return res.status < 500;
  } catch {
    return false;
  }
}

export const state = (page: Page) => page.locator("html");

export async function view(page: Page): Promise<View> {
  const raw = await page.evaluate(() => window.__cwb?.view() ?? null);
  if (raw === null) throw new Error("window.__cwb.view() is not installed");
  return JSON.parse(raw) as View;
}

export async function hasHooks(page: Page): Promise<boolean> {
  return page.evaluate(() => typeof window.__cwb?.view === "function");
}

export async function atScreen(page: Page, screen: Screen, timeout = 30_000) {
  await expect(state(page)).toHaveAttribute("data-state", screen, { timeout });
}

/**
 * The reasons a test is not running, spelled out. Each names the thing that
 * has to exist; none of them says "not implemented".
 */
export const BLOCKED = {
  frontend: (url: string, why: string) =>
    `${url} is ${why}. Start it: \`make dev\` (frontend :5291, backend :5390), ` +
    `or point E2E_BASE_URL / E2E_BACKEND_URL at a running instance. This suite never ` +
    `starts a server itself — see playwright.config.ts.`,
  backend: (url: string, why: string) =>
    `the backend at ${url} is ${why}. The frontend draws, the server owns every rule ` +
    `(PLAN.md) — a journey test without it would assert nothing. Start it: ` +
    `\`make serve\`, or set E2E_BACKEND_URL.`,
  hooks:
    "the frontend does not publish `window.__cwb` / `<html data-state>`. " +
    "The contract is in e2e/fixtures.ts and proposed to FE in docs/decisions.md " +
    "(2026-09-11, 'the e2e hook contract'). Nothing here can select a sprite without it.",
} as const;

/**
 * Every test goes through this. Two gates, two different messages:
 *
 *   nothing listening      → skip: start the servers
 *   listening, no hooks    → fixme: FE owes the hooks
 *
 * The distinction matters. The first is "you did not run it right"; the
 * second is "the product is not there yet". Collapsing them into one red
 * line is how a suite stops being read.
 */
export const test = base.extend<{ ready: void }>({
  ready: [
    async ({ page, baseURL }, use) => {
      // `global-setup.ts` probed both ports before any browser was launched,
      // so this is a string comparison and not a second round of fetches.
      const frontUrl = baseURL ?? "http://127.0.0.1:5291";
      const backUrl = process.env.E2E_BACKEND_URL ?? "http://127.0.0.1:5390";
      const front = process.env.E2E_FRONTEND_STATE ?? "down (no preflight)";
      const back = process.env.E2E_BACKEND_STATE ?? "down (no preflight)";
      test.skip(front !== "up", BLOCKED.frontend(frontUrl, front));
      test.skip(back !== "up", BLOCKED.backend(backUrl, back));

      const errors: string[] = [];
      page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
      page.on("pageerror", (e) => errors.push(String(e)));
      (test.info() as unknown as { _errors: string[] })._errors = errors;

      await page.goto("/");
      // `boot` is allowed to be brief; what matters is that the hooks arrive.
      await page
        .waitForFunction(() => typeof window.__cwb?.view === "function", null, {
          timeout: 15_000,
        })
        .catch(() => undefined);
      if (!(await hasHooks(page))) test.fixme(true, BLOCKED.hooks);

      await use();
    },
    { auto: true },
  ],
});

export { expect, here };
