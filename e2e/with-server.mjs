/**
 * Start a throwaway server, run Playwright against it, stop it.
 *
 *     node e2e/with-server.mjs playground-sync.spec.ts
 *
 * The rest of this suite runs against a server somebody else started (see
 * `playwright.config.ts`), because several agents share the tree. The specs
 * this runs are the ones CI can afford: they need no CausewaybayWallet binary
 * and no compiler, only the server binary and the e2e bundle, both of which
 * `make test-sync` builds first. The server gets a fresh `--home` and a port
 * of its own, and is stopped however the run ends.
 *
 * Arguments are handed to `playwright test` as they are.
 */
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const BIN =
  process.env.CWBHACKER_BIN ?? join(ROOT, "backend/target/debug/cwbhacker");
const STATIC = join(ROOT, "frontend/dist-e2e");

for (const [path, how] of [
  [BIN, "cd backend && cargo build -p cwbhacker"],
  [join(STATIC, "index.html"), "cd frontend && npm run build:e2e"],
]) {
  if (!existsSync(path)) {
    console.error(`missing ${path} — build it first: ${how}`);
    process.exit(2);
  }
}

const home = mkdtempSync(join(tmpdir(), "cwbhacker-e2e-"));
const port = 5530 + Math.floor(Math.random() * 200);
const url = `http://127.0.0.1:${port}`;
const log = [];
const server = spawn(
  BIN,
  ["serve", "--bind", `127.0.0.1:${port}`, "--home", home, "--static", STATIC],
  { cwd: join(ROOT, "backend"), stdio: ["ignore", "pipe", "pipe"] },
);
server.stdout.on("data", (d) => log.push(String(d)));
server.stderr.on("data", (d) => log.push(String(d)));

let stopped = false;
function stop() {
  if (stopped) return;
  stopped = true;
  if (server.exitCode === null) server.kill("SIGTERM");
  rmSync(home, { recursive: true, force: true });
}
process.on("SIGINT", () => (stop(), process.exit(130)));
process.on("SIGTERM", () => (stop(), process.exit(143)));

/** Until the websocket answers: the static files come up before `/ws` does. */
async function waitForServer(seconds = 600) {
  const until = Date.now() + seconds * 1000;
  while (Date.now() < until) {
    if (server.exitCode !== null)
      throw new Error(
        `the server exited with ${server.exitCode}:\n${log.join("").slice(-3000)}`,
      );
    const ok = await new Promise((resolve) => {
      let ws;
      try {
        ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
      } catch {
        return resolve(false);
      }
      const timer = setTimeout(() => (ws.close(), resolve(false)), 3000);
      ws.addEventListener(
        "open",
        () => (clearTimeout(timer), ws.close(), resolve(true)),
      );
      ws.addEventListener("error", () => (clearTimeout(timer), resolve(false)));
    });
    if (ok) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(
    `no websocket at ${url} within ${seconds}s:\n${log.join("").slice(-3000)}`,
  );
}

let code = 1;
try {
  await waitForServer();
  console.log(`server up at ${url} (home ${home})`);
  code = await new Promise((resolve) => {
    const pw = spawn("npx", ["playwright", "test", ...process.argv.slice(2)], {
      cwd: join(ROOT, "e2e"),
      stdio: "inherit",
      env: { ...process.env, E2E_BASE_URL: url },
    });
    pw.on("exit", (c) => resolve(c ?? 1));
  });
  if (code !== 0)
    console.error(`\nlast of the server's log:\n${log.join("").slice(-2000)}`);
} catch (e) {
  console.error(String(e instanceof Error ? e.message : e));
} finally {
  stop();
}
process.exit(code);
