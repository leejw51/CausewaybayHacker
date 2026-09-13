import { mkdirSync } from "node:fs";
import type { Page } from "@playwright/test";
import {
  atScreen,
  clickButton,
  editorText,
  expect,
  freshAccount,
  identifyOpenQuest,
  login,
  openSelectedNode,
  pickCategory,
  pickLand,
  sceneNow,
  setSource,
  submit,
  test,
  Wire,
  type Account,
} from "./fixtures.js";

/**
 * A wide sweep of every screen, in both orientations, with a screenshot of
 * each so a human can look at the layout. Complements `journey.spec.ts`
 * (which proves the loop on the wire) with the menus, AUTO SELECT, the
 * playground, search, AI mode, the story replay, the display keys, every
 * language, and every code-size step.
 */

const SHOTS = process.env.SWEEP_SHOTS ?? "test-results/sweep";
mkdirSync(SHOTS, { recursive: true });

const BACKEND = process.env.E2E_BACKEND_URL ?? "http://127.0.0.1:5390";

test.describe.configure({ mode: "default" });

const WRONG = 'fn main() { println!("wrong"); }\n';

// ------------------------------------------------------------------ helpers

function project(): string {
  return test.info().project.name;
}

/** Settle, screenshot the whole page, resume. Also report a horizontal scroll. */
async function shot(page: Page, name: string): Promise<string> {
  const path = `${SHOTS}/${project()}-${name}.png`;
  await page.evaluate(() => window.__cwbCapture?.settle(1.0));
  await page.screenshot({ path, fullPage: true });
  const overflow = await page.evaluate(() => ({
    sw: document.documentElement.scrollWidth,
    cw: document.documentElement.clientWidth,
    sh: document.documentElement.scrollHeight,
    ch: document.documentElement.clientHeight,
  }));
  await page.evaluate(() => window.__cwbCapture?.resume());
  const line = `[shot] ${project()}-${name}.png scroll=${overflow.sw}x${overflow.sh} client=${overflow.cw}x${overflow.ch}`;
  console.log(line);
  test.info().annotations.push({ type: "shot", description: line });
  expect(overflow.sw, `${name}: horizontal page scroll`).toBeLessThanOrEqual(overflow.cw);
  return path;
}

/** Cold boot goes title → story → login; a key on each hands over. */
async function toLogin(page: Page): Promise<void> {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    const s = await sceneNow(page);
    if (s === "login") return;
    if (s === "title" || s === "story") await page.keyboard.press("Space");
    await page.waitForTimeout(300);
  }
  throw new Error(`never reached login, at ${await sceneNow(page)}`);
}

/** `atScreen` for the screens the fixture's `Screen` type does not list. */
async function at(page: Page, want: string, timeout = 90_000): Promise<void> {
  await expect
    .poll(async () => sceneNow(page), { timeout, message: `waiting for the ${want} screen` })
    .toBe(want);
  await page.evaluate(() => {
    window.__cwbCapture?.settle();
    window.__cwbCapture?.resume();
  });
}

async function buttonIds(page: Page): Promise<string[]> {
  return page.evaluate(() => (window.__cwbCapture?.buttons() ?? []).map((b) => b.id));
}

async function waitButton(page: Page, prefix: string, timeout = 30_000): Promise<string> {
  let found = "";
  await expect
    .poll(
      async () => {
        const ids = await buttonIds(page);
        found = ids.find((i) => i.startsWith(prefix)) ?? "";
        return found;
      },
      { timeout, message: `waiting for a button starting with ${prefix}` },
    )
    .not.toBe("");
  return found;
}

function flatten(s: string): string {
  return s
    .replace(/\u200b/g, "")
    .split("\n")
    .map((l) => l.replace(/\s+$/, ""))
    .filter((l) => l.length > 0)
    .join("\n")
    .trim();
}

