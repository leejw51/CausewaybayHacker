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
import { ensureFonts, printf, wrap } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { fill, type Ctx, type Rect } from "../engine/ui";
import { arriving, Buttons, footer, frame, GO, header, RUST, titledPanel } from "../ui/chrome";
import { Chase, seconds, Tween } from "../engine/motion";
import type { Category, CategorySummary, Land, Responses } from "../net/protocol";
import { MapScene } from "./map";

type Lands = Responses["world.lands"]["lands"];

const NPC: Record<Land, string> = { rust: "sprite_ferris", go: "sprite_gogo" };
const BLURB: Record<Land, string> = {
  rust: "Ownership, borrows, lifetimes. The craft you had before the machine wrote it for you.",
  go: "Goroutines, channels, the small language that fits in a head.",
};

export class LandsScene implements Scene {
  readonly name = "lands";
  readonly mood = "lands" as const;
  private lands: Lands = [];
  /** Read by `App` to tint the city behind the screen. */
  land: Land = "rust";
  /** Two lists: the land buttons are painted by the shared pixel-button
   *  painter, the category rows paint themselves and only need a hit box. */
  private readonly landBtns = new Buttons();
  private readonly catBtns = new Buttons();
  private t = 0;
  private error = "";
  private readonly leftIn = new Tween(seconds("panel"));
  private readonly rightIn = new Tween(seconds("panel"), seconds("stagger"));

  /**
   * Which plate is open, 0 for RUST and 1 for GO, eased between the two. It is
   * one number rather than two because the plates share a column: whatever one
   * gives up the other takes, which is what makes the swap read as a single
   * movement instead of two panels resizing at once.
   */
  private readonly open = new Chase(0, "panel");

  constructor(private readonly app: App) {}

