/**
 * Entry point. Picks a transport, builds the app, starts at boot.
 *
 * Two things here are dev-only and must not reach a production bundle: the
 * stand-in server (`net/endpoint.ts` chooses it) and the capture hook. Both
 * are reached through a dynamic `import()` behind a build-time constant that
 * Vite folds to `false`, so Rollup drops the chunk entirely. There is a
 * `grep` over `dist/` in the build notes that proves it.
 */
import { App } from "./app";
import { Client } from "./net/client";
import { chooseTransport } from "./net/endpoint";
import { BootScene } from "./scenes/boot";
import { preferredLocale, setLocale, t } from "./i18n";

/**
 * Dev, or a build made for the end-to-end suite. QA needs the capture hook in
 * a *built* bundle, which is why this is not `import.meta.env.DEV` alone.
 */
const CAPTURE = import.meta.env.DEV || import.meta.env.VITE_E2E === "1";

/** This browser's localStorage, or nothing where touching it throws (private browsing, site data blocked). */
function localStore(): Storage | undefined {
  try {
    const store = globalThis.localStorage;
    store.setItem("cwbhacker.probe", "1");
    store.removeItem("cwbhacker.probe");
    return store;
  } catch {
    return undefined;
  }
}

async function main(): Promise<void> {
  const canvas = document.getElementById("game") as HTMLCanvasElement | null;
  const fx = document.getElementById("fx") as HTMLCanvasElement | null;
  const overlay = document.getElementById("overlay");
  if (!canvas || !fx || !overlay) throw new Error("the page is missing its canvases");

  // The language before anything is measured. `setLocale` swaps the table on
  // the call and only the CJK face is asynchronous, so every string below is
  // already in the right language and `boot.ts` waits for the font.
  void setLocale(preferredLocale(), false);

  const { factory, label } = await chooseTransport();
  // One session per browser, in `localStorage`, shared by every tab. The
  // server rotates the token on each resume, so two tabs resuming at once can
  // retire each other's copy; the client reads the store fresh each time, and
  // a tab that still loses signs in again with the kept key (`App#signInAgain`).
  const client = new Client({ transport: factory, storage: localStore() });
  const app = new App(canvas, fx, overlay, client);
  // Scene transitions are `void this.app.go(...)` in twenty places, and a
  // scene's `enter` that throws used to vanish: no console line the player
  // would see, no banner, a screen that simply did not change. Both kinds of
  // uncaught error land here and are said out loud, once each.
  const crashed = (what: unknown) => {
    console.error("[causewaybay hacker]", what);
    app.say(t("app.crashed"), 6);
  };
  window.addEventListener("unhandledrejection", (e) => crashed(e.reason));
  window.addEventListener("error", (e) => crashed(e.error ?? e.message));
  // Useful once, on the first frame, and never again: which server this is.
  console.info(`[causewaybay hacker] talking to ${label}`);
  app.start(new BootScene(app));

  if (CAPTURE) {
    const { install } = await import("./dev/capture");
    install(app);
  }
}

void main();
