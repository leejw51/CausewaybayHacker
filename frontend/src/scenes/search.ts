/**
 * One box, 126 streets — and, for every hit, *why* it is a hit.
 *
 * SPEC §8 puts three rankings behind one field: BM25 over `title, brief,
 * concepts, story` with a title weighted four times a story, a brute-force
 * cosine over hashed 512-dimension vectors, and `unified`, which is the default
 * and is reciprocal-rank fusion over the two. The response carries the
 * component scores as well as the fused one, and §8.3 says why in as many
 * words: "so the search screen can show *why* something matched".
 *
 * This screen is built around that sentence. A result is not a title and a
 * score; it is a title, the words the text index highlighted, and two small
 * bars saying which of the two indexes found it and how much each liked it.
 * "BOTH INDEXES AGREE" is the interesting case and it is the one a plain
 * ranked list throws away — under RRF, agreement is the entire reason the fused
 * order differs from either input order.
 *
 * Nothing is locked (§4.7), so a hit is a door: clicking one opens the quest.
 *
 * `search.query` is live (§4.12). The screen still probes and renders what
 * comes back rather than assuming a shape, so a server built without the
 * index — `unavailable` (§3.3) — gets the "still being built" line in the
 * story's voice instead of a broken list.
 */
import type { App, Scene } from "../app";
import { ensureFonts, print, printf, width, wrap, type Font } from "../engine/text";
import { css, Theme, type RGBA } from "../engine/theme";
import { clipped, fill, pixBtn, well, type Ctx, type Rect } from "../engine/ui";
import {
  arriving,
  Buttons,
  footer,
  frame,
  header,
  landColour,
  titledPanel,
  landName,
} from "../ui/chrome";
import { seconds, Tween } from "../engine/motion";
import { Overlay } from "../ui/overlay";
import { WireError } from "../net/client";
import { playerText } from "../net/protocol";
import type { Category, Land, NodeState, SearchHit, SearchMode } from "../net/protocol";
import { unbuilt, unbuiltLine } from "../net/milestone";
import { onLocale, t } from "../i18n";
import { auxHeight, auxRow, drawAux, AUX_HINT, openAux } from "../ui/auxnav";
import { drawNotice, type Notice } from "../ui/notice";
import { emptySearch } from "../ui/coach";
import { component, foundLine, normalise, snippetRuns, type Bars } from "../ui/relevance";
import { QuestScene } from "./quest";

const MODES: readonly SearchMode[] = ["unified", "bm25", "semantic"];

/** What each mode is, in the one line there is room for. */
const MODE_LINE: Record<SearchMode, () => string> = {
  unified: () => t("search.modeUnified"),
  bm25: () => t("search.modeText"),
  semantic: () => t("search.modeMeaning"),
};

/** `state` is offered as two values, not three: §4.7 never locks anything. */
const STATES = (): ReadonlyArray<{ id: string; label: string; value: NodeState | null }> => [
  { id: "state:any", label: t("search.any"), value: null },
  { id: "state:open", label: t("search.open"), value: "open" },
  { id: "state:cleared", label: t("search.cleared"), value: "cleared" },
];

const LANDS = (): ReadonlyArray<{ id: string; label: string; value: Land | null }> => [
  { id: "land:any", label: t("search.any"), value: null },
  { id: "land:rust", label: t("search.rust"), value: "rust" },
  { id: "land:go", label: t("search.go"), value: "go" },
  { id: "land:cpp", label: t("search.cpp"), value: "cpp" },
  { id: "land:python", label: t("search.python"), value: "python" },
  { id: "land:pytorch", label: t("search.pytorch"), value: "pytorch" },
];

const CATS = (): ReadonlyArray<{ id: string; label: string; value: Category | null }> => [
  { id: "cat:any", label: t("search.any"), value: null },
  { id: "cat:basic", label: t("search.basic"), value: "basic" },
  { id: "cat:advanced", label: t("search.adv"), value: "advanced" },
  { id: "cat:hacker", label: t("search.hacker"), value: "hacker" },
];

/** §4.12: default 20, max 100. Twenty is plenty for a screen you scroll. */
const LIMIT = 20;

export class SearchScene implements Scene {
  readonly name = "search";
  /** No mood of its own — the chooser's city is the right one for a lobby. */
  readonly mood = "lands" as const;
  land: Land = "rust";

  private readonly field: HTMLTextAreaElement;
  private readonly overlay: Overlay;
  private offLocale?: () => void;
  private fieldRect: Rect = [0, 0, 0, 0];

