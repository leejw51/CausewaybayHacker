// Ported from CausewaybayGolang/typescript/src/engine/particles.ts (which in turn
// carries it over from that project's love2d Lua). Kept close to the original
// so a fix made there can still be read across; Causewaybay Hacker changes are
// marked where they occur.
/**
 * The effects layer: three.js on a second canvas over the game.
 *
 * The game itself is drawn with the 2D context, and stays that way. This is
 * one transparent WebGL canvas laid over it for the things a 2D context does
 * badly — a few thousand glowing, trailing, additive particles at once —
 * and it is fed in the game's own virtual pixels, so a burst asked for at a
 * point in the scene lands on that point whatever the window is doing.
 *
 * Nothing moves on the CPU. A particle is written into a buffer once, with
 * where it started, how far it goes, when it was born and how long it lives,
 * and the vertex shader works out where it is now from the clock: an ease-out
 * along its reach, gravity on top, a wobble from its seed. A trail is the
 * same particle drawn a few more times at a few moments earlier, smaller and
 * fainter, which costs nothing but vertices. When nothing is alive the frame
 * is skipped altogether, so an idle game pays no WebGL at all.
 *
 * If WebGL is not there — or goes away — `ok` is false and the caller uses
 * the 2D sparks it always had.
 */
import {
  BufferAttribute,
  BufferGeometry,
  CustomBlending,
  DoubleSide,
  Mesh,
  NearestFilter,
  OneFactor,
  OneMinusSrcAlphaFactor,
  OrthographicCamera,
  PlaneGeometry,
  Points,
  Scene,
  ShaderMaterial,
  Texture,
  WebGLRenderer,
} from "three";

import { Particle, Plan, Ring } from "./burst";
import type { Layout } from "./layout";

/**
 * How many ghosts a trailing particle drags behind it, and how far apart in
 * time. Close enough together that a fast spark reads as a comet tail rather
 * than a string of dots; a tail is ten more vertices, which is nothing.
 */
const TRAIL = 10;
const TRAIL_DT = 0.018;
/** Particles the two pools can hold at once; the oldest is overwritten. */
const GLOW_CAP = 2400;
const PAPER_CAP = 900;
const RING_CAP = 8;

