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
import { preferredLocale, setLocale } from "./i18n";

/**
 * Dev, or a build made for the end-to-end suite. QA needs the capture hook in
 * a *built* bundle, which is why this is not `import.meta.env.DEV` alone.
 */
const CAPTURE = import.meta.env.DEV || import.meta.env.VITE_E2E === "1";

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
  const client = new Client({ transport: factory, storage: localStorage });
  const app = new App(canvas, fx, overlay, client);
  // Useful once, on the first frame, and never again: which server this is.
  console.info(`[causewaybay hacker] talking to ${label}`);
  app.start(new BootScene(app));

  if (CAPTURE) {
    const { install } = await import("./dev/capture");
    install(app);
  }
}

void main();
