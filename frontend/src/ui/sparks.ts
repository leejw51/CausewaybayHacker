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
import { pathPoint, type Plan, type Smear } from "../engine/burst";
import type { Layout } from "../engine/layout";
import { css } from "../engine/theme";

export class Sparks {
  private readonly canvas = document.createElement("canvas");
  private readonly g: CanvasRenderingContext2D | null;
  /** Bursts, with the scene clock reading at which each was thrown. */
  private live: Array<{ plan: Plan; born: number }> = [];
  /** Caret smears, the same way. */
  private smears: Array<{ smear: Smear; born: number }> = [];

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

  /** The caret moved: its smear, as a stroked path that shortens from the tail. */
  smear(s: Smear, now: number): void {
    this.smears.push({ smear: s, born: now });
    if (this.smears.length > 6) this.smears.shift();
  }

  clear(): void {
    this.live.length = 0;
    this.smears.length = 0;
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
    if (this.live.length === 0 && this.smears.length === 0) return;
    const { dw, dh, scale, ox, oy } = this.layout;
    if (this.canvas.width !== dw || this.canvas.height !== dh) {
      this.canvas.width = dw;
      this.canvas.height = dh;
    }
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, dw, dh);
    g.setTransform(scale, 0, 0, scale, ox, oy);

    let alive = false;
    for (const { smear, born } of this.smears) {
      const k = (now - born) / smear.life;
      if (k < 0 || k >= 1) continue;
      alive = true;
      // The same shape as the GPU's: the head across almost at once, the
      // tail on a slow start, width and alpha dying together.
      const head = expOut(Math.min(1, k / 0.45));
      const tail = k * k * (3 - 2 * k);
      if (head <= tail) continue;
      const piece = (from: number, to: number): [number, number][] => {
        const pts: [number, number][] = [pathPoint(smear.path, from)];
        if (smear.path.length === 3) {
          const [ax, ay] = smear.path[0];
          const [cx, cy] = smear.path[1];
          const [bx, by] = smear.path[2];
          const first = Math.hypot(cx - ax, cy - ay);
          const corner = first / (first + Math.hypot(bx - cx, by - cy));
          if (corner > from && corner < to) pts.push([cx, cy]);
        }
        pts.push(pathPoint(smear.path, to));
        return pts;
      };
      const pts = piece(tail, head);
      const stroke = (width: number, colour: string, alpha: number) => {
        g.globalAlpha = alpha;
        g.strokeStyle = colour;
        g.lineWidth = Math.max(1, width);
        g.lineCap = "butt";
        g.lineJoin = "miter";
        g.beginPath();
        g.moveTo(pts[0][0], pts[0][1]);
        for (let i = 1; i < pts.length; i++) g.lineTo(pts[i][0], pts[i][1]);
        g.stroke();
      };
      const fade = 1 - k * k;
      stroke(smear.width * (1 - 0.8 * k * k), css(smear.color), 0.45 * fade);
      stroke(Math.max(1, smear.width * 0.12), "#ffffff", smear.core * 0.8 * fade);
      g.globalAlpha = 1;
    }
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
        // A grain is a flat streak, not a square.
        const h = p.shape === 7 ? p.size * 0.2 : p.size;
        g.fillRect(x - p.size / 2, y - h / 2, p.size, h);
      }
      g.globalAlpha = 1;
    }
    if (!alive) {
      this.live.length = 0;
      this.smears.length = 0;
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
