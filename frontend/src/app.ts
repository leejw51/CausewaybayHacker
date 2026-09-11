/**
 * The shell: one layout, one loop, one scene at a time.
 *
 * Everything a scene is allowed to touch hangs off `App`. Notably absent from
 * that list is any game state — no progress, no quest list, no cleared set.
 * A scene asks the server, draws the answer and forgets it, which is what makes
 * "a reload loses nothing" true rather than aspirational (SPEC §6.4).
 */
import { Layout, type Orientation } from "./engine/layout";
import { Input, loveKey } from "./engine/input";
import { Assets } from "./engine/assets";
import { ensureFonts, remeasure } from "./engine/text";
import { Theme } from "./engine/theme";
import type { Ctx } from "./engine/ui";
import { Client } from "./net/client";
import { Chip } from "./audio/sfx";

export interface Scene {
  readonly name: string;
  enter?(): void | Promise<void>;
  leave?(): void;
  update?(dt: number): void;
  draw(g: Ctx): void;
  /** Virtual coordinates, already clipped to the canvas. */
  pointer?(x: number, y: number, phase: "down" | "move" | "up"): void;
  /** A LÖVE-flavoured key name from `engine/input.ts`. */
  key?(name: string, ev: KeyboardEvent): void;
  /** The window changed shape or orientation; rebuild anything cached. */
  resized?(): void;
}

/** Where the player's chosen orientation is kept. A preference, not a secret. */
const ORIENT_KEY = "cwbhacker.orientation";

export class App {
  readonly layout: Layout;
  readonly input = new Input();
  readonly g: Ctx;
  readonly chip = new Chip();
  assets: Assets | null = null;

  /** Set by the login scene and read by the header. Display only. */
  addressLabel = "";

  private scene: Scene | null = null;
  private last = 0;
  private raf = 0;
  /** A one-line banner for anything the player needs told: errors, reconnects. */
  private toast: { text: string; until: number } | null = null;

  constructor(
    readonly canvas: HTMLCanvasElement,
    readonly fx: HTMLCanvasElement,
    readonly overlay: HTMLElement,
    readonly client: Client,
  ) {
    const touch = matchMedia("(pointer: coarse)").matches;
    this.layout = new Layout(canvas, touch);
    const ctx = canvas.getContext("2d", { alpha: true });
    if (!ctx) throw new Error("this browser has no 2d canvas");
    this.g = ctx;

    const saved = localStorage.getItem(ORIENT_KEY);
    if (saved === "portrait" || saved === "landscape") this.layout.pin(saved as Orientation);

    addEventListener("resize", () => this.measure());
    addEventListener("orientationchange", () => this.measure());
    addEventListener("blur", () => this.input.releaseAll());
    this.wirePointer();
    this.wireKeys();

    // The connection banner is the app's, not a scene's: it has to be visible
    // on whichever screen the player happens to be on when the server goes.
    client.onState((s) => {
      if (s === "offline") this.say("connection lost — retrying");
      if (s === "authed") this.toast = null;
    });
    client.on("server.bye", (p) => this.say(p.reason));
  }

  // -- the loop ------------------------------------------------------------

  start(scene: Scene): void {
    this.measure();
    void this.go(scene);
    this.last = performance.now();
    const frame = (t: number) => {
      this.raf = requestAnimationFrame(frame);
      // Clamped: a tab that was in the background for a minute must not hand
      // the scene a sixty-second `dt` and teleport everything.
      const dt = Math.min(0.05, (t - this.last) / 1000);
      this.last = t;
      this.scene?.update?.(dt);
      this.render();
    };
    this.raf = requestAnimationFrame(frame);
  }

  stop(): void {
    cancelAnimationFrame(this.raf);
  }

  async go(next: Scene): Promise<void> {
    this.scene?.leave?.();
    this.scene = next;
    await next.enter?.();
  }

  get currentScene(): Scene | null {
    return this.scene;
  }

  private render(): void {
    const { g, layout } = this;
    ensureFonts(layout.uiScale());
    layout.begin(g);
    g.imageSmoothingEnabled = false;
    this.scene?.draw(g);
    this.drawToast(g);
  }

