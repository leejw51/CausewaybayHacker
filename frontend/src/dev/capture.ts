/**
 * The freeze-and-capture hook. Dev and e2e builds only.
 *
 * CWBHACKER_CAPTURE_SENTINEL — grep for this in a production `dist/`. It must
 * not be there.
 *
 * The problem it solves: a canvas game never stops changing, so a screenshot
 * tool that waits for the page to be idle waits for ever, and two screenshots
 * of "the same screen" are never the same picture. Neither a human reviewer
 * nor a visual-regression suite can work with that.
 *
 * So the loop can be stopped and driven by hand. `settle()` runs the game at a
 * fixed 1/60 step until every transition has finished and then freezes, which
 * makes a screenshot both *possible* and *deterministic* — the same call
 * produces the same frame, because nothing in the render path reads the wall
 * clock, only the `dt` it is handed (see `engine/motion.ts`).
 *
 * It is deliberately not a test harness. It exposes the loop, the layout and
 * a compositor, and nothing that could reach the wallet module.
 */
import type { App } from "../app";

const STEP = 1 / 60;

export interface CaptureApi {
  /** Stop the loop where it is. */
  freeze(): void;
  /** Hand the loop back to `requestAnimationFrame`. */
  resume(): void;
  frozen(): boolean;
  /** Advance exactly `n` frames of 1/60 s and stay frozen. */
  step(n?: number): number;
  /** Run `secs` of game time at a fixed step, then freeze. Default 2.5 s. */
  settle(secs?: number): number;
  /** Force an orientation without going through a key event. */
  orient(mode: "landscape" | "portrait"): void;
  /** The whole screen — both canvases and the DOM overlay — as a PNG data URL. */
  png(): string;
  scene(): string | null;
  orientation(): string;
  virtual(): [number, number];
  /** Device-pixel size of both canvases, for checking they actually match. */
  backing(): { game: [number, number]; fx: [number, number] };
  /**
   * Frames per second, averaged over the last two seconds of *real* frames.
   *
   * Read it in a separate call from whatever set the screen up, and never while
   * frozen. A driver that navigates and then measures in the same evaluation
   * gets the frame rate of a starved tab, which is a number that says nothing
   * about the machine.
   */
  fps(): number;
  /** Turn the tube on or off from a script, for a shot of each. */
  crt(on?: boolean): boolean;
  /**
   * Every button the current screen is hit-testing, by id.
   *
   * A canvas control has no DOM node, so an automated run either has this or a
   * geometric scan of the pixels — and the scan breaks every time a row
   * re-wraps, which is how three e2e tests went red when SUBMIT moved. The
   * rects come from the same `Buttons` objects the scene itself hits, so this
   * cannot disagree with what a click does.
   *
   * `rect` is in virtual pixels (the coordinates a scene thinks in) and
   * `client` is in CSS pixels relative to the viewport, which is what a driver
   * needs to dispatch a pointer event or to call `page.mouse.click`.
   */
  buttons(): Array<{
    id: string;
    label: string;
    dim: boolean;
    rect: [number, number, number, number];
    client: [number, number, number, number];
  }>;
  /** The middle of one button in CSS pixels, or null if it is not on screen. */
  buttonAt(id: string): [number, number] | null;
}

/**
 * Draw the DOM overlay — the seed field and the CodeMirror editor — into the
 * capture.
 *
 * A canvas cannot composite a DOM element, and those two are deliberately DOM
 * (a canvas has no clipboard and no IME). Left out, a screenshot of the quest
 * screen would show an empty well where the editor is, which is the single
 * most important thing on that screen. So their text is re-drawn here, in the
 * same place and at the same size the page has them.
 *
 * This is a *rendering* of the overlay, not a screengrab of it — the caret,
 * the selection and the syntax colours are not reproduced. Anyone reading a
 * shot should know that; it is stated wherever these are published.
 */
/**
 * What a field's text looks like *on the screen*, which is not always what is
 * in its `value`.
 *
 * The seed field is masked (`-webkit-text-security`, or a blur where that is
 * not implemented). A capture hook that painted `el.value` would take a
 * screenshot in which the twelve words are legible while the browser was
 * showing dots — and those screenshots go into `frontend/shots/` and into
 * pull requests. So the mask is read off the element and reproduced.
 *
 * It is done by reading the computed style rather than by special-casing the
 * login screen, so the rule is "the hook paints what is on screen" and any
 * future masked field is covered by it without anybody remembering to.
 */
function maskedFor(el: HTMLElement, text: string): string {
  let masked = el.classList.contains("cwb-masked");
  if (!masked) {
    try {
      const style = getComputedStyle(el);
      const sec =
        style.getPropertyValue("-webkit-text-security") || style.getPropertyValue("text-security");
      masked = sec.trim() !== "" && sec.trim() !== "none";
    } catch {
      /* an element with no computed style is not masked */
    }
  }
  if (!masked) return text;
  // Line structure is kept: a phrase pasted across two lines still looks like
  // two lines of something, which is information about the *shape* of what is
  // in the box and not about its content.
  return text
    .split("\n")
    .map((line) => "\u2022".repeat(line.length))
    .join("\n");
}

