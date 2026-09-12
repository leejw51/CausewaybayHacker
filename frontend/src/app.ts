/**
 * The shell: one layout, one loop, one scene at a time, one city behind them.
 *
 * Everything a scene is allowed to touch hangs off `App`. Notably absent from
 * that list is any game state — no progress, no quest list, no cleared set.
 * A scene asks the server, draws the answer and forgets it, which is what
 * makes "a reload loses nothing" true rather than aspirational (SPEC §6.4),
 * and what makes logging out a matter of dropping two references rather than
 * hunting for caches.
 */
import { Layout, type Orientation } from "./engine/layout";
import { Input, loveKey } from "./engine/input";
import { Assets } from "./engine/assets";
import { ensureFonts, printf, remeasure, wrap } from "./engine/text";
import { css, Theme } from "./engine/theme";
import { btnBox, fill, inRect, panel, pixBtn, type Ctx, type Rect } from "./engine/ui";
import { seconds, reducedMotion, Tween } from "./engine/motion";
import { expInOut } from "./engine/ease";
import { Backdrop, type Mood } from "./gfx/backdrop";
import { Crt } from "./gfx/crt";
import { Client } from "./net/client";
import type { Land } from "./net/protocol";
import type { Buttons } from "./ui/chrome";
import { Chip } from "./audio/sfx";
import { wipe as wipeKey } from "./wallet/wallet";
import { localeInfo, nextLocale, setLocale, t } from "./i18n";

export interface Scene {
  readonly name: string;
  /** What the city does behind this screen. */
  readonly mood: Mood;
  enter?(): void | Promise<void>;
  leave?(): void;
  update?(dt: number): void;
  draw(g: Ctx): void;
  /** Virtual coordinates, already clipped to the canvas. */
  pointer?(x: number, y: number, phase: "down" | "move" | "up"): void;
  /** A LÖVE-flavoured key name from `engine/input.ts`. */
  key?(name: string, ev: KeyboardEvent): void;
  /** Wheel or trackpad, in virtual pixels. Positive is downwards. */
  wheel?(dy: number, x: number, y: number): void;
  /** The window changed shape or orientation; rebuild anything cached. */
  resized?(): void;
  /** True when leaving would throw away something the player typed. */
  unsaved?(): boolean;
  /** Which land the city should be tinted for, if the screen knows. */
  land?: Land;
  /**
   * The screen's button lists, for `dev/capture.ts` only.
   *
   * Nothing in the game reads this — it is how an automated run finds a
   * control that has no DOM node. The lists are the same objects the scene
   * hit-tests against, so what the hook reports and what a click actually
   * hits cannot drift apart.
   */
  controls?(): Buttons[];
}

/** Where the player's chosen orientation is kept. A preference, not a secret. */
const ORIENT_KEY = "cwbhacker.orientation";
/** And whether they want the tube. Default on; the choice is theirs to keep. */
const CRT_KEY = "cwbhacker.crt";

/**
 * How fast a screen stops shaking, in trauma per second.
 *
 * The shake is `trauma²` rather than `trauma`, which is the Vlambeer trick: the
 * square makes a big hit feel disproportionately bigger than a small one and
 * makes the tail-off die away rather than trail.
 */
const TRAUMA_DECAY = 1.9;

/**
 * The three screens SPEC §10 lists after the main run — search, stats, ai.
 *
 * They are on function keys next to F1/F2/F3 and reachable from every screen
 * for the same reason the orientation toggle is: a way in that only exists on
 * one screen is a way in nobody finds. Imported on demand, exactly as
 * `logout()` imports the login screen, so the shell does not depend on them.
 */
const AUX: Record<string, ((app: App) => Promise<Scene>) | undefined> = {
  f4: async (app) => new (await import("./scenes/search")).SearchScene(app),
  f5: async (app) => new (await import("./scenes/stats")).StatsScene(app),
  f6: async (app) => new (await import("./scenes/ai")).AiScene(app),
};

/** A screen change, in the direction of travel. */
export type Direction = "forward" | "back" | "none";

/**
 * How the change is drawn. `slide` carries both screens across together;
 * `iris` closes a circle on a point, swaps, and opens it again — which is what
 * a 16-bit game does when you step into a door, and the map's nodes are doors.
 */
type TransitionKind = "slide" | "iris";

interface Modal {
  title: string;
  body: string;
  confirm: string;
  cancel: string;
  resolve: (ok: boolean) => void;
  tween: Tween;
  rects: { confirm: Rect; cancel: Rect } | null;
  hover: "confirm" | "cancel" | null;
}

