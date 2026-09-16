/**
 * The code screens' effects layer: typing, as a game.
 *
 * The editor is a DOM element on top of both canvases, and its face is all
 * but opaque, so anything thrown at the caret has to be painted on a layer
 * *above* it. This is that layer: one transparent WebGL canvas, added to the
 * overlay after the editor so it is composited over it, driven by the same
 * `Layout` as the game so a point in the scene is the same point here. It
 * never takes a pointer event — it is decoration over something a person is
 * typing into.
 *
 * The particles are `engine/particles.ts`, the three.js pool the rest of the
 * game had ready and nothing was using: a few thousand additive, trailing
 * points moved entirely in the vertex shader, plus two Grok-drawn pixel-art
 * strips (rubble and dust) for the shapes that want to look like things. The
 * *plans* — how many, which way, what colour — are `engine/burst.ts`, pure
 * and tested. This file is the glue: it listens to the editor, converts client
 * pixels to virtual ones, and picks a plan.
 *
 * What happens when:
 *
 *   * the pointer moves — a thin thread of light behind it, the caret's
 *     colour, whiter the faster it goes;
 *   * the caret moves — its rectangle smears from where it was to where it
 *     is and shrinks back, a white thread down its middle, an L across
 *     lines; and a *jump* (PageDown, a far click) drops grains on the way;
 *   * a character is typed — a pop of sparks in the token's syntax colour;
 *   * ENTER — a puff of dust along the new line;
 *   * a character is erased — it breaks into brick and falls;
 *   * the caret rests by a bracket — a runner along the line to its match;
 *   * a loop is closed — gold stars run a loop of their own round the block,
 *     the editor gives a kick, and the coin sound plays.
 *
 * Without WebGL the 2D `Sparks` canvas takes the same plans, in squares.
 * Under `prefers-reduced-motion` the smear is off and everything else is a
 * quarter of itself: feedback, not a performance.
 */
import type { Assets } from "../engine/assets";
import {
  RUBBLE_MAX,
  cornerPlan,
  dustPlan,
  isJump,
  jumpPlan,
  keyPlan,
  linkPlan,
  loopPlan,
  pointerPlan,
  rubblePlan,
  smearFor,
  type Cell,
  type Plan,
  type Rubble,
} from "../engine/burst";
import type { Layout } from "../engine/layout";
import { reducedMotion } from "../engine/motion";
import { Particles } from "../engine/particles";
import { Theme, type RGBA } from "../engine/theme";
import type { Chip } from "../audio/sfx";
import type { EditEvent, Editor, Pt, Tone } from "./editor";
import { Sparks } from "./sparks";

/** The syntax palette (`editor.ts`'s `retro`), as the spark each family throws. */
const TONE_COLOUR: Record<Tone, RGBA> = {
  keyword: Theme.pink,
  name: Theme.cream,
  call: Theme.cyan,
  type: Theme.coin,
  string: Theme.grass,
  number: Theme.coin,
  comment: Theme.dim,
  operator: Theme.panel,
  bracket: Theme.cyan,
  plain: Theme.cream,
};

/**
 * The longest gap that still counts towards the caret's speed. A click after
 * a minute's thought is a fast move to where it clicked, not a slow one.
 */
const MOVE_GAP = 0.25;
/** Virtual pixels of pointer travel between one ember and the next. */
const TRAIL_STEP = 5;
/** The most embers one pointer event may leave: a flick is a flick, not a wall. */
const TRAIL_MAX = 10;
/** Seconds the editor holds its kick class: matches the CSS animation. */
const KICK_SECS = 0.6;

export class CodeFx {
  private readonly canvas = document.createElement("canvas");
  private gl: Particles | null = null;
  private flat: Sparks | null = null;
  /** The scene clock, for the 2D fallback and the caret's speed. */
  private now = 0;
  private fitted = "";
  private editor: Editor | null = null;
  /** When the caret last moved, for how fast it moved this time. */
  private movedAt = -1;
  /** The pointer's last virtual position and when it was there. */
  private last: Pt | null = null;
  private lastAt = 0;
  private carry = 0;
  private kick: ReturnType<typeof setTimeout> | null = null;
  private readonly onPointer = (ev: PointerEvent): void => this.pointed(ev);

