/**
 * The playground's screen-space light: one transparent WebGL canvas over the
 * whole scene, one full-screen quad, one fragment shader.
 *
 * `ui/codefx.ts` throws *things* — sparks, bricks, stars — over the editor.
 * This is the other half of a game's feedback, the part that is light rather
 * than matter, and it is what makes a run feel like a hit landing:
 *
 *   * RUN — a ripple of light leaves the button and crosses the screen;
 *   * a clean run — a bloom flash in the run's colour from the output, and a
 *     gold sweep along the editor;
 *   * a failed build — the editor glitches: torn scanline bands in red and
 *     cyan, a shudder of chromatic fringes, a red vignette that breathes out;
 *   * FEVER (a long typing combo) — the screen's edge burns pink and gold,
 *     with sparks running round it.
 *
 * It only ever *adds* light (premultiplied, nothing opaque), so the editor
 * under it stays readable through every effect, and it draws nothing — not
 * even a clear — once every effect has decayed. Under
 * `prefers-reduced-motion` each effect is a quarter as strong and the glitch
 * does not tear.
 */
import {
  Mesh,
  NoBlending,
  OrthographicCamera,
  PlaneGeometry,
  Scene,
  ShaderMaterial,
  Vector2,
  Vector3,
  Vector4,
  WebGLRenderer,
} from "three";
import type { Layout } from "../engine/layout";
import { reducedMotion } from "../engine/motion";
import type { Rect } from "../engine/ui";
import type { RGBA } from "../engine/theme";

const VERT = /* glsl */ `
varying vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = vec4(position.xy, 0.0, 1.0);
}
`;

