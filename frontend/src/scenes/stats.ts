/**
 * The record — and the one screen where this game's premise is visible.
 *
 * *Your mistakes are the curriculum.* `stats.summary` is the scoreboard and
 * `stats.history` is the log, but `stats.mistakes` is the reason the other two
 * exist: SPEC §7.2 says that on every attempt the kinds you made have their
 * `cleared_since` reset to zero and every kind you *did not* make has it
 * incremented, and that at five a kind "is considered learned and drops out of
 * the AI plan's priority list, without being deleted".
 *
 * That counter is the most motivating number in the product, so it is drawn as
 * five pips and a sentence rather than as a field. "You have not done this in
 * four submits — one to go" is a thing a person wants to finish. `cleared_since:
 * 4` is not.
 *
 * §4.14 returns only the kinds below the line by default. This screen asks with
 * `include_learned: true` and keeps the beaten ones in their own section
 * underneath, because a drill list that silently drops a kind the moment it is
 * beaten throws away the only evidence the player ever gets that the loop
 * worked.
 *
 * The shelf (§4.14b) is the other half. DESIGN drew `badge_slot` — an empty
 * recessed socket — precisely so an unearned badge reads as a thing you can go
 * and get rather than as nothing, so the shelf draws the whole catalogue and
 * fills in what has been earned.
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf, width, wrap } from "../engine/text";
import { css, Theme, type RGBA } from "../engine/theme";
import { clipped, fill, type Ctx, type Rect } from "../engine/ui";
import { arriving, Buttons, footer, frame, GO, header, RUST, titledPanel } from "../ui/chrome";
import { seconds, Tween } from "../engine/motion";
import { WireError } from "../net/client";
import { playerText } from "../net/protocol";
import type { AttemptBrief, Award, Category, Land, MistakeStat, Responses } from "../net/protocol";
import { unbuilt, unbuiltLine } from "../net/milestone";
import { t as T, tn } from "../i18n";
import { auxHeight, auxRow, drawAux, AUX_HINT, openAux } from "../ui/auxnav";
import { drawNotice, type Notice } from "../ui/notice";
import { isLearned, LEARNED_AT, tamedFraction, tamedLine } from "../ui/coach";
import { shelf, shelfCount, type Slot } from "../ui/awards";
import { QuestScene } from "./quest";

type Summary = Responses["stats.summary"];

type Tab = "drill" | "shelf" | "log";

const TABS = (): ReadonlyArray<{ id: Tab; label: string }> => [
  { id: "drill", label: T("stats.drill") },
  { id: "shelf", label: T("stats.shelf") },
  { id: "log", label: T("stats.log") },
];

/** A fixed order, never the server's — `by_land` came back alphabetical. */
const LAND_ORDER: readonly Land[] = ["rust", "go"];

/** The colour a verdict is drawn in, in the log. Green only for accepted. */
function verdictCol(v: string): RGBA {
  if (v === "accepted") return Theme.admit;
  if (v === "timeout" || v === "output_limit") return Theme.coin;
  return Theme.red;
}

export class StatsScene implements Scene {
  readonly name = "stats";
  readonly mood = "result" as const;
  land: Land = "rust";

  private summary: Summary | null = null;
  private mistakes: MistakeStat[] = [];
  private history: AttemptBrief[] = [];
  private awards: Award[] = [];
  private notice: Notice | null = null;
  /** Which of the four calls failed, if any did, so one gap is not four. */
  private partial = "";

  private tab: Tab = "drill";
  private scroll: Record<Tab, number> = { drill: 0, shelf: 0, log: 0 };
  private overflow = 0;

  private readonly tabs = new Buttons();
  private readonly rows = new Buttons();
  private readonly nav = new Buttons();
  private readonly leftIn = new Tween(seconds("panel"));
  private readonly rightIn = new Tween(seconds("panel"), seconds("stagger"));

  constructor(private readonly app: App) {}

