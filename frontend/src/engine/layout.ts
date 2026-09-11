// Ported from CausewaybayGolang/typescript/src/engine/layout.ts (which in turn
// carries it over from that project's love2d Lua). Kept close to the original
// so a fix made there can still be read across; Causewaybay Hacker changes are
// marked where they occur.
/**
 * The virtual canvas, ported from `love2d/src/layout.lua`.
 *
 * The game is authored against 1280x720, or 720x1280 turned on its side, and
 * every coordinate in the renderer is in those units. This module works out
 * how many of them fit in the window and what to multiply them by.
 *
 * The one rule worth keeping in mind: below a 2x fit the virtual canvas is
 * *grown* along the longer axis rather than letterboxed, up to half again the
 * design size. A landscape layout in a tall browser window gets a taller
 * playfield, not black bars — which is why `SCENE_H` and the panel heights in
 * the renderer are all computed from `vw`/`vh` rather than being constants.
 */
import { Theme } from "./theme";

/** How far past the design size the canvas may grow before it letterboxes. */
const MAX_STRETCH = 1.5;

/**
 * On a touch screen, how many CSS pixels a virtual pixel should be worth
 * before the type is scaled up to compensate. A phone fits the 720-wide
 * portrait design into 390 CSS pixels — every virtual pixel is half a real
 * one — and 16px Press Start 2P at that size is eight pixels tall.
 */
const TOUCH_READABLE = 0.8;
/** The most the type is boosted by; past this the panels stop fitting. */
const TOUCH_BOOST_MAX = 1.5;
/** The smallest thing a finger can be expected to hit, in CSS pixels. */
const TOUCH_TARGET = 40;

/**
 * How lopsided a window has to be before its shape is an *answer* rather than
 * a preference.
 *
 * Causewaybay Hacker change. At 1.2 a window half again as tall as it is wide
 * — a phone, or a browser window dragged into a column — is unambiguously
 * portrait, and a 16:9 desktop window is unambiguously landscape. Between the
 * two, near square, the window is not saying anything and whatever was chosen
 * stands.
 */
const DECISIVE = 1.2;

export type Orientation = "landscape" | "portrait";

export class Layout {
  mode: Orientation = "landscape";
  /** Virtual pixels across and down: what the renderer draws in. */
  vw = Theme.landW;
  vh = Theme.landH;
  /** Device pixels per virtual pixel. */
  scale = 1;
  /** CSS pixels per virtual pixel: how big things are to a finger or an eye. */
  cssScale = 1;
  /** Where the virtual canvas sits inside the window, in device pixels. */
  ox = 0;
  oy = 0;
  /** Device pixels across and down. */
  dw = Theme.landW;
  dh = Theme.landH;

  /**
   * Whether the player has chosen an orientation themselves.
   *
   * The desktop build picks one from the display at startup and then leaves it
   * alone, because a window does not spin round while you are looking at it. A
   * phone does. So until somebody presses F1 the layout follows the window,
   * and after that it is theirs.
   */
  private pinned: Orientation | null = null;

  /**
   * The window the choice was made in, in device pixels — and the Causewaybay
   * Hacker change that this file exists to carry.
   *
   * The ported version had one flag and no memory, so a pin was permanent and
   * a *restored* pin was as strong as a pressed one. That is the bug the user
   * hit: F1 pressed once in a wide window, saved to localStorage, and from
   * then on every session in every window was landscape — including a browser
   * window 1080 wide and 1730 tall, where the landscape layout is squeezed
   * into a 1075x907 band with 47% of the window left over.
   *
   * So a choice now remembers the window it was made in. It holds for as long
   * as that window holds. The moment the window is a different shape *and*
   * that shape is decisive, the choice is stale — it was an answer to a
   * question nobody is asking any more — and the layout goes back to following
   * the window. Pressing F1 again re-answers it, in the window that is
   * actually on screen.
   */
  private pinnedShape: [number, number] | null = null;

  /**
   * @param touch whether this is a screen that is tapped rather than clicked.
   * A phone is held closer and hit with a finger, so type is boosted and
   * buttons get a floor under their height; a small desktop window gets
   * neither, because it can always be made bigger.
   */
  constructor(
    private readonly canvas: HTMLCanvasElement,
    readonly touch = false,
  ) {
    if (window.innerHeight > window.innerWidth) this.mode = "portrait";
  }

  /**
   * Restore a saved orientation.
   *
   * @param shape the window it was chosen in. Omitted means *this* window,
   * which is what an in-session choice is. An explicit `null` means the window
   * is not known — a preference saved by an older build — and such a choice
   * loses to the first decisive window that disagrees with it. That is the
   * safe direction: the cost of being wrong is a layout the player fixes with
   * one key, and the cost of the other direction is the game rendering into
   * 40% of the screen with no way to find out why.
   */
  pin(mode: Orientation, shape?: [number, number] | null): void {
    this.mode = mode;
    this.pinned = mode;
    this.pinnedShape = shape === undefined ? [this.dw, this.dh] : shape;
  }

  /** The window the current choice was made in, for saving alongside it. */
  get choiceShape(): [number, number] {
    return this.pinnedShape ?? [this.dw, this.dh];
  }

  /** The orientation the player chose, whether or not it applies right now. */
  get choice(): Orientation | null {
    return this.pinned;
  }

  /**
   * What the window itself says, when it says anything. Null when it is close
   * enough to square that its shape is not an argument.
   */
  private decisive(ww: number, wh: number): Orientation | null {
    if (wh >= ww * DECISIVE) return "portrait";
    if (ww >= wh * DECISIVE) return "landscape";
    return null;
  }

  private base(): [number, number] {
    return this.mode === "portrait"
      ? [Theme.portW, Theme.portH]
      : [Theme.landW, Theme.landH];
  }

