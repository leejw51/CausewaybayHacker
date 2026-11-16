/**
 * CONSOLE's compile and run, in particles (three.js) — the Claude Design
 * "Console Compile FX" canvas, built:
 *
 *   * compiling — motes drift out of the code and spiral into a core low on
 *     the monitor, the spin quickening as they near it (a vortex), cyan
 *     going violet; the core brightens as it is fed;
 *   * running — the core breathes on a cosine and the motes orbit it in a
 *     wobbling ring, with a shock ring going out every 0.9 s;
 *   * a clean run — everything bursts outward green and gold, drags to a
 *     halt and fades, behind a bright ring;
 *   * a failed one — red embers slump and fall, and the screen's edge warms
 *     red and cools again (slowly, smoothly: nothing flickers).
 *
 * Points with additive blending and a soft round sprite, each with a short
 * trail of its own last positions; the core, the rings and the red edge are
 * one full-screen fragment shader. All of it is clipped to the monitor's
 * screen, adds light only, and draws nothing once it has died down.
 */
import {
  AdditiveBlending,
  BufferAttribute,
  BufferGeometry,
  Mesh,
  OrthographicCamera,
  PlaneGeometry,
  Points,
  Scene,
  ShaderMaterial,
  Vector2,
  Vector4,
  WebGLRenderer,
} from "three";
import type { Layout } from "../engine/layout";
import { reducedMotion } from "../engine/motion";
import type { Rect } from "../engine/ui";

type Mode = "in" | "orbit" | "spark" | "ember";
type Rgb = readonly [number, number, number];

interface Mote {
  mode: Mode;
  x: number;
  y: number;
  /** The last positions, newest first: the trail. */
  hx: number[];
  hy: number[];
  r: number;
  r0: number;
  a: number;
  vx: number;
  vy: number;
  age: number;
  life: number;
  size: number;
  seed: number;
  lane: number;
  col: Rgb;
}

const MAX = 1800;
const TRAIL = 3;
const PER = TRAIL + 1;
const PERIOD = 1.15;

const CYAN: Rgb = [0.3, 0.9, 1];
const VIOLET: Rgb = [0.59, 0.47, 1];
const PINK: Rgb = [1, 0.38, 0.72];
// Gold and white first: a green spark is lost on a green tube.
const SPARKS: Rgb[] = [
  [1, 0.86, 0.38],
  [1, 0.95, 0.75],
  [0.55, 1, 0.75],
  [1, 0.72, 0.3],
  [0.45, 0.92, 1],
];
const EMBERS: Rgb[] = [
  [1, 0.31, 0.2],
  [1, 0.55, 0.24],
  [1, 0.24, 0.35],
];

function ramp(u: number): Rgb {
  const k = Math.max(0, Math.min(1, u));
  const [a, b, f] = k < 0.5 ? [CYAN, VIOLET, k * 2] : [VIOLET, PINK, (k - 0.5) * 2];
  return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f];
}
const pick = (xs: Rgb[]): Rgb => xs[Math.floor(Math.random() * xs.length)];

const POINT_VERT = /* glsl */ `
attribute float aSize;
attribute vec4 aTint;
varying vec4 vTint;
void main() {
  vTint = aTint;
  gl_PointSize = aSize;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}
`;
const POINT_FRAG = /* glsl */ `
precision highp float;
varying vec4 vTint;
void main() {
  float d = length(gl_PointCoord - 0.5) * 2.0;
  float k = smoothstep(1.0, 0.0, d);
  float hot = k * k * k;
  k = k * k * vTint.a;
  // A white-hot centre in a coloured halo.
  vec3 c = mix(vTint.rgb, vec3(1.0), hot * 0.6);
  gl_FragColor = vec4(c * k * 1.9, k * 0.35);
}
`;