  private measure(): void {
    if (this.layout.measure()) {
      remeasure();
      this.scene?.resized?.();
    }
  }

  // -- input ---------------------------------------------------------------

  private wirePointer(): void {
    const send = (ev: PointerEvent, phase: "down" | "move" | "up") => {
      const v = this.layout.toVirtual(ev.clientX, ev.clientY);
      if (!v) return;
      this.scene?.pointer?.(v[0], v[1], phase);
    };
    this.canvas.addEventListener("pointerdown", (ev) => {
      // The first gesture is what lets an AudioContext start at all.
      this.chip.unlock();
      this.canvas.setPointerCapture(ev.pointerId);
      send(ev, "down");
    });
    this.canvas.addEventListener("pointermove", (ev) => send(ev, "move"));
    this.canvas.addEventListener("pointerup", (ev) => send(ev, "up"));
    this.canvas.addEventListener("pointercancel", (ev) => send(ev, "up"));
  }

  private wireKeys(): void {
    addEventListener("keydown", (ev) => {
      const name = loveKey(ev);
      if (!name) return;
      // F1 pins the orientation, everywhere, on every screen — the spec calls
      // both orientations first-class, so the toggle cannot belong to the map.
      if (name === "f1") {
        ev.preventDefault();
        this.layout.toggleOrientation();
        localStorage.setItem(ORIENT_KEY, this.layout.isPortrait() ? "portrait" : "landscape");
        remeasure();
        this.scene?.resized?.();
        this.say(`orientation: ${this.layout.isPortrait() ? "portrait" : "landscape"}`);
        return;
      }
      this.input.track(name, true);
      // A key typed into the editor or a login field belongs to that field, not
      // to the scene — with one exception. An accelerator (anything held with
      // Ctrl or Cmd) has to work *while* the caret is in the editor, because
      // Ctrl+Enter to run is pressed by someone who has just finished typing,
      // and a shortcut that only works when the editor is unfocused is a
      // shortcut nobody finds.
      //
      // `target` is only sometimes a Node — a synthetic event dispatched at
      // `window` has `window` there — so the type is checked rather than
      // assumed; `contains` throws on anything else.
      const target = ev.target;
      const inOverlay = target instanceof Node && this.overlay.contains(target);
      if (inOverlay && !(ev.ctrlKey || ev.metaKey)) return;
      this.scene?.key?.(name, ev);
    });
    addEventListener("keyup", (ev) => {
      const name = loveKey(ev);
      if (name) this.input.track(name, false);
    });
  }

  // -- the banner ----------------------------------------------------------

  say(text: string, seconds = 4): void {
    this.toast = { text, until: performance.now() + seconds * 1000 };
  }

  private drawToast(g: Ctx): void {
    if (!this.toast) return;
    if (performance.now() > this.toast.until) {
      this.toast = null;
      return;
    }
    const { vw } = this.layout;
    const s = this.layout.uiScale();
    const h = Math.round(26 * s);
    // Under the header, not over it: the header says where you are, and a
    // banner that covers it trades one piece of information for another.
    const top = Math.round(38 * s);
    g.fillStyle = "rgba(216,40,0,0.92)";
    g.fillRect(0, top, vw, h);
    g.fillStyle = "rgba(40,24,16,1)";
    g.fillRect(0, top + h - 2, vw, 2);
    const f = ensureFonts(s).stationSm;
    g.font = f.css;
    g.textBaseline = "middle";
    g.textAlign = "center";
    g.fillStyle = "rgba(252,236,200,1)";
    g.fillText(this.toast.text.toUpperCase(), vw / 2, top + h / 2);
    g.textBaseline = "top";
    g.textAlign = "left";
  }

  /** The backdrop every screen starts from, so nothing is ever drawn on stale pixels. */
  clear(g: Ctx, r = Theme.void): void {
    g.fillStyle = `rgba(${Math.round(r[0] * 255)},${Math.round(r[1] * 255)},${Math.round(
      r[2] * 255,
    )},1)`;
    g.fillRect(0, 0, this.layout.vw, this.layout.vh);
  }
}