  async enter(): Promise<void> {
    const client = this.app.client;
    // All four at once. They are four independent reads of the same record and
    // nothing on this screen depends on the order they land in, so waiting for
    // each in turn would be four round trips to draw one page.
    const [summary, mistakes, history, awards] = await Promise.allSettled([
      client.request("stats.summary", {}),
      // `include_learned` is the whole reason the beaten kinds can be shown at
      // all: §4.14's default hides any kind whose `cleared_since` has reached
      // five, which is exactly the moment worth celebrating.
      client.request("stats.mistakes", { limit: 50, include_learned: true }),
      client.request("stats.history", { limit: 30 }),
      client.request("stats.awards", {}),
    ]);
    if (summary.status === "fulfilled") this.summary = summary.value;
    if (mistakes.status === "fulfilled") this.mistakes = mistakes.value.mistakes ?? [];
    if (history.status === "fulfilled") this.history = history.value.attempts ?? [];
    if (awards.status === "fulfilled") this.awards = awards.value.awards ?? [];

    const failures: Array<[string, unknown]> = [];
    if (summary.status === "rejected") failures.push(["stats.summary", summary.reason]);
    if (mistakes.status === "rejected") failures.push(["stats.mistakes", mistakes.reason]);
    if (history.status === "rejected") failures.push(["stats.history", history.reason]);
    if (awards.status === "rejected") failures.push(["stats.awards", awards.reason]);
    if (failures.length > 0) this.take(failures);
  }

  /**
   * What to say when some of the four did not answer.
   *
   * Named individually rather than as one red banner: `stats.awards` is a
   * §4.14b addition and a server that predates it answers `not_found` for that
   * one call while the other three are perfectly good. A screen that blanked
   * itself over that would hide a working record behind a missing shelf.
   */
  private take(failures: Array<[string, unknown]>): void {
    for (const [type, reason] of failures) {
      const gap = unbuilt(reason);
      if (gap) {
        console.info(`${type} is not built yet:`, gap.developerMessage);
        continue;
      }
      if (reason instanceof WireError) {
        console.warn(`${type} failed:`, reason.payload.code, reason.payload.message);
      }
    }
    const names = failures.map(([t]) => t.replace("stats.", "")).join(", ");
    this.partial = T("stats.unbuilt", { names });
    if (failures.length === 4) {
      const first = failures[0][1];
      const gap = unbuilt(first);
      this.notice = gap
        ? {
            head: unbuiltLine(T("stats.emptyHead"), gap).toUpperCase(),
            body: T("stats.emptyBody"),
            tone: "unbuilt",
          }
        : {
            head: T("stats.failedHead"),
            body:
              first instanceof WireError ? playerText(first.payload.code) : T("stats.failedBody"),
            tone: "fault",
          };
    }
  }

  update(dt: number): void {
    this.leftIn.update(dt);
    this.rightIn.update(dt);
  }

  controls(): Buttons[] {
    return [this.tabs, this.rows, this.nav];
  }

  key(name: string): void {
    if (name === "escape") return void openAux(this.app, "aux:maps");
    if (name === "q" || name === "left") return this.cycle(-1);
    if (name === "e" || name === "right") return this.cycle(1);
  }

  private cycle(step: number): void {
    const i = TABS().findIndex((t) => t.id === this.tab);
    this.tab = TABS()[(i + step + TABS().length) % TABS().length].id;
    this.app.chip.blip();
  }

