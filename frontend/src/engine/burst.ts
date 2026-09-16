// Ported from CausewaybayGolang/typescript/src/engine/burst.ts (which in turn
// carries it over from that project's love2d Lua). Kept close to the original
// so a fix made there can still be read across; Causewaybay Hacker changes are
// marked where they occur.
/**
 * What a right answer throws into the air, as numbers.
 *
 * The GPU side of the effects (`particles.ts`) only knows how to move a
 * particle from a start, along a reach, under gravity, with an ease-out on
 * the way and a trail behind it. Everything about *which* particles — how
 * many, which way, what colour, how big, for how long — is decided here, in
 * plain arithmetic that a unit test can look at without a WebGL context.
 */
import { RGBA, Theme } from "./theme";

/**
 * 0 a soft glowing disc, 1 a four-point star, 2 a tumbling scrap of paper,
 * 3 a spinning gold coin, 4 a chunk of brick (the piece a deleted character
 * breaks into), 5 a puff of dust, 6 a soft disc that does not wobble, 7 a
 * flat streak (the grain a caret jump drops). 4 and 5 are pixel-art strips
 * when the art has loaded and a procedural stand-in when it has not.
 */
export type Shape = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7;

export interface Particle {
  /** Where it starts, in virtual pixels. */
  x: number;
  y: number;
  /** How far it is thrown over its life, in virtual pixels, easing out. */
  dx: number;
  dy: number;
  /**
   * A second leg, easing in and out exponentially, that lands it somewhere
   * exact: a coin's way to the counter. Zero for anything thrown and left.
   */
  tox: number;
  toy: number;
  /** A bulge along the way, as sin(pi t): the arc a coin flies in. */
  liftx: number;
  lifty: number;
  /** Seconds it lives, and seconds after the burst before it starts. */
  life: number;
  delay: number;
  /** Diameter in virtual pixels, at full size. */
  size: number;
  color: RGBA;
  shape: Shape;
  /** Whether it leaves a trail of ghosts behind it. */
  trail: boolean;
  /** Gravity, in virtual pixels per second squared. */
  gravity: number;
  /** Anything per-particle the shader wants to vary on: spin, flutter, phase. */
  seed: number;
}

export interface Ring {
  x: number;
  y: number;
  /** Radius at the end of the expansion, in virtual pixels. */
  radius: number;
  life: number;
  delay: number;
  color: RGBA;
  /** A soft disc of light rather than a line. */
  glow: boolean;
}

export interface Plan {
  particles: Particle[];
  rings: Ring[];
}

const SPARK: RGBA[] = [Theme.coin, Theme.pink, Theme.cyan, Theme.cream, Theme.admit];
const PAPER: RGBA[] = [Theme.coin, Theme.pink, Theme.cyan, Theme.cream, Theme.admit, Theme.brick];
const GOLD: RGBA[] = [Theme.coin, Theme.cream, [1, 0.95, 0.7, 1]];

type Rng = () => number;

function between(rng: Rng, a: number, b: number): number {
  return a + (b - a) * rng();
}

function pick<T>(rng: Rng, list: T[]): T {
  return list[Math.floor(rng() * list.length) % list.length];
}

/** Something thrown from a point: no second leg, no arc. */
function thrown(
  x: number,
  y: number,
  dx: number,
  dy: number,
  rest: Omit<Particle, "x" | "y" | "dx" | "dy" | "tox" | "toy" | "liftx" | "lifty">,
): Particle {
  return { x, y, dx, dy, tox: 0, toy: 0, liftx: 0, lifty: 0, ...rest };
}

/**
 * The burst a right answer gets. `n` is what the core asks for — it climbs
 * with the streak — and everything scales from it: more sparks, further,
 * with a little longer to fall.
 */
