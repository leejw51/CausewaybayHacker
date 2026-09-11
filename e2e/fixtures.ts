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

export const SCREENS = [
  "boot",
  "login",
  "lands",
  "categories",
  "map",
  "quest",
  "result",
] as const;
export type Screen = (typeof SCREENS)[number];

export interface CwbHooks {
  /** The whole view model, as the scene sees it, JSON-stringified. */
  view(): string;
  /**
   * Log in with a mnemonic or a `0x…` private key: derive, `auth.challenge`,
   * sign, `auth.login`, land on the land-select screen. Resolves when the
   * session is live. This exists because typing twelve words into a canvas
   * one `keyboard.press` at a time is a test of the keyboard handler, not of
   * the login, and it is tested separately by FE's own unit tests.
   */
  login(secret: string): Promise<void>;
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
  category: "basic" | "advanced" | "hacker" | null;
  /** Present on the map screen. Mirrors `MapNode` from SPEC §6.3. */
  nodes?: {
    quest_id: string;
    node: number;
    title: string;
    state: "locked" | "open" | "cleared";
    stars: 0 | 1 | 2 | 3;
  }[];
  /** Present on the quest screen. */
  quest?: { quest_id: string; title: string; source: string };
  /** Present on the result screen. Mirrors `Attempt` from SPEC §6.3. */
  attempt?: {
    id: string;
    verdict: string;
    tests_passed: number;
    tests_total: number;
    cleared: boolean;
    stars: 0 | 1 | 2 | 3;
  };
  /** Every error frame the client has received, newest last. */
  errors?: { code: string; message: string }[];
}

// ------------------------------------------------------------- the fixtures

const here = fileURLToPath(new URL(".", import.meta.url));

/** The first mnemonic from `tests/vectors/addresses.json`, with its address. */
export function testAccount(index = 0): { phrase: string; address: string; lower: string } {
  const doc = JSON.parse(
    readFileSync(new URL("../tests/vectors/addresses.json", import.meta.url), "utf8"),
  );
  const m = doc.mnemonics[0];
  const a = m.accounts.find((x: { index: number }) => x.index === index);
  if (!a) throw new Error(`no account ${index} in addresses.json`);
  return { phrase: m.phrase, address: a.address, lower: a.address_lower };
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
