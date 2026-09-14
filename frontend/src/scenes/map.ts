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
 *
 * **Nothing on this map is locked** (PROTOCOL §4.7): `state` is `open` or
 * `cleared` and the server never refuses a quest because an earlier one is
 * unfinished. The route is still drawn and still means something — the packs
 * are written in a deliberate order and "where do I go next" is a real
 * question — but it is advice, so no node is ever drawn as forbidden. The
 * guidance that replaces the gate is the NEXT marker: the first street on the
 * route the player has not cleared wears a chevron, and that is the whole of
 * it.
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf, wrap } from "../engine/text";
import { css, Theme, TRACK_HAZE } from "../engine/theme";
import { btnBox, clipped, fill, panel, pixBtn, type Ctx, type Rect } from "../engine/ui";
import {
  clearRibbon,
  clearedStamp,
  difficulty as drawDifficulty,
  difficultyH,
  footer,
  header,
  stars as drawStars,
  Buttons,
  landColour,
  footerH,
  landName,
} from "../ui/chrome";
import { motionScale, reducedMotion, seconds, Tween } from "../engine/motion";
import { LANDS, type Category, type Land, type MapNode } from "../net/protocol";
import { LandsScene } from "./lands";
import { PlaygroundScene } from "./playground";
import { QuestScene } from "./quest";
import { AUX_BAR, openAux } from "../ui/auxnav";
import { locale, t } from "../i18n";
import { NeonRail } from "../gfx/neon";

/**
 * The overworld art, per land. Rust and Go are two places, not one plate and a
 * tint; C++ and Python reuse the rust plate under their own haze until they
 * have a plate of their own (docs/art.md: the haze is what separates them).
 */
const PLATE: Record<Land, string> = {
  rust: "map_rust",
  go: "map_go",
  cpp: "map_cpp",
  python: "map_python",
};

/**
 * The twelve maps, laid out the way the switcher shows them: four lands across
 * three categories. The order is the order of the bar and the order the keys
 * cycle in (`LANDS` comes from the protocol so every screen agrees on it), and
 * there is one of each so the player can see every place from any one of them.
 */
const CATEGORIES: readonly Category[] = ["basic", "advanced", "hacker"];

/**
 * Where each of the six maps was left, keyed by land and category.
 *
 * Module-level on purpose: the scene is rebuilt every time it is entered — from
 * the lands screen, from a quest, from a verdict — and a player who switches to
 * GO·HACKER to look at something and comes back should find the cursor and Mei
 * where they left them, not at node 1. Six entries, quest ids only, and it does
 * not outlive the tab.
 */
const MENU_LABEL = (): string => t("map.allMaps");
const PLAY_LABEL = (): string => t("map.playground");

const LAST_AT = new Map<string, string>();
const slot = (land: Land, category: Category): string => `${land}.${category}`;

/**
 * The face at the end of each map, keyed by the map it closes.
 *
 * By map rather than by quest id: the wire already says which node is the
 * boss (`MapNode.kind === "boss"`, exactly one per map), and a quest id has
 * its number baked in, so a table of ids went quietly stale the first time a
 * pack was renumbered and the portraits simply stopped appearing. The art is
 * still a portrait of one specific antagonist; that antagonist is whichever
 * node the pack marks as the boss.
 */
const BOSS: Record<string, string> = {
  "rust.basic": "boss_autocomplete",
  "rust.advanced": "boss_deadlock",
  "rust.hacker": "boss_whiteboard",
  "go.basic": "boss_nullptr",
  "go.advanced": "boss_race",
  "go.hacker": "boss_clock",
  "cpp.basic": "boss_segfault",
  "cpp.advanced": "boss_dangling",
  "cpp.hacker": "boss_linker",
  "python.basic": "boss_none",
  "python.advanced": "boss_gil",
  "python.hacker": "boss_recursion",
};

/** Four scaled pixels, rounded — the gap between a label and its value. */
function f8(s: number): number {
  return Math.round(4 * s);
}

