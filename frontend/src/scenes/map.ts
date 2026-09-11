/**
 * The overworld.
 *
 * Nodes come from `world.map` with `x`/`y` as fractions **of the map image**
 * (SPEC §6.3). That wording is the whole geometry of this screen: the plate is
 * sized to the art's aspect ratio and the art is drawn to fill it exactly, so
 * a fraction is a place on the picture and node 1 stands where it was authored
 * to stand. Mapping those fractions onto whatever rectangle the layout happened
 * to leave over — which is what this did before — spreads the nodes across a
 * crop of the picture, and in portrait that put node 1 in the harbour.
 *
 * The paths are drawn from `edges`, as a Super Mario World map draws them: a
 * thick ink line, a lighter core, and a row of dots along it. They bend, by a
 * fixed perpendicular offset that alternates with the edge index, because a
 * straight chord between two points on a drawn landscape is a wire and a map
 * of a place is a walk.
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf } from "../engine/text";
import { css, Theme, TRACK_HAZE } from "../engine/theme";
import { clipped, fill, panel, type Ctx, type Rect } from "../engine/ui";
import {
  clearRibbon,
  clearedStamp,
  difficulty as drawDifficulty,
  difficultyH,
  footer,
  header,
  stars as drawStars,
  GO,
  RUST,
} from "../ui/chrome";
import { seconds, Tween } from "../engine/motion";
import type { Category, Land, MapNode } from "../net/protocol";
import { LandsScene } from "./lands";
import { QuestScene } from "./quest";

/** The overworld art, per land. Two places, not one plate and a tint. */
const PLATE: Record<Land, string> = { rust: "map_rust", go: "map_go" };

/**
 * The face at the end of each category, keyed by the quest it guards.
 *
 * By quest id rather than by node number: the number is a position in a pack
 * and the art is a portrait of one specific antagonist. THE AUTOCOMPLETE is
 * node 12 of rust/basic today and the sprite should follow the quest if that
 * ever changes.
 */
const BOSS: Record<string, string> = {
  "rust.basic.12.traits": "boss_autocomplete",
  "rust.advanced.10.deadlock": "boss_deadlock",
  "rust.hacker.08.top-k": "boss_whiteboard",
  "go.basic.12.nil-and-order": "boss_nullptr",
  "go.advanced.10.race": "boss_race",
  "go.hacker.08.kth-largest": "boss_clock",
};

/** Four scaled pixels, rounded — the gap between a label and its value. */
function f8(s: number): number {
  return Math.round(4 * s);
}

export class MapScene implements Scene {
  readonly name = "map";
  readonly mood = "map" as const;
  private nodes: MapNode[] = [];
  /** Pairs of quest ids (PROTOCOL §4.7), given so a client never infers them. */
  private edges: Array<[string, string]> = [];
  private selected = 0;
  private t = 0;
  private status = "";
  private plate: Rect = [0, 0, 1, 1];
  /** Each node's arrival, staggered, so the overworld assembles itself. */
  private pops: Tween[] = [];
  private readonly plateIn = new Tween(seconds("panel"));
  private readonly infoIn = new Tween(seconds("panel"), seconds("stagger") * 2);
  private offProgress: (() => void) | null = null;
  private offState: (() => void) | null = null;

  /**
   * How close the Mode 7 camera is. 1 is the whole overworld; the push happens
   * on the way *into* a street, while the iris is closing on it, so the last
   * thing you see before the quest screen is the ground coming up at you.
   */
  private zoom = 1;

  /**
   * Mei, in map coordinates, and the walk she is in the middle of.
   *
   * She is not an NPC here. Everywhere else in this game the player is a
   * cursor; on the overworld the player is a person standing on a street in
   * Causeway Bay, and where she is standing is the answer to "where am I up
   * to". When a clear unlocks the next street she walks to it, along the same
   * curve the path is drawn on — not a straight line across the ground, the
   * actual drawn road.
   */
  private mei: [number, number] = [0.5, 0.5];
  private meiOn: string | null = null;
  private walk: {
    a: [number, number];
    c: [number, number];
    b: [number, number];
    tween: Tween;
  } | null = null;
  /** Which way she is facing: 1 right, -1 left. */
  private facing = 1;

  constructor(
    private readonly app: App,
    readonly land: Land,
    readonly category: Category,
  ) {}

