/**
 * CONSOLE: the playground with everything but the code put away.
 *
 * One press from the bench puts the pad on a monitor with RUN and CONSOLE
 * in the corner and nothing else; a second press, or ESC, brings the bench
 * back — and with it, a computer setting of NORMAL, since the monitor was
 * only lent. The line under the glass is `consoleLine`, unit-tested; the
 * e2e server has no compiler to give it anything else to say.
 */
import {
  atScreen,
  clickButton,
  editorText,
  expect,
  fixtureAccount,
  login,
  sceneNow,
  test,
} from "./fixtures";

// Index 2, shared with the filter spec: neither keeps anything on the shelf.
const ACCOUNT = fixtureAccount(2);

async function ids(page: import("@playwright/test").Page): Promise<string[]> {
  return page.evaluate(() => (window.__cwbCapture?.buttons() ?? []).map((b) => b.id));
}

test("CONSOLE puts the pad on a monitor alone, and gives the bench back", async ({
  page,
}, info) => {
  await login(page, ACCOUNT);
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await expect.poll(async () => sceneNow(page), { timeout: 30_000 }).toBe("playground");
  await expect(page.locator(".cm-content")).toBeVisible();
  const bench = await ids(page);
  expect(bench).toContain("console");
  const before = await editorText(page);
  const computer = () =>
    page.evaluate(() => document.documentElement.dataset.computer ?? "normal");
  expect(await computer()).toBe("normal");

  await clickButton(page, "console");
  await expect.poll(async () => (await ids(page)).sort()).toEqual(["console", "run"]);
  await expect(page.locator(".cm-content")).toBeVisible();
  // The monitor is lent for the mode, the face with it.
  await expect.poll(computer).toBe("apple2");
  // The same pad: its first line (the editor only renders what is on screen,
  // and the monitor shows more of it than the bench did).
  expect((await editorText(page)).split("\n")[0]).toBe(before.split("\n")[0]);
  // Nothing from the bench is left floating over it.
  await expect(page.locator("input.cwb-field:visible")).toHaveCount(0);
  await page.waitForTimeout(3_000); // past the tube's warm-up
  await page.screenshot({ path: info.outputPath("console.png") });

  // Typing still types, and the pad is still the pad.
  await page.locator(".cm-content").click();
  await page.keyboard.press("ControlOrMeta+End");
  await page.keyboard.type("\n// zen");
  await expect.poll(async () => editorText(page)).toContain("// zen");

  // ESC: back to CODE's toolbar, not out of the screen; the monitor goes back.
  await page.keyboard.press("Escape");
  await expect.poll(async () => ids(page)).toContain("unfocus");
  expect(await sceneNow(page)).toBe("playground");
  await expect.poll(computer).toBe("normal");

  // And the button again, from CODE, toggles it on and off.
  await clickButton(page, "console");
  await expect.poll(async () => (await ids(page)).sort()).toEqual(["console", "run"]);
  await clickButton(page, "console");
  await expect.poll(async () => ids(page)).toContain("unfocus");
  await expect.poll(computer).toBe("normal");
});

/**
 * The line under the glass, for real, at the size it is played at. The e2e
 * server has no compiler, so the socket is put between the page and it and
 * `playground.run` is answered here: a compile error, then a clean run.
 */
test("the line under the glass says OK, or the error and its line", async ({
  browser,
  baseURL,
}, info) => {
  const context = await browser.newContext({ baseURL, viewport: { width: 1920, height: 1080 } });
  let next: Record<string, unknown> | null = null;
  await context.routeWebSocket(/\/ws/, (ws) => {
    const server = ws.connectToServer();
    ws.onMessage((m) => {
      const f = JSON.parse(String(m)) as { v: number; id: string; type: string };
      if (f.type === "playground.run" && next) {
        ws.send(JSON.stringify({ v: f.v, id: f.id, type: "playground.run.ok", payload: { run: next } }));
      } else server.send(m);
    });
    server.onMessage((m) => ws.send(m));
  });
  const page = await context.newPage();
  await page.goto("/");
  await login(page, ACCOUNT);
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await expect.poll(async () => sceneNow(page), { timeout: 30_000 }).toBe("playground");
  await clickButton(page, "console");
  await expect.poll(async () => (await ids(page)).sort()).toEqual(["console", "run"]);
  await page.waitForTimeout(1_500);
  await page.screenshot({ path: info.outputPath("1-ready.png") });

  const base = {
    attempt_id: "a",
    lang: "rust",
    compile_ms: 412,
    run_ms: 0,
    exit_code: null,
    stdout: "",
    stderr: "",
  };
  next = {
    ...base,
    outcome: "compile_error",
    diagnostics: [
      { kind: "error", code: "E0425", message: "cannot find value `count` in this scope", line: 7, col: 13 },
    ],
  };
  await clickButton(page, "run");
  await page.waitForTimeout(1_000);
  await page.screenshot({ path: info.outputPath("2-error.png") });
  // One line, and no machine's multi-line alert over the code.
  expect(await ids(page)).toContain("run");

  next = { ...base, outcome: "ok", run_ms: 3, exit_code: 0, stdout: "hi\n", diagnostics: [] };
  await clickButton(page, "run");
  await page.waitForTimeout(1_000);
  await page.screenshot({ path: info.outputPath("3-ok.png") });
  await context.close();
});
