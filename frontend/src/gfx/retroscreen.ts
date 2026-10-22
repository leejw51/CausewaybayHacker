/**
 * The tube over the playground's editor, when the playground is an old
 * computer (`ui/computer.ts`).
 *
 * After cool-retro-term (github.com/swordfish90/cool-retro-term), which is a
 * terminal drawn through a stack of shaders: bloom, scanlines, a phosphor
 * mask, static, flicker, a rolling sync bar, curvature and a bezel. Most of
 * that stack wants to *sample* the terminal's text, and the editor here is
 * DOM — a WebGL canvas laid over it cannot read its pixels. So the work is
 * split by what each half can reach:
 *
 *   * **the glyphs' own glow** is CSS, a `text-shadow` per machine in
 *     `style.css`, the only thing that can blur DOM text;
 *   * **everything that sits on the glass** is this: one transparent
 *     three.js quad exactly over the editor, premultiplied, composited above
 *     it — scanline gaps, the aperture grille, a still grain, the rolling
 *     bar, a vignette, rounded glass corners and a glare;
 *   * **the boot screen** is the one thing drawn *on* the tube rather than
 *     over it, so it gets the full treatment: barrel distortion, bloom from a
 *     blurred copy, colour fringing and line jitter. It is the machine's own
 *     power-on text — `]` and a beep, MSX BASIC's banner, Workbench's title
 *     bar — painted into a small 2D canvas at the machine's resolution and
 *     scaled up with nearest-neighbour, so the pixels are its pixels.
 *
 * Switching machines plays the power-on: a bright line opens into the
 * screen, the banner types itself out, and the screen fades into the editor.
 * Switching to "normal" plays the power-off — the picture collapses to a line
 * and then a dot. A failed RUN puts the machine's own error up over the
 * code for a few seconds; on the Amiga that is a Guru Meditation, with its
 * red box blinking.
 *
 * Without WebGL none of this exists and the CSS half carries the theme on
 * its own. Nothing flickers: cool-retro-term's mains flicker, crawling
 * static and sync jitter were tried — as an option, and gentled with
 * cosines — and taken out, because a pane somebody reads for an hour must
 * hold still. Under reduced motion the roll stops and the boot is a quick
 * fade.
 */
import {
  CanvasTexture,
  Mesh,
  NearestFilter,
  OrthographicCamera,
  PlaneGeometry,
  Scene,
  ShaderMaterial,
  Vector2,
  Vector3,
  WebGLRenderer,
} from "three";

import type { Layout } from "../engine/layout";
import { reducedMotion } from "../engine/motion";
import type { Rect } from "../engine/ui";
import { Overlay } from "../ui/overlay";
import type { Computer, Tube } from "../ui/computer";
import { TUBE } from "../ui/computer";

type Machine = Exclude<Computer, "normal">;

/** Seconds for the line to open into a screen, and to collapse back. */
const WARM = 0.42;
const COOL = 0.5;
/** How long the boot screen takes to fade into the editor. */
const REVEAL = 0.5;
/** How long a run's error stays up. */
const ALERT_SECS = 3.2;

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
uniform sampler2D uText;
uniform vec2 uRes;       // canvas pixels
uniform vec2 uTextRes;   // boot-screen pixels
uniform float uTime;
uniform float uPower;    // 0 = a dot, 1 = a full picture
uniform float uScreen;   // how much of the boot screen covers the editor
uniform float uMotion;   // 0 under reduced motion
uniform float uDpr;
uniform vec3 uPaper;
uniform vec3 uInk;
uniform float uScan;
uniform float uScanPx;
uniform float uMask;
uniform float uBloom;
uniform float uCurve;
uniform float uNoise;
uniform float uRoll;
uniform float uFringe;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

// "a over b", both premultiplied.
vec4 over(vec4 a, vec4 b) { return a + b * (1.0 - a.a); }

vec3 screen(vec2 uv) {
  vec2 px = vec2(uFringe / uTextRes.x, 0.0);
  vec3 c;
  c.r = texture2D(uText, uv + px).r;
  c.g = texture2D(uText, uv).g;
  c.b = texture2D(uText, uv - px).b;
  // Bloom: a cheap blur of thirteen taps, added back. Phosphor that is lit
  // bleeds into the glass round it.
  vec3 b = vec3(0.0);
  vec2 s = 1.5 / uTextRes;
  for (int i = -3; i <= 3; i++) {
    b += texture2D(uText, uv + vec2(float(i), 0.0) * s).rgb;
    if (i != 0) b += texture2D(uText, uv + vec2(0.0, float(i)) * s).rgb;
  }
  b /= 13.0;
  return c + max(b - uPaper * 0.9, 0.0) * uBloom;
}