const QUAD_VERT = /* glsl */ `
void main() { gl_Position = vec4(position.xy, 0.0, 1.0); }
`;
const QUAD_FRAG = /* glsl */ `
precision highp float;
uniform vec4 uRect;      // the screen, device px, y up: x0 y0 x1 y1
uniform vec2 uCore;      // device px, y up
uniform float uEnergy;   // 0..1
uniform float uBeat;     // 0..1, a cosine
uniform float uScale;
uniform vec4 uRings;     // four rings' progress 0..1, < 0 = none
uniform vec4 uRingKind;  // 0 violet (run), 1 green (clear), 2 red (fail)
uniform float uRed;      // 0..1, the failed run's edge
vec3 ringCol(float k) {
  return k < 0.5 ? vec3(0.55, 0.51, 1.0) : k < 1.5 ? vec3(0.47, 1.0, 0.7) : vec3(1.0, 0.31, 0.24);
}
float ring(vec2 p, float u, float reach) {
  if (u < 0.0) return 0.0;
  float ease = 1.0 - pow(2.0, -10.0 * u);
  float R = 20.0 * uScale + ease * reach;
  vec2 q = (p - uCore) / vec2(1.0, 0.62);
  float w = (3.0 * (1.0 - u) + 0.8) * uScale;
  return exp(-pow((length(q) - R) / (w * 1.5), 2.0)) * (1.0 - u) * 0.95;
}
void main() {
  vec2 p = gl_FragCoord.xy;
  vec3 col = vec3(0.0);
  vec2 size = uRect.zw - uRect.xy;
  float reach = min(size.x, size.y) * 0.42;
  if (uEnergy > 0.001) {
    float rad = (14.0 + 26.0 * uEnergy + 10.0 * uBeat * uEnergy) * uScale;
    float d = length(p - uCore) / (rad * 3.2);
    col += vec3(1.0) * exp(-d * d * 22.0) * (0.55 + 0.35 * uEnergy);
    col += vec3(0.59, 0.55, 1.0) * exp(-d * d * 6.0) * 0.45 * (0.4 + uEnergy);
    col += vec3(0.3, 0.9, 1.0) * exp(-d * d * 1.6) * 0.16 * (0.4 + uEnergy);
  }
  col += ringCol(uRingKind.x) * ring(p, uRings.x, reach);
  col += ringCol(uRingKind.y) * ring(p, uRings.y, reach);
  col += ringCol(uRingKind.z) * ring(p, uRings.z, reach);
  col += ringCol(uRingKind.w) * ring(p, uRings.w, reach);
  if (uRed > 0.001) {
    vec2 c = (uRect.xy + uRect.zw) * 0.5;
    vec2 e = abs(p - c) / (size * 0.5);
    float edge = smoothstep(0.55, 1.0, max(e.x, e.y));
    col += vec3(1.0, 0.16, 0.16) * edge * 0.35 * uRed;
  }
  col *= 1.5;
  gl_FragColor = vec4(col, max(col.r, max(col.g, col.b)) * 0.2);
}
`;

export class CompileFx {
  private readonly canvas = document.createElement("canvas");
  private renderer: WebGLRenderer | null = null;
  private readonly scene = new Scene();
  private readonly camera = new OrthographicCamera(0, 1, 1, 0, -1, 1);
  private readonly geo = new BufferGeometry();
  private readonly pos = new Float32Array(MAX * PER * 3);
  private readonly size = new Float32Array(MAX * PER);
  private readonly tint = new Float32Array(MAX * PER * 4);
  private readonly pointMat: ShaderMaterial;
  private readonly quadMat: ShaderMaterial;
  private motes: Mote[] = [];
  private rings: Array<{ age: number; life: number; kind: number }> = [];
  private t = 0;
  private stageT = 0;
  private energy = 0;
  private red = 0;
  private busy = false;
  private running = false;
  private drew = false;
  private gone = 0;
  private lastScreen: Rect | null = null;

