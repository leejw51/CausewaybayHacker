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
        if (u && u.state === "locked") u.state = "open";
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
    const r = this.nodeRadius();
    for (let i = 0; i < this.nodes.length; i++) {
      const [nx, ny] = this.nodeAt(this.nodes[i]);
      if (Math.hypot(x - nx, y - ny) > r * 1.4) continue;
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
    void this.app.go(new QuestScene(this.app, this.land, this.category, n.quest_id), "forward");
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

  private nodeAt(n: MapNode): [number, number] {
    const [x, y, w, h] = this.plate;
    // `x`/`y` are fractions of the map image (PROTOCOL §5.2) and the plate *is*
    // the map image, so this is the whole mapping.
    return [x + n.x * w, y + n.y * h];
  }

  private nodeRadius(): number {
    return Math.round(18 * this.app.layout.uiScale());
  }

  // -- drawing -------------------------------------------------------------

  draw(g: Ctx): void {
    const { layout } = this.app;
    const accent = this.land === "rust" ? RUST : GO;
    // The WebGL sky is already behind, so this clears rather than fills — but
    // only when there *is* one. Without WebGL the same call would leave the
    // map floating on the page background, so the app decides.
    this.app.clear(g, Theme.void);
    this.plate = this.mapPlate();
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
      const [ax, ay] = this.nodeAt(a);
      const [bx, by] = this.nodeAt(b);
      // One control point, offset perpendicular to the midpoint, its sign
      // alternating with the edge index. Four lines, and every chord becomes
      // an arc that reads as a street rather than as a cable.
      const dx = bx - ax;
      const dy = by - ay;
      const len = Math.hypot(dx, dy) || 1;
      const bow = len * 0.12 * (e % 2 === 0 ? 1 : -1);
      const cx = (ax + bx) / 2 - (dy / len) * bow;
      const cy = (ay + by) / 2 + (dx / len) * bow;
      const walked = a.state === "cleared";
      const path = () => {
        g.beginPath();
        g.moveTo(ax, ay);
        g.quadraticCurveTo(cx, cy, bx, by);
      };
      g.lineCap = "round";
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
      const steps = Math.max(1, Math.floor(len / (9 * s)));
      g.fillStyle = css(walked ? Theme.cream : Theme.dim, walked ? 0.9 : 0.4);
      for (let i = 1; i < steps; i++) {
        const u = i / steps;
        const k = 1 - u;
        const px = k * k * ax + 2 * k * u * cx + u * u * bx;
        const py = k * k * ay + 2 * k * u * cy + u * u * by;
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
    const r = this.nodeRadius();
    const fonts = ensureFonts(s);
    for (let i = 0; i < this.nodes.length; i++) {
      const n = this.nodes[i];
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
    const ix = x + Math.round(14 * s);
    const iw = w - Math.round(28 * s);
    let iy = top + Math.round(14 * s);
    if (!n) {
      g.fillStyle = css(Theme.dim);
      printf(g, fonts.small, "nothing here yet", ix, iy, iw, "center");
      return;
    }
    const stampW = Math.round(104 * s);
    // The boss gets a face on the plate before you go in, and the stamp takes
    // its place once it is beaten. Six antagonists exist as art and none of
    // them had ever been on screen.
    const boss =
      n.state === "cleared" ? null : (this.app.assets?.picture(BOSS[n.quest_id] ?? "") ?? null);
    if (boss) {
      const d = Math.min(h - Math.round(12 * s), Math.round(96 * s));
      const box = this.app.assets?.box.get(BOSS[n.quest_id] ?? "");
      const scale = d / boss.naturalHeight;
      const feet = box ? box.feet * scale : d;
      g.save();
      if (n.state === "locked") g.globalAlpha = 0.45;
      g.drawImage(
        boss,
        x + w - Math.round(20 * s) - boss.naturalWidth * scale,
        top + h - Math.round(6 * s) - feet,
        boss.naturalWidth * scale,
        d,
      );
      g.restore();
    }
    if (n.state === "cleared") {
      // On its own ground at the end of the plate, not dropped across the
      // stars: the payoff and the score are two facts, not one collision.
      clearedStamp(g, this.app, x + w - stampW * 0.72, top + h / 2, stampW, -0.14);
    }
    const textW = n.state === "cleared" || boss ? iw - stampW : iw;

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

    // Difficulty is a property of the street; stars are what the player did.
    // They are on separate rows in separate glyphs for exactly that reason.
    const barW = Math.min(Math.round(120 * s), Math.round(textW * 0.4));
    drawDifficulty(g, ix, iy, barW, n.difficulty, 5);

    const sx = ix + barW + Math.round(24 * s);
    if (n.state === "cleared") {
      g.fillStyle = css(Theme.dim);
      printf(g, fonts.stationSm, "STARS", sx, iy, textW, "left");
      drawStars(
        g,
        sx + Math.round(8 * s),
        iy + fonts.stationSm.height + Math.round(10 * s),
        Math.round(7 * s),
        n.stars,
        3,
      );
    } else {
      g.fillStyle = css(n.state === "locked" ? Theme.dim : Theme.coin);
      printf(
        g,
        fonts.small,
        n.state === "locked" ? "LOCKED — clear the street before it" : "OPEN",
        sx,
        iy + Math.round(2 * s),
        textW - (sx - ix),
        "left",
      );
    }
  }

  resized(): void {
    this.plate = this.mapPlate();
  }
}