const VERT = /* glsl */ `
  attribute vec2 aOrigin;
  attribute vec2 aReach;
  attribute vec2 aTo;
  attribute vec2 aLift;
  attribute float aBirth;
  attribute float aLife;
  attribute float aSize;
  attribute vec3 aColor;
  attribute float aSeed;
  attribute float aShape;
  attribute float aTrail;
  attribute float aGravity;

  uniform float uTime;
  uniform float uScale;
  uniform float uTrailDt;
  uniform float uTrailMax;

  varying vec3 vColor;
  varying float vAlpha;
  varying float vShape;
  varying float vSeed;
  varying float vAge;
  varying float vTrail;
  varying float vT;

  // Exponential ease-out: almost all of the distance at once, then a long
  // settle — the shape of a thing thrown hard.
  float easeOutExpo(float t) { return t >= 1.0 ? 1.0 : 1.0 - pow(2.0, -10.0 * t); }
  // Exponential ease-in-out: hangs, then whips across, then lands softly.
  float easeInOutExpo(float t) {
    if (t <= 0.0) return 0.0;
    if (t >= 1.0) return 1.0;
    return t < 0.5
      ? pow(2.0, 20.0 * t - 10.0) * 0.5
      : (2.0 - pow(2.0, -20.0 * t + 10.0)) * 0.5;
  }

  void main() {
    float age = uTime - aBirth - aTrail * uTrailDt;
    float t = age / aLife;
    if (age < 0.0 || t > 1.0) {
      gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
      gl_PointSize = 0.0;
      vAlpha = 0.0;
      return;
    }
    bool coin = abs(aShape - 3.0) < 0.5;
    // The throw eases out; the second leg, if there is one, eases in and out
    // on top of it, so a coin drifts up out of the burst before it goes.
    vec2 p = aOrigin
      + aReach * easeOutExpo(t)
      + aTo * easeInOutExpo(t)
      + aLift * sin(t * 3.14159)
      + vec2(0.0, aGravity) * age * age * 0.5;
    // Only the light wobbles. Paper tumbles, a coin flies true, and a brick
    // is a brick: it goes where it was thrown.
    if (aShape < 2.5) {
      p += vec2(
        sin(age * 6.0 + aSeed * 6.2832),
        cos(age * 4.5 + aSeed * 3.1416)
      ) * 6.0 * t * (1.0 - aShape * 0.5);
    }

    // Pops up over the first tenth of its life, holds, then fades away —
    // except a coin, which is whole until the moment it lands.
    float grow = smoothstep(0.0, 0.1, t);
    float fade = coin ? 1.0 - smoothstep(0.94, 1.0, t) : 1.0 - smoothstep(0.55, 1.0, t);
    // Ghosts down the trail are smaller and fainter the further back they
    // are, tapering to nothing: a comet, not a caterpillar.
    float back = 1.0 - aTrail / (uTrailMax + 1.0);
    // A coin's tail is drawn without additive blending, so it is kept
    // stronger to read the same.
    float ghost = aTrail > 0.5 ? (coin ? back * 0.85 : back * back * 0.7) : 1.0;
    float size = aSize * grow * (0.55 + 0.45 * fade) * mix(0.25, 1.0, back);
    if (coin) size = aSize * grow * mix(0.35, 1.0, back);
    // Dust spreads as it thins: a puff is small and dense, then wide and gone.
    if (abs(aShape - 5.0) < 0.5) size = aSize * grow * mix(0.6, 1.4, t);
    // A ribbon ember only ever shrinks: it is brightest and biggest where the
    // pointer just was, and gone at the tail.
    if (aShape > 5.5) size = aSize * (1.0 - 0.6 * t) * mix(0.3, 1.0, back);

    vColor = aColor;
    vAlpha = grow * fade * ghost;
    vShape = aShape;
    vSeed = aSeed;
    vAge = age;
    vTrail = aTrail;
    vT = t;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 0.0, 1.0);
    gl_PointSize = size * uScale;
  }
`;