  constructor(
    host: HTMLElement,
    private readonly layout: Layout,
    assets: Assets | null,
    private readonly chip: Chip | null,
  ) {
    this.canvas.className = "cwb-sparks cwb-codefx";
    host.appendChild(this.canvas);
    const gl = new Particles(this.canvas);
    if (gl.ok) {
      this.gl = gl;
      // The strips, if the art has arrived. A PNG is loaded up front by
      // `Assets.load`, so on any screen after boot this is a map lookup; a
      // build served without them draws the procedural shapes and says
      // nothing, which is the same bargain every sprite in the game makes.
      for (const [name, which] of [
        ["fx_bricks", "brick"],
        ["fx_dust", "dust"],
      ] as const) {
        const img = assets?.picture(name);
        const strip = assets?.strip(name);
        if (img && strip) gl.sheet(which, img, strip.frames);
      }
    } else {
      this.canvas.remove();
      this.flat = new Sparks(host, layout);
    }
    // Faded in by the stylesheet once the class lands, a frame after it is
    // in the document, so the first paint is a fade and not a pop.
    requestAnimationFrame(() => this.canvas.classList.add("cwb-on"));
    addEventListener("pointermove", this.onPointer, { passive: true });
  }

  /** Listen to this editor. One at a time; the screen has one. */
  attach(editor: Editor): void {
    if (this.editor) this.editor.events = null;
    this.editor = editor;
    editor.events = (e) => this.on(e);
  }

  /** Throw a plan of your own — the quest screen's ANSWER-mode sparks. */
  play(plan: Plan): void {
    const p = reducedMotion() ? trim(plan, 0.25) : plan;
    if (this.gl) this.gl.play(p);
    else this.flat?.add(p, this.now);
  }

  /** Once a frame, from the scene's `update`. */
  frame(dt: number): void {
    this.now += dt;
    if (this.gl) {
      this.fit();
      this.gl.frame(dt);
    } else {
      this.flat?.draw(this.now);
    }
  }

  destroy(): void {
    removeEventListener("pointermove", this.onPointer);
    if (this.editor) {
      this.editor.events = null;
      this.editor.dom.classList.remove("cwb-kick");
    }
    if (this.kick !== null) clearTimeout(this.kick);
    this.editor = null;
    this.flat?.destroy();
    this.canvas.remove();
  }

  // -- the events ----------------------------------------------------------

  private on(e: EditEvent): void {
    const cell = this.cell(e.cell);
    switch (e.kind) {
      case "type": {
        const at = this.virtual(e.at);
        if (!at) return;
        this.play(keyPlan(at[0], at[1] + cell[1] / 2, cell, TONE_COLOUR[e.tone], e.text.length));
        return;
      }
      case "erase": {
        const at = this.virtual(e.at);
        if (!at) return;
        // One cell per character of what went, laid out the way the text
        // was: along the line from `at`, and each further line starting
        // `column` cells to the left of it, one line down.
        const cells: Rubble[] = [];
        let col = 0;
        let row = 0;
        const x0 = at[0] - e.column * cell[0];
        for (let i = 0; i < e.text.length && cells.length < RUBBLE_MAX; i++) {
          const ch = e.text[i];
          if (ch === "\n") {
            row++;
            col = 0;
            continue;
          }
          const x = row === 0 ? at[0] + col * cell[0] : x0 + col * cell[0];
          col++;
          if (ch.trim() === "") continue;
          cells.push({ x, y: at[1] + row * cell[1], color: TONE_COLOUR[e.tones[i] ?? "plain"] });
        }
        if (cells.length === 0) return;
        this.play(rubblePlan(cells, cell));
        return;
      }
      case "enter": {
        const at = this.virtual(e.at);
        if (!at) return;
        this.play(dustPlan(at[0], at[1], cell));
        return;
      }
      case "bracket": {
        const a = this.virtual(e.a);
        const b = this.virtual(e.b);
        if (!a || !b) return;
        this.play(linkPlan(a, b, cell));
        return;
      }
      case "loop": {
        const open = this.virtual(e.open);
        const close = this.virtual(e.close);
        if (!open || !close) return;
        this.play(loopPlan(open, close, cell));
        this.kickEditor();
        this.chip?.coin();
        return;
      }
      case "move": {
        const from = this.virtual(e.from);
        const to = this.virtual(e.to);
        if (!from || !to) return;
        this.moved(from, to, cell);
        return;
      }
    }
  }

  // -- the caret -----------------------------------------------------------