  async enter(): Promise<void> {
    this.app.chip.music("stage");
    // PROTOCOL §6.5: never trust a map cached across a disconnect — a
    // `progress.update` may have been missed while the socket was down.
    this.offState = this.app.client.onState((s) => {
      if (s === "authed") void this.refresh();
    });
    // A clear landing while the player is looking at the map is the moment the
    // stamp should appear, so the map listens rather than re-fetching.
    // PROTOCOL §4.19 carries `unlocked`, so a clear updates the overworld in
    // place. The event also reaches this user's *other* windows, which is how
    // two of them stay in step — and why this must not be a refetch storm.
    this.offProgress = this.app.client.on("progress.update", (p) => {
      const n = this.nodes.find((x) => x.quest_id === p.quest_id);
      if (n) {
        n.state = p.state;
        n.stars = p.stars;
      }
      for (const id of p.unlocked) {
        const u = this.nodes.find((x) => x.quest_id === id);
        if (u && u.state === "locked") {
          u.state = "open";
          // The street that just opened is where she goes next. First one
          // only: two simultaneous unlocks is a fork, and a walk to both is
          // not a thing a person can do.
          if (!this.walk) this.walkTo(u);
        }
      }
      // A node we have never seen means the map really did change shape.
      if (!n) void this.refresh();
    });
    await this.refresh();
  }

  leave(): void {
    this.offProgress?.();
    this.offState?.();
    this.app.chip.music("stop");
  }

  private async refresh(): Promise<void> {
    try {
      const res = await this.app.client.request("world.map", {
        land: this.land,
        category: this.category,
      });
      const first = this.nodes.length === 0;
      this.nodes = res.nodes.slice().sort((a, b) => a.node - b.node);
      this.edges = res.edges;
      // Only the first load pops the nodes in. A refresh after a clear should
      // change one stamp, not replay the whole opening.
      if (first) {
        this.pops = this.nodes.map(
          (_, i) => new Tween(seconds("node"), seconds("nodeStagger") * i),
        );
      }
      this.status = this.nodes.length === 0 ? "no streets here yet" : "";
      if (this.selected >= this.nodes.length) this.selected = 0;
    } catch {
      this.status = "could not read the map";
    }
  }

  update(dt: number): void {
    this.t += dt;
    this.plateIn.update(dt);
    this.infoIn.update(dt);
    for (const p of this.pops) p.update(dt);
    // The plate is worked out here rather than in `draw`, because the ground
    // plane has to be handed to the WebGL layer before the frame is rendered
    // and `draw` runs after it.
    this.plate = this.mapPlate();
    this.stepMei(dt);
    this.feedGl();
  }

  /** Move her along the road, and settle her when she gets there. */
  private stepMei(dt: number): void {
    const w = this.walk;
    if (w) {
      w.tween.update(dt);
      const before = this.mei[0];
      this.mei = this.onRoad(w.a, w.c, w.b, w.tween.inOut);
      if (Math.abs(this.mei[0] - before) > 0.0004) this.facing = this.mei[0] > before ? 1 : -1;
      if (w.tween.finished) this.walk = null;
      return;
    }
    const home = this.nodes.find((n) => n.quest_id === this.meiOn) ?? this.homeNode();
    if (!home) return;
    // First sight of the map: she is simply already there. Walking her in from
    // nowhere on load would claim a journey that did not happen this session.
    if (this.meiOn !== home.quest_id) {
      this.meiOn = home.quest_id;
      this.mei = [home.x, home.y];
    }
  }

  /**
   * Hand the overworld to the GPU for this frame — if this screen is the one
   * entitled to it (`App.mapLayerScene`), and if the painting has arrived.
   *
   * Everything about the request is per-frame: the plate, the image and the
   * camera aim. Nothing persists, so the ground cannot outlive the screen.
   */
  private feedGl(): void {
    const gl = this.app.backdrop;
    if (!gl || this.app.mapLayerScene !== this) return;
    const portrait = this.app.layout.isPortrait();
    const art = this.app.assets?.picture(PLATE[this.land], portrait);
    const size = this.app.assets?.size(PLATE[this.land], portrait);
    if (!art || !size) return;
    const { ox, oy, scale, dh } = this.app.layout;
    gl.showMap(art, size.w, size.h, {
      x: Math.round(this.plate[0] * scale + ox),
      y: Math.round(this.plate[1] * scale + oy),
      w: Math.round(this.plate[2] * scale),
      h: Math.round(this.plate[3] * scale),
      dh,
    });
    const n = this.nodes[this.selected];
    gl.map.aim(n?.x ?? 0.5, n?.y ?? 0.5, this.zoom);
  }

  // -- input ---------------------------------------------------------------