  /**
   * One land, as a plate. Closed it is a name and a rule; open it holds the
   * mascot and the sentence that says what the land is for.
   */
  private drawLandPlate(g: Ctx, rect: Rect, land: Land, chosen: boolean): void {
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
    const accent = land === "rust" ? RUST : GO;
    const inner = titledPanel(g, rect, land.toUpperCase(), chosen ? accent : Theme.dim);
    if (!chosen) {
      g.fillStyle = css(Theme.dim);
      printf(
        g,
        fonts.small,
        "press to switch",
        inner[0],
        inner[1] + Math.round((inner[3] - fonts.small.height) / 2),
        inner[2],
        "center",
      );
      return;
    }
    const blurbLines = wrap(fonts.small, BLURB[land], inner[2]).length;
    const blurbH = blurbLines * fonts.small.height;
    const blurbY = inner[1] + inner[3] - blurbH;

    const sprite = this.app.assets?.picture(NPC[land]);
    const room = blurbY - Math.round(10 * s) - inner[1];
    if (sprite && room > 20) {
      // The `box` metadata from the art manifest is what lets a sprite stand on
      // its feet instead of on the bottom of its transparent margin.
      const box = this.app.assets?.box.get(NPC[land]);
      const hh = Math.min(room, inner[2] * 0.62);
      const scale = hh / sprite.naturalHeight;
      const ww = sprite.naturalWidth * scale;
      const bob = Math.sin(this.t * 2.2) * 2 * s;
      const feet = box ? box.feet * scale : hh;
      g.drawImage(sprite, inner[0] + (inner[2] - ww) / 2, inner[1] + (room - feet) + bob, ww, hh);
    }

    g.fillStyle = css(Theme.cream);
    printf(g, fonts.small, BLURB[land], inner[0], blurbY, inner[2], "center");
  }

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
    this.leftIn.update(dt);
    this.rightIn.update(dt);
    this.open.update(dt);
    // The overworld is a megabyte of JPEG and the player is one click from it.
    this.app.assets?.prefetch(
      this.land === "rust" ? "map_rust" : "map_go",
      this.app.layout.isPortrait(),
    );
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
      this.open.to(this.land === "rust" ? 0 : 1);
      return;
    }
    if (hit.id.startsWith("cat:")) {
      const category = hit.id.slice(4) as Category;
      void this.app.go(new MapScene(this.app, this.land, category), "forward");
    }
  }

  key(name: string): void {
    if (name === "left" || name === "right" || name === "a" || name === "d") {
      this.land = this.land === "rust" ? "go" : "rust";
      this.open.to(this.land === "rust" ? 0 : 1);
      this.app.chip.blip();
    }
  }

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    if (!this.app.backdrop) {
      // `bg_night` went away with the old art set; this is the same job done
      // by a picture that still exists. Without it the flat path is a blank
      // navy field, which is the regression this branch is here to prevent.
      const bg = this.app.assets?.picture("bg_times", layout.isPortrait());
      if (bg) {
        g.globalAlpha = 0.5;
        g.drawImage(bg, 0, 0, layout.vw, layout.vh);
        g.globalAlpha = 1;
        fill(g, Theme.void, 0, 0, layout.vw, layout.vh, 0.45);
      }
    }
    header(g, this.app, "CHOOSE YOUR LAND");
    const f = frame(layout, layout.isPortrait() ? 0.46 : 0.34, 0.07);
    const s = f.scale;
    const fonts = ensureFonts(s);
    this.landBtns.reset();
    this.catBtns.reset();

    // --- the two lands -----------------------------------------------------
    // The choice *is* the panel. It used to be two small buttons in the corner
    // of a box with three hundred pixels of nothing under them, which made the
    // single most important decision in the game look like an afterthought.
    // Now the chosen land opens to hold its mascot and its sentence, and the
    // other stays a closed plate — on the house curve, so the swap reads as
    // one thing making room for another.
    arriving(g, f, "left", this.leftIn, () => {
      const gap = Math.round(8 * s);
      const [lx, ly, lw, lh] = f.left;
      const k = this.open.value;
      const big = Math.round((lh - gap) * 0.74);
      const small = lh - gap - big;
      const heights: Record<Land, number> = {
        rust: Math.round(big + (small - big) * k),
        go: Math.round(small + (big - small) * k),
      };
      let y = ly;
      for (const land of ["rust", "go"] as Land[]) {
        const h = heights[land];
        this.drawLandPlate(g, [lx, y, lw, h], land, land === this.land);
        this.landBtns.add({ id: `land:${land}`, rect: [lx, y, lw, h], label: "" });
        y += h + gap;
      }
    });

    // --- the three categories ---------------------------------------------
    arriving(g, f, "right", this.rightIn, () => {
      const row = this.lands.find((l) => l.land === this.land);
      // A fixed order, not the server's. `world.lands` does not promise one, and
      // a map whose rows move between sessions is a map you cannot learn.
      const ORDER: Category[] = ["basic", "advanced", "hacker"];
      const cats: CategorySummary[] = row
        ? ORDER.map((c) => row.categories.find((x) => x.category === c)).filter(
            (c): c is CategorySummary => c !== undefined,
          )
        : ORDER.map((category) => ({
            category,
            total: 0,
            cleared: 0,
            stars: 0,
            open: false,
          }));

      const rowH = Math.max(layout.minTouchH(), Math.round(fonts.button.height + 52 * s));
      const gap = Math.round(8 * s);
      // Sized to the three rows it holds, then centred in the space — a box
      // stretched to the viewport with its contents at the top reads as
      // unfinished, which is what this screen read as.
      const titleH = fonts.stationSm.height + Math.round(fonts.stationSm.size * 0.9) + 16;
      const needed = titleH + cats.length * (rowH + gap) + Math.round(18 * s);
      const panelH = Math.min(f.right[3], needed);
      const panelY = f.right[1] + Math.round((f.right[3] - panelH) / 2);
      const right = titledPanel(
        g,
        [f.right[0], panelY, f.right[2], panelH],
        `${this.land.toUpperCase()} — CATEGORY`,
        Theme.coin,
      );

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
        y += rowH + gap;
      }

      if (this.error) {
        g.fillStyle = css(Theme.red);
        printf(
          g,
          fonts.small,
          this.error,
          f.right[0],
          panelY + panelH + Math.round(8 * s),
          f.right[2],
          "center",
        );
      }
    });

    footer(g, layout, "←→  LAND   CLICK  CATEGORY   F1  ORIENTATION   F3  LOG OUT");
  }
}