const FRAG = /* glsl */ `
precision highp float;
varying vec2 vUv;
uniform vec2 uRes;
uniform float uTime;
uniform float uScale;

uniform vec4 uRect;        // the editor, device px, y up: x0 y0 x1 y1
uniform float uFlash;      // 0..1
uniform vec3 uFlashCol;
uniform vec2 uFlashAt;     // device px, y up
uniform float uRipple;     // seconds since RUN, < 0 = none
uniform vec2 uRippleAt;
uniform vec3 uRippleCol;
uniform float uGlitch;     // 0..1
uniform float uSweep;      // seconds since a clean run, < 0 = none
uniform float uFever;      // 0..1
uniform float uTear;       // 0 or 1: reduced motion turns tearing off

float hash(float n) { return fract(sin(n) * 43758.5453123); }
float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void main() {
  vec2 p = gl_FragCoord.xy;
  vec3 col = vec3(0.0);
  float a = 0.0;

  // -- bloom flash: a soft disc of the run's colour, from where it landed.
  if (uFlash > 0.001) {
    float d = length(p - uFlashAt) / (uRes.y * 0.9);
    float k = exp(-d * d * 3.0) * uFlash;
    col += uFlashCol * k * 0.9;
    a += k * 0.12;
  }

  // -- RUN ripple: a ring of light leaving the button, then a fainter echo.
  if (uRipple >= 0.0) {
    float r = uRipple * uRes.y * 1.9;
    float d = length(p - uRippleAt);
    float w = 10.0 * uScale + uRipple * 30.0 * uScale;
    float fade = clamp(1.0 - uRipple / 0.9, 0.0, 1.0);
    float ring = exp(-pow((d - r) / w, 2.0)) * fade;
    float echo = exp(-pow((d - r * 0.62) / (w * 0.7), 2.0)) * fade * 0.45;
    col += uRippleCol * (ring + echo);
    a += (ring + echo) * 0.08;
  }

  bool inRect = p.x >= uRect.x && p.x <= uRect.z && p.y >= uRect.y && p.y <= uRect.w;

  // -- glitch: torn bands, chromatic fringes, scan noise, inside the editor;
  //    a red vignette breathing out over the whole screen.
  if (uGlitch > 0.001) {
    if (inRect) {
      float t = floor(uTime * 24.0);
      float band = floor(p.y / (6.0 * uScale + 14.0 * uScale * hash(t)));
      float on = step(1.0 - 0.28 * uGlitch, hash(band * 7.13 + t));
      float shift = (hash(band + t * 3.1) - 0.5) * 60.0 * uScale * uGlitch * uTear;
      float edge = fract((p.x + shift) / (uRect.z - uRect.x));
      float stripe = on * (0.35 + 0.65 * step(0.5, fract(edge * 3.0 + hash(band))));
      vec3 rc = mix(vec3(1.0, 0.12, 0.08), vec3(0.2, 0.9, 1.0), step(0.5, hash(band * 1.7 + t)));
      col += rc * stripe * 0.55 * uGlitch;
      a += stripe * 0.32 * uGlitch;
      float scan = step(0.985, hash2(vec2(floor(p.y / (2.0 * uScale)), t))) * uGlitch;
      col += vec3(1.0, 0.5, 0.45) * scan;
      a += scan * 0.4;
      // the frame itself flickers red
      float fx = min(p.x - uRect.x, uRect.z - p.x);
      float fy = min(p.y - uRect.y, uRect.w - p.y);
      float rim = exp(-min(fx, fy) / (5.0 * uScale)) * uGlitch;
      col += vec3(1.0, 0.16, 0.05) * rim * 1.4;
      a += rim * 0.6;
    }
    vec2 q = (p / uRes) - 0.5;
    float vig = smoothstep(0.42, 0.85, length(q * vec2(uRes.x / uRes.y, 1.0))) * uGlitch;
    col += vec3(0.85, 0.05, 0.02) * vig * 0.6;
    a += vig * 0.25;
  }

  // -- a clean run: a gold light sweeping down the editor, once.
  if (uSweep >= 0.0 && inRect) {
    float h = uRect.w - uRect.y;
    float y = uRect.w - uSweep / 0.7 * (h + 120.0 * uScale);
    float k = exp(-pow((p.y - y) / (26.0 * uScale), 2.0)) * clamp(1.0 - uSweep / 0.9, 0.0, 1.0);
    float sparkle = step(0.992, hash2(floor(p / (3.0 * uScale)) + floor(uTime * 30.0)));
    col += vec3(1.0, 0.85, 0.3) * k * (0.55 + sparkle * 2.0);
    a += k * 0.08;
  }

  // -- FEVER: the screen's edge burns, with sparks running round it.
  if (uFever > 0.001) {
    float dx = min(p.x, uRes.x - p.x);
    float dy = min(p.y, uRes.y - p.y);
    float e = min(dx, dy);
    float pulse = 0.65 + 0.35 * sin(uTime * 7.0);
    float burn = exp(-e / (18.0 * uScale)) * uFever * pulse;
    // a hue running round the frame: pink to gold
    float around = (p.x + p.y) / (uRes.x + uRes.y) + uTime * 0.35;
    vec3 fc = mix(vec3(1.0, 0.35, 0.65), vec3(1.0, 0.82, 0.2), 0.5 + 0.5 * sin(around * 12.566));
    col += fc * burn * 1.3;
    a += burn * 0.25;
    float runner = step(0.996, hash2(floor(p / (4.0 * uScale)) + floor(uTime * 20.0))) * exp(-e / (40.0 * uScale)) * uFever;
    col += vec3(1.0) * runner * 1.5;
    a += runner * 0.1;
  }

  a = clamp(a, 0.0, 0.92);
  gl_FragColor = vec4(min(col, vec3(1.0)), a);
}
`;

/** How long each effect takes to die away, in seconds. */
const FLASH_LIFE = 0.55;
const RIPPLE_LIFE = 0.9;
const GLITCH_LIFE = 0.7;
const SWEEP_LIFE = 0.9;

export class PlayFx {
  private readonly canvas = document.createElement("canvas");
  private renderer: WebGLRenderer | null = null;
  private readonly scene = new Scene();
  private readonly camera = new OrthographicCamera(-1, 1, 1, -1, 0, 1);
  private readonly mat: ShaderMaterial;
  private time = 0;
  private flash = 0;
  private ripple = -1;
  private glitch = 0;
  private sweep = -1;
  private fever = 0;
  private feverTarget = 0;
  /** Whether the last frame drew anything, so an idle screen is cleared once. */
  private drew = false;