/**
 * How tall the confirmation dialogue has to be to hold its own question.
 *
 * This used to be a flat 190px, which is two lines of English and silently
 * hides everything past that: the Korean "clear the stack?" body wraps to four
 * and the last two printed *underneath* the buttons. A dialogue that crops the
 * sentence explaining what it is about to destroy is worse than no dialogue,
 * and it fails in exactly the languages nobody writing it reads — so the body
 * is measured and the panel is built around it.
 *
 * Floored at the old height so the short English questions this was tuned
 * against keep the proportions they had.
 */
export function askHeight(
  s: number,
  bodyTop: number,
  bodyLines: number,
  lineH: number,
  buttonH: number,
): number {
  // Body, a breath, the buttons, and the same 18px skirt they always had.
  const needed = bodyTop + bodyLines * lineH + Math.round(20 * s) + buttonH + Math.round(18 * s);
  return Math.max(Math.round(190 * s), needed);
}

export class App {
  readonly layout: Layout;
  readonly input = new Input();
  readonly g: Ctx;
  readonly chip = new Chip();
  readonly backdrop: Backdrop | null;
  /** The tube. Drawn last, on `#game`, which is under the editor's own layer. */
  readonly crt = new Crt();
  assets: Assets | null = null;

  /** Set at login, cleared at logout. Display only, and the logout button. */
  addressLabel = "";
  /**
   * Where the header drew its logout chip this frame, and whether the pointer
   * is over it. The header is app-level furniture on every authed screen, so
   * the hit test lives here — a scene that forgot to wire it would be a screen
   * you cannot log out of, which is exactly the bug this is replacing.
   */
  logoutRect: Rect | null = null;
  logoutHover = false;

  private scene: Scene | null = null;
  /** The screen being slid off, drawn until the transition finishes. */
  private outgoing: Scene | null = null;
  private transition: Tween | null = null;
  private direction: Direction = "none";
  private kind: TransitionKind = "slide";
  /** Where the iris closes, in virtual pixels. */
  private irisAt: [number, number] = [0, 0];

  /** Screen shake, 0..1, and its own clock. Never `Math.random` — see `shake`. */
  private trauma = 0;
  private shakeT = 0;

  /** The last two seconds of frame times, for `__cwbCapture.fps()`. */
  private readonly frames = new Float32Array(120);
  private frameAt = 0;

  private last = 0;
  private raf = 0;
  private frozen = false;
  /** The instant `freeze()` happened, so `now()` can hold still. */
  private frozenAt = Date.now();
  private modal: Modal | null = null;
  /** A one-line banner for anything the player needs told: errors, reconnects. */
  private toast: { text: string; left: number; tween: Tween } | null = null;

  /** Set by `logout()` so the login screen can say why it is being shown. */
  loggedOutNotice = "";

  /** True only while `logout()` is tearing the socket down on purpose. */
  private closingOnPurpose = false;

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
    this.backdrop = Backdrop.create(fx);

    this.restoreOrientation();
    try {
      this.crt.enabled = localStorage.getItem(CRT_KEY) !== "off";
    } catch {
      /* a browser with storage blocked still gets the default, which is on */
    }

    addEventListener("resize", () => this.measure());
    addEventListener("orientationchange", () => this.measure());
    addEventListener("blur", () => this.input.releaseAll());
    this.wirePointer();
    this.wireKeys();

