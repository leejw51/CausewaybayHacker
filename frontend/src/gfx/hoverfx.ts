/**
 * The street under the cursor, lit from the ground.
 *
 * The overworld camera looks almost straight down (`mode7.ts`, a six-degree
 * tilt), so anything that stands *up* off the plane is seen end-on and
 * vanishes. Everything here therefore lies *in* the plane, on the painting,
 * where the camera can see it: a pool of light, a pulsing ring, a shockwave
 * that keeps leaving it, a slow wheel of rays, and sparks spiralling out and
 * rising toward the lens — rising is the one vertical move that reads from
 * above, because a spark coming closer grows.
 *
 * Additive, depth-test off, drawn after the ground: it brightens the street
 * rather than covering it, and the 2D coin is still painted on top.
 */
import {
  AdditiveBlending,
  BufferAttribute,
  BufferGeometry,
  CanvasTexture,
  CircleGeometry,
  Color,
  Group,
  Mesh,
  MeshBasicMaterial,
  Points,
  PointsMaterial,
  RingGeometry,
  type Texture,
} from "three";

const SPARKS = 48;

/** A soft round dot, white at the middle and nothing at the rim. */
function glowTexture(): Texture {
  const c = document.createElement("canvas");
  c.width = c.height = 64;
  const g = c.getContext("2d")!;
  const grad = g.createRadialGradient(32, 32, 0, 32, 32, 32);
  grad.addColorStop(0, "rgba(255,255,255,1)");
  grad.addColorStop(0.35, "rgba(255,255,255,0.55)");
  grad.addColorStop(1, "rgba(255,255,255,0)");
  g.fillStyle = grad;
  g.fillRect(0, 0, 64, 64);
  return new CanvasTexture(c);
}

/** Twelve soft rays from the centre, fading out toward the rim. */
function raysTexture(): Texture {
  const c = document.createElement("canvas");
  c.width = c.height = 128;
  const g = c.getContext("2d")!;
  g.translate(64, 64);
  for (let i = 0; i < 12; i++) {
    g.rotate((Math.PI * 2) / 12);
    const grad = g.createLinearGradient(0, 0, 0, -64);
    grad.addColorStop(0, "rgba(255,255,255,0.9)");
    grad.addColorStop(1, "rgba(255,255,255,0)");
    g.fillStyle = grad;
    g.beginPath();
    g.moveTo(-3, 0);
    g.lineTo(-9, -64);
    g.lineTo(9, -64);
    g.lineTo(3, 0);
    g.fill();
  }
  return new CanvasTexture(c);
}

function additive(color: number, map?: Texture): MeshBasicMaterial {
  return new MeshBasicMaterial({
    color: new Color(color),
    map: map ?? null,
    transparent: true,
    opacity: 0,
    blending: AdditiveBlending,
    depthTest: false,
    depthWrite: false,
  });
}

export class HoverFx {
  readonly group = new Group();
  private readonly glow = glowTexture();
  private readonly raysTex = raysTexture();
  private readonly pool: Mesh;
  private readonly ring: Mesh;
  private readonly wave: Mesh;
  private readonly rays: Mesh;
  private readonly sparks: Points;
  private readonly sparkPos = new Float32Array(SPARKS * 3);
  private readonly seeds = Array.from({ length: SPARKS }, () => ({
    phase: Math.random(),
    angle: Math.random() * Math.PI * 2,
    spin: 0.6 + Math.random() * 1.4,
    reach: 0.6 + Math.random() * 0.8,
  }));
  /** How lit the effect is now, chasing `want`: it fades in and out. */
  private level = 0;
  private want = 0;
  private t = 0;
  private x = 0;
  private z = 0;
  private r = 0.03;

