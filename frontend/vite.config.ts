import { defineConfig } from "vitest/config";

/**
 * The server serves the built bundle from `/` and the art from `/art/…` on the
 * one port (SPEC §6), so there is no Cloudflare-style relative `base` here and
 * no CORS to arrange. In dev the page is on 5291 and the server on 5390, which
 * is the only time the websocket URL is not simply derived from `location`.
 */
export default defineConfig({
  server: { host: true, port: 5291 },
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