  key(name: string): void {
    if (name === "escape") return void this.app.go(new LandsScene(this.app), "back");
    if (this.nodes.length === 0) return;
    if (name === "left" || name === "up" || name === "a" || name === "w") {
      this.selected = (this.selected + this.nodes.length - 1) % this.nodes.length;
      this.app.chip.blip();
    } else if (name === "right" || name === "down" || name === "d" || name === "s") {
      this.selected = (this.selected + 1) % this.nodes.length;
      this.app.chip.blip();
    } else if (name === "return" || name === "kpenter" || name === "space") {
      this.open(this.nodes[this.selected]);
    }
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    for (let i = 0; i < this.nodes.length; i++) {
      const [nx, ny] = this.nodeAt(this.nodes[i]);
      if (Math.hypot(x - nx, y - ny) > this.nodeRadius(this.nodes[i]) * 1.4) continue;
      if (phase === "move" && this.selected !== i) {
        this.selected = i;
        this.app.chip.blip();
      }
      if (phase === "down") {
        this.selected = i;
        this.open(this.nodes[i]);
      }
      return;
    }
  }

  private open(n: MapNode | undefined): void {
    if (!n) return;
    if (n.state === "locked") {
      this.app.chip.fail();
      this.app.say("clear the street before it first");
      return;
    }
    this.app.chip.select();
    // The iris closes on the node you chose, and the camera pushes into the
    // ground under it while it does. This is the one place in the game where
    // a screen change has a *place* — you are going into that street, not to
    // the next screen — so it is the one place that gets a door.
    this.zoom = 0.42;
    void this.app.go(
      new QuestScene(this.app, this.land, this.category, n.quest_id),
      "forward",
      this.nodeAt(n),
    );
  }

  // -- Mei -----------------------------------------------------------------

  /** Where she should be standing, given what has been cleared. */
  private homeNode(): MapNode | undefined {
    const cleared = this.nodes.filter((n) => n.state === "cleared");
    if (cleared.length > 0) return cleared[cleared.length - 1];
    return this.nodes.find((n) => n.state === "open") ?? this.nodes[0];
  }

  /**
   * The road between two streets, in map coordinates.
   *
   * The same control point `drawEdges` bends the path with, computed in the
   * same space, so she walks on the drawn line rather than near it. The bow's
   * sign comes from the edge's index, which is why the edge list is searched
   * rather than the two nodes being enough on their own.
   */
  private road(a: MapNode, b: MapNode): { c: [number, number] } {
    let e = this.edges.findIndex(
      ([f, t]) =>
        (f === a.quest_id && t === b.quest_id) || (f === b.quest_id && t === a.quest_id),
    );
    if (e < 0) e = 0;
    // The plate's aspect, so "perpendicular" means perpendicular on screen and
    // not in a unit square that is not square.
    const A = this.plate[2] / Math.max(1, this.plate[3]);
    const dx = (b.x - a.x) * A;
    const dy = b.y - a.y;
    const len = Math.hypot(dx, dy) || 1;
    const bow = len * 0.12 * (e % 2 === 0 ? 1 : -1);
    return {
      c: [((a.x + b.x) / 2) * A - (dy / len) * bow, (a.y + b.y) / 2 + (dx / len) * bow],
    };
  }

  /** Sample a road. `c` is in the aspect-corrected space `road()` returns. */
  private onRoad(
    a: [number, number],
    c: [number, number],
    b: [number, number],
    t: number,
  ): [number, number] {
    const A = this.plate[2] / Math.max(1, this.plate[3]);
    const k = 1 - t;
    const x = k * k * a[0] * A + 2 * k * t * c[0] + t * t * b[0] * A;
    const y = k * k * a[1] + 2 * k * t * c[1] + t * t * b[1];
    return [x / A, y];
  }

  private walkTo(to: MapNode): void {
    const from = this.nodes.find((n) => n.quest_id === this.meiOn);
    const a: [number, number] = from ? [from.x, from.y] : this.mei;
    const { c } = from ? this.road(from, to) : { c: [(a[0] + to.x) / 2, (a[1] + to.y) / 2] };
    const A = this.plate[2] / Math.max(1, this.plate[3]);
    this.walk = {
      a,
      c: from ? (c as [number, number]) : [((a[0] + to.x) / 2) * A, (a[1] + to.y) / 2],
      b: [to.x, to.y],
      tween: new Tween(seconds("scene") * 1.6),
    };
    this.meiOn = to.quest_id;
    this.app.chip.coin();
  }

  // -- geometry ------------------------------------------------------------