export function burstPlan(x: number, y: number, n: number, rng: Rng = Math.random): Plan {
  const k = Math.max(0.6, Math.min(2.2, n / 36));
  const particles: Particle[] = [];
  const rings: Ring[] = [];

  // The sparks: a shell of glowing points thrown in every direction, each
  // with a trail, easing out to a stop and then dropping.
  for (let i = 0; i < n; i++) {
    const ang = rng() * Math.PI * 2;
    const reach = between(rng, 70, 230) * Math.sqrt(k);
    particles.push(
      thrown(x, y, Math.cos(ang) * reach, Math.sin(ang) * reach - 40 * k, {
        life: between(rng, 1.1, 1.9),
        delay: rng() * 0.06,
        size: between(rng, 5, 12),
        color: pick(rng, SPARK),
        shape: 0,
        trail: true,
        gravity: 150,
        seed: rng(),
      }),
    );
  }

  // The stars: fewer, bigger, gold, and they go further.
  const stars = Math.round(n / 3);
  for (let i = 0; i < stars; i++) {
    const ang = rng() * Math.PI * 2;
    const reach = between(rng, 120, 300) * Math.sqrt(k);
    particles.push(
      thrown(x, y, Math.cos(ang) * reach, Math.sin(ang) * reach - 60 * k, {
        life: between(rng, 1.4, 2.2),
        delay: rng() * 0.1,
        size: between(rng, 14, 26),
        color: pick(rng, GOLD),
        shape: 1,
        trail: true,
        gravity: 90,
        seed: rng(),
      }),
    );
  }

  // The paper: thrown mostly upward, tumbling, and it takes its time to fall.
  const paper = Math.round(n / 2);
  for (let i = 0; i < paper; i++) {
    const ang = -Math.PI / 2 + (rng() - 0.5) * Math.PI * 1.3;
    const reach = between(rng, 90, 320) * Math.sqrt(k);
    particles.push(
      thrown(x, y, Math.cos(ang) * reach, Math.sin(ang) * reach, {
        life: between(rng, 1.9, 2.9),
        delay: rng() * 0.12,
        size: between(rng, 9, 16),
        color: pick(rng, PAPER),
        shape: 2,
        trail: false,
        gravity: 220,
        seed: rng(),
      }),
    );
  }

  // A flash of light where it happened, and a shockwave out of it.
  rings.push({ x, y, radius: 90 * Math.sqrt(k), life: 0.5, delay: 0, color: Theme.cream, glow: true });
  rings.push({ x, y, radius: 150 * Math.sqrt(k), life: 0.8, delay: 0, color: Theme.coin, glow: false });
  if (k > 1.4) {
    rings.push({ x, y, radius: 210 * Math.sqrt(k), life: 1.0, delay: 0.15, color: Theme.pink, glow: false });
  }

  return { particles, rings };
}

/**
 * A street going CLEAR: fireworks across the scene, one after another, and
 * a slow rain of paper from the top. `perfect` is a fourth, bigger one in
 * the middle, all gold.
 */
export function clearPlan(
  rect: { x: number; y: number; w: number; h: number },
  perfect: boolean,
  rng: Rng = Math.random,
): Plan {
  const particles: Particle[] = [];
  const rings: Ring[] = [];
  const shells: Array<[number, number, number]> = [
    [rect.x + rect.w * 0.25, rect.y + rect.h * 0.35, 0],
    [rect.x + rect.w * 0.75, rect.y + rect.h * 0.3, 0.18],
    [rect.x + rect.w * 0.5, rect.y + rect.h * 0.22, 0.36],
  ];
  if (perfect) shells.push([rect.x + rect.w * 0.5, rect.y + rect.h * 0.45, 0.6]);

  shells.forEach(([sx, sy, at], i) => {
    const big = perfect && i === shells.length - 1;
    const shell = burstPlan(sx, sy, big ? 96 : 48, rng);
    for (const p of shell.particles) {
      p.delay += at;
      if (big) p.color = pick(rng, GOLD);
    }
    for (const r of shell.rings) r.delay += at;
    particles.push(...shell.particles);
    rings.push(...shell.rings);
  });

  // The rain: paper from above the scene, drifting down over a few seconds.
  const rain = perfect ? 90 : 60;
  for (let i = 0; i < rain; i++) {
    particles.push(
      thrown(rect.x + rng() * rect.w, rect.y - 20, (rng() - 0.5) * 80, rect.h * between(rng, 0.5, 0.9), {
        life: between(rng, 2.2, 3.4),
        delay: rng() * 1.6,
        size: between(rng, 9, 15),
        color: perfect ? pick(rng, GOLD) : pick(rng, PAPER),
        shape: 2,
        trail: false,
        gravity: 60,
        seed: rng(),
      }),
    );
  }

  return { particles, rings };
}

/** Seconds a coin is in the air, and the most a shower is spread over. */
export const COIN_FLIGHT = 1.15;
export const COIN_SPREAD = 0.5;

