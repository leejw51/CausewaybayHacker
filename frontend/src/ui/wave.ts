import { css, type RGBA } from "../engine/theme";
import type { Ctx } from "../engine/ui";

/**
 * Waiting, drawn as cosine waves: for a compile or a run that is out.
 *
 * Smooth all the way round (a cosine has no corners), so it reads as
 * breathing rather than as a spinner ticking. Neon — cyan into violet into
 * pink, with a glow — but nothing flashes: every brightness here moves on a
 * cosine, never a step.
 */

/** One full wave every `PERIOD` seconds. */
const PERIOD = 1.15;

const CYAN: RGBA = [0.3, 0.92, 1, 1];
const VIOLET: RGBA = [0.62, 0.48, 1, 1];
const PINK: RGBA = [1, 0.38, 0.72, 1];

/** Along the neon ramp: 0 cyan, 0.5 violet, 1 pink. */
function ramp(u: number): RGBA {
  const k = Math.max(0, Math.min(1, u));
  const [a, b, f] = k < 0.5 ? [CYAN, VIOLET, k * 2] : [VIOLET, PINK, (k - 0.5) * 2];
  return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, 1];
}

/**
 * A row of `n` dots, each rising, swelling and glowing as a cosine wave
 * passes along them, coloured along the ramp. Returns the width it took.
 * (`_col` is kept for callers; the ramp is the colour now.)
 */
export function waveDots(
  g: Ctx,
  x: number,
  midY: number,
  t: number,
  _col: RGBA,
  s: number,
  n = 5,
): number {
  const r = 2.6 * s;
  const gap = 7.5 * s;
  g.save();
  for (let i = 0; i < n; i++) {
    const ph = (t / PERIOD) * Math.PI * 2 - i * 0.75;
    const k = (1 - Math.cos(ph)) / 2; // 0..1, smooth
    const col = ramp(i / Math.max(1, n - 1));
    g.shadowColor = css(col, 0.9);
    g.shadowBlur = 10 * s * k;
    g.fillStyle = css(col, 0.35 + 0.65 * k);
    g.beginPath();
    g.arc(x + r + i * gap, midY + r * 1.4 - k * r * 2.8, r * (0.8 + 0.35 * k), 0, Math.PI * 2);
    g.fill();
  }
  g.restore();
  return r * 2 + (n - 1) * gap;
}

