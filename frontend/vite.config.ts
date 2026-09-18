import { defineConfig } from "vitest/config";

/**
 * The server serves the built bundle from `/` and the art from `/art/…` on the
 * one port (SPEC §6), so there is no Cloudflare-style relative `base` here and
 * no CORS to arrange. In dev the page is on 5291 and the server on 5390, which
 * is the only time the websocket URL is not simply derived from `location`.
 *
 * Loopback only. The dev server serves the source tree, and a phone cannot use
 * it anyway: the page it serves talks to `127.0.0.1:5390`, which on the phone
 * is the phone. From another device the game is the server's own port (README,
 * `make remote`), never this one — so there is no reason for this one to be
 * reachable from there.
 */
export default defineConfig({
  server: { host: "127.0.0.1", port: 5291 },
  build: {
    outDir: "dist",
    assetsDir: "assets",
    sourcemap: false,
    assetsInlineLimit: 4096,
  },
  test: {
    environment: "happy-dom",
    include: ["tests/**/*.test.ts"],
  },
});
