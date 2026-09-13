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
import { ensureFonts, printf, width, wrap } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { btnBox, clipped, fill, pixBtn, type Ctx, type Rect } from "../engine/ui";
import {
  arriving,
  Buttons,
  footer,
  frame,
  header,
  landColour,
  landName,
  titledPanel,
} from "../ui/chrome";
import { seconds, Tween } from "../engine/motion";
import {
  LANDS,
  type Category,
  type CategorySummary,
  type Land,
  type Responses,
} from "../net/protocol";
import { MapScene } from "./map";
import { PlaygroundScene } from "./playground";
import { t } from "../i18n";

type Lands = Responses["world.lands"]["lands"];

const NPC: Record<Land, string> = {
  rust: "sprite_ferris",
  go: "sprite_gogo",
  cpp: "sprite_cpp",
  python: "sprite_python",
};
const BLURB: Record<Land, () => string> = {
  rust: () => t("lands.rustBlurb"),
  go: () => t("lands.goBlurb"),
  cpp: () => t("lands.cppBlurb"),
  python: () => t("lands.pythonBlurb"),
};

/**
 * How much wider than its own column an emblem band may be drawn before it
 * stops growing: 1 would never crop, and 1.3 hides just under a quarter.
 *
 * It is a bound on the *crop*, never on the proportions — the aspect ratio
 * drawn is always the art's. A 3.37:1 band and a row column that is nearer
 * 1.3:1 cannot both be honoured, and the only question is which way to give:
 * the full row height with most of the picture cropped away, or the whole
 * picture at a third of the row's height. Neither extreme is right. A quarter
 * of the width behind a fade is where a market stall still reads as a market
 * stall and the band is still as tall as the row can nearly make it.
 */
const EMBLEM_OVERHANG = 1.3;

/**
 * What each road *is*, from `docs/story.md` §4, in one line.
 *
 * The rows used to be a word, a count and a hundred and thirty pixels of empty
 * blue — three of them stacked, which read as a settings menu rather than as
 * three places you could go. A road that says what it is is both more useful
 * and more alive than a slab with a label on it.
 */
/**
 * How many rows of a land's sentence the plate will show.
 *
 * Both the measuring (`plateHeight`) and the drawing (`drawLandPlate`) read
 * this one constant, so the space budgeted and the space used cannot drift.
 */
const BLURB_LINES = 2;

/**
 * Cut already-wrapped lines to at most `max`, marking the cut.
 *
 * The ellipsis goes on the **last line kept**, not on a line of its own, so a
 * capped sentence costs exactly `max` lines and the plate height budgeted for
 * it in `plateHeight` is the height it actually takes. Getting that wrong is
 * how the sentence ended up printed over the title bar in the first place.
 */
export function capLines(
  lines: readonly string[],
  max: number,
  fits: (line: string) => boolean = () => true,
): string[] {
  if (max <= 0) return [];
  if (lines.length <= max) return [...lines];
  // The last kept line came out of `wrap`, so it already fills the column to
  // the pixel — and appending an ellipsis to a full line makes it *wider than
  // the column*. The caller draws with `printf`, which wraps, so that one
  // character silently became a third line printed across the record
  // underneath it. Give back a word at a time until the ellipsis fits.
  let last = lines[max - 1].trimEnd();
  while (last.length > 0 && !fits(`${last}…`)) {
    const cut = last.replace(/\s*\S+$/, "").trimEnd();
    // A single word longer than the column would loop forever; drop a
    // character instead and let it end mid-word, which is still readable.
    last = cut.length > 0 ? cut : last.slice(0, -1).trimEnd();
  }
  return [...lines.slice(0, max - 1), `${last}…`];
}

/** Where every land plate goes, and whether the column has to scroll. */
export interface LandGrid {
  cols: number;
  rows: number;
  /** Plate width and height; every plate is the same size. */
  pw: number;
  ph: number;
  /** Height of the whole grid, gaps included. */
  total: number;
  /** How much of it does not fit the column. 0 when it all fits. */
  overflow: number;
  /** The scroll to actually use, clamped and nudged to show the selection. */
  scroll: number;
  /** Top-left of each plate, in order, already scrolled. */
  origins: { x: number; y: number }[];
}