  /**
   * The smear from where the caret was to where it is, hotter the faster it
   * went; the corner's wink if it bent; and, only on a jump, the grains.
   * All of it is motion for its own sake, so none of it under
   * `prefers-reduced-motion`.
   */
  private moved(from: Pt, to: Pt, cell: Cell): void {
    const t = this.now;
    const gap = this.movedAt < 0 ? MOVE_GAP : Math.min(MOVE_GAP, Math.max(0.04, t - this.movedAt));
    this.movedAt = t;
    if (reducedMotion()) return;
    const dist = Math.hypot(to[0] - from[0], to[1] - from[1]);
    const smear = smearFor(from, to, cell, dist / gap);
    if (this.gl) this.gl.smear(smear);
    else this.flat?.smear(smear, t);
    this.play(cornerPlan(smear));
    if (isJump(from, to, cell)) this.play(jumpPlan(smear));
  }

  /**
   * The editor jumps, once, in its frame. A class, so the motion is the
   * stylesheet's — the same ease-in-out curve as everything else that moves
   * — and removed again so the next loop can do it again.
   */
  private kickEditor(): void {
    const dom = this.editor?.dom;
    if (!dom) return;
    dom.classList.remove("cwb-kick");
    // Off and on in one frame does not restart a CSS animation; the reflow
    // between does.
    void dom.offsetWidth;
    dom.classList.add("cwb-kick");
    if (this.kick !== null) clearTimeout(this.kick);
    this.kick = setTimeout(() => {
      dom.classList.remove("cwb-kick");
      this.kick = null;
    }, KICK_SECS * 1000);
  }

  // -- the pointer ---------------------------------------------------------

  /**
   * Embers along the pointer's path.
   *
   * Distance-paced rather than event-paced: a pointer moving slowly across a
   * 240 Hz screen fires far more events per pixel than a flick does, and a
   * trail that was one ember per event would be dense when still and thin
   * when moving — the opposite of a tail. So travel is banked and an ember is
   * spent every `TRAIL_STEP` virtual pixels, placed along the segment.
   */
  private pointed(ev: PointerEvent): void {
    if (reducedMotion()) return;
    const v = this.layout.toVirtual(ev.clientX, ev.clientY);
    if (!v) return;
    const t = this.now;
    const last = this.last;
    this.last = v;
    // A pointer that has been still for a while has no path to trail: this
    // is its first point again, not a jump from where it was.
    if (!last || t - this.lastAt > 0.25) {
      this.lastAt = t;
      this.carry = 0;
      return;
    }
    const dt = Math.max(1 / 240, t - this.lastAt);
    this.lastAt = t;
    const dx = v[0] - last[0];
    const dy = v[1] - last[1];
    const dist = Math.hypot(dx, dy);
    if (dist < 0.5) return;
    this.carry += dist;
    const n = Math.min(TRAIL_MAX, Math.floor(this.carry / TRAIL_STEP));
    if (n === 0) return;
    this.carry -= n * TRAIL_STEP;
    const vx = dx / dt;
    const vy = dy / dt;
    for (let i = 1; i <= n; i++) {
      const u = i / n;
      this.play(pointerPlan(last[0] + dx * u, last[1] + dy * u, vx, vy));
    }
  }

  // -- coordinates ---------------------------------------------------------

  private virtual(p: Pt): Pt | null {
    return this.layout.toVirtual(p[0], p[1]);
  }

  /** A client-pixel cell as virtual pixels. */
  private cell(c: Pt): Cell {
    const k = 1 / (this.layout.cssScale || 1);
    return [Math.max(4, c[0] * k), Math.max(6, c[1] * k)];
  }

  /** Match the game canvas whenever the layout has changed under us. */
  private fit(): void {
    const { dw, dh, scale, ox, oy } = this.layout;
    const key = `${dw}x${dh}@${scale}/${ox},${oy}`;
    if (key === this.fitted) return;
    this.fitted = key;
    this.gl?.resize(this.layout);
  }
}

/**
 * A plan with a fraction of its particles: the first `k` of each shape, so
 * the shape of the effect survives and only its density goes. Rings stay —
 * they are one draw each and are the part that says *where*.
 */
export function trim(plan: Plan, k: number): Plan {
  const keep = Math.max(1, Math.ceil(plan.particles.length * k));
  return { particles: plan.particles.slice(0, keep), rings: plan.rings };
}