async function waitEditor(page: Page): Promise<string> {
  await page.waitForFunction(
    () =>
      Array.from(document.querySelectorAll(".cm-line")).some(
        (l) => (l.textContent ?? "").trim().length > 0,
      ),
    null,
    { timeout: 30_000 },
  );
  return editorText(page);
}

async function pref(page: Page, key: string): Promise<string | null> {
  return page.evaluate((k) => localStorage.getItem("cwbhacker." + k), key);
}

/** The editor (a DOM overlay) must sit inside the game canvas. */
async function editorInsideCanvas(page: Page, label: string): Promise<void> {
  const ed = await page.locator(".cm-editor").boundingBox();
  const cv = await page.locator("canvas#game").boundingBox();
  const vp = page.viewportSize()!;
  expect(ed, `${label}: editor is visible`).not.toBeNull();
  const msg = `${label}: editor ${JSON.stringify(ed)} vs canvas ${JSON.stringify(cv)} viewport ${vp.width}x${vp.height}`;
  console.log(`[editor] ${msg}`);
  expect(ed!.x, msg).toBeGreaterThanOrEqual(cv!.x - 1);
  expect(ed!.y, msg).toBeGreaterThanOrEqual(cv!.y - 1);
  expect(ed!.x + ed!.width, msg).toBeLessThanOrEqual(cv!.x + cv!.width + 1);
  expect(ed!.y + ed!.height, msg).toBeLessThanOrEqual(cv!.y + cv!.height + 1);
  expect(ed!.width, `${label}: editor has width`).toBeGreaterThan(40);
  expect(ed!.height, `${label}: editor has height`).toBeGreaterThan(20);
}

async function signIn(page: Page, account: Account): Promise<void> {
  await toLogin(page);
  await login(page, account);
}

async function toRustBasicQuest(page: Page, wire: Wire): Promise<string> {
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await openSelectedNode(page);
  const id = await identifyOpenQuest(page, wire);
  expect(id, "the open quest is a rust one").toMatch(/^rust\./);
  return id!;
}

/**
 * Leave the result screen for the map. Reports whether the BACK TO THE MAP
 * button is actually inside the viewport; if it is not, records that as a
 * bug and takes the Enter key instead so the rest of the flow is still
 * exercised.
 */
async function backToMap(page: Page): Promise<void> {
  const info = await page.evaluate(() => {
    const all = window.__cwbCapture?.buttons() ?? [];
    const b = all.find((x) => x.id === "map");
    return { btn: b ?? null, vh: innerHeight, vw: innerWidth, ids: all.map((x) => x.id) };
  });
  const b = info.btn;
  const inside =
    !!b && b.client[1] >= 0 && b.client[1] + b.client[3] <= info.vh && b.client[0] >= 0;
  const line = `[result] ${project()} map button client=${JSON.stringify(b?.client)} viewport=${info.vw}x${info.vh} inside=${inside}`;
  console.log(line);
  test.info().annotations.push({ type: "result-buttons", description: line });
  if (inside) {
    await clickButton(page, "map");
  } else {
    await page.keyboard.press("Enter");
  }
  await atScreen(page, "map");
  expect.soft(inside, `BACK TO THE MAP is not fully inside the viewport: ${line}`).toBe(true);
}

// -------------------------------------------------------------------- tests