const FRAG = /* glsl */ `
  uniform float uAdditive;
  // The two sprite strips (Grok-drawn, art/fx_bricks.png and art/fx_dust.png)
  // and how many frames across each has. A strip that has not arrived has
  // zero frames and its shape draws the procedural stand-in instead.
  uniform sampler2D uBrick;
  uniform float uBrickFrames;
  uniform sampler2D uDust;
  uniform float uDustFrames;

  varying vec3 vColor;
  varying float vAlpha;
  varying float vShape;
  varying float vSeed;
  varying float vAge;
  varying float vTrail;
  varying float vT;

  void main() {
    if (vAlpha <= 0.001) discard;
    vec2 q = (gl_PointCoord - 0.5) * 2.0;
    float a;
    vec3 col = vColor;
    if (vShape > 5.5) {
      // The ribbon's ember: a soft disc with a hot centre, and nothing else.
      float d = length(q);
      a = smoothstep(1.0, 0.2, d);
      a = a * a + smoothstep(0.35, 0.0, d) * 0.8;
      col = mix(col, vec3(1.0), smoothstep(0.3, 0.0, d) * 0.5);
    } else if (vShape > 4.5) {
      // A puff of dust, from the strip: the frame is the particle's age, so
      // one puff plays through "dense, lobed, breaking, wisps" as it fades.
      if (uDustFrames < 0.5) {
        float d = length(q);
        a = smoothstep(1.0, 0.3, d) * 0.8;
      } else {
        // Half of them flipped, so four frames read as more than four.
        vec2 uv = vec2(vSeed > 0.5 ? 1.0 - gl_PointCoord.x : gl_PointCoord.x, 1.0 - gl_PointCoord.y);
        float f = min(uDustFrames - 1.0, floor(vT * uDustFrames));
        vec4 tx = texture2D(uDust, vec2((f + uv.x) / uDustFrames, uv.y));
        a = tx.a;
        col = mix(tx.rgb, vColor, 0.25);
      }
    } else if (vShape > 3.5) {
      // A chunk of brick, spinning as it falls.
      float rot = vSeed * 6.2832 + vAge * (4.0 + vSeed * 8.0) * (vSeed > 0.5 ? 1.0 : -1.0);
      float c = cos(rot), s = sin(rot);
      vec2 r = vec2(c * q.x - s * q.y, s * q.x + c * q.y);
      if (uBrickFrames < 0.5) {
        // No strip: a bevelled 16-bit block — lit along the top-left edge, in
        // shadow at the bottom-right, a fleck of highlight in the corner.
        float box = max(abs(r.x), abs(r.y));
        a = step(box, 0.62);
        float face = smoothstep(0.62, 0.42, box);
        float lit = smoothstep(0.0, 0.5, -(r.x + r.y));
        vec3 edge = mix(col * 0.45, mix(col, vec3(1.0), 0.45), lit);
        col = mix(edge, col, face);
        col += vec3(0.35) * smoothstep(0.25, 0.0, length(r - vec2(-0.28, -0.28))) * face;
      } else {
        // The strip's chunk, drawn in the circle the rotation stays inside of
        // (1/sqrt2 of the point) so a corner is never clipped on a turn. The
        // art is brick orange; its light and dark are kept and its hue is
        // the token's, so a deleted string breaks green.
        vec2 uv = r * 0.7071 * 0.5 + 0.5;
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) discard;
        float f = floor(vSeed * uBrickFrames);
        f = min(uBrickFrames - 1.0, f);
        vec4 tx = texture2D(uBrick, vec2((f + uv.x) / uBrickFrames, 1.0 - uv.y));
        a = tx.a;
        float lum = dot(tx.rgb, vec3(0.3, 0.59, 0.11));
        col = vColor * lum * 2.1;
      }
    } else if (vShape > 2.5 && vTrail < 0.5) {
      // A gold coin, spinning on its vertical axis: the face narrows to an
      // edge and back, darker at the rim, with a highlight up and left.
      float spin = vAge * (9.0 + vSeed * 5.0) + vSeed * 6.2832;
      float w = max(0.14, abs(cos(spin)));
      vec2 r = vec2(q.x / w, q.y);
      float d = length(r);
      a = smoothstep(1.0, 0.86, d);
      float face = smoothstep(0.8, 0.68, d);
      col = mix(vec3(0.62, 0.36, 0.05), vColor, face);
      col += vec3(1.0, 0.97, 0.8) * smoothstep(0.55, 0.0, length(r - vec2(-0.3, -0.32))) * 0.55 * face;
      col *= 0.72 + 0.28 * w;
    } else if (vShape > 2.5) {
      // The coin's tail: soft gold light, not more coins.
      float d = length(q);
      a = smoothstep(1.0, 0.1, d);
      a = a * a * 0.9;
      col = mix(vColor, vec3(1.0, 0.95, 0.7), 0.4);
    } else if (vShape < 0.5) {
      // A soft disc with a hot centre.
      float d = length(q);
      a = smoothstep(1.0, 0.15, d);
      a = a * a + smoothstep(0.4, 0.0, d) * 0.9;
      col = mix(col, vec3(1.0), smoothstep(0.35, 0.0, d) * 0.6);
    } else if (vShape < 1.5) {
      // A four-point star, turning slowly.
      float rot = vSeed * 6.2832 + vAge * (1.5 + vSeed * 2.0);
      float c = cos(rot), s = sin(rot);
      vec2 r = vec2(c * q.x - s * q.y, s * q.x + c * q.y);
      float d = length(r);
      float ang = atan(r.y, r.x);
      float lobe = pow(abs(cos(ang * 2.0)), 6.0);
      float edge = mix(0.22, 1.0, lobe);
      a = smoothstep(edge, edge * 0.45, d) + smoothstep(0.3, 0.0, d) * 0.8;
      col = mix(col, vec3(1.0), smoothstep(0.3, 0.0, d) * 0.7);
    } else {
      // A scrap of paper, spinning in the plane and flipping through it.
      float rot = vSeed * 6.2832 + vAge * (3.0 + vSeed * 6.0) * (vSeed > 0.5 ? 1.0 : -1.0);
      float c = cos(rot), s = sin(rot);
      vec2 r = vec2(c * q.x - s * q.y, s * q.x + c * q.y);
      float flip = abs(sin(vAge * (5.0 + vSeed * 4.0) + vSeed * 6.2832));
      float thick = 0.22 * max(0.1, flip);
      a = step(abs(r.x), 0.46) * step(abs(r.y), thick);
      col *= 0.65 + 0.35 * flip;
    }
    a = clamp(a, 0.0, 1.0) * vAlpha;
    // Premultiplied out, so the canvas composites over the game correctly.
    gl_FragColor = vec4(col * a, a * (1.0 - uAdditive * 0.35));
  }
`;