/**
 * Coins from where the answer landed to the counter: each is tossed a little
 * way out (easing out), hangs at the top of its arc, then whips into the
 * counter (easing in), with a tail behind it. They leave one after another,
 * so the counter takes them one after another too. Returns the plan and the
 * moment, in seconds from now, the first coin arrives.
 */
export function coinPlan(
  x: number,
  y: number,
  tx: number,
  ty: number,
  n: number,
  rng: Rng = Math.random,
): { plan: Plan; firstLanding: number; lastLanding: number } {
  const particles: Particle[] = [];
  const rings: Ring[] = [];
  const count = Math.max(1, Math.round(n));
  // The arc bulges away from the straight line, upward for preference.
  const ddx = tx - x;
  const ddy = ty - y;
  const len = Math.max(1, Math.hypot(ddx, ddy));
  const nx = -ddy / len;
  const ny = ddx / len;
  const sign = ny < 0 ? 1 : -1;

  for (let i = 0; i < count; i++) {
    const delay = (i / count) * COIN_SPREAD + rng() * 0.04;
    const ang = -Math.PI / 2 + (rng() - 0.5) * Math.PI * 1.4;
    const toss = between(rng, 24, 70);
    const dx = Math.cos(ang) * toss;
    const dy = Math.sin(ang) * toss;
    // A shallow arc: enough to read as a throw, not so much that a coin
    // bound for the top corner sails through the HUD on its way.
    const lift = between(rng, 0.05, 0.15) * len * sign;
    particles.push({
      x,
      y,
      dx,
      dy,
      tox: ddx - dx,
      toy: ddy - dy,
      liftx: nx * lift,
      lifty: ny * lift,
      life: COIN_FLIGHT * between(rng, 0.92, 1.08),
      delay,
      size: between(rng, 24, 32),
      color: Theme.coin,
      shape: 3,
      trail: true,
      gravity: 0,
      seed: rng(),
    });
  }

  const firstLanding = COIN_FLIGHT * 0.92;
  const lastLanding = COIN_SPREAD + 0.04 + COIN_FLIGHT * 1.08;
  // A wink of light at the counter as the first lands, and as the last does.
  rings.push({ x: tx, y: ty, radius: 46, life: 0.3, delay: firstLanding, color: Theme.coin, glow: true });
  rings.push({ x: tx, y: ty, radius: 70, life: 0.4, delay: lastLanding, color: Theme.cream, glow: false });
  return { plan: { particles, rings }, firstLanding, lastLanding };
}

// ---------------------------------------------------------------------------
// The editor's effects. Causewaybay Hacker addition.
//
// Typing is the game here, so the keystrokes get the same treatment a right
// answer does: every plan below is what one gesture in the editor throws into
// the air, in the editor's own virtual pixels. `cell` is the width and height
// of one character cell, which is the only size these know — a bigger font is
// a bigger explosion, and that is right.
//
// Same shape as the burst above: plain arithmetic, a `rng` that can be pinned,
// and nothing that needs a GPU to be looked at.
// ---------------------------------------------------------------------------

/** How big one character is on screen, in virtual pixels: `[width, height]`. */
export type Cell = readonly [number, number];

const DUST: RGBA[] = [Theme.dim, Theme.cream, [0.6, 0.55, 0.5, 1], [0.45, 0.4, 0.38, 1]];
/** `col` a little lighter or darker: one brick is never quite its neighbour's colour. */
function shade(col: RGBA, k: number): RGBA {
  return [
    Math.min(1, col[0] * k),
    Math.min(1, col[1] * k),
    Math.min(1, col[2] * k),
    col[3],
  ];
}

/**
 * What the pointer leaves behind as it crosses the code page: one ember on
 * the path, in the caret's colour, with the shader's ghost trail for a body.
 *
 * Thin and short on purpose. The first version cycled through colours and
 * was a website's mouse trail pasted over an editor; this is a thread of
 * the same light the caret smears, and it says only "the pointer went this
 * way". The ember drifts a little *against* the motion (`vx, vy`, virtual
 * pixels a second) so the thread lengthens with speed, and its core goes
 * whiter the faster the pointer went.
 */