function paintOverlay(app: App, g: CanvasRenderingContext2D): void {
  // The overlay host is hidden outright while a modal is up, so that the
  // canvas-drawn dialogue is genuinely on top. A capture that painted the
  // editor anyway would show a bug that is not there — worse than showing one
  // that is, because it sends someone looking for it.
  if (getComputedStyle(app.overlay).visibility === "hidden") return;
  const host = app.overlay.getBoundingClientRect();
  const dpr = app.canvas.width / Math.max(1, app.canvas.clientWidth);
  for (const el of Array.from(app.overlay.children) as HTMLElement[]) {
    if (el.classList.contains("cwb-hidden")) continue;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) continue;
    const x = (r.left - host.left) * dpr;
    const y = (r.top - host.top) * dpr;
    const w = r.width * dpr;
    const h = r.height * dpr;

    const size = parseFloat(getComputedStyle(el).fontSize || "14") * dpr;
    const lineH = Math.round(size * 1.2);
    g.save();
    g.beginPath();
    g.rect(x, y, w, h);
    g.clip();
    g.fillStyle = "rgba(10,8,26,0.98)";
    g.fillRect(x, y, w, h);
    g.font = `${Math.round(size)}px "VT323", ui-monospace, monospace`;
    g.textBaseline = "top";

    const lines: string[] = [];
    let colour = "#fcecc8";
    if (el instanceof HTMLTextAreaElement) {
      if (el.value) lines.push(...maskedFor(el, el.value).split("\n"));
      else {
        lines.push(el.placeholder);
        colour = "#786858";
      }
    } else {
      // CodeMirror keeps one element per line; its own gutter is drawn too, so
      // the numbers in the picture are the numbers on the screen.
      for (const line of Array.from(el.querySelectorAll(".cm-line"))) {
        lines.push((line.textContent ?? "").replace(/\u200b/g, ""));
      }
    }
    g.fillStyle = colour;
    const pad = Math.round(6 * dpr);
    lines.forEach((line, i) => g.fillText(line, x + pad, y + pad + i * lineH));
    g.restore();
  }
}

export function install(app: App): void {
  const drive = (frames: number): number => {
    app.freeze();
    for (let i = 0; i < frames; i++) app.tick(STEP);
    return frames;
  };

  const api: CaptureApi = {
    freeze: () => app.freeze(),
    resume: () => app.resume(),
    frozen: () => app.isFrozen,
    step: (n = 1) => drive(n),
    settle: (secs = 2.5) => drive(Math.round(secs / STEP)),
    orient: (mode) => {
      app.setOrientation(mode);
      // One frame so the new layout is what the next capture sees, rather
      // than the old one with a new canvas size.
      if (app.isFrozen) app.tick(STEP);
    },
    png: () => {
      const out = document.createElement("canvas");
      out.width = app.canvas.width;
      out.height = app.canvas.height;
      const g = out.getContext("2d");
      if (!g) return "";
      // The WebGL layer first, then the pixel art over it — the same order the
      // stylesheet stacks them in.
      g.fillStyle = "#0b1030";
      g.fillRect(0, 0, out.width, out.height);
      try {
        g.drawImage(app.fx, 0, 0, out.width, out.height);
      } catch {
        /* a lost context just means a flat backdrop in the picture */
      }
      g.drawImage(app.canvas, 0, 0);
      paintOverlay(app, g);
      return out.toDataURL("image/png");
    },
    scene: () => app.currentScene?.name ?? null,
    orientation: () => (app.layout.isPortrait() ? "portrait" : "landscape"),
    virtual: () => [app.layout.vw, app.layout.vh],
    backing: () => ({
      game: [app.canvas.width, app.canvas.height],
      fx: [app.fx.width, app.fx.height],
    }),
    fps: () => app.fps(),
    buttons: () => {
      const out: ReturnType<CaptureApi["buttons"]> = [];
      for (const list of app.currentScene?.controls?.() ?? []) {
        for (const b of list.list()) {
          const [x, y, w, h] = b.rect;
          const [left, top] = app.layout.toClient(x, y);
          const [right, bottom] = app.layout.toClient(x + w, y + h);
          out.push({
            id: b.id,
            label: b.label,
            dim: b.dim === true,
            rect: [x, y, w, h],
            client: [left, top, right - left, bottom - top],
          });
        }
      }
      return out;
    },
    buttonAt: (id: string) => {
      const hit = api.buttons().find((b) => b.id === id);
      if (!hit) return null;
      return [hit.client[0] + hit.client[2] / 2, hit.client[1] + hit.client[3] / 2];
    },
    crt: (on?: boolean) => {
      if (on !== undefined && on !== app.crt.enabled) app.toggleCrt();
      else if (on === undefined) app.toggleCrt();
      if (app.isFrozen) app.tick(STEP);
      return app.crt.enabled;
    },
  };

  (globalThis as Record<string, unknown>).__cwbCapture = api;
  // The older, smaller peephole some of the existing probes use.
  (globalThis as Record<string, unknown>).__cwb = {
    scene: api.scene,
    orientation: api.orientation,
    virtual: api.virtual,
  };

  // `?freeze=1` brings the page up already settled and stopped, which is what
  // a screenshot run wants without having to script anything first.
  try {
    if (new URLSearchParams(location.search).get("freeze") === "1") {
      setTimeout(() => api.settle(), 400);
    }
  } catch {
    /* no location in some embedders */
  }
}