/** FNV-1a over the text: the same source, the same curve. */
export function sourceSeed(text: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

/** mulberry32: a small seeded generator, 0..1. */
function seeded(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** An integer hash to 0..1. */
function hash01(seed: number, i: number): number {
  let h = (seed ^ Math.imul(i, 0x9e3779b1)) >>> 0;
  h = Math.imul(h ^ (h >>> 16), 0x85ebca6b);
  h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}

/**
 * Smooth value noise, -1..1: random heights at the integers, joined by a
 * cosine — never periodic, never a corner.
 */
function noise(seed: number, x: number): number {
  const i = Math.floor(x);
  const f = x - i;
  const k = (1 - Math.cos(Math.PI * f)) / 2;
  const a = hash01(seed, i);
  const b = hash01(seed, i + 1);
  return (a + (b - a) * k) * 2 - 1;
}

/** Two octaves of it: big slow wanders with a little quicker detail. */
function wander(seed: number, x: number): number {
  return noise(seed, x) * 0.7 + noise(seed ^ 0x5bd1e995, x * 2.3) * 0.3;
}

/** Now and then a surge, 0..1: a smooth bump, rare and at no fixed time. */
function surge(seed: number, t: number): number {
  const n = noise(seed ^ 0x27d4eb2f, t * 0.45);
  return Math.max(0, (n - 0.45) / 0.55) ** 2;
}

interface Layer {
  /** Seeds for this layer's own noise. */
  nf: number;
  na: number;
  nc: number;
  /** Cycles across the width, at rest. */
  f0: number;
  /** How far the frequency swings, 0..1, and how fast (Hz): the bandwidth. */
  fDepth: number;
  fRate: number;
  /** Height, and its own slow swell. */
  amp: number;
  aDepth: number;
  aRate: number;
  /** Travel, cycles a second; negative runs the other way. */
  speed: number;
  /** The overtone's share and its ratio to the tone. */
  over: number;
  ratio: number;
  phase: number;
  hue: number;
  alpha: number;
  width: number;
}

const layersFor = new Map<number, Layer[]>();

/** The source's own family of curves, made once per seed. */
function layers(seed: number): Layer[] {
  const had = layersFor.get(seed);
  if (had) return had;
  const r = seeded(seed);
  const hueAt = r();
  const out: Layer[] = [0, 1, 2, 3].map((i) => ({
    nf: (seed + i * 7919) >>> 0,
    na: (seed + i * 104729 + 1) >>> 0,
    nc: (seed + i * 1299709 + 2) >>> 0,
    f0: 1.4 + r() * 4.2,
    fDepth: 0.35 + r() * 0.5,
    fRate: 0.08 + r() * 0.3,
    amp: i === 0 ? 1 : 0.5 + r() * 0.5,
    aDepth: 0.2 + r() * 0.5,
    aRate: 0.08 + r() * 0.25,
    speed: (0.35 + r() * 1.1) * (r() < 0.3 ? -1 : 1),
    over: 0.15 + r() * 0.5,
    ratio: 1.5 + r() * 1.6,
    phase: r() * Math.PI * 2,
    hue: (hueAt + i * 0.23 + r() * 0.1) % 1,
    alpha: i === 0 ? 0.95 : 0.3 + r() * 0.3,
    width: i === 0 ? 2.2 : 1.1 + r() * 0.6,
  }));
  if (layersFor.size > 32) layersFor.clear();
  layersFor.set(seed, out);
  return out;
}

/**
 * Waiting, as the source's own curves: four layers whose shape comes from
 * a hash of the code (the same program, the same curves; edit it and they
 * change), each drifting through its bandwidth — its frequency stretching
 * and squeezing, its height swelling — on slow seeded cosines, a tone and
 * an overtone apiece, tapering at both ends, on the neon ramp with a glow,
 * and a bright bead riding the main one.
 *
 * The shape is drawn in cycles per width, so a line stretched across a wide
 * well passes `density` (its width over the 360-unit line it was tuned at)
 * to keep the same texture rather than flattening into long lazy swells;
 * `height` scales the swing for a well with the room for it.
 */
export function waveLine(
  g: Ctx,
  x: number,
  midY: number,
  w: number,
  t: number,
  _col: RGBA,
  s: number,
  seed = 0,
  density = 1,
  height = 1,
): void {
  const amp = 22 * s * height;
  const step = Math.max(2, 2.5 * s);
  const TAU = Math.PI * 2;
  const ls = layers(seed);
  // Two packets of energy travelling the curve at their own speeds: where
  // one passes, the curve stands up.
  const pk = [0, 1].map((k) => {
    const sp = 0.07 + hash01(seed, 40 + k) * 0.16;
    const c = (((hash01(seed, 50 + k) + t * sp * (k === 0 ? 1 : -1)) % 1) + 1) % 1;
    return { c, wid: (0.08 + hash01(seed, 60 + k) * 0.1) / Math.max(1, Math.sqrt(density)) };
  });
  const burst = surge(seed, t);
  const yAt = (l: Layer, dx: number): number => {
    const u = dx / w;
    // The bandwidth wanders, not cycles: the frequency is scaled by
    // e^(noise), about 0.4x to 3x, and a surge widens it further.
    const f = l.f0 * density * Math.exp(1.0 * wander(l.nf, t * l.fRate * 4) + burst * 0.8);
    const a = l.amp * Math.max(0.15, 0.75 + 0.55 * wander(l.na, t * l.aRate * 3) + burst * 0.6);
    // A chirp: tighter at one end of the line than the other, which end
    // and how much wandering too.
    const chirp = wander(l.nc, t * 0.2) * 1.6;
    const ph = TAU * (f * (u + chirp * u * u * 0.5) - l.speed * t) + l.phase;
    const y = Math.cos(ph) + l.over * Math.cos(ph * l.ratio + l.phase * 0.5);
    let env = Math.sin(u * Math.PI) * 0.45;
    for (const p of pk) {
      const dd = Math.min(Math.abs(u - p.c), 1 - Math.abs(u - p.c)) / p.wid;
      env += Math.exp(-dd * dd) * 0.9 * Math.sin(u * Math.PI);
    }
    return midY + (y / (1 + l.over)) * a * amp * env;
  };
  g.save();
  g.lineCap = "round";
  g.lineJoin = "round";
  for (let i = ls.length - 1; i >= 0; i--) {
    const l = ls[i];
    const grad = g.createLinearGradient(x, 0, x + w, 0);
    grad.addColorStop(0, css(ramp(l.hue)));
    grad.addColorStop(0.5, css(ramp((l.hue + 0.35) % 1)));
    grad.addColorStop(1, css(ramp((l.hue + 0.7) % 1)));
    g.globalAlpha = l.alpha;
    g.strokeStyle = grad;
    g.lineWidth = Math.max(1, l.width * s);
    g.shadowColor = css(VIOLET, 0.8);
    g.shadowBlur = i === 0 ? 12 * s : 0;
    g.beginPath();
    for (let dx = 0; dx <= w; dx += step) {
      const y = yAt(l, dx);
      if (dx === 0) g.moveTo(x + dx, y);
      else g.lineTo(x + dx, y);
    }
    g.stroke();
  }

  // The bead on the main curve, eased in and out at the ends.
  const u = (((t / (PERIOD * 1.6)) % 1) + 1) % 1;
  const px = u * w;
  const py = yAt(ls[0], px);
  const col = ramp(u);
  g.globalAlpha = Math.sin(u * Math.PI);
  g.shadowColor = css(col);
  g.shadowBlur = 18 * s;
  g.fillStyle = css([1, 1, 1, 1]);
  g.beginPath();
  g.arc(x + px, py, 2.6 * s, 0, Math.PI * 2);
  g.fill();
  g.fillStyle = css(col, 0.35);
  g.beginPath();
  g.arc(x + px, py, 6 * s, 0, Math.PI * 2);
  g.fill();
  g.restore();
}