const RING_VERT = /* glsl */ `
  uniform vec2 uCenter;
  uniform float uRadius;
  varying vec2 vQ;
  void main() {
    vQ = position.xy;
    vec2 p = uCenter + position.xy * uRadius * 1.25;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 0.0, 1.0);
  }
`;

const RING_FRAG = /* glsl */ `
  uniform vec3 uColor;
  uniform float uAlpha;
  uniform float uGlow;
  uniform float uWidth;
  varying vec2 vQ;
  void main() {
    float d = length(vQ) * 1.25;
    float a;
    if (uGlow > 0.5) {
      a = smoothstep(1.0, 0.0, d);
      a = a * a * 0.9 + smoothstep(0.4, 0.0, d) * 0.5;
    } else {
      float edge = smoothstep(uWidth, 0.0, abs(d - 1.0));
      a = edge * edge + smoothstep(1.0, 0.55, d) * 0.12;
    }
    a *= uAlpha;
    if (a <= 0.002) discard;
    vec3 col = mix(uColor, vec3(1.0), 0.25 * a);
    gl_FragColor = vec4(col * a, a * 0.6);
  }
`;

interface Live {
  t: number;
  ring: Ring;
  mesh: Mesh<PlaneGeometry, ShaderMaterial>;
}

/** Exponential ease-out for the shockwave: nearly all the way out at once. */
function easeOutExpo(t: number): number {
  return t >= 1 ? 1 : 1 - Math.pow(2, -10 * t);
}

/** A ring of particle slots on the GPU, one draw call. */
class Pool {
  readonly points: Points<BufferGeometry, ShaderMaterial>;
  private readonly cap: number;
  private readonly per: number;
  private head = 0;
  /** The clock when the last particle written here dies. */
  aliveUntil = -1;

  private readonly origin: BufferAttribute;
  private readonly reach: BufferAttribute;
  private readonly to: BufferAttribute;
  private readonly lift: BufferAttribute;
  private readonly birth: BufferAttribute;
  private readonly life: BufferAttribute;
  private readonly size: BufferAttribute;
  private readonly color: BufferAttribute;
  private readonly seed: BufferAttribute;
  private readonly shape: BufferAttribute;
  private readonly trail: BufferAttribute;
  private readonly gravity: BufferAttribute;
  private readonly all: BufferAttribute[];

