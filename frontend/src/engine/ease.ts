// Ported from CausewaybayGolang/typescript/src/engine/ease.ts (which in turn
// carries it over from that project's love2d Lua). Kept close to the original
// so a fix made there can still be read across; Causewaybay Hacker changes are
// marked where they occur.
/** Cosine and exponential easing, from `love2d/src/ease.lua`. `t` is 0..1. */

export function clamp(t: number, a: number, b: number): number {
  return t < a ? a : t > b ? b : t;
}

export function cosine(t: number): number {
  return (1 - Math.cos(clamp(t, 0, 1) * Math.PI)) * 0.5;
}

export function expOut(t: number): number {
  t = clamp(t, 0, 1);
  return t >= 1 ? 1 : 1 - Math.pow(2, -10 * t);
}

export function expIn(t: number): number {
  t = clamp(t, 0, 1);
  return t === 0 ? 0 : Math.pow(2, 10 * (t - 1));
}

export function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

/**
 * Frame-rate independent exponential smoothing. The point of the `exp` is that
 * two frames of `dt` land where one frame of twice `dt` does, so the camera
 * does not drift with the refresh rate.
 */
export function smooth(current: number, target: number, dt: number, speed: number): number {
  return current + (target - current) * (1 - Math.exp(-speed * dt));
}

// ---------------------------------------------------------------------------
// Causewaybay Hacker additions.
//
// The house curve for this game is exponential, in and out. Its character is
// that it is almost still, then very fast, then almost still — which is what
// makes a panel feel thrown rather than dragged, and why it wants a longer
// duration than a cubic would: about 0.5 s to read as deliberate instead of
// abrupt, where a cubic would be fine at 0.3 s. All the durations in
// `engine/motion.ts` are tuned against these two functions and nothing else.
// ---------------------------------------------------------------------------

/** `easeInOutExpo`. For anything that starts somewhere and ends somewhere. */
export function expInOut(t: number): number {
  t = clamp(t, 0, 1);
  if (t === 0) return 0;
  if (t === 1) return 1;
  return t < 0.5 ? Math.pow(2, 20 * t - 10) * 0.5 : (2 - Math.pow(2, -20 * t + 10)) * 0.5;
}

/**
 * `easeOutExpo`. For anything that only *arrives* — a panel sliding in, a
 * stamp landing, a star appearing. Starting at full speed and settling is what
 * makes an arrival feel like it was already on its way.
 */
export const easeOutExpo = expOut;
export const easeInOutExpo = expInOut;
