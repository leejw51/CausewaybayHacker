/**
 * The overworld's parallax, in three.js.
 *
 * SPEC §10 gives three.js the map's parallax layers and effects, and gives the
 * quest screen to a 2D overlay. This is that layer and nothing else: a sky, two
 * drifting star fields at different depths, and a haze in the land's colour.
 * It draws on its own canvas *behind* the pixel-art one, so the nodes, the
 * paths and the stamps stay crisp 2D while the sky moves.
 *
 * It is entirely optional. A browser with no WebGL context gets `null` from
 * `MapFx.create` and the map falls back to its flat backdrop, because losing
 * the sky is not a reason to lose the game.
 */
import {
  AdditiveBlending,
  BufferAttribute,
  BufferGeometry,
  Color,
  Mesh,
  OrthographicCamera,
  PlaneGeometry,
  Points,
  PointsMaterial,
  Scene,
  ShaderMaterial,
  WebGLRenderer,
} from "three";
import type { Land } from "../net/protocol";

const SKY_VERT = /* glsl */ `
varying vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = vec4(position.xy, 0.0, 1.0);
}`;

/**
 * A two-stop vertical ramp with a horizontal band of light where the street
 * would be. Banded on purpose — a smooth gradient reads as modern, and this
 * screen is pretending to be a cartridge.
 */
const SKY_FRAG = /* glsl */ `
precision mediump float;
varying vec2 vUv;
uniform vec3 uTop;
uniform vec3 uBottom;
uniform vec3 uGlow;
uniform float uTime;
void main() {
  float t = vUv.y;
  vec3 col = mix(uBottom, uTop, t);
  float band = exp(-pow((t - 0.32) * 5.0, 2.0));
  col += uGlow * band * (0.35 + 0.08 * sin(uTime * 0.8));
  // Quantise to sixteen steps per channel: the colour depth of the era.
  col = floor(col * 16.0) / 16.0;
  gl_FragColor = vec4(col, 1.0);
}`;

const PALETTE: Record<Land, { top: number; bottom: number; glow: number }> = {
  rust: { top: 0x140c2a, bottom: 0x5c2a10, glow: 0xf27828 },
  go: { top: 0x0a1430, bottom: 0x104858, glow: 0x50d8f8 },
};

function starField(count: number, size: number, depth: number): Points {
  const positions = new Float32Array(count * 3);
  for (let i = 0; i < count; i++) {
    positions[i * 3] = Math.random() * 2 - 1;
    positions[i * 3 + 1] = Math.random() * 2 - 1;
    positions[i * 3 + 2] = depth;
  }
  const geo = new BufferGeometry();
  geo.setAttribute("position", new BufferAttribute(positions, 3));
  const mat = new PointsMaterial({
    size,
    sizeAttenuation: false,
    color: new Color(0xfcecc8),
    transparent: true,
    opacity: 0.75,
    blending: AdditiveBlending,
    depthTest: false,
  });
  return new Points(geo, mat);
}

export class MapFx {
  private readonly scene = new Scene();
  private readonly camera = new OrthographicCamera(-1, 1, 1, -1, -10, 10);
  private readonly sky: ShaderMaterial;
  private readonly near: Points;
  private readonly far: Points;

  static create(canvas: HTMLCanvasElement): MapFx | null {
    try {
      const renderer = new WebGLRenderer({ canvas, antialias: false, alpha: false });
      return new MapFx(renderer);
    } catch {
      return null;
    }
  }

  private constructor(private readonly renderer: WebGLRenderer) {
    this.sky = new ShaderMaterial({
      vertexShader: SKY_VERT,
      fragmentShader: SKY_FRAG,
      depthTest: false,
      uniforms: {
        uTop: { value: new Color(PALETTE.rust.top) },
        uBottom: { value: new Color(PALETTE.rust.bottom) },
        uGlow: { value: new Color(PALETTE.rust.glow) },
        uTime: { value: 0 },
      },
    });
    const quad = new Mesh(new PlaneGeometry(2, 2), this.sky);
    quad.frustumCulled = false;
    this.scene.add(quad);

    this.far = starField(220, 2, -1);
    this.near = starField(90, 4, -0.5);
    this.scene.add(this.far, this.near);
    this.renderer.setClearColor(0x0b1030, 1);
  }

  setLand(land: Land): void {
    const p = PALETTE[land];
    (this.sky.uniforms.uTop.value as Color).setHex(p.top);
    (this.sky.uniforms.uBottom.value as Color).setHex(p.bottom);
    (this.sky.uniforms.uGlow.value as Color).setHex(p.glow);
  }

  /** Device pixels, matching the 2D canvas's backing store exactly. */
  resize(dw: number, dh: number): void {
    this.renderer.setPixelRatio(1);
    this.renderer.setSize(dw, dh, false);
  }

  /**
   * `pan` is -1..1 and comes from where the cursor is over the map, so the two
   * star layers separate as the player moves across it. Depth is the whole
   * point of a parallax; a single layer would just be wallpaper.
   */
  render(t: number, panX: number, panY: number): void {
    this.sky.uniforms.uTime.value = t;
    this.far.position.set(panX * 0.02, panY * 0.015 + Math.sin(t * 0.15) * 0.01, 0);
    this.near.position.set(panX * 0.06, panY * 0.04 + Math.sin(t * 0.21) * 0.02, 0);
    this.renderer.render(this.scene, this.camera);
  }

  dispose(): void {
    this.renderer.dispose();
  }
}
