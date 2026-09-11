import type { FullConfig } from "@playwright/test";

/**
 * Probe the two ports once, before a browser is launched.
 *
 * Without this the reachability check would live in a fixture, which means
 * Chromium starts, navigates to a dead port, and the run reports a browser
 * error where the truth is "you did not start the server". The result of the
 * probe is handed to the suite through the environment because that is the
 * only channel a `globalSetup` has to the workers.
 */

const FRONTEND = process.env.E2E_BASE_URL ?? "http://127.0.0.1:5291";
const BACKEND = process.env.E2E_BACKEND_URL ?? "http://127.0.0.1:5390";

async function probe(url: string): Promise<string> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(3_000) });
    return res.status < 500 ? "up" : `http ${res.status}`;
  } catch (err) {
    return `down (${(err as Error).message})`;
  }
}

export default async function globalSetup(_config: FullConfig) {
  const [frontend, backend] = await Promise.all([probe(FRONTEND), probe(BACKEND)]);
  process.env.E2E_FRONTEND_STATE = frontend;
  process.env.E2E_BACKEND_STATE = backend;

  const line = (name: string, url: string, s: string) =>
    `  ${s === "up" ? "ok  " : "DOWN"}  ${name.padEnd(9)} ${url}  ${s === "up" ? "" : s}`;

  console.log("\ncausewaybay-hacker e2e — preflight");
  console.log(line("frontend", FRONTEND, frontend));
  console.log(line("backend", BACKEND, backend));
  if (frontend !== "up" || backend !== "up") {
    console.log(
      "\n  Nothing is being started for you: four agents share this tree and a\n" +
        "  Playwright-owned server would fight whatever build is in flight.\n" +
        "  Start them yourself:  make dev\n" +
        "  Or point the suite elsewhere:  E2E_BASE_URL=… E2E_BACKEND_URL=…\n" +
        "  Every test will skip with that reason rather than fail.\n",
    );
  }
}
