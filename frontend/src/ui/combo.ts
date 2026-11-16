/**
 * The typing combo: every keystroke that comes within `WINDOW` seconds of the
 * last one adds to it; a pause longer than that drains it. Crossing a
 * milestone is the event the scene celebrates — a fountain of stars, a
 * badge that bumps — and a combo of `FEVER_AT` or more puts the screen's edge
 * on fire (`PlayFx.setFever`).
 *
 * Pure: no DOM, no clock of its own. The scene feeds it `hit(now)` and
 * `tick(now)`, so a unit test can type at it.
 */
export const COMBO_WINDOW = 1.6;
export const COMBO_MILESTONES = [10, 25, 50, 100, 200] as const;
export const FEVER_AT = 50;

export class Combo {
  count = 0;
  best = 0;
  private last = -Infinity;

  /**
   * One keystroke at `now` (seconds). Returns the milestone just crossed,
   * or 0.
   */
  hit(now: number): number {
    if (now - this.last > COMBO_WINDOW) this.count = 0;
    this.last = now;
    const before = this.count;
    this.count++;
    this.best = Math.max(this.best, this.count);
    for (const m of COMBO_MILESTONES) if (before < m && this.count >= m) return m;
    return 0;
  }

  /** Let the combo lapse once the window has passed. Returns true if it just did. */
  tick(now: number): boolean {
    if (this.count > 0 && now - this.last > COMBO_WINDOW) {
      this.count = 0;
      return true;
    }
    return false;
  }

  /** How much of the window is left, 1 just after a key and 0 when it lapses. */
  left(now: number): number {
    if (this.count === 0) return 0;
    return Math.max(0, 1 - (now - this.last) / COMBO_WINDOW);
  }

  /** 0 below FEVER, rising to 1 at twice FEVER. */
  fever(): number {
    if (this.count < FEVER_AT) return 0;
    return Math.min(1, 0.5 + (this.count - FEVER_AT) / (FEVER_AT * 2));
  }

  /** Which of the milestones' tiers the combo is in: 0 none, 1.. upward. */
  tier(): number {
    let t = 0;
    for (const m of COMBO_MILESTONES) if (this.count >= m) t++;
    return t;
  }
}
