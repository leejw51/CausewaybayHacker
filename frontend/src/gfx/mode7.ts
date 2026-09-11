/**
 * The overworld, on the GPU.
 *
 * Until this round the three.js layer was wallpaper: a sky and three scrolling
 * bands behind a screen that was entirely flat 2D. The map is the one screen
 * where that is a waste, because the map *is* a picture of a place and the
 * era's answer to "make a picture of a place feel like a world" was Mode 7 —
 * put the texture on a plane, put a camera above it, and move the camera.
 *
 * What is deliberately *not* done here is a steep tilt. `map_rust.jpg` is an
 * axonometric painting: the projection is already baked into the pixels, and
 * laying it flat at 25 degrees produces a photograph of a map lying on a table
 * rather than a world. So the plane is tilted about eleven degrees — enough
 * that the near edge is wider than the far one and the ground has somewhere to
 * go — and the energy goes into the *camera move* instead: it leans toward the
 * street under the cursor, and pushes into it on the expo curve when you go in.
 *
 * Two rules this module lives by:
 *
 *   - **It is scissored.** The map is rendered into the plate rectangle only,
 *     as a second pass over the sky, so the ground does not appear behind the
 *     header, the footer or the info plate.
 *   - **It owns the projection.** `project()` is the only place that turns a
 *     node's 0..1 map coordinate into a virtual pixel, and both the drawing and
 *     the hit-testing go through it. The one thing that must never drift apart
 *     on this screen is where a node is drawn and where it can be clicked.
 */
import {
  Color,
  Mesh,
  MeshBasicMaterial,
  NearestFilter,
  PerspectiveCamera,
  PlaneGeometry,
  Scene,
  SRGBColorSpace,
  Texture,
  Vector3,
  type WebGLRenderer,
} from "three";
import { Chase, reducedMotion } from "../engine/motion";

/** Narrow enough that the perspective is a lean, not a fish-eye. */
const FOV = 34;

/**
 * How far the plane is tilted away from square-on, in radians. About eleven
 * degrees. Every degree past this makes the painted buildings look like they
 * are falling over, because they were painted with their own projection.
 */
const TILT = 0.2;

/** A plate rectangle, in device pixels, with the canvas height it sits in. */
export interface Viewport {
  x: number;
  y: number;
  w: number;
  h: number;
  dh: number;
}

export class Mode7 {
  private readonly scene = new Scene();
  private readonly camera = new PerspectiveCamera(FOV, 1.5, 0.01, 60);
  private readonly mat: MeshBasicMaterial;
  private readonly mesh: Mesh;
  private tex: Texture | null = null;
  private source: HTMLImageElement | null = null;

  /** The plane's extent in world units: `aspect` across, 1 deep. */
  private aspect = 1.5;
  /** The camera height that fits the whole plane in the plate, before zoom. */
  private baseDist = 2;
  private vp: Viewport = { x: 0, y: 0, w: 1, h: 1, dh: 1 };

  /** Where the camera is looking, in 0..1 map coordinates, and how close. */
  private readonly fu = new Chase(0.5, "camera");
  private readonly fv = new Chase(0.5, "camera");
  private readonly zoom = new Chase(1, "camera");

  /** Set every frame by the map scene; cleared by the app before each update. */
  wanted = false;
  /** True only on the frames the map should actually be drawn. */
  private live = false;

  constructor() {
    this.mat = new MeshBasicMaterial({ color: new Color(0xffffff), depthTest: false });
    this.mesh = new Mesh(new PlaneGeometry(1, 1), this.mat);
    // A plane made in XY, laid down into XZ. `u` runs +x, `v` runs +z, so a
    // node's map fraction and its world position differ only by a scale.
    this.mesh.rotation.x = -Math.PI / 2;
    this.mesh.frustumCulled = false;
    this.scene.add(this.mesh);
  }

  /**
   * Hand it the overworld painting. Cheap to call every frame: it does nothing
   * unless the image is a different one from last time, which matters because
   * the JPEG arrives several seconds after the screen does.
   */
  setImage(img: HTMLImageElement, aspectW: number, aspectH: number): void {
    if (this.source !== img) {
      this.tex?.dispose();
      const tex = new Texture(img);
      tex.magFilter = NearestFilter;
      tex.minFilter = NearestFilter;
      tex.generateMipmaps = false;
      // The same bytes the 2D fallback would blit, so the GPU path and the
      // flat path are the same picture rather than two different exposures.
      tex.colorSpace = SRGBColorSpace;
      tex.needsUpdate = true;
      this.tex = tex;
      this.mat.map = tex;
      this.mat.needsUpdate = true;
      this.source = img;
    }
    const a = Math.max(0.2, aspectW / Math.max(1, aspectH));
    if (a !== this.aspect) {
      this.aspect = a;
      this.mesh.scale.set(a, 1, 1);
      this.fit();
    }
  }

  /** The plate, in device pixels. Refits the camera when it changes shape. */
  setViewport(v: Viewport): void {
    const changed = v.w !== this.vp.w || v.h !== this.vp.h;
    this.vp = v;
    if (changed) {
      this.camera.aspect = Math.max(0.2, v.w / Math.max(1, v.h));
      this.camera.updateProjectionMatrix();
      this.fit();
    }
  }