export class MapScene implements Scene {
  readonly name = "map";
  readonly mood = "map" as const;
  private nodes: MapNode[] = [];
  /** The UI locale the nodes' titles were asked in; see `update`. */
  private askedLocale: string | null = null;
  /** Pairs of quest ids (PROTOCOL §4.7), given so a client never infers them. */
  private edges: Array<[string, string]> = [];
  private selected = 0;
  private t = 0;
  /** The signs over the street, and their palette cycle. */
  private readonly neon = new NeonRail();
  private status = "";
  private plate: Rect = [0, 0, 1, 1];
  /** Each node's arrival, staggered, so the overworld assembles itself. */
  private pops: Tween[] = [];
  private readonly plateIn = new Tween(seconds("panel"));
  /** The land/category switcher's hit rects, rebuilt every frame from `bar()`. */
  private readonly bar = new Buttons();
  /** Set by `switchTo`, so the next `refresh` restores that map's cursor. */
  private justSwitched = false;
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
  /**
   * The street she is walking to in order to go *into*, as opposed to the walk
   * she takes when one unlocks. Set when the player chooses a node; the quest
   * opens on arrival.
   */
  private pendingOpen: MapNode | null = null;

  constructor(
    private readonly app: App,
    // Not `readonly`: the switcher changes which of the six maps this screen is
    // showing without leaving the screen. Going back to the lands screen to
    // reach the dynamic-programming street is the friction the unlocking was
    // supposed to remove. `land` stays public because `Scene.land` is what the
    // city behind the screen is tinted from — and it has to follow the switch.
    public land: Land,
    private category: Category,
  ) {}