export function pointerPlan(
  x: number,
  y: number,
  vx: number,
  vy: number,
  rng: Rng = Math.random,
): Plan {
  const speed = Math.hypot(vx, vy);
  const nx = speed > 1 ? -vx / speed : 0;
  const ny = speed > 1 ? -vy / speed : 0;
  const heat = Math.min(1, speed / SMEAR_HOT);
  const drift = between(rng, 4, 9) * (0.6 + heat);
  const c = Theme.cyan;
  const particles: Particle[] = [
    thrown(x, y, nx * drift, ny * drift, {
      life: between(rng, 0.22, 0.3),
      delay: 0,
      size: 4 + 3 * heat,
      color: [c[0] + (1 - c[0]) * heat * 0.6, c[1] + (1 - c[1]) * heat * 0.6, c[2], 1],
      shape: 6,
      trail: true,
      gravity: 0,
      seed: rng(),
    }),
  ];
  return { particles, rings: [] };
}

/**
 * The caret moved: a smear.
 *
 * The first version of the code page's light trail followed the *pointer*,
 * in a cycle of colours, and read as a website's mouse trail pasted over an
 * editor. This follows the *caret* — the thing that actually moves when
 * code is written — and is what a good terminal does: the caret's rectangle
 * stretches from where it was to where it is and shrinks back, its width and
 * alpha dying together inside a fifth of a second, with a thin white core
 * down its middle that gets hotter the faster the caret went. One colour
 * plus white; the caret's own neon.
 *
 * Along a line it is a horizontal beam. Across lines it bends: down the
 * column first and then along the new line, an L, with a wink of light at
 * the corner. The path is two or three points in virtual pixels, and the
 * GPU (`particles.ts`) or the 2D fallback (`ui/sparks.ts`) draws it.
 */
export interface Smear {
  /** Two points for a straight run, three for a bend, `[x, y]` each. */
  path: ReadonlyArray<readonly [number, number]>;
  /** Full width in virtual pixels: the caret's height. */
  width: number;
  /** Seconds from stretch to gone. */
  life: number;
  color: RGBA;
  /** 0..1, how white the core burns: the caret's speed. */
  core: number;
}

/** Virtual pixels per second past which the core is as white as it gets. */
const SMEAR_HOT = 2400;

/**
 * The smear for a caret that was at `from` and is now at `to` — both the
 * top-left of the caret's cell — having got there at `speed` virtual pixels
 * a second (its distance over the time since it last moved).
 */
export function smearFor(
  from: readonly [number, number],
  to: readonly [number, number],
  cell: Cell,
  speed: number,
): Smear {
  const [, ch] = cell;
  const mid = ch / 2;
  const a: [number, number] = [from[0], from[1] + mid];
  const b: [number, number] = [to[0], to[1] + mid];
  const bend = Math.abs(a[1] - b[1]) > ch * 0.5 && Math.abs(a[0] - b[0]) > 0.5;
  const path = bend ? [a, [a[0], b[1]] as const, b] : [a, b];
  const dist = pathLength(path);
  return {
    path,
    width: ch,
    // A step lives a short life; a jump across the screen a little longer,
    // so the tail has time to cross what the head crossed.
    life: Math.min(0.22, 0.12 + dist / 4000),
    color: Theme.cyan,
    core: Math.min(1, 0.35 + (0.65 * speed) / SMEAR_HOT),
  };
}

/** The bend's wink: a small glow where the smear turns the corner. Nothing on a straight run. */
export function cornerPlan(smear: Smear): Plan {
  if (smear.path.length < 3) return { particles: [], rings: [] };
  const [x, y] = smear.path[1];
  return {
    particles: [],
    rings: [{ x, y, radius: smear.width * 0.9, life: smear.life, delay: 0, color: smear.color, glow: true }],
  };
}

export function pathLength(path: ReadonlyArray<readonly [number, number]>): number {
  let len = 0;
  for (let i = 1; i < path.length; i++) len += Math.hypot(path[i][0] - path[i - 1][0], path[i][1] - path[i - 1][1]);
  return len;
}

/** The point `u` (0..1) of the way along `path`, by distance. */
export function pathPoint(path: ReadonlyArray<readonly [number, number]>, u: number): [number, number] {
  const total = pathLength(path);
  let want = Math.max(0, Math.min(1, u)) * total;
  for (let i = 1; i < path.length; i++) {
    const [ax, ay] = path[i - 1];
    const [bx, by] = path[i];
    const seg = Math.hypot(bx - ax, by - ay);
    if (want <= seg || i === path.length - 1) {
      const f = seg > 0 ? Math.min(1, want / seg) : 1;
      return [ax + (bx - ax) * f, ay + (by - ay) * f];
    }
    want -= seg;
  }
  return [path[0][0], path[0][1]];
}