  /**
   * The rectangle the 0..1 node coordinates are mapped onto — which is also,
   * exactly, the rectangle the art is drawn into.
   *
   * The plate takes the art's aspect ratio and is centred in whatever the
   * layout left over. Letting it take the whole area instead would mean either
   * stretching the overworld or cropping it, and a crop is what divorced the
   * nodes from the ground they were authored against.
   */
  private mapPlate(): Rect {
    const { layout } = this.app;
    const s = layout.uiScale();
    const portrait = layout.isPortrait();
    const top = Math.round(38 * s) + Math.round(8 * s);
    const bottom = layout.vh - Math.round(26 * s) - Math.round(8 * s);
    const infoH = Math.round((portrait ? 150 : 108) * s);
    const availX = Math.round(8 * s);
    const availW = layout.vw - Math.round(16 * s);
    const availH = Math.max(40, bottom - top - infoH - Math.round(8 * s));
    // From the manifest, not from a loaded image: the JPEG arrives late and a
    // plate that resized when it landed would move every node under the cursor.
    const size = this.app.assets?.size(PLATE[this.land], portrait) ?? { w: 3, h: 2 };
    const scale = Math.min(availW / size.w, availH / size.h);
    const w = Math.max(40, Math.round(size.w * scale));
    const h = Math.max(40, Math.round(size.h * scale));
    return [availX + Math.round((availW - w) / 2), top + Math.round((availH - h) / 2), w, h];
  }

  /**
   * A point on the map, in virtual pixels.
   *
   * Two branches, and they must agree about which one is live or the map is
   * clickable somewhere other than where it is drawn. With the ground on the
   * GPU the answer comes out of the Mode 7 camera; without WebGL — a real
   * supported mode, `13-no-webgl-map` — the plate has the art's aspect ratio
   * and a fraction is a place on it, which is the mapping this screen has
   * always used.
   */
  private at(u: number, v: number): [number, number] {
    const gl = this.app.backdrop;
    if (gl?.map.active) {
      const { ox, oy, scale } = this.app.layout;
      const p = gl.map.project(u, v, ox, oy, scale);
      if (p) return p;
    }
    const [x, y, w, h] = this.plate;
    return [x + u * w, y + v * h];
  }

  private nodeAt(n: MapNode): [number, number] {
    return this.at(n.x, n.y);
  }

  /**
   * How far a node reaches, in virtual pixels.
   *
   * Per node, not per screen: under a perspective camera a street at the top of
   * the map is further away and is drawn smaller, and a hit box that stayed the
   * same size would make the far half of the overworld feel sticky and the near
   * half feel loose.
   */
  private nodeRadius(n?: MapNode): number {
    const base = Math.round(18 * this.app.layout.uiScale());
    const gl = this.app.backdrop;
    if (!n || !gl?.map.active) return base;
    return base * gl.map.scaleAt(n.x, n.y);
  }

  // -- drawing -------------------------------------------------------------

  draw(g: Ctx): void {
    const { layout } = this.app;
    const accent = this.land === "rust" ? RUST : GO;
    // The WebGL sky is already behind, so this clears rather than fills — but
    // only when there *is* one. Without WebGL the same call would leave the
    // map floating on the page background, so the app decides.
    this.app.clear(g, Theme.void);
    const s = layout.uiScale();
    const fonts = ensureFonts(s);

    // The plate drops in from above and the detail slides up from below, so
    // the overworld assembles around the middle rather than appearing.
    const plateLift = (1 - this.plateIn.out) * Math.round(40 * s);
    g.save();
    g.globalAlpha = Math.min(1, this.plateIn.raw * 2.2);
    g.translate(0, -plateLift);
    this.drawPlate(g);
    clipped(g, this.plate[0], this.plate[1], this.plate[2], this.plate[3], () => {
      this.drawEdges(g);
      this.drawNodes(g);
      this.drawMei(g);
      this.drawWires(g);
    });
    g.restore();

    header(g, this.app, `${this.land.toUpperCase()} · ${this.category.toUpperCase()}`);
    const infoDrop = (1 - this.infoIn.out) * Math.round(60 * s);
    g.save();
    g.globalAlpha = Math.min(1, this.infoIn.raw * 2.2);
    g.translate(0, infoDrop);
    this.drawInfo(g, accent);
    g.restore();

    if (this.status) {
      g.fillStyle = css(Theme.cream);
      printf(
        g,
        fonts.small,
        this.status,
        this.plate[0],
        this.plate[1] + this.plate[3] / 2,
        this.plate[2],
        "center",
      );
    }
    footer(g, layout, "←→  STREET   ENTER  GO IN   ESC  BACK   F1  ORIENTATION   F3  LOG OUT");
  }