  wheel(dy: number): void {
    this.scroll[this.tab] = Math.max(0, Math.min(this.overflow, this.scroll[this.tab] + dy));
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    if (phase === "move") {
      this.tabs.hovered = this.tabs.hit(x, y)?.id ?? null;
      this.rows.hovered = this.rows.hit(x, y)?.id ?? null;
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
    const tab = this.tabs.hit(x, y);
    if (tab) {
      this.tab = tab.id.slice(4) as Tab;
      this.app.chip.blip();
      return;
    }
    const row = this.rows.hit(x, y);
    if (row?.id.startsWith("quest:")) this.open(row.id.slice(6));
  }

  /**
   * A mistake row is a door. `MistakeStat.example_quest_id` is the last street
   * this kind happened on (§5.6), and "go and fix the one that caught you" is
   * the only useful thing to do with a list of your own mistakes.
   */
  private open(questId: string): void {
    const parts = questId.split(".");
    if (parts.length < 2) return;
    const [land, category] = parts as [Land, Category];
    if (land !== "rust" && land !== "go") return;
    if (category !== "basic" && category !== "advanced" && category !== "hacker") return;
    this.app.chip.select();
    void this.app.go(new QuestScene(this.app, land, category, questId), "forward");
  }

  // -- drawing -------------------------------------------------------------

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    header(g, this.app, T("stats.title"));
    const f = frame(layout, layout.isPortrait() ? 0.38 : 0.34, 0.03);
    this.tabs.reset();
    this.rows.reset();

    arriving(g, f, "left", this.leftIn, () => this.drawSummary(g, f.left, f.scale));
    arriving(g, f, "right", this.rightIn, () => this.drawTabbed(g, f.right, f.scale));

    footer(g, layout, T("stats.footer", { aux: AUX_HINT() }));
  }