/**
 * Whether a caret move is a *jump* — PageDown, a click on a far line, a
 * search hit — rather than a step. A jump gets grains; a step never does,
 * so an arrow key held down is a beam and not a game.
 */
export function isJump(
  from: readonly [number, number],
  to: readonly [number, number],
  cell: Cell,
): boolean {
  const [cw, ch] = cell;
  return Math.abs(to[1] - from[1]) >= ch * 2.5 || Math.abs(to[0] - from[0]) >= cw * 16;
}

/**
 * The grains a jump drops along its smear: a dozen or so flat streaks —
 * never taller than a fraction of the line — that appear in order along
 * the path, fall a little, and are gone in half a second. Shape 7 is that
 * streak. Rare on purpose: this is the moment the smear looks like it was
 * going too fast, not a thing that happens every keystroke.
 */
export function jumpPlan(smear: Smear, rng: Rng = Math.random): Plan {
  const ch = smear.width;
  const dist = pathLength(smear.path);
  const count = Math.round(Math.min(20, 8 + dist / (ch * 4)));
  const particles: Particle[] = [];
  for (let i = 0; i < count; i++) {
    const u = (i + rng()) / count;
    const [x, y] = pathPoint(smear.path, u);
    particles.push(
      thrown(x, y + (rng() - 0.5) * ch * 0.5, (rng() - 0.5) * ch, between(rng, 0.1, 0.4) * ch, {
        life: between(rng, 0.3, 0.5),
        delay: u * 0.08 + rng() * 0.03,
        size: between(rng, 0.45, 0.8) * ch,
        color: i % 4 === 3 ? Theme.cream : smear.color,
        shape: 7,
        trail: false,
        gravity: 260,
        seed: rng(),
      }),
    );
  }
  return { particles, rings: [] };
}

/**
 * One character typed: a few sparks off the caret, in the colour the
 * character will be highlighted in, and a wink of light. `n` is how many
 * characters arrived at once — a paste is one bigger pop, not a pop per
 * letter.
 */
export function keyPlan(
  x: number,
  y: number,
  cell: Cell,
  color: RGBA,
  n = 1,
  rng: Rng = Math.random,
): Plan {
  const [cw, ch] = cell;
  const k = Math.min(3, Math.sqrt(n));
  const particles: Particle[] = [];
  const count = Math.round(4 * k);
  for (let i = 0; i < count; i++) {
    // Up and out, biased away from the line being typed on so the sparks
    // do not sit over the next character.
    const ang = -Math.PI / 2 + (rng() - 0.5) * Math.PI * 1.1;
    const reach = between(rng, 0.8, 2.2) * ch * k;
    particles.push(
      thrown(x, y, Math.cos(ang) * reach, Math.sin(ang) * reach, {
        life: between(rng, 0.35, 0.65),
        delay: rng() * 0.03,
        size: between(rng, 0.25, 0.5) * ch,
        // Two in three the token's colour, the third white-hot: a spark has
        // a core. Counted rather than rolled, so a single keystroke's four
        // sparks are always mostly the colour of what was typed.
        color: i % 3 === 2 ? Theme.cream : color,
        shape: 0,
        trail: true,
        gravity: 260,
        seed: rng(),
      }),
    );
  }
  const rings: Ring[] = [
    { x: x + cw / 2, y, radius: ch * 0.9 * k, life: 0.28, delay: 0, color, glow: true },
  ];
  return { particles, rings };
}

/**
 * ENTER: dust. The caret lands on a new line and kicks up a puff along it —
 * soft, slow, grey-cream motes that drift up and thin out, the way dust does
 * when something drops onto a shelf. `x, y` is where the caret landed.
 */