test("1+2+4: full flow, persistence, AUTO SELECT after a failure, stats", async ({ page }) => {
  const account = freshAccount();
  const wire = await Wire.as(BACKEND, account);
  try {
    await toLogin(page);
    await shot(page, "01-login");
    await login(page, account);
    await shot(page, "02-lands");

    const questId = await toRustBasicQuest(page, wire);
    console.log(`[flow] opened ${questId}`);
    await page.keyboard.press("Escape");
    await atScreen(page, "map");
    await shot(page, "03-map-fresh");
    await openSelectedNode(page);
    await waitEditor(page);
    await shot(page, "04-quest");

    // ---- a wrong submit first -------------------------------------------
    await setSource(page, WRONG);
    await submit(page);
    await shot(page, "05-result-wrong");
    let history = await wire.history();
    expect(history.length).toBe(1);
    expect(history[0].verdict).not.toBe("accepted");
    expect(history[0].quest_id).toBe(questId);
    console.log(`[flow] wrong verdict = ${history[0].verdict}`);

    // ---- AUTO SELECT goes to the failed quest ---------------------------
    await backToMap(page);
    await clickButton(page, "menu");
    await atScreen(page, "lands");
    const weakest = (await wire.ok("stats.weakest", { limit: 1 })).weakest as {
      quest_id: string;
    }[];
    expect(weakest[0]?.quest_id, "the server's weakest is the failed quest").toBe(questId);
    await clickButton(page, "auto");
    await atScreen(page, "quest");
    const got = (await wire.ok("quest.get", { quest_id: questId })).quest as {
      draft?: string | null;
      starter: string;
    };
    const shown = flatten(await waitEditor(page));
    const expected = flatten(got.draft ?? got.starter);
    expect(shown, "AUTO SELECT opened the quest that beat us (editor shows its draft)").toBe(
      expected,
    );
    await shot(page, "06-auto-select-quest");

    // ---- SOLVE, then SUBMIT ----------------------------------------------
    const before = await editorText(page);
    await clickButton(page, "solve");
    await expect
      .poll(async () => editorText(page), { timeout: 30_000, message: "SOLVE filled the editor" })
      .not.toBe(before);
    await shot(page, "07-quest-solved");
    await submit(page);
    await shot(page, "08-result-accepted");
    history = await wire.history();
    expect(history[0].verdict, "the solved source is accepted").toBe("accepted");
    const node = await wire.node(questId);
    expect(node?.state).toBe("cleared");
    console.log(`[flow] cleared ${questId} stars=${node?.stars}`);

    // ---- back to the map: cleared -----------------------------------------
    await backToMap(page);
    await shot(page, "09-map-cleared");

    // ---- next quest -------------------------------------------------------
    await page.keyboard.press("ArrowRight");
    await page.waitForTimeout(300);
    await openSelectedNode(page);
    await waitEditor(page);
    const next = await identifyOpenQuest(page, wire);
    console.log(`[flow] next quest = ${next}`);
    expect(next, "the next node is a different quest").not.toBe(questId);
    await shot(page, "10-quest-next");
    await page.keyboard.press("Escape");
    await atScreen(page, "map");

    // ---- reload: still cleared -------------------------------------------
    await page.reload();
    await page.waitForFunction(() => typeof window.__cwbCapture?.settle === "function");
    await expect
      .poll(async () => sceneNow(page), { timeout: 60_000 })
      .not.toMatch(/^(boot|login|title|story)$/);
    const after = await sceneNow(page);
    console.log(`[flow] after reload the scene is ${after}`);
    if (after === "quest") {
      await page.keyboard.press("Escape");
    } else if (after === "lands") {
      await pickLand(page, "rust");
      await pickCategory(page, "basic");
    }
    await atScreen(page, "map");
    await shot(page, "11-map-after-reload");
    expect((await wire.node(questId))?.state, "cleared after reload").toBe("cleared");

    // ---- stats reflect it ------------------------------------------------
    await page.keyboard.press("F5");
    await at(page, "stats");
    await shot(page, "12-stats");
    const summary = (await wire.ok("stats.summary", {})) as { cleared: number; attempts: number };
    console.log(`[flow] stats.summary cleared=${summary.cleared} attempts=${summary.attempts}`);
    expect(summary.cleared).toBeGreaterThanOrEqual(1);
    expect(summary.attempts).toBeGreaterThanOrEqual(2);
    for (const tab of ["shelf", "log", "drill"]) {
      await clickButton(page, `tab:${tab}`);
      await page.waitForTimeout(400);
      await shot(page, `12-stats-${tab}`);
    }
    await clickButton(page, "aux:maps");
    await atScreen(page, "lands");
  } finally {
    wire.close();
  }
});