  private readonly chips = new Buttons();
  private readonly hitBtns = new Buttons();
  private readonly nav = new Buttons();

  private mode: SearchMode = "unified";
  private filterLand: Land | null = null;
  private filterCat: Category | null = null;
  private filterState: NodeState | null = null;

  private hits: SearchHit[] = [];
  private bars: Bars[] = [];
  private tookMs = 0;
  private answeredMode: SearchMode = "unified";
  /** The query the results on screen belong to, so the count cannot lie. */
  private searched = "";
  private busy = false;
  private notice: Notice | null = null;

  private scroll = 0;
  private overflow = 0;
  private readonly leftIn = new Tween(seconds("panel"));
  private readonly rightIn = new Tween(seconds("panel"), seconds("stagger"));

  constructor(private readonly app: App) {
    // A textarea rather than an input, for the same reason the login field is
    // one: `dev/capture.ts` re-draws the overlay into a screenshot and only
    // knows how to read a textarea's value. An `<input>` would photograph as an
    // empty well with no query in it — on the one screen whose whole subject is
    // the query.
    const el = document.createElement("textarea");
    el.className = "cwb-field";
    el.rows = 1;
    el.spellcheck = false;
    el.autocapitalize = "off";
    el.autocomplete = "off";
    el.setAttribute("autocorrect", "off");
    el.placeholder = t("search.placeholder");
    this.offLocale = onLocale(() => {
      el.placeholder = t("search.placeholder");
    });
    // Its own listener, because `App` forwards a keystroke out of the overlay
    // only when Ctrl or Cmd is held — a bare Enter inside a field never reaches
    // `Scene.key`, and wiring it there would look like a dead button.
    el.addEventListener("keydown", (ev) => {
      if (ev.key !== "Enter") return;
      ev.preventDefault();
      void this.run();
    });
    this.field = el;
    this.overlay = new Overlay(app.overlay, app.layout, el);
  }

  enter(): void {
    queueMicrotask(() => this.field.focus());
  }

  leave(): void {
    this.offLocale?.();
    this.offLocale = undefined;
    this.overlay.destroy();
  }

  update(dt: number): void {
    this.leftIn.update(dt);
    this.rightIn.update(dt);
  }

  controls(): Buttons[] {
    return [this.chips, this.hitBtns, this.nav];
  }

  // -- asking --------------------------------------------------------------

  private filters(): { land?: Land; category?: Category; state?: NodeState } | undefined {
    const f: { land?: Land; category?: Category; state?: NodeState } = {};
    if (this.filterLand) f.land = this.filterLand;
    if (this.filterCat) f.category = this.filterCat;
    if (this.filterState) f.state = this.filterState;
    // Omitted entirely rather than sent empty: §4.12 calls every filter
    // optional, and `{}` is a different frame from no key at all.
    return Object.keys(f).length > 0 ? f : undefined;
  }

  private async run(): Promise<void> {
    const q = this.field.value.trim();
    if (this.busy) return;
    if (q === "") {
      // §4.12 is explicit that an empty `q` returns no hits rather than
      // everything, so there is nothing to learn from sending it.
      this.hits = [];
      this.bars = [];
      this.searched = "";
      this.notice = null;
      return;
    }
    this.busy = true;
    this.notice = null;
    this.app.chip.select();
    const filters = this.filters();
    try {
      const res = await this.app.client.request("search.query", {
        q,
        mode: this.mode,
        limit: LIMIT,
        ...(filters ? { filters } : {}),
      });
      this.hits = res.hits ?? [];
      this.bars = normalise(this.hits);
      // The server says which mode it actually ran, and it is drawn instead of
      // the one that was asked for: a build that only has BM25 may answer a
      // `unified` request honestly, and a screen that captioned it "UNIFIED"
      // would be putting words in the server's mouth.
      this.answeredMode = res.mode ?? this.mode;
      this.tookMs = res.took_ms ?? 0;
      this.searched = q;
      this.scroll = 0;
    } catch (e) {
      this.hits = [];
      this.bars = [];
      this.searched = q;
      this.notice = this.explain(e);
      this.app.chip.fail();
    } finally {
      this.busy = false;
    }
  }

