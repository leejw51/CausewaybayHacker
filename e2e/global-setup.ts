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

// One port. The e2e bundle is served by the Rust server itself
// (PROTOCOL.md §1: the frontend from `/`, the websocket at `/ws`, no CORS),
// which is also the artifact that actually ships.
const SERVER = process.env.E2E_BASE_URL ?? "http://127.0.0.1:5390";

async function probe(url: string): Promise<string> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(3_000) });
    return res.status < 500 ? "up" : `http ${res.status}`;
  } catch (err) {
    return `down (${(err as Error).message})`;
  }
}

export default async function globalSetup(_config: FullConfig) {
  const state = await probe(SERVER);
  process.env.E2E_SERVER_STATE = state;

  console.log("\ncausewaybay-hacker e2e — preflight");
  console.log(
    `  ${state === "up" ? "ok  " : "DOWN"}  server    ${SERVER}  ${state === "up" ? "" : state}`,
  );
  if (state !== "up") {
    console.log(
      "\n  Nothing is being started for you: several agents share this tree\n" +
        "  and a Playwright-owned server would fight whatever build is in\n" +
        "  flight. Start one with the e2e bundle, which is the only build\n" +
        "  that carries the capture hook:\n\n" +
        "    cd frontend && npm run build:e2e\n" +
        "    cd backend && cargo run -p cwbhacker -- serve \\\n" +
        "        --static ../frontend/dist-e2e --home $(mktemp -d)\n\n" +
        "  Or run the whole matrix, which does it for you:\n" +
        "    node tests/run-all.mjs\n\n" +
        "  Every test will skip with that reason rather than fail.\n",
    );
  }
}