  private drawSummary(g: Ctx, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const inner = titledPanel(g, rect, T("stats.where"), Theme.coin);
    const [x, y, w, h] = inner;
    const touch = this.app.layout.minTouchH();
    const navH = auxHeight(fonts.stationSm, w, touch);
    const floor = y + h - navH - Math.round(8 * s);

    if (!this.summary) {
      if (this.notice) drawNotice(g, this.app, [x, y, w, floor - y], this.notice);
      else {
        drawNotice(g, this.app, [x, y, w, floor - y], {
          head: T("stats.readingHead"),
          body: T("stats.readingBody"),
          tone: "empty",
        });
      }
      this.drawNav(g, [x, y + h - navH, w, navH], fonts.stationSm, touch);
      return;
    }

    const sum = this.summary;
    let cy = y;

    // The one big number. Cleared out of the whole world, with the bar under
    // it, because the whole world is what the map never shows you at once.
    const bigH = fonts.title.height;
    g.fillStyle = css(Theme.coin);
    printf(g, fonts.title, `${sum.cleared}`, x, cy, w, "left");
    g.fillStyle = css(Theme.cream, 0.7);
    printf(
      g,
      fonts.stationSm,
      T("stats.clearedOf", { total: sum.total }),
      x + width(fonts.title, `${sum.cleared}`) + Math.round(10 * s),
      cy + bigH - fonts.stationSm.height - Math.round(4 * s),
      w,
      "left",
    );
    cy += bigH + Math.round(6 * s);
    const barH = Math.max(4, Math.round(7 * s));
    fill(g, Theme.ink, x, cy, w, barH, 0.8);
    if (sum.total > 0) {
      fill(g, Theme.admit, x, cy, Math.round((w * sum.cleared) / sum.total), barH);
    }
    cy += barH + Math.round(12 * s);

    // The four facts, two by two. `accuracy` is 0..1 and is printed as a
    // percentage with no decimal: 22% is a fact and 0.2222222 is a float.
    const cell = Math.floor((w - Math.round(8 * s)) / 2);
    const facts: Array<[string, string, RGBA]> = [
      [T("stats.attempts"), `${sum.attempts}`, Theme.cream],
      [T("stats.accepted"), `${Math.round((sum.accuracy ?? 0) * 100)}%`, Theme.cyan],
      [T("stats.streak"), tn("stats.days", sum.streak_days), Theme.brick],
      [T("stats.stars"), `${sum.stars}`, Theme.coin],
    ];
    for (let i = 0; i < facts.length; i++) {
      const [label, value, col] = facts[i];
      const fx = x + (i % 2) * (cell + Math.round(8 * s));
      const fy =
        cy +
        Math.floor(i / 2) * (fonts.station.height + fonts.stationSm.height + Math.round(12 * s));
      g.fillStyle = css(Theme.dim);
      printf(g, fonts.stationSm, label, fx, fy, cell, "left");
      g.fillStyle = css(col);
      printf(
        g,
        fonts.station,
        value,
        fx,
        fy + fonts.stationSm.height + Math.round(3 * s),
        cell,
        "left",
      );
    }
    cy +=
      2 * (fonts.station.height + fonts.stationSm.height + Math.round(12 * s)) + Math.round(4 * s);

    // Per land, in a fixed order. The server returned them alphabetically —
    // `go` before `rust` — and a record whose rows swap places between servers
    // is a record you cannot read at a glance.
    for (const land of LAND_ORDER) {
      const row = sum.by_land?.find((l) => l.land === land);
      if (!row || cy + fonts.stationSm.height + Math.round(10 * s) > floor) continue;
      const accent: RGBA = land === "go" ? GO : RUST;
      fill(g, accent, x, cy, Math.round(3 * s), fonts.stationSm.height + Math.round(6 * s));
      g.fillStyle = css(Theme.cream);
      printf(
        g,
        fonts.stationSm,
        land.toUpperCase(),
        x + Math.round(10 * s),
        cy + Math.round(3 * s),
        w,
        "left",
      );
      g.fillStyle = css(accent);
      printf(
        g,
        fonts.stationSm,
        `${row.cleared} / ${row.total}`,
        x,
        cy + Math.round(3 * s),
        w,
        "right",
      );
      const lineY = cy + fonts.stationSm.height + Math.round(7 * s);
      fill(g, Theme.ink, x + Math.round(10 * s), lineY, w - Math.round(10 * s), 2, 0.7);
      if (row.total > 0) {
        fill(
          g,
          accent,
          x + Math.round(10 * s),
          lineY,
          Math.round(((w - Math.round(10 * s)) * row.cleared) / row.total),
          2,
        );
      }
      cy = lineY + Math.round(12 * s);
    }

    // The shelf, in miniature, in the room the record leaves under it.
    //
    // It is not a duplicate of the tab: it is the *reason to press the tab*. A
    // panel that stopped at "0 / 63" left two thirds of the column empty on a
    // new account, and empty is the one thing a screen about what you have done
    // must not be while there is still something to go and get.
    const stripH = Math.round(30 * s);
    if (cy + stripH + fonts.stationSm.height * 2 < floor) {
      const count = shelfCount(this.awards);
      g.fillStyle = css(Theme.dim);
      printf(g, fonts.stationSm, T("stats.shelf"), x, cy, w, "left");
      g.fillStyle = css(count.have > 0 ? Theme.coin : Theme.dim);
      printf(g, fonts.stationSm, `${count.have} OF ${count.of}`, x, cy, w, "right");
      cy += fonts.stationSm.height + Math.round(6 * s);
      const slots = shelf(this.awards);
      const across = Math.max(1, Math.floor(w / (stripH + Math.round(6 * s))));
      for (let i = 0; i < Math.min(across, slots.length); i++) {
        const slot = slots[i];
        const bx = x + i * (stripH + Math.round(6 * s));
        const art = this.app.assets?.picture(slot.award ? slot.art : "badge_slot");
        if (art) {
          g.save();
          g.drawImage(art, bx, cy, stripH, stripH);
          g.restore();
        } else {
          fill(g, Theme.ink, bx, cy, stripH, stripH, 0.7);
        }
      }
      cy += stripH + Math.round(10 * s);
    }

    if (this.partial && cy + fonts.stationSm.height < floor) {
      g.fillStyle = css(Theme.dim);
      printf(
        g,
        fonts.stationSm,
        this.partial.toUpperCase(),
        x,
        floor - fonts.stationSm.height,
        w,
        "left",
      );
    }

    this.drawNav(g, [x, y + h - navH, w, navH], fonts.stationSm, touch);
  }

  private drawNav(
    g: Ctx,
    rect: Rect,
    f: ReturnType<typeof ensureFonts>["stationSm"],
    touch: number,
  ): void {
    auxRow(this.nav, f, rect, "stats", touch);
    drawAux(g, this.nav, f);
  }

