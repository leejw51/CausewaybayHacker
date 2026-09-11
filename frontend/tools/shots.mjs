/**
 * Regenerate `frontend/shots/`.
 *
 * The set was taken by hand until now, which is why two of them were wrong for
 * a week: a WebGL screenshot has to be read in the *same task* as the frame
 * that produced it — the context is not `preserveDrawingBuffer`, so a `png()`
 * after an `await` composites an empty `#fx` and the whole city goes missing.
 * Every capture here is therefore one evaluate: `freeze(); step(1); png()`,
 * with nothing between them, which is also the only capture that is
 * reproducible.
 *
 * Usage, with the dev server on 5291 and a server behind it:
 *
 *     node tools/shots.mjs                 # everything it can reach
 *     node tools/shots.mjs --only 2,3      # just the groups whose ids start 2 and 3
 *     BASE=http://127.0.0.1:5390 node tools/shots.mjs
 *
 * Playwright is not a dependency of this package — it belongs to `e2e/` — so
 * it is resolved from there and the script says so plainly if it is missing
 * rather than failing with a module error.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(HERE, "../shots");
const BASE = process.env.BASE ?? "http://127.0.0.1:5291";
/** Any 32-byte hex is a wallet. A fixed one keeps two runs comparable. */
const KEY = "0x1111111111111111111111111111111111111111111111111111111111111111";
const LAND = [1280, 800];
const PORT = [900, 1400];
/** The window the orientation faults were reported in. */
const TALL = [1080, 1750];

const only = (() => {
  const i = process.argv.indexOf("--only");
  if (i < 0) return null;
  return new Set((process.argv[i + 1] ?? "").split(",").filter(Boolean));
})();

async function playwright() {
  for (const spec of ["playwright", "../e2e/node_modules/playwright/index.mjs"]) {
    try {
      return await import(spec.startsWith(".") ? resolve(HERE, "..", spec) : spec);
    } catch {
      /* try the next one */
    }
  }
  throw new Error(
    "playwright is not installed. It belongs to `e2e/`: run `npm install` in " +
      "e2e/ (or `npm i -D playwright` here) and try again.",
  );
}

const taken = [];
const skipped = [];

function wanted(name) {
  return !only || only.has(name.slice(0, 1)) || only.has(name.slice(0, 2));
}

