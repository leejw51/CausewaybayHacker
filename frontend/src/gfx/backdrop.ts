/**
 * The three.js layer, behind everything, on every screen.
 *
 * It used to be the map's alone. That was a mistake twice over: the boot and
 * login screens had no WebGL canvas at all, and the one that existed was never
 * sized — the browser's default 300x150 backing store stretched by CSS to the
 * window, so everything on it was drawn at a quarter resolution and in the
 * wrong place. Now `App` owns exactly one of these, sizes it from `Layout`
 * alongside the 2D canvas, and scenes only say what mood they want.
 *
 * What it draws: a banded night sky, three scrolling parallax bands of
 * Causeway Bay (`skyline.ts`), two star fields at different depths, and an
 * additive glow that the result screen throws when a street clears. Every
 * texture is `NearestFilter` with no mipmaps, so a pixel stays a pixel.
 *
 * It is entirely optional. `Backdrop.create` returns null where there is no
 * WebGL, and every scene still paints its own 2D ground underneath.
 */
import {
  AdditiveBlending,
  BufferAttribute,
  BufferGeometry,
  CanvasTexture,
  Color,
  Mesh,
  MeshBasicMaterial,
  NearestFilter,
  OrthographicCamera,
  PlaneGeometry,
  Points,
  PointsMaterial,
  RepeatWrapping,
  Scene,
  ShaderMaterial,
  Texture,
  WebGLRenderer,
} from "three";
import type { Land } from "../net/protocol";
import { Chase, Tween, seconds } from "../engine/motion";
import { farBand, glowTexture, midBand, nearBand, type Band } from "./skyline";

export type Mood = "title" | "lands" | "map" | "quest" | "result";

const SKY_VERT = /* glsl */ `
varying vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = vec4(position.xy, 0.0, 1.0);
}`;

/**
 * A vertical ramp with a band of light where the harbour would be, quantised
 * to sixteen steps per channel. The banding is the point: a smooth gradient
 * reads as modern, and this screen is pretending to be a cartridge.
 */
const SKY_FRAG = /* glsl */ `
precision mediump float;
varying vec2 vUv;
uniform vec3 uTop;
uniform vec3 uBottom;
uniform vec3 uGlow;
uniform float uTime;
uniform float uHorizon;
void main() {
  float t = vUv.y;
  vec3 col = mix(uBottom, uTop, t);
  float band = exp(-pow((t - uHorizon) * 6.0, 2.0));
  col += uGlow * band * (0.30 + 0.06 * sin(uTime * 0.7));
  col = floor(col * 16.0 + 0.5) / 16.0;
  gl_FragColor = vec4(col, 1.0);
}`;

/** Per-land sky. Rust burns orange over the harbour; Go is colder and greener. */
const SKY: Record<Land, { top: number; bottom: number; glow: number }> = {
  rust: { top: 0x161e50, bottom: 0x2c1a1e, glow: 0xf27828 },
  go: { top: 0x111c3c, bottom: 0x122c34, glow: 0x50d8f8 },
};

/**
 * How each screen wants the city to behave. `drift` is how fast the bands
 * scroll, `lift` moves the whole city up or down the frame, `dim` is how far
 * it gets out of the way of the panels in front of it.
 *
 * The quest screen is the interesting one: it is where somebody is trying to
 * think, so the city nearly stops and nearly goes dark. Motion behind text is
 * a tax on reading it.
 */
const MOODS: Record<Mood, { drift: number; lift: number; dim: number }> = {
  title: { drift: 1, lift: 0, dim: 1 },
  lands: { drift: 0.7, lift: -0.06, dim: 0.85 },
  map: { drift: 0.35, lift: -0.18, dim: 0.55 },
  quest: { drift: 0.08, lift: -0.3, dim: 0.28 },
  result: { drift: 1.4, lift: -0.04, dim: 0.95 },
};

function bandTexture(band: Band): Texture {
  const tex = new CanvasTexture(band.canvas);
  tex.wrapS = RepeatWrapping;
  tex.magFilter = NearestFilter;
  tex.minFilter = NearestFilter;
  tex.generateMipmaps = false;
  return tex;
}

