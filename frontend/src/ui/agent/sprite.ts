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
 * On top of where it is, how it *carries itself*: `scale` zooms in while it
 * types and breathes while it waits, `angle` rocks with the typing, banks
 * into a turn and barrel-rolls when it starts writing or lands a program,
 * and each keystroke is a `pulse` that squashes and stretches it. Every one
 * of those chases its target exponentially (`1 - e^(-k·dt)`), so a change
 * starts fast and settles soft, and none of them read the wall clock. A
 * short `trail` of where it has just been is kept for the afterimages.
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
/** How fast scale and angle chase their targets, per second. */
const EASE = 9;
/** How fast a keystroke's pulse dies away, per second. */
const PULSE_DECAY = 7;
/** The zoom while typing, and the extra a keystroke adds on top. */
const TYPING_ZOOM = 1.18;
const PULSE_ZOOM = 0.22;
/** Squash and stretch: how far a pulse pulls the sprite wide and flat. */
const SQUASH = 0.16;
/** The rock while typing: amplitude in radians and rate in Hz. */
const ROCK = 0.13;
const ROCK_HZ = 4.5;
/** How far it banks into a turn, per virtual pixel per second of travel. */
const BANK = 0.0022;
const BANK_MAX = 0.35;
/** A barrel roll: one full turn at this rate, radians per second. */
const ROLL_RATE = 11;
/** The afterimages: how many, and how fast the sprite must move to leave one. */
const TRAIL_MAX = 7;
const TRAIL_SPEED = 180;

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
  /** The zoom, chasing a target by state; 1 at rest. */
  scale = 1;
  /** The eased part of the tilt: the bank into a turn. */
  private bank = 0;
  /** The rock while typing, applied straight: it is already a smooth wave. */
  private rock = 0;
  /** How far round a barrel roll has turned; 0 when level. */
  private spin = 0;
  /** A keystroke's kick, 1 on the key and dying away. */
  pulse = 0;
  /** Radians of barrel roll still to turn. */
  private rolling = 0;

  /** The tilt in radians: bank, rock and roll together. 0 at rest. */
  get angle(): number {
    return this.bank + this.rock + this.spin;
  }
  /** Where it has just been, newest last, for the afterimages. */
  trail: Pt[] = [];
  private vx = 0;
  private vy = 0;

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

  /** A keystroke: the sprite squashes, stretches and zooms for a beat. */
  kick(): void {
    this.pulse = 1;
  }

  /** One full barrel roll, on top of whatever else the angle is doing. */
  roll(): void {
    if (this.reduced()) return;
    this.rolling += Math.PI * 2;
  }

  /** How fast it is going, in virtual pixels per second. */
  speed(): number {
    return Math.hypot(this.vx, this.vy);
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
    const x0 = this.x;
    const y0 = this.y;
    this.x += dx * k;
    this.y += (ty - this.y) * k;
    if (Math.abs(dx) > 0.6 && !this.reduced()) this.facing = dx < 0 ? -1 : 1;
    // Clamp to the box, whatever the target asked for.
    const m = this.size * MARGIN;
    this.x = Math.min(box[0] + box[2] - m, Math.max(box[0] + m, this.x));
    this.y = Math.min(box[1] + box[3] - m, Math.max(box[1] + m, this.y));
    if (dt > 0) {
      this.vx = (this.x - x0) / dt;
      this.vy = (this.y - y0) / dt;
    }
    this.carry(dt);
  }

  /**
   * How it carries itself this frame: the zoom, the tilt, the pulse and the
   * afterimages. Everything chases a target exponentially, so a state change
   * starts fast and settles soft.
   */
  private carry(dt: number): void {
    if (this.reduced()) {
      this.scale = 1;
      this.bank = 0;
      this.rock = 0;
      this.spin = 0;
      this.pulse = 0;
      this.rolling = 0;
      this.trail.length = 0;
      return;
    }
    this.pulse *= Math.exp(-PULSE_DECAY * dt);
    if (this.pulse < 0.005) this.pulse = 0;
    const ease = 1 - Math.exp(-EASE * dt);
    // The zoom: in while typing, a touch out while thinking, breathing at rest.
    const targetScale =
      this.state === "typing"
        ? TYPING_ZOOM + PULSE_ZOOM * this.pulse
        : this.state === "thinking"
          ? 0.92
          : 1 + 0.035 * Math.sin(this.t * 1.1);
    this.scale += (targetScale - this.scale) * ease;
    // The tilt, in three parts. The bank into a turn is eased. The rock
    // while typing is a wave already and is applied straight, fading in
    // and out with the state. The roll is spent at a fixed rate until it
    // has gone all the way round, and a full turn is level again.
    const bankTarget =
      this.state === "typing"
        ? 0
        : Math.max(-BANK_MAX, Math.min(BANK_MAX, -this.vx * BANK * this.facing));
    this.bank += (bankTarget - this.bank) * ease;
    const rockTarget =
      this.state === "typing"
        ? Math.sin(this.t * ROCK_HZ * Math.PI * 2) * ROCK * (0.6 + 0.4 * this.pulse)
        : 0;
    this.rock = this.state === "typing" ? rockTarget : this.rock * (1 - ease);
    if (this.rolling > 0) {
      const step = Math.min(this.rolling, ROLL_RATE * dt);
      this.spin += step * this.facing;
      this.rolling -= step;
      if (this.rolling <= 0) {
        this.rolling = 0;
        this.spin = 0;
      }
    }
    // The afterimages: only while it is really moving.
    if (this.speed() > TRAIL_SPEED) {
      this.trail.push([this.x, this.y]);
      if (this.trail.length > TRAIL_MAX) this.trail.shift();
    } else if (this.trail.length) this.trail.shift();
  }

  /** The squash and stretch of the moment: [x, y] factors on top of `scale`. */
  squash(): Pt {
    if (this.reduced()) return [1, 1];
    return [1 + SQUASH * this.pulse, 1 - SQUASH * this.pulse];
  }

  /** Whether a roll is still turning. */
  get rollingNow(): boolean {
    return this.rolling > 0;
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
