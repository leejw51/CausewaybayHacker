/**
 * Which server, and whether there is one.
 *
 * In production the bundle is served by the Rust server itself (SPEC §6: one
 * port, the frontend from `/`, the art from `/art/…`), so the websocket URL is
 * derived from `location` and needs no configuration. In dev the page is on
 * 5291 and the server on 5390, so `VITE_WS_URL` points across.
 *
 * `VITE_MOCK=1` swaps in the dev-only stand-in server. The import is dynamic
 * *and* guarded by `import.meta.env.DEV`, which Vite replaces with the literal
 * `false` in a production build — so Rollup drops the branch, and with it the
 * whole mock chunk. A static top-level import of `./mock` anywhere would undo
 * that, which is why there is none.
 */
import type { TransportFactory } from "./transport";
import { websocketTransport } from "./transport";

export function wsUrl(): string {
  const configured = import.meta.env.VITE_WS_URL;
  if (typeof configured === "string" && configured.length > 0) return configured;
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  return `${proto}//${location.host}/ws`;
}

export function usingMock(): boolean {
  return import.meta.env.DEV && import.meta.env.VITE_MOCK === "1";
}

export async function chooseTransport(): Promise<{ factory: TransportFactory; label: string }> {
  if (usingMock()) {
    const { mockTransport } = await import("./mock");
    return { factory: mockTransport(), label: "mock server (dev)" };
  }
  const url = wsUrl();
  return { factory: websocketTransport(url), label: url };
}