  /** §3.3: the server's English goes to the console, ours goes on the screen. */
  private explain(e: unknown): Notice {
    const gap = unbuilt(e);
    if (gap) {
      console.info("search.query is not built yet:", gap.developerMessage);
      return {
        head: unbuiltLine(t("search.unbuiltHead"), gap).toUpperCase(),
        body: t("search.unbuiltBody"),
        tone: "unbuilt",
      };
    }
    if (e instanceof WireError) {
      console.warn("search.query failed:", e.payload.code, e.payload.message, e.payload.detail);
      return { head: t("search.failedHead"), body: playerText(e.payload.code), tone: "fault" };
    }
    return { head: t("search.failedHead"), body: t("search.failedBody"), tone: "fault" };
  }

  // -- input ---------------------------------------------------------------

  key(name: string, ev: KeyboardEvent): void {
    if (name === "escape") {
      void openAux(this.app, "aux:maps");
      return;
    }
    if (name === "return" || name === "kpenter") {
      ev.preventDefault();
      void this.run();
    }
  }

  wheel(dy: number): void {
    this.scroll = Math.max(0, Math.min(this.overflow, this.scroll + dy));
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    if (phase === "move") {
      this.chips.hovered = this.chips.hit(x, y)?.id ?? null;
      this.hitBtns.hovered = this.hitBtns.hit(x, y)?.id ?? null;
      this.nav.hovered = this.nav.hit(x, y)?.id ?? null;
      return;
    }
    if (phase !== "down") return;
    const nav = this.nav.hit(x, y);
    if (nav) {
      this.app.chip.select();
      void openAux(this.app, nav.id);
      return;
    }
    const chip = this.chips.hit(x, y);
    if (chip) {
      this.app.chip.blip();
      this.apply(chip.id);
      return;
    }
    const hit = this.hitBtns.hit(x, y);
    if (hit?.id.startsWith("hit:")) this.open(hit.id.slice(4));
  }

  private apply(id: string): void {
    if (id === "go") return void this.run();
    if (id === "clear") {
      this.field.value = "";
      this.hits = [];
      this.bars = [];
      this.searched = "";
      this.notice = null;
      this.field.focus();
      return;
    }
    const [group, value] = id.split(":");
    if (group === "mode") this.mode = value as SearchMode;
    else if (group === "land") this.filterLand = value === "any" ? null : (value as Land);
    else if (group === "cat") this.filterCat = value === "any" ? null : (value as Category);
    else if (group === "state") this.filterState = value === "any" ? null : (value as NodeState);
    // A filter changed is a question changed: re-ask it rather than leaving the
    // old answer under a new set of chips, which is how a filter comes to look
    // like it does nothing.
    if (this.searched !== "") void this.run();
  }

  private open(questId: string): void {
    const hit = this.hits.find((h) => h.quest_id === questId);
    if (!hit) return;
    this.app.chip.select();
    void this.app.go(
      new QuestScene(this.app, hit.land as Land, hit.category as Category, hit.quest_id),
      "forward",
    );
  }

  // -- drawing -------------------------------------------------------------

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    header(g, this.app, t("search.title"));
    const f = frame(layout, layout.isPortrait() ? 0.42 : 0.34, 0.03);
    this.chips.reset();
    this.hitBtns.reset();

    arriving(g, f, "left", this.leftIn, () => this.drawAsk(g, f.left, f.scale));
    arriving(g, f, "right", this.rightIn, () => this.drawHits(g, f.right, f.scale));