  constructor() {
    const flat = -Math.PI / 2;
    this.pool = new Mesh(new CircleGeometry(1, 40), additive(0x3fd6ff, this.glow));
    this.ring = new Mesh(new RingGeometry(0.82, 1, 56), additive(0x7ff0ff));
    this.wave = new Mesh(new RingGeometry(0.9, 1, 56), additive(0xffd34a));
    this.rays = new Mesh(new CircleGeometry(1, 40), additive(0xffc23a, this.raysTex));
    for (const m of [this.pool, this.rays, this.wave, this.ring]) {
      m.rotation.x = flat;
      m.frustumCulled = false;
      m.renderOrder = 2;
      this.group.add(m);
    }
    const geo = new BufferGeometry();
    geo.setAttribute("position", new BufferAttribute(this.sparkPos, 3));
    this.sparks = new Points(
      geo,
      new PointsMaterial({
        color: new Color(0xfff2a8),
        map: this.glow,
        size: 0.02,
        sizeAttenuation: true,
        transparent: true,
        opacity: 0,
        blending: AdditiveBlending,
        depthTest: false,
        depthWrite: false,
      }),
    );
    this.sparks.frustumCulled = false;
    this.sparks.renderOrder = 3;
    this.group.add(this.sparks);
    this.group.visible = false;
  }

  /**
   * Light the street at world `(x, z)`, a coin of world radius `r`, at
   * `strength` 0..1 — or put it out with `null`. A move to a new street jumps
   * there; only the brightness is eased.
   */
  set(at: { x: number; z: number; r: number; strength: number } | null): void {
    if (!at) {
      this.want = 0;
      return;
    }
    if (Math.hypot(at.x - this.x, at.z - this.z) > 1e-6) this.t = 0;
    this.x = at.x;
    this.z = at.z;
    this.r = at.r;
    this.want = at.strength;
  }

  update(dt: number, calm: boolean): void {
    this.t += dt;
    const k = 1 - Math.exp(-dt * 10);
    this.level += (this.want - this.level) * k;
    this.group.visible = this.level > 0.01;
    if (!this.group.visible) return;
    const L = this.level;
    const r = this.r;
    const t = this.t;
    const at = (m: Mesh, scale: number, opacity: number, y = 0.002): void => {
      m.position.set(this.x, y, this.z);
      m.scale.set(scale, scale, scale);
      (m.material as MeshBasicMaterial).opacity = opacity;
    };
    const breathe = calm ? 1 : 1 + 0.08 * Math.sin(t * 5);
    at(this.pool, r * 3.2 * breathe, 0.55 * L);
    at(this.ring, r * 1.55 * breathe, 0.9 * L, 0.003);
    // The shockwave leaves every 1.1 s and fades as it grows.
    const w = calm ? 0.5 : (t % 1.1) / 1.1;
    at(this.wave, r * (1.4 + 2.6 * w), 0.8 * L * (1 - w), 0.003);
    at(this.rays, r * 3.6, 0.35 * L, 0.0025);
    this.rays.rotation.z = calm ? 0 : t * 0.6;

    // Sparks: each on its own loop, spiralling out from the coin's rim and
    // rising toward the camera as it goes, so it grows on its way out.
    for (let i = 0; i < SPARKS; i++) {
      const s = this.seeds[i];
      const p = calm ? s.phase : (s.phase + t * 0.55) % 1;
      const a = s.angle + p * s.spin * 2.2;
      const d = r * (1.1 + 2.6 * p * s.reach);
      this.sparkPos[i * 3] = this.x + Math.cos(a) * d;
      this.sparkPos[i * 3 + 1] = 0.004 + p * r * 6;
      this.sparkPos[i * 3 + 2] = this.z + Math.sin(a) * d;
    }
    const pm = this.sparks.material as PointsMaterial;
    pm.size = r * 0.9;
    pm.opacity = (calm ? 0.4 : 0.85) * L;
    (this.sparks.geometry.getAttribute("position") as BufferAttribute).needsUpdate = true;
  }

  dispose(): void {
    for (const m of [this.pool, this.ring, this.wave, this.rays]) {
      m.geometry.dispose();
      (m.material as MeshBasicMaterial).dispose();
    }
    this.sparks.geometry.dispose();
    (this.sparks.material as PointsMaterial).dispose();
    this.glow.dispose();
    this.raysTex.dispose();
  }
}