  constructor(
    host: HTMLElement,
    private readonly layout: Layout,
  ) {
    this.canvas.className = "cwb-sparks cwb-playfx";
    this.geo.setAttribute("position", new BufferAttribute(this.pos, 3));
    this.geo.setAttribute("aSize", new BufferAttribute(this.size, 1));
    this.geo.setAttribute("aTint", new BufferAttribute(this.tint, 4));
    this.pointMat = new ShaderMaterial({
      vertexShader: POINT_VERT,
      fragmentShader: POINT_FRAG,
      blending: AdditiveBlending,
      transparent: true,
      depthTest: false,
      depthWrite: false,
    });
    this.quadMat = new ShaderMaterial({
      vertexShader: QUAD_VERT,
      fragmentShader: QUAD_FRAG,
      blending: AdditiveBlending,
      transparent: true,
      depthTest: false,
      depthWrite: false,
      uniforms: {
        uRect: { value: new Vector4() },
        uCore: { value: new Vector2() },
        uEnergy: { value: 0 },
        uBeat: { value: 0 },
        uScale: { value: 1 },
        uRings: { value: new Vector4(-1, -1, -1, -1) },
        uRingKind: { value: new Vector4() },
        uRed: { value: 0 },
      },
    });
    try {
      this.renderer = new WebGLRenderer({
        canvas: this.canvas,
        alpha: true,
        premultipliedAlpha: true,
        antialias: false,
        powerPreference: "low-power",
      });
      this.renderer.setClearColor(0x000000, 0);
    } catch {
      this.renderer = null;
      return;
    }
    const quad = new Mesh(new PlaneGeometry(2, 2), this.quadMat);
    quad.frustumCulled = false;
    const points = new Points(this.geo, this.pointMat);
    points.frustumCulled = false;
    this.scene.add(quad, points);
    host.appendChild(this.canvas);
    this.canvas.addEventListener("webglcontextlost", (ev) => ev.preventDefault());
  }