export function dustPlan(x: number, y: number, cell: Cell, rng: Rng = Math.random): Plan {
  const [cw, ch] = cell;
  const particles: Particle[] = [];
  const count = 14;
  for (let i = 0; i < count; i++) {
    // Along the line, mostly to the right of the caret — that is where the
    // new line is — and rising, with a little sideways spread.
    const side = rng() < 0.75 ? 1 : -1;
    const along = between(rng, 0.5, 9) * cw * side;
    particles.push(
      thrown(x + (rng() - 0.3) * cw, y + ch * 0.4, along, -between(rng, 0.3, 1.4) * ch, {
        life: between(rng, 0.55, 1.0),
        delay: rng() * 0.08,
        size: between(rng, 0.6, 1.1) * ch,
        color: pick(rng, DUST),
        shape: 5,
        trail: false,
        // Negative: dust rises, then hangs.
        gravity: -40,
        seed: rng(),
      }),
    );
  }
  // A few brighter grains in the cloud, so it catches the light.
  for (let i = 0; i < 4; i++) {
    particles.push(
      thrown(x, y + ch * 0.4, between(rng, 1, 6) * cw, -between(rng, 0.5, 1.5) * ch, {
        life: between(rng, 0.4, 0.7),
        delay: rng() * 0.05,
        size: between(rng, 0.15, 0.3) * ch,
        color: Theme.cream,
        shape: 0,
        trail: true,
        gravity: 120,
        seed: rng(),
      }),
    );
  }
  const rings: Ring[] = [
    { x: x + cw, y: y + ch * 0.3, radius: ch * 1.6, life: 0.4, delay: 0, color: Theme.cream, glow: true },
  ];
  return { particles, rings };
}

/** One character's cell, for `rubblePlan`: its top-left and its colour. */
export interface Rubble {
  x: number;
  y: number;
  color: RGBA;
}

/** The most cells one deletion breaks: past this, the rest went quietly. */
export const RUBBLE_MAX = 400;

/**
 * Deleted characters break like bricks — every one of them.
 *
 * A cell per character, in that character's own syntax colour, so a deleted
 * line crumbles the way it was written: pink where the keyword was, green
 * where the string was. Each cell throws its own chunks — right and down for
 * preference, the way rubble falls off a wall hit from the left — heavy and
 * spinning, gone in under a second, with a pinch of dust so it is rubble and
 * not confetti. The cells go in order, a few milliseconds apart, so a whole
 * line does not vanish in one flash but crumbles across, left to right.
 *
 * A big deletion is more rubble, up to a point: the chunks per cell drop
 * from three to two past forty cells, so a page selected and deleted is a
 * landslide and not a frame drop.
 */
export function rubblePlan(cells: readonly Rubble[], cell: Cell, rng: Rng = Math.random): Plan {
  const [cw, ch] = cell;
  const particles: Particle[] = [];
  const rings: Ring[] = [];
  const n = Math.min(cells.length, RUBBLE_MAX);
  if (n === 0) return { particles, rings };
  const perCell = n > 40 ? 2 : 3;
  const stagger = n > 40 ? 0.004 : 0.012;
  for (let i = 0; i < n; i++) {
    const { x, y, color } = cells[i];
    const at = i * stagger;
    for (let k = 0; k < perCell; k++) {
      const px = x + rng() * cw;
      const py = y + rng() * ch;
      const ang = (rng() - 0.35) * Math.PI - Math.PI / 2;
      const reach = between(rng, 1.2, 3.5) * ch;
      particles.push(
        thrown(px, py, Math.cos(ang) * reach + cw * 0.5, Math.sin(ang) * reach, {
          life: between(rng, 0.55, 0.95),
          delay: at + rng() * 0.03,
          size: between(rng, 0.3, 0.55) * ch,
          color: shade(color, between(rng, 0.6, 1.15)),
          shape: 4,
          trail: false,
          gravity: 900,
          seed: rng(),
        }),
      );
    }
    // Dust on every other cell: enough to hang in the air, not a fog.
    if (i % 2 === 0) {
      particles.push(
        thrown(x + rng() * cw, y + ch * 0.6, (rng() - 0.3) * 3 * cw, -between(rng, 0.2, 1) * ch, {
          life: between(rng, 0.4, 0.8),
          delay: at + rng() * 0.04,
          size: between(rng, 0.5, 0.9) * ch,
          color: pick(rng, DUST),
          shape: 5,
          trail: false,
          gravity: -20,
          seed: rng(),
        }),
      );
    }
  }
  // One flash for the lot, centred on what went, wider the more went.
  const first = cells[0];
  const last = cells[n - 1];
  rings.push({
    x: (first.x + last.x + cw) / 2,
    y: (first.y + last.y + ch) / 2,
    radius: ch * (1.2 + Math.min(3, Math.sqrt(n) * 0.4)),
    life: 0.3,
    delay: 0,
    color: last.color,
    glow: true,
  });
  return { particles, rings };
}