  private drawTabbed(g: Ctx, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const live = this.mistakes.filter((m) => !isLearned(m));
    const title =
      this.tab === "drill"
        ? T("stats.drillTab", { n: live.length })
        : this.tab === "shelf"
          ? (() => {
              const c = shelfCount(this.awards);
              return T("stats.shelfTab", { have: c.have, of: c.of });
            })()
          : T("stats.logTab", { n: this.history.length });
    const inner = titledPanel(g, rect, title, Theme.cyan);
    const [x, y, w, h] = inner;

    // The tabs, as a strip of three inside the panel's own head.
    const tabH = Math.max(this.app.layout.minTouchH(), fonts.stationSm.height + Math.round(12 * s));
    const tabW = Math.floor((w - Math.round(8 * s)) / 3);
    for (let i = 0; i < TABS().length; i++) {
      const t = TABS()[i];
      const tx = x + i * (tabW + Math.round(4 * s));
      const on = t.id === this.tab;
      const hot = this.tabs.hovered === `tab:${t.id}`;
      fill(g, on ? Theme.navy : Theme.ink, tx, y, tabW, tabH, on ? 0.95 : hot ? 0.7 : 0.45);
      fill(g, on ? Theme.coin : Theme.dim, tx, y + tabH - 3, tabW, 3, on ? 1 : 0.5);
      g.fillStyle = css(on ? Theme.cream : hot ? Theme.cyan : Theme.dim);
      printf(
        g,
        fonts.stationSm,
        t.label,
        tx,
        y + Math.round((tabH - fonts.stationSm.height) / 2),
        tabW,
        "center",
      );
      this.tabs.add({ id: `tab:${t.id}`, rect: [tx, y, tabW, tabH], label: t.label });
    }

    const body: Rect = [x, y + tabH + Math.round(10 * s), w, h - tabH - Math.round(10 * s)];
    if (this.tab === "drill") this.drawDrill(g, body, s);
    else if (this.tab === "shelf") this.drawShelf(g, body, s);
    else this.drawLog(g, body, s);
  }

  // -- the drill -----------------------------------------------------------

  private drawDrill(g: Ctx, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const [x, y, w, h] = rect;
    if (this.mistakes.length === 0) {
      drawNotice(g, this.app, rect, {
        head: this.notice ? this.notice.head : T("stats.noDrillHead"),
        body: this.notice ? this.notice.body : T("stats.noDrillBody"),
        tone: this.notice ? this.notice.tone : "empty",
      });
      this.overflow = 0;
      return;
    }

    const live = this.mistakes.filter((m) => !isLearned(m));
    const tamed = this.mistakes.filter((m) => isLearned(m));
    const rowH = this.mistakeRowH(fonts, s);
    const headH = fonts.stationSm.height + Math.round(8 * s);
    const total = live.length * rowH + (tamed.length > 0 ? headH + tamed.length * rowH : 0) + headH;
    this.overflow = Math.max(0, total - h);
    this.scroll.drill = Math.min(this.scroll.drill, this.overflow);

    clipped(g, x, y, w, h, () => {
      let cy = y - this.scroll.drill;
      g.fillStyle = css(Theme.dim);
      printf(
        g,
        fonts.stationSm,
        live.length > 0 ? T("stats.stillCatching") : T("stats.nothingCatching"),
        x,
        cy,
        w,
        "left",
      );
      cy += headH;
      for (const m of live) {
        this.drawMistake(g, m, [x, cy, w, rowH], s, false);
        cy += rowH;
      }
      if (tamed.length > 0) {
        cy += Math.round(4 * s);
        g.fillStyle = css(Theme.admit);
        printf(g, fonts.stationSm, T("stats.beaten", { n: tamed.length }), x, cy, w, "left");
        cy += headH;
        for (const m of tamed) {
          this.drawMistake(g, m, [x, cy, w, rowH], s, true);
          cy += rowH;
        }
      }
    });
    this.rail(g, rect, this.scroll.drill, s);
  }