  /** The map's own frame, plus the background art if it arrived. */
  private drawPlate(g: Ctx): void {
    const [x, y, w, h] = this.plate;
    const gl = this.app.backdrop?.map.active === true;
    if (gl) {
      // The ground is already on screen, drawn by the GPU underneath this
      // canvas. Filling the plate here — which is what this used to do before
      // blitting the art over it — would paint the overworld out. So the frame
      // becomes four strips around a hole rather than a rectangle with a
      // picture on it.
      fill(g, Theme.ink, x - 4, y - 4, w + 8, 4);
      fill(g, Theme.ink, x - 4, y + h, w + 8, 4);
      fill(g, Theme.ink, x - 4, y, 4, h);
      fill(g, Theme.ink, x + w, y, 4, h);
      const haze = TRACK_HAZE[this.land];
      if (haze) fill(g, haze, x, y, w, h, haze[3]);
      fill(g, Theme.coin, x - 4, y - 4, w + 8, 2);
      fill(g, Theme.coin, x - 4, y + h + 2, w + 8, 2);
      return;
    }
    fill(g, Theme.ink, x - 4, y - 4, w + 8, h + 8);
    const art = this.app.assets?.picture(PLATE[this.land], this.app.layout.isPortrait());
    if (art) {
      // The plate already has the art's aspect ratio, so this is a plain
      // stretch onto a rectangle of the same shape — no crop, no letterbox,
      // and every node fraction still means what it meant to the author.
      g.drawImage(art, x, y, w, h);
      // The haze: the land's own colour laid over the ground, which is what
      // ties the panel borders and the accent to the place they frame. It was
      // specified in `theme.ts` and never applied to anything until now.
      const haze = TRACK_HAZE[this.land];
      if (haze) fill(g, haze, x, y, w, h, haze[3]);
    } else {
      fill(g, Theme.navy, x, y, w, h, 0.7);
    }
    fill(g, Theme.coin, x - 4, y - 4, w + 8, 2);
    fill(g, Theme.coin, x - 4, y + h + 2, w + 8, 2);
  }

  private drawEdges(g: Ctx): void {
    const byId = new Map(this.nodes.map((n) => [n.quest_id, n]));
    const s = this.app.layout.uiScale();
    for (let e = 0; e < this.edges.length; e++) {
      const [from, to] = this.edges[e];
      const a = byId.get(from);
      const b = byId.get(to);
      if (!a || !b) continue;
      // The bend is computed on the *map*, not on the screen, and every point
      // along it is projected. A road drawn between two projected endpoints
      // would be a chord through the air over a tilted plane; a road sampled on
      // the ground and then projected lies on the ground, which is the whole
      // reason the camera move reads as a camera move.
      const { c } = this.road(a, b);
      const pts: Array<[number, number]> = [];
      const SEGS = 24;
      for (let i = 0; i <= SEGS; i++) {
        const [u, v] = this.onRoad([a.x, a.y], c, [b.x, b.y], i / SEGS);
        pts.push(this.at(u, v));
      }
      const walked = a.state === "cleared";
      const path = () => {
        g.beginPath();
        g.moveTo(pts[0][0], pts[0][1]);
        for (let i = 1; i < pts.length; i++) g.lineTo(pts[i][0], pts[i][1]);
      };
      g.lineCap = "round";
      g.lineJoin = "round";
      g.strokeStyle = css(Theme.ink, 0.9);
      g.lineWidth = 7 * s;
      path();
      g.stroke();
      g.strokeStyle = css(walked ? Theme.coin : Theme.cream, walked ? 1 : 0.5);
      g.lineWidth = 4 * s;
      path();
      g.stroke();
      // The dots: a step every nine virtual pixels along the *curve*, so the
      // walk and the line it is drawn on are the same shape.
      let len = 0;
      for (let i = 1; i < pts.length; i++) {
        len += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
      }
      const steps = Math.max(1, Math.floor(len / (9 * s)));
      g.fillStyle = css(walked ? Theme.cream : Theme.dim, walked ? 0.9 : 0.4);
      for (let i = 1; i < steps; i++) {
        const [u, v] = this.onRoad([a.x, a.y], c, [b.x, b.y], i / steps);
        const [px, py] = this.at(u, v);
        g.fillRect(px - s, py - s, 2 * s, 2 * s);
      }
      g.lineWidth = 1;
    }
  }

  /**
   * The marker a node wears.
   *
   * Silhouette carries the meaning, not colour: a padlock disc for locked, a
   * spiked gear for a boss, a plain coin for an ordinary street. Node 12 is
   * THE AUTOCOMPLETE and it used to be drawn exactly like node 5.
   */
  private markerFor(n: MapNode): string {
    if (n.state === "locked") return "node_locked";
    return n.kind === "boss" ? "node_boss" : "node_quest";
  }