test("3g: CODE mode leaves the player on the quest screen, signed in", async ({ page }) => {
  // The header is not drawn in CODE mode, and `app.logoutRect` is only ever
  // cleared by `header()`. Left over from the previous frame it sits in the
  // top right corner — under DONE — and `App`'s pointer handler tests it
  // before the scene sees the press, so the button that ends a writing
  // session logged the player out. On a desktop the chip carries the address
  // as well as the word, which makes it wide enough to swallow DONE whole.
  const account = freshAccount();
  await login(page, account);
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await openSelectedNode(page);
  const code = await page.evaluate(() => window.__cwbCapture!.buttonAt("focus"));
  expect(code).not.toBeNull();
  await page.mouse.click(code![0], code![1]);
  await page.waitForTimeout(700);
  await shot(page, "60-code-mode");
  const done = await page.evaluate(() => window.__cwbCapture!.buttonAt("unfocus"));
  expect(done).not.toBeNull();
  // The controls a writing session actually uses are on this screen too.
  const onCode = await buttonIds(page);
  for (const id of ["run", "format", "undo", "redo", "answer", "unfocus"]) {
    expect(onCode).toContain(id);
  }

  // ANSWER: the reference solution as ghost text *behind* what is typed —
  // the buffer is untouched, the ghost is in the editor's own layout, and
  // what has been typed instead of the answer is marked.
  const answer = await page.evaluate(() => window.__cwbCapture!.buttonAt("answer"));
  // The *document*, with the ghost taken back out. `editorText` scrapes the
  // rendered lines, and the ghost is rendered inside them on purpose — which
  // is exactly why the buffer has to be read without it here.
  const docText = () =>
    page.evaluate(() =>
      Array.from(document.querySelectorAll(".cm-line"))
        .map((line) => {
          const copy = line.cloneNode(true) as HTMLElement;
          copy.querySelectorAll(".cwb-ghost").forEach((gh) => gh.remove());
          return (copy.textContent ?? "").replace(/\u200b/g, "");
        })
        .join("\n"),
    );
  const before = await docText();
  expect(before.trim().length).toBeGreaterThan(0);
  await page.mouse.click(answer![0], answer![1]);
  await expect
    .poll(async () => page.evaluate(() => document.querySelectorAll(".cwb-ghost").length), {
      timeout: 30_000,
      message: "waiting for the answer ghost",
    })
    .toBeGreaterThan(0);
  // The starter goes: it is the server's boilerplate, and against the answer
  // it is a screenful of red nobody typed.
  expect((await docText()).trim()).toBe("");
  // But the ghost is there to type over, so the *rendered* lines are not.
  expect(await editorText(page)).not.toBe("");
  await shot(page, "62-answer-ghost");

  // TAB takes the rest of the line. Pressed until it stops giving, it lands
  // exactly on the answer — checked here, on a clean buffer, because past a
  // divergence TAB is supposed to refuse instead (see below).
  const ghosts = () => page.evaluate(() => document.querySelectorAll(".cwb-ghost").length);
  for (let i = 0; i < 40 && (await ghosts()) > 0; i++) {
    await page.keyboard.press("Tab");
    await page.waitForTimeout(120);
  }
  await page.waitForTimeout(400);
  expect(await ghosts()).toBe(0);
  // Exactly the answer, and nothing past it: a TAB with nothing left to
  // complete is consumed rather than left to indent a buffer that is right.
  expect(await page.evaluate(() => document.querySelectorAll(".cwb-wrong").length)).toBe(0);
  await shot(page, "64-answer-tabbed");

  // ANSWER shows the solution; it never writes it. Toggle off, type
  // something of the player's own, toggle back on: the writing stays.
  await page.mouse.click(answer![0], answer![1]);
  await page.waitForTimeout(400);
  await page.keyboard.type("let mine = 1;");
  await page.waitForTimeout(300);
  const mine = await docText();
  expect(mine).toContain("let mine = 1;");
  await page.mouse.click(answer![0], answer![1]);
  await page.waitForTimeout(600);
  expect(await docText()).toBe(mine);

  // A character that is not the answer is marked, not swallowed.
  await page.keyboard.press("Control+Home");
  await page.keyboard.type("zz");
  await page.waitForTimeout(500);
  expect(
    await page.evaluate(() => document.querySelectorAll(".cwb-wrong").length),
  ).toBeGreaterThan(0);
  // And TAB refuses while the buffer has stopped being the answer: completing
  // past a mistake would bury it under correct text.
  const stuck = await docText();
  await page.keyboard.press("Tab");
  await page.waitForTimeout(250);
  expect(await docText()).toBe(stuck);
  await shot(page, "63-answer-diverged");

  // The effects are painted on their own layer *over* the editor, because
  // both game canvases are under the overlay and the editor's face is all
  // but opaque. A burst on the game canvas would be a burst nobody sees.
  const sparks = await page.evaluate(() => {
    const el = document.querySelector(".cwb-sparks") as HTMLCanvasElement | null;
    if (!el) return null;
    const ed = document.querySelector(".cwb-editor");
    return {
      over: !!(ed && el.compareDocumentPosition(ed) & Node.DOCUMENT_POSITION_PRECEDING),
      clicks: getComputedStyle(el).pointerEvents,
    };
  });
  expect(sparks).not.toBeNull();
  expect(sparks!.over).toBe(true);
  expect(sparks!.clicks).toBe("none");

  await page.mouse.click(done![0], done![1]);
  await page.waitForTimeout(900);
  expect(await sceneNow(page)).toBe("quest");
  expect(await page.evaluate(() => window.__cwbCapture!.buttonAt("focus"))).not.toBeNull();
  await shot(page, "61-done-back-on-the-quest");
});