/**
 * The caret is beside a bracket and its partner lit up: a couple of sparks
 * run the line between them, so the eye is led from one to the other.
 * `a` and `b` are the centres of the two bracket cells.
 */
export function linkPlan(
  a: readonly [number, number],
  b: readonly [number, number],
  cell: Cell,
  rng: Rng = Math.random,
): Plan {
  const [, ch] = cell;
  const ddx = b[0] - a[0];
  const ddy = b[1] - a[1];
  const len = Math.max(1, Math.hypot(ddx, ddy));
  // Bulge away from the straight line, so the runner is visibly a runner and
  // not a character sliding along the text.
  const nx = -ddy / len;
  const ny = ddx / len;
  const particles: Particle[] = [];
  for (let i = 0; i < 3; i++) {
    const lift = between(rng, 0.08, 0.2) * len * (i % 2 === 0 ? 1 : -1);
    particles.push({
      x: a[0],
      y: a[1],
      dx: 0,
      dy: 0,
      tox: ddx,
      toy: ddy,
      liftx: nx * lift,
      lifty: ny * lift,
      life: between(rng, 0.32, 0.45),
      delay: i * 0.03,
      size: between(rng, 0.25, 0.45) * ch,
      color: Theme.cyan,
      shape: 0,
      trail: true,
      gravity: 0,
      seed: rng(),
    });
  }
  const rings: Ring[] = [
    { x: a[0], y: a[1], radius: ch * 0.9, life: 0.3, delay: 0, color: Theme.cyan, glow: true },
    { x: b[0], y: b[1], radius: ch * 0.9, life: 0.3, delay: 0.3, color: Theme.cyan, glow: true },
  ];
  return { particles, rings };
}

/**
 * A loop closed: the moment its last brace (or, in Python, its first body
 * line) is written. Stars run a loop of their own around the block — from
 * the closing brace up to the keyword along one side and back down the
 * other — and where they meet, a burst.
 *
 * `open` is the centre of the loop's first character, `close` of its last.
 */
export function loopPlan(
  open: readonly [number, number],
  close: readonly [number, number],
  cell: Cell,
  rng: Rng = Math.random,
): Plan {
  const [, ch] = cell;
  const particles: Particle[] = [];
  const rings: Ring[] = [];
  const ddx = open[0] - close[0];
  const ddy = open[1] - close[1];
  const len = Math.max(ch, Math.hypot(ddx, ddy));
  const nx = -ddy / len;
  const ny = ddx / len;
  // Tall enough to read as a loop even on a one-line `loop {}`.
  const bulge = Math.max(ch * 2.5, len * 0.35);

  const leg = (from: readonly [number, number], dx: number, dy: number, sign: number, at: number) => {
    const n = 12;
    for (let i = 0; i < n; i++) {
      particles.push({
        x: from[0],
        y: from[1],
        dx: 0,
        dy: 0,
        tox: dx,
        toy: dy,
        liftx: nx * bulge * sign,
        lifty: ny * bulge * sign,
        life: 0.85,
        delay: at + i * 0.028,
        size: between(rng, 0.7, 1.1) * ch,
        color: pick(rng, GOLD),
        shape: 1,
        trail: true,
        gravity: 0,
        seed: rng(),
      });
    }
  };
  // Up one side, back down the other, and the two legs overlap a little so
  // the loop never has a gap in it.
  leg(close, ddx, ddy, 1, 0);
  leg(open, -ddx, -ddy, -1, 0.55);

  rings.push({ x: close[0], y: close[1], radius: ch * 2.2, life: 0.4, delay: 0, color: Theme.coin, glow: true });
  rings.push({ x: open[0], y: open[1], radius: ch * 2.2, life: 0.4, delay: 0.8, color: Theme.coin, glow: true });

  // The finale, where the second leg lands: a right answer's burst, scaled
  // to the type size rather than to a streak.
  const finale = burstPlan(close[0], close[1], 28, rng);
  const scale = ch / 22;
  for (const p of finale.particles) {
    p.delay += 1.35;
    p.dx *= scale;
    p.dy *= scale;
    p.size *= Math.max(0.6, scale);
    p.gravity *= scale;
  }
  for (const r of finale.rings) {
    r.delay += 1.35;
    r.radius *= scale;
  }
  particles.push(...finale.particles);
  rings.push(...finale.rings);
  return { particles, rings };
}