  private drawNodes(g: Ctx): void {
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
    // Back to front, so a near marker overlaps a far one rather than the other
    // way round. On a tilted plane that is the difference between depth and a
    // pile of stickers.
    const order = this.nodes.map((_, i) => i).sort((a, b) => this.nodes[a].y - this.nodes[b].y);
    for (const i of order) {
      const n = this.nodes[i];
      const r = this.nodeRadius(n);
      const [x, y] = this.nodeAt(n);
      const chosen = i === this.selected;
      const pop = this.pops[i]?.out ?? 1;
      if (pop <= 0.001) continue;
      const pulse = chosen ? 1 + 0.08 * Math.sin(this.t * 6) : 1;
      const rr = r * pulse * pop;
      // A boss is bigger than a street, because it is.
      const scale = n.kind === "boss" ? 1.3 : 1;
      const mark = this.app.assets?.picture(this.markerFor(n)) ?? null;

      if (mark) {
        const d = rr * 2.3 * scale;
        g.save();
        if (n.state === "locked") g.globalAlpha = 0.75;
        g.drawImage(mark, x - d / 2, y - d / 2, d, d);
        g.restore();
      } else {
        // Until the markers arrive, the old discs — the map must be playable
        // on the first frame, not only once the art has downloaded.
        const face =
          n.state === "cleared" ? Theme.admit : n.state === "open" ? Theme.coin : Theme.dim;
        g.fillStyle = css(Theme.ink);
        g.beginPath();
        g.arc(x, y, rr + 3 * s, 0, Math.PI * 2);
        g.fill();
        g.fillStyle = css(face, n.state === "locked" ? 0.6 : 1);
        g.beginPath();
        g.arc(x, y, rr, 0, Math.PI * 2);
        g.fill();
      }

      // The number rides on the marker at `ui` size. At `stationSm` — an 8px
      // pixel font — it was a smudge inside an 18px circle.
      const nf = n.kind === "boss" ? fonts.stationSm : fonts.ui;
      // On a locked node the number sits low, so the padlock's shackle stays
      // visible above it — the lock is the whole reason the marker is there.
      const ny = y - nf.height / 2 + (n.state === "locked" ? rr * 0.22 : 0);
      g.fillStyle = css(Theme.ink, 0.85);
      printf(g, nf, String(n.node), x - r + 1, ny + 1, r * 2, "center");
      // Cream on every state: a padlock marker is busy and a dim number on it
      // is a number nobody can read, which defeats numbering the map at all.
      g.fillStyle = css(Theme.cream, n.state === "locked" ? 0.85 : 1);
      printf(g, nf, String(n.node), x - r, ny, r * 2, "center");

      if (n.state === "cleared") {
        clearRibbon(g, x, y + rr * 0.75, r * 2.6);
        drawStars(g, x - r * 1.2, y + r * 2.3, r * 0.42, n.stars, 3);
      }
      if (chosen) {
        g.strokeStyle = css(Theme.cyan, 0.8 + 0.2 * Math.sin(this.t * 8));
        g.lineWidth = 2 * s;
        g.beginPath();
        g.arc(x, y, rr * 1.25 * scale + 4 * s, 0, Math.PI * 2);
        g.stroke();
        g.lineWidth = 1;
      }
    }
  }

  /**
   * The near layer: tram wires, poles, a banyan branch and four hanging signs,
   * strung across the top of the plate.
   *
   * It is drawn last inside the plate's clip, over the nodes, because it is in
   * front of the street — that is the point of it. It slides further than the
   * camera leans, which is the only reason it is here at all: a static overlay
   * would be a decal, and a decal does not make a picture into a place.
   *
   * Only the **top third of the source** is used, and that is a decision
   * against the brief rather than a shortcut. `fg_wires` is a 3:1 strip, so
   * stretching all of it across a plate this wide makes it half the plate
   * tall — and the bottom two thirds of it are four hanging sign panels the
   * size of shop awnings, which sat squarely over nodes 1 to 9. The wires, the
   * insulators, the pole tops, the awning corner and the head of the banyan
   * are the part that belongs in front of a map. The signs are used at full
   * size on the lands screen instead, where there is sky to hang them in.
   */
  private drawWires(g: Ctx): void {
    const art = this.app.assets?.picture("fg_wires");
    if (!art) return;
    const [px, py, pw] = this.plate;
    const gl = this.app.backdrop?.map;
    const [lu] = gl?.active ? gl.lean() : [0.5];
    const srcH = Math.round(art.naturalHeight * 0.34);
    // Wider than the plate, so there is something to slide.
    const w = pw * 1.16;
    const h = (w * srcH) / art.naturalWidth;
    const slide = (0.5 - lu) * pw * 0.2;
    g.save();
    g.globalAlpha = 0.9;
    g.drawImage(
      art,
      0,
      0,
      art.naturalWidth,
      srcH,
      px + (pw - w) / 2 + slide,
      py - Math.round(h * 0.06),
      w,
      h,
    );
    g.restore();
  }

