/**
 * The overworld.
 *
 * Nodes come from `world.map` with `x`/`y` as fractions of the map image
 * (SPEC §6.3), which is what lets the art be replaced without touching
 * content — and, more usefully here, lets the same node positions work in both
 * orientations: the fractions are mapped onto whatever rectangle the layout
 * hands over, portrait or landscape.
 *
 * The paths are drawn from `edges`, as a Super Mario World map draws them:
 * a thick ink line, a lighter core, and a row of dots along it. An edge into a
 * node that is still locked is drawn faint, so the shape of the map is visible
 * before the streets are.
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { clipped, fill, panel, type Ctx, type Rect } from "../engine/ui";
import { clearRibbon, clearedStamp, footer, header, stars as drawStars, GO, RUST } from "../ui/chrome";
import type { Category, Land, MapNode } from "../net/protocol";
import { MapFx } from "./mapfx";
import { LandsScene } from "./lands";
import { QuestScene } from "./quest";

export class MapScene implements Scene {
  readonly name = "map";
  private nodes: MapNode[] = [];
  /** Pairs of quest ids (PROTOCOL §4.7), given so a client never infers them. */
  private edges: Array<[string, string]> = [];
  private selected = 0;
  private t = 0;
  private status = "";
  private fx: MapFx | null = null;
  private pan: [number, number] = [0, 0];
  private plate: Rect = [0, 0, 1, 1];
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
    this.fx = MapFx.create(this.app.fx);
    this.fx?.setLand(this.land);
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
    this.fx?.dispose();
    this.fx = null;
    // The WebGL canvas keeps its last frame otherwise, and it would show
    // through every screen that is not the map.
    this.app.fx.width = 1;
    this.app.fx.height = 1;
    this.app.chip.music("stop");
  }

  private async refresh(): Promise<void> {
    try {
      const res = await this.app.client.request("world.map", {
        land: this.land,
        category: this.category,
      });
      this.nodes = res.nodes.slice().sort((a, b) => a.node - b.node);
      this.edges = res.edges;
      this.status = this.nodes.length === 0 ? "no streets here yet" : "";
      if (this.selected >= this.nodes.length) this.selected = 0;
    } catch {
      this.status = "could not read the map";
    }
  }

  update(dt: number): void {
    this.t += dt;
    if (this.fx) {
      this.fx.resize(this.app.layout.dw, this.app.layout.dh);
      this.fx.render(this.t, this.pan[0], this.pan[1]);
    }
  }

  // -- input ---------------------------------------------------------------

  key(name: string): void {
    if (name === "escape") return void this.app.go(new LandsScene(this.app));
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
    const [px, py, pw, ph] = this.plate;
    this.pan = [((x - px) / Math.max(1, pw)) * 2 - 1, ((y - py) / Math.max(1, ph)) * 2 - 1];
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
    void this.app.go(new QuestScene(this.app, this.land, this.category, n.quest_id));
  }

  // -- geometry ------------------------------------------------------------

  /** The rectangle the 0..1 node coordinates are mapped onto. */
  private mapPlate(): Rect {
    const { layout } = this.app;
    const s = layout.uiScale();
    const top = Math.round(38 * s) + Math.round(8 * s);
    const bottom = layout.vh - Math.round(26 * s) - Math.round(8 * s);
    const infoH = Math.round((layout.isPortrait() ? 150 : 96) * s);
    return [
      Math.round(8 * s),
      top,
      layout.vw - Math.round(16 * s),
      Math.max(40, bottom - top - infoH - Math.round(8 * s)),
    ];
  }

  private nodeAt(n: MapNode): [number, number] {
    const [x, y, w, h] = this.plate;
    return [x + n.x * w, y + n.y * h];
  }

  private nodeRadius(): number {
    return Math.round(14 * this.app.layout.uiScale());
  }

  // -- drawing -------------------------------------------------------------

  draw(g: Ctx): void {
    const { layout } = this.app;
    const accent = this.land === "rust" ? RUST : GO;
    // The WebGL sky is already behind; the 2D layer only needs to not paint
    // over it, so the backdrop here is transparent rather than a fill.
    g.clearRect(0, 0, layout.vw, layout.vh);
    this.plate = this.mapPlate();
    const s = layout.uiScale();
    const fonts = ensureFonts(s);

    this.drawPlate(g);
    clipped(g, this.plate[0], this.plate[1], this.plate[2], this.plate[3], () => {
      this.drawEdges(g);
      this.drawNodes(g);
    });

    header(
      g,
      layout,
      `${this.land.toUpperCase()} · ${this.category.toUpperCase()}`,
      this.app.addressLabel,
    );
    this.drawInfo(g, accent);

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
    footer(g, layout, "←→  STREET      ENTER  GO IN      ESC  BACK      F1  ORIENTATION");
  }

  /** The map's own frame, plus the background art if it arrived. */
  private drawPlate(g: Ctx): void {
    const [x, y, w, h] = this.plate;
    fill(g, Theme.ink, x - 4, y - 4, w + 8, h + 8);
    const art = this.app.assets?.picture("map_bg", this.app.layout.isPortrait());
    if (art) {
      clipped(g, x, y, w, h, () => {
        // Cover, not stretch: the art is 3:2 and the plate is whatever the
        // window left over, and a squashed overworld looks broken rather than
        // stylised.
        const scale = Math.max(w / art.naturalWidth, h / art.naturalHeight);
        const aw = art.naturalWidth * scale;
        const ah = art.naturalHeight * scale;
        g.globalAlpha = 0.72;
        g.drawImage(art, x + (w - aw) / 2, y + (h - ah) / 2, aw, ah);
        g.globalAlpha = 1;
      });
    } else {
      fill(g, Theme.navy, x, y, w, h, 0.7);
    }
    fill(g, Theme.coin, x - 4, y - 4, w + 8, 2);
    fill(g, Theme.coin, x - 4, y + h + 2, w + 8, 2);
  }

  private drawEdges(g: Ctx): void {
    const byId = new Map(this.nodes.map((n) => [n.quest_id, n]));
    const s = this.app.layout.uiScale();
    for (const [from, to] of this.edges) {
      const a = byId.get(from);
      const b = byId.get(to);
      if (!a || !b) continue;
      const [ax, ay] = this.nodeAt(a);
      const [bx, by] = this.nodeAt(b);
      const walked = a.state === "cleared";
      g.lineCap = "round";
      g.strokeStyle = css(Theme.ink, 0.9);
      g.lineWidth = 7 * s;
      g.beginPath();
      g.moveTo(ax, ay);
      g.lineTo(bx, by);
      g.stroke();
      g.strokeStyle = css(walked ? Theme.coin : Theme.dim, walked ? 1 : 0.55);
      g.lineWidth = 3 * s;
      g.stroke();
      // The dots: a step every eight virtual pixels, so a long street reads as
      // a walk rather than a wire.
      const len = Math.hypot(bx - ax, by - ay);
      const steps = Math.max(1, Math.floor(len / (9 * s)));
      g.fillStyle = css(walked ? Theme.cream : Theme.dim, walked ? 0.9 : 0.4);
      for (let i = 1; i < steps; i++) {
        const u = i / steps;
        g.fillRect(ax + (bx - ax) * u - s, ay + (by - ay) * u - s, 2 * s, 2 * s);
      }
      g.lineWidth = 1;
    }
  }

  private drawNodes(g: Ctx): void {
    const s = this.app.layout.uiScale();
    const r = this.nodeRadius();
    const fonts = ensureFonts(s);
    for (let i = 0; i < this.nodes.length; i++) {
      const n = this.nodes[i];
      const [x, y] = this.nodeAt(n);
      const chosen = i === this.selected;
      const pulse = chosen ? 1 + 0.08 * Math.sin(this.t * 6) : 1;
      const rr = r * pulse;

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
      // The highlight: a 16-bit sphere is a circle with a dot in the top left.
      g.fillStyle = "rgba(255,255,255,0.35)";
      g.beginPath();
      g.arc(x - rr * 0.3, y - rr * 0.35, rr * 0.3, 0, Math.PI * 2);
      g.fill();

      g.fillStyle = css(Theme.ink);
      printf(g, fonts.stationSm, String(n.node), x - r, y - fonts.stationSm.height / 2, r * 2, "center");

      if (n.state === "cleared") {
        clearRibbon(g, x, y, r * 2.6);
        drawStars(g, x - r * 1.2, y + r * 2.1, r * 0.42, n.stars, 3);
      }
      if (chosen) {
        g.strokeStyle = css(Theme.cyan, 0.8 + 0.2 * Math.sin(this.t * 8));
        g.lineWidth = 2 * s;
        g.beginPath();
        g.arc(x, y, rr + 6 * s, 0, Math.PI * 2);
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
    let iy = top + Math.round(16 * s);
    if (!n) {
      g.fillStyle = css(Theme.dim);
      printf(g, fonts.small, "nothing here yet", ix, iy, iw, "center");
      return;
    }
    if (n.state === "cleared") {
      // The stamp the milestone asks for, at a size it can actually be read at.
      clearedStamp(g, x + w - Math.round(90 * s), top + h / 2, Math.round(150 * s), -0.14);
    }
    g.fillStyle = css(accent);
    printf(g, fonts.station, `${String(n.node).padStart(2, "0")}  ${n.title}`, ix, iy, iw, "left");
    iy += fonts.station.height + Math.round(6 * s);
    drawStars(g, ix + Math.round(6 * s), iy + fonts.small.height * 0.4, Math.round(6 * s), n.difficulty, 5);
    g.fillStyle = css(Theme.cream);
    printf(
      g,
      fonts.small,
      n.state === "cleared"
        ? `CLEARED · ${n.stars}/3 STARS`
        : n.state === "locked"
          ? "LOCKED — clear the street before it"
          : "OPEN",
      ix + Math.round(90 * s),
      iy,
      iw - Math.round(90 * s),
      "left",
    );
  }

  resized(): void {
    this.plate = this.mapPlate();
  }
}