  constructor(cap: number, trail: number, additive: boolean) {
    this.cap = cap;
    this.per = 1 + trail;
    const n = cap * this.per;
    const geo = new BufferGeometry();
    const make = (items: number): BufferAttribute => {
      const a = new BufferAttribute(new Float32Array(n * items), items);
      a.setUsage(35048); // DynamicDrawUsage
      return a;
    };
    this.origin = make(2);
    this.reach = make(2);
    this.to = make(2);
    this.lift = make(2);
    this.birth = make(1);
    this.life = make(1);
    this.size = make(1);
    this.color = make(3);
    this.seed = make(1);
    this.shape = make(1);
    this.trail = make(1);
    this.gravity = make(1);
    this.all = [
      this.origin,
      this.reach,
      this.to,
      this.lift,
      this.birth,
      this.life,
      this.size,
      this.color,
      this.seed,
      this.shape,
      this.trail,
      this.gravity,
    ];
    // A dead particle is one whose birth is far in the past; every slot
    // starts that way.
    (this.birth.array as Float32Array).fill(-1e6);
    (this.life.array as Float32Array).fill(1);
    geo.setAttribute("aOrigin", this.origin);
    geo.setAttribute("aReach", this.reach);
    geo.setAttribute("aTo", this.to);
    geo.setAttribute("aLift", this.lift);
    geo.setAttribute("aBirth", this.birth);
    geo.setAttribute("aLife", this.life);
    geo.setAttribute("aSize", this.size);
    geo.setAttribute("aColor", this.color);
    geo.setAttribute("aSeed", this.seed);
    geo.setAttribute("aShape", this.shape);
    geo.setAttribute("aTrail", this.trail);
    geo.setAttribute("aGravity", this.gravity);
    // three wants a `position` to count vertices by; the shader ignores it.
    geo.setAttribute("position", new BufferAttribute(new Float32Array(n * 3), 3));
    geo.boundingSphere = null;

    const mat = new ShaderMaterial({
      vertexShader: VERT,
      fragmentShader: FRAG,
      uniforms: {
        uTime: { value: 0 },
        uScale: { value: 1 },
        uTrailDt: { value: TRAIL_DT },
        uTrailMax: { value: Math.max(1, trail) },
        uAdditive: { value: additive ? 1 : 0 },
        uBrick: { value: null },
        uBrickFrames: { value: 0 },
        uDust: { value: null },
        uDustFrames: { value: 0 },
      },
      transparent: true,
      depthTest: false,
      depthWrite: false,
      blending: CustomBlending,
      blendSrc: OneFactor,
      blendDst: additive ? OneFactor : OneMinusSrcAlphaFactor,
    });
    this.points = new Points(geo, mat);
    this.points.frustumCulled = false;
  }

  /** Write a particle into the next slot, with its ghosts behind it. */
  emit(p: Particle, now: number): void {
    const slot = this.head;
    this.head = (this.head + 1) % this.cap;
    const base = slot * this.per;
    const born = now + p.delay;
    for (let i = 0; i < this.per; i++) {
      const v = base + i;
      this.origin.setXY(v, p.x, p.y);
      this.reach.setXY(v, p.dx, p.dy);
      this.to.setXY(v, p.tox, p.toy);
      this.lift.setXY(v, p.liftx, p.lifty);
      // A particle without a trail still owns its ghost slots; they are
      // written dead rather than drawn on top of it.
      this.birth.setX(v, i > 0 && !p.trail ? -1e6 : born);
      this.life.setX(v, p.life);
      this.size.setX(v, p.size);
      this.color.setXYZ(v, p.color[0], p.color[1], p.color[2]);
      this.seed.setX(v, p.seed);
      this.shape.setX(v, p.shape);
      this.trail.setX(v, p.trail ? i : 0);
      this.gravity.setX(v, p.gravity);
    }
    for (const a of this.all) {
      a.addUpdateRange(base * a.itemSize, this.per * a.itemSize);
      a.needsUpdate = true;
    }
    const end = born + p.life + this.per * TRAIL_DT;
    if (end > this.aliveUntil) this.aliveUntil = end;
  }