test("4b: AUTO SELECT with no failures says so and stays put", async ({ page }) => {
  const account = freshAccount();
  await signIn(page, account);
  await clickButton(page, "auto");
  await page.waitForTimeout(1500);
  expect(await sceneNow(page), "stayed on lands").toBe("lands");
  await shot(page, "13-auto-select-none");
});

test("3a: NEW WALLET via the UI signs in, and STORY replays", async ({ page }) => {
  await toLogin(page);
  // The opening, on demand.
  await clickButton(page, "story");
  await at(page, "story");
  await page.waitForTimeout(2500);
  await shot(page, "14-story-replay");
  await page.keyboard.press("Space");
  await atScreen(page, "login");

  await clickButton(page, "new");
  await page.waitForTimeout(500);
  await shot(page, "15-new-wallet");
  await clickButton(page, "keep");
  await atScreen(page, "lands");
  await shot(page, "16-lands-new-wallet");
  await page.keyboard.press("F3");
  await atScreen(page, "login");
  await expect(page.locator("textarea.cwb-field")).toHaveValue("");
});

test("3b: search — type, submit, results, open one", async ({ page }) => {
  const account = freshAccount();
  await signIn(page, account);
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  await clickButton(page, "aux:search");
  await at(page, "search");
  await shot(page, "17-search-empty");
  const field = page.locator("textarea.cwb-field");
  await expect(field).toBeVisible();
  await field.fill("print");
  await clickButton(page, "go");
  // The index is milestone 2: the server answers `not_found`. If a hit ever
  // appears, open it; otherwise record the unbuilt notice and move on.
  await page.waitForTimeout(2500);
  let hit = (await buttonIds(page)).find((i) => i.startsWith("hit:")) ?? "";
  console.log(`[search] after SEARCH: hit=${hit || "(none)"}; ids=${(await buttonIds(page)).join(",")}`);
  await shot(page, "18-search-results");
  await clickButton(page, "mode:bm25");
  await clickButton(page, "go");
  await page.waitForTimeout(2500);
  hit = hit || ((await buttonIds(page)).find((i) => i.startsWith("hit:")) ?? "");
  await shot(page, "18-search-results-text");
  test.info().annotations.push({
    type: "search",
    description: hit ? `opened ${hit}` : "search.query is not built on this server (milestone 2)",
  });
  if (hit) {
    await clickButton(page, hit);
    await atScreen(page, "quest");
    await waitEditor(page);
    await shot(page, "19-search-opened-quest");
    await page.keyboard.press("Escape");
    await atScreen(page, "map");
  } else {
    await clickButton(page, "clear");
    await expect(field).toHaveValue("");
    await clickButton(page, "aux:maps");
    await atScreen(page, "lands");
  }
});