  async enter(): Promise<void> {
    // Being on this map is being in this land and category. The server records
    // the same thing from the `world.map` request below (§1.3); this is the
    // in-window half, so ESC back to the lobby lands where the player is.
    this.app.land = this.land;
    this.app.category = this.category;
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
          if (!this.walk) this.walkTo(u, true);
        }
      }
      // A node we have never seen means the map really did change shape.
      if (!n) void this.refresh();
    });
    await this.refresh();
  }

  /** Park the cursor for this map, so coming back costs nothing. */
  private remember(): void {
    const n = this.nodes[this.selected];
    if (n) LAST_AT.set(slot(this.land, this.category), n.quest_id);
  }

  leave(): void {
    this.remember();
    this.offProgress?.();
    this.offState?.();
    this.app.chip.music("stop");
  }

  private async refresh(): Promise<void> {
    try {
      // §4.7: titles in the UI language where a translation pack has them;
      // each node says which language its title is in.
      this.askedLocale = locale();
      const res = await this.app.client.request("world.map", {
        land: this.land,
        category: this.category,
        locale: this.askedLocale,
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
      this.status = this.nodes.length === 0 ? t("map.none") : "";
      if (this.selected >= this.nodes.length) this.selected = 0;
      // Back to where this map was left, if it has been open before.
      const was = LAST_AT.get(slot(this.land, this.category));
      if (first || this.justSwitched) {
        this.justSwitched = false;
        const i = was ? this.nodes.findIndex((n) => n.quest_id === was) : -1;
        if (i >= 0) {
          this.selected = i;
          this.meiOn = this.nodes[i].quest_id;
          this.mei = [this.nodes[i].x, this.nodes[i].y];
        }
      }
    } catch {
      this.status = t("map.failed");
    }
  }

  update(dt: number): void {
    if (this.askedLocale !== null && this.askedLocale !== locale()) {
      // F7 under an open map: the titles came from the server in the old
      // language. `refresh` sets the guard before it awaits, so this fires
      // once per change and not once per frame.
      this.askedLocale = locale();
      void this.refresh();
    }
    this.neon.update(dt);
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
      if (w.tween.finished) {
        this.walk = null;
        const go = this.pendingOpen;
        this.pendingOpen = null;
        if (go) this.open(go);
      }
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
    // While she walks the camera follows *her* and leans in a little; the
    // lean is only affordable because the slight zoom makes the plane
    // over-fill the plate, so there is no edge to expose (see `mode7.ts`).
    // At rest it sits square on the whole map.
    const n = this.nodes[this.selected];
    if (this.walk) gl.map.aim(this.mei[0], this.mei[1], 0.86);
    else gl.map.aim(n?.x ?? 0.5, n?.y ?? 0.5, this.zoom);
  }

  // -- the switcher --------------------------------------------------------

  /**
   * Every button on the strip, in the order it is read in, with the group it
   * belongs to.
   *
   * One list, consumed by both the layout and the drawing, because the last
   * bug this strip shipped was exactly a layout and a draw that agreed in the
   * common case and disagreed in the rare one: `barLayout` returned its rects
   * grouped by *line* while `drawBar` consumed them by *label*, and on a narrow
   * window ALL MAPS was painted on top of PLAYGROUND. Two orders that have to
   * match cannot be written down twice.
   *
   * The group number is the only thing the layout knows about meaning. "Which
   * land", "which road" and "where else can I go" are three questions, and a
   * strip of ten evenly spaced buttons reads as one list of ten — so the gap
   * between groups is wider than the gap inside one, and a group is kept whole
   * on a line where it can be.
   */
  /**
   * The bar's face: the button face, or the chrome face on a phone, where
   * ten buttons a finger tall wrapped to five rows and the overworld under
   * them was a stamp.
   */
  private barFont(s: number) {
    const fonts = ensureFonts(s);
    return this.app.layout.isPhone() ? fonts.stationSm : fonts.button;
  }

  private barItems(): Array<{ id: string; label: string; lit: boolean; group: number }> {
    const phone = this.app.layout.isPhone();
    return [
      ...LANDS.map((l) => ({
        id: `land:${l}`,
        label: t(`map.${l}` as "map.rust"),
        lit: l === this.land,
        group: 0,
      })),
      ...CATEGORIES.map((c) => ({
        id: `cat:${c}`,
        label: t(`map.${c}` as "map.basic"),
        lit: c === this.category,
        group: 1,
      })),
      // The way to see all six at once. ESC does the same thing and always
      // did, but a keystroke printed in the footer is not a control — the
      // player who wants the chooser is exactly the player who does not yet
      // know where anything is.
      { id: "menu", label: phone ? t("map.allMapsShort") : MENU_LABEL(), lit: false, group: 2 },
      // The scratchpad. It is not one of the six maps and it is not styled
      // like one: nothing there is scored, and a button that looked like a
      // category would promise otherwise.
      { id: "play", label: phone ? t("map.playgroundShort") : PLAY_LABEL(), lit: false, group: 2 },
      // Search, stats and AI mode. They were on F4/F5/F6 and nowhere else,
      // which meant three finished screens that a player could only reach by
      // being told they existed. The ids are `ui/auxnav.ts`'s own, so
      // `openAux` opens them here with no second table of names to drift.
      // On a phone the five ways off this map are one row of short words,
      // and one group, so the bar is three rows — lands, roads, ways out —
      // rather than the five it wrapped to at the long names.
      // The ids are `auxnav`'s own (`aux:search`, …), so the short label is
      // looked up by the same suffix rather than by a second list of names.
      ...AUX_BAR().map((a) => ({
        id: a.id,
        label: phone ? t(`aux.${a.id.replace("aux:", "")}Short` as "aux.searchShort") : a.label,
        lit: false,
        group: phone ? 2 : 3,
      })),
    ];
  }

  /**
   * Where the buttons go, and how tall the strip they need is.
   *
   * Measured, then laid out, then reported — `mapPlate` subtracts the height
   * this returns, so the overworld is never drawn underneath the bar.
   *
   * It flows rather than choosing between a one-line and a two-line case. It
   * used to be the latter, written out longhand, and adding three ids to it
   * fitted neither branch: the arithmetic was a description of five buttons
   * rather than of a strip. A flow costs nothing, has no case that is only
   * exercised on a phone, and the labels stay words — shrinking them to
   * initials would throw away the one thing the strip is for, which is that a
   * player can read where the other five maps are.
   *
   * The rects come back in label order whatever line they land on.
   */
  private barLayout(): { h: number; rows: Rect[] } {
    const { layout } = this.app;
    const s = layout.uiScale();
    const f = this.barFont(s);
    const gap = Math.round(f.size * 0.5);
    const split = gap * 3;
    const pad = f.size * 2;
    const minH = layout.minTouchH();
    const bh = btnBox(f, [t("map.basic")], 0, pad, minH)[1];
    const x0 = Math.round(8 * s);
    const wide = layout.vw - Math.round(16 * s);

    const items = this.barItems();
    const widths = items.map((it) => btnBox(f, [it.label], 0, pad, minH)[0]);
    /** How much room a whole group wants, so it is not split when it need not be. */
    const span = (group: number): number => {
      let total = 0;
      let n = 0;
      for (let i = 0; i < items.length; i++) {
        if (items[i].group !== group) continue;
        total += widths[i];
        n++;
      }
      return total + gap * Math.max(0, n - 1);
    };
    const lead = (i: number): number => (items[i].group !== items[i - 1].group ? split : gap);

    // Greedy flow. A group starting a line is tested by the width of the
    // *group*; anything else by its own.
    const lines: Array<{ from: number; to: number; width: number }> = [];
    let from = 0;
    let used = widths[0] ?? 0;
    for (let i = 1; i < items.length; i++) {
      const fresh = items[i].group !== items[i - 1].group;
      const need = lead(i) + (fresh ? span(items[i].group) : widths[i]);
      if (i > from && used + need > wide) {
        lines.push({ from, to: i, width: used });
        from = i;
        used = widths[i];
      } else {
        used += lead(i) + widths[i];
      }
    }
    if (items.length > 0) lines.push({ from, to: items.length, width: used });

    const rows: Rect[] = [];
    let y = 0;
    for (const line of lines) {
      let cx = x0 + Math.round((wide - line.width) / 2);
      for (let i = line.from; i < line.to; i++) {
        if (i > line.from) cx += lead(i);
        rows[i] = [cx, y, widths[i], bh];
        cx += widths[i];
      }
      y += bh + gap;
    }
    return { h: Math.max(bh, lines.length * bh + (lines.length - 1) * gap), rows };
  }

  /**
   * RUST | GO | C++ | PYTHON and BASIC | ADVANCED | HACKER, across the top of
   * the overworld.
   *
   * The lit land wears its own colour (the same orange, cyan, blue and gold
   * the lands screen and the map haze use) rather than the generic gold, so "which land
   * am I in" is answered by a colour the player has already learnt; the lit
   * category is gold like every other selected thing in the game.
   */
  private drawBar(g: Ctx, y0: number): void {
    const s = this.app.layout.uiScale();
    const f = this.barFont(s);
    const { rows } = this.barLayout();
    this.bar.reset();
    const labels = this.barItems();
    for (let i = 0; i < labels.length; i++) {
      const [x, ry, w, h] = rows[i];
      const y = y0 + ry;
      const item = labels[i];
      this.bar.add({ id: item.id, rect: [x, y, w, h], label: item.label });
      const hover = this.bar.hovered === item.id;
      const land = item.id.startsWith("land:") ? (item.id.slice(5) as Land) : null;
      if (land && item.lit) {
        // The one button `pixBtn` cannot draw: a face in the track's colour.
        panel(g, x, y, w, h, landColour(land));
        g.fillStyle = css(Theme.ink);
        printf(g, f, item.label, x, y + 8 + Math.floor((h - 8 - f.height) * 0.5), w, "center");
      } else {
        pixBtn(g, f, x, y, w, h, item.label, {
          lit: item.lit,
          hover,
          quiet: !item.lit,
        });
      }
      // A gold pip under whichever button is open, in both groups: the colour
      // alone does not survive a colour-blind eye or a dim screen.
      if (item.lit)
        fill(g, Theme.coin, x + w / 2 - Math.round(5 * s), y + h + 2, Math.round(10 * s), 2);
    }
  }

  /**
   * Change which of the six maps this is, in place.
   *
   * A cut, deliberately, and never a walk: Mei is standing on a street in Rust
   * Land and the next frame she is standing on a different street in Go Land,
   * which is not a journey anybody can animate honestly. The plate and the
   * nodes replay their arrival instead, so the screen says "this is a different
   * place" with the language it already has.
   */
  private switchTo(land: Land, category: Category): void {
    if (land === this.land && category === this.category) return;
    this.remember();
    this.justSwitched = true;
    this.land = land;
    this.category = category;
    this.app.chip.select();
    this.walk = null;
    this.pendingOpen = null;
    this.meiOn = null;
    this.selected = 0;
    this.zoom = 1;
    this.nodes = [];
    this.edges = [];
    this.pops = [];
    this.status = "";
    this.plateIn.restart();
    this.infoIn.restart();
    void this.refresh();
  }

  private cycleLand(): void {
    this.switchTo(LANDS[(LANDS.indexOf(this.land) + 1) % LANDS.length], this.category);
  }

  private cycleCategory(step: number): void {
    const i = CATEGORIES.indexOf(this.category);
    const n = CATEGORIES.length;
    this.switchTo(this.land, CATEGORIES[(i + step + n) % n]);
  }

  // -- input ---------------------------------------------------------------

  key(name: string, ev?: KeyboardEvent): void {
    if (name === "escape") return void this.app.go(new LandsScene(this.app), "back");
    // Switching is a look, not a commitment: one `world.map` call, reversible
    // with the same key. It is allowed to interrupt a walk, because the walk
    // belongs to a map that is about to stop existing.
    if (name === "tab") {
      // Otherwise the browser walks the focus ring off the canvas and the next
      // keystroke goes somewhere else entirely.
      ev?.preventDefault();
      return this.cycleLand();
    }
    if (name === "q") return this.cycleCategory(-1);
    if (name === "e") return this.cycleCategory(1);
    // The walk is delight, not a toll. Any key while she is walking puts her at
    // the far end of it immediately — a player who has chosen a street wants
    // the street, and a cutscene between the click and the quest is a cutscene
    // they will learn to resent.
    if (this.walk) return this.skipWalk();
    if (this.nodes.length === 0) return;
    if (name === "left" || name === "up" || name === "a" || name === "w") {
      this.selected = (this.selected + this.nodes.length - 1) % this.nodes.length;
      this.app.chip.blip();
    } else if (name === "right" || name === "down" || name === "d" || name === "s") {
      this.selected = (this.selected + 1) % this.nodes.length;
      this.app.chip.blip();
    } else if (name === "return" || name === "kpenter" || name === "space") {
      this.choose(this.nodes[this.selected]);
    }
  }

  controls(): Buttons[] {
    return [this.bar];
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    // The strip is above the overworld and is tested first: a button that
    // happens to overlap a far node must not enter a street.
    const onBar = this.bar.hit(x, y);
    if (phase === "move") this.bar.hovered = onBar?.id ?? null;
    if (onBar) {
      if (phase === "down") {
        const [kind, value] = onBar.id.split(":");
        if (onBar.id === "menu") void this.app.go(new LandsScene(this.app), "back");
        else if (onBar.id === "play") void this.app.go(new PlaygroundScene(this.app), "forward");
        // Before the land/category dispatch, not after it. `aux:search` splits
        // into `["aux", "search"]`, and a fall-through would have sent
        // `switchTo(this.land, "search")` to `world.map` as a category.
        else if (kind === "aux") void openAux(this.app, onBar.id);
        else if (kind === "land") this.switchTo(value as Land, this.category);
        else this.switchTo(this.land, value as Category);
      }
      return;
    }
    for (let i = 0; i < this.nodes.length; i++) {
      const [nx, ny] = this.nodeAt(this.nodes[i]);
      if (Math.hypot(x - nx, y - ny) > this.nodeRadius(this.nodes[i]) * 1.4) continue;
      if (phase === "move" && this.selected !== i) {
        this.selected = i;
        this.app.chip.blip();
      }
      if (phase === "down") {
        this.selected = i;
        this.choose(this.nodes[i]);
      }
      return;
    }
    // A click on the ground, mid-walk, is also "get on with it".
    if (phase === "down" && this.walk) this.skipWalk();
  }

  /**
   * Choosing a street: she walks there, and the quest opens when she arrives.
   *
   * Every node is reachable (§4.7), so a click can be from node 1 to node 24.
   * The duration is therefore capped and grows only gently with distance — the
   * camera carries the ground past, the legs do not have to cover it in real
   * time. Exponential in and out, which is almost still, then very fast, then
   * almost still: it needs a longer duration than a cubic to read as
   * deliberate and a shorter one than you expect once the distance is large.
   */
  private choose(n: MapNode | undefined): void {
    if (!n) return;
    if (this.walk) return this.skipWalk();
    if (this.meiOn === n.quest_id) return this.open(n);
    this.app.chip.blip();
    this.pendingOpen = n;
    this.walkTo(n);
  }

  /** Put her at the end of the walk on the next frame, and act on arrival. */
  private skipWalk(): void {
    this.walk?.tween.finish();
  }

  private open(n: MapNode | undefined): void {
    if (!n) return;
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
      ([f, t]) => (f === a.quest_id && t === b.quest_id) || (f === b.quest_id && t === a.quest_id),
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

  private walkTo(to: MapNode, fanfare = false): void {
    const from = this.nodes.find((n) => n.quest_id === this.meiOn);
    const a: [number, number] = from ? [from.x, from.y] : this.mei;
    const { c } = from ? this.road(from, to) : { c: [(a[0] + to.x) / 2, (a[1] + to.y) / 2] };
    const A = this.plate[2] / Math.max(1, this.plate[3]);
    // Tuned by eye against the real map. A neighbouring street is a little
    // under half a second; the whole diagonal is a little under a second, and
    // never more, however far it is.
    const dist = Math.hypot((to.x - a[0]) * A, to.y - a[1]);
    const dur = Math.min(0.92, Math.max(0.42, 0.34 + dist * 0.55)) * motionScale();
    this.walk = {
      a,
      c: from ? (c as [number, number]) : [((a[0] + to.x) / 2) * A, (a[1] + to.y) / 2],
      b: [to.x, to.y],
      tween: new Tween(dur),
    };
    this.meiOn = to.quest_id;
    if (fanfare) this.app.chip.coin();
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
  /**
   * How tall the street plate under the map has to be.
   *
   * It was `108 * s` in landscape and `150 * s` in portrait — numbers tuned by
   * eye against the old type sizes, which is fine right up until the type
   * changes. When the chrome grew, the last line of the plate ("ENTER and go
   * in") slid under the footer bar in Korean. This is `drawInfo`'s own
   * arithmetic, run ahead of it, so the two cannot drift again.
   */
  private infoH(): number {
    const { layout } = this.app;
    const s = layout.uiScale();
    const f = ensureFonts(s);
    // On a phone the title takes two lines and the facts stack — see
    // `drawInfo` — and the plate is measured for both.
    const phone = layout.isPhone();
    const facts = phone
      ? difficultyH() + Math.round(8 * s) + f.stationSm.height + f8(s) + f.small.height
      : Math.max(difficultyH(), f.stationSm.height + f8(s) + f.small.height);
    return (
      Math.round(14 * s) +
      f.station.height * (phone ? 2 : 1) +
      Math.round(10 * s) +
      facts +
      Math.round(12 * s) +
      // Two lines for the last line: "CLEARED · 2/3 STARS · ENTER to walk
      // back in" wraps beside the stamp, and one line's room put "walk back
      // in" over the plate's bottom rim.
      f.small.height * (phone ? 3 : 2) +
      Math.round(14 * s) +
      (layout.isPortrait() ? Math.round(30 * s) : 0)
    );
  }

  private mapPlate(): Rect {
    const { layout } = this.app;
    const s = layout.uiScale();
    const portrait = layout.isPortrait();
    const top = Math.round(38 * s) + Math.round(8 * s) + this.barLayout().h + Math.round(10 * s);
    const bottom = layout.vh - footerH(layout) - Math.round(8 * s);
    const infoH = this.infoH();
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
    const accent = landColour(this.land);
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
      // In front of the ground, behind the markers. The wires are scenery and
      // the markers are the game: the first frame with them on top put the
      // awning squarely over node 1, which on this pack stands in the very
      // corner of the map.
      this.drawWires(g);
      this.drawEdges(g);
      this.drawNodes(g);
      this.drawMei(g);
    });
    g.restore();

    header(g, this.app, `${landName(this.land)} · ${this.category.toUpperCase()}`);
    // Outside the plate's lift and alpha: the switcher is chrome, and chrome
    // that fades in with the ground reads as part of the ground.
    this.drawBar(g, Math.round(38 * s) + Math.round(8 * s));
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
    footer(
      g,
      layout,
      // ESC is not in this line any more: ALL MAPS is a visible button that
      // does the same thing, which was the point of adding it. F1 is, because
      // the orientation toggle is the thing a player on a phone reaches for and
      // this is the screen they are on when they want it.
      t("map.footer"),
    );
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
   * Silhouette carries the meaning, not colour: a spiked gear for a boss, a
   * plain coin for an ordinary street. Node 12 is THE AUTOCOMPLETE and it used
   * to be drawn exactly like node 5.
   *
   * `node_locked` is deliberately not used. Every street is reachable now, and
   * a padlock on a door that opens is worse than no padlock at all. The art is
   * still in the set; it is simply not what this map means any more.
   */
  private markerFor(n: MapNode): string {
    return n.kind === "boss" ? "node_boss" : "node_quest";
  }

  /**
   * The street the route suggests next: the first one, in the pack's own
   * order, that has not been cleared.
   *
   * This is what is left of the gate, and it is the part worth keeping. The
   * packs are written in an order and a player who has just cleared node 3 is
   * asking where to go, not asking for permission.
   */
  private nextNode(): MapNode | undefined {
    return this.nodes.find((n) => n.state !== "cleared");
  }

  private drawNodes(g: Ctx): void {
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
    // Back to front, so a near marker overlaps a far one rather than the other
    // way round. On a tilted plane that is the difference between depth and a
    // pile of stickers.
    const next = this.nextNode();
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
      // The route's advice, and the only thing left of the old gate: the first
      // street not yet cleared wears a chevron. Nothing is forbidden; this
      // just answers "where was I".
      if (n.quest_id === next?.quest_id && !chosen) {
        const bob = Math.sin(this.t * 3) * rr * 0.12;
        g.fillStyle = css(Theme.coin, 0.9);
        g.beginPath();
        g.moveTo(x, y - rr * 1.5 - bob);
        g.lineTo(x - rr * 0.4, y - rr * 2.1 - bob);
        g.lineTo(x + rr * 0.4, y - rr * 2.1 - bob);
        g.closePath();
        g.fill();
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
   * Only the **top half of the source** is used, and that is a decision
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
    // 55% of the source: the wire web and the tops of the poles, stopping at the
    // row where the hanging sign panels begin.
    const srcH = Math.round(art.naturalHeight * 0.55);
    // Wider than the plate, so there is something to slide.
    const w = pw * 1.16;
    const h = (w * srcH) / art.naturalWidth;
    // Two things move it: the camera, while it is pushing into a street, and a
    // slow idle drift, because wires over a street are never quite still. The
    // drift is dt-driven like everything else, so a captured frame is the same
    // frame every run.
    const drift = reducedMotion() ? 0 : Math.sin(this.t * 0.21) * pw * 0.012;
    const slide = (0.5 - lu) * pw * 0.5 + drift;
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
    this.drawNeon(g, py - Math.round(h * 0.06) + h * 0.62);
  }

  /**
   * The signs hanging off the wires.
   *
   * `fg_wires` stops at 55% of its source because the four hanging panels
   * below that line are the size of shop awnings and sat over nodes 1 to 9.
   * The wires are still a place to hang something from, though, and
   * `neon_signs` is six signs at a size that fits: they drop into the band
   * `fg_wires` gave up, above the first row of nodes, and they are the one
   * thing on this screen that changes colour while you are reading it.
   *
   * The cycle is in `gfx/neon.ts` and it is a real palette cycle — the same
   * slot drawn from a different frame of the strip on each beat, in the order
   * of the hues measured in `art/palette.json`.
   */
  private drawNeon(g: Ctx, y: number): void {
    const art = this.app.assets?.picture("neon_signs");
    if (!art) return;
    const s = this.app.layout.uiScale();
    const [px, py, pw, ph] = this.plate;
    const h = Math.min(Math.round(56 * s), Math.round(ph * 0.13));
    // Fewer in portrait: the plate is narrower there and six signs across it
    // is a fence rather than a street.
    const count = this.app.layout.isPortrait() ? 4 : 6;
    // Inset, so a sign never hangs over the plate's own gold edge.
    const inset = Math.round(pw * 0.06);
    this.neon.draw(
      g,
      this.app.assets ?? null,
      art,
      px + inset,
      Math.max(py, y),
      pw - inset * 2,
      h,
      count,
      0.92,
    );
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
    const h = Math.round(58 * s * depth);
    const walking = this.walk !== null;
    // The step is driven by the walk's own progress, not by wall time, so a
    // captured frame is the same frame every run.
    const phase = walking ? (this.walk as { tween: Tween }).tween.raw * 14 : this.t * 2.2;
    // With a real four-frame cycle the body does not need a bob; the sprite has
    // one in it. The lozenge fallback still gets one, and so does standing.
    const bob =
      strip && walking
        ? 0
        : walking
          ? Math.abs(Math.sin(phase)) * h * 0.1
          : Math.sin(phase) * h * 0.03;

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
      // Ten a second, on the scene clock rather than on the walk's progress:
      // the cadence of a walk is a property of the legs, not of how far there
      // is to go, and driving it off the tween made a short hop flicker and a
      // long one crawl. `t` is accumulated `dt`, so a captured frame is still
      // the same frame every run.
      //
      // Ten rather than six because frames 2 and 4 are both passing poses and
      // are not identical: slower than this and the cycle reads as a limp.
      const i = walking ? Math.floor(this.t * 10) % n : 1;
      const bx = strip.boxes[i] ?? strip.boxes[0];
      const cellH = strip.fh;
      const scale = h / cellH;
      const feet = (bx ? bx.feet : cellH) * scale;
      const cw = strip.fw * scale;
      g.save();
      g.translate(x, y - feet - bob);
      if (this.facing < 0) g.scale(-1, 1);
      g.drawImage(sheet, i * strip.fw, 0, strip.fw, strip.fh, -cw / 2, 0, cw, cellH * scale);
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
    const h = layout.vh - footerH(layout) - top - Math.round(8 * s);
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
    const bossArt = n.kind === "boss" ? (BOSS[slot(this.land, this.category)] ?? "") : "";
    const boss = n.state === "cleared" ? null : (this.app.assets?.picture(bossArt) ?? null);
    const artW = n.state === "cleared" || boss ? stampW : 0;
    const textW = iw - artW - (artW ? Math.round(14 * s) : 0);

    if (boss) {
      const d = Math.min(h - Math.round(12 * s), Math.round(96 * s));
      const box = this.app.assets?.box.get(bossArt);
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
    const titleText = `${String(n.node).padStart(2, "0")}  ${n.title}${n.kind === "boss" ? `  ·  ${t("map.boss")}` : ""}`;
    // Wrapped, and advanced by the lines it took: a title that wrapped on a
    // phone was printed through the facts under it.
    const titleLines = wrap(fonts.station, titleText, textW).slice(0, 2);
    for (const line of titleLines) {
      printf(g, fonts.station, line, ix, iy, textW, "left");
      iy += fonts.station.height;
    }
    iy += Math.round(10 * s);

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
    // Three columns across the whole width of the plate, not three things
    // huddled at the left end of it. The slab is as wide as the overworld and
    // the facts have to be laid out as if that width were on purpose.
    // Three columns, or — on a phone, where three columns are each a word
    // wide — the difficulty on a row of its own and the two counts under it.
    const stacked = layout.isPhone();
    const col = stacked ? textW / 2 : textW / 3;
    const barW = Math.min(Math.round(150 * s), Math.round((stacked ? textW : col) * 0.8));
    drawDifficulty(g, ix, iy, barW, n.difficulty, 5);
    if (stacked) iy += difficultyH() + Math.round(8 * s);

    const label = (text: string, lx: number, col2 = Theme.dim) => {
      g.fillStyle = css(col2);
      printf(g, fonts.stationSm, text, lx, iy, textW, "left");
    };
    const valueY = iy + fonts.stationSm.height + Math.round(f8(s));

    const starX = stacked ? ix : ix + Math.round(col);
    label(t("map.stars"), starX);
    drawStars(
      g,
      starX + Math.round(7 * s),
      valueY + Math.round(5 * s),
      Math.round(7 * s),
      n.stars,
      3,
    );

    const tryX = stacked ? ix + Math.round(col) : ix + Math.round(col * 2);
    label(t("map.tries"), tryX);
    g.fillStyle = css(n.attempts > 0 ? Theme.cream : Theme.dim);
    printf(g, fonts.small, String(n.attempts), tryX, valueY, textW, "left");

    iy += stacked
      ? fonts.stationSm.height + Math.round(f8(s)) + fonts.small.height + Math.round(12 * s)
      : difficultyH() + Math.round(12 * s);

    // The one line that says what to do about it. `requires` is given by the
    // server (§5.2) so the lock can name the street it is waiting on rather
    // than saying "locked" and leaving the player to guess which of eleven.
    // Never a refusal. §4.7: every street is reachable, so the line either
    // says what happened here or points at where the route goes next.
    const next = this.nextNode();
    let line: string;
    let colour = Theme.coin;
    if (n.state === "cleared") {
      line = t("map.clearedLine", { stars: n.stars });
      colour = Theme.admit;
    } else if (next && next.quest_id === n.quest_id) {
      line = n.kind === "boss" ? t("map.nextBoss") : t("map.next");
    } else {
      line = n.kind === "boss" ? t("map.bossHere") : t("map.enterToGo");
    }
    g.fillStyle = css(colour);
    for (const l of wrap(fonts.small, line, textW).slice(0, layout.isPhone() ? 3 : 2)) {
      printf(g, fonts.small, l, ix, iy, textW, "left");
      iy += fonts.small.height;
    }
  }

  resized(): void {
    this.plate = this.mapPlate();
  }
}