  private mistakeRowH(fonts: ReturnType<typeof ensureFonts>, s: number): number {
    return (
      fonts.station.height +
      Math.round(5 * s) +
      fonts.stationSm.height +
      Math.round(6 * s) +
      fonts.small.height +
      Math.round(14 * s)
    );
  }

  /**
   * One kind, with the five pips that are the point of the whole screen.
   *
   * The pips are five because §7.2 says five, and they are drawn filled from
   * the left with the remaining ones as empty sockets — the same visual grammar
   * as `badge_slot` on the shelf, and for the same reason: an empty socket is a
   * thing you can go and fill, and a missing pip is nothing at all.
   */
  private drawMistake(g: Ctx, m: MistakeStat, rect: Rect, s: number, beaten: boolean): void {
    const fonts = ensureFonts(s);
    const [x, y, w, h] = rect;
    const id = m.example_quest_id ? `quest:${m.example_quest_id}` : `kind:${m.kind}`;
    const hot = this.rows.hovered === id;
    const pad = Math.round(10 * s);
    const accent: RGBA = beaten ? Theme.admit : m.cleared_since === 0 ? Theme.red : Theme.coin;

    fill(g, Theme.navy, x, y, w, h - Math.round(6 * s), hot ? 0.95 : 0.7);
    fill(g, accent, x, y, Math.round(4 * s), h - Math.round(6 * s), hot ? 1 : 0.7);

    g.fillStyle = css(hot ? Theme.coin : Theme.cream);
    const label = (m.label || m.kind).toUpperCase();
    printf(g, fonts.station, label, x + pad, y + pad, w - pad * 2 - Math.round(70 * s), "left");

    // The tally, right-aligned on the title line. It is the *count*, which is
    // what orders the list, and it is never drawn as a star.
    g.fillStyle = css(Theme.dim);
    printf(g, fonts.station, `${m.count}×`, x, y + pad, w - pad, "right");

    const pipY = y + pad + fonts.station.height + Math.round(5 * s);
    const pipR = Math.max(4, Math.round(7 * s));
    const pipGap = Math.round(5 * s);
    const done = Math.round(tamedFraction(m) * LEARNED_AT);
    for (let i = 0; i < LEARNED_AT; i++) {
      const px = x + pad + i * (pipR * 2 + pipGap);
      fill(g, Theme.ink, px, pipY, pipR * 2, pipR, 0.85);
      if (i < done) fill(g, accent, px + 1, pipY + 1, pipR * 2 - 2, pipR - 2);
    }
    const lineX = x + pad + LEARNED_AT * (pipR * 2 + pipGap) + Math.round(8 * s);
    g.fillStyle = css(accent);
    printf(
      g,
      fonts.stationSm,
      tamedLine(m),
      lineX,
      pipY + Math.round((pipR - fonts.stationSm.height) / 2),
      Math.max(Math.round(40 * s), x + w - pad - lineX),
      "left",
    );

    // What to drill to fix it (§5.6), and where it last happened. The concepts
    // are the server's own answer to "what should I go and read", so they are
    // printed rather than summarised.
    const tailY = pipY + pipR + Math.round(6 * s);
    const concepts = m.concepts.length > 0 ? m.concepts.join(" · ") : T("stats.noConcepts");
    const tailW = w - pad * 2;
    // The quest id is the door and it goes on the right, measured, so that a
    // long list of concepts crowds itself rather than pushing the one clickable
    // fact off the end of the row. It was being truncated to just the arrow.
    let conceptW = tailW;
    if (m.example_quest_id) {
      const door = `→ ${m.example_quest_id}`;
      const doorW = Math.min(width(fonts.small, door), Math.round(tailW * 0.55));
      g.fillStyle = css(Theme.cyan, 0.75);
      printf(g, fonts.small, door, x + pad + tailW - doorW, tailY, doorW, "right");
      conceptW = tailW - doorW - Math.round(10 * s);
    }
    g.fillStyle = css(Theme.cream, 0.55);
    const lines = wrap(fonts.small, concepts, Math.max(Math.round(40 * s), conceptW));
    let head = lines[0] ?? "";
    if (lines.length > 1) head = head.replace(/.{0,2}$/u, "…");
    printf(g, fonts.small, head, x + pad, tailY, conceptW, "left");

    this.rows.add({ id, rect: [x, y, w, h - Math.round(6 * s)], label, dim: !m.example_quest_id });
  }

