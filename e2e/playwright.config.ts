import { defineConfig, devices } from "@playwright/test";

/**
 * The suite runs against a server somebody else started.
 *
 * Deliberately **no `webServer` block**. Four agents share this tree; a config
 * that spawns `vite` or `cargo run` would fight whatever build is already in
 * flight, and a Playwright-owned server that dies mid-suite looks like a
 * product bug. Start the thing yourself:
 *
 *     make dev          # backend on :5390, frontend on :5291
 *     cd e2e && npx playwright test
 *
 * `E2E_BASE_URL` points the same suite somewhere else — at the release build
 * served by the backend itself on :5390, for instance, which is the artifact
 * that actually ships (SPEC §6: one port, no CORS).
 *
 * When nothing is listening the suite skips every test with a loud reason
 * rather than failing with a connection error that says nothing. See
 * `fixtures.ts`.
 */

const FRONTEND = process.env.E2E_BASE_URL ?? "http://127.0.0.1:5291";

// SPEC §10 / the lifted `layout.ts`: the game is authored at 1280×720 or
// 720×1280 and scales from there. Both orientations are first-class on every
// screen, so both are a project rather than a flag on one test.
const LANDSCAPE = { width: 1280, height: 720 };
const PORTRAIT = { width: 720, height: 1280 };

export default defineConfig({
  testDir: ".",
  globalSetup: "./global-setup.ts",
  timeout: 120_000, // a cold `rustc` is the slow part, not the browser
  expect: { timeout: 30_000 },
  fullyParallel: false,
  retries: 0,
  workers: 1, // the backend is one process with one database
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : [["list"]],
  use: {
    baseURL: FRONTEND,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    video: "off",
  },
  projects: [
    {
      name: "landscape",
      use: { ...devices["Desktop Chrome"], viewport: LANDSCAPE },
    },
    {
      name: "portrait",
      // A phone-shaped viewport, but not a phone: touch and mobile emulation
      // change the input path as well as the layout, and what §10 asks for
      // here is the *orientation*. A separate touch project belongs to M2.
      use: { ...devices["Desktop Chrome"], viewport: PORTRAIT },
    },
  ],
});
