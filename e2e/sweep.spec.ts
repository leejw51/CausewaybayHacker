import { mkdirSync } from "node:fs";
import type { Page } from "@playwright/test";
import {
  atScreen,
  choicesShown,
  clickButton,
  editorText,
  expect,
  freshAccount,
  login,
  openedQuestId,
  openSelectedNode,
  pickCategory,
  pickLand,
  pickOnScreen,
  sceneNow,
  sentFrames,
  setSource,
  test,
  Wire,
  type Account,
  pressWhenStill,
} from "./fixtures.js";

/**
 * A wide sweep of every screen, in both orientations, with a screenshot of
 * each so a human can look at the layout. Complements `journey.spec.ts`
 * (which proves the loop on the wire) with the menus, AUTO SELECT, the
 * playground, search, AI mode, the story replay, the display keys, every
 * language, and every text-size step.
 *
 * A quest is picked, not typed (SPEC §0): four choices, one right, and no
 * editor on the quest screen. So the flow trains by pressing choices, and
 * the quest screen's layout checks are about the choices; CODE mode is the
 * playground's.
 */

const SHOTS = process.env.SWEEP_SHOTS ?? "test-results/sweep";
mkdirSync(SHOTS, { recursive: true });

// The server the wire checks ask. The same one the page is served from when
// `E2E_BASE_URL` points at a backend (the release build on its own port):
// without that fallback a run against an isolated server asked the default
// :5390 — a different database — and read no history for a real submit.
const BACKEND =
  process.env.E2E_BACKEND_URL ??
  process.env.E2E_BASE_URL ??
  "http://127.0.0.1:5390";

test.describe.configure({ mode: "default" });

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
  expect(overflow.sw, `${name}: horizontal page scroll`).toBeLessThanOrEqual(
    overflow.cw,
  );
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
    .poll(async () => sceneNow(page), {
      timeout,
      message: `waiting for the ${want} screen`,
    })
    .toBe(want);
  await page.evaluate(() => {
    window.__cwbCapture?.settle();
    window.__cwbCapture?.resume();
  });
}

async function buttonIds(page: Page): Promise<string[]> {
  return page.evaluate(() =>
    (window.__cwbCapture?.buttons() ?? []).map((b) => b.id),
  );
}

async function waitButton(
  page: Page,
  prefix: string,
  timeout = 30_000,
): Promise<string> {
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

/**
 * The quest screen is a pick (SPEC §0): the four choices are drawn inside the
 * game canvas, across its width, every one reachable, and there is no editor
 * over them.
 */
async function choicesInsideCanvas(page: Page, label: string): Promise<void> {
  await choicesShown(page);
  await expect(page.locator(".cm-content"), `${label}: no editor on a pick`).toBeHidden();
  const cv = (await page.locator("canvas#game").boundingBox())!;
  const rects = await page.evaluate(() =>
    window.__cwbCapture!
      .buttons()
      .filter((b) => b.id.startsWith("choice:"))
      .map((b) => b.client),
  );
  const msg = `${label}: choices ${JSON.stringify(rects)} vs canvas ${JSON.stringify(cv)}`;
  console.log(`[choices] ${msg}`);
  // Held upright, a tall brief keeps some of the four under the fold (they
  // were each reached above); those on screen now are measured. One cut by
  // the panel's edge is only as tall as the part that shows.
  expect(rects.length, msg).toBeGreaterThan(0);
  for (const r of rects) {
    expect(r[0], msg).toBeGreaterThanOrEqual(cv.x - 1);
    expect(r[0] + r[2], msg).toBeLessThanOrEqual(cv.x + cv.width + 1);
    expect(r[1], msg).toBeGreaterThanOrEqual(cv.y - 1);
    expect(r[1] + r[3], msg).toBeLessThanOrEqual(cv.y + cv.height + 1);
    expect(r[2], `${label}: a choice has width`).toBeGreaterThan(40);
  }
  expect(
    Math.max(...rects.map((r) => r[3])),
    `${label}: a choice has height`,
  ).toBeGreaterThan(20);
}

async function signIn(page: Page, account: Account): Promise<void> {
  await toLogin(page);
  await login(page, account);
}

/** Open the selected RUST × BASIC node, and say which quest the page asked for. */
async function toRustBasicQuest(page: Page): Promise<string> {
  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  const since = sentFrames().length;
  await openSelectedNode(page);
  const id = await openedQuestId(since);
  expect(id, "the open quest is a rust one").toMatch(/^rust\./);
  return id;
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
    return {
      btn: b ?? null,
      vh: innerHeight,
      vw: innerWidth,
      ids: all.map((x) => x.id),
    };
  });
  const b = info.btn;
  const inside =
    !!b &&
    b.client[1] >= 0 &&
    b.client[1] + b.client[3] <= info.vh &&
    b.client[0] >= 0;
  const line = `[result] ${project()} map button client=${JSON.stringify(b?.client)} viewport=${info.vw}x${info.vh} inside=${inside}`;
  console.log(line);
  test.info().annotations.push({ type: "result-buttons", description: line });
  if (inside) {
    await clickButton(page, "map");
  } else {
    await page.keyboard.press("Enter");
  }
  await atScreen(page, "map");
  expect
    .soft(inside, `BACK TO THE MAP is not fully inside the viewport: ${line}`)
    .toBe(true);
}