test("3c: AI mode", async ({ page }) => {
  const account = freshAccount();
  await signIn(page, account);
  await page.keyboard.press("F6");
  await at(page, "ai");
  await page.waitForTimeout(1000);
  await shot(page, "20-ai");
  console.log(`[ai] buttons: ${(await buttonIds(page)).join(",")}`);
  for (const m of ["repeat", "spaced", "weakness"]) {
    const ids = await buttonIds(page);
    if (ids.includes(`mode:${m}`)) {
      await clickButton(page, `mode:${m}`);
      await page.waitForTimeout(300);
    }
  }
  await clickButton(page, "start");
  await page.waitForTimeout(2500);
  const scene = await sceneNow(page);
  const ids = await buttonIds(page);
  console.log(`[ai] after START scene=${scene} buttons=${ids.join(",")}`);
  await shot(page, "21-ai-started");
  if (ids.includes("go")) {
    await clickButton(page, "go");
    await atScreen(page, "quest");
    await waitEditor(page);
    await shot(page, "22-ai-quest");
    await page.keyboard.press("Escape");
  }
  const s2 = await sceneNow(page);
  console.log(`[ai] ended on ${s2}`);
  if (s2 === "ai") await clickButton(page, "aux:maps");
});

test("3d: playground — write code, run, see the output", async ({ page }) => {
  const account = freshAccount();
  await signIn(page, account);
  // Listen to the wire from this page, then reload so the socket is caught.
  const received: string[] = [];
  page.on("websocket", (ws) => ws.on("framereceived", (f) => received.push(String(f.payload))));
  await page.reload();
  await page.waitForFunction(() => typeof window.__cwbCapture?.settle === "function");
  await expect
    .poll(async () => sceneNow(page), { timeout: 60_000 })
    .not.toMatch(/^(boot|login|title|story)$/);
  if ((await sceneNow(page)) !== "lands") {
    await page.keyboard.press("Escape");
    await page.waitForTimeout(500);
    if ((await sceneNow(page)) === "map") await clickButton(page, "menu");
  }
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await at(page, "playground");
  await waitEditor(page);
  await shot(page, "23-playground");
  await setSource(page, 'fn main() { println!("hello from playground {}", 6 * 7); }\n');
  await clickButton(page, "run");
  await expect
    .poll(
      () => received.some((f) => f.includes("hello from playground 42")),
      { timeout: 180_000, message: "the run's stdout came back over the wire" },
    )
    .toBe(true);
  await page.waitForTimeout(800);
  await shot(page, "24-playground-output");
  await clickButton(page, "back");
  await page.waitForTimeout(800);
  console.log(`[playground] BACK went to ${await sceneNow(page)}`);
  expect(await sceneNow(page)).not.toBe("playground");
});

