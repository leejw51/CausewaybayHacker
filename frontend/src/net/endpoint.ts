/**
 * Which server, and whether there is one.
 *
 * In production the bundle is served by the Rust server itself (SPEC §6: one
 * port, the frontend from `/`, the art from `/art/…`), so the websocket URL is
 * derived from `location` and needs no configuration. In dev the page is on
 * 5291 and the server on 5390, so `VITE_WS_URL` points across.
 *
 * The desktop app is the third case. Its page is the webview's own
 * (`tauri://localhost`), a fixed origin so the key kept in localStorage
 * survives a relaunch, and its server is on a random loopback port. The app
 * says which, before any script of ours runs, as `window.__CWBH_SERVER__`
 * (`http://127.0.0.1:<port>`; desktop/src/main.rs). Everything the server
 * serves that the page does not have — the socket, the chat's photos — is
 * addressed through `serverUrl`.
 *
 * `VITE_MOCK=1` swaps in the dev-only stand-in server. The import is dynamic
 * *and* guarded by `import.meta.env.DEV`, which Vite replaces with the literal
 * `false` in a production build — so Rollup drops the branch, and with it the
 * whole mock chunk. A static top-level import of `./mock` anywhere would undo
 * that, which is why there is none.
 */
import type { TransportFactory } from "./transport";
import { websocketTransport } from "./transport";

declare global {
  interface Window {
    /** Set by the desktop app: its server's `http://127.0.0.1:<port>`. */
    __CWBH_SERVER__?: string;
  }
}

/** The desktop app's server, with no trailing slash; `""` everywhere else. */
export function serverBase(): string {
  const injected = typeof window === "undefined" ? undefined : window.__CWBH_SERVER__;
  if (typeof injected !== "string" || !/^https?:\/\/[^/]+/.test(injected)) return "";
  return injected.replace(/\/+$/, "");
}

/**
 * A server path (`/photos/…`) as a URL this page can load: unchanged where the
 * page and the server share an origin, absolute on the desktop app's server.
 * Anything that is not a root-relative path (`data:`, a full URL) is left as is.
 */
export function serverUrl(path: string): string {
  const base = serverBase();
  if (!base || !path.startsWith("/") || path.startsWith("//")) return path;
  return base + path;
}

export function wsUrl(): string {
  const base = serverBase();
  if (base) return base.replace(/^http/, "ws") + "/ws";
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
