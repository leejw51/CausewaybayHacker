import { animate } from "motion";

/**
 * A canvas menu's appearance, 0 (gone) to 1 (open), tweened by motion.dev
 * the way iOS opens and closes a menu: an exponential ease-out on the way in
 * (fast, then settling), a short exponential ease-in on the way out.
 *
 * The menu is drawn on the canvas every frame, so there is no element for
 * motion to animate; it tweens a number and the scene draws from it. Call
 * `follow` once a frame with whether the menu should be open.
 */
export const EXPO_OUT = [0.16, 1, 0.3, 1] as const;
export const EXPO_IN = [0.7, 0, 0.84, 0] as const;

export class MenuFx {
  value = 0;
  private target = false;
  private ctl: { stop(): void } | null = null;

  follow(open: boolean): number {
    if (open === this.target) return this.value;
    this.target = open;
    this.ctl?.stop();
    this.ctl = null;
    if (reducedMotion()) {
      this.value = open ? 1 : 0;
      return this.value;
    }
    this.ctl = animate(this.value, open ? 1 : 0, {
      duration: open ? 0.42 : 0.2,
      ease: open ? [...EXPO_OUT] : [...EXPO_IN],
      onUpdate: (v: number) => {
        this.value = v;
      },
      onComplete: () => {
        this.ctl = null;
      },
    });
    return this.value;
  }

  /** On screen at all: open, or still fading out. */
  get shown(): boolean {
    return this.target || this.value > 0.002;
  }

  /** Gone at once, no tween: the screen the menu was on is not this one. */
  reset(): void {
    this.ctl?.stop();
    this.ctl = null;
    this.target = false;
    this.value = 0;
  }
}

/**
 * One item's share of the menu's progress `p`: the items arrive one after
 * another (a short stagger down the list), and each is fully in at p = 1.
 */
export function staggered(p: number, i: number): number {
  const d = Math.min(0.3, i * 0.014);
  return Math.max(0, Math.min(1, (p - d) / (1 - d)));
}

function reducedMotion(): boolean {
  try {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  } catch {
    return false;
  }
}