test("3e: display controls — orientation (F1), CRT (F2), fullscreen, language (F7)", async ({
  page,
}) => {
  const account = freshAccount();
  await signIn(page, account);

  // Orientation cycles landscape → portrait → auto.
  const seen: string[] = [];
  for (let i = 0; i < 3; i++) {
    await page.keyboard.press("F1");
    await page.waitForTimeout(400);
    const o = await page.evaluate(() => window.__cwbCapture!.orientation());
    const saved = await pref(page, "orientation");
    seen.push(`${o}/${saved}`);
    await shot(page, `25-orient-${i}-${o}`);
    expect(await sceneNow(page)).toBe("lands");
  }
  console.log(`[display] F1 cycle: ${seen.join(" -> ")}`);
  expect(seen.some((s) => s.startsWith("landscape"))).toBe(true);
  expect(seen.some((s) => s.startsWith("portrait"))).toBe(true);
  expect(seen[2].endsWith("/auto"), "third press returns to auto").toBe(true);

  // CRT.
  const crtBefore = await pref(page, "crt");
  await page.keyboard.press("F2");
  await page.waitForTimeout(300);
  const crtAfter = await pref(page, "crt");
  console.log(`[display] F2 crt: ${crtBefore} -> ${crtAfter}`);
  expect(crtAfter).not.toBe(crtBefore);
  await shot(page, "26-crt-toggled");
  await page.keyboard.press("F2");

  // Fullscreen: F11 from any screen. Headless Chromium grants the request
  // and reports it through `document.fullscreenElement`, which is what the
  // app reads, so the toggle is observable even without a real display.
  await page.keyboard.press("F11");
  await page.waitForTimeout(500);
  const fsOn = await page.evaluate(() => !!document.fullscreenElement);
  await page.keyboard.press("F11");
  await page.waitForTimeout(500);
  const fsOff = await page.evaluate(() => !!document.fullscreenElement);
  console.log(`[display] F11 fullscreen: ${fsOn} -> ${fsOff}`);
  expect(fsOn).toBe(true);
  expect(fsOff).toBe(false);

  // Language: F7 walks every locale round.
  const order: string[] = [];
  for (let i = 0; i < 6; i++) {
    await page.keyboard.press("F7");
    await page.waitForTimeout(1200); // the CJK face is a download
    const loc = (await pref(page, "locale")) ?? "?";
    order.push(loc);
    await shot(page, `27-lang-${loc}-lands`);
    expect(await sceneNow(page)).toBe("lands");
  }
  console.log(`[display] F7 cycle: ${order.join(" -> ")}`);
  expect(order).toEqual(["ko", "yue", "zh", "ja", "cs", "en"]);
});

test("3f: every language on the login screen, via the LANG button", async ({ page }) => {
  await toLogin(page);
  const order: string[] = [];
  for (let i = 0; i < 6; i++) {
    await clickButton(page, "lang");
    await page.waitForTimeout(1200);
    const loc = (await pref(page, "locale")) ?? "?";
    order.push(loc);
    await shot(page, `28-lang-${loc}-login`);
  }
  console.log(`[lang] LANG button cycle: ${order.join(" -> ")}`);
  expect(new Set(order).size).toBe(6);

  // And the fullscreen button beside it, which says the state it moves to.
  const ids = await buttonIds(page);
  expect(ids).toContain("fullscreen");
  await clickButton(page, "fullscreen");
  await page.waitForTimeout(600);
  expect(await page.evaluate(() => !!document.fullscreenElement)).toBe(true);
  await shot(page, "29-fullscreen-login");
  await clickButton(page, "fullscreen");
  await page.waitForTimeout(600);
  expect(await page.evaluate(() => !!document.fullscreenElement)).toBe(false);
});

