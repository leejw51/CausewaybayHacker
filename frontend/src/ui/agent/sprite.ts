/**
 * Where the coder is, and where it is going.
 *
 * A state machine in virtual pixels with no canvas in it, so
 * `tests/agent-sprite.test.ts` can pin it: **wander** drifts on a slow
 * Lissajous inside the editor's rectangle; **peek** flies to the caret and
 * hovers a beat; **typing** sits a cell to the right of the caret while the
 * typist runs; **thinking** circles while a request is out. The numbers are
 * CausewaybayRaiden's agent flight (orbit, spin, follow) scaled to the box.
 *
 * `reducedMotion` pins it in the top-right corner and only the bubble moves.
 */
export type Rect = readonly [number, number, number, number];
export type Pt = readonly [number, number];

export type State = "wander" | "peek" | "typing" | "thinking";

/** How fast the sprite eases towards its target, per second (Raiden's `follow`). */
const FOLLOW = 5.5;
/** The wander's period in seconds along each axis; unequal so it never repeats. */
const WANDER_X = 11.0;
const WANDER_Y = 7.3;
/** The bob under everything: a hover, not a stand. */
const BOB_HZ = 1.6;
/** How far the sprite keeps from the box's edge, as a share of its size. */
const MARGIN = 0.55;
/** The peek: how long it hovers at the caret. */
const PEEK_HOLD = 1.6;
/** The orbit while thinking. */
const THINK_R = 18;
const THINK_HZ = 0.9;

export class Sprite {
  x = 0;
  y = 0;
  /** −1 faces left, +1 right. Flips with the direction of travel. */
  facing = 1;
  state: State = "wander";
  /** The wander's own clock; advanced only while wandering so it resumes where it left off. */
  private phase = 0;
  private t = 0;
  private held = 0;
  /** Where the caret was last seen, for peek and typing. */
  caret: Pt | null = null;
  private placed = false;

  constructor(
    /** The sprite's drawn size in virtual pixels, for the margin. */
    public size: number,
    private readonly reduced: () => boolean,
  ) {}

  /** The point the wander wants at its clock. */
  wanderPoint(box: Rect): Pt {
    const m = this.size * MARGIN;
    const [x, y, w, h] = box;
    const cx = x + w / 2;
    const cy = y + h / 2;
    const rx = Math.max(0, w / 2 - m);
    const ry = Math.max(0, h / 2 - m);
    const p = this.phase;
    return [
      cx + rx * Math.sin((p / WANDER_X) * Math.PI * 2),
      cy + ry * Math.sin((p / WANDER_Y) * Math.PI * 2 + 1.1),
    ];
  }

  /** The corner it sits in under reduced motion, and where it starts. */
  restPoint(box: Rect): Pt {
    const m = this.size * MARGIN;
    return [box[0] + box[2] - m, box[1] + m];
  }

  /** The seat beside the caret: a cell to the right and a little up. */
  seat(box: Rect, cell: number): Pt {
    const c = this.caret ?? this.restPoint(box);
    const m = this.size * MARGIN;
    return [
      Math.min(box[0] + box[2] - m, Math.max(box[0] + m, c[0] + cell * 2.5 + this.size * 0.4)),
      Math.min(box[1] + box[3] - m, Math.max(box[1] + m, c[1] - this.size * 0.15)),
    ];
  }

  /** Go and look at the caret; nothing happens if there is none. */
  peek(): boolean {
    if (!this.caret || this.state !== "wander") return false;
    this.state = "peek";
    this.held = 0;
    return true;
  }

  typing(on: boolean): void {
    if (on) this.state = "typing";
    else if (this.state === "typing") this.state = "wander";
  }

  thinking(on: boolean): void {
    if (on) this.state = "thinking";
    else if (this.state === "thinking") this.state = "wander";
  }

  /** The target for this frame, by state. */
  target(box: Rect, cell: number): Pt {
    if (this.reduced()) return this.restPoint(box);
    switch (this.state) {
      case "wander":
        return this.wanderPoint(box);
      case "peek":
      case "typing":
        return this.seat(box, cell);
      case "thinking": {
        const [sx, sy] = this.seat(box, cell);
        const a = this.t * THINK_HZ * Math.PI * 2;
        return [sx + Math.cos(a) * THINK_R, sy + Math.sin(a) * THINK_R * 0.5];
      }
    }
  }

  update(dt: number, box: Rect, cell: number): void {
    this.t += dt;
    if (this.state === "wander") this.phase += dt;
    if (this.state === "peek") {
      this.held += dt;
      if (this.held >= PEEK_HOLD) this.state = "wander";
    }
    const [tx, ty] = this.target(box, cell);
    if (!this.placed) {
      const [rx, ry] = this.restPoint(box);
      this.x = rx;
      this.y = ry;
      this.placed = true;
    }
    const k = 1 - Math.exp(-FOLLOW * dt);
    const dx = tx - this.x;
    this.x += dx * k;
    this.y += (ty - this.y) * k;
    if (Math.abs(dx) > 0.6 && !this.reduced()) this.facing = dx < 0 ? -1 : 1;
    // Clamp to the box, whatever the target asked for.
    const m = this.size * MARGIN;
    this.x = Math.min(box[0] + box[2] - m, Math.max(box[0] + m, this.x));
    this.y = Math.min(box[1] + box[3] - m, Math.max(box[1] + m, this.y));
  }

  /** The hover bob, in virtual pixels, at this moment. */
  bob(): number {
    if (this.reduced()) return 0;
    const amp = this.state === "typing" ? 1.5 : 3.5;
    return Math.sin(this.t * BOB_HZ * Math.PI * 2) * amp;
  }

  /** How hard the engine burns: 0..1, for the flame's length. */
  thrust(): number {
    if (this.reduced()) return 0.3;
    return this.state === "thinking" ? 1 : this.state === "typing" ? 0.35 : 0.6;
  }
}