/**
 * The land column's geometry, with no canvas and no fonts in sight.
 *
 * Pulled out of the draw call because every hard decision on this screen lives
 * here — one column or two, share the height or take the floor, scroll or not,
 * and where the selection drags the scroll to — and none of it was reachable
 * by a test while it sat inside a closure that needed a 2D context to run.
 * The two heights arrive measured (`viableH`, `comfortableH`) precisely so
 * that this function never has to touch a font.
 *
 * @param col       the column to fill: `[x, y, w, h]`
 * @param count     how many lands there are
 * @param gap       pixels between plates, both ways
 * @param minCol    narrowest a plate may be before two columns stop being worth it
 * @param viableH   plate height with the smallest mascot still worth drawing
 * @param comfortableH plate height with the mascot at the size it wants
 * @param selected  index of the chosen land, which must stay on screen
 * @param scroll    the scroll as it stands, before clamping
 */
export function landGrid(
  col: Rect,
  count: number,
  gap: number,
  minCol: number,
  viableH: number,
  comfortableH: number,
  selected: number,
  scroll: number,
): LandGrid {
  const [lx, ly, lw, lh] = col;
  const n = Math.max(1, count);
  // Two across only when both halves are still wide enough to read, and only
  // when there is something to gain — two lands stacked are already fine.
  const cols = n > 2 && Math.floor((lw - gap) / 2) >= minCol ? 2 : 1;
  const rows = Math.ceil(n / cols);
  const pw = Math.floor((lw - gap * (cols - 1)) / cols);
  const fair = Math.floor((lh - gap * (rows - 1)) / rows);
  // Take the fair share whenever it still leaves a mascot worth drawing, and
  // fall back to the comfortable floor — which means scrolling — only when it
  // does not. Twenty pixels of extra mascot is not worth hiding a land behind
  // a scroll nobody knows is there.
  const ph = fair >= viableH ? fair : Math.max(fair, comfortableH);
  const total = ph * rows + gap * (rows - 1);
  const overflow = Math.max(0, total - lh);
  // Clamp first, then drag the window to the selected plate's row, so the
  // arrow keys can walk past the bottom of the grid and the grid follows.
  let next = Math.max(0, Math.min(overflow, scroll));
  const top = Math.floor(Math.max(0, Math.min(n - 1, selected)) / cols) * (ph + gap);
  next = Math.max(Math.min(next, top), Math.min(overflow, top + ph - lh));
  const origins = [];
  for (let i = 0; i < n; i++) {
    origins.push({
      x: lx + (i % cols) * (pw + gap),
      y: ly - next + Math.floor(i / cols) * (ph + gap),
    });
  }
  return { cols, rows, pw, ph, total, overflow, scroll: next, origins };
}

const CAT_LINE: Record<Category, () => string> = {
  basic: () => t("lands.basicBlurb"),
  advanced: () => t("lands.advancedBlurb"),
  hacker: () => t("lands.hackerBlurb"),
};

/**
 * A caption beside a button: one line when it fits, two when the button is
 * tall enough, and cut with an ellipsis rather than left to run into the
 * caption under it — which is what "the stage beating you most" did to
 * "nothing here is scored" in a landscape window.
 */
function noteBeside(
  g: Ctx,
  font: ReturnType<typeof ensureFonts>["small"],
  text: string,
  x: number,
  y: number,
  w: number,
  h: number,
): void {
  if (w < font.height * 3) return;
  const lines = wrap(font, text, w);
  // Two lines at most beside a button, however tall the button: three
  // lines of caption beside a one-line label reads as a paragraph.
  const fit = Math.max(1, Math.min(lines.length, 2, Math.floor(h / font.height)));
  const use = lines.slice(0, fit);
  if (lines.length > fit) use[fit - 1] = use[fit - 1].replace(/.{0,2}$/u, "…");
  g.fillStyle = css(Theme.cream, 0.55);
  let ly = y + Math.round((h - use.length * font.height) / 2);
  for (const line of use) {
    printf(g, font, line, x, ly, w, "left");
    ly += font.height;
  }
}