  /**
   * Mei, standing where the player has got to.
   *
   * She has no walk cycle — there is one frame of her in the art set — so the
   * cadence is done with the body: a two-step bob and a small lean, which is
   * what a 16-bit overworld does with a single sprite anyway. The shadow is
   * what actually sells her as being *on* the ground rather than in front of
   * it, and it shrinks with the bob.
   */
  private drawMei(g: Ctx): void {
    if (this.nodes.length === 0) return;
    const s = this.app.layout.uiScale();
    const strip = this.app.assets?.strip("walk_mei");
    const sheet = strip ? this.app.assets?.picture("walk_mei") : null;
    const sprite = sheet ?? this.app.assets?.picture("sprite_mei");
    const [x, y] = this.at(this.mei[0], this.mei[1]);
    const depth = this.app.backdrop?.map.active
      ? this.app.backdrop.map.scaleAt(this.mei[0], this.mei[1])
      : 1;
    const h = Math.round(46 * s * depth);
    const walking = this.walk !== null;
    // The step is driven by the walk's own progress, not by wall time, so a
    // captured frame is the same frame every run.
    const phase = walking ? (this.walk as { tween: Tween }).tween.raw * 14 : this.t * 2.2;
    // With a real four-frame cycle the body does not need a bob; the sprite has
    // one in it. The lozenge fallback still gets one, and so does standing.
    const bob = strip && walking ? 0 : walking ? Math.abs(Math.sin(phase)) * h * 0.1 : Math.sin(phase) * h * 0.03;

    // The shadow first: an ellipse on the ground at her feet.
    g.save();
    g.fillStyle = css(Theme.ink, 0.4 - bob / (h * 3));
    g.beginPath();
    g.ellipse(x, y, h * 0.24, h * 0.09, 0, 0, Math.PI * 2);
    g.fill();
    g.restore();

    if (!sprite) {
      // No art yet: a lozenge, so the player's own position on the map is
      // never simply missing while a PNG is in flight.
      g.fillStyle = css(Theme.cream);
      g.fillRect(x - 3 * s, y - h + bob, 6 * s, h * 0.8);
      return;
    }
    if (strip && sheet) {
      // `walk_mei`: four frames on a fixed 64x96 grid, feet on a common row.
      // Aligned on the cell rather than on each frame's ink, because the cutter
      // already normalised the figures into their cells — per-frame bounds
      // would reintroduce exactly the jitter that normalising removed.
      //
      // Frames 2 and 4 are both passing poses and are not identical, so a slow
      // cycle reads as a limp. Ten a second is fast enough that it reads as a
      // walk at map size; standing rests on frame 2, which is the upright one.
      const n = strip.frames;
      const i = walking ? Math.floor(phase * 1.4) % n : 1;
      const bx = strip.boxes[i] ?? strip.boxes[0];
      const cellH = strip.fh;
      const scale = h / cellH;
      const feet = (bx ? bx.feet : cellH) * scale;
      const cw = strip.fw * scale;
      g.save();
      g.translate(x, y - feet - bob);
      if (this.facing < 0) g.scale(-1, 1);
      g.drawImage(
        sheet,
        i * strip.fw,
        0,
        strip.fw,
        strip.fh,
        -cw / 2,
        0,
        cw,
        cellH * scale,
      );
      g.restore();
      return;
    }
    const box = this.app.assets?.box.get("sprite_mei");
    const scale = h / sprite.naturalHeight;
    const w = sprite.naturalWidth * scale;
    const feet = box ? box.feet * scale : h;
    g.save();
    g.translate(x, y - feet - bob);
    if (this.facing < 0) g.scale(-1, 1);
    g.drawImage(sprite, -w / 2, 0, w, h);
    g.restore();
  }

