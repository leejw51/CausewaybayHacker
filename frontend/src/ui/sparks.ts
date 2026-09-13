/**
 * A spark layer that sits *over* the DOM editor.
 *
 * The game has two canvases and both of them are underneath `#overlay`
 * (`index.html` says so in as many words), and the editor's own face is 96%
 * opaque — so an effect thrown at the caret and painted on the game canvas is
 * an effect nobody sees. ANSWER mode's whole point is to put something where
 * the mistake is, so this is a third, transparent canvas, added *inside* the
 * overlay after the editor and therefore painted on top of it.
 *
 * It takes the same virtual coordinates the rest of the game draws in, and
 * sets the same transform `Layout.begin` does, so a burst asked for at a point
 * in the scene lands on that point. It never takes a pointer event — it is
 * decoration over something a person is typing into, and a decoration that
 * swallowed a click would be a bug in the editor.
 */
import { cosine, expOut } from "../engine/ease";
import type { Plan } from "../engine/burst";
import type { Layout } from "../engine/layout";
import { css } from "../engine/theme";

export class Sparks {
  private readonly canvas = document.createElement("canvas");
  private readonly g: CanvasRenderingContext2D | null;
  /** Bursts, with the scene clock reading at which each was thrown. */
  private live: Array<{ plan: Plan; born: number }> = [];

  constructor(
    host: HTMLElement,
    private readonly layout: Layout,
  ) {
    this.canvas.className = "cwb-sparks";
    this.g = this.canvas.getContext("2d");
    host.appendChild(this.canvas);
  }

  /** Throw one. `now` is the scene's clock, in seconds. */
  add(plan: Plan, now: number): void {
    this.live.push({ plan, born: now });
    // A cap rather than a queue: a player typing fast can ask for one a
    // keystroke, and what matters is the last few.
    if (this.live.length > 8) this.live.shift();
  }

  clear(): void {
    this.live.length = 0;
    this.paintNothing();
  }

  /**
   * Paint whatever is still alive at `now`.
   *
   * The path is closed-form — position is a function of age, exactly as the
   * result screen's confetti — so it looks the same at 60 Hz and at 144 Hz
   * and nothing is integrated between frames.
   */
  draw(now: number): void {
    const g = this.g;
    if (!g) return;
    if (this.live.length === 0) return;
    const { dw, dh, scale, ox, oy } = this.layout;
    if (this.canvas.width !== dw || this.canvas.height !== dh) {
      this.canvas.width = dw;
      this.canvas.height = dh;
    }
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, dw, dh);
    g.setTransform(scale, 0, 0, scale, ox, oy);

    let alive = false;
    for (const { plan, born } of this.live) {
      const t = now - born;
      for (const r of plan.rings) {
        const age = t - r.delay;
        if (age < 0 || age > r.life) continue;
        alive = true;
        const u = age / r.life;
        g.globalAlpha = (1 - u) * (r.glow ? 0.3 : 0.7);
        g.strokeStyle = css(r.color);
        g.lineWidth = Math.max(1, r.radius * 0.06 * (1 - u));
        g.beginPath();
        g.arc(r.x, r.y, r.radius * expOut(u), 0, Math.PI * 2);
        g.stroke();
      }
      g.globalAlpha = 1;
      g.lineWidth = 1;
      for (const p of plan.particles) {
        const age = t - p.delay;
        if (age < 0 || age > p.life) continue;
        alive = true;
        const u = age / p.life;
        const out = expOut(u);
        const leg = cosine(u);
        const lift = Math.sin(Math.PI * u);
        const x = p.x + p.dx * out + p.tox * leg + p.liftx * lift;
        const y = p.y + p.dy * out + p.toy * leg + p.lifty * lift + 0.5 * p.gravity * age * age;
        g.globalAlpha = Math.max(0, 1 - u * u);
        g.fillStyle = css(p.color, 1);
        g.fillRect(x - p.size / 2, y - p.size / 2, p.size, p.size);
      }
      g.globalAlpha = 1;
    }
    if (!alive) {
      this.live.length = 0;
      this.paintNothing();
    }
  }

  private paintNothing(): void {
    const g = this.g;
    if (!g) return;
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, this.canvas.width, this.canvas.height);
  }

  destroy(): void {
    this.canvas.remove();
  }
}