void main() {
  vec2 uv = vUv;
  vec2 cc = uv - 0.5;
  // Barrel: the boot screen bends, the glass corners round off.
  vec2 bent = uv + cc * dot(cc, cc) * uCurve * 1.6;
  float inside = step(0.0, bent.x) * step(bent.x, 1.0) * step(0.0, bent.y) * step(bent.y, 1.0);

  vec4 out_ = vec4(0.0);

  // -- the boot screen, when it is up -----------------------------------
  if (uScreen > 0.001) {
    vec3 c = inside > 0.5 ? screen(bent) : vec3(0.0);
    out_ = vec4(c * uScreen, uScreen);
  }

  float y = gl_FragCoord.y / uDpr;
  float x = gl_FragCoord.x / uDpr;

  // -- scanlines: the dark gaps between rows of phosphor -----------------
  float line = 0.5 + 0.5 * cos(6.2831853 * y / uScanPx);
  out_ = over(vec4(0.0, 0.0, 0.0, uScan * line * line), out_);

  // -- aperture grille: faint R, G, B stripes ----------------------------
  if (uMask > 0.0) {
    float k = mod(floor(x), 3.0);
    vec3 m = k < 1.0 ? vec3(1.0, 0.0, 0.0) : k < 2.0 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);
    out_ = over(vec4(m * uMask * 0.35, uMask * 0.35), out_);
  }

  // -- grain: still. It does not crawl. --------------------------------
  float n = hash(gl_FragCoord.xy);
  out_ = over(vec4(uInk * n * uNoise * 0.6, n * uNoise * 0.4), out_);

  // -- the rolling bar: a soft band of light walking down ----------------
  float bar = fract(uTime * 0.11 * uMotion);
  float d = abs((1.0 - uv.y) - bar);
  float band = smoothstep(0.08, 0.0, d) * uRoll;
  out_ += vec4(uInk * band * 0.5, 0.0);


  // -- vignette and glass ------------------------------------------------
  float v = smoothstep(0.35, 0.95, length(cc * vec2(1.05, 1.15)) * 1.25);
  out_ = over(vec4(0.0, 0.0, 0.0, v * 0.55), out_);
  float glare = smoothstep(0.55, 0.0, length((uv - vec2(0.18, 0.86)) * vec2(1.0, 1.8)));
  out_ += vec4(vec3(glare * 0.05), 0.0);
  // Rounded corners of the tube, in the bezel's black.
  vec2 q = abs(cc) * 2.0;
  float r = 0.06 + uCurve * 0.25;
  vec2 ar = vec2(uRes.x / uRes.y, 1.0);
  float corner = length(max(q * ar - (ar - r), 0.0)) / r;
  out_ = over(vec4(0.0, 0.0, 0.0, smoothstep(0.92, 1.0, corner)), out_);

  // -- power: a line that opens into a picture, and a dot it closes to --
  if (uPower < 0.999) {
    float h = smoothstep(0.0, 0.7, uPower);          // how tall the picture is
    float w = smoothstep(0.0, 0.25, uPower);         // how wide the line is
    float ay = abs(uv.y - 0.5) * 2.0;
    float ax = abs(uv.x - 0.5) * 2.0;
    float lit = step(ay, max(h, 0.006)) * step(ax, max(w, 0.02));
    float hot = (1.0 - h) * lit;                     // thin = bright
    vec4 black = vec4(0.0, 0.0, 0.0, 1.0 - lit);
    out_ = over(black, out_);
    out_ += vec4(mix(uInk, vec3(1.0), 0.6) * hot * 1.4, hot);
  }

  gl_FragColor = clamp(out_, 0.0, 1.0);
}
`;

/** One boot screen: how long it runs and what it shows at time `t`. */
interface Boot {
  readonly secs: number;
  draw(g: CanvasRenderingContext2D, t: number, grid: Grid): void;
}

/** The boot screen's character grid. */
interface Grid {
  readonly cols: number;
  readonly rows: number;
  readonly cw: number;
  readonly ch: number;
  /** How much each glyph is stretched across to fill its cell. */
  readonly sx: number;
}

const FAMILY: Record<Machine, string> = {
  apple2: `"AppleIIPR3", "VT323", monospace`,
  msx: `"MSX1Code", "VT323", monospace`,
  amiga: `"TopazUnicode", "VT323", monospace`,
};

const css = (c: readonly [number, number, number], a = 1) =>
  `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${a})`;

/** Text on the grid, one cell per character, so every face lands on it. */
function put(g: CanvasRenderingContext2D, grid: Grid, col: number, row: number, s: string): void {
  for (let i = 0; i < s.length; i++) {
    g.save();
    g.translate((col + i) * grid.cw, row * grid.ch + grid.ch * 0.82);
    g.scale(grid.sx, 1);
    g.fillText(s[i], 0, 0);
    g.restore();
  }
}

/** How much of `s` is typed by `t`, starting at `from`, `cps` a second. */
function typed(s: string, t: number, from: number, cps = 14): string {
  if (t < from) return "";
  return s.slice(0, Math.floor((t - from) * cps));
}

const blink = (t: number, hz = 2) => Math.floor(t * hz) % 2 === 0;

const BOOTS: Record<Machine, Boot> = {
  // The //e: a beep, "Apple ][" across the top, then BASIC's bracket prompt.
  apple2: {
    secs: 2.4,
    draw(g, t, grid) {
      const tube = TUBE.apple2;
      g.fillStyle = css(tube.ink);
      const title = "APPLE ][";
      if (t > 0.15) put(g, grid, Math.floor((grid.cols - title.length) / 2), 0, title);
      if (t > 0.6) {
        const cmd = typed("RUN PLAYGROUND", t, 0.75);
        put(g, grid, 0, grid.rows - 3, "]" + cmd);
        // The Apple's cursor is a flashing checkerboard block.
        if (blink(t, 3))
          g.fillRect((1 + cmd.length) * grid.cw, (grid.rows - 3) * grid.ch, grid.cw, grid.ch);
      }
    },
  },
  // MSX BASIC's banner on its blue, and the function-key bar along the bottom.
  msx: {
    secs: 2.6,
    draw(g, t, grid) {
      const tube = TUBE.msx;
      g.fillStyle = css(tube.ink);
      const lines = [
        "MSX BASIC version 1.0",
        "Copyright 1983 by Microsoft",
        "28815 Bytes free",
        "Ok",
      ];
      lines.forEach((l, i) => {
        if (t > 0.2 + i * 0.25) put(g, grid, 1, i + 1, l);
      });
      if (t > 1.25) {
        const cmd = typed('run "PLAYGROUND"', t, 1.3);
        put(g, grid, 1, 5, cmd);
        if (blink(t, 3)) g.fillRect((1 + cmd.length) * grid.cw, 5 * grid.ch, grid.cw, grid.ch);
      }
      const keys = ["color", "auto", "goto", "list", "run"];
      // SCREEN 0 kept a border round the text; so does this.
      const w = Math.floor((grid.cols - 2) / keys.length);
      keys.forEach((k, i) => {
        g.fillStyle = css(tube.ink);
        g.fillRect((1 + i * w) * grid.cw, (grid.rows - 2) * grid.ch, (w - 1) * grid.cw, grid.ch);
        g.fillStyle = css(tube.paper);
        put(g, grid, 1 + i * w, grid.rows - 2, k.slice(0, w - 1));
      });
    },
  },
  // Workbench 1.3: the white title bar with its free memory, and a CLI.
  amiga: {
    secs: 2.6,
    draw(g, t, grid) {
      const white: [number, number, number] = [1, 1, 1];
      const orange: [number, number, number] = [1, 0.53, 0];
      const blue = TUBE.amiga.paper;
      // Kickstart's white screen first, then Workbench draws over it.
      if (t < 0.5) {
        g.fillStyle = css(white);
        g.fillRect(0, 0, grid.cols * grid.cw, grid.rows * grid.ch);
        return;
      }
      g.fillStyle = css(white);
      g.fillRect(0, 0, grid.cols * grid.cw, grid.ch * 1.2);
      g.fillStyle = css(blue);
      put(g, grid, 1, 0, "Workbench release 1.3   451344 free memory");
      // The depth gadgets, top right.
      g.fillRect((grid.cols - 4) * grid.cw, grid.ch * 0.2, grid.cw * 1.4, grid.ch * 0.8);
      g.fillStyle = css(orange);
      g.fillRect((grid.cols - 2) * grid.cw, grid.ch * 0.2, grid.cw * 1.4, grid.ch * 0.8);
      if (t > 0.8) {
        // The CLI window: an orange-and-white frame with its own title bar.
        const x = grid.cw * 2;
        const y = grid.ch * 2.5;
        const w = (grid.cols - 4) * grid.cw;
        const h = (grid.rows - 4) * grid.ch;
        g.fillStyle = css(white);
        g.fillRect(x, y, w, grid.ch * 1.1);
        g.strokeStyle = css(white);
        g.lineWidth = Math.max(1, grid.cw * 0.25);
        g.strokeRect(x, y, w, h);
        g.fillStyle = css(blue);
        put(g, grid, 3, 2.5, "AmigaShell");
        g.fillStyle = css(orange);
        g.fillRect(x + w - grid.cw * 2, y + grid.ch * 0.15, grid.cw * 1.4, grid.ch * 0.8);
        g.fillStyle = css(white);
        const lines = ["1.SYS:> LoadWB", "1.SYS:> cd Work:", "1.Work:> "];
        lines.forEach((l, i) => {
          if (t > 1.0 + i * 0.25) put(g, grid, 3, 4 + i, l);
        });
        if (t > 1.6) {
          const cmd = typed("playground", t, 1.65);
          put(g, grid, 3 + lines[2].length, 6, cmd);
          if (blink(t, 2)) {
            g.fillStyle = css(orange);
            g.fillRect((3 + lines[2].length + cmd.length) * grid.cw, 6 * grid.ch, grid.cw, grid.ch);
          }
        }
      }
    },
  },
};

export class RetroScreen {
  readonly ok: boolean;
  private readonly canvas = document.createElement("canvas");
  private readonly overlay: Overlay;
  private renderer: WebGLRenderer | null = null;
  private readonly scene = new Scene();
  private readonly camera = new OrthographicCamera(-1, 1, 1, -1, 0, 1);
  private material: ShaderMaterial | null = null;
  private readonly text = document.createElement("canvas");
  private readonly tg: CanvasRenderingContext2D | null;
  private texture: CanvasTexture | null = null;

  private machine: Machine | null = null;
  private now = 0;
  /** What the tube is doing, and since when (`now`). */
  private phase: "off" | "cooling" | "warming" | "booting" | "revealing" | "on" = "off";
  private since = 0;
  /** Whether the warm-up goes on into the banner, or straight to the code. */
  private booting = false;
  /** A run's error, and when it went up. */
  private alert: { lines: string[]; at: number } | null = null;
  private rect: Rect = [0, 0, 0, 0];
  private placed = false;

  constructor(
    host: HTMLElement,
    layout: Layout,
    /** The editor it sits on: hidden whenever that is. */
    private readonly under: HTMLElement,
  ) {
    this.canvas.className = "cwb-retro";
    this.overlay = new Overlay(host, layout, this.canvas);
    // Straight after the editor, so the tube is over the code and under
    // everything laid on top of it later (the effects, the fields).
    host.insertBefore(this.canvas, under.nextSibling);
    this.tg = this.text.getContext("2d");
    try {
      this.renderer = new WebGLRenderer({
        canvas: this.canvas,
        alpha: true,
        antialias: false,
        premultipliedAlpha: true,
        powerPreference: "low-power",
        failIfMajorPerformanceCaveat: false,
      });
      this.renderer.setClearColor(0x000000, 0);
    } catch {
      this.renderer = null;
    }
    this.ok = this.renderer !== null && this.tg !== null;
    if (!this.ok) return;
    this.texture = new CanvasTexture(this.text);
    this.texture.magFilter = NearestFilter;
    this.texture.minFilter = NearestFilter;
    this.texture.generateMipmaps = false;
    this.material = new ShaderMaterial({
      vertexShader: VERT,
      fragmentShader: FRAG,
      transparent: true,
      premultipliedAlpha: true,
      depthTest: false,
      depthWrite: false,
      uniforms: {
        uText: { value: this.texture },
        uRes: { value: new Vector2(1, 1) },
        uTextRes: { value: new Vector2(1, 1) },
        uTime: { value: 0 },
        uPower: { value: 1 },
        uScreen: { value: 0 },
        uMotion: { value: 1 },
        uDpr: { value: 1 },
        uPaper: { value: new Vector3() },
        uInk: { value: new Vector3() },
        uScan: { value: 0 },
        uScanPx: { value: 3 },
        uMask: { value: 0 },
        uBloom: { value: 0 },
        uCurve: { value: 0 },
        uNoise: { value: 0 },
        uRoll: { value: 0 },
        uFringe: { value: 0 },
      },
    });
    this.scene.add(new Mesh(new PlaneGeometry(2, 2), this.material));
  }

  /**
   * Become `next`. `boot` plays the whole power-on — the banner and all —
   * which is for the moment the machine is picked; arriving at the screen
   * with one already picked only warms the tube up.
   */
  power(next: Computer, boot: boolean): void {
    if (!this.ok) return;
    if (next === "normal") {
      if (this.machine && this.phase !== "off") this.go("cooling");
      return;
    }
    this.machine = next;
    this.alert = null;
    this.tune(TUBE[next]);
    this.booting = boot && !reducedMotion();
    this.go(reducedMotion() ? "revealing" : "warming");
  }

  /** Put the machine's own error over the code for a few seconds. */
  say(lines: string[]): void {
    if (!this.ok || !this.machine || this.phase === "off" || this.phase === "cooling") return;
    this.alert = { lines, at: this.now };
  }

  /** Over this rectangle of the virtual canvas, every frame it is shown. */
  place(rect: Rect): void {
    this.rect = rect;
    this.placed = true;
  }

  frame(dt: number): void {
    if (!this.ok) return;
    this.now += dt;
    this.step();
    const visible =
      this.phase !== "off" && this.placed && !this.under.classList.contains("cwb-hidden");
    this.placed = false;
    if (!visible) {
      this.overlay.hide();
      return;
    }
    this.overlay.place(this.rect);
    this.render();
  }

  destroy(): void {
    this.texture?.dispose();
    this.material?.dispose();
    // Given back now, not when the collector gets round to it: a context per
    // visit to the playground is how a long session reaches the browser's cap.
    this.renderer?.forceContextLoss();
    this.renderer?.dispose();
    this.overlay.destroy();
  }

  // -- the clock ------------------------------------------------------------

  private go(phase: RetroScreen["phase"]): void {
    this.phase = phase;
    this.since = this.now;
  }

  private step(): void {
    const t = this.now - this.since;
    const boot = this.machine ? BOOTS[this.machine] : null;
    if (this.phase === "warming" && t >= WARM)
      this.go(this.booting && boot ? "booting" : "revealing");
    else if (this.phase === "booting" && boot && t >= boot.secs) this.go("revealing");
    else if (this.phase === "revealing" && t >= REVEAL) this.go("on");
    else if (this.phase === "cooling" && t >= COOL) {
      this.go("off");
      this.machine = null;
    }
    if (this.alert && this.now - this.alert.at > ALERT_SECS) this.alert = null;
  }

  private tune(tube: Tube): void {
    const u = this.material!.uniforms;
    (u.uPaper.value as Vector3).set(...tube.paper);
    (u.uInk.value as Vector3).set(...tube.ink);
    u.uScan.value = tube.scan;
    u.uScanPx.value = tube.scanPx;
    u.uMask.value = tube.mask;
    u.uBloom.value = tube.bloom;
    u.uCurve.value = tube.curve;
    u.uNoise.value = tube.noise;
    u.uRoll.value = tube.roll;
    u.uFringe.value = tube.fringe;
  }

  // -- drawing --------------------------------------------------------------

  private render(): void {
    const renderer = this.renderer!;
    const u = this.material!.uniforms;
    const cw = Math.max(1, this.canvas.clientWidth);
    const ch = Math.max(1, this.canvas.clientHeight);
    const dpr = Math.min(2, devicePixelRatio || 1);
    const size = renderer.getSize(new Vector2());
    if (size.x !== cw || size.y !== ch || renderer.getPixelRatio() !== dpr) {
      renderer.setPixelRatio(dpr);
      renderer.setSize(cw, ch, false);
    }
    const t = this.now - this.since;
    let power = 1;
    let screen = 0;
    if (this.phase === "warming") {
      power = Math.min(1, t / WARM);
      screen = this.booting ? 1 : 1 - power * 0.3;
    } else if (this.phase === "booting") screen = 1;
    else if (this.phase === "revealing") screen = 1 - Math.min(1, t / REVEAL);
    else if (this.phase === "cooling") {
      power = Math.max(0, 1 - t / COOL);
      screen = 0;
    }
    // An error goes up on the boot screen too, over the code, and fades.
    const alertAge = this.alert ? this.now - this.alert.at : 0;
    if (this.alert)
      screen = Math.max(screen, Math.min(1, (ALERT_SECS - alertAge) / 0.4, alertAge / 0.08));
    if (screen > 0 && this.machine) this.paint(this.machine, cw, ch, t, alertAge);
    u.uRes.value.set(cw * dpr, ch * dpr);
    u.uTextRes.value.set(this.text.width, this.text.height);
    u.uTime.value = this.now;
    u.uPower.value = power;
    u.uScreen.value = screen;
    u.uMotion.value = reducedMotion() ? 0 : 1;
    u.uDpr.value = dpr;
    renderer.render(this.scene, this.camera);
  }

  /** The boot screen (or the error) into the small canvas, at its own size. */
  private paint(machine: Machine, cw: number, ch: number, t: number, alertAge: number): void {
    const g = this.tg!;
    const tube = TUBE[machine];
    // Square cells, sixteen texels each: the 8x8 cells the machines had, at
    // twice the resolution so the glyphs survive the trip. Rows follow the
    // pane's shape. Each glyph is stretched to fill its cell, which is what
    // the 40-column machines did with their 7-dot characters anyway.
    const cell = 16;
    const cols = tube.cols;
    const w = cols * cell;
    const rows = Math.max(6, Math.round((cols * ch) / cw));
    const h = rows * cell;
    if (this.text.width !== w || this.text.height !== h) {
      this.text.width = w;
      this.text.height = h;
      // A canvas of a new size is a new texture to the GPU.
      this.texture!.dispose();
    }
    g.imageSmoothingEnabled = false;
    g.textBaseline = "alphabetic";
    // Sized on the glyph, not the em: the three faces put very different
    // ems round the same 8x8 dot (MSX1's is two cells tall). A capital is
    // made to stand seven-eighths of the cell, as on the machines.
    g.font = `${cell}px ${FAMILY[machine]}`;
    const cap = g.measureText("M").actualBoundingBoxAscent;
    const px = cap > 0 ? (cell * cell * 0.72) / cap : cell;
    g.font = `${px.toFixed(2)}px ${FAMILY[machine]}`;
    const adv = g.measureText("M").width || cell;
    const grid: Grid = { cols, rows, cw: cell, ch: cell, sx: Math.min(2.4, cell / adv) };
    g.fillStyle = css(tube.paper);
    g.fillRect(0, 0, w, h);
    if (this.alert) this.paintAlert(g, machine, grid, alertAge);
    else if (this.phase === "warming" || this.phase === "booting") {
      if (this.phase === "booting") BOOTS[machine].draw(g, t, grid);
    } else if (this.phase === "revealing" && this.booting)
      BOOTS[machine].draw(g, BOOTS[machine].secs, grid);
    this.texture!.needsUpdate = true;
  }

  private paintAlert(g: CanvasRenderingContext2D, machine: Machine, grid: Grid, age: number): void {
    const lines = this.alert!.lines;
    const tube = TUBE[machine];
    if (machine === "amiga") {
      // The Guru: black, a red box that blinks, red text centred in it.
      const red = "rgb(255,34,0)";
      g.fillStyle = "#000";
      g.fillRect(0, 0, grid.cols * grid.cw, grid.rows * grid.ch);
      const top = 1;
      const boxH = (lines.length + 2) * grid.ch;
      if (blink(age, 1.2)) {
        g.strokeStyle = red;
        g.lineWidth = grid.cw * 0.75;
        g.strokeRect(grid.cw * 0.6, top * grid.ch, (grid.cols - 1.2) * grid.cw, boxH);
      }
      g.fillStyle = red;
      lines.forEach((l, i) =>
        put(g, grid, Math.max(1, Math.floor((grid.cols - l.length) / 2)), top + 1 + i, l),
      );
      return;
    }
    // The 8-bits print it under the code they were running and go back to
    // the prompt: the line, a beep's worth of bright, and the cursor.
    g.fillStyle = css(tube.ink);
    const row = Math.max(1, Math.floor(grid.rows / 2) - 1);
    lines.forEach((l, i) => put(g, grid, 0, row + i, l));
    const prompt = machine === "apple2" ? "]" : "Ok";
    put(g, grid, 0, row + lines.length, prompt);
    if (blink(age, 3)) {
      g.fillRect(
        (machine === "apple2" ? 1 : 0) * grid.cw,
        (row + lines.length + (machine === "apple2" ? 0 : 1)) * grid.ch,
        grid.cw,
        grid.ch,
      );
    }
  }
}