  isPortrait(): boolean {
    return this.mode === "portrait";
  }

  toggleOrientation(): void {
    this.mode = this.mode === "landscape" ? "portrait" : "landscape";
    this.pinned = this.mode;
    // The choice is about *this* window. Recorded before `measure`, because
    // `dw`/`dh` still hold the window the key was pressed in.
    this.pinnedShape = [this.dw, this.dh];
    this.measure();
  }

  /**
   * Fonts are authored for the design size. When the virtual canvas grows,
   * type grows with it, so a 1600-wide window is not a 1280 layout with a lot
   * of empty space in the panels.
   */
  uiScale(): number {
    const [bw, bh] = this.base();
    return Math.max(1, Math.min(this.vw / bw, this.vh / bh)) * this.touchBoost();
  }

  /**
   * How much bigger than designed the type is on a touch screen, so that it
   * stays readable when the canvas is squeezed into a phone. 1 on anything
   * that is not touched, and on a tablet, where the fit is already close.
   */
  touchBoost(): number {
    if (!this.touch) return 1;
    return Math.min(TOUCH_BOOST_MAX, Math.max(1, TOUCH_READABLE / this.cssScale));
  }

  /**
   * The least tall a button may be, in virtual pixels, so a finger can land
   * on it. Zero where there are no fingers.
   */
  minTouchH(): number {
    return this.touch ? Math.ceil(TOUCH_TARGET / this.cssScale) : 0;
  }

  /**
   * Re-read the window and resize the backing store. Returns true when
   * anything moved, which is the renderer's cue to rebuild its fonts.
   */
  measure(): boolean {
    // Capped at 2: a phone at devicePixelRatio 3 would otherwise render nine
    // times the pixels for a difference nobody can see on pixel art.
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const cw = Math.max(1, this.canvas.clientWidth);
    const ch = Math.max(1, this.canvas.clientHeight);
    const ww = Math.max(1, Math.round(cw * dpr));
    const wh = Math.max(1, Math.round(ch * dpr));
    // A phone that was turned on its side, or a window dragged into a new
    // shape: follow it, unless the player has said which way they want it —
    // in this window. A choice made in a different window that this one
    // decisively contradicts is not a preference any more, it is a stale
    // answer, and honouring it is how the game ends up in a band across the
    // top of a column-shaped browser with the rest of it empty.
    // A choice is *suspended*, not forgotten, while the window decisively
    // disagrees with it in a shape it was not made in. Drag the window back to
    // the shape the key was pressed in and the choice comes back — which is
    // what a preference should do, and is the difference between this and
    // simply throwing it away on the first resize.
    const says = this.decisive(ww, wh);
    const sameWindow =
      this.pinnedShape !== null && this.pinnedShape[0] === ww && this.pinnedShape[1] === wh;
    if (this.pinned !== null && (sameWindow || !says || says === this.pinned)) {
      this.mode = this.pinned;
    } else {
      this.mode = says ?? (wh > ww ? "portrait" : "landscape");
    }
    const [bw, bh] = this.base();

    // The fit is worked out in CSS pixels, not device pixels: a Retina
    // display has twice the pixels but is not twice as big, and a layout that
    // counted them would draw everything at half size and then letterbox it.
    // The device scale is that fit with the pixel ratio put back.
    const fit = Math.min(cw / bw, ch / bh);
    const cssScale = fit >= 2 ? Math.floor(fit) : fit >= 1 ? 1 : Math.max(0.35, fit);
    const scale = cssScale * dpr;
    const vw = Math.min(Math.floor(ww / scale), Math.floor(bw * MAX_STRETCH));
    const vh = Math.min(Math.floor(wh / scale), Math.floor(bh * MAX_STRETCH));

    // The backing store is compared too, not just the last measurement: a
    // window that happens to be exactly the design size matches the defaults
    // on the first frame, and the canvas would stay at its own 300x150.
    const changed =
      scale !== this.scale ||
      vw !== this.vw ||
      vh !== this.vh ||
      ww !== this.dw ||
      wh !== this.dh ||
      this.canvas.width !== ww ||
      this.canvas.height !== wh;
    this.scale = scale;
    this.cssScale = cssScale;
    this.vw = vw;
    this.vh = vh;
    this.dw = ww;
    this.dh = wh;
    this.ox = Math.floor((ww - vw * scale) / 2);
    this.oy = Math.floor((wh - vh * scale) / 2);

    if (changed) {
      this.canvas.width = ww;
      this.canvas.height = wh;
    }
    return changed;
  }

  /** Put the context into virtual coordinates for a frame. */
  begin(g: CanvasRenderingContext2D): void {
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, this.dw, this.dh);
    g.setTransform(this.scale, 0, 0, this.scale, this.ox, this.oy);
  }

  /** A pointer position in window coordinates, in virtual ones, or null when
   *  it landed on the letterbox rather than on the game. */
  /** The inverse: a virtual point, in window coordinates. */
  toClient(vx: number, vy: number): [number, number] {
    const rect = this.canvas.getBoundingClientRect();
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    return [(vx * this.scale + this.ox) / dpr + rect.left, (vy * this.scale + this.oy) / dpr + rect.top];
  }

  toVirtual(clientX: number, clientY: number): [number, number] | null {
    const rect = this.canvas.getBoundingClientRect();
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const px = (clientX - rect.left) * dpr;
    const py = (clientY - rect.top) * dpr;
    const vx = (px - this.ox) / this.scale;
    const vy = (py - this.oy) / this.scale;
    if (vx < 0 || vy < 0 || vx >= this.vw || vy >= this.vh) return null;
    return [vx, vy];
  }
}