  /**
   * One frame. `screen`: the monitor's glass in virtual px, or null when
   * CONSOLE is not up (everything is dropped). `busy`: a compile or run is
   * out; `running`: it has got as far as running. `outcome` names how the
   * last run ended, the frame it ends.
   */
  frame(
    dt: number,
    screen: Rect | null,
    busy: boolean,
    running: boolean,
    outcome: "ok" | "bad" | null,
  ): void {
    if (!this.renderer) return;
    if (screen) {
      this.gone = 0;
      this.lastScreen = screen;
    } else this.gone += dt;
    // A frame or two without CONSOLE (a popup drawn instead, a celebration)
    // is not CONSOLE gone: keep going on its last glass. Gone a while, drop
    // everything.
    if (!screen && this.gone < 0.3 && this.lastScreen) screen = this.lastScreen;
    if (!screen) {
      this.lastScreen = null;
      this.motes = [];
      this.rings = [];
      this.energy = 0;
      this.red = 0;
      this.busy = false;
      if (this.drew) {
        this.renderer.clear();
        this.drew = false;
      }
      return;
    }
    const { ox, oy, scale, dw, dh } = this.layout;
    const d = scale;
    const sx = ox + screen[0] * scale;
    const sy = oy + screen[1] * scale;
    const sw = screen[2] * scale;
    const sh = screen[3] * scale;
    const cx = sx + sw * 0.5;
    const cy = sy + sh * 0.56;
    const calm = reducedMotion() ? 0.3 : 1;

    this.t += dt;
    this.stageT += dt;
    if (running !== this.running) {
      this.running = running;
      this.stageT = 0;
    }
    // A compile starting: a first wave out of the code at once, so even a
    // compile that is over in a blink shows its vortex.
    if (!this.busy && busy) {
      for (let i = 0; i < 140 * calm && this.motes.length < MAX; i++) {
        const x = sx + sw * (0.04 + Math.random() * 0.75);
        const y = sy + sh * (0.04 + Math.random() * 0.5);
        const r = Math.hypot(x - cx, y - cy);
        this.motes.push(this.mote("in", x, y, r, Math.atan2(y - cy, x - cx), d));
      }
    }
    if (this.busy && !busy && outcome) this.settle(outcome === "bad", cx, cy);
    this.busy = busy;
    const beat = (1 - Math.cos((this.t / PERIOD) * Math.PI * 2)) / 2;

    // Spawn.
    if (busy && !running) {
      const n = Math.round(6 * calm);
      for (let i = 0; i < n && this.motes.length < MAX; i++) {
        const x = sx + sw * (0.06 + Math.random() * 0.6);
        const y = sy + sh * (0.05 + Math.random() * 0.45);
        const r = Math.hypot(x - cx, y - cy);
        this.motes.push(this.mote("in", x, y, r, Math.atan2(y - cy, x - cx), d));
      }
    } else if (busy && running) {
      const orbiting = this.motes.reduce((n, m) => n + (m.mode === "orbit" ? 1 : 0), 0);
      for (let i = 0; i < 4 && orbiting + i < 240 * calm && this.motes.length < MAX; i++) {
        const m = this.mote("orbit", cx, cy, 0, Math.random() * Math.PI * 2, d);
        m.lane = 0.7 + Math.random() * 0.6;
        this.motes.push(m);
      }
    }

    // Move.
    const keep: Mote[] = [];
    for (const m of this.motes) {
      m.age += dt;
      m.hx.unshift(m.x);
      m.hy.unshift(m.y);
      m.hx.length = Math.min(m.hx.length, TRAIL);
      m.hy.length = Math.min(m.hy.length, TRAIL);
      if (m.mode === "in") {
        m.r *= Math.exp(-dt * 1.35);
        m.r -= dt * 40 * d;
        m.a += dt * (1.6 + (90 * d) / Math.max(8 * d, m.r));
        m.x = cx + Math.cos(m.a) * m.r;
        m.y = cy + Math.sin(m.a) * m.r * 0.72;
        if (m.r < 6 * d) {
          this.energy = Math.min(1, this.energy + 0.004);
          continue;
        }
        if (!busy) this.scatter(m, cx, cy, false);
      } else if (m.mode === "orbit") {
        m.r += (70 * d * m.lane - m.r) * Math.min(1, dt * 3);
        m.a += dt * (2.2 / m.lane);
        const wob = Math.cos(m.a * 3 + this.t * 2 + m.seed) * 8 * d;
        m.x = cx + Math.cos(m.a) * (m.r + wob);
        m.y = cy + Math.sin(m.a) * (m.r + wob) * 0.6;
        if (!busy || !running) this.scatter(m, cx, cy, false);
      } else {
        const ember = m.mode === "ember";
        const drag = Math.exp(-dt * (ember ? 1.2 : 1.9));
        m.vx *= drag;
        m.vy *= drag;
        m.vy += dt * (ember ? 420 : 90) * d;
        if (ember) m.vx += Math.cos(this.t * 3 + m.seed) * 30 * d * dt;
        m.x += m.vx * dt;
        m.y += m.vy * dt;
        if (m.age >= m.life) continue;
      }
      keep.push(m);
    }
    this.motes = keep;

    // The core and the red edge.
    if (busy) this.energy = running ? Math.min(1, this.energy + dt * 2) : this.energy;
    else this.energy = Math.max(0, this.energy - dt * 1.5);
    this.red = Math.max(0, this.red - dt * 0.35);
    this.rings = this.rings.filter((r) => (r.age += dt) < r.life);

    const live =
      this.motes.length > 0 || this.energy > 0.001 || this.rings.length > 0 || this.red > 0.001;
    if (!live) {
      if (this.drew) {
        this.renderer.clear();
        this.drew = false;
      }
      return;
    }

    // Fill the buffers: each mote and its trail, y flipped to GL's up.
    let n = 0;
    for (const m of this.motes) {
      const [r, g, b, a] = this.look(m, busy, running);
      const pts = [[m.x, m.y], ...m.hx.map((x, i) => [x, m.hy[i]])];
      pts.forEach(([x, y], i) => {
        if (n >= MAX * PER) return;
        const fade = i === 0 ? 1 : 0.5 / i;
        this.pos[n * 3] = x;
        this.pos[n * 3 + 1] = dh - y;
        this.pos[n * 3 + 2] = 0;
        this.size[n] = m.size * (i === 0 ? 6.5 : 4.5);
        this.tint[n * 4] = r;
        this.tint[n * 4 + 1] = g;
        this.tint[n * 4 + 2] = b;
        this.tint[n * 4 + 3] = a * fade * calm;
        n++;
      });
    }
    this.geo.setDrawRange(0, n);
    (this.geo.getAttribute("position") as BufferAttribute).needsUpdate = true;
    (this.geo.getAttribute("aSize") as BufferAttribute).needsUpdate = true;
    (this.geo.getAttribute("aTint") as BufferAttribute).needsUpdate = true;

    const u = this.quadMat.uniforms;
    (u.uRect.value as Vector4).set(sx, dh - (sy + sh), sx + sw, dh - sy);
    (u.uCore.value as Vector2).set(cx, dh - cy);
    u.uEnergy.value = this.energy * calm;
    u.uBeat.value = running ? beat : 0;
    u.uScale.value = d;
    u.uRed.value = this.red * (0.65 + 0.35 * beat) * calm;
    const rings = u.uRings.value as Vector4;
    const kinds = u.uRingKind.value as Vector4;
    rings.set(-1, -1, -1, -1);
    this.rings.slice(-4).forEach((r, i) => {
      rings.setComponent(i, r.age / r.life);
      kinds.setComponent(i, r.kind);
    });

    if (this.canvas.width !== dw || this.canvas.height !== dh) this.renderer.setSize(dw, dh, false);
    this.camera.left = 0;
    this.camera.right = dw;
    this.camera.top = dh;
    this.camera.bottom = 0;
    this.camera.updateProjectionMatrix();
    this.renderer.setScissorTest(false);
    this.renderer.clear();
    this.renderer.setScissor(sx, dh - (sy + sh), sw, sh);
    this.renderer.setScissorTest(true);
    this.renderer.render(this.scene, this.camera);
    this.renderer.setScissorTest(false);
    this.drew = true;
  }

