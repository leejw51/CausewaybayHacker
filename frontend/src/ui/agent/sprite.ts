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
 * **A journey is a flight, not a slide.** Changing state — going to peek at
 * the caret, sitting down to type, orbiting to think, drifting off again —
 * starts a flight from where it is to where it is going, on the house
 * exponential in-out curve: slow away, fast through the middle, slow to
 * arrive. The destination is re-read every frame, so a caret that moves
 * mid-flight is still where it lands. Once there, small movements are the
 * exponential follow, which is what tracking a caret wants. The barrel roll
 * turns on the same curve.
 *
 * `reducedMotion` pins it in the top-right corner and only the bubble moves.
 */
import { expInOut } from "../../engine/ease";

export type Rect = readonly [number, number, number, number];
export type Pt = readonly [number, number];

export type State = "wander" | "peek" | "typing" | "thinking" | "hold";

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
/**
 * The hold: pressed, the sprite stops so its bubble can be read. It does not
 * stop dead — it coasts this many seconds' worth of its speed further and
 * settles there on the exponential follow, an ease-out from wherever it
 * was — and it lets itself go after this long, in case nobody presses again.
 */
const HOLD_COAST = 0.22;
const HOLD_SECS = 20;
/** The zoom while held: a touch closer, attentive. */
const HOLD_ZOOM = 1.06;
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
/** A barrel roll: one full turn, eased in and out, over this many seconds. */
const ROLL_SECS = 0.7;
/** A flight's length: a floor, plus this much per virtual pixel, to a ceiling. */
const FLIGHT_MIN = 0.4;
const FLIGHT_PER_PX = 1 / 520;
const FLIGHT_MAX = 1.3;
/** A destination that moved further than this mid-flight is a new flight. */
const REPLAN_PX = 120;
/** How many frames of a flight the light ribbon remembers. */
const WAKE_MAX = 16;
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
  /** Where it settles while held. */
  private holdAt: Pt = [0, 0];
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
  /** The roll's progress, 0..1, or -1 when level. */
  private rolling = -1;
  /** The flight under way, if any: where from, and how far along. */
  private flight: { from: Pt; to: Pt; t: number; secs: number } | null = null;

  /** The tilt in radians: bank, rock and roll together. 0 at rest. */
  get angle(): number {
    return this.bank + this.rock + this.spin;
  }
  /** Where it has just been, newest last, for the afterimages. */
  trail: Pt[] = [];
  /** Every frame of a flight, newest last, for the light ribbon behind it. */
  wake: Pt[] = [];
  /** Set for one frame when a flight begins, and when one ends. */
  tookOff = false;
  landed = false;
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
    this.go("peek");
    this.held = 0;
    return true;
  }

  typing(on: boolean): void {
    if (on) this.go("typing");
    else if (this.state === "typing") this.go("wander");
  }

  /**
   * Pressed: stop, so the bubble can be read. Only an idle sprite holds —
   * one at work keeps working — and the stop is a braking curve, not a
   * freeze: the target is a little ahead along its motion and the follow
   * eases it there. Released, it flies off again. Returns whether it held.
   */
  hold(on: boolean, box?: Rect): boolean {
    if (on) {
      if (this.state === "typing" || this.state === "thinking") return false;
      const m = this.size * MARGIN;
      let hx = this.x + this.vx * HOLD_COAST;
      let hy = this.y + this.vy * HOLD_COAST;
      if (box) {
        hx = Math.min(box[0] + box[2] - m, Math.max(box[0] + m, hx));
        hy = Math.min(box[1] + box[3] - m, Math.max(box[1] + m, hy));
      }
      this.holdAt = [hx, hy];
      this.state = "hold";
      this.held = 0;
      this.flight = null;
      this.depart = false;
      return true;
    }
    if (this.state === "hold") this.go("wander");
    return false;
  }

  /** Whether it is holding still for a reader. */
  get holding(): boolean {
    return this.state === "hold";
  }

  thinking(on: boolean): void {
    if (on) this.go("thinking");
    else if (this.state === "thinking") this.go("wander");
  }

  /** Change state, and set off: every change of mind is a flight. */
  private go(state: State): void {
    if (this.state === state) return;
    this.state = state;
    this.flight = null;
    this.depart = true;
  }

  /** Set on a state change; the next update plans the flight from there. */
  private depart = false;

  private plan(to: Pt): void {
    const dist = Math.hypot(to[0] - this.x, to[1] - this.y);
    if (dist < 2) {
      this.flight = null;
      return;
    }
    const secs = Math.min(FLIGHT_MAX, FLIGHT_MIN + dist * FLIGHT_PER_PX);
    this.flight = { from: [this.x, this.y], to, t: 0, secs };
    this.tookOff = true;
  }

  /** Whether a flight is under way. */
  get flying(): boolean {
    return this.flight !== null;
  }

  /** A keystroke: the sprite squashes, stretches and zooms for a beat. */
  kick(): void {
    this.pulse = 1;
  }

  /** One full barrel roll, eased in and out, on top of whatever else the angle is doing. */
  roll(): void {
    if (this.reduced()) return;
    if (this.rolling < 0) this.rolling = 0;
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
      case "hold":
        return this.holdAt;
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
    } else if (this.state === "hold") {
      this.held += dt;
      if (this.held >= HOLD_SECS) this.go("wander");
    }
    const [tx, ty] = this.target(box, cell);
    if (!this.placed) {
      const [rx, ry] = this.restPoint(box);
      this.x = rx;
      this.y = ry;
      this.placed = true;
    }
    const x0 = this.x;
    const y0 = this.y;
    this.tookOff = false;
    this.landed = false;
    if (this.depart && !this.reduced()) {
      this.depart = false;
      this.plan([tx, ty]);
    }
    const dx = tx - this.x;
    if (this.flight) {
      // A flight: the in-out curve from where it set off to where it is
      // going, the destination re-read every frame. A destination that
      // jumped is a new flight from here.
      const f = this.flight;
      if (Math.hypot(tx - f.to[0], ty - f.to[1]) > REPLAN_PX) {
        this.plan([tx, ty]);
      } else {
        f.to = [tx, ty];
        f.t = Math.min(1, f.t + dt / f.secs);
        const k = expInOut(f.t);
        this.x = f.from[0] + (f.to[0] - f.from[0]) * k;
        this.y = f.from[1] + (f.to[1] - f.from[1]) * k;
        if (f.t >= 1) {
          this.flight = null;
          this.landed = true;
        }
      }
    } else {
      // At rest, or tracking: the exponential follow.
      const k = 1 - Math.exp(-FOLLOW * dt);
      this.x += dx * k;
      this.y += (ty - this.y) * k;
    }
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
      this.rolling = -1;
      this.flight = null;
      this.trail.length = 0;
      this.wake.length = 0;
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
          : this.state === "hold"
            ? HOLD_ZOOM
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
    if (this.rolling >= 0) {
      this.rolling = Math.min(1, this.rolling + dt / ROLL_SECS);
      this.spin = Math.PI * 2 * expInOut(this.rolling) * this.facing;
      if (this.rolling >= 1) {
        this.rolling = -1;
        this.spin = 0;
      }
    }
    // The afterimages: only while it is really moving.
    if (this.speed() > TRAIL_SPEED) {
      this.trail.push([this.x, this.y]);
      if (this.trail.length > TRAIL_MAX) this.trail.shift();
    } else if (this.trail.length) this.trail.shift();
    // The wake: the whole flight, fading once it has landed.
    if (this.flight) {
      this.wake.push([this.x, this.y]);
      if (this.wake.length > WAKE_MAX) this.wake.shift();
    } else if (this.wake.length) this.wake.shift();
  }

  /** The squash and stretch of the moment: [x, y] factors on top of `scale`. */
  squash(): Pt {
    if (this.reduced()) return [1, 1];
    return [1 + SQUASH * this.pulse, 1 - SQUASH * this.pulse];
  }

  /** Whether a roll is still turning. */
  get rollingNow(): boolean {
    return this.rolling >= 0;
  }

  /** The hover bob, in virtual pixels, at this moment. */
  bob(): number {
    if (this.reduced()) return 0;
    const amp = this.state === "typing" || this.state === "hold" ? 1.5 : 3.5;
    return Math.sin(this.t * BOB_HZ * Math.PI * 2) * amp;
  }

  /** How hard the engine burns: 0..1, for the flame's length. */
  thrust(): number {
    if (this.reduced()) return 0.3;
    return this.state === "thinking"
      ? 1
      : this.state === "typing" || this.state === "hold"
        ? 0.35
        : 0.6;
  }
}