function starField(count: number, size: number, z: number, seedOffset: number): Points {
  const positions = new Float32Array(count * 3);
  // Deterministic, like the skyline: a star field that reshuffled on every
  // reload would make two screenshots of one screen differ.
  let s = (0x2545 + seedOffset) >>> 0;
  const next = () => ((s = (s * 1664525 + 1013904223) >>> 0), s / 0x100000000);
  for (let i = 0; i < count; i++) {
    positions[i * 3] = next() * 2 - 1;
    // Kept to the upper half: stars below the rooftops are streetlights, and
    // the near band already has those.
    positions[i * 3 + 1] = next() * 1.2 - 0.1;
    positions[i * 3 + 2] = z;
  }
  const geo = new BufferGeometry();
  geo.setAttribute("position", new BufferAttribute(positions, 3));
  const mat = new PointsMaterial({
    size,
    sizeAttenuation: false,
    color: new Color(0xfcecc8),
    transparent: true,
    opacity: 0.7,
    blending: AdditiveBlending,
    depthTest: false,
  });
  return new Points(geo, mat);
}

interface Layer {
  mesh: Mesh;
  tex: Texture;
  mat: MeshBasicMaterial;
  /** Relative scroll speed. The near band moves furthest — that is parallax. */
  speed: number;
  band: Band;
}

export class Backdrop {
  private readonly scene = new Scene();
  private readonly camera = new OrthographicCamera(-1, 1, 1, -1, -10, 10);
  private readonly sky: ShaderMaterial;
  private readonly layers: Layer[] = [];
  private readonly stars: Points[] = [];
  private readonly glow: Mesh;
  private readonly glowMat: MeshBasicMaterial;
  private glowTween = new Tween(1.2, 0, true);

  private t = 0;
  private scroll = 0;
  private land: Land = "rust";
  private mood: Mood = "title";
  /** Every mood change is eased, so a scene change does not snap the city. */
  private readonly drift = new Chase(MOODS.title.drift, "scene");
  private readonly lift = new Chase(MOODS.title.lift, "scene");
  private readonly dim = new Chase(MOODS.title.dim, "scene");
  private readonly skyMix = new Chase(0, "scene");
  private skyFrom: Land = "rust";

  static create(canvas: HTMLCanvasElement): Backdrop | null {
    try {
      const renderer = new WebGLRenderer({ canvas, antialias: false, alpha: false });
      return new Backdrop(renderer);
    } catch {
      // No WebGL, a blocked context, or a headless run without a GPU. Every
      // scene draws its own 2D ground, so the game is merely flatter.
      return null;
    }
  }

  private constructor(private readonly renderer: WebGLRenderer) {
    this.sky = new ShaderMaterial({
      vertexShader: SKY_VERT,
      fragmentShader: SKY_FRAG,
      depthTest: false,
      uniforms: {
        uTop: { value: new Color(SKY.rust.top) },
        uBottom: { value: new Color(SKY.rust.bottom) },
        uGlow: { value: new Color(SKY.rust.glow) },
        uTime: { value: 0 },
        uHorizon: { value: 0.34 },
      },
    });
    const skyQuad = new Mesh(new PlaneGeometry(2, 2), this.sky);
    skyQuad.frustumCulled = false;
    skyQuad.renderOrder = 0;
    this.scene.add(skyQuad);

    const far = starField(200, 2, -2, 11);
    const near = starField(70, 3, -1.5, 77);
    far.renderOrder = 1;
    near.renderOrder = 1;
    this.stars.push(far, near);
    this.scene.add(far, near);

    // Back to front, each moving further than the one behind it.
    const bands: Array<[Band, number, number]> = [
      [farBand(), 0.012, 0x6d7ab2],
      [midBand(), 0.035, 0xffffff],
      [nearBand(), 0.085, 0xffffff],
    ];
    let order = 2;
    for (const [band, speed, tint] of bands) {
      const tex = bandTexture(band);
      const mat = new MeshBasicMaterial({
        map: tex,
        transparent: true,
        depthTest: false,
        color: new Color(tint),
      });
      const mesh = new Mesh(new PlaneGeometry(2, 2), mat);
      mesh.frustumCulled = false;
      mesh.renderOrder = order++;
      this.scene.add(mesh);
      this.layers.push({ mesh, tex, mat, speed, band });
    }

    this.glowMat = new MeshBasicMaterial({
      map: new CanvasTexture(glowTexture()),
      transparent: true,
      blending: AdditiveBlending,
      depthTest: false,
      opacity: 0,
      color: new Color(0xf8d030),
    });
    this.glow = new Mesh(new PlaneGeometry(2, 2), this.glowMat);
    this.glow.frustumCulled = false;
    this.glow.renderOrder = 20;
    this.scene.add(this.glow);

    this.renderer.setClearColor(0x0b1030, 1);
    this.applyMood(true);
  }