  // -- the shelf -----------------------------------------------------------

  private drawShelf(g: Ctx, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const [x, y, w, h] = rect;
    const slots = shelf(this.awards);
    const cols = Math.max(1, Math.floor(w / Math.round(112 * s)));
    const cw = Math.floor(w / cols);
    // Measured, not assumed: a two-word title wraps and a socket whose hint was
    // placed one line under the *first* line printed the two on top of each
    // other. `slotText` is the same measurement `drawSlot` lays out with.
    let words = 2;
    for (const slot of slots) words = Math.max(words, slotText(fonts, slot, cw, s));
    const ch = cw + words * fonts.stationSm.height + Math.round(14 * s);
    const rows = Math.ceil(slots.length / cols);
    this.overflow = Math.max(0, rows * ch - h);
    this.scroll.shelf = Math.min(this.scroll.shelf, this.overflow);

    clipped(g, x, y, w, h, () => {
      for (let i = 0; i < slots.length; i++) {
        const cx = x + (i % cols) * cw;
        const cy = y + Math.floor(i / cols) * ch - this.scroll.shelf;
        if (cy > y + h || cy + ch < y) continue;
        this.drawSlot(g, slots[i], [cx, cy, cw, ch], s);
      }
    });
    this.rail(g, rect, this.scroll.shelf, s);

    if (this.awards.length === 0) {
      // The sockets are drawn behind this either way — the catalogue is this
      // client's, not the server's — but "you have earned none of these" and
      // "nobody asked" look identical as a grid of empty sockets, and only one
      // of them is the player's fault. So the line says which it is.
      const asked = !this.partial.includes("awards");
      g.fillStyle = css(asked ? Theme.coin : Theme.red);
      printf(
        g,
        fonts.stationSm,
        asked ? T("stats.noAwardsHead") : T("stats.noShelfHead"),
        x,
        y + h - fonts.stationSm.height,
        w,
        "center",
      );
    }
  }

  private drawSlot(g: Ctx, slot: Slot, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const [x, y, w] = rect;
    const pad = Math.round(6 * s);
    const size = w - pad * 2;
    const earned = slot.award !== null;
    // `badge_slot` is the empty socket DESIGN drew for exactly this. Falling
    // back to a drawn recess rather than to nothing keeps the shelf legible on
    // a cold art cache — an absent badge must never look like an absent row.
    const art = this.app.assets?.picture(earned ? slot.art : "badge_slot");
    if (art) {
      g.save();
      // Full strength, not half. The socket art is *already* dark — DESIGN
      // drew a recess — and dimming it on top of that sank the shelf into the
      // panel until it read as a grid of nothing. It is recessed, not absent,
      // and the difference between those two is the whole idea.
      g.drawImage(art, x + pad, y + pad, size, size);
      g.restore();
    } else {
      fill(g, Theme.ink, x + pad, y + pad, size, size, 0.7);
      fill(g, earned ? Theme.coin : Theme.dim, x + pad, y + pad, size, 2, earned ? 1 : 0.5);
    }
    const ty = y + pad + size + Math.round(4 * s);
    const titleLines = wrap(fonts.stationSm, slot.title, size);
    g.fillStyle = css(earned ? Theme.coin : Theme.dim);
    printf(g, fonts.stationSm, slot.title, x + pad, ty, size, "center");
    if (!earned && slot.hint) {
      g.fillStyle = css(Theme.cream, 0.4);
      printf(
        g,
        fonts.stationSm,
        slot.hint.toUpperCase(),
        x + pad,
        ty + titleLines.length * fonts.stationSm.height + Math.round(2 * s),
        size,
        "center",
      );
    }
  }

  // -- the log -------------------------------------------------------------