// -------------------------------------------------------------------- tests

test("1+2+4: full flow, persistence, AUTO SELECT after a failure, stats", async ({
  page,
}) => {
  const account = freshAccount();
  const wire = await Wire.as(BACKEND, account);
  try {
    await toLogin(page);
    await shot(page, "01-login");
    await login(page, account);
    await shot(page, "02-lands");

    const questId = await toRustBasicQuest(page);
    console.log(`[flow] opened ${questId}`);
    await page.keyboard.press("Escape");
    await atScreen(page, "map");
    await shot(page, "03-map-fresh");
    let since = sentFrames().length;
    await openSelectedNode(page);
    expect(await openedQuestId(since)).toBe(questId);
    await choicesShown(page);
    await shot(page, "04-quest");

    // ---- a wrong pick first: recorded, and the player stays put ---------
    await pickOnScreen(page, wire, questId, "wrong");
    await shot(page, "05-quest-missed");
    let history = await wire.history();
    expect(history.length).toBe(1);
    expect(history[0].verdict).not.toBe("accepted");
    expect(history[0].quest_id).toBe(questId);
    console.log(`[flow] wrong verdict = ${history[0].verdict}`);

    // ---- AUTO SELECT goes to the failed quest ---------------------------
    await page.keyboard.press("Escape");
    await atScreen(page, "map");
    await clickButton(page, "menu");
    await atScreen(page, "lands");
    const weakest = (await wire.ok("stats.weakest", { limit: 1 })).weakest as {
      quest_id: string;
    }[];
    expect(
      weakest[0]?.quest_id,
      "the server's weakest is the failed quest",
    ).toBe(questId);
    // AUTO SELECT goes where the server's rule says (PROTOCOL §4.14d): the
    // first street not cleared, in road order, comes before the ones owed —
    // and on a fresh wallet that is not the failed one.
    const next = (await wire.ok("stats.next", { land: "rust" })).next as {
      quest_id: string;
    };
    since = sentFrames().length;
    await clickButton(page, "auto");
    await atScreen(page, "quest");
    expect(
      await openedQuestId(since),
      "AUTO SELECT opened the street the server names",
    ).toBe(next.quest_id);
    await choicesShown(page);
    await shot(page, "06-auto-select-quest");

    // ---- back to the failed quest, by the map ------------------------------
    if (next.quest_id !== questId) {
      await page.keyboard.press("Escape");
      await atScreen(page, "map");
      await clickButton(page, "menu");
      await atScreen(page, "lands");
      await pickLand(page, "rust");
      await pickCategory(page, "basic");
      since = sentFrames().length;
      await openSelectedNode(page);
      expect(await openedQuestId(since)).toBe(questId);
      await choicesShown(page);
    }

    // ---- the right pick ---------------------------------------------------
    await pickOnScreen(page, wire, questId, "right");
    await shot(page, "08-result-accepted");
    history = await wire.history();
    expect(history[0].verdict, "the right choice is accepted").toBe(
      "accepted",
    );
    const node = await wire.node(questId);
    expect(node?.state).toBe("cleared");
    console.log(`[flow] cleared ${questId} stars=${node?.stars}`);

    // ---- back to the map: cleared -----------------------------------------
    await backToMap(page);
    await shot(page, "09-map-cleared");

    // ---- next quest -------------------------------------------------------
    await page.keyboard.press("ArrowRight");
    await page.waitForTimeout(300);
    since = sentFrames().length;
    await openSelectedNode(page);
    const following = await openedQuestId(since);
    await choicesShown(page);
    console.log(`[flow] next quest = ${following}`);
    expect(following, "the next node is a different quest").not.toBe(questId);
    await shot(page, "10-quest-next");
    await page.keyboard.press("Escape");
    await atScreen(page, "map");

    // ---- reload: still cleared -------------------------------------------
    await page.reload();
    await page.waitForFunction(
      () => typeof window.__cwbCapture?.settle === "function",
    );
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
    expect((await wire.node(questId))?.state, "cleared after reload").toBe(
      "cleared",
    );

    // ---- stats reflect it ------------------------------------------------
    await page.keyboard.press("F5");
    await at(page, "stats");
    await shot(page, "12-stats");
    const summary = (await wire.ok("stats.summary", {})) as {
      cleared: number;
      attempts: number;
    };
    console.log(
      `[flow] stats.summary cleared=${summary.cleared} attempts=${summary.attempts}`,
    );
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

test("3g: CODE mode leaves the player on the playground, signed in", async ({
  page,
}) => {
  // The header is not drawn in CODE mode, and `app.logoutRect` is only ever
  // cleared by `header()`. Left over from the previous frame it sits in the
  // top right corner — under DONE — and `App`'s pointer handler tests it
  // before the scene sees the press, so the button that ends a writing
  // session logged the player out. On a desktop the chip carries the address
  // as well as the word, which makes it wide enough to swallow DONE whole.
  //
  // This was the quest screen's CODE mode, with its ANSWER, BLANKS and +LINE
  // drills. A quest is picked now, not typed (SPEC §0), so the drills went
  // with its editor and CODE mode is the playground's.
  const account = freshAccount();
  await login(page, account);
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await at(page, "playground");
  await waitEditor(page);
  await clickButton(page, "code");
  await page.waitForTimeout(700);
  await shot(page, "60-code-mode");
  const done = await page.evaluate(() =>
    window.__cwbCapture!.buttonAt("unfocus"),
  );
  expect(done).not.toBeNull();
  // The controls a writing session actually uses are on this screen too.
  const onCode = await buttonIds(page);
  for (const id of ["run", "format", "undo", "redo", "unfocus"]) {
    expect(onCode).toContain(id);
  }

  // The effects are painted on their own layer *over* the editor, because
  // both game canvases are under the overlay and the editor's face is all
  // but opaque. A burst on the game canvas would be a burst nobody sees.
  const sparks = await page.evaluate(() => {
    const el = document.querySelector(
      ".cwb-sparks",
    ) as HTMLCanvasElement | null;
    if (!el) return null;
    const ed = document.querySelector(".cwb-editor");
    return {
      over: !!(
        ed && el.compareDocumentPosition(ed) & Node.DOCUMENT_POSITION_PRECEDING
      ),
      clicks: getComputedStyle(el).pointerEvents,
    };
  });
  expect(sparks).not.toBeNull();
  expect(sparks!.over).toBe(true);
  expect(sparks!.clicks).toBe("none");

  await page.mouse.click(done![0], done![1]);
  await page.waitForTimeout(900);
  expect(await sceneNow(page)).toBe("playground");
  expect(
    await page.evaluate(() => window.__cwbCapture!.buttonAt("code")),
  ).not.toBeNull();
  await shot(page, "61-done-back-on-the-playground");
});

test("4b: AUTO SELECT with no failures says so and stays put", async ({
  page,
}) => {
  const account = freshAccount();
  await signIn(page, account);
  await clickButton(page, "auto");
  await page.waitForTimeout(1500);
  expect(await sceneNow(page), "stayed on lands").toBe("lands");
  await shot(page, "13-auto-select-none");
});

test("3a: NEW WALLET via the UI signs in, and STORY replays", async ({
  page,
}) => {
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
  console.log(
    `[search] after SEARCH: hit=${hit || "(none)"}; ids=${(await buttonIds(page)).join(",")}`,
  );
  await shot(page, "18-search-results");
  await clickButton(page, "mode:bm25");
  await clickButton(page, "go");
  await page.waitForTimeout(2500);
  hit =
    hit || ((await buttonIds(page)).find((i) => i.startsWith("hit:")) ?? "");
  await shot(page, "18-search-results-text");
  test.info().annotations.push({
    type: "search",
    description: hit
      ? `opened ${hit}`
      : "search.query is not built on this server (milestone 2)",
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
  page.on("websocket", (ws) =>
    ws.on("framereceived", (f) => received.push(String(f.payload))),
  );
  await page.reload();
  await page.waitForFunction(
    () => typeof window.__cwbCapture?.settle === "function",
  );
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
  await setSource(
    page,
    'fn main() { println!("hello from playground {}", 6 * 7); }\n',
  );
  // RUN sits on the rows SAVE reflows; see `pressWhenStill`.
  await pressWhenStill(page, "run");
  await expect
    .poll(() => received.some((f) => f.includes("hello from playground 42")), {
      timeout: 180_000,
      message: "the run's stdout came back over the wire",
    })
    .toBe(true);
  await page.waitForTimeout(800);
  await shot(page, "24-playground-output");

  // Code size. Measured off the rendered editor rather than off the button,
  // because a size control that draws its own buttons and changes nothing is
  // exactly the failure worth catching.
  const codePx = () =>
    page.evaluate(() => {
      const el = document.querySelector(".cm-content") as HTMLElement | null;
      return el ? parseFloat(getComputedStyle(el).fontSize) : 0;
    });
  const beforeFont = await codePx();
  await clickButton(page, "fontup");
  await page.waitForTimeout(500);
  await clickButton(page, "fontup");
  await page.waitForTimeout(500);
  const bigger = await codePx();
  await clickButton(page, "fontdown");
  await page.waitForTimeout(500);
  const smaller = await codePx();
  console.log(
    `[playground] code size ${beforeFont} -> ${bigger} -> ${smaller}`,
  );
  expect(bigger, "A+ makes the code bigger").toBeGreaterThan(beforeFont);
  expect(smaller, "A- takes it back down").toBeLessThan(bigger);
  // It is one preference for every screen, so it survives a visit to
  // another screen and back.
  expect(await pref(page, "ui.text")).not.toBe("");

  // The code face, cycled by a button that says which face it is. Measured
  // off the rendered editor: a face button that changes a label and not the
  // glyphs is the failure worth catching, and it looks identical.
  const faceOf = () =>
    page.evaluate(() => {
      const el = document.querySelector(".cm-content") as HTMLElement | null;
      return el
        ? getComputedStyle(el).fontFamily.split(",")[0].replace(/"/g, "")
        : "";
    });
  const colsOf = async () =>
    page.evaluate(() => {
      const el = document.querySelector(".cm-content") as HTMLElement | null;
      if (!el) return 0;
      const st = getComputedStyle(el);
      const g = document.createElement("canvas").getContext("2d")!;
      g.font = `${st.fontSize} ${st.fontFamily}`;
      const adv = g.measureText("MMMMMMMMMM").width / 10;
      return Math.round(el.getBoundingClientRect().width / adv);
    });
  const face0 = await faceOf();
  const cols0 = await colsOf();
  const px0 = await codePx();
  await clickButton(page, "face");
  await page.waitForTimeout(700);
  const face1 = await faceOf();
  const cols1 = await colsOf();
  // The next face is set at 0.68 of VT323's size (`CODE_FACE_SCALE`), once.
  // The editor used to apply that factor a second time in CSS, which drew
  // IOSEVKA at 0.46 — under half the size of the brief beside it.
  const px1 = await codePx();
  expect(px1 / px0, `${face1} is scaled once, not twice`).toBeGreaterThan(0.6);
  await clickButton(page, "face");
  await page.waitForTimeout(700);
  const face2 = await faceOf();
  const cols2 = await colsOf();
  console.log(
    `[playground] columns ${face0}=${cols0} ${face1}=${cols1} ${face2}=${cols2}`,
  );
  console.log(`[playground] code face ${face0} -> ${face1} -> ${face2}`);
  expect(face1, "the face button changes the face").not.toBe(face0);
  expect(face2, "and again, to a third").not.toBe(face1);
  expect(
    await pref(page, "quest.face"),
    "the choice is remembered",
  ).toBeTruthy();
  // Round the cycle and back to where it started: seven faces, two pressed.
  // The four downloadable ones are fetched on the press, so each gets time.
  for (let k = 0; k < 5; k++) {
    await clickButton(page, "face");
    await page.waitForTimeout(1200);
  }
  expect(await faceOf(), "the cycle comes back round").toBe(face0);

  // Which compiler is live, on the button itself. The row hand-paints the
  // chosen land in its own colour; `Buttons.draw` used to repaint every
  // registered item, so the lit box was covered by a plain button and all
  // four looked identical whatever was selected.
  // Sampled just inside the button's left edge rather than at its middle:
  // the middle is where the label is, so a centre pixel reports the colour
  // of a glyph or of the gap between two, depending on the word. Ten virtual
  // pixels in: past the six-pixel bevel (`panel`), short of the label, which
  // starts half the button's side padding in — a fraction of the width lands
  // on one or the other depending on how long the word is.
  const landPixels = async (id: string) => {
    const b = await page.evaluate(
      (b) => window.__cwbCapture!.buttons().find((x) => x.id === b) ?? null,
      id,
    );
    if (!b) return null;
    return page.evaluate(
      ([[x, y, w, h], vw]) => {
        const c = document.querySelector("#game") as HTMLCanvasElement;
        const g = c.getContext("2d")!;
        const r = c.getBoundingClientRect();
        const px = Math.round(
          ((x + (w / vw) * 10 - r.left) / r.width) * c.width,
        );
        const py = Math.round(((y + h * 0.5 - r.top) / r.height) * c.height);
        const d = g.getImageData(px, py, 1, 1).data;
        return `${d[0]},${d[1]},${d[2]}`;
      },
      [b.client, b.rect[2]] as const,
    );
  };
  const rustLit = await landPixels("rust");
  const goUnlit = await landPixels("go");
  expect(rustLit, "the selected land is painted").not.toBeNull();
  expect(
    rustLit,
    "the chosen land does not look like an unchosen one",
  ).not.toBe(goUnlit);
  await clickButton(page, "go");
  await page.waitForTimeout(700);
  const goLit = await landPixels("go");
  const rustUnlit = await landPixels("rust");
  console.log(
    `[playground] lands rust ${rustLit}->${rustUnlit}, go ${goUnlit}->${goLit}`,
  );
  // Each land wears its own colour when it is live — rust orange, go cyan —
  // so the lit ones differ from each other as well as from the unlit.
  expect(goLit, "GO lights when GO is chosen").not.toBe(goUnlit);
  expect(rustUnlit, "RUST goes dark when GO is chosen").toBe(goUnlit);
  expect(goLit).not.toBe(rustLit);
  await shot(page, "23d-playground-lang");
  await clickButton(page, "rust");
  await page.waitForTimeout(700);

  // CODE: the editor and nothing else. The bench is a list, an editor, a
  // stdin box, a band of buttons and an output panel, and the report that
  // started this was that it is very hard to use — so what is asserted is
  // the thing that was wrong: how much of the window the editor gets.
  const editorH = async () =>
    page.evaluate(() => {
      const ed = document.querySelector(".cm-editor") as HTMLElement | null;
      return ed?.getBoundingClientRect().height ?? 0;
    });
  const framed = await editorH();
  await clickButton(page, "code");
  await page.waitForTimeout(700);
  const focused = await editorH();
  console.log(
    `[playground] editor ${Math.round(framed)}px framed -> ${Math.round(focused)}px CODE`,
  );
  expect(focused).toBeGreaterThan(framed * 1.5);
  // And stdin is **kept** here, on its own line above the editor. It is the
  // one thing CODE cannot take back from the code: a scratchpad has no test
  // cases, so this box is the only way a program that reads gets fed at all.
  const stdinHere = await page.evaluate(() => {
    const ta = document.querySelector(
      "textarea.cwb-field",
    ) as HTMLElement | null;
    const r = ta?.getBoundingClientRect();
    return r ? { h: Math.round(r.height), top: Math.round(r.top) } : null;
  });
  const codeTop = await page.evaluate(() =>
    Math.round(
      (
        document.querySelector(".cm-editor") as HTMLElement
      ).getBoundingClientRect().top,
    ),
  );
  console.log(
    `[playground] CODE stdin ${JSON.stringify(stdinHere)} above editor at ${codeTop}`,
  );
  expect(stdinHere, "the stdin field is on screen in CODE").not.toBeNull();
  expect(
    stdinHere!.h,
    "and it is one line tall, not collapsed",
  ).toBeGreaterThan(10);
  expect(stdinHere!.top, "above the editor, not over it").toBeLessThan(codeTop);
  await shot(page, "23b-playground-code");

  // Copy and paste, which is the only way anything leaves a canvas: there is
  // nothing here to select with a mouse. The round trip is asserted, not the
  // button — a copy that puts the wrong text on the clipboard looks identical.
  await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
  await clickButton(page, "copycode");
  await page.waitForTimeout(600);
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  console.log(`[playground] copied ${JSON.stringify(copied.slice(0, 40))}`);
  expect(copied, "COPY CODE puts the editor on the clipboard").toContain(
    "fn main",
  );
  await page.evaluate(() =>
    navigator.clipboard.writeText("fn main() { /* from the clipboard */ }\n"),
  );
  await clickButton(page, "pastecode");
  await page.waitForTimeout(700);
  expect(await editorText(page), "PASTE replaces the editor").toContain(
    "from the clipboard",
  );
  await clickButton(page, "copycode");
  await page.waitForTimeout(600);
  expect(await page.evaluate(() => navigator.clipboard.readText())).toContain(
    "from the clipboard",
  );

  // With output on screen, a landscape window puts it **beside** the code and
  // an upright one under it. Measured off the editor's width: stacked, it has
  // the whole panel; beside, it gives up a third of it.
  await clickButton(page, "run");
  await expect
    .poll(
      async () => page.evaluate(() => document.body.innerText.length >= 0),
      { timeout: 120_000 },
    )
    .toBe(true);
  await page.waitForTimeout(3000);
  const edBox = async () =>
    page.evaluate(() => {
      const el = document.querySelector(".cm-editor") as HTMLElement | null;
      const r = el?.getBoundingClientRect();
      return r
        ? {
            w: r.width,
            h: r.height,
            vw: window.innerWidth,
            vh: window.innerHeight,
          }
        : null;
    });
  const laid = await edBox();
  const wide = (laid?.vw ?? 0) > (laid?.vh ?? 0);
  const share = laid!.w / laid!.vw;
  console.log(
    `[playground] CODE editor ${Math.round(laid!.w)}x${Math.round(laid!.h)} of ${laid!.vw}x${laid!.vh}` +
      ` (${wide ? "landscape" : "portrait"}, ${(share * 100).toFixed(0)}% wide)`,
  );
  // And stdin keeps the output company across the short axis: stacked above
  // it in the column when wide, beside it in the band when tall.
  const boxes = await page.evaluate(() => {
    const el = (q: string) =>
      document.querySelector(q)?.getBoundingClientRect();
    const ed = el(".cm-editor");
    const ta = el("textarea.cwb-field");
    return ed && ta
      ? {
          ed: {
            x: Math.round(ed.x),
            y: Math.round(ed.y),
            w: Math.round(ed.width),
            h: Math.round(ed.height),
          },
          ta: {
            x: Math.round(ta.x),
            y: Math.round(ta.y),
            w: Math.round(ta.width),
            h: Math.round(ta.height),
          },
        }
      : null;
  });
  console.log(
    `[playground] stdin ${JSON.stringify(boxes?.ta)} editor ${JSON.stringify(boxes?.ed)}`,
  );
  expect(boxes, "both the editor and stdin are on screen").not.toBeNull();
  if (wide) {
    expect(
      share,
      "landscape gives the output a column beside the code",
    ).toBeLessThan(0.8);
    expect(
      boxes!.ta.x,
      "stdin is in the column beside the code",
    ).toBeGreaterThanOrEqual(boxes!.ed.x + boxes!.ed.w - 4);
  } else {
    expect(share, "upright keeps the code full width").toBeGreaterThan(0.85);
    expect(
      boxes!.ta.y,
      "stdin is in the band under the code",
    ).toBeGreaterThanOrEqual(boxes!.ed.y + boxes!.ed.h - 4);
    expect(
      boxes!.ta.w,
      "and it takes only part of that band's width",
    ).toBeLessThan(boxes!.ed.w * 0.6);
    // Side by side means the same height: a full panel with a one-line sliver
    // beside it does not read as a pair.
    const outH = await page.evaluate(() => {
      const c = document.querySelector("#game") as HTMLCanvasElement;
      return Math.round(c.getBoundingClientRect().height);
    });
    expect(
      boxes!.ta.h,
      "stdin is a band, not a sliver, beside the output",
    ).toBeGreaterThan(outH * 0.1);
    // The label is over the field, not beside it: alongside, `표준 입력` takes
    // two thirds of a narrow box and the input gets the third that is left.
    const band = await page.evaluate(() => {
      const c = document.querySelector("#game") as HTMLCanvasElement;
      const r = c.getBoundingClientRect();
      const ta = document
        .querySelector("textarea.cwb-field")!
        .getBoundingClientRect();
      return {
        taW: Math.round(ta.width),
        taX: Math.round(ta.x),
        canvasX: Math.round(r.x),
      };
    });
    console.log(`[playground] stdin field ${band.taW}px wide in a band`);
    expect(band.taW, "the field has most of its box's width").toBeGreaterThan(
      boxes!.ed.w * 0.3,
    );
  }
  await shot(page, "23e-code-output");

  // The same two buttons on a page with **no async clipboard** — which is
  // every `http://` origin, and so every phone reaching this over a tailnet.
  // `127.0.0.1` is a secure context, so everything above proves nothing about
  // the case that was reported. Run first: COPY OUTPUT with nothing to copy
  // correctly writes nothing, and a stale capture then looks like a bug.
  await page.evaluate(() => {
    const w = window as unknown as { __copied?: string };
    w.__copied = "";
    Object.defineProperty(navigator, "clipboard", {
      value: undefined,
      configurable: true,
    });
    document.execCommand = (cmd: string) => {
      if (cmd === "copy") {
        const el = document.activeElement as HTMLTextAreaElement | null;
        w.__copied = el && "value" in el ? el.value : "<not a field>";
      }
      return true;
    };
  });
  const grab = async (id: string) => {
    await page.evaluate(
      () => ((window as unknown as { __copied?: string }).__copied = ""),
    );
    await clickButton(page, id);
    await page.waitForTimeout(500);
    return page.evaluate(
      () => (window as unknown as { __copied?: string }).__copied ?? "",
    );
  };
  const fbCode = await grab("copycode");
  const fbOut = await grab("copyout");
  console.log(
    `[playground] no-async: code ${JSON.stringify(fbCode.slice(0, 26))} out ${JSON.stringify(fbOut.slice(0, 26))}`,
  );
  expect(fbCode, "COPY CODE works with no async clipboard").toContain(
    "fn main",
  );
  expect(fbOut.length, "COPY OUTPUT copies something").toBeGreaterThan(0);
  expect(fbOut, "COPY OUTPUT copies the run, not the code").not.toContain(
    "fn main",
  );

  // **One entry, two things.** The input belongs to the pad: a scratchpad has
  // no test cases, so this is the only thing its program will ever read, and
  // a pad that came back without it would come back unrunnable.
  const stdinBox = page.locator("textarea.cwb-field").first();
  await stdinBox.fill("7 11\n");
  await page.waitForTimeout(400);
  await clickButton(page, "save");
  await page.waitForTimeout(800);
  // Back to the framed screen: the pad list is not drawn in CODE, so there is
  // nothing there to find the saved pad among.
  await clickButton(page, "unfocus");
  await page.waitForTimeout(700);
  await expect
    .poll(
      async () =>
        page.evaluate(() =>
          window.__cwbCapture!.buttons().some((b) => b.id.startsWith("snip:")),
        ),
      { timeout: 30_000, message: "the pad reaches the list" },
    )
    .toBe(true);
  const padId = await page.evaluate(
    () =>
      window.__cwbCapture!.buttons().find((b) => b.id.startsWith("snip:"))
        ?.id ?? "",
  );
  // Away and back, through the server rather than through this page's memory.
  await page.reload();
  await page.waitForFunction(
    () => typeof window.__cwbCapture?.settle === "function",
  );
  // A reload lands where the server remembers the player being (§1.3), which
  // is the lobby — the scratchpad is not a place in the world.
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
  await expect
    .poll(async () => sceneNow(page), { timeout: 30_000 })
    .toBe("playground");
  await page.waitForSelector(".cm-editor");
  await page.waitForTimeout(900);
  await clickButton(page, padId);
  await page.waitForTimeout(1200);
  const fedBack = await page.locator("textarea.cwb-field").first().inputValue();
  console.log(
    `[playground] pad reopened with stdin ${JSON.stringify(fedBack)}`,
  );
  expect(fedBack, "the pad kept its input").toContain("7 11");
  await clickButton(page, "code");
  await page.waitForTimeout(800);

  // The display toggles are buttons here, not only F-keys — this is the
  // screen people reach for on a phone, and a phone has no F11.
  const ids = await page.evaluate(() =>
    window.__cwbCapture!.buttons().map((b) => b.id),
  );
  expect(ids).toContain("fullscreen");
  expect(ids).toContain("orient");
  const before = await page.evaluate(() => window.__cwbCapture!.orientation());
  await clickButton(page, "orient");
  await page.waitForTimeout(500);
  const after = await page.evaluate(() => window.__cwbCapture!.orientation());
  console.log(`[playground] ORIENT button: ${before} -> ${after}`);

  // RENAME: the pad's own name, typed over in place — and the list is what
  // has to show it. The name lived only on the screen it was typed on: the
  // save never sent it, the reply overwrote it, and a rename that moved no
  // code was taken for an autosave with nothing to do.
  await clickButton(page, "unfocus");
  await page.waitForTimeout(600);
  await clickButton(page, "save");
  await expect
    .poll(
      async () =>
        page.evaluate(() =>
          window.__cwbCapture!.buttons().some((b) => b.id.startsWith("snip:")),
        ),
      { timeout: 30_000, message: "the saved pad reaches the list" },
    )
    .toBe(true);
  await clickButton(page, "rename");
  await page.waitForTimeout(400);
  // Selected whole with the caret at the **front**: typing replaces the name,
  // and one press of Left is the start of it for somebody editing what is
  // already there. `select()` alone leaves the caret at the far end.
  const sel = await page.evaluate(() => {
    const el = document.activeElement as HTMLInputElement | null;
    if (!el || el.tagName !== "INPUT") return null;
    return {
      start: el.selectionStart,
      end: el.selectionEnd,
      dir: el.selectionDirection,
      len: el.value.length,
    };
  });
  console.log(`[playground] rename selection ${JSON.stringify(sel)}`);
  expect(sel, "the name field has the focus").not.toBeNull();
  expect(sel!.start, "selected from the front").toBe(0);
  expect(sel!.end, "selected to the end").toBe(sel!.len);
  expect(sel!.dir, "caret at the front, not the end").toBe("backward");
  await page.keyboard.type("kettle");
  await page.keyboard.press("Enter");
  await expect
    .poll(
      async () =>
        page.evaluate(() =>
          window
            .__cwbCapture!.buttons()
            .some((b) => b.id.startsWith("snip:") && b.label === "kettle"),
        ),
      { timeout: 30_000, message: "the new name reaches the list" },
    )
    .toBe(true);
  console.log("[playground] RENAME reached the list");
  await shot(page, "23c-playground-renamed");

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

test("3f: every language on the login screen, via the LANG button", async ({
  page,
}) => {
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

test("5: every text-size step on the quest screen (en)", async ({ page }) => {
  const account = freshAccount();
  const wire = await Wire.as(BACKEND, account);
  try {
    await signIn(page, account);
    await toRustBasicQuest(page);
    await choicesShown(page);
    // Down to the floor.
    for (let i = 0; i < 4; i++) {
      await clickButton(page, "fontdown");
      await page.waitForTimeout(150);
    }
    const steps: string[] = [];
    let last = "";
    for (let i = 0; i < 20; i++) {
      const mul = (await pref(page, "ui.text")) ?? "1";
      if (mul === last) break;
      last = mul;
      const pct = Math.round(Number(mul) * 100);
      steps.push(String(pct));
      await page.waitForTimeout(300);
      await shot(page, `30-font-${String(pct).padStart(3, "0")}`);
      await choicesInsideCanvas(page, `font ${pct}%`);
      await clickButton(page, "fontup");
      await page.waitForTimeout(150);
    }
    console.log(`[font] steps: ${steps.join(", ")}`);
    expect(steps[0]).toBe("70");
    expect(steps[steps.length - 1]).toBe("120");
  } finally {
    wire.close();
  }
});

test("5b: Korean (CJK) at the smallest, default and largest text size, plus the other screens", async ({
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
    const since = sentFrames().length;
    await openSelectedNode(page);
    const questId = await openedQuestId(since);
    await choicesShown(page);
    await shot(page, "42-ko-quest-100");
    await choicesInsideCanvas(page, "ko 100%");
    for (let i = 0; i < 4; i++) await clickButton(page, "fontdown");
    await page.waitForTimeout(300);
    await shot(page, "42-ko-quest-070");
    await choicesInsideCanvas(page, "ko 70%");
    for (let i = 0; i < 8; i++) await clickButton(page, "fontup");
    await page.waitForTimeout(300);
    expect(await pref(page, "ui.text")).toBe("1.2");
    await shot(page, "42-ko-quest-120");
    await choicesInsideCanvas(page, "ko 120%");
    // A miss, at the biggest size: the pick says so where it was made.
    await pickOnScreen(page, wire, questId, "wrong");
    await shot(page, "43-ko-quest-120-missed");
    // A result and the stats in Korean.
    await pickOnScreen(page, wire, questId, "right");
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

test("5c: the other CJK locales and Czech on the map and quest", async ({
  page,
}) => {
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
      await choicesShown(page);
      await shot(page, `51-${loc}-quest`);
      await page.keyboard.press("Escape");
      await atScreen(page, "map");
    }
  } finally {
    wire.close();
  }
});
