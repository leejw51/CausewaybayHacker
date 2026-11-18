import { animate } from "motion";
import { EXPO_IN, EXPO_OUT } from "./menufx";

/**
 * Two small motion.dev pieces for CONSOLE, both on real DOM elements (so
 * they sit over the editor, which a canvas drawing cannot):
 *
 *   * `veiled` — a change of screen behind a dark veil: the veil comes up on
 *     an exponential ease-in, the screen changes under it, and it lifts on
 *     an exponential ease-out. Whatever swaps in that one frame (the editor
 *     moving, the monitor's tube changing) is never seen: no blink.
 *   * `ScorePop` — a game's score: "+1 HP" pops up gold, overshoots, rises
 *     and fades; "-1 HP" lands red, shudders and sinks.
 */

let veiling = false;

function reduced(): boolean {
  try {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  } catch {
    return false;
  }
}

/**
 * `p`, or nothing after `ms`: whichever comes first. A rejection counts as
 * done — the caller only needs to know it may go on.
 */
function settle(p: unknown, ms: number): Promise<void> {
  return Promise.race([
    Promise.resolve(p).then(
      () => undefined,
      () => undefined,
    ),
    new Promise<void>((r) => setTimeout(r, ms)),
  ]);
}

/**
 * Run `change` behind a veil over `host`. A second call while one runs just
 * changes.
 *
 * **The veil always lifts.** Every wait is bounded: the fades, the frames,
 * and `change` itself (`limitMs`). Opened from the iPad home screen, CONSOLE
 * came up as a black screen — the veil was up and one of those waits never
 * came back (a font that never arrived, an animation that never reported
 * it was done), so it never lifted. Now the screen is shown after the limit
 * whatever is still pending; a change that finishes later still lands.
 */
export async function veiled(
  host: HTMLElement,
  change: () => unknown,
  limitMs = 3000,
): Promise<void> {
  if (veiling || reduced()) {
    await change();
    return;
  }
  veiling = true;
  const el = document.createElement("div");
  el.className = "cwb-veil";
  el.style.opacity = "0";
  host.appendChild(el);
  try {
    await settle(animate(el, { opacity: [0, 1] }, { duration: 0.18, ease: [...EXPO_IN] }), 500);
    await settle(change(), limitMs);
    // Two frames for the new screen to lay itself out under the veil.
    await settle(new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))), 200);
    await settle(animate(el, { opacity: [1, 0] }, { duration: 0.34, ease: [...EXPO_OUT] }), 700);
  } finally {
    el.remove();
    veiling = false;
  }
}

export class ScorePop {
  constructor(private readonly host: HTMLElement) {}

  /** At client px (x, y): `gain` true for "+N HP", false for "-N HP". */
  pop(x: number, y: number, gain: boolean, n = 1, note = ""): void {
    const el = document.createElement("div");
    el.className = `cwb-score ${gain ? "cwb-score-up" : "cwb-score-down"}`;
    el.style.left = `${x}px`;
    el.style.top = `${y}px`;
    // The outer box is centred on the point by CSS; motion.dev drives the
    // inner one's transform, which would otherwise overwrite the centring.
    const inner = document.createElement("div");
    inner.className = "cwb-score-in";
    const big = document.createElement("span");
    big.className = "cwb-score-n";
    big.textContent = `${gain ? "+" : "−"}${n} HP`;
    inner.appendChild(big);
    if (note) {
      const small = document.createElement("span");
      small.className = "cwb-score-note";
      small.textContent = note;
      inner.appendChild(small);
    }
    el.appendChild(inner);
    this.host.appendChild(el);
    const done = () => el.remove();
    if (reduced()) {
      void animate(
        inner,
        { opacity: [0, 1, 1, 0] },
        { duration: 1.4, times: [0, 0.1, 0.75, 1] },
      ).then(done);
      return;
    }
    if (gain) {
      // Pops in past its size, settles, rises and fades: a coin collected.
      void animate(
        inner,
        {
          opacity: [0, 1, 1, 0],
          scale: [0.4, 1.22, 1, 0.94],
          y: [18, -8, -26, -70],
        },
        { duration: 1.6, times: [0, 0.16, 0.62, 1], ease: [...EXPO_OUT] },
      ).then(done);
    } else {
      // Lands hard, shudders, and sinks away.
      void animate(
        inner,
        {
          opacity: [0, 1, 1, 0],
          scale: [1.35, 1, 1, 0.96],
          x: [0, -9, 8, -6, 4, -2, 0, 0],
          y: [-14, 0, 0, 0, 0, 0, 8, 46],
        },
        { duration: 1.6, ease: [...EXPO_IN] },
      ).then(done);
    }
  }

  destroy(): void {
    for (const el of Array.from(this.host.querySelectorAll(".cwb-score"))) el.remove();
  }
}