  private drawLog(g: Ctx, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const [x, y, w, h] = rect;
    if (this.history.length === 0) {
      drawNotice(g, this.app, rect, {
        head: this.notice?.head ?? T("stats.noLogHead"),
        body: this.notice?.body ?? T("stats.noLogBody"),
        tone: this.notice?.tone ?? "empty",
      });
      this.overflow = 0;
      return;
    }
    const rowH = fonts.stationSm.height * 2 + Math.round(16 * s);
    this.overflow = Math.max(0, this.history.length * rowH - h);
    this.scroll.log = Math.min(this.scroll.log, this.overflow);

    clipped(g, x, y, w, h, () => {
      let cy = y - this.scroll.log;
      for (const a of this.history) {
        if (cy > y + h || cy + rowH < y) {
          cy += rowH;
          continue;
        }
        const id = `quest:${a.quest_id}`;
        const hot = this.rows.hovered === id;
        const col = verdictCol(a.verdict);
        fill(g, Theme.navy, x, cy, w, rowH - Math.round(4 * s), hot ? 0.9 : 0.6);
        fill(g, col, x, cy, Math.round(3 * s), rowH - Math.round(4 * s), hot ? 1 : 0.7);
        g.fillStyle = css(hot ? Theme.coin : Theme.cream);
        printf(
          g,
          fonts.stationSm,
          a.quest_id,
          x + Math.round(10 * s),
          cy + Math.round(6 * s),
          w - Math.round(20 * s),
          "left",
        );
        g.fillStyle = css(col);
        // `mode` is on the wire but not in §5.7 — see docs/decisions.md. It is
        // printed because a RUN never clears a node (§4.9b), so a log that did
        // not distinguish them reads as a string of failures on a quest the
        // player went on to clear.
        const kind = a.mode === "run" ? T("stats.run") : T("stats.submit");
        printf(
          g,
          fonts.stationSm,
          `${kind}  ${a.verdict.replace(/_/g, " ").toUpperCase()}`,
          x,
          cy + Math.round(6 * s),
          w - Math.round(10 * s),
          "right",
        );
        g.fillStyle = css(Theme.dim);
        const kinds = a.kinds.length > 0 ? a.kinds.join(" · ") : T("stats.noMistakes");
        printf(
          g,
          fonts.stationSm,
          `${a.tests_passed}/${a.tests_total}   ${kinds}`,
          x + Math.round(10 * s),
          cy + Math.round(6 * s) + fonts.stationSm.height + Math.round(3 * s),
          w - Math.round(20 * s),
          "left",
        );
        this.rows.add({ id, rect: [x, cy, w, rowH - Math.round(4 * s)], label: a.quest_id });
        cy += rowH;
      }
    });
    this.rail(g, rect, this.scroll.log, s);
  }

  private rail(g: Ctx, rect: Rect, scroll: number, s: number): void {
    if (this.overflow <= 0) return;
    const [x, y, w, h] = rect;
    const railH = Math.max(20 * s, (h * h) / (h + this.overflow));
    const railY = y + ((h - railH) * scroll) / this.overflow;
    fill(g, Theme.ink, x + w - 3, y, 3, h, 0.5);
    fill(g, Theme.coin, x + w - 3, railY, 3, railH, 0.8);
  }

  resized(): void {
    this.scroll = { drill: 0, shelf: 0, log: 0 };
  }
}

/**
 * How many lines of small type a socket needs under its badge.
 *
 * Shared by the grid that reserves the height and the routine that draws into
 * it, so the two cannot disagree — which they did, and a wrapped two-line title
 * had its hint printed straight through it.
 */
function slotText(
  fonts: ReturnType<typeof ensureFonts>,
  slot: Slot,
  cellW: number,
  s: number,
): number {
  const inner = cellW - Math.round(12 * s);
  const title = wrap(fonts.stationSm, slot.title, inner).length;
  const hint =
    slot.award === null && slot.hint
      ? wrap(fonts.stationSm, slot.hint.toUpperCase(), inner).length
      : 0;
  return title + hint;
}
