/**
 * The clear. Planned here, painted in `scenes/result.ts`.
 *
 * Three things happen when a street is cleared, on top of the confetti and
 * the stamp the screen already had:
 *
 *   1. a **flash** — the whole frame lit for a moment and let go on the expo
 *      curve, so the eye is told *now* before it is told what;
 *   2. **light trails** — comets that leave the centre on a spiral, each one
 *      a bright head with a tail of where it has just been, the tail fading
 *      as it lengthens. A trail is the difference between a particle and a
 *      streak of light, and a streak is what a win looks like;
 *   3. the **XP** — the number this clear was worth, zooming in from far too
 *      big on the expo curve and counting up as it lands; and on a level-up,
 *      the new level slammed in over it.
 *
 * Everything is closed-form — position and alpha are functions of age, as
 * `engine/burst.ts` does it — so it looks the same at 60 Hz and 144 Hz, and
 * every random choice comes from an injected `rng`, so `dev/capture.ts` can
 * step it and get the same frame every run. Nothing here touches a canvas.
 */
import { clamp, expIn, expInOut, expOut } from "./ease";
import { Theme, type RGBA } from "./theme";
import type { Ring } from "./burst";

type Rng = () => number;

/** One streak of light: a spiral out from the centre, drawn with its tail. */
export interface Comet {
  /** The centre it spirals from, in virtual pixels. */
  cx: number;
  cy: number;
  /** Radius at birth and at the end of its life; it eases out between them. */
  r0: number;
  r1: number;
  /** Angle at birth, and how far round it turns over its life (radians). */
  a0: number;
  spin: number;
  /** Seconds it lives, and seconds after the clear before it sets off. */
  life: number;
  delay: number;
  color: RGBA;
  /** Stroke width of the head, in virtual pixels. */
  width: number;
  /** Anything per-comet the paint wants to vary on. */
  seed: number;
}

export interface Celebration {
  comets: Comet[];
  rings: Ring[];
  /** Seconds the flash takes to let go. */
  flash: number;
}

const LIGHT: RGBA[] = [Theme.coin, Theme.cream, Theme.cyan, Theme.pink, [1, 0.95, 0.7, 1]];

function between(rng: Rng, a: number, b: number): number {
  return a + (b - a) * rng();
}

/**
 * The plan. `n` comets around `(cx, cy)`, reaching out to about `reach`
 * virtual pixels. Half of them set off at once and the rest trail out over
 * a third of a second, so the burst has a leading edge and a body rather
 * than one ring of identical streaks.
 */
export function celebrationPlan(
  cx: number,
  cy: number,
  reach: number,
  n: number,
  rng: Rng = Math.random,
): Celebration {
  const comets: Comet[] = [];
  for (let i = 0; i < n; i++) {
    const a0 = (i / n) * Math.PI * 2 + between(rng, -0.25, 0.25);
    const dir = rng() < 0.5 ? -1 : 1;
    comets.push({
      cx,
      cy,
      r0: between(rng, reach * 0.04, reach * 0.12),
      r1: between(rng, reach * 0.55, reach),
      a0,
      spin: dir * between(rng, 0.9, 2.2),
      life: between(rng, 0.9, 1.5),
      delay: i % 2 === 0 ? 0 : between(rng, 0.05, 0.32),
      color: LIGHT[Math.floor(rng() * LIGHT.length) % LIGHT.length],
      width: between(rng, 2, 4.5),
      seed: rng(),
    });
  }
  const rings: Ring[] = [
    { x: cx, y: cy, radius: reach * 0.9, life: 0.8, delay: 0, color: Theme.coin, glow: true },
    { x: cx, y: cy, radius: reach * 1.25, life: 1.05, delay: 0.12, color: Theme.cream, glow: false },
  ];
  return { comets, rings, flash: 0.55 };
}

/**
 * Where a comet's head is at `age` seconds after its delay, and how bright.
 *
 * The radius eases out — almost all of the travel happens in the first
 * third, then it drifts — while the angle eases in and out, so the spiral
 * opens fast and settles. Alpha dies as the square of the remaining life:
 * bright for most of the way, gone at the end rather than fading from the
 * start.
 */
export function cometAt(c: Comet, age: number): { x: number; y: number; alpha: number } {
  const u = clamp(age / c.life, 0, 1);
  const r = c.r0 + (c.r1 - c.r0) * expOut(u);
  const a = c.a0 + c.spin * expInOut(u);
  return {
    x: c.cx + Math.cos(a) * r,
    y: c.cy + Math.sin(a) * r,
    alpha: age < 0 || age > c.life ? 0 : Math.pow(1 - u, 1.6),
  };
}

/**
 * The tail: `samples` positions ending at the head, going back `span`
 * seconds, oldest first. Painted as a polyline whose width and alpha shrink
 * toward the old end, that is the streak. Points before birth are pinned to
 * the birth position, so a comet that has just set off has a tail of zero
 * length rather than one reaching back to nowhere.
 */
export function cometTrail(c: Comet, age: number, samples = 12, span = 0.22): [number, number][] {
  const pts: [number, number][] = [];
  for (let k = samples - 1; k >= 0; k--) {
    const t = Math.max(0, age - (span * k) / (samples - 1));
    const { x, y } = cometAt(c, t);
    pts.push([x, y]);
  }
  return pts;
}

/**
 * Something arriving from far too big: 3.6× and invisible at `u = 0`, its
 * own size and solid at `u = 1`, on the expo-out curve — so nearly all of the
 * shrink happens at once and the last stretch is a settle.
 */
export function zoomIn(u: number): { scale: number; alpha: number } {
  const k = expOut(clamp(u, 0, 1));
  return { scale: 1 + (1 - k) * 2.6, alpha: Math.min(1, clamp(u, 0, 1) * 3) };
}

/**
 * The same thing leaving: it hangs at its own size, then swells and goes on
 * the expo-in curve — slow to start, gone all at once.
 */
export function zoomOut(u: number): { scale: number; alpha: number } {
  const k = expIn(clamp(u, 0, 1));
  return { scale: 1 + k * 1.8, alpha: 1 - k };
}

/** A number counting up from `from` to `to`: fast first, then the last few. */
export function countUp(from: number, to: number, u: number): number {
  return Math.round(from + (to - from) * expOut(clamp(u, 0, 1)));
}

/** The flash: full at the clear, let go on the expo curve over `life`. */
export function flashAlpha(age: number, life: number): number {
  if (age < 0 || age >= life) return 0;
  return 0.85 * (1 - expOut(age / life));
}