export class LandsScene implements Scene {
  readonly name = "lands";
  readonly mood = "lands" as const;
  private lands: Lands = [];
  /** Read by `App` to tint the city behind the screen. */
  // Seeded from the app, which was seeded from the server. This used to be a
  // literal "rust", which is why walking out of a quest lost the land.
  land: Land = "rust";
  /** Two lists: the land buttons are painted by the shared pixel-button
   *  painter, the category rows paint themselves and only need a hit box. */
  private readonly landBtns = new Buttons();
  private readonly catBtns = new Buttons();
  private t = 0;
  private error = "";
  /** Replaces the AUTO SELECT hint while it is working, or when there is
   *  nothing to send them to. Cleared on the next click. */
  private autoNote: string | null = null;
  private autoBusy = false;
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
  /**
   * The land column scrolls, and this is why.
   *
   * It used to divide the column's height by the number of lands, which was
   * right while there were two of them and wrong the moment there were four:
   * each plate got half the room, the mascot no longer fitted so it was
   * skipped entirely, and the sentence — measured up from the bottom — ran off
   * the top of its own panel and printed across the title bar. A land you
   * cannot see the mascot of is the one thing this screen exists to show.
   *
   * So the plate has a floor now (`plateHeight`), tall enough for the whole
   * arrangement, and when the plates no longer fit the column the column
   * scrolls instead of squashing them. Four lands, or ten, look the same as
   * two did.
   */
  private scroll = 0;
  private overflow = 0;

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
  /**
   * The shortest a plate may be and still hold everything `drawLandPlate`
   * draws: the title bar, a mascot big enough to read as an animal, the
   * sentence, and the record line.
   *
   * Measured from the same fonts and the same chrome the plate itself uses, so
   * it cannot drift out of agreement with the drawing code the way a magic
   * number would. The mascot allowance is the one judgement call, and it comes
   * in two sizes because the honest answer differs by a few pixels and those
   * few pixels decide whether a whole row of lands is on the screen:
   *
   * * `COMFORTABLE` is the size the sprite wants — what a plate takes when
   *   the screen can afford it.
   * * `VIABLE` is the smallest at which it still reads as an animal rather
   *   than a smudge. Dropping to it is worth doing when it is the difference
   *   between seeing every land and having to scroll for one, because a land
   *   you must go looking for is a land nobody picks.
   *
   * The caller picks: fit the grid at `VIABLE` if it can, and only scroll when
   * even that will not fit.
   */
  private plateHeight(s: number, colW: number, mascot = 76): number {
    const fonts = ensureFonts(s);
    const MASCOT_MIN = Math.round(mascot * s);
    // The same font object `titledPanel` measures its bar with — `font()` and
    // `ensureFonts()` hand back one registry — so the two cannot disagree.
    const bar = fonts.stationSm;
    // Both numbers come straight off `titledPanel`: it insets by 6 a side plus
    // 8 again, and spends 8 above the bar and 6 below the body.
    const chrome = 30 + bar.height + Math.round(bar.size * 0.9);
    const innerW = Math.max(1, colW - 28);
    // The tallest sentence of any land, so every plate is the same height and
    // the one with the longest blurb is not the one that gets clipped — but
    // capped, because the sentence is flavour and the mascot is the point.
    //
    // Uncapped it decides the layout, and badly: in Korean at half width the
    // Python line wraps to six rows, which alone made the plate taller than
    // half the column and pushed two of the four lands off the screen. Three
    // rows says what the land is; a fourth is the plate spending the mascot's
    // room on prose nobody is reading twice.
    const lines = Math.min(
      BLURB_LINES,
      Math.max(...LANDS.map((l) => wrap(fonts.small, BLURB[l](), innerW).length)),
    );
    const recH = fonts.stationSm.height + Math.round(6 * s);
    return chrome + MASCOT_MIN + Math.round(8 * s) + lines * fonts.small.height + recH;
  }