  set(time: number, scale: number): void {
    this.points.material.uniforms.uTime.value = time;
    this.points.material.uniforms.uScale.value = scale;
  }

  /** Hand this pool one of the sprite strips. */
  sheet(which: "brick" | "dust", tex: Texture, frames: number): void {
    const u = this.points.material.uniforms;
    if (which === "brick") {
      u.uBrick.value = tex;
      u.uBrickFrames.value = frames;
    } else {
      u.uDust.value = tex;
      u.uDustFrames.value = frames;
    }
  }
}

export class Particles {
  /** False when there is no WebGL to be had; the caller draws 2D sparks then. */
  ok = false;

  private renderer: WebGLRenderer | null = null;
  private readonly scene = new Scene();
  private readonly camera = new OrthographicCamera(0, 1, 0, 1, -1, 1);
  private glow!: Pool;
  private paper!: Pool;
  private readonly rings: Live[] = [];
  private readonly ringMeshes: Mesh<PlaneGeometry, ShaderMaterial>[] = [];
  private readonly pending: Array<{ at: number; ring: Ring }> = [];
  private scale = 1;
  private clock = 0;
  private cleared = true;

  constructor(canvas: HTMLCanvasElement) {
    try {
      this.renderer = new WebGLRenderer({
        canvas,
        alpha: true,
        antialias: false,
        premultipliedAlpha: true,
        powerPreference: "low-power",
        failIfMajorPerformanceCaveat: false,
      });
    } catch {
      this.renderer = null;
      return;
    }
    this.renderer.setClearColor(0x000000, 0);
    this.renderer.autoClear = true;
    // Paper has no trail, but the coins share its pool — opaque things, both
    // — and a coin does.
    this.glow = new Pool(GLOW_CAP, TRAIL, true);
    this.paper = new Pool(PAPER_CAP, TRAIL, false);
    this.scene.add(this.paper.points);
    this.scene.add(this.glow.points);
    const quad = new PlaneGeometry(2, 2);
    for (let i = 0; i < RING_CAP; i++) {
      const mesh = new Mesh(
        quad,
        new ShaderMaterial({
          vertexShader: RING_VERT,
          fragmentShader: RING_FRAG,
          uniforms: {
            uCenter: { value: [0, 0] },
            uRadius: { value: 1 },
            uColor: { value: [1, 1, 1] },
            uAlpha: { value: 0 },
            uGlow: { value: 0 },
            uWidth: { value: 0.18 },
          },
          transparent: true,
          depthTest: false,
          depthWrite: false,
          side: DoubleSide,
          blending: CustomBlending,
          blendSrc: OneFactor,
          blendDst: OneFactor,
        }),
      );
      mesh.visible = false;
      mesh.frustumCulled = false;
      this.ringMeshes.push(mesh);
      this.scene.add(mesh);
    }
    canvas.addEventListener("webglcontextlost", (ev) => {
      ev.preventDefault();
      this.ok = false;
      canvas.hidden = true;
    });
    canvas.addEventListener("webglcontextrestored", () => {
      this.ok = true;
      canvas.hidden = false;
    });
    this.ok = true;
  }

  /** Match the game canvas: same device pixels, same virtual coordinates. */
  resize(layout: Layout): void {
    if (!this.renderer) return;
    this.renderer.setSize(layout.dw, layout.dh, false);
    // The camera sees virtual pixels, y down, with the letterbox outside it.
    this.camera.left = -layout.ox / layout.scale;
    this.camera.right = (layout.dw - layout.ox) / layout.scale;
    this.camera.top = -layout.oy / layout.scale;
    this.camera.bottom = (layout.dh - layout.oy) / layout.scale;
    this.camera.updateProjectionMatrix();
    this.scale = layout.scale;
  }