test("5: every code-size step on the quest screen (en)", async ({ page }) => {
  const account = freshAccount();
  const wire = await Wire.as(BACKEND, account);
  try {
    await signIn(page, account);
    await toRustBasicQuest(page, wire);
    await waitEditor(page);
    // Down to the floor.
    for (let i = 0; i < 4; i++) {
      await clickButton(page, "fontdown");
      await page.waitForTimeout(150);
    }
    const steps: string[] = [];
    let last = "";
    for (let i = 0; i < 20; i++) {
      const mul = (await pref(page, "quest.font")) ?? "1";
      if (mul === last) break;
      last = mul;
      const pct = Math.round(Number(mul) * 100);
      steps.push(String(pct));
      await page.waitForTimeout(300);
      await shot(page, `30-font-${String(pct).padStart(3, "0")}`);
      await editorInsideCanvas(page, `font ${pct}%`);
      await clickButton(page, "fontup");
      await page.waitForTimeout(150);
    }
    console.log(`[font] steps: ${steps.join(", ")}`);
    expect(steps[0]).toBe("70");
    expect(steps[steps.length - 1]).toBe("240");
  } finally {
    wire.close();
  }
});

test("5b: Korean (CJK) at the smallest, default and largest code size, plus the other screens", async ({
  page,
}) => {
  const account = freshAccount();
  const wire = await Wire.as(BACKEND, account);
  try {
    await signIn(page, account);
    await page.keyboard.press("F7"); // en -> ko
    await page.waitForTimeout(1500);
    expect(await pref(page, "locale")).toBe("ko");
    await shot(page, "40-ko-lands");
    await pickLand(page, "rust");
    await pickCategory(page, "basic");
    await shot(page, "41-ko-map");
    await openSelectedNode(page);
    await waitEditor(page);
    await shot(page, "42-ko-quest-100");
    await editorInsideCanvas(page, "ko 100%");
    for (let i = 0; i < 4; i++) await clickButton(page, "fontdown");
    await page.waitForTimeout(300);
    await shot(page, "42-ko-quest-070");
    await editorInsideCanvas(page, "ko 70%");
    for (let i = 0; i < 14; i++) await clickButton(page, "fontup");
    await page.waitForTimeout(300);
    expect(await pref(page, "quest.font")).toBe("2.4");
    await shot(page, "42-ko-quest-240");
    await editorInsideCanvas(page, "ko 240%");
    // The console drawer and the hint, at the biggest size.
    await clickButton(page, "console");
    await page.waitForTimeout(300);
    await shot(page, "43-ko-quest-240-console");
    await clickButton(page, "console");
    // A result and the stats in Korean.
    await setSource(page, WRONG);
    await submit(page);
    await shot(page, "44-ko-result");
    await backToMap(page);
    await page.keyboard.press("F5");
    await at(page, "stats");
    await shot(page, "45-ko-stats");
    await page.keyboard.press("F4");
    await at(page, "search");
    await shot(page, "46-ko-search");
    await page.keyboard.press("F6");
    await at(page, "ai");
    await page.waitForTimeout(800);
    await shot(page, "47-ko-ai");
    await clickButton(page, "aux:maps");
    await atScreen(page, "lands");
    await clickButton(page, "playground");
    await at(page, "playground");
    await waitEditor(page);
    await shot(page, "48-ko-playground");
  } finally {
    wire.close();
  }
});

test("5c: the other CJK locales and Czech on the map and quest", async ({ page }) => {
  const account = freshAccount();
  const wire = await Wire.as(BACKEND, account);
  try {
    await signIn(page, account);
    await pickLand(page, "rust");
    await pickCategory(page, "basic");
    // en -> ko -> yue -> zh -> ja -> cs
    for (const loc of ["ko", "yue", "zh", "ja", "cs"]) {
      await page.keyboard.press("F7");
      await page.waitForTimeout(1200);
      expect(await pref(page, "locale")).toBe(loc);
      if (loc === "ko") continue; // covered above
      await shot(page, `50-${loc}-map`);
      await openSelectedNode(page);
      await waitEditor(page);
      await shot(page, `51-${loc}-quest`);
      await page.keyboard.press("Escape");
      await atScreen(page, "map");
    }
  } finally {
    wire.close();
  }
});