  // -- what a scene says to it ---------------------------------------------

  setMood(mood: Mood, land: Land = this.land): void {
    if (mood === this.mood && land === this.land) return;
    if (land !== this.land) {
      this.skyFrom = this.land;
      this.skyMix.snap(0);
      this.skyMix.to(1);
      this.land = land;
    }
    this.mood = mood;
    this.applyMood(false);
  }

  private applyMood(instant: boolean): void {
    const m = MOODS[this.mood];
    if (instant) {
      this.drift.snap(m.drift);
      this.lift.snap(m.lift);
      this.dim.snap(m.dim);
      this.skyMix.snap(1);
    } else {
      this.drift.to(m.drift);
      this.lift.to(m.lift);
      this.dim.to(m.dim);
    }
  }

  /** The fanfare: a bloom-free additive flash, thrown once and left to decay. */
  pulse(colour = 0xf8d030): void {
    this.glowMat.color.setHex(colour);
    this.glowTween = new Tween(seconds("verdict") * 2.4);
  }

  // -- the frame -----------------------------------------------------------

  resize(dw: number, dh: number): void {
    this.renderer.setPixelRatio(1);
    // `false` so three does not write a CSS size back onto the element — the
    // canvas is already stretched to the window by the stylesheet, and the
    // backing store is the only thing that should follow the layout.
    this.renderer.setSize(dw, dh, false);
    const aspect = Math.max(0.2, dw / Math.max(1, dh));
    for (const l of this.layers) {
      // Repeat across, never up: the bands are placed by their mesh, so the
      // texture never stretches vertically and the buildings stay square.
      l.tex.repeat.set(aspect * 1.15, 1);
      const h = l.band.height;
      l.mesh.scale.set(1, h * 0.5, 1);
    }
  }

  update(dt: number): void {
    this.t += dt;
    this.drift.update(dt);
    this.lift.update(dt);
    this.dim.update(dt);
    this.skyMix.update(dt);
    this.glowTween.update(dt);
    this.scroll += dt * this.drift.value;

    const mix = this.skyMix.value;
    const from = SKY[this.skyFrom];
    const to = SKY[this.land];
    const u = this.sky.uniforms;
    (u.uTop.value as Color).setHex(from.top).lerp(new Color(to.top), mix);
    (u.uBottom.value as Color).setHex(from.bottom).lerp(new Color(to.bottom), mix);
    (u.uGlow.value as Color).setHex(from.glow).lerp(new Color(to.glow), mix);
    u.uTime.value = this.t;
    u.uHorizon.value = 0.34 + this.lift.value * 0.5;

    const dim = this.dim.value;
    for (const l of this.layers) {
      l.tex.offset.x = this.scroll * l.speed;
      l.mat.opacity = dim;
      // The bands sink together when a screen wants them out of the way, and
      // the nearest sinks furthest, which keeps the parallax legible even at
      // a mood where the city is nearly gone.
      l.mesh.position.y = l.band.base + this.lift.value * (0.6 + l.speed * 6);
    }
    for (const s of this.stars) {
      (s.material as PointsMaterial).opacity = 0.7 * dim;
      s.position.x = Math.sin(this.t * 0.05) * 0.01;
    }

    // The glow grows and fades on the arrival curve, so it lands rather than
    // swelling — a fanfare that ramps up reads as a loading bar.
    const g = this.glowTween;
    this.glowMat.opacity = g.finished ? 0 : (1 - g.raw) * 0.85;
    const scale = 0.35 + g.out * 1.5;
    this.glow.scale.set(scale, scale, 1);
  }

  render(): void {
    this.renderer.render(this.scene, this.camera);
  }

  dispose(): void {
    for (const l of this.layers) {
      l.tex.dispose();
      l.mat.dispose();
      l.mesh.geometry.dispose();
    }
    this.glowMat.map?.dispose();
    this.glowMat.dispose();
    this.sky.dispose();
    this.renderer.dispose();
  }
}