    footer(g, layout, t("search.footer", { aux: AUX_HINT() }));
  }

  private drawAsk(g: Ctx, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const inner = titledPanel(g, rect, t("search.oneBox", { n: 126 }), Theme.coin);
    const [x, y, w, h] = inner;
    const gap = Math.round(8 * s);

    // The field. A well with a real element over it — the same arrangement the
    // login screen and the editor use, because a canvas has no caret and no
    // clipboard and a search box needs both.
    const fieldH = Math.max(this.app.layout.minTouchH(), fonts.small.height + Math.round(14 * s));
    well(g, x, y, w, fieldH);
    this.fieldRect = [x + 4, y + 4, w - 8, fieldH - 8];

    // The one action, and the way to empty the box, side by side under it.
    const btnH = Math.max(this.app.layout.minTouchH(), fonts.button.height + 20);
    const by = y + fieldH + gap;
    const half = Math.floor((w - gap) * 0.62);
    const goLabel = this.busy ? "…" : t("search.search");
    pixBtn(g, fonts.button, x, by, half, btnH, goLabel, {
      lit: !this.busy,
      hover: this.chips.hovered === "go",
      dim: this.busy,
    });
    this.chips.add({ id: "go", rect: [x, by, half, btnH], label: goLabel, dim: this.busy });
    const clearX = x + half + gap;
    const clearW = w - half - gap;
    pixBtn(g, fonts.button, clearX, by, clearW, btnH, t("search.clear"), {
      quiet: true,
      hover: this.chips.hovered === "clear",
    });
    this.chips.add({ id: "clear", rect: [clearX, by, clearW, btnH], label: t("search.clear") });

    let cy = by + btnH + gap * 2;
    cy = this.drawChipRow(
      g,
      t("search.how"),
      MODES.map((m) => ({
        id: `mode:${m}`,
        label:
          m === "unified"
            ? t("search.unified")
            : m === "bm25"
              ? t("search.text")
              : t("search.meaning"),
        on: m === this.mode,
      })),
      [x, cy, w, 0],
      s,
    );
    // What the chosen mode does, under the chips it belongs to. The three
    // rankings are the substance of §8 and a player who cannot tell them apart
    // will leave the default alone for ever — which is fine, but it should be a
    // choice rather than a shrug.
    g.fillStyle = css(Theme.cream, 0.6);
    const lines = wrap(fonts.small, MODE_LINE[this.mode](), w);
    for (let i = 0; i < lines.length && cy + fonts.small.height < y + h; i++) {
      printf(g, fonts.small, lines[i], x, cy, w, "left");
      cy += fonts.small.height;
    }
    cy += gap;

    cy = this.drawChipRow(
      g,
      t("search.land"),
      LANDS().map((l) => ({ id: l.id, label: l.label, on: l.value === this.filterLand })),
      [x, cy, w, 0],
      s,
    );
    cy = this.drawChipRow(
      g,
      t("search.road"),
      CATS().map((c) => ({ id: c.id, label: c.label, on: c.value === this.filterCat })),
      [x, cy, w, 0],
      s,
    );
    cy = this.drawChipRow(
      g,
      t("search.state"),
      STATES().map((st) => ({ id: st.id, label: st.label, on: st.value === this.filterState })),
      [x, cy, w, 0],
      s,
    );

    // The nav sits on the floor of the panel, not after the chips: it is the
    // way out and it has to be in the same place on all three screens.
    const navF = fonts.stationSm;
    const touch = this.app.layout.minTouchH();
    const navH = auxHeight(navF, w, touch);
    auxRow(this.nav, navF, [x, y + h - navH, w, navH], "search", touch);
    drawAux(g, this.nav, navF);

    // Last, so it lands over the well rather than under the panel that is still
    // arriving. While a panel is mid-flight the element is hidden outright —
    // a DOM box does not slide with a canvas and would sit in mid-air.
    if (this.leftIn.finished) this.overlay.place(this.fieldRect, fonts.small.size);
    else this.overlay.hide();
  }

  /** A labelled row of small pills. Painted here; hit-tested by `chips`. */
  private drawChipRow(
    g: Ctx,
    label: string,
    items: ReadonlyArray<{ id: string; label: string; on: boolean }>,
    rect: Rect,
    s: number,
  ): number {
    const fonts = ensureFonts(s);
    const f = fonts.stationSm;
    const [x, y, w] = rect;
    const pad = Math.round(7 * s);
    const gap = Math.round(5 * s);
    const h = Math.max(this.app.layout.minTouchH(), f.height + Math.round(10 * s));
    const labelW = width(f, t("search.state")) + pad;
    g.fillStyle = css(Theme.dim);
    printf(g, f, label, x, y + Math.round((h - f.height) / 2), labelW, "left");

    let cx = x + labelW + gap;
    let cy = y;
    for (const item of items) {
      const cw = width(f, item.label) + pad * 2;
      if (cx + cw > x + w && cx > x + labelW + gap) {
        cx = x + labelW + gap;
        cy += h + gap;
      }
      const hot = this.chips.hovered === item.id;
      fill(g, item.on ? Theme.coin : Theme.ink, cx, cy, cw, h, item.on ? 1 : hot ? 0.8 : 0.5);
      fill(g, item.on ? Theme.wood : Theme.dim, cx, cy + h - 2, cw, 2, item.on ? 1 : 0.6);
      g.fillStyle = css(item.on ? Theme.ink : hot ? Theme.cream : Theme.cyan);
      printf(g, f, item.label, cx, cy + Math.round((h - f.height) / 2), cw, "center");
      this.chips.add({ id: item.id, rect: [cx, cy, cw, h], label: item.label });
      cx += cw + gap;
    }
    return cy + h + Math.round(6 * s);
  }

  private drawHits(g: Ctx, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    // The head counts only what actually came back. It said "0 OF 126 ·
    // UNIFIED · 0 MS" over an `unavailable` panel once, which is three
    // measurements of a search that never ran.
    const title =
      this.notice || this.searched === ""
        ? t("search.results")
        : t("search.resultLine", {
            n: this.hits.length,
            total: 126,
            mode: this.answeredMode.toUpperCase(),
            ms: this.tookMs,
          });
    const inner = titledPanel(g, rect, title, Theme.cyan);
    const [x, y, w, h] = inner;

    if (this.notice) {
      drawNotice(g, this.app, inner, this.notice);
      this.overflow = 0;
      return;
    }
    if (this.hits.length === 0) {
      const empty = emptySearch(this.field.value, this.searched !== "");
      drawNotice(g, this.app, inner, {
        head: empty.head,
        body: empty.body,
        tone: this.searched === "" ? "empty" : "empty",
      });
      this.overflow = 0;
      return;
    }

    const rowH = this.rowHeight(fonts, w, s);
    const total = this.hits.length * rowH;
    this.overflow = Math.max(0, total - h);
    this.scroll = Math.min(this.scroll, this.overflow);

    clipped(g, x, y, w, h, () => {
      let ry = y - this.scroll;
      for (let i = 0; i < this.hits.length; i++) {
        if (ry + rowH > y && ry < y + h)
          this.drawHit(g, this.hits[i], this.bars[i], i, [x, ry, w, rowH], s);
        this.hitBtns.add({
          id: `hit:${this.hits[i].quest_id}`,
          rect: [x, Math.max(y, ry), w, Math.max(0, Math.min(ry + rowH, y + h) - Math.max(y, ry))],
          label: this.hits[i].title,
        });
        ry += rowH;
      }
    });

    if (this.overflow > 0) {
      // The same thin rail the quest brief uses: enough to say there is more,
      // not enough to be furniture.
      const railH = Math.max(20, (h * h) / (h + this.overflow));
      const railY = y + ((h - railH) * this.scroll) / this.overflow;
      fill(g, Theme.ink, x + w - 3, y, 3, h, 0.5);
      fill(g, Theme.coin, x + w - 3, railY, 3, railH, 0.8);
    }
  }

  private rowHeight(fonts: ReturnType<typeof ensureFonts>, w: number, s: number): number {
    // Fixed, so the list can be scrolled by arithmetic rather than by measuring
    // every row twice. Two lines of snippet is what a three-line row can hold
    // and what a one-line snippet from FTS5 usually needs.
    void w;
    return (
      fonts.station.height +
      Math.round(4 * s) +
      fonts.stationSm.height +
      Math.round(6 * s) +
      fonts.small.height * 2 +
      Math.round(10 * s) +
      Math.round(10 * s)
    );
  }

  private drawHit(g: Ctx, hit: SearchHit, bars: Bars, i: number, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const [x, y, w, h] = rect;
    const hot = this.hitBtns.hovered === `hit:${hit.quest_id}`;
    const accent: RGBA = landColour(hit.land);
    const pad = Math.round(10 * s);

    fill(g, Theme.navy, x, y, w, h - Math.round(4 * s), hot ? 0.95 : 0.7);
    fill(g, accent, x, y, Math.round(4 * s), h - Math.round(4 * s), hot ? 1 : 0.6);
    if (hit.state === "cleared") {
      // Inside the row's own face, not on its bottom edge: a rule drawn in the
      // gap read as a divider belonging to the row *below* it, and green on
      // this screen means "you have cleared this one" and nothing else.
      fill(g, Theme.admit, x, y + h - Math.round(10 * s), w, 2);
    }

    // Rank first. Under RRF the position is the answer and the fused score is a
    // number somebody may want to check; putting the ordinal on the row makes
    // "why is this third" a question the rest of the row can answer.
    const ord = `${i + 1}`.padStart(2, "0");
    g.fillStyle = css(Theme.dim);
    printf(g, fonts.stationSm, ord, x + pad, y + pad, width(fonts.stationSm, "88"), "left");
    const tx = x + pad + width(fonts.stationSm, "88") + Math.round(8 * s);
    const tw = w - (tx - x) - pad;

    g.fillStyle = css(hot ? Theme.coin : Theme.cream);
    printf(g, fonts.station, hit.title.toUpperCase(), tx, y + pad, tw, "left");

    const metaY = y + pad + fonts.station.height + Math.round(4 * s);
    g.fillStyle = css(accent);
    const meta = `${landName(hit.land)} · ${hit.category.toUpperCase()}${
      hit.state === "cleared" ? " · CLEARED" : ""
    }`;
    printf(g, fonts.stationSm, meta, tx, metaY, tw, "left");

    // The why. Two bars and their numbers, on the right of the meta line.
    this.drawWhy(g, hit, bars, [tx, metaY, tw, fonts.stationSm.height], s);

    const snipY = metaY + fonts.stationSm.height + Math.round(6 * s);
    drawRuns(
      g,
      fonts.small,
      snippetRuns(hit.snippet ?? ""),
      tx,
      snipY,
      tw,
      2,
      hot ? Theme.cream : [Theme.cream[0], Theme.cream[1], Theme.cream[2], 0.7],
      Theme.coin,
    );
  }

  /**
   * The two component bars, right-aligned on the meta line.
   *
   * Each bar is scaled inside its own column (see `ui/relevance.ts`) because
   * §8.3 is explicit that a BM25 score and a cosine are not on one scale. The
   * label under each says which index it is; a missing component draws as an
   * empty socket with a dash, because "this index did not rank it" is itself
   * the most informative thing a search screen can say.
   */
  private drawWhy(g: Ctx, hit: SearchHit, bars: Bars, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const f = fonts.stationSm;
    const [x, y, w] = rect;
    const barW = Math.round(46 * s);
    const barH = Math.max(3, Math.round(5 * s));
    const gap = Math.round(8 * s);
    const line = foundLine(hit, this.answeredMode);
    const lineW = width(f, line);
    const pairW = (barW + width(f, "COS") + Math.round(4 * s)) * 2 + gap;
    if (w < pairW + lineW + gap * 2) {
      // Too narrow for both: the sentence wins. It is the half a person reads.
      g.fillStyle = css(Theme.cyan, 0.8);
      printf(g, f, line, x, y, w, "right");
      return;
    }
    let cx = x + w - pairW;
    g.fillStyle = css(Theme.cyan, 0.8);
    printf(g, f, line, x, y, cx - x - gap, "right");

    const pair: Array<[string, number | null, number | null, RGBA]> = [
      ["TXT", bars.bm25, hit.bm25, Theme.coin],
      ["COS", bars.cosine, hit.cosine, Theme.cyan],
    ];
    for (const [label, frac, raw, col] of pair) {
      g.fillStyle = css(Theme.dim);
      printf(g, f, label, cx, y, width(f, "COS"), "left");
      const bx = cx + width(f, "COS") + Math.round(4 * s);
      const byy = y + Math.round((f.height - barH) / 2);
      fill(g, Theme.ink, bx, byy, barW, barH, 0.8);
      if (frac === null) {
        // An empty socket, not a zero-length bar: "not in that ranking" (§5.5)
        // and "ranked last" are different facts and must not draw the same.
        for (let i = 0; i < 3; i++) {
          fill(g, Theme.dim, bx + i * Math.round(6 * s) + 2, byy + 1, 2, barH - 2, 0.6);
        }
      } else {
        fill(g, col, bx, byy, Math.max(2, Math.round(barW * frac)), barH);
      }
      g.fillStyle = css(Theme.dim);
      const num = component(raw);
      printf(g, f, num, bx, y + f.height + Math.round(1 * s), barW, "left");
      cx = bx + barW + gap;
    }
  }

  resized(): void {
    this.scroll = 0;
  }
}

/**
 * Draw `runs` wrapped into `w`, with the FTS5-marked words in `hot`.
 *
 * Word by word rather than line by line, because the highlight can start and
 * stop in the middle of a line and `printf` can only paint one colour. It stops
 * at `maxLines` and returns the y it reached, so a fixed-height row cannot be
 * overrun by a long snippet.
 */
function drawRuns(
  g: Ctx,
  f: Font,
  runs: ReadonlyArray<{ text: string; hit: boolean }>,
  x: number,
  y: number,
  w: number,
  maxLines: number,
  plain: RGBA,
  hot: RGBA,
): number {
  let cx = x;
  let cy = y;
  let lines = 1;
  for (const run of runs) {
    for (const token of run.text.split(/(\s+)/)) {
      if (token === "") continue;
      const tw = width(f, token);
      if (cx > x && cx + tw > x + w) {
        if (lines >= maxLines) return cy + f.height;
        cy += f.height;
        cx = x;
        lines++;
        if (token.trim() === "") continue;
      }
      g.fillStyle = css(run.hit ? hot : plain);
      print(g, f, token, cx, cy);
      cx += tw;
    }
  }
  return cy + f.height;
}