  /**
   * Give the brick and dust shapes their pixel art. Causewaybay Hacker
   * addition: the strips are drawn by Grok and cut by `art/tools/strip.py`,
   * and until they arrive (or if they never do) the two shapes draw a
   * procedural stand-in, so nothing here waits on a fetch.
   *
   * Nearest-neighbour both ways: a 48-pixel chunk blown up on a point sprite
   * is meant to show its pixels, the same as every other sprite in the game.
   */
  sheet(which: "brick" | "dust", img: HTMLImageElement, frames: number): void {
    if (!this.renderer) return;
    const tex = new Texture(img);
    tex.magFilter = NearestFilter;
    tex.minFilter = NearestFilter;
    tex.generateMipmaps = false;
    tex.flipY = false;
    tex.needsUpdate = true;
    this.glow.sheet(which, tex, frames);
    this.paper.sheet(which, tex, frames);
  }

  /** Everything in a plan, starting now. */
  play(plan: Plan): void {
    if (!this.ok) return;
    for (const p of plan.particles) {
      // Light (0, 1, 6) is additive and lives in the glow pool; everything
      // solid — paper, coins, bricks, dust — is composited over the page.
      (p.shape >= 2 && p.shape <= 5 ? this.paper : this.glow).emit(p, this.clock);
    }
    for (const ring of plan.rings) this.pending.push({ at: this.clock + ring.delay, ring });
  }

  /** Whether anything is still alive — for a caller that fades its canvas. */
  get busy(): boolean {
    return (
      this.rings.length > 0 ||
      this.pending.length > 0 ||
      this.clock < this.glow.aliveUntil ||
      this.clock < this.paper.aliveUntil
    );
  }

  private startRing(ring: Ring): void {
    let mesh = this.ringMeshes.find((m) => !m.visible);
    if (!mesh) {
      // All busy: the oldest gives way.
      const oldest = this.rings.shift();
      if (!oldest) return;
      mesh = oldest.mesh;
    }
    const u = mesh.material.uniforms;
    u.uCenter.value = [ring.x, ring.y];
    u.uColor.value = [ring.color[0], ring.color[1], ring.color[2]];
    u.uGlow.value = ring.glow ? 1 : 0;
    u.uWidth.value = ring.glow ? 0 : 0.16;
    mesh.visible = true;
    this.rings.push({ t: 0, ring, mesh });
  }

  /** Advance the clock and draw, if there is anything to draw. */
  frame(dt: number): void {
    if (!this.renderer || !this.ok) return;
    this.clock += dt;

    for (let i = this.pending.length - 1; i >= 0; i--) {
      if (this.pending[i].at <= this.clock) {
        this.startRing(this.pending[i].ring);
        this.pending.splice(i, 1);
      }
    }
    for (let i = this.rings.length - 1; i >= 0; i--) {
      const live = this.rings[i];
      live.t += dt;
      const k = Math.min(1, live.t / live.ring.life);
      const u = live.mesh.material.uniforms;
      if (k >= 1) {
        live.mesh.visible = false;
        this.rings.splice(i, 1);
        continue;
      }
      u.uRadius.value = Math.max(1, live.ring.radius * easeOutExpo(k));
      // A glow is brightest at once and gone quickly; a ring fades as it thins.
      u.uAlpha.value = live.ring.glow ? (1 - k) * (1 - k) : 1 - k * k;
    }

    const busy =
      this.rings.length > 0 ||
      this.pending.length > 0 ||
      this.clock < this.glow.aliveUntil ||
      this.clock < this.paper.aliveUntil;
    if (!busy) {
      // One clear after the last particle dies, then nothing until the next.
      if (!this.cleared) {
        this.renderer.clear();
        this.cleared = true;
      }
      return;
    }
    this.cleared = false;
    this.glow.set(this.clock, this.scale);
    this.paper.set(this.clock, this.scale);
    this.renderer.render(this.scene, this.camera);
  }
}
