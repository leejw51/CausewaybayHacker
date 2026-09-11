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
import { reducedMotion } from "../engine/motion";
import { Chase, seconds, Tween } from "../engine/motion";
import type { Category, CategorySummary, Land, Responses } from "../net/protocol";
import { MapScene } from "./map";

type Lands = Responses["world.lands"]["lands"];

const NPC: Record<Land, string> = { rust: "sprite_ferris", go: "sprite_gogo" };

/**
 * The neon row's frame grid.
 *
 * Six signs across a 512x256 sheet at 85 wide — measured and recorded in
 * `art/palette.json`, which also carries each sign's tube/face colour pair and
 * its hue. None of that colour data is needed here, and that is the point: the
 * six signs are the same shape in six hues, so *rotating which frame is drawn
 * in which slot is a hue rotation*. That is palette cycling as the hardware did
 * it — indices moving under fixed pixels — rather than six tinted copies of one
 * texture, which is what it would cost to do it the modern way.
 */
const NEON = { frames: 6, fw: 85, fh: 256 };
/** Seconds per index step. A rate, so reduced motion stops it. */
const NEON_STEP = 0.9;
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
    const rec = this.record(land);
    if (!chosen) {
      // A closed plate is still a *land*, not an empty box with an instruction
      // in the middle of it. It keeps its mascot, its record and its colour —
      // everything except the sentence — so the two plates read as two places
      // of which one is open, which is what they are.
      const sprite = this.app.assets?.picture(NPC[land]);
      const footH = fonts.stationSm.height + Math.round(10 * s);
      const room = inner[3] - footH;
      if (sprite && room > 16) {
        const box = this.app.assets?.box.get(NPC[land]);
        const hh = Math.min(room, inner[2] * 0.46);
        const sc = hh / sprite.naturalHeight;
        const ww = sprite.naturalWidth * sc;
        const feet = box ? box.feet * sc : hh;
        g.save();
        g.globalAlpha = 0.68;
        g.drawImage(
          sprite,
          inner[0] + (inner[2] - ww) / 2,
          inner[1] + (room - feet) + Math.sin(this.t * 2.2) * 2 * s,
          ww,
          hh,
        );
        g.restore();
      }
      g.fillStyle = css(Theme.dim);
      printf(
        g,
        fonts.stationSm,
        rec.total > 0 ? `${rec.cleared}/${rec.total}  ★${rec.stars}` : "PRESS TO SWITCH",
        inner[0],
        inner[1] + inner[3] - fonts.stationSm.height,
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

  /** One land's totals, added up off the server's own category rows. */
  private record(land: Land): { cleared: number; total: number; stars: number } {
    const row = this.lands.find((l) => l.land === land);
    const out = { cleared: 0, total: 0, stars: 0 };
    for (const c of row?.categories ?? []) {
      out.cleared += c.cleared;
      out.total += c.total;
      out.stars += c.stars;
    }
    return out;
  }

  /**
   * The night-market strip across the top of the right column.
   *
   * This corner of the screen was empty, and an empty corner on the screen
   * where the game asks its one real question reads as unfinished. It is not
   * filled with another panel: it is filled with the street the land is made
   * of, plus the one fact a player coming back to this screen wants, which is
   * how far into it they are.
   */
  private drawNeon(g: Ctx, rect: Rect, land: Land): void {
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
    const [x, yTop, w, hAvail] = rect;
    const accent = land === "rust" ? RUST : GO;
    const sheet = this.app.assets?.picture("neon_signs");
    const barH = fonts.stationSm.height + Math.round(10 * s);
    const signH = Math.min(hAvail - barH - Math.round(18 * s), Math.round(118 * s));
    // The strip takes only the room it uses and sits on top of the category
    // panel. Whatever is left above it is left as the city, which is the best
    // thing on this screen and was being covered by a scrim for no reason.
    const h = Math.round(14 * s) + signH + Math.round(8 * s) + barH;
    const y = yTop + hAvail - h;
    // A scrim, not a box.
    fill(g, Theme.ink, x, y, w, h, 0.3);
    // The rail the signs hang from.
    fill(g, Theme.ink, x, y + Math.round(6 * s), w, Math.round(3 * s), 0.9);

    if (sheet && signH > 12) {
      const sw = Math.round((signH * NEON.fw) / NEON.fh);
      const gap = Math.round(18 * s);
      const fit = Math.max(1, Math.min(NEON.frames, Math.floor((w - gap) / (sw + gap))));
      // The rotation. Indices move, pixels do not.
      const step = reducedMotion() ? 0 : Math.floor(this.t / NEON_STEP);
      const left = x + Math.round((w - (fit * (sw + gap) - gap)) / 2);
      for (let j = 0; j < fit; j++) {
        const frame = (j + step) % NEON.frames;
        // Each sign hangs a little differently, so the row is a street and not
        // a toolbar. The offsets are fixed, not random: a screenshot of this
        // screen has to be the same screenshot twice.
        const drop = [0, 3, 1, 4, 2, 5][j % 6] * Math.round(3 * s);
        const sx = left + j * (sw + gap);
        const sy = y + Math.round(8 * s) + drop;
        // The bracket, so a sign is hung on the rail rather than floating.
        fill(g, Theme.ink, sx + sw / 2 - 1, y + Math.round(6 * s), 2, drop + Math.round(4 * s));
        g.drawImage(sheet, frame * NEON.fw, 0, NEON.fw, NEON.fh, sx, sy, sw, signH);
      }
    }

    const rec = this.record(land);
    const by = y + h - barH;
    fill(g, Theme.navy, x, by, w, barH, 0.9);
    fill(g, accent, x, by, Math.round(3 * s), barH);
    g.fillStyle = css(Theme.cream);
    printf(
      g,
      fonts.stationSm,
      rec.total > 0
        ? `${land.toUpperCase()}  ${rec.cleared}/${rec.total} CLEARED  ★${rec.stars}`
        : `${land.toUpperCase()}`,
      x + Math.round(10 * s),
      by + Math.round(5 * s),
      w - Math.round(20 * s),
      "left",
    );
    if (rec.total > 0) {
      const bw = Math.round((w - Math.round(20 * s)) * (rec.cleared / rec.total));
      fill(g, Theme.admit, x, by + barH - 2, bw, 2);
    }
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

      const gap = Math.round(8 * s);
      // Sized to the three rows it holds, then centred in the space — a box
      // stretched to the viewport with its contents at the top reads as
      // unfinished, which is what this screen read as.
      const titleH = fonts.stationSm.height + Math.round(fonts.stationSm.size * 0.9) + 16;
      const minRowH = Math.max(layout.minTouchH(), Math.round(fonts.button.height + 52 * s));
      const needed = titleH + cats.length * (minRowH + gap) + Math.round(18 * s);
      // The column is filled by two things and nothing is left over: a band of
      // street across the top, and the categories under it taking the rest.
      // In portrait the column is nearly twice as tall as the rows need, and
      // the previous answer — size the panel to its contents and centre it —
      // left three hundred pixels of navy in the middle of the screen.
      const band = Math.max(0, Math.min(Math.round(190 * s), f.right[3] - needed - gap));
      const panelH = f.right[3] - (band > 0 ? band + gap : 0);
      const panelY = f.right[1] + f.right[3] - panelH;
      const rowH = Math.max(
        minRowH,
        Math.floor((panelH - titleH - Math.round(18 * s)) / cats.length) - gap,
      );
      if (band > Math.round(54 * s)) {
        this.drawNeon(g, [f.right[0], f.right[1], f.right[2], band], this.land);
      }
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
          f.right[1] + Math.round(8 * s),
          f.right[2],
          "center",
        );
      }
    });

    footer(g, layout, "←→  LAND   CLICK  CATEGORY   F1  ORIENTATION   F3  LOG OUT");
  }
}