  private drawLandPlate(g: Ctx, rect: Rect, land: Land, chosen: boolean): void {
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
    const accent = landColour(land);
    const inner = titledPanel(g, rect, t(`map.${land}` as "map.rust"), chosen ? accent : Theme.dim);
    const rec = this.record(land);

    // Bottom up: the record on the last line, the sentence above it, and the
    // mascot standing on whatever is left. Everything is measured inside
    // `inner`, so nothing can land on the plate's own border — which is where
    // `0/58 ★0` was being cut in half.
    const recH = fonts.stationSm.height + Math.round(6 * s);
    // Capped to the same number of rows `plateHeight` budgeted for, with the
    // last one ended in an ellipsis so a cut sentence reads as cut rather than
    // as one that simply stops mid-thought.
    const blurb = capLines(
      wrap(fonts.small, BLURB[land](), inner[2]),
      BLURB_LINES,
      (l) => width(fonts.small, l) <= inner[2],
    );
    const blurbH = blurb.length * fonts.small.height;
    // Measured up from the bottom, then floored at the top of the panel. The
    // floor is not defensive decoration: without it a plate shorter than its
    // own contents puts the sentence *above* `inner`, which is the title bar,
    // and the two print on top of each other. `plateHeight` is what stops the
    // column ever asking for that, and this is what stops it looking broken if
    // some future layout does anyway.
    const blurbY = Math.max(inner[1], inner[1] + inner[3] - recH - blurbH);
    const room = blurbY - Math.round(8 * s) - inner[1];

    // Which sprite: the land's mascot at rest, or — while a road is under the
    // cursor and this is the land it belongs to — that road's mascot doing the
    // thing the road is about. Ferris works two tills when you hover ADVANCED.
    const hovering = chosen ? this.catBtns.hovered : null;
    const act = hovering?.startsWith("cat:") ? `mascot_${land}_${hovering.slice(4)}` : null;
    const name = (act && this.app.assets?.picture(act) ? act : null) ?? NPC[land];
    const sprite = this.app.assets?.picture(name);
    if (sprite && room > 20) {
      // The `box` metadata from the art manifest is what lets a sprite stand on
      // its feet instead of on the bottom of its transparent margin.
      const box = this.app.assets?.box.get(name);
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
    // Line by line, because the text was already wrapped and capped above and
    // handing the whole string back to `printf` would re-wrap it uncapped.
    blurb.forEach((line, i) => {
      printf(g, fonts.small, line, inner[0], blurbY + i * fonts.small.height, inner[2], "center");
    });

    g.fillStyle = css(chosen ? accent : Theme.dim);
    printf(
      g,
      fonts.stationSm,
      rec.total > 0
        ? t("lands.record", { cleared: rec.cleared, total: rec.total, stars: rec.stars })
        : "—",
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
    // Every route into this screen goes through here, which is why the land is
    // taken now rather than in the constructor: `new LandsScene(app)` is
    // written in nine places and none of them should have to know about this.
    this.land = this.app.land;
    this.app.chip.music("title");
    try {
      const res = await this.app.client.request("world.lands", {});
      this.lands = res.lands;
    } catch {
      this.error = t("lands.noWorld");
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
    this.app.assets?.prefetch(`map_${this.land}`, this.app.layout.isPortrait());
  }

  controls(): Buttons[] {
    return [this.landBtns, this.catBtns];
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
      this.app.land = this.land;
      return;
    }
    if (hit.id === "auto") {
      void this.autoSelect();
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

  /**
   * Go straight to the stage this player is worst at (§4.14c).
   *
   * The ranking is the server's: it is the same list `progress.json` carries,
   * and a client that computed its own would disagree with the file the player
   * can read. An empty answer is the normal one for somebody who has failed
   * nothing — it says so and stays put, rather than sending them somewhere
   * arbitrary or showing an error for having done well.
   */
  private async autoSelect(): Promise<void> {
    if (this.autoBusy) return;
    this.autoBusy = true;
    this.autoNote = t("lands.autoWorking");
    try {
      const { weakest } = await this.app.client.request("stats.weakest", { limit: 1 });
      const pick = weakest[0];
      if (!pick) {
        this.autoNote = t("lands.autoNone");
        return;
      }
      this.autoNote = null;
      // Imported here rather than at the top: `quest.ts` constructs this scene
      // on its way back to the lobby, so a static import would make the two
      // modules a cycle. `app.ts` reaches for the same `await import` on every
      // screen it opens by key, and this method was already async.
      const { QuestScene } = await import("./quest");
      await this.app.go(
        new QuestScene(this.app, pick.land, pick.category, pick.quest_id),
        "forward",
      );
    } catch {
      this.autoNote = t("lands.autoNone");
    } finally {
      this.autoBusy = false;
    }
  }

  wheel(dy: number): void {
    this.scroll = Math.max(0, Math.min(this.overflow, this.scroll + dy));
  }

  key(name: string): void {
    if (name === "left" || name === "right" || name === "a" || name === "d") {
      // A cycle over every land, in the order the plates are drawn, so the
      // keys walk the column the way the eye does.
      const step = name === "left" || name === "a" ? -1 : 1;
      const i = LANDS.indexOf(this.land);
      this.land = LANDS[(i + step + LANDS.length) % LANDS.length];
      this.app.land = this.land;
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
    header(g, this.app, t("lands.title"));
    // A third of the width was right for two tall plates side by side with the
    // category panel. It is wrong for four: at 1280×720 it leaves a column
    // 379px across, which is under twice `MIN_COL`, so the grid falls back to
    // one column, the plates keep their full height, and **Python ends up
    // entirely below the bottom of the screen** — the same "I only see rust
    // and go" this screen was supposed to have stopped having. Half the width
    // fits two plates of ~285 and still leaves the three category rows more
    // room than they use.
    const wide = layout.isPortrait() ? 0.46 : LANDS.length > 2 ? 0.5 : 0.34;
    const f = frame(layout, wide, 0.07);
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
      // — see `drawLandPlate`. A column that resizes its plates as you switch
      // between them draws the eye to the movement rather than to the choice,
      // and at the extremes it looked like a collapsed panel.
      //
      // Equal, and never below the height the contents actually need: share
      // the column out when there is room, and take the floor when there is
      // not, which is what turns the surplus into scroll instead of into
      // four squashed plates.
      // **Two across, when two across fit.** One plate per row is right for two
      // lands and wasteful for four: the plate is the full width of the column
      // and its contents are a 76px mascot and a centred sentence, so a second
      // land fits beside the first without either of them giving up anything
      // that matters. Four lands then occupy the vertical room two used to,
      // and every land is on screen at once — which is the point of this
      // screen. A land you have to go looking for is a land nobody picks.
      //
      // `MIN_COL` is where a plate stops being able to hold its own sentence
      // in a sane number of lines; below it, one column and scroll instead.
      const MIN_COL = Math.round(260 * s);
      // The width the heights have to be measured against is decided by the
      // same rule `landGrid` uses, so ask it once for the shape, measure, then
      // ask again for the final geometry. The first call's heights are only
      // ever used to pick a column count, which does not depend on them.
      const shape = landGrid(f.left, LANDS.length, gap, MIN_COL, 0, 0, 0, 0);
      const grid = landGrid(
        f.left,
        LANDS.length,
        gap,
        MIN_COL,
        this.plateHeight(s, shape.pw, 52),
        this.plateHeight(s, shape.pw),
        LANDS.indexOf(this.land),
        this.scroll,
      );
      this.overflow = grid.overflow;
      this.scroll = grid.scroll;
      const h = grid.ph;
      const total = grid.total;

      g.save();
      // Clipped, because a plate that is half past the end of the column must
      // stop at the column and not paint over the screen below it.
      g.beginPath();
      g.rect(lx, ly, lw, lh);
      g.clip();
      LANDS.forEach((land, i) => {
        const { x: px, y: py } = grid.origins[i];
        this.drawLandPlate(g, [px, py, grid.pw, h], land, land === this.land);
        // The hit box is where the plate *is*, which is the scrolled position
        // — **cut to the column**, as the paint is. A plate scrolled past the
        // column's end is invisible, and on a phone it lies under the
        // category panel; `pointer` tests the plates first, so an uncut box
        // there took the tap meant for BASIC and switched the land instead.
        const top = Math.max(py, ly);
        const bottom = Math.min(py + h, ly + lh);
        if (bottom > top) {
          this.landBtns.add({ id: `land:${land}`, rect: [px, top, grid.pw, bottom - top], label: "" });
        }
      });
      g.restore();

      if (this.overflow > 0) {
        // A column that scrolls and does not say so is a column nobody
        // scrolls — the same rule the quest brief and the console follow.
        const trackW = Math.max(2, Math.round(3 * s));
        const tx = lx + lw - trackW;
        fill(g, Theme.dim, tx, ly, trackW, lh, 0.35);
        const frac = lh / total;
        const barH = Math.max(Math.round(16 * s), Math.floor(lh * frac));
        const by = ly + Math.round((lh - barH) * (this.scroll / this.overflow));
        fill(g, landColour(this.land), tx, by, trackW, barH, 0.9);
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
      const right = titledPanel(
        g,
        f.right,
        t("lands.category", { land: landName(this.land) }),
        Theme.coin,
      );

      // The record, inside the panel and above the rows, with room round it.
      // It used to be a thin strip wedged between two panels with no breathing
      // space on either side.
      const rec = this.record(this.land);
      const recH = fonts.stationSm.height + Math.round(14 * s);
      fill(g, Theme.navy, right[0], right[1], right[2], recH, 0.9);
      fill(g, landColour(this.land), right[0], right[1], Math.round(3 * s), recH);
      g.fillStyle = css(Theme.cream);
      printf(
        g,
        fonts.stationSm,
        rec.total > 0
          ? t("lands.clearedOf", { cleared: rec.cleared, total: rec.total })
          : t("lands.nothingYet"),
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
      const playH = Math.max(
        layout.minTouchH(),
        fonts.button.height + 20,
        fonts.small.height * 2 + Math.round(4 * s),
      );
      // Two buttons stack under the category rows now: AUTO SELECT above
      // PLAYGROUND. Both are "somewhere other than a land plate to go", and
      // they are the same size because neither is the primary action here.
      const rowsBottom = right[1] + right[3] - playH * 2 - gap * 3;
      // The rows share what the column has. Both heights above are
      // preferences, not floors — including the finger floor: in a phone's
      // browser, with its own chrome taking a fifth of the screen, three
      // rows at `minTouchH` ran under the two buttons below them and HACKER
      // was a road nobody could see. A row shorter than a fingertip can
      // still be read and still be tapped; a row behind a button cannot.
      const share = Math.floor((rowsBottom - rowsTop) / cats.length) - gap;
      const floorH = fonts.button.height + Math.round(14 * s);
      const rowH = Math.max(floorH, Math.min(minRowH, share));

      let y = rowsTop;
      for (const c of cats) {
        // Nothing is *locked* (PROTOCOL §4.7): a road with streets in it is a
        // road you may walk down today, whatever you have cleared. `open` is
        // still read, but it no longer means "not yet" — it means the pack did
        // not import, which is a fault and not a rule, and the row says which
        // of the two kinds of nothing it is rather than just going grey.
        const missing = c.total > 0 && !c.open;
        const empty = c.total === 0 || missing;
        const id = `cat:${c.category}`;
        if (!this.glow.has(id)) this.glow.set(id, 0);
        const lit = this.glow.get(id) ?? 0;
        const barW = right[2];
        const slide = Math.round(lit * 8 * s);
        const rx = right[0] + slide;
        const accent = landColour(this.land);

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

        // The emblem band. DESIGN composed these 3:1 with a quiet left quarter
        // and the pipeline then cropped to the ink, so the ink fills the cell:
        // it is drawn from the manifest `box`, inset, and it owns the right of
        // the row while the words own the left.
        //
        // **At its own aspect.** It used to take the scale from the row height
        // and then clamp the *width* to 44% of the row with the height left
        // alone, which is not a fit, it is a squash: `emblem_rust_basic`'s ink
        // is 384x114 (3.37:1) and it was drawn at 322x145 (2.22:1) — 66% of its
        // correct width, most visible on the tram, which came out tall and
        // narrow instead of long and low.
        //
        // The fix is the one the LÖVE client arrived at on the same art rather
        // than DESIGN's §2.4 (`k = min(bandH/inkH, 0.44*barW/inkW)`, a smaller
        // emblem that fits inside 44%): the band is drawn at **row height**, in
        // its own proportions, anchored to the right, and clipped to the column
        // the words do not own — with a fade on its leading edge so a band
        // wider than the room it has cuts into the row instead of ending in a
        // vertical line. §2.4's version keeps the whole picture but shrinks it
        // to about two thirds of the row's height, and these are 3:1 bands: the
        // thing worth protecting is how tall the objects on them are, not how
        // many of them are on screen. The words' column is a floor, so the
        // blurb cannot be starved by an emblem that happens to be wide.
        const art = this.app.assets?.picture(`emblem_${this.land}_${c.category}`);
        const abox = this.app.assets?.box.get(`emblem_${this.land}_${c.category}`);
        const gutter = Math.round(barW * 0.58);
        let textW = barW;
        if (art && !empty) {
          const inset = Math.round(8 * s);
          const bandH = rowH - inset * 2;
          const inkW = abox ? abox.maxx - abox.minx : art.naturalWidth;
          const inkH = abox ? abox.maxy - abox.miny : art.naturalHeight;
          const winX = rx + gutter;
          const winW = barW - gutter - inset;
          // Row height, with a bound on how far the band may run past its own
          // window. Unbounded it is right where the row is long and low — which
          // is the landscape case, and it is what the LÖVE client sees — and
          // wrong in a tall portrait row, where filling a 194px height with a
          // 3.37:1 band means six hundred pixels of picture in a column two
          // hundred and fifty wide and everything but the last object cropped
          // away. `OVERHANG` is the most of itself a band may hide: past that
          // it stops growing, keeps its proportions, and stands on the bottom
          // of the row rather than filling it.
          const k = Math.min(
            bandH / Math.max(1, inkH),
            (winW * EMBLEM_OVERHANG) / Math.max(1, inkW),
          );
          const bw = inkW * k;
          const bh = inkH * k;
          const bx = rx + barW - bw - inset;
          const by = y + inset + (bandH - bh);
          if (winW > Math.round(24 * s)) {
            clipped(g, winX, y + inset, winW, bandH, () => {
              g.save();
              g.globalAlpha = 0.55 + 0.45 * lit;
              if (abox) {
                g.drawImage(art, abox.minx, abox.miny, inkW, inkH, bx, by, bw, bh);
              } else {
                g.drawImage(art, bx, by, bw, bh);
              }
              g.restore();
              const fx = Math.max(bx, winX);
              const fw = Math.min(Math.round(52 * s), Math.max(1, Math.round(bw * 0.35)));
              const grad = g.createLinearGradient(fx, 0, fx + fw, 0);
              grad.addColorStop(0, css(Theme.navy, 0.95));
              grad.addColorStop(1, css(Theme.navy, 0));
              g.fillStyle = grad;
              g.fillRect(fx, by, fw, bh);
            });
          }
          textW = gutter - inset;
        }

        const tx = rx + Math.round(14 * s);
        const tw = Math.max(Math.round(120 * s), textW - Math.round(28 * s));
        const lineH = fonts.small.height;
        const titleY = y + Math.round(12 * s);
        // The name and the count share a line only while both fit: "POKROČILÉ"
        // ran into its "0/17" in Czech, so the count drops under the name
        // when the two would touch.
        const catName = t(`map.${c.category}` as "map.basic");
        const count = missing
          ? t("lands.notInstalled")
          : empty
            ? t("lands.empty")
            : `${c.cleared}/${c.total}  ★${c.stars}`;
        const countBelow =
          width(fonts.button, catName) + width(fonts.stationSm, count) + Math.round(16 * s) > tw;
        g.fillStyle = css(empty ? Theme.dim : Theme.cream);
        printf(g, fonts.button, catName, tx, titleY, tw, "left");
        // What the road is, from the bible. Only when the row is tall enough
        // to hold it — in a short portrait window the count is what matters.
        const lineY =
          titleY + fonts.button.height + Math.round(6 * s) + (countBelow ? fonts.stationSm.height : 0);
        // Only the lines that fit inside the row. In portrait the text column
        // is narrow and this wraps to four; a row that let the fourth spill
        // over its own bottom edge was the first thing the eye found.
        const fits = Math.floor((y + rowH - Math.round(10 * s) - lineY) / lineH);
        if (fits >= 1) {
          const all = wrap(fonts.small, CAT_LINE[c.category](), tw);
          const use = all.slice(0, fits);
          if (all.length > use.length && use.length > 0) {
            use[use.length - 1] = use[use.length - 1].replace(/.{0,2}$/u, "…");
          }
          g.fillStyle = css(Theme.cream, empty ? 0.3 : 0.55 + 0.35 * lit);
          let ly = lineY;
          for (const line of use) {
            printf(g, fonts.small, line, tx, ly, tw, "left");
            ly += lineH;
          }
        }
        // Under the title, not across the row: the right of the row belongs to
        // the emblem now, and a count floating over it read as a caption for
        // the picture rather than as the score for the road.
        g.fillStyle = css(empty ? Theme.dim : Theme.coin);
        printf(
          g,
          fonts.stationSm,
          count,
          tx + Math.round(4 * s),
          titleY + Math.round(2 * s) + (countBelow ? fonts.button.height + Math.round(2 * s) : 0),
          tw,
          countBelow ? "left" : "right",
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

        // The padlock is for this and only this: a road whose pack is not on
        // the server. It is never drawn on the map, where nothing is locked.
        const badge = missing ? this.app.assets?.picture("badge_locked") : null;
        if (badge) {
          const bh2 = Math.min(rowH - Math.round(16 * s), Math.round(34 * s));
          g.save();
          g.globalAlpha = 0.75;
          g.drawImage(badge, rx + barW - bh2 - Math.round(12 * s), y + (rowH - bh2) / 2, bh2, bh2);
          g.restore();
        }
        this.catBtns.add({
          id,
          rect: [right[0], y, barW, rowH],
          label: "",
          dim: empty,
        });
        y += rowH + gap;
      }

      // The one button on this screen that answers "I do not know what to
      // practise". It asks the server rather than guessing, because the
      // ranking is SPEC §1.2's and both clients must agree on it.
      const [aw] = btnBox(
        fonts.button,
        [t("lands.autoSelect")],
        0,
        fonts.button.size * 2,
        layout.minTouchH(),
      );
      const abw = Math.max(aw, Math.round(right[2] * 0.4));
      const aby = right[1] + right[3] - playH * 2 - gap;
      const ahov = this.landBtns.hovered === "auto";
      pixBtn(g, fonts.button, right[0], aby, abw, playH, t("lands.autoSelect"), {
        hover: ahov,
        quiet: !ahov,
      });
      noteBeside(g, fonts.small, this.autoNote ?? t("lands.autoNote"),
        right[0] + abw + Math.round(12 * s), aby, right[2] - abw - Math.round(12 * s), playH);
      this.landBtns.add({
        id: "auto",
        rect: [right[0], aby, abw, playH],
        label: t("lands.autoSelect"),
      });

      const [pw] = btnBox(
        fonts.button,
        [t("lands.playground")],
        0,
        fonts.button.size * 2,
        layout.minTouchH(),
      );
      // Painted here rather than through `Buttons.draw`: the land plates use
      // that list for hit boxes only, and nothing on this screen paints it.
      const pbw = Math.max(pw, Math.round(right[2] * 0.4));
      const pby = right[1] + right[3] - playH;
      const phov = this.landBtns.hovered === "playground";
      pixBtn(g, fonts.button, right[0], pby, pbw, playH, t("lands.playground"), {
        hover: phov,
        quiet: !phov,
      });
      noteBeside(g, fonts.small, t("lands.playgroundNote"),
        right[0] + pbw + Math.round(12 * s), pby, right[2] - pbw - Math.round(12 * s), playH);
      this.landBtns.add({
        id: "playground",
        rect: [right[0], pby, pbw, playH],
        label: t("lands.playground"),
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

    footer(g, layout, t("lands.footer"));
  }
}