    // The connection banner is the app's, not a scene's: it has to be visible
    // on whichever screen the player happens to be on when the server goes.
    client.onState((s) => {
      // A logout closes the socket on purpose. Announcing that as a failure
      // would put a red alarm across the login screen the player just asked
      // for, so the deliberate case is swallowed here.
      if (s === "offline" && !this.closingOnPurpose) this.say(t("app.connLost"));
      if (s === "authed") this.toast = null;
    });
    client.on("server.bye", (p) => this.say(p.reason));
  }

  // -- the loop ------------------------------------------------------------

  start(scene: Scene): void {
    this.measure();
    void this.go(scene, "none");
    this.last = performance.now();
    const frame = (t: number) => {
      this.raf = requestAnimationFrame(frame);
      if (this.frozen) return;
      // Clamped: a tab that was in the background for a minute must not hand
      // the scene a sixty-second `dt` and teleport everything.
      const dt = Math.min(0.05, (t - this.last) / 1000);
      this.last = t;
      // Measured here rather than inside `tick`, because the capture hook also
      // calls `tick` — at a fixed 1/60 — and a frame rate averaged over
      // synthetic steps is a number that means nothing.
      this.frames[this.frameAt] = dt;
      this.frameAt = (this.frameAt + 1) % this.frames.length;
      this.tick(dt);
    };
    this.raf = requestAnimationFrame(frame);
  }

  stop(): void {
    cancelAnimationFrame(this.raf);
  }

  /**
   * One update and one frame. Split out from the loop so the capture hook can
   * drive the whole game at a fixed step and get the same picture every run.
   */
  tick(dt: number): void {
    this.shakeT += dt;
    this.trauma = Math.max(0, this.trauma - dt * TRAUMA_DECAY);
    if (this.transition) {
      this.transition.update(dt);
      this.outgoing?.update?.(dt);
      if (this.transition.finished) {
        this.transition = null;
        this.outgoing = null;
      }
    }
    this.modal?.tween.update(dt);
    this.toast?.tween.update(dt);
    if (this.toast) {
      this.toast.left -= dt;
      if (this.toast.left <= 0) this.toast = null;
    }
    this.scene?.update?.(dt);
    // After the scenes, not before: the overworld plane has to be asked for
    // again every frame (`Backdrop.showMap`) and this is the call that both
    // consumes the request and clears it. Updating the city first would put a
    // frame of lag between "the map screen is gone" and "the ground is gone",
    // and that one frame is a ground plane showing through the quest screen.
    this.backdrop?.update(dt);
    this.crt.update(dt);
    this.render();
  }

  /**
   * Which scene, if any, is entitled to the WebGL ground plane this frame.
   *
   * Only one screen can be on the GPU at a time, so during a slide — where two
   * screens are on the canvas at once, at two different offsets — nobody gets
   * it and the map falls back to the flat blit it has always had. During an
   * iris only one screen is visible at a time, so the answer is simply which
   * half of the iris we are in.
   */
  get mapLayerScene(): Scene | null {
    if (!this.transition) return this.scene;
    if (this.kind === "iris") {
      return this.transition.raw < 0.5 ? (this.outgoing ?? this.scene) : this.scene;
    }
    return null;
  }

  /**
   * Hit the screen.
   *
   * `amount` is 0..1 and accumulates, so three small failures in a row build
   * rather than each cancelling the last. It is driven by `shakeT`, which is
   * the accumulated `dt` — sine of a clock the capture hook controls, not
   * `Math.random`, so a shaken frame is the same shaken frame every run.
   *
   * It refuses to fire while the DOM overlay has anything in it. The editor and
   * the seed field are real elements stacked above the canvas and they are not
   * shaken by a canvas transform: a screen that trembled around a perfectly
   * still block of code would read as a rendering fault, not as impact.
   */
  shake(amount: number): void {
    if (this.overlay.childElementCount > 0) return;
    if (reducedMotion()) amount *= 0.3;
    this.trauma = Math.min(1, this.trauma + amount);
  }

  private shakeOffset(): [number, number] {
    if (this.trauma <= 0.001) return [0, 0];
    // 26 rather than the 9 this started at: at nine, a wrong answer moved the
    // screen two pixels and a compile error seven, which is a jitter rather
    // than a hit. Measured by taking the frame, not by reasoning about it.
    const k = this.trauma * this.trauma * 26 * this.layout.uiScale();
    return [
      Math.round(Math.sin(this.shakeT * 37.1) * k),
      Math.round(Math.sin(this.shakeT * 51.7) * k * 0.8),
    ];
  }

  /** Dev/e2e only: stop the loop so a screenshot has something still to take. */
  freeze(): void {
    if (!this.frozen) this.frozenAt = Date.now();
    this.frozen = true;
  }

  /**
   * The wall clock, as the game is allowed to see it.
   *
   * Almost nothing may read the real one — the whole render path is frame
   * driven so a capture is reproducible. The countdown is the exception the
   * spec forces: §4.8b's deadline is an instant on the *server*, and a client
   * that decremented its own counter would come back wrong from a backgrounded
   * tab. So it re-derives from here every frame, and here stands still while
   * the capture hook is frozen — a screenshot of a clock has to be the same
   * screenshot twice.
   */
  now(): number {
    return this.frozen ? this.frozenAt : Date.now();
  }

  resume(): void {
    if (!this.frozen) return;
    this.frozen = false;
    this.last = performance.now();
  }

  get isFrozen(): boolean {
    return this.frozen;
  }

  /**
   * @param iris the virtual point the transition should close on. Given, the
   * change is an iris out of that point and back in; omitted, the two screens
   * slide past each other as they always have.
   */
  async go(next: Scene, direction: Direction = "forward", iris?: [number, number]): Promise<void> {
    const old = this.scene;
    old?.leave?.();
    // The outgoing screen keeps being drawn — its DOM overlay is already gone,
    // which is correct: an editor that slid across the screen would look like
    // a bug rather than a transition.
    this.outgoing = direction === "none" ? null : old;
    this.direction = direction;
    this.kind = iris && direction !== "none" ? "iris" : "slide";
    if (iris) this.irisAt = iris;
    this.transition = direction === "none" ? null : new Tween(seconds("scene"));
    this.scene = next;
    this.backdrop?.setMood(next.mood, next.land ?? "rust");
    await next.enter?.();
  }

  get currentScene(): Scene | null {
    return this.scene;
  }

  private render(): void {
    const { g, layout } = this;
    ensureFonts(layout.uiScale());
    this.backdrop?.render();
    layout.begin(g);
    g.imageSmoothingEnabled = false;

    const [sx, sy] = this.shakeOffset();
    if (sx || sy) g.translate(sx, sy);

    if (this.transition && this.kind === "iris") {
      // One screen at a time. The swap happens at the midpoint, where the hole
      // is closed and there is nothing to see through it.
      const shown = this.mapLayerScene;
      shown?.draw(g);
    } else if (this.transition && this.outgoing) {
      // Both screens travel on the same expo curve, so the pair moves as one
      // object rather than as two things that happen to be sliding.
      const t = this.transition.inOut;
      const away = this.direction === "back" ? layout.vw : -layout.vw;
      this.drawShifted(this.outgoing, away * t);
      this.drawShifted(this.scene, -away * (1 - t));
    } else {
      this.scene?.draw(g);
    }

    if (sx || sy) g.translate(-sx, -sy);
    this.drawToast(g);
    this.drawModal(g);
    this.frameEdge();
    this.drawIris();
    this.crt.draw(g, layout.dw, layout.dh, layout.scale);
  }

  /**
   * The hole.
   *
   * Drawn in device space over the whole canvas, bands included, because an
   * iris that stops at the edge of the playfield is a circle on a picture
   * rather than a shutter in front of one. Two expo halves: closed to nothing,
   * then open again from the same point.
   */
  private drawIris(): void {
    const t = this.transition;
    if (!t || this.kind !== "iris") return;
    const { g, layout } = this;
    const { ox, oy, scale, dw, dh } = layout;
    const cx = this.irisAt[0] * scale + ox;
    const cy = this.irisAt[1] * scale + oy;
    const reach = Math.max(
      Math.hypot(cx, cy),
      Math.hypot(dw - cx, cy),
      Math.hypot(cx, dh - cy),
      Math.hypot(dw - cx, dh - cy),
    );
    const raw = t.raw;
    const k = raw < 0.5 ? 1 - expInOut(raw * 2) : expInOut((raw - 0.5) * 2);
    const r = Math.max(0, reach * k);
    g.save();
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.fillStyle = "rgba(6,6,20,1)";
    g.beginPath();
    g.rect(0, 0, dw, dh);
    g.arc(cx, cy, r, 0, Math.PI * 2, true);
    g.fill("evenodd");
    // A rim on the shutter, so the circle reads as an aperture rather than as
    // a hole punched in a flat fill.
    if (r > 2) {
      g.strokeStyle = "rgba(248,208,48,0.35)";
      g.lineWidth = Math.max(1, 2 * scale);
      g.beginPath();
      g.arc(cx, cy, r, 0, Math.PI * 2);
      g.stroke();
      g.lineWidth = 1;
    }
    g.restore();
  }

  /** Frames per second, averaged over the ring. Zero before it has filled. */
  fps(): number {
    let sum = 0;
    let n = 0;
    for (const v of this.frames) {
      if (v > 0) {
        sum += v;
        n++;
      }
    }
    return n > 0 ? Math.round(n / sum) : 0;
  }

  /** Turn the tube on or off, and remember which. */
  toggleCrt(): boolean {
    this.crt.enabled = !this.crt.enabled;
    try {
      localStorage.setItem(CRT_KEY, this.crt.enabled ? "on" : "off");
    } catch {
      /* the choice still holds for this session */
    }
    return this.crt.enabled;
  }

  /**
   * Treat the seam.
   *
   * The WebGL city is sized to the whole window while the game is drawn into a
   * virtual canvas inset within it, so on most window shapes there are bands of
   * city down the sides or across the top. Letting them run is the right
   * instinct — black bars would be worse — but untreated they make the play
   * area's edge read as a crop: the header's rule and the footer bar simply
   * stop, with a lit skyline continuing behind them.
   *
   * So the bands are pushed back with a soft fall-off and the playfield gets a
   * hard ink rule around it. That is the 16-bit way of saying "the game is in
   * here", and it costs two gradients.
   */
  private frameEdge(): void {
    const { g, layout } = this;
    const { ox, oy, dw, dh } = layout;
    if (ox <= 0 && oy <= 0) return;
    g.save();
    g.setTransform(1, 0, 0, 1, 0, 0);
    const w = dw - ox * 2;
    const h = dh - oy * 2;
    // Per axis. One `reach` taken from the smaller of the two offsets meant
    // that a window with a two-pixel side band and a four-hundred-pixel top
    // band treated the top band with a two-pixel gradient, which is no
    // treatment at all — the case a column-shaped window lands in.
    const reachX = Math.max(24, ox * 0.9);
    const reachY = Math.max(24, oy * 0.9);
    if (ox > 0) {
      for (const [x0, x1, x, wide] of [
        [ox, ox - reachX, 0, ox],
        [dw - ox, dw - ox + reachX, dw - ox, ox],
      ] as const) {
        const grad = g.createLinearGradient(x0, 0, x1, 0);
        grad.addColorStop(0, "rgba(10,14,40,0.55)");
        grad.addColorStop(1, "rgba(6,8,24,0.97)");
        g.fillStyle = grad;
        g.fillRect(x, 0, wide, dh);
      }
    }
    if (oy > 0) {
      for (const [y0, y1, y, tall] of [
        [oy, oy - reachY, 0, oy],
        [dh - oy, dh - oy + reachY, dh - oy, oy],
      ] as const) {
        const grad = g.createLinearGradient(0, y0, 0, y1);
        grad.addColorStop(0, "rgba(10,14,40,0.55)");
        grad.addColorStop(1, "rgba(6,8,24,0.97)");
        g.fillStyle = grad;
        g.fillRect(0, y, dw, tall);
      }
    }
    // Two rules, ink outside and gold inside: the edge of a screen set into a
    // cabinet. One dark line on a night sky is not an edge, it is a scratch.
    g.strokeStyle = css(Theme.ink);
    g.lineWidth = 4;
    g.strokeRect(ox - 2, oy - 2, w + 4, h + 4);
    g.strokeStyle = css(Theme.coin, 0.5);
    g.lineWidth = 2;
    g.strokeRect(ox - 1, oy - 1, w + 2, h + 2);
    g.lineWidth = 1;
    g.restore();
  }

  private drawShifted(scene: Scene | null, dx: number): void {
    if (!scene) return;
    const g = this.g;
    g.save();
    g.translate(Math.round(dx), 0);
    scene.draw(g);
    g.restore();
  }

  private measure(): void {
    if (!this.layout.measure()) return;
    remeasure();
    // The WebGL canvas gets the same backing store as the 2D one. Left to
    // itself it keeps the browser's default 300x150 and is stretched to the
    // window by CSS, which is a quarter-resolution backdrop in the wrong place.
    this.fx.width = this.layout.dw;
    this.fx.height = this.layout.dh;
    this.backdrop?.resize(this.layout.dw, this.layout.dh);
    this.crt.resized();
    this.scene?.resized?.();
  }

  /** Re-read the window on demand — the orientation toggle and the capture hook. */
  remeasure(): void {
    this.layout.measure();
    remeasure();
    this.fx.width = this.layout.dw;
    this.fx.height = this.layout.dh;
    this.backdrop?.resize(this.layout.dw, this.layout.dh);
    this.crt.resized();
    this.scene?.resized?.();
  }

  /**
   * Force an orientation for this window, without recording it as a *choice*.
   *
   * The only caller is the capture hook, and the capture hook is not the
   * player: a screenshot run that wrote `chosen,landscape,…` into localStorage
   * would leave a real preference behind on whatever machine took the shots.
   * F1 saves; this does not.
   */
  setOrientation(mode: Orientation): void {
    this.layout.pin(mode);
    this.remeasure();
  }

  /**
   * Read back the saved orientation.
   *
   * Three things can be in there and they are three different values, which is
   * the whole fix:
   *
   *   - `chosen,<mode>,<w>,<h>` — somebody pressed F1, in a window of that
   *     shape. Honoured, and suspended only while a decisively different window
   *     is on screen (`Layout.measure`).
   *   - `auto` — somebody pressed F1 until it said automatic. Follow the window.
   *   - a bare `portrait`/`landscape` — written by the build that had no such
   *     distinction, where *restoring* a preference was recorded as *choosing*
   *     one. It is read as **not pinned**, which is the safe side: it is the
   *     exact record that put the landscape layout into a 1080x1730 window and
   *     left 47% of it empty, and nothing in it says the player ever asked for
   *     that.
   */
  private restoreOrientation(): void {
    let raw: string | null = null;
    try {
      raw = localStorage.getItem(ORIENT_KEY);
    } catch {
      return;
    }
    if (!raw) return;
    const parts = raw.split(",");
    if (parts[0] !== "chosen") return;
    const mode = parts[1];
    if (mode !== "portrait" && mode !== "landscape") return;
    const w = +parts[2];
    const h = +parts[3];
    const shape: [number, number] | null =
      Number.isFinite(w) && Number.isFinite(h) && w > 0 && h > 0 ? [w, h] : null;
    this.layout.pin(mode as Orientation, shape);
  }

  private saveOrientation(
    picked: Orientation | "auto" = this.layout.isPortrait() ? "portrait" : "landscape",
  ): void {
    try {
      if (picked === "auto") {
        localStorage.setItem(ORIENT_KEY, "auto");
        return;
      }
      const [w, h] = this.layout.choiceShape;
      localStorage.setItem(ORIENT_KEY, `chosen,${picked},${w},${h}`);
    } catch {
      /* the choice still holds for this session */
    }
  }

  // -- the session ---------------------------------------------------------

  /**
   * Log out, from any screen.
   *
   * The order matters. The key is wiped first, because that is the part that
   * must happen even if something below throws. Then the token, then the
   * socket — a connection is authenticated for its whole life (PROTOCOL §3.1)
   * and never goes back to anonymous, so the only way to stop being this user
   * is to close it and open another.
   *
   * Nothing else needs clearing, and that is by design: no scene holds
   * progress, so the second wallet cannot see the first one's map.
   */
  async logout(reason = ""): Promise<boolean> {
    if (this.scene?.unsaved?.()) {
      const ok = await this.ask({
        title: t("app.logoutTitle"),
        body: t("app.logoutBody"),
        confirm: t("app.logout"),
        cancel: t("app.keepWriting"),
      });
      if (!ok) return false;
    }
    wipeKey();
    this.client.forgetToken();
    this.closingOnPurpose = true;
    this.client.close();
    this.addressLabel = "";
    this.loggedOutNotice = reason;
    this.chip.music("stop");
    // A fresh connection, anonymous, ready for whoever logs in next.
    this.client.connect();
    this.closingOnPurpose = false;
    // Anything the old session had to say is about a session that is gone.
    this.toast = null;
    const { LoginScene } = await import("./scenes/login");
    await this.go(new LoginScene(this), "back");
    return true;
  }

  // -- a question the player has to answer ---------------------------------

  ask(q: { title: string; body: string; confirm: string; cancel: string }): Promise<boolean> {
    // A second question while one is open would stack two modals; the first
    // one wins and the second is declined, which is the safe answer for a
    // dialogue whose only job is to stop something destructive.
    if (this.modal) return Promise.resolve(false);
    // The editor and the seed field are DOM, stacked *above* the canvas by the
    // stylesheet, so a modal drawn on the canvas would appear behind them —
    // and a confirmation you can click straight through is not a
    // confirmation. The whole overlay is hidden for as long as the question
    // is on screen.
    this.overlay.style.visibility = "hidden";
    return new Promise<boolean>((resolve) => {
      this.modal = {
        ...q,
        resolve,
        tween: new Tween(seconds("panel")),
        rects: null,
        hover: null,
      };
    });
  }

  private answer(ok: boolean): void {
    const m = this.modal;
    if (!m) return;
    this.modal = null;
    this.overlay.style.visibility = "";
    this.chip.select();
    m.resolve(ok);
  }

  get modalOpen(): boolean {
    return this.modal !== null;
  }

  private drawModal(g: Ctx): void {
    const m = this.modal;
    if (!m) return;
    const { layout } = this;
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    const t = m.tween.out;

    fill(g, Theme.void, 0, 0, layout.vw, layout.vh, 0.72 * t);

    const w = Math.min(layout.vw - 40 * s, 520 * s);
    const x = Math.round((layout.vw - w) / 2);

    // Tall enough for the question it is actually asking.
    //
    // This was a flat 190px, which fits two lines of English and silently
    // hides the rest: the Korean "clear the stack?" body wraps to four and the
    // last two printed underneath the buttons. A dialogue that crops the
    // sentence explaining what it is about to destroy is worse than no
    // dialogue, and it fails in exactly the languages nobody writing it reads.
    // So the body is measured first and the panel is built around it.
    const bodyTop = Math.round(56 * s);
    const bodyW = w - Math.round(40 * s);
    const bodyLines = wrap(fonts.small, m.body, bodyW).length;
    const [bw, bh] = btnBox(
      fonts.button,
      [m.confirm, m.cancel],
      0,
      fonts.button.size * 2,
      layout.minTouchH(),
    );
    const h = askHeight(s, bodyTop, bodyLines, fonts.small.height, bh);
    // The dialogue drops in and settles rather than fading up, so it reads as
    // something that arrived to stop you rather than something that was
    // always there.
    const y = Math.round((layout.vh - h) / 2 - (1 - t) * 60 * s);
    panel(g, x, y, w, h, Theme.paper);

    g.fillStyle = css(Theme.coin);
    printf(g, fonts.station, m.title, x, y + Math.round(22 * s), w, "center");
    g.fillStyle = css(Theme.cream);
    printf(g, fonts.small, m.body, x + Math.round(20 * s), y + bodyTop, bodyW, "center");

    const gap = Math.round(12 * s);
    const by = y + h - bh - Math.round(18 * s);
    const cancelRect: Rect = [Math.round(x + w / 2 - bw - gap / 2), by, bw, bh];
    const confirmRect: Rect = [Math.round(x + w / 2 + gap / 2), by, bw, bh];
    m.rects = { cancel: cancelRect, confirm: confirmRect };
    // The safe answer is the lit one. Every `ask()` in this game is asking
    // before something destructive, so the button that keeps the player's work
    // gets the weight and the one that throws it away has to be chosen on
    // purpose.
    pixBtn(g, fonts.button, ...cancelRect, m.cancel, {
      hover: m.hover === "cancel",
      lit: m.hover !== "confirm",
    });
    pixBtn(g, fonts.button, ...confirmRect, m.confirm, {
      hover: m.hover === "confirm",
      quiet: m.hover !== "confirm",
    });
  }

  // -- input ---------------------------------------------------------------

  private wirePointer(): void {
    const send = (ev: PointerEvent, phase: "down" | "move" | "up") => {
      const v = this.layout.toVirtual(ev.clientX, ev.clientY);
      if (!v) return;
      const m = this.modal;
      if (m) {
        // A modal eats the screen underneath it. Anything else would let a
        // player press RUN through the dialogue asking whether to discard it.
        if (!m.rects) return;
        if (phase === "move") {
          m.hover = inRect(v[0], v[1], m.rects.confirm)
            ? "confirm"
            : inRect(v[0], v[1], m.rects.cancel)
              ? "cancel"
              : null;
          return;
        }
        if (phase !== "down") return;
        if (inRect(v[0], v[1], m.rects.confirm)) this.answer(true);
        else if (inRect(v[0], v[1], m.rects.cancel)) this.answer(false);
        return;
      }
      if (this.logoutRect) {
        const over = inRect(v[0], v[1], this.logoutRect);
        if (phase === "move") this.logoutHover = over;
        if (over && phase === "down") {
          this.chip.select();
          void this.logout();
          return;
        }
      }
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
    this.canvas.addEventListener(
      "wheel",
      (ev) => {
        const v = this.layout.toVirtual(ev.clientX, ev.clientY);
        if (!v || this.modal) return;
        // The page cannot scroll — there is nothing to scroll — so the wheel
        // belongs to whatever the cursor is over.
        ev.preventDefault();
        this.scene?.wheel?.(ev.deltaY / this.layout.scale, v[0], v[1]);
      },
      { passive: false },
    );
  }

  private wireKeys(): void {
    addEventListener("keydown", (ev) => {
      const name = loveKey(ev);
      if (!name) return;

      if (this.modal) {
        if (name === "escape") this.answer(false);
        if (name === "return" || name === "kpenter") this.answer(true);
        ev.preventDefault();
        return;
      }

      // F1 pins the orientation, everywhere, on every screen — the spec calls
      // both orientations first-class, so the toggle cannot belong to the map.
      if (name === "f1") {
        ev.preventDefault();
        const picked = this.layout.cycleOrientation();
        this.remeasure();
        this.saveOrientation(picked);
        this.say(
          picked === "auto"
            ? t("app.orientAuto")
            : picked === "portrait"
              ? t("app.orientPortrait")
              : t("app.orientLandscape"),
        );
        return;
      }
      // F2 is the tube. On by default and remembered, because a scanline mask
      // is a taste and somebody reading code through it for an hour may not
      // share ours.
      if (name === "f2") {
        ev.preventDefault();
        this.say(this.toggleCrt() ? t("app.crtOn") : t("app.crtOff"));
        return;
      }
      // F3 logs out from anywhere, including mid-quest. It is on a function
      // key rather than a letter because every letter belongs to the editor.
      if (name === "f3") {
        ev.preventDefault();
        if (this.client.state === "authed") void this.logout();
        return;
      }
      // F7 cycles the language, from any screen, exactly like F1 and F2 — a
      // language you can only choose on the title card is a language you
      // cannot change once you are three screens in and have realised the
      // interface is in one you do not read. The toast names the new language
      // *in that language*, which is the only label that helps somebody who
      // has just pressed it by accident.
      if (name === "f7") {
        ev.preventDefault();
        const next = nextLocale();
        void setLocale(next);
        this.say(t("app.language", { name: localeInfo(next).label }));
        return;
      }
      // F4/F5/F6: search, stats, AI mode. See `AUX` above. They need a session
      // like every other screen that asks the server anything, and they refuse
      // to re-enter the screen you are already on — F5 twice on the stats
      // screen would otherwise re-run four requests and replay the arrival.
      const aux = AUX[name];
      if (aux) {
        ev.preventDefault();
        if (this.client.state !== "authed") return;
        const already = { f4: "search", f5: "stats", f6: "ai" }[name];
        if (this.scene?.name === already) return;
        void aux(this).then((s) => this.go(s, "forward"));
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

  say(text: string, secs = 4): void {
    this.toast = { text, left: secs, tween: new Tween(seconds("panel")) };
  }

  /**
   * How much room the banner is taking under the header, in virtual pixels.
   *
   * Zero when there is none. It exists because the banner is drawn *over* the
   * screen and one screen — the quest bench — now puts a toolbar in exactly
   * the band it slides into, so "connection lost" would paint across BACK TO
   * MAP and PASTE. The screens that have something there ask for this and give
   * up the height; everything else is unaffected and does not have to know.
   *
   * The height is the banner's own arithmetic, kept in step by being the same
   * expression `drawToast` lays out with.
   */
  toastBand(): number {
    if (!this.toast) return 0;
    return this.toastH() + Math.round(6 * this.layout.uiScale());
  }

  /** The banner's own height: the line in it, or the old minimum. */
  private toastH(): number {
    const s = this.layout.uiScale();
    return Math.max(Math.round(26 * s), ensureFonts(s).stationSm.height + Math.round(8 * s));
  }

  private drawToast(g: Ctx): void {
    const toast = this.toast;
    if (!toast) return;
    const { vw } = this.layout;
    const s = this.layout.uiScale();
    const h = this.toastH();
    // Under the header, not over it: the header says where you are, and a
    // banner that covers it trades one piece of information for another. It
    // slides down out of the header rather than appearing, so the eye is
    // brought to it instead of having to notice it.
    const top = Math.round(38 * s) - Math.round((1 - toast.tween.out) * h);
    g.fillStyle = "rgba(216,40,0,0.92)";
    g.fillRect(0, top, vw, h);
    g.fillStyle = "rgba(40,24,16,1)";
    g.fillRect(0, top + h - 2, vw, 2);
    const f = ensureFonts(s).stationSm;
    g.font = f.css;
    g.textBaseline = "middle";
    g.textAlign = "center";
    g.fillStyle = "rgba(252,236,200,1)";
    g.fillText(toast.text.toUpperCase(), vw / 2, top + h / 2);
    g.textBaseline = "top";
    g.textAlign = "left";
  }

  /**
   * The ground a screen draws on. With the city behind, that is *nothing* —
   * painting an opaque colour over the backdrop is how the three.js layer
   * ended up only ever being visible on the map.
   */
  clear(g: Ctx, fallback = Theme.void): void {
    if (this.backdrop) {
      g.clearRect(0, 0, this.layout.vw, this.layout.vh);
      return;
    }
    g.fillStyle = css(fallback, 1);
    g.fillRect(0, 0, this.layout.vw, this.layout.vh);
  }
}