  /** The selected street's plate, under the map in both orientations. */
  private drawInfo(g: Ctx, accent: readonly [number, number, number, number]): void {
    const { layout } = this.app;
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    const top = this.plate[1] + this.plate[3] + Math.round(8 * s);
    const h = layout.vh - Math.round(26 * s) - top - Math.round(8 * s);
    const x = this.plate[0];
    const w = this.plate[2];
    if (h < 20) return;
    panel(g, x, top, w, h, Theme.paper);

    const n = this.nodes[this.selected];
    const ix = x + Math.round(20 * s);
    const iw = w - Math.round(34 * s);
    let iy = top + Math.round(14 * s);
    if (!n) {
      g.fillStyle = css(Theme.dim);
      printf(g, fonts.small, "nothing here yet", ix, iy, iw, "center");
      return;
    }

    // A strip of the land's colour down the edge of the plate. It is the
    // cheapest possible way to stop a wide rectangle from reading as an empty
    // wide rectangle, and it ties the slab to the ground above it.
    fill(g, accent, x + 6, top + 8, Math.round(4 * s), h - Math.round(14 * s));

    const stampW = Math.round(96 * s);
    const boss =
      n.state === "cleared" ? null : (this.app.assets?.picture(BOSS[n.quest_id] ?? "") ?? null);
    const artW = n.state === "cleared" || boss ? stampW : 0;
    const textW = iw - artW - (artW ? Math.round(14 * s) : 0);

    if (boss) {
      const d = Math.min(h - Math.round(12 * s), Math.round(96 * s));
      const box = this.app.assets?.box.get(BOSS[n.quest_id] ?? "");
      const bs = d / boss.naturalHeight;
      const feet = box ? box.feet * bs : d;
      g.save();
      if (n.state === "locked") g.globalAlpha = 0.45;
      g.drawImage(
        boss,
        x + w - Math.round(20 * s) - boss.naturalWidth * bs,
        top + h - Math.round(6 * s) - feet,
        boss.naturalWidth * bs,
        d,
      );
      g.restore();
    }
    if (n.state === "cleared") {
      // On its own ground at the end of the plate, not dropped across the
      // stars: the payoff and the score are two facts, not one collision.
      clearedStamp(g, this.app, x + w - stampW * 0.72, top + h / 2, stampW, -0.14);
    }

    g.fillStyle = css(accent);
    printf(
      g,
      fonts.station,
      `${String(n.node).padStart(2, "0")}  ${n.title}${n.kind === "boss" ? "  ·  BOSS" : ""}`,
      ix,
      iy,
      textW,
      "left",
    );
    iy += fonts.station.height + Math.round(10 * s);

    /**
     * The row of facts.
     *
     * This plate used to hold a title, a difficulty bar and the single word
     * OPEN across a slab more than half of which was empty — a wide box with
     * nothing in it reads as a screen that is not finished. Everything below is
     * already on the wire in `world.map`: the street's difficulty, the stars
     * this player earned on it, how many times they have thrown code at it, and
     * what is standing between them and it. None of it is invented here.
     */
    const gap = Math.round(20 * s);
    const barW = Math.min(Math.round(124 * s), Math.round(textW * 0.34));
    drawDifficulty(g, ix, iy, barW, n.difficulty, 5);

    const label = (text: string, lx: number, col = Theme.dim) => {
      g.fillStyle = css(col);
      printf(g, fonts.stationSm, text, lx, iy, textW, "left");
    };
    const valueY = iy + fonts.stationSm.height + Math.round(f8(s));

    let cx2 = ix + barW + gap;
    label("STARS", cx2);
    drawStars(g, cx2 + Math.round(7 * s), valueY + Math.round(5 * s), Math.round(7 * s), n.stars, 3);

    cx2 += Math.round(84 * s);
    label("TRIES", cx2);
    g.fillStyle = css(n.attempts > 0 ? Theme.cream : Theme.dim);
    printf(g, fonts.small, String(n.attempts), cx2, valueY, textW, "left");

    iy += difficultyH() + Math.round(12 * s);

    // The one line that says what to do about it. `requires` is given by the
    // server (§5.2) so the lock can name the street it is waiting on rather
    // than saying "locked" and leaving the player to guess which of eleven.
    let line: string;
    let colour = Theme.coin;
    if (n.state === "cleared") {
      line = `CLEARED · ${n.stars}/3 STARS · ENTER TO RUN IT AGAIN`;
      colour = Theme.admit;
    } else if (n.state === "locked") {
      const need = n.requires
        .map((id) => this.nodes.find((x) => x.quest_id === id)?.node)
        .filter((v): v is number => v !== undefined)
        .map((v) => String(v).padStart(2, "0"));
      line = need.length
        ? `LOCKED — clear ${need.length > 1 ? "streets" : "street"} ${need.join(", ")} first`
        : "LOCKED — clear the street before it";
      colour = Theme.dim;
    } else {
      line = n.kind === "boss" ? "OPEN — the boss of this street" : "OPEN — ENTER to go in";
    }
    g.fillStyle = css(colour);
    printf(g, fonts.small, line, ix, iy, textW, "left");
  }

  resized(): void {
    this.plate = this.mapPlate();
  }
}
