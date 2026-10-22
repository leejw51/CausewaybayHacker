/**
 * The playground's COMPUTER button: NORMAL → APPLE ][ → MSX → AMIGA → NORMAL.
 *
 * Each machine sets `<html data-computer>`, its face, its paper, and puts the
 * three.js tube (`gfx/retroscreen.ts`) over the editor; NORMAL takes all of
 * it away again. The choice survives a reload, and the quest screen never
 * sees the attribute — only the playground sets it.
 */
import { expect, type Page } from "@playwright/test";
import {
  atScreen,
  clickButton,
  freshAccount,
  login,
  sceneNow,
  test,
} from "./fixtures";

const SHOTS = process.env.E2E_SHOTS;

const attr = (page: Page) =>
  page.evaluate(() => document.documentElement.dataset.computer ?? null);
const pref = (page: Page) =>
  page.evaluate(() => localStorage.getItem("cwbhacker.pg.computer"));
const label = (page: Page) =>
  page.evaluate(
    () =>
      window.__cwbCapture!.buttons().find((b) => b.id === "computer")?.label ??
      null,
  );
const editorBg = (page: Page) =>
  page.evaluate(
    () =>
      getComputedStyle(document.querySelector(".cwb-editor")!).backgroundColor,
  );
const tubeShown = (page: Page) =>
  page.evaluate(() => {
    const c = document.querySelector(".cwb-retro");
    return !!c && !c.classList.contains("cwb-hidden");
  });

const MACHINES = [
  { id: "apple2", label: "APPLE ][", bg: "rgb(5, 12, 7)" },
  { id: "msx", label: "MSX", bg: "rgb(84, 85, 237)" },
  { id: "amiga", label: "AMIGA", bg: "rgb(0, 85, 170)" },
];

test("the playground's COMPUTER button turns it into an old computer, and back", async ({
  page,
}) => {
  // A shader that does not compile fails silently on screen; not here.
  const glErrors: string[] = [];
  page.on("console", (m) => {
    if (/WebGLProgram|Shader Error/.test(m.text())) glErrors.push(m.text());
  });
  await login(page, freshAccount());
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await expect
    .poll(() => sceneNow(page), { timeout: 30_000 })
    .toBe("playground");
  await expect(page.locator(".cm-content")).toBeVisible();
  expect(await attr(page)).toBe(null);
  await expect.poll(() => label(page)).toBe("NORMAL");
  expect(await tubeShown(page)).toBe(false);

  for (const m of MACHINES) {
    await clickButton(page, "computer");
    await expect.poll(() => attr(page)).toBe(m.id);
    await expect.poll(() => pref(page)).toBe(m.id);
    await expect.poll(() => label(page)).toBe(m.label);
    expect(await editorBg(page)).toBe(m.bg);
    await expect.poll(() => tubeShown(page)).toBe(true);
    // Mid-boot: the banner is on the tube.
    await page.waitForTimeout(1500);
    if (SHOTS)
      await page.screenshot({ path: `${SHOTS}/computer-${m.id}-boot.png` });
    // Booted: the code, through the glass.
    await page.waitForTimeout(2200);
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/computer-${m.id}.png` });
  }

  expect(glErrors, "the tube's shader compiles").toEqual([]);

  // CODE, the editor full-window: the same monitor and tube, bigger.
  await clickButton(page, "code");
  await expect.poll(() => tubeShown(page)).toBe(true);
  await page.waitForTimeout(600);
  if (SHOTS)
    await page.screenshot({ path: `${SHOTS}/computer-amiga-code.png` });
  await clickButton(page, "unfocus");

  // For good: a reload keeps the Amiga.
  await page.reload();
  await expect.poll(() => pref(page)).toBe("amiga");
  await expect
    .poll(() => sceneNow(page), { timeout: 60_000 })
    .not.toMatch(/^(boot|title|story|login)$/);
  if ((await sceneNow(page)) !== "playground") {
    // Off the playground the attribute is not on the page.
    expect(await attr(page)).toBe(null);
    await atScreen(page, "lands");
    await clickButton(page, "playground");
    await expect
      .poll(() => sceneNow(page), { timeout: 30_000 })
      .toBe("playground");
  }
  await expect.poll(() => attr(page)).toBe("amiga");

  // And round to NORMAL: the tube powers off and the attribute goes.
  await clickButton(page, "computer");
  await expect.poll(() => attr(page)).toBe(null);
  await expect.poll(() => pref(page)).toBe("normal");
  await expect.poll(() => tubeShown(page), { timeout: 3000 }).toBe(false);
});

// A RUN that does not compile, on the Amiga: the Guru, over the code. Needs a
// server that can compile Rust, so it runs only when asked (E2E_GURU=1).
test("a failed RUN on the Amiga is a Guru Meditation", async ({ page }) => {
  test.skip(!process.env.E2E_GURU, "needs a server with a Rust toolchain");
  await login(page, freshAccount());
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await expect
    .poll(() => sceneNow(page), { timeout: 30_000 })
    .toBe("playground");
  for (let i = 0; i < 3; i++) await clickButton(page, "computer");
  await expect.poll(() => attr(page)).toBe("amiga");
  await page.waitForTimeout(3500);
  await page.locator(".cm-content").click();
  await page.keyboard.press("ControlOrMeta+a");
  await page.keyboard.type("fn main() { let x: i32 = ; }");
  await clickButton(page, "run");
  // The Guru stays up for three seconds from whenever the compiler answers;
  // a frame a second until then is enough to catch it.
  for (let i = 0; i < 20; i++) {
    await page.waitForTimeout(1000);
    if (SHOTS)
      await page.screenshot({ path: `${SHOTS}/computer-amiga-guru-${i}.png` });
  }
});