async function main() {
  const { chromium } = await playwright();
  mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: LAND[0], height: LAND[1] } });
  page.on("console", (m) => {
    if (m.type() === "error" && !m.text().includes("favicon")) console.log("  ! " + m.text());
  });

  /** One frame, frozen, both canvases and the overlay, written to disk. */
  const shot = async (name) => {
    if (!wanted(name)) return;
    await ready();
    const url = await page.evaluate(() => {
      const api = window.__cwbCapture;
      api.freeze();
      api.step(1);
      return api.png();
    });
    if (!url) throw new Error(`no picture for ${name}`);
    writeFileSync(resolve(OUT, `${name}.png`), Buffer.from(url.split(",")[1], "base64"));
    taken.push(`${name}.png`);
    process.stdout.write(`  ${name}.png\n`);
    await page.evaluate(() => window.__cwbCapture.resume());
  };

  /**
   * Wait for the capture hook.
   *
   * `page.goto` resolves on `load`, and the hook is installed by a module that
   * runs after it. Every helper below goes through this, because the failure
   * without it is `Cannot read properties of undefined` at whatever line
   * happened to be first — which says nothing about what went wrong.
   */
  const ready = async (ms = 20000) => {
    const end = Date.now() + ms;
    for (;;) {
      if (await page.evaluate(() => Boolean(window.__cwbCapture?.scene))) return;
      if (Date.now() > end) throw new Error("the page never installed `__cwbCapture`");
      await page.waitForTimeout(150);
    }
  };
  const settle = async (secs = 2.5) => {
    await ready();
    await page.evaluate((s) => window.__cwbCapture.settle(s), secs);
  };
  const scene = async () => {
    await ready();
    return page.evaluate(() => window.__cwbCapture.scene());
  };
  const size = async ([w, h]) => {
    await page.setViewportSize({ width: w, height: h });
    await page.waitForTimeout(250);
  };
  const orient = async (mode) => {
    await page.evaluate((m) => window.__cwbCapture.orient(m), mode);
    await page.waitForTimeout(120);
  };
  const press = async (id, wait = 1200) => {
    const at = await page.evaluate((i) => window.__cwbCapture.buttonAt(i), id);
    if (!at) throw new Error(`no button \`${id}\` on ${await scene()}`);
    await page.mouse.click(at[0], at[1]);
    await page.waitForTimeout(wait);
  };
  /** Wait for a screen, or say which one we are stuck on. */
  const at = async (name, ms = 20000) => {
    const end = Date.now() + ms;
    for (;;) {
      if ((await scene()) === name) return;
      if (Date.now() > end) throw new Error(`still on ${await scene()}, wanted ${name}`);
      await page.waitForTimeout(200);
    }
  };
  const group = async (label, body) => {
    try {
      await body();
    } catch (err) {
      skipped.push(`${label}: ${err.message}`);
      console.log(`  — ${label} skipped: ${err.message}`);
    }
  };

  // ---- the opening, logged out ------------------------------------------
  await page.goto(`${BASE}/`);
  await page.evaluate(() => {
    try {
      localStorage.clear();
    } catch {
      /* nothing to clear */
    }
  });

  /**
   * When each beat of the opening is on screen, in seconds from the first
   * frame, and which shot belongs to it.
   *
   * Derived from `scenes/story.ts` rather than guessed: a beat lasts
   * `CUT + chars / CPS + hold`, and the moment worth a picture is just after
   * the last character lands. Guessing four seconds a beat put
   * `03-story-face` on the wrong room twice.
   */
  const BEATS = [
    [3.3, "01-story-open"],
    [11.6, "02-story-ghost-text"],
    [18.3, "03-story-face"],
    [30.4, "04-story-datacentre"],
    [35.7, "05-story-stairs"],
    [38.8, "06-story-lands"],
  ];

  await group("story", async () => {
    await size(LAND);
    await page.goto(`${BASE}/`);
    await at("story", 25000);
    // Real time to each beat, frozen only for the frame itself: the beats
    // wait on background JPEGs that a frozen loop would never receive, and a
    // `settle()` through the whole opening would never let one arrive.
    const t0 = Date.now();
    for (const [when, name] of BEATS) {
      const wait = t0 + when * 1000 - Date.now();
      if (wait > 0) await page.waitForTimeout(wait);
      if ((await scene()) !== "story") break;
      await shot(name);
    }
    // The logo is the end of the sequence and the screen hands over by itself
    // a few seconds later, so it is taken by holding the last story frame:
    // each pass overwrites the one before, and the file that survives is the
    // last frame before the hand-over.
    for (let i = 0; i < 20 && (await scene()) === "story"; i++) {
      await shot("07-story-title");
      await page.waitForTimeout(450);
    }
  });

  await group("story-portrait", async () => {
    await size(PORT);
    await page.goto(`${BASE}/`);
    await at("story", 25000);
    await page.waitForTimeout(2600);
    await shot("08-story-portrait");
  });

  // ---- login -------------------------------------------------------------
  await group("login", async () => {
    await size(LAND);
    await page.goto(`${BASE}/`);
    await at("login", 45000);
    await settle(2.5);
    await shot("10-login-landscape");
    await press("new", 1600);
    await settle(2.5);
    await shot("11-login-phrase");
    await orient("portrait");
    await settle(1.5);
    await shot("13-login-portrait");
    await orient("landscape");
  });

  await group("login-offline", async () => {
    // Its own page, and that is not fussiness. A websocket route survives
    // `unrouteAll` badly enough that the first run of this script signed in
    // against a socket that was still being closed under it, and every group
    // after this one reported "still on login". A page that is thrown away
    // cannot leak a route into the rest of the run.
    const dead = await browser.newPage({ viewport: { width: LAND[0], height: LAND[1] } });
    try {
      // Only the game's own socket: routing everything takes Vite's
      // hot-reload channel with it and the page spends the shot complaining
      // about that instead of holding the phrase.
      await dead.routeWebSocket(/\/ws(\?|$)/, (ws) => ws.close());
      await dead.goto(`${BASE}/`);
      const on = async (name, ms = 45000) => {
        const until = Date.now() + ms;
        for (;;) {
          const now = await dead.evaluate(() => window.__cwbCapture?.scene?.() ?? null);
          if (now === name) return;
          if (Date.now() > until) throw new Error(`still on ${now}, wanted ${name}`);
          await dead.waitForTimeout(200);
        }
      };
      await on("login");
      await dead.evaluate(() => window.__cwbCapture.settle(2.5));
      const hit = await dead.evaluate(() => window.__cwbCapture.buttonAt("new"));
      if (!hit) throw new Error("no NEW WALLET button");
      await dead.mouse.click(hit[0], hit[1]);
      await dead.waitForTimeout(1600);
      const keep = await dead.evaluate(() => window.__cwbCapture.buttonAt("keep"));
      if (keep) {
        await dead.mouse.click(keep[0], keep[1]);
        await dead.waitForTimeout(2500);
      }
      await dead.evaluate(() => window.__cwbCapture.settle(2.5));
      const url = await dead.evaluate(() => {
        const api = window.__cwbCapture;
        api.freeze();
        api.step(1);
        return api.png();
      });
      const name = "12-login-phrase-held-offline";
      if (wanted(name) && url) {
        writeFileSync(resolve(OUT, `${name}.png`), Buffer.from(url.split(",")[1], "base64"));
        taken.push(`${name}.png`);
        process.stdout.write(`  ${name}.png\n`);
      }
    } finally {
      await dead.close();
    }
  });

  // ---- signed in ---------------------------------------------------------
  const signIn = async () => {
    if ((await scene()) === "lands") return;
    await page.goto(`${BASE}/`);
    await at("login", 45000);
    const field = page.locator("textarea.cwb-field");
    await field.waitFor({ timeout: 15000 });
    await field.fill(KEY);
    await field.press("ControlOrMeta+Enter");
    await at("lands", 30000);
    await page.waitForTimeout(600);
  };

  await group("lands", async () => {
    await size(LAND);
    await signIn();
    await settle(2.5);
    await shot("20-lands-landscape");
    // The mascot follows the cursor: hover ADVANCED and Ferris works two tills.
    const at2 = await page.evaluate(() => window.__cwbCapture.buttonAt("cat:advanced"));
    if (at2) {
      await page.mouse.move(at2[0], at2[1]);
      await page.waitForTimeout(700);
      await shot("21-lands-hover-advanced");
      await page.mouse.move(4, 4);
    }
    await size(PORT);
    await page.waitForTimeout(400);
    await settle(2);
    await shot("22-lands-portrait");
  });

  await group("lands-nogl", async () => {
    await size(TALL);
    await page.goto(`${BASE}/?nogl=1`);
    await at("lands", 45000);
    await settle(2.5);
    await shot("23-lands-no-webgl-1080x1750");
  });

  await group("map", async () => {
    await size(LAND);
    await page.goto(`${BASE}/`);
    await at("lands", 45000);
    await settle(2);
    await press("cat:basic", 2500);
    await at("map", 25000);
    await settle(3);
    await shot("30-map-landscape");
    await size(PORT);
    await page.waitForTimeout(400);
    await settle(2);
    await shot("31-map-portrait");
    await size(LAND);
    await page.waitForTimeout(400);
    await settle(2);
    await press("cat:advanced", 2500);
    await settle(3);
    await shot("35-map-rust-advanced");
    await press("land:go", 2500);
    await settle(3);
    await shot("37-map-go-advanced");
    await press("land:rust", 2500);
    await press("cat:basic", 2500);
    await settle(3);
    // Mid-walk, then the iris closing on the street she reached.
    const node = await page.evaluate(() => {
      const api = window.__cwbCapture;
      return api.virtual();
    });
    await page.mouse.click(node[0] * 0.55, node[1] * 0.6);
    await page.waitForTimeout(150);
    await shot("32-map-walk-a");
    await page.waitForTimeout(500);
    await shot("33-map-walk-b");
    await page.waitForTimeout(700);
    await shot("34-map-iris-into-street");
  });

  await group("map-nogl", async () => {
    await size(TALL);
    await page.goto(`${BASE}/?nogl=1`);
    await at("lands", 45000);
    await settle(2);
    await press("cat:basic", 2500);
    await at("map", 25000);
    await settle(3);
    await shot("36-map-no-webgl-1080x1750");
  });

  // ---- a quest, and what comes out of it ---------------------------------
  const openQuest = async (category = "cat:basic") => {
    await page.goto(`${BASE}/`);
    await at("lands", 45000);
    await settle(2);
    await press(category, 2500);
    await at("map", 25000);
    await settle(3);
    await page.keyboard.press("Enter");
    await at("quest", 30000);
    await page.waitForTimeout(2500);
  };

  await group("quest", async () => {
    await size(LAND);
    await openQuest();
    await settle(2.5);
    await shot("40-quest-landscape");
    await press("format", 3500).catch(() => {});
    await settle(2);
    await shot("46-quest-format");
    await press("run", 1000);
    await page.waitForTimeout(9000);
    await settle(2.5);
    await shot("41-quest-run-report-fail");
    await size(PORT);
    await page.waitForTimeout(400);
    await settle(2);
    await shot("43-quest-portrait");
    await shot("42-quest-run-report-pass-portrait");
  });

  await group("quest-clock", async () => {
    await size(LAND);
    await openQuest("cat:hacker");
    await settle(2.5);
    await shot("44-quest-clock");
    await page.waitForTimeout(2500);
    await settle(2.5);
    await shot("45-quest-clock-overtime-forced");
  });

  await group("result", async () => {
    await size(LAND);
    await openQuest();
    await settle(2);
    await press("submit", 1200);
    // The confirm dialogue, then the compile.
    await page.keyboard.press("Enter");
    await at("result", 60000);
    await page.waitForTimeout(1200);
    await shot("50-result-rejected");
    await settle(0.2);
    await shot("52-result-shake");
    await size(PORT);
    await page.waitForTimeout(400);
    await settle(2.5);
    await shot("51-result-accepted-portrait");
  });

  // ---- the scratchpad ----------------------------------------------------
  await group("playground", async () => {
    await size(LAND);
    await page.goto(`${BASE}/`);
    await at("lands", 45000);
    await settle(2);
    await press("playground", 2500);
    await at("playground", 25000);
    await settle(2.5);
    await shot("60-playground-landscape");
    await press("format", 3500).catch(() => {});
    await settle(2);
    await shot("62-playground-format");
    await size(PORT);
    await page.waitForTimeout(400);
    await settle(2);
    await shot("61-playground-portrait");
  });

  await browser.close();

  console.log(`\n${taken.length} written to ${OUT}`);
  if (skipped.length) {
    console.log(`${skipped.length} group(s) not taken:`);
    for (const s of skipped) console.log(`  - ${s}`);
  }
}

main().catch((err) => {
  console.error(err.message ?? err);
  process.exit(1);
});