  /**
   * Look at a point on the map, at a zoom.
   *
   * Both are chased rather than set, so a run of arrow keys is one continuous
   * move and not eleven restarts — the same reason the old 2D camera used a
   * `Chase`, kept for the one thing on this screen that still needs it.
   */
  aim(u: number, v: number, zoom = 1): void {
    this.fu.to(u);
    this.fv.to(v);
    this.zoom.to(zoom);
  }

  /** Put the camera where it is going, with no travel. Used on first sight. */
  snap(u: number, v: number, zoom = 1): void {
    this.fu.snap(u);
    this.fv.snap(v);
    this.zoom.snap(zoom);
  }

  update(dt: number): void {
    this.fu.update(dt);
    this.fv.update(dt);
    this.zoom.update(dt);
    this.place();
    this.live = this.wanted && this.tex !== null;
    this.wanted = false;
  }

  private world(u: number, v: number): Vector3 {
    return new Vector3((u - 0.5) * this.aspect, 0, (v - 0.5) * 1);
  }

  /**
   * Where the camera sits for the current focus and zoom.
   *
   * The lean is *toward* the focus rather than centred on it: pointing the
   * camera straight at the selected node would swing the whole overworld
   * across the plate every time the cursor moved, and a map you cannot hold
   * still is a map you cannot read. A third of the way is enough to feel the
   * ground shift under the selection.
   */
  private place(): void {
    const lean = reducedMotion() ? 0.12 : 0.34;
    const u = 0.5 + (this.fu.value - 0.5) * lean;
    const v = 0.5 + (this.fv.value - 0.5) * lean;
    const focus = this.world(u, v);
    const d = this.baseDist * this.zoom.value;
    this.camera.position.set(focus.x, d * Math.cos(TILT), focus.z + d * Math.sin(TILT));
    this.camera.lookAt(focus.x, 0, focus.z);
    this.camera.updateMatrixWorld();
  }

  /**
   * Choose the camera height that fits the whole plane inside the plate.
   *
   * Analytically for a square-on camera, then widened until all four corners
   * are genuinely inside the frame — the tilt spreads the near edge and the
   * closed form gets it slightly wrong, and the failure mode of "slightly
   * wrong" here is node 1 sitting outside the plate.
   */
  private fit(): void {
    const half = Math.tan((FOV * Math.PI) / 360);
    this.baseDist = (0.5 / half) * 1.04;
    for (let i = 0; i < 32; i++) {
      this.place();
      let inside = true;
      for (const [cu, cv] of [
        [0, 0],
        [1, 0],
        [0, 1],
        [1, 1],
      ] as const) {
        const p = this.world(cu, cv).project(this.camera);
        if (Math.abs(p.x) > 0.995 || Math.abs(p.y) > 0.995) inside = false;
      }
      if (inside) return;
      this.baseDist *= 1.03;
    }
  }

  /**
   * A node's place on screen, in virtual pixels — or null when the camera has
   * pushed it off the plate.
   *
   * `ox`/`oy`/`scale` come from `Layout`: three projects against the viewport
   * it was given, which is the plate in device pixels, and the 2D renderer
   * draws in virtual pixels inset into the window. Both conversions live here
   * so that no caller can do one of them and forget the other.
   */
  project(
    u: number,
    v: number,
    ox: number,
    oy: number,
    scale: number,
  ): [number, number] | null {
    if (!this.live) return null;
    const p = this.world(u, v).project(this.camera);
    if (!Number.isFinite(p.x) || !Number.isFinite(p.y)) return null;
    const dx = this.vp.x + (p.x * 0.5 + 0.5) * this.vp.w;
    const dy = this.vp.y + (1 - (p.y * 0.5 + 0.5)) * this.vp.h;
    return [(dx - ox) / scale, (dy - oy) / scale];
  }

  /**
   * How big a thing standing at `(u,v)` should be drawn, relative to one at the
   * middle of the map. Screen size under a perspective camera goes as 1/depth,
   * so this is that ratio and nothing cleverer.
   *
   * Without it the markers all come out the same size and the far half of the
   * map floats above its own ground.
   */
  scaleAt(u: number, v: number): number {
    if (!this.live) return 1;
    const ref = this.camera.position.distanceTo(this.world(0.5, 0.5));
    const here = this.camera.position.distanceTo(this.world(u, v));
    return here > 0.001 ? ref / here : 1;
  }

  get active(): boolean {
    return this.live;
  }

  /** The second pass, over the sky, inside the plate. */
  render(renderer: WebGLRenderer): void {
    if (!this.live) return;
    const { x, y, w, h, dh } = this.vp;
    // three counts viewport rows from the bottom of the drawing buffer; the
    // layout counts them from the top.
    const gy = dh - y - h;
    renderer.autoClear = false;
    renderer.setViewport(x, gy, w, h);
    renderer.setScissor(x, gy, w, h);
    renderer.setScissorTest(true);
    renderer.render(this.scene, this.camera);
    renderer.setScissorTest(false);
    renderer.autoClear = true;
  }

  dispose(): void {
    this.tex?.dispose();
    this.mat.dispose();
    this.mesh.geometry.dispose();
  }
}