  constructor(
    host: HTMLElement,
    private readonly layout: Layout,
  ) {
    this.canvas.className = "cwb-sparks cwb-playfx";
    this.mat = new ShaderMaterial({
      vertexShader: VERT,
      fragmentShader: FRAG,
      // One quad on a cleared canvas: nothing under it to blend with. The
      // colour it writes is premultiplied *light* — it may exceed its own
      // alpha, which the compositor then adds over the page rather than
      // laying over it: a glow, not a wash.
      blending: NoBlending,
      transparent: true,
      depthTest: false,
      depthWrite: false,
      uniforms: {
        uRes: { value: new Vector2(1, 1) },
        uTime: { value: 0 },
        uScale: { value: 1 },
        uRect: { value: new Vector4(0, 0, 0, 0) },
        uFlash: { value: 0 },
        uFlashCol: { value: new Vector3(1, 1, 1) },
        uFlashAt: { value: new Vector2(0, 0) },
        uRipple: { value: -1 },
        uRippleAt: { value: new Vector2(0, 0) },
        uRippleCol: { value: new Vector3(1, 0.85, 0.2) },
        uGlitch: { value: 0 },
        uSweep: { value: -1 },
        uFever: { value: 0 },
        uTear: { value: 1 },
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
    this.scene.add(new Mesh(new PlaneGeometry(2, 2), this.mat));
    host.appendChild(this.canvas);
    this.canvas.addEventListener("webglcontextlost", (ev) => ev.preventDefault());
  }

  get ok(): boolean {
    return this.renderer !== null;
  }

  /** Device px, y up, from a virtual point. */
  private dev(x: number, y: number): [number, number] {
    const { ox, oy, scale, dh } = this.layout;
    return [ox + x * scale, dh - (oy + y * scale)];
  }

  private colour(c: RGBA): Vector3 {
    return new Vector3(c[0], c[1], c[2]);
  }

  private get k(): number {
    return reducedMotion() ? 0.25 : 1;
  }

  /** Where the editor is, in virtual pixels: the glitch and sweep stay in it. */
  editor(rect: Rect): void {
    const [x0, y1] = this.dev(rect[0], rect[1]);
    const [x1, y0] = this.dev(rect[0] + rect[2], rect[1] + rect[3]);
    (this.mat.uniforms.uRect.value as Vector4).set(x0, y0, x1, y1);
  }

  /** RUN was pressed at (x, y). */
  launch(x: number, y: number, c: RGBA): void {
    this.ripple = 0;
    const [dx, dy] = this.dev(x, y);
    (this.mat.uniforms.uRippleAt.value as Vector2).set(dx, dy);
    this.mat.uniforms.uRippleCol.value = this.colour(c);
  }

  /** A clean run: a flash from (x, y) and a sweep down the editor. */
  clear(x: number, y: number, c: RGBA): void {
    this.flash = 1;
    this.sweep = 0;
    const [dx, dy] = this.dev(x, y);
    (this.mat.uniforms.uFlashAt.value as Vector2).set(dx, dy);
    this.mat.uniforms.uFlashCol.value = this.colour(c);
  }

  /** A failed build or a crash: the editor glitches. */
  hurt(): void {
    this.glitch = 1;
  }

  /** How hot the combo is, 0..1: the edge burns toward it. */
  setFever(v: number): void {
    this.feverTarget = Math.max(0, Math.min(1, v));
  }

  frame(dt: number): void {
    if (!this.renderer) return;
    this.time += dt;
    this.flash = Math.max(0, this.flash - dt / FLASH_LIFE);
    this.glitch = Math.max(0, this.glitch - dt / GLITCH_LIFE);
    if (this.ripple >= 0) this.ripple = this.ripple + dt > RIPPLE_LIFE ? -1 : this.ripple + dt;
    if (this.sweep >= 0) this.sweep = this.sweep + dt > SWEEP_LIFE ? -1 : this.sweep + dt;
    this.fever += (this.feverTarget - this.fever) * Math.min(1, dt * 4);
    if (this.fever < 0.002) this.fever = 0;

    const live =
      this.flash > 0 || this.glitch > 0 || this.ripple >= 0 || this.sweep >= 0 || this.fever > 0;
    if (!live) {
      if (this.drew) {
        this.renderer.clear();
        this.drew = false;
      }
      return;
    }
    const { dw, dh, scale } = this.layout;
    if (this.canvas.width !== dw || this.canvas.height !== dh) this.renderer.setSize(dw, dh, false);
    const u = this.mat.uniforms;
    const k = this.k;
    (u.uRes.value as Vector2).set(dw, dh);
    u.uTime.value = this.time;
    u.uScale.value = scale;
    u.uFlash.value = this.flash * this.flash * k;
    u.uRipple.value = this.ripple;
    u.uGlitch.value = this.glitch * k;
    u.uSweep.value = this.sweep;
    u.uFever.value = this.fever * k;
    u.uTear.value = reducedMotion() ? 0 : 1;
    this.renderer.render(this.scene, this.camera);
    this.drew = true;
  }

  destroy(): void {
    this.renderer?.dispose();
    this.mat.dispose();
    this.canvas.remove();
  }
}
