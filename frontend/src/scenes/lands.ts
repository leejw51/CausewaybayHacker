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
import { btnBox, clipped, fill, pixBtn, type Ctx, type Rect } from "../engine/ui";
import { arriving, Buttons, footer, frame, GO, header, RUST, titledPanel } from "../ui/chrome";
import { seconds, Tween } from "../engine/motion";
import type { Category, CategorySummary, Land, Responses } from "../net/protocol";
import { MapScene } from "./map";
import { PlaygroundScene } from "./playground";

type Lands = Responses["world.lands"]["lands"];

const NPC: Record<Land, string> = { rust: "sprite_ferris", go: "sprite_gogo" };
const BLURB: Record<Land, string> = {
  rust: "Ownership, borrows, lifetimes. The craft you had before the machine wrote it for you.",
  go: "Goroutines, channels, the small language that fits in a head.",
};

/**
 * What each road *is*, from `docs/story.md` §4, in one line.
 *
 * The rows used to be a word, a count and a hundred and thirty pixels of empty
 * blue — three of them stacked, which read as a settings menu rather than as
 * three places you could go. A road that says what it is is both more useful
 * and more alive than a slab with a label on it.
 */
const CAT_LINE: Record<Category, string> = {
  basic: "The morning walk. Shopfronts, kiosks and tills — read what the machine wrote.",
  advanced: "The lunch rush. Two tills on one counter, and both of them happened at once.",
  hacker: "The interview. One room, one clock, and nothing finishing your lines.",
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
  /**
   * How lit each row is, 0..1, eased per frame rather than switched.
   *
   * Frame-driven like everything else on this screen — nothing here reads the
   * wall clock, so the capture hook still gets the same picture for the same
   * number of steps.
   */
  private readonly glow = new Map<string, number>();
  private readonly leftIn = new Tween(seconds("panel"));
  private readonly rightIn = new Tween(seconds("panel"), seconds("stagger"));

  constructor(private readonly app: App) {}

  /**
   * One land, as a plate. **One rule for both of them.**
   *
   * The two plates are the same size and hold the same things in the same
   * places: name, mascot, sentence, record. The difference between the chosen
   * land and the other one is carried entirely in *weight* — the title bar
   * takes the land's colour instead of grey, the mascot is at full strength
   * instead of half, the sentence is cream instead of dim.
   *
   * It was two rules before, and it looked like a fault rather than a choice:
   * a 430px RUST plate with Ferris floating in a field of empty purple next to
   * a 145px GO strip with a gopher crammed into it. Two plates that trade
   * emphasis read as deliberate; one large and one squashed reads as a bug,
   * and it was read as one.
   */
  private drawLandPlate(g: Ctx, rect: Rect, land: Land, chosen: boolean): void {
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
    const accent = land === "rust" ? RUST : GO;
    const inner = titledPanel(g, rect, land.toUpperCase(), chosen ? accent : Theme.dim);
    const rec = this.record(land);

    // Bottom up: the record on the last line, the sentence above it, and the
    // mascot standing on whatever is left. Everything is measured inside
    // `inner`, so nothing can land on the plate's own border — which is where
    // `0/58 ★0` was being cut in half.
    const recH = fonts.stationSm.height + Math.round(6 * s);
    const blurbLines = wrap(fonts.small, BLURB[land], inner[2]).length;
    const blurbH = blurbLines * fonts.small.height;
    const blurbY = inner[1] + inner[3] - recH - blurbH;
    const room = blurbY - Math.round(8 * s) - inner[1];

    const sprite = this.app.assets?.picture(NPC[land]);
    if (sprite && room > 20) {
      // The `box` metadata from the art manifest is what lets a sprite stand on
      // its feet instead of on the bottom of its transparent margin.
      const box = this.app.assets?.box.get(NPC[land]);
      const hh = Math.min(room, inner[2] * 0.62);
      const scale = hh / sprite.naturalHeight;
      const ww = sprite.naturalWidth * scale;
      const feet = box ? box.feet * scale : hh;
      // The chosen land's mascot is awake: a two-beat idle with a hop every
      // few seconds, a shadow that tightens as he leaves the ground, and a
      // little squash on the landing. The other land's mascot is asleep, and
      // that is the difference between "not selected" and "not drawn yet".
      const beat = this.t * 2.2;
      const cycle = (this.t % 3.4) / 3.4;
      const hop = chosen && cycle < 0.18 ? Math.sin((cycle / 0.18) * Math.PI) : 0;
      const bob = chosen ? Math.sin(beat) * 2 * s + hop * -10 * s : 0;
      const squash = chosen ? 1 - hop * 0.06 + Math.sin(beat) * 0.01 : 1;
      const air = Math.min(1, Math.abs(bob) / (10 * s));
      const fx = inner[0] + inner[2] / 2;
      const fy = inner[1] + room;
      g.save();
      if (!chosen) g.globalAlpha = 0.5;
      // The shadow is what makes a hop a hop rather than a drift.
      g.fillStyle = css(Theme.ink, (chosen ? 0.45 : 0.3) * (1 - air * 0.6));
      g.beginPath();
      g.ellipse(fx, fy - 2, ww * 0.34 * (1 - air * 0.25), Math.max(2, 4 * s), 0, 0, Math.PI * 2);
      g.fill();
      const dh = hh * squash;
      const dw = ww / squash;
      g.drawImage(sprite, fx - dw / 2, inner[1] + (room - feet) + bob + (hh - dh), dw, dh);
      g.restore();
    }

    g.fillStyle = css(chosen ? Theme.cream : Theme.dim);
    printf(g, fonts.small, BLURB[land], inner[0], blurbY, inner[2], "center");

    g.fillStyle = css(chosen ? accent : Theme.dim);
    printf(
      g,
      fonts.stationSm,
      rec.total > 0 ? `${rec.cleared}/${rec.total} CLEARED   ★${rec.stars}` : "—",
      inner[0],
      inner[1] + inner[3] - fonts.stationSm.height,
      inner[2],
      "center",
    );
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
    // Chase the hover, do not snap to it: a row that lifts over three frames
    // reads as a thing being picked up, and a row that changes colour in one
    // reads as a stylesheet.
    const k = 1 - Math.exp(-dt * 16);
    for (const [id, v] of this.glow) {
      const want = this.catBtns.hovered === id ? 1 : 0;
      this.glow.set(id, v + (want - v) * k);
    }
    // The overworld is a megabyte of JPEG and the player is one click from it.
    this.app.assets?.prefetch(
      this.land === "rust" ? "map_rust" : "map_go",
      this.app.layout.isPortrait(),
    );
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    if (phase === "move") {
      this.landBtns.hovered = this.landBtns.hit(x, y)?.id ?? null;
      const was = this.catBtns.hovered;
      this.catBtns.hovered = this.catBtns.hit(x, y)?.id ?? null;
      // One note when the cursor arrives on a row, and none while it sits
      // there: a blip per mouse-move event is a rattle, not feedback.
      if (this.catBtns.hovered && this.catBtns.hovered !== was) this.app.chip.blip();
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
    if (hit.id === "playground") {
      void this.app.go(new PlaygroundScene(this.app), "forward");
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
      this.app.chip.blip();
    }
  }

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    if (!this.app.backdrop) {
      // The flat path's own ground. `bg_night` went away with the old art set;
      // this is the same job done by a picture that still exists.
      //
      // **Cover, not stretch.** It was `drawImage(bg, 0, 0, vw, vh)`, and in a
      // window 1080 wide and 1750 tall that pulls a 3:2 street to 0.6:1 — a
      // 2.3x vertical stretch, which is why the screen was reported as three
      // unrelated rooms tiled down the page. It is one room now, cropped, and
      // clipped to the playfield so it cannot spill into the bands.
      const bg = this.app.assets?.picture("bg_times", layout.isPortrait());
      if (bg) {
        const k = Math.max(layout.vw / bg.naturalWidth, layout.vh / bg.naturalHeight);
        const aw = bg.naturalWidth * k;
        const ah = bg.naturalHeight * k;
        g.save();
        g.globalAlpha = 0.5;
        clipped(g, 0, 0, layout.vw, layout.vh, () =>
          g.drawImage(bg, (layout.vw - aw) / 2, (layout.vh - ah) / 2, aw, ah),
        );
        g.restore();
        fill(g, Theme.void, 0, 0, layout.vw, layout.vh, 0.5);
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
      const gap = Math.round(10 * s);
      const [lx, ly, lw, lh] = f.left;
      // Equal. The chosen land is not a *bigger* plate, it is a *brighter* one
      // — see `drawLandPlate`. A column that resizes its two halves as you
      // switch between them draws the eye to the movement rather than to the
      // choice, and at the extremes it looked like a collapsed panel.
      const h = Math.floor((lh - gap) / 2);
      let y = ly;
      for (const land of ["rust", "go"] as Land[]) {
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
      // One panel, filling the column. There is no decorative band any more:
      // the row of neon signs that used to live above this was six blank
      // coloured slabs, and it read as a debug draw that had escaped rather
      // than as a street — which is exactly what it was reported as. A screen
      // that asks the game's one real question should not be decorated by
      // something nobody can name.
      const right = titledPanel(g, f.right, `${this.land.toUpperCase()} — CATEGORY`, Theme.coin);

      // The record, inside the panel and above the rows, with room round it.
      // It used to be a thin strip wedged between two panels with no breathing
      // space on either side.
      const rec = this.record(this.land);
      const recH = fonts.stationSm.height + Math.round(14 * s);
      fill(g, Theme.navy, right[0], right[1], right[2], recH, 0.9);
      fill(g, this.land === "rust" ? RUST : GO, right[0], right[1], Math.round(3 * s), recH);
      g.fillStyle = css(Theme.cream);
      printf(
        g,
        fonts.stationSm,
        rec.total > 0 ? `${rec.cleared} / ${rec.total} CLEARED` : "NOTHING HERE YET",
        right[0] + Math.round(12 * s),
        right[1] + Math.round(7 * s),
        right[2] - Math.round(24 * s),
        "left",
      );
      g.fillStyle = css(Theme.coin);
      printf(
        g,
        fonts.stationSm,
        `★ ${rec.stars}`,
        right[0],
        right[1] + Math.round(7 * s),
        right[2] - Math.round(12 * s),
        "right",
      );
      if (rec.total > 0) {
        fill(
          g,
          Theme.admit,
          right[0],
          right[1] + recH - 2,
          Math.round((right[2] * rec.cleared) / rec.total),
          2,
        );
      }

      const rowsTop = right[1] + recH + gap * 2;
      const minRowH = Math.max(layout.minTouchH(), Math.round(fonts.button.height + 52 * s));
      // The scratchpad lives under the three roads, with its own band of air,
      // because it is not a fourth road: nothing there is scored.
      const playH = Math.max(layout.minTouchH(), fonts.button.height + 20);
      const rowsBottom = right[1] + right[3] - playH - gap * 2;
      const rowH = Math.max(minRowH, Math.floor((rowsBottom - rowsTop) / cats.length) - gap);

      let y = rowsTop;
      for (const c of cats) {
        // Nothing is locked (PROTOCOL §4.7): `open` is not consulted, because a
        // road with streets in it is a road you may walk down today. `empty`
        // means there is genuinely nothing there — a pack that has not shipped.
        const empty = c.total === 0;
        const id = `cat:${c.category}`;
        if (!this.glow.has(id)) this.glow.set(id, 0);
        const lit = this.glow.get(id) ?? 0;
        const barW = right[2];
        const slide = Math.round(lit * 8 * s);
        const rx = right[0] + slide;
        const accent = this.land === "rust" ? RUST : GO;

        fill(g, empty ? Theme.dim : Theme.navy, rx, y, barW, rowH, empty ? 0.35 : 0.9);
        // The lit face is the land's own colour at a whisper, so hovering GO
        // and hovering RUST do not feel like the same screen.
        if (lit > 0.01) fill(g, accent, rx, y, barW, rowH, 0.18 * lit);
        // A thick bar down the leading edge, which is the thing that actually
        // reads as "this row is under the cursor" at a glance.
        fill(g, accent, rx, y, Math.round(4 * s), rowH, 0.35 + 0.65 * lit);
        fill(g, empty ? Theme.dim : Theme.coin, rx, y + rowH - 3, barW, 3, empty ? 0.4 : 1);
        // The cleared bar: the map's own progress, read straight off the server.
        if (c.total > 0) {
          fill(g, Theme.admit, rx, y + rowH - 3, Math.round((barW * c.cleared) / c.total), 3);
        }

        const tx = rx + Math.round(14 * s);
        const tw = barW - Math.round(28 * s);
        const lineH = fonts.small.height;
        const titleY = y + Math.round(12 * s);
        g.fillStyle = css(empty ? Theme.dim : Theme.cream);
        printf(g, fonts.button, c.category.toUpperCase(), tx, titleY, tw, "left");
        // What the road is, from the bible. Only when the row is tall enough
        // to hold it — in a short portrait window the count is what matters.
        const lineY = titleY + fonts.button.height + Math.round(6 * s);
        if (rowH > fonts.button.height + lineH * 2 + Math.round(24 * s)) {
          g.fillStyle = css(Theme.cream, empty ? 0.3 : 0.55 + 0.35 * lit);
          printf(g, fonts.small, CAT_LINE[c.category], tx, lineY, tw, "left");
        }
        g.fillStyle = css(empty ? Theme.dim : Theme.coin);
        printf(
          g,
          fonts.stationSm,
          empty ? "EMPTY" : `${c.cleared}/${c.total}  ★${c.stars}`,
          rx,
          titleY + Math.round(2 * s),
          barW - Math.round(14 * s),
          "right",
        );
        // The chevron that says a row is a door. It only exists while the row
        // is lit, and it nudges with the same value the row slides on.
        if (lit > 0.02 && !empty) {
          const cxx = rx + barW - Math.round(16 * s) + lit * Math.round(4 * s);
          const cy = y + rowH / 2;
          const r = Math.round(7 * s);
          g.fillStyle = css(Theme.coin, lit);
          g.beginPath();
          g.moveTo(cxx - r, cy - r);
          g.lineTo(cxx, cy);
          g.lineTo(cxx - r, cy + r);
          g.closePath();
          g.fill();
        }

        this.catBtns.add({
          id,
          rect: [right[0], y, barW, rowH],
          label: "",
          dim: empty,
        });
        y += rowH + gap;
      }

      const [pw] = btnBox(
        fonts.button,
        ["PLAYGROUND"],
        0,
        fonts.button.size * 2,
        layout.minTouchH(),
      );
      // Painted here rather than through `Buttons.draw`: the land plates use
      // that list for hit boxes only, and nothing on this screen paints it.
      const pbw = Math.max(pw, Math.round(right[2] * 0.4));
      const pby = right[1] + right[3] - playH;
      const phov = this.landBtns.hovered === "playground";
      pixBtn(g, fonts.button, right[0], pby, pbw, playH, "PLAYGROUND", {
        hover: phov,
        quiet: !phov,
      });
      g.fillStyle = css(Theme.cream, 0.55);
      printf(
        g,
        fonts.small,
        "write anything · nothing here is scored",
        right[0] + pbw + Math.round(12 * s),
        pby + Math.round((playH - fonts.small.height) / 2),
        right[2] - pbw - Math.round(12 * s),
        "left",
      );
      this.landBtns.add({
        id: "playground",
        rect: [right[0], pby, pbw, playH],
        label: "PLAYGROUND",
      });

      if (this.error) {
        g.fillStyle = css(Theme.red);
        printf(
          g,
          fonts.small,
          this.error,
          right[0],
          right[1] + right[3] - fonts.small.height,
          right[2],
          "center",
        );
      }
    });

    footer(g, layout, "←→  LAND   CLICK  CATEGORY   F1  ORIENTATION   F3  LOG OUT");
  }
}
