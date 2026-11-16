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

/**
 * Three cosine waves flowing across `w` at their own speeds, tapering to
 * nothing at both ends, on a neon gradient with a glow — and a bright pulse
 * riding the main one from left to right.
 */
export function waveLine(
  g: Ctx,
  x: number,
  midY: number,
  w: number,
  t: number,
  _col: RGBA,
  s: number,
): void {
  const amp = 8 * s;
  const step = Math.max(2, 3 * s);
  const grad = g.createLinearGradient(x, 0, x + w, 0);
  grad.addColorStop(0, css(CYAN));
  grad.addColorStop(0.5, css(VIOLET));
  grad.addColorStop(1, css(PINK));
  const phase = (t / PERIOD) * Math.PI * 2;
  const yAt = (dx: number, len: number, speed: number, shift: number, a: number) => {
    const env = Math.sin((dx / w) * Math.PI);
    return midY + Math.cos((dx / len) * Math.PI * 2 - phase * speed + shift) * a * env;
  };
  const layer = (
    len: number,
    speed: number,
    shift: number,
    a: number,
    alpha: number,
    lw: number,
    glow: number,
  ) => {
    g.globalAlpha = alpha;
    g.strokeStyle = grad;
    g.lineWidth = lw;
    g.shadowColor = css(VIOLET, 0.8);
    g.shadowBlur = glow;
    g.beginPath();
    for (let dx = 0; dx <= w; dx += step) {
      const y = yAt(dx, len, speed, shift, a);
      if (dx === 0) g.moveTo(x + dx, y);
      else g.lineTo(x + dx, y);
    }
    g.stroke();
  };
  g.save();
  g.lineCap = "round";
  g.lineJoin = "round";
  layer(170 * s, 0.6, 2.1, amp * 0.5, 0.22, Math.max(1, 1.2 * s), 0);
  layer(90 * s, 1.4, 1.0, amp * 0.65, 0.35, Math.max(1, 1.4 * s), 0);
  layer(125 * s, 1, 0, amp, 0.95, Math.max(1, 2.2 * s), 12 * s);

  // The pulse: a bright bead on the main wave, crossing it once a cycle and
  // a half, its brightness eased in and out at the ends by the same taper.
  const u = (((t / (PERIOD * 1.6)) % 1) + 1) % 1;
  const px = u * w;
  const py = yAt(px, 125 * s, 1, 0, amp);
  const fade = Math.sin(u * Math.PI);
  const col = ramp(u);
  g.globalAlpha = fade;
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