  private mote(mode: Mode, x: number, y: number, r: number, a: number, d: number): Mote {
    return {
      mode,
      x,
      y,
      hx: [],
      hy: [],
      r,
      r0: Math.max(1, r),
      a,
      vx: 0,
      vy: 0,
      age: 0,
      life: 1,
      size: (0.8 + Math.random() * 1.6) * d,
      seed: Math.random() * Math.PI * 2,
      lane: 1,
      col: CYAN,
    };
  }

  /** A mote let go: it flies off and fades as a spark (or falls as an ember). */
  private scatter(m: Mote, cx: number, cy: number, bad: boolean): void {
    m.mode = bad ? "ember" : "spark";
    // Let go gently: drifting off, not thrown.
    m.vx = (m.x - cx) * (bad ? 0.5 : 0.8);
    m.vy = (m.y - cy) * (bad ? 0.5 : 0.8);
    m.age = 0;
    m.life = 1.2 + Math.random() * 0.8;
    m.col = pick(bad ? EMBERS : SPARKS);
  }

  /**
   * The run is over: no big bang, no burst, no ring — the motes let go and
   * drift off fading, and the score says the rest. A failure leaves a
   * faint red at the glass's edge, a hint and not an alarm.
   */
  private settle(bad: boolean, cx: number, cy: number): void {
    for (const m of this.motes) this.scatter(m, cx, cy, bad);
    if (bad) this.red = 0.5;
  }

  private look(m: Mote, busy: boolean, running: boolean): [number, number, number, number] {
    if (m.mode === "in") {
      const u = 1 - m.r / m.r0;
      const [r, g, b] = ramp(u);
      return [r, g, b, Math.min(1, m.age * 3) * (0.55 + 0.45 * u)];
    }
    if (m.mode === "orbit") {
      const [r, g, b] = ramp(0.5 + 0.5 * Math.cos(m.a + this.t));
      return [r, g, b, Math.min(1, m.age * 2) * 0.85 * (busy && running ? 1 : 0.6)];
    }
    const life = Math.max(0, 1 - m.age / m.life);
    return [m.col[0], m.col[1], m.col[2], life * life];
  }

  destroy(): void {
    this.renderer?.dispose();
    this.geo.dispose();
    this.pointMat.dispose();
    this.quadMat.dispose();
    this.canvas.remove();
  }
}
