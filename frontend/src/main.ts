/**
 * Entry point. Picks a transport, builds the app, starts at boot.
 *
 * The transport choice is the only place the mock exists as far as the build is
 * concerned, and it is behind `import.meta.env.DEV` inside `net/endpoint.ts`
 * so a production bundle contains no trace of it.
 */
import { App } from "./app";
import { Client } from "./net/client";
import { chooseTransport } from "./net/endpoint";
import { BootScene } from "./scenes/boot";

async function main(): Promise<void> {
  const canvas = document.getElementById("game") as HTMLCanvasElement | null;
  const fx = document.getElementById("fx") as HTMLCanvasElement | null;
  const overlay = document.getElementById("overlay");
  if (!canvas || !fx || !overlay) throw new Error("the page is missing its canvases");

  const { factory, label } = await chooseTransport();
  const client = new Client({ transport: factory, storage: localStorage });
  const app = new App(canvas, fx, overlay, client);
  // Useful once, on the first frame, and never again: which server this is.
  console.info(`[causewaybay hacker] talking to ${label}`);
  app.start(new BootScene(app));

  // A dev-only peephole, for the e2e suite and for a human debugging a scene
  // transition. Folded out of a production build with everything else behind
  // `import.meta.env.DEV`, and it exposes only names — never the app object,
  // and never anything that could reach the wallet module.
  if (import.meta.env.DEV) {
    (globalThis as Record<string, unknown>).__cwb = {
      scene: () => app.currentScene?.name ?? null,
      orientation: () => (app.layout.isPortrait() ? "portrait" : "landscape"),
      virtual: () => [app.layout.vw, app.layout.vh],
    };
  }
}

void main();
