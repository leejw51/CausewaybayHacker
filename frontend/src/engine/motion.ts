/**
 * Timings, and the small state machine every animated thing in the game uses.
 *
 * One curve family — exponential, from `ease.ts` — and one place that decides
 * how long things take. A screen that wants a panel to arrive asks for a
 * `Tween`; it does not get to pick a duration out of the air, because six
 * screens each picking their own is how a game ends up feeling assembled
 * rather than designed.
 *
 * Exponential easing is almost still, then very fast, then almost still. That
 * shape needs *longer* than a cubic to read as deliberate — the numbers below
 * are tuned by eye against the real screens, not derived.
 */
import { expInOut, expOut } from "./ease";

/**
 * Someone who has asked their system not to animate things still needs to see
 * *what changed* — a state that appears with no transition at all is harder to
 * follow, not easier. So the durations are cut to a quarter rather than to
 * zero: the motion becomes a flicker of feedback instead of a performance.
 */
function reduced(): boolean {
  try {
    return matchMedia("(prefers-reduced-motion: reduce)").matches;
  } catch {
    return false;
  }
}

let scale = reduced() ? 0.25 : 1;
try {
  matchMedia("(prefers-reduced-motion: reduce)").addEventListener("change", (e) => {
    scale = e.matches ? 0.25 : 1;
  });
} catch {
  /* an old browser keeps whatever it started with */
}

/** The house durations, in seconds, before the reduced-motion scale. */
const BASE = {
  /** A whole screen changing. The longest thing in the game. */
  scene: 0.62,
  /** A panel arriving inside a screen that is already there. */
  panel: 0.52,
  /** The gap between one panel arriving and the next. */
  stagger: 0.07,
  /** A map node popping in, and the gap between them. */
  node: 0.44,
  nodeStagger: 0.05,
  /** The map camera easing to a new node. */
  camera: 0.58,
  /** The stamp coming down. Short, because a stamp is an impact. */
  stamp: 0.46,
  /** The verdict word. */
  verdict: 0.7,
  /** A star appearing, and the gap between them. */
  star: 0.38,
  starStagger: 0.13,
  /** The clock arriving when a timed quest opens. */
  clock: 0.66,
  /** One beat of the clock reacting: a threshold crossed, or time running out. */
  clockBeat: 0.9,
} as const;

export type Beat = keyof typeof BASE;

export function seconds(beat: Beat): number {
  return BASE[beat] * scale;
}

export function motionScale(): number {
  return scale;
}

/**
 * Whether the player asked for less motion.
 *
 * `seconds()` scales *durations*, which covers everything that arrives and
 * settles. It does not cover an amplitude or a rate — how far the screen
 * shakes, how fast a tram crosses, how long a line of story dwells before the
 * next one — and those are exactly the things this round added. Without a
 * public accessor the only way to honour the preference for them would be for
 * six modules to each call `matchMedia` themselves, which is how a setting
 * ends up half-respected.
 */
export function reducedMotion(): boolean {
  return scale < 1;
}

/**
 * A one-shot animation: starts at 0, walks to 1 over `duration`, and stays
 * there. `at` applies the curve; `raw` is the linear progress for anything
 * that needs its own shape.
 *
 * It is driven by `update(dt)` rather than by the wall clock so that the
 * capture hook can step the whole game a frame at a time and get the same
 * picture every run (`dev/capture.ts`).
 */
export class Tween {
  private elapsed: number;

  constructor(
    readonly duration: number,
    readonly delay = 0,
    /** Start finished — for a screen that is being re-entered, not entered. */
    done = false,
  ) {
    this.elapsed = done ? duration + delay : 0;
  }

  update(dt: number): void {
    this.elapsed += dt;
  }

  get raw(): number {
    if (this.duration <= 0) return 1;
    const t = (this.elapsed - this.delay) / this.duration;
    return t < 0 ? 0 : t > 1 ? 1 : t;
  }

  /** Eased for something that arrives: fast, then settles. */
  get out(): number {
    return expOut(this.raw);
  }

  /** Eased for something that travels from A to B: still, fast, still. */
  get inOut(): number {
    return expInOut(this.raw);
  }

  get finished(): boolean {
    return this.raw >= 1;
  }

  /** `from` → `to`, on the arrival curve. */
  lerpOut(from: number, to: number): number {
    return from + (to - from) * this.out;
  }

  restart(): void {
    this.elapsed = 0;
  }

  finish(): void {
    this.elapsed = this.duration + this.delay;
  }
}

/**
 * A value that chases a target on the expo curve. Used for the map camera,
 * where the destination changes while the previous move is still running and
 * restarting a `Tween` would jump.
 */
export class Chase {
  private from: number;
  private tween: Tween;

  constructor(
    public target: number,
    beat: Beat = "camera",
  ) {
    this.from = target;
    this.tween = new Tween(seconds(beat), 0, true);
  }

  /** Aim somewhere new, starting from wherever the value is right now. */
  to(next: number): void {
    if (next === this.target) return;
    this.from = this.value;
    this.target = next;
    this.tween.restart();
  }

  update(dt: number): void {
    this.tween.update(dt);
  }

  get value(): number {
    return this.from + (this.target - this.from) * this.tween.out;
  }

  snap(v: number): void {
    this.from = v;
    this.target = v;
    this.tween.finish();
  }
}

/**
 * A panel's arrival offset, in virtual pixels, for a tween that is partway
 * through. Panels come in from the nearest edge and settle — never from the
 * centre, because a panel that grows out of nothing reads as a popup rather
 * than as part of the furniture.
 */
export function slideIn(t: Tween, distance: number): number {
  return (1 - t.out) * distance;
}

/**
 * The countdown's thresholds, in seconds remaining.
 *
 * Here rather than in the quest scene because they are part of the same
 * vocabulary as the durations above: "a minute left" is a beat of this game's
 * motion, and a screen that invented its own number would drift from the next
 * screen that does the same.
 */
export const CLOCK = {
  /** It starts paying attention. */
  warn: 60,
  /** It means it. */
  urgent: 30,
} as const;

/**
 * How hard the clock is pulsing right now, 0..1, for `left` seconds remaining
 * and `since` seconds after the most recent threshold was crossed.
 *
 * Calm for most of its life on purpose: this sits on the screen somebody is
 * reading code on, and a countdown that animates every second is noise. The
 * motion belongs to the moments that mean something — arriving, crossing a
 * line, running out — and the reduced-motion scale shortens the beat rather
 * than removing it.
 */
export function clockPulse(left: number, since: number): number {
  const beat = seconds("clockBeat");
  if (since >= beat) return 0;
  const k = 1 - since / beat;
  const depth = left <= 0 ? 1 : left <= CLOCK.urgent ? 0.8 : 0.55;
  return k * k * depth;
}
