/**
 * Land and category, one screen with two steps.
 *
 * `world.lands` carries the totals and the cleared counts, so the only thing
 * this screen knows is what the server just told it. Categories with no
 * content are drawn dim rather than hidden — the map is supposed to feel like
 * a place with streets you have not been down yet, and a category that appears
 * later would otherwise read as the game growing a new limb.
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { fill, type Ctx } from "../engine/ui";
import { Buttons, footer, frame, GO, header, RUST, titledPanel } from "../ui/chrome";
import type { Category, CategorySummary, Land, Responses } from "../net/protocol";
import { MapScene } from "./map";

type Lands = Responses["world.lands"]["lands"];

const NPC: Record<Land, string> = { rust: "sprite_ferris", go: "sprite_gogo" };
const BLURB: Record<Land, string> = {
  rust: "Ownership, borrows, lifetimes. The craft you had before the machine\nwrote it for you.",
  go: "Goroutines, channels, the small language that fits in a head.",
};

export class LandsScene implements Scene {
  readonly name = "lands";
  private lands: Lands = [];
  private land: Land = "rust";
  /** Two lists: the land buttons are painted by the shared pixel-button
   *  painter, the category rows paint themselves and only need a hit box. */
  private readonly landBtns = new Buttons();
  private readonly catBtns = new Buttons();
  private t = 0;
  private error = "";

  constructor(private readonly app: App) {}

  async enter(): Promise<void> {
    this.app.chip.music("title");
    try {
      const res = await this.app.client.request("world.lands", {});
      this.lands = res.lands;
    } catch {
      this.error = "the server did not send the world";
    }
  }

  leave(): void {
    this.app.chip.music("stop");
  }

  update(dt: number): void {
    this.t += dt;
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    if (phase === "move") {
      this.landBtns.hovered = this.landBtns.hit(x, y)?.id ?? null;
      return;
    }
    if (phase !== "down") return;
    const hit = this.landBtns.hit(x, y) ?? this.catBtns.hit(x, y);
    if (!hit) return;
    this.app.chip.select();
    if (hit.id.startsWith("land:")) {
      this.land = hit.id.slice(5) as Land;
      return;
    }
    if (hit.id.startsWith("cat:")) {
      const category = hit.id.slice(4) as Category;
      void this.app.go(new MapScene(this.app, this.land, category));
    }
  }

  key(name: string): void {
    if (name === "left" || name === "right" || name === "a" || name === "d") {
      this.land = this.land === "rust" ? "go" : "rust";
      this.app.chip.blip();
    }
  }

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    const bg = this.app.assets?.picture("bg_night", layout.isPortrait());
    if (bg) {
      g.globalAlpha = 0.5;
      g.drawImage(bg, 0, 0, layout.vw, layout.vh);
      g.globalAlpha = 1;
    }
    header(g, layout, "CHOOSE YOUR LAND", this.app.addressLabel);
    const f = frame(layout, layout.isPortrait() ? 0.42 : 0.4);
    const s = f.scale;
    const fonts = ensureFonts(s);
    this.landBtns.reset();
    this.catBtns.reset();

    // --- the two lands -----------------------------------------------------
    const left = titledPanel(g, f.left, "LAND", this.land === "rust" ? RUST : GO);
    this.landBtns.row(
      fonts.button,
      [left[0], left[1], left[2], left[3]],
      [
        { id: "land:rust", label: "RUST" },
        { id: "land:go", label: "GO" },
      ],
      layout.minTouchH(),
    );

    const sprite = this.app.assets?.picture(NPC[this.land]);
    const spriteTop = left[1] + Math.round(fonts.button.height + 34 * s);
    if (sprite) {
      // The `box` metadata from the art manifest is what lets a sprite stand on
      // its feet instead of on the bottom of its transparent margin.
      const box = this.app.assets?.box.get(NPC[this.land]);
      const h = Math.min(left[3] - (spriteTop - left[1]), Math.round(120 * s));
      const scale = h / sprite.naturalHeight;
      const w = sprite.naturalWidth * scale;
      const bob = Math.sin(this.t * 2.2) * 2 * s;
      const feet = box ? box.feet * scale : h;
      g.drawImage(sprite, left[0] + (left[2] - w) / 2, spriteTop + (h - feet) + bob, w, h);
    }

    g.fillStyle = css(Theme.cream);
    printf(
      g,
      fonts.small,
      BLURB[this.land],
      left[0],
      left[1] + left[3] - fonts.small.height * 2,
      left[2],
      "center",
    );

    // --- the three categories ---------------------------------------------
    const right = titledPanel(g, f.right, `${this.land.toUpperCase()} — CATEGORY`, Theme.coin);
    const row = this.lands.find((l) => l.land === this.land);
    const cats: CategorySummary[] = row
      ? row.categories
      : (["basic", "advanced", "hacker"] as Category[]).map((category) => ({
          category,
          total: 0,
          cleared: 0,
          stars: 0,
          open: false,
        }));

    const rowH = Math.max(layout.minTouchH(), Math.round(fonts.button.height + 30 * s));
    let y = right[1];
    for (const c of cats) {
      // §4.6: `open` is false while the category's first node is locked. A
      // category with content you cannot start yet is not the same as an empty
      // one, and the row says which.
      const empty = c.total === 0 || !c.open;
      const barW = right[2];
      fill(g, empty ? Theme.dim : Theme.navy, right[0], y, barW, rowH, empty ? 0.35 : 0.9);
      fill(g, empty ? Theme.dim : Theme.coin, right[0], y + rowH - 3, barW, 3, empty ? 0.4 : 1);
      // The cleared bar: the map's own progress, read straight off the server.
      if (c.total > 0) {
        fill(g, Theme.admit, right[0], y + rowH - 3, Math.round((barW * c.cleared) / c.total), 3);
      }
      g.fillStyle = css(empty ? Theme.dim : Theme.cream);
      printf(
        g,
        fonts.button,
        c.category.toUpperCase(),
        right[0] + Math.round(10 * s),
        y + Math.round((rowH - fonts.button.height) / 2),
        barW,
        "left",
      );
      g.fillStyle = css(empty ? Theme.dim : Theme.coin);
      printf(
        g,
        fonts.stationSm,
        c.total === 0 ? "EMPTY" : empty ? "LOCKED" : `${c.cleared}/${c.total}  ★${c.stars}`,
        right[0],
        y + Math.round((rowH - fonts.stationSm.height) / 2),
        barW - Math.round(10 * s),
        "right",
      );
      this.catBtns.add({
        id: `cat:${c.category}`,
        rect: [right[0], y, barW, rowH],
        label: "",
        dim: empty,
      });
      y += rowH + Math.round(8 * s);
    }

    this.landBtns.draw(g, fonts.button);

    if (this.error) {
      g.fillStyle = css(Theme.red);
      printf(
        g,
        fonts.small,
        this.error,
        right[0],
        right[1] + right[3] - fonts.small.height,
        right[2],
        "left",
      );
    }

    footer(g, layout, "←→  LAND      CLICK  CATEGORY      F1  ORIENTATION");
  }
}
