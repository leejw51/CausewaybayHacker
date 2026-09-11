/**
 * AI MODE — the coach, and the one line that makes it one.
 *
 * SPEC §7.3 builds three plans entirely from the tables the rest of the game
 * already fills in, and says so in as many words: "No external model is
 * required for any of them." `repeat` is what you failed most, `weakness`
 * groups your compiler errors by kind and hands you five different shapes of
 * the one you make most, `spaced` brings cleared quests back on an SM-2-ish
 * interval. The plan is a fixed ordered list written at creation (§4.16) so a
 * reconnect resumes the same session rather than reshuffling it.
 *
 * **`ai.next` returns a `why`** — "you hit borrow-after-move 6 times" — and
 * PROTOCOL §4.16 says what it is for: "it is generated from the mistake tables,
 * not from a language model, and it is the thing that makes the mode feel like
 * a coach rather than a shuffle." So it is not a caption. It gets the top of
 * the panel, at the size a headline is set in, above the quest it explains —
 * because the sentence is the product and the quest is the exercise.
 *
 * All three `ai.*` calls are milestone 2 and today answer `unavailable`, so
 * this screen probes and renders whatever comes back. What it must never do is
 * render zero rows in silence: a new player has no mistakes, so every plan can
 * legitimately be empty, and `ui/coach.ts` gives each of the three its own
 * answer for why and what would fill it.
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf, width, wrap } from "../engine/text";
import { css, Theme, type RGBA } from "../engine/theme";
import { clipped, fill, pixBtn, type Ctx, type Rect } from "../engine/ui";
import { arriving, Buttons, footer, frame, GO, header, RUST, titledPanel } from "../ui/chrome";
import { seconds, Tween } from "../engine/motion";
import { WireError } from "../net/client";
import { playerText } from "../net/protocol";
import type { Category, Drill, DrillMode, Land, MistakeStat, Quest } from "../net/protocol";
import { unbuilt, unbuiltLine } from "../net/milestone";
import { auxHeight, auxRow, drawAux, AUX_HINT, openAux } from "../ui/auxnav";
import { drawNotice, type Notice } from "../ui/notice";
import { emptyDrill, isLearned, type CoachContext } from "../ui/coach";
import { QuestScene } from "./quest";
import { LandsScene } from "./lands";

const MODES: readonly DrillMode[] = ["weakness", "repeat", "spaced"];

const MODE_TITLE: Record<DrillMode, string> = {
  weakness: "WEAKNESS",
  repeat: "REPEAT",
  spaced: "SPACED",
};

/** What each plan is, from §7.3, in the coach's own voice. */
const MODE_LINE: Record<DrillMode, string> = {
  weakness:
    "The mistake you make most, in five different shapes — cleared streets included. " +
    "The one that teaches.",
  repeat: "The streets that beat you, worst first. Do it again until it sticks.",
  spaced: "Cleared streets, due for review. Three stars in a fortnight, one star in two days.",
};

/** §4.16's `size`. Five is the example and a sensible sitting. */
const SIZE = 5;

/**
 * The drill in progress, kept outside the scene on purpose.
 *
 * A drill is a *session*: you leave this screen to solve a quest, come back,
 * and take the next one. Holding it on the instance would end the plan every
 * time the player walked into a street, and re-planning on return would hand
 * out a different list — the opposite of §4.16's "fixed ordered list fixed at
 * creation, so a reconnect resumes the same session".
 *
 * It is a module-level `let` rather than state on `App` because `App` holds no
 * game state by design (see its header), and a drill id is exactly the kind of
 * thing that must not outlive a logout. `forget()` is called from `leave()`
 * only when the drill is over, and the id is useless to anyone else: the server
 * scopes it to the address that made it.
 */
let session: {
  /**
   * Whose drill it is. A module-level session outlives a logout, and the next
   * wallet to log in must not inherit a drill id scoped to the last one — it
   * would answer `not_found` and read as a broken coach rather than as somebody
   * else's session. Compared on entry; nothing else is kept.
   */
  who: string;
  drill: Drill;
  quest: Quest | null;
  why: string;
  position: number;
  total: number;
  done: boolean;
  summary: { attempted: number; cleared: number; kinds_improved: string[] } | null;
} | null = null;

export class AiScene implements Scene {
  readonly name = "ai";
  readonly mood = "quest" as const;
  land: Land = "rust";

  private mode: DrillMode = "weakness";
  private landFilter: Land | null = null;
  private busy = false;
  private notice: Notice | null = null;
  /** Read once on entry, so an empty plan can say *which* kind of empty. */
  private context: CoachContext = { live: 0, learned: 0, cleared: 0, attempts: 0 };
  private mistakes: MistakeStat[] = [];

  private scroll = 0;
  private overflow = 0;
  private readonly picks = new Buttons();
  private readonly acts = new Buttons();
  private readonly nav = new Buttons();
  private readonly leftIn = new Tween(seconds("panel"));
  private readonly rightIn = new Tween(seconds("panel"), seconds("stagger"));
  /** The `why` arriving. It is the headline, so it is given a beat of its own. */
  private readonly whyIn = new Tween(seconds("verdict"), seconds("stagger") * 2);

  constructor(private readonly app: App) {}

  async enter(): Promise<void> {
    // The context comes from `stats.*`, which is built and answers today. It is
    // what lets an empty plan say "you have not failed one that is still
    // standing" rather than "no drills" — see `ui/coach.ts`.
    const [summary, mistakes] = await Promise.allSettled([
      this.app.client.request("stats.summary", {}),
      this.app.client.request("stats.mistakes", { limit: 50, include_learned: true }),
    ]);
    if (summary.status === "fulfilled") {
      this.context.cleared = summary.value.cleared;
      this.context.attempts = summary.value.attempts;
    }
    if (mistakes.status === "fulfilled") {
      this.mistakes = mistakes.value.mistakes ?? [];
      this.context.live = this.mistakes.filter((m) => !isLearned(m)).length;
      this.context.learned = this.mistakes.filter((m) => isLearned(m)).length;
    }
    if (session && session.who !== this.app.addressLabel) session = null;
    if (session) {
      this.mode = session.drill.mode;
      this.whyIn.finish();
    }
  }

  update(dt: number): void {
    this.leftIn.update(dt);
    this.rightIn.update(dt);
    this.whyIn.update(dt);
  }

  controls(): Buttons[] {
    return [this.picks, this.acts, this.nav];
  }

  // -- the plan ------------------------------------------------------------

  private async plan(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.notice = null;
    this.app.chip.select();
    try {
      const res = await this.app.client.request("ai.plan", {
        mode: this.mode,
        size: SIZE,
        ...(this.landFilter ? { land: this.landFilter } : {}),
      });
      session = {
        who: this.app.addressLabel,
        drill: res.drill,
        quest: null,
        why: "",
        position: res.drill.cursor,
        total: res.drill.plan.length,
        done: false,
        summary: null,
      };
      this.whyIn.restart();
      this.scroll = 0;
      // A plan with nothing in it is a real, correct answer for a player who
      // has not made the mistake the mode reads from. It is answered here
      // rather than drawn as an empty list.
      if (res.drill.plan.length === 0) {
        const empty = emptyDrill(this.mode, this.context);
        this.notice = { head: empty.head, body: empty.body, tone: "empty" };
      } else {
        await this.next();
      }
    } catch (e) {
      session = null;
      this.notice = this.explain(e, "THE COACH");
      this.app.chip.fail();
    } finally {
      this.busy = false;
    }
  }

  private async next(): Promise<void> {
    if (!session || this.busy) return;
    this.busy = true;
    try {
      const res = await this.app.client.request("ai.next", { drill_id: session.drill.id });
      session.quest = res.quest;
      session.why = res.why ?? "";
      session.position = res.position;
      session.total = res.total;
      this.whyIn.restart();
      this.app.chip.coin();
    } catch (e) {
      // §4.16: "`ai.next` past the end returns `not_found`; call `ai.finish`."
      // That is the plan being *finished*, not a failure, and it must not be
      // drawn in the colour that means something broke.
      if (e instanceof WireError && e.payload.code === "not_found" && session) {
        await this.finish();
      } else {
        this.notice = this.explain(e, "THE NEXT STREET");
        this.app.chip.fail();
      }
    } finally {
      this.busy = false;
    }
  }

  private async finish(): Promise<void> {
    if (!session) return;
    try {
      const res = await this.app.client.request("ai.finish", { drill_id: session.drill.id });
      session.summary = res.summary;
      session.done = true;
      session.quest = null;
      this.app.chip.clear();
    } catch (e) {
      this.notice = this.explain(e, "THE SUMMARY");
      session.done = true;
      session.quest = null;
    }
  }

  private explain(e: unknown, what: string): Notice {
    const gap = unbuilt(e);
    if (gap) {
      console.info("ai.* is not built yet:", gap.developerMessage);
      return {
        head: unbuiltLine(what, gap).toUpperCase(),
        body:
          "SPEC §7.3 has all three plans and none of them needs a language model — they are " +
          "queries over the mistakes you have already made. The tables are being filled in " +
          "every time you press SUBMIT; the coach that reads them is not in this build yet.",
        tone: "unbuilt",
      };
    }
    if (e instanceof WireError) {
      console.warn("ai call failed:", e.payload.code, e.payload.message, e.payload.detail);
      return { head: "THAT DID NOT WORK", body: playerText(e.payload.code), tone: "fault" };
    }
    return { head: "THAT DID NOT WORK", body: "the coach did not answer", tone: "fault" };
  }

  // -- input ---------------------------------------------------------------

  key(name: string): void {
    if (name === "escape") return void openAux(this.app, "aux:maps");
    if (name === "return" || name === "kpenter") {
      if (session?.quest) this.go();
      else void this.plan();
      return;
    }
    if (name === "q" || name === "left") this.pick(-1);
    if (name === "e" || name === "right") this.pick(1);
  }

  private pick(step: number): void {
    const i = MODES.indexOf(this.mode);
    this.mode = MODES[(i + step + MODES.length) % MODES.length];
    this.app.chip.blip();
  }

  wheel(dy: number): void {
    this.scroll = Math.max(0, Math.min(this.overflow, this.scroll + dy));
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    if (phase === "move") {
      this.picks.hovered = this.picks.hit(x, y)?.id ?? null;
      this.acts.hovered = this.acts.hit(x, y)?.id ?? null;
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
    const pick = this.picks.hit(x, y);
    if (pick) {
      this.app.chip.blip();
      if (pick.id.startsWith("mode:")) this.mode = pick.id.slice(5) as DrillMode;
      else if (pick.id.startsWith("land:")) {
        const v = pick.id.slice(5);
        this.landFilter = v === "any" ? null : (v as Land);
      }
      return;
    }
    const act = this.acts.hit(x, y);
    if (!act) return;
    switch (act.id) {
      case "start":
        void this.plan();
        break;
      case "go":
        this.go();
        break;
      case "skip":
        void this.next();
        break;
      case "finish":
        void this.finish();
        break;
      case "again":
        session = null;
        this.notice = null;
        break;
      case "maps":
        this.app.chip.select();
        void this.app.go(new LandsScene(this.app), "back");
        break;
    }
  }

  /**
   * Into the street.
   *
   * The drill is left standing rather than torn down: the plan lives on the
   * server (§4.16) and the cursor with it, so coming back to AI MODE — F6 from
   * anywhere, including from inside the quest — resumes at the same place.
   * The alternative would be a coach that forgets what it told you the moment
   * you act on it.
   */
  private go(): void {
    const q = session?.quest;
    if (!q) return;
    this.app.chip.select();
    void this.app.go(
      new QuestScene(this.app, q.land as Land, q.category as Category, q.id),
      "forward",
    );
  }

  // -- drawing -------------------------------------------------------------

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    header(g, this.app, "AI MODE");
    const f = frame(layout, layout.isPortrait() ? 0.44 : 0.36, 0.03);
    this.picks.reset();
    this.acts.reset();

    arriving(g, f, "left", this.leftIn, () => this.drawChooser(g, f.left, f.scale));
    arriving(g, f, "right", this.rightIn, () => this.drawSession(g, f.right, f.scale));

    footer(g, layout, `Q/E  PLAN   ENTER  GO   ${AUX_HINT}`);
  }

  private drawChooser(g: Ctx, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const inner = titledPanel(g, rect, "WHAT SHOULD I DRILL", Theme.coin);
    const [x, y, w, h] = inner;
    const touch = this.app.layout.minTouchH();
    const navH = auxHeight(fonts.stationSm, w, touch);
    const btnH = Math.max(touch, fonts.button.height + 20);
    const floor = y + h - navH - btnH - Math.round(18 * s);

    const gap = Math.round(8 * s);
    const plateH = Math.max(
      Math.round(60 * s),
      Math.floor((floor - y - gap * (MODES.length - 1) - Math.round(34 * s)) / MODES.length),
    );
    let cy = y;
    for (const m of MODES) {
      this.drawModePlate(g, m, [x, cy, w, plateH], s);
      cy += plateH + gap;
    }

    // The one filter §4.16 offers. ANY is the default and is drawn as a choice
    // rather than as the absence of one.
    const chipH = Math.max(touch, fonts.stationSm.height + Math.round(10 * s));
    const chipY = Math.min(cy, floor - chipH);
    let cx = x;
    g.fillStyle = css(Theme.dim);
    const labelW = width(fonts.stationSm, "LAND") + Math.round(8 * s);
    printf(
      g,
      fonts.stationSm,
      "LAND",
      x,
      chipY + Math.round((chipH - fonts.stationSm.height) / 2),
      labelW,
      "left",
    );
    cx += labelW;
    for (const [id, label, value] of [
      ["land:any", "ANY", null],
      ["land:rust", "RUST", "rust"],
      ["land:go", "GO", "go"],
    ] as Array<[string, string, Land | null]>) {
      const cw = width(fonts.stationSm, label) + Math.round(14 * s);
      const on = value === this.landFilter;
      const hot = this.picks.hovered === id;
      fill(g, on ? Theme.coin : Theme.ink, cx, chipY, cw, chipH, on ? 1 : hot ? 0.8 : 0.5);
      g.fillStyle = css(on ? Theme.ink : hot ? Theme.cream : Theme.cyan);
      printf(
        g,
        fonts.stationSm,
        label,
        cx,
        chipY + Math.round((chipH - fonts.stationSm.height) / 2),
        cw,
        "center",
      );
      this.picks.add({ id, rect: [cx, chipY, cw, chipH], label });
      cx += cw + Math.round(5 * s);
    }

    const label = this.busy ? "…" : session && !session.done ? "NEW PLAN" : `DRILL ${SIZE}`;
    const by = y + h - navH - btnH - Math.round(8 * s);
    pixBtn(g, fonts.button, x, by, w, btnH, label, {
      strong: !this.busy,
      hover: this.acts.hovered === "start",
      dim: this.busy,
    });
    this.acts.add({ id: "start", rect: [x, by, w, btnH], label, dim: this.busy });

    auxRow(this.nav, fonts.stationSm, [x, y + h - navH, w, navH], "ai", touch);
    drawAux(g, this.nav, fonts.stationSm);
  }

  private drawModePlate(g: Ctx, m: DrillMode, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const [x, y, w, h] = rect;
    const on = m === this.mode;
    const hot = this.picks.hovered === `mode:${m}`;
    const accent: RGBA = on ? Theme.coin : Theme.dim;
    fill(g, Theme.navy, x, y, w, h, on ? 0.95 : hot ? 0.8 : 0.55);
    fill(g, accent, x, y, Math.round(4 * s), h, on ? 1 : 0.6);
    fill(g, accent, x, y + h - 2, w, 2, on ? 1 : 0.35);
    const pad = Math.round(10 * s);
    g.fillStyle = css(on ? Theme.coin : hot ? Theme.cream : Theme.dim);
    printf(g, fonts.station, MODE_TITLE[m], x + pad, y + pad, w - pad * 2, "left");
    const lineY = y + pad + fonts.station.height + Math.round(4 * s);
    const fits = Math.floor((y + h - Math.round(8 * s) - lineY) / fonts.small.height);
    if (fits >= 1) {
      const all = wrap(fonts.small, MODE_LINE[m], w - pad * 2);
      const use = all.slice(0, fits);
      if (all.length > use.length && use.length > 0) {
        use[use.length - 1] = use[use.length - 1].replace(/.{0,2}$/u, "…");
      }
      g.fillStyle = css(Theme.cream, on ? 0.85 : 0.45);
      let ly = lineY;
      for (const line of use) {
        printf(g, fonts.small, line, x + pad, ly, w - pad * 2, "left");
        ly += fonts.small.height;
      }
    }
    this.picks.add({ id: `mode:${m}`, rect, label: MODE_TITLE[m] });
  }

  private drawSession(g: Ctx, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    // A finished plan does not have a current position: leaving the head on
    // "2 OF 5" over a PLAN COMPLETE panel is the screen contradicting itself.
    const title = !session
      ? "THE COACH"
      : session.done
        ? `${MODE_TITLE[session.drill.mode]} — DONE`
        : `${MODE_TITLE[session.drill.mode]} — ${Math.min(session.position + 1, session.total)} OF ${session.total}`;
    const inner = titledPanel(g, rect, title, Theme.cyan);
    const [x, y, w, h] = inner;
    const touch = this.app.layout.minTouchH();
    const btnH = Math.max(touch, fonts.button.height + 20);

    if (this.notice) {
      drawNotice(g, this.app, [x, y, w, h - btnH - Math.round(10 * s)], this.notice);
      this.drawActions(g, [x, y + h - btnH, w, btnH], s, [
        { id: "again", label: "TRY ANOTHER PLAN" },
        { id: "maps", label: "TO THE MAPS" },
      ]);
      this.overflow = 0;
      return;
    }

    if (!session) {
      drawNotice(g, this.app, [x, y, w, h], {
        head: "PICK A PLAN",
        body:
          "Three of them, all built from your own record rather than from a model: what you " +
          "failed, what you keep getting wrong, and what you cleared long enough ago to have " +
          "forgotten. Choose one and the coach will say why each street is next.",
        tone: "empty",
      });
      this.overflow = 0;
      return;
    }

    if (session.done) {
      this.drawSummary(g, [x, y, w, h - btnH - Math.round(10 * s)], s);
      this.drawActions(g, [x, y + h - btnH, w, btnH], s, [
        { id: "again", label: "ANOTHER PLAN" },
        { id: "maps", label: "TO THE MAPS" },
      ]);
      this.overflow = 0;
      return;
    }

    // --- the why ----------------------------------------------------------
    // Top of the panel, in the station face, on its own band. §4.16 calls this
    // the thing that makes the mode a coach rather than a shuffle, and a line
    // of grey small print under a quest title is not that.
    const why = session.why || session.drill.reason || "";
    let cy = y;
    if (why) {
      const pad = Math.round(12 * s);
      const inner2 = w - pad * 2 - Math.round(5 * s);
      const lines = wrap(fonts.station, why.toUpperCase(), inner2);
      const bandH = pad * 2 + lines.length * fonts.station.height;
      // It arrives: the band grows down from the head of the panel on the
      // house curve, so a new `why` is something that was *said* rather than
      // something that was always there.
      const t = this.whyIn.out;
      clipped(g, x, y, w, Math.max(1, Math.round(bandH * t)), () => {
        fill(g, Theme.ink, x, y, w, bandH, 0.7);
        fill(g, Theme.coin, x, y, Math.round(5 * s), bandH);
        g.fillStyle = css(Theme.dim);
        printf(g, fonts.stationSm, "WHY THIS ONE", x + pad, y + Math.round(4 * s), inner2, "left");
        g.fillStyle = css(Theme.coin);
        let ly = y + pad + Math.round(6 * s);
        for (const line of lines) {
          printf(g, fonts.station, line, x + pad, ly, inner2, "left");
          ly += fonts.station.height;
        }
      });
      // The band's *space* is reserved in full from the first frame and only
      // its ink wipes in. Advancing `cy` with the tween instead made the quest
      // title start at the top of the panel and get overpainted by the band
      // sliding down through it — half a second of two things in one place.
      cy = y + bandH + Math.round(12 * s);
    }

    // --- the quest --------------------------------------------------------
    const q = session.quest;
    if (q) {
      const accent: RGBA = q.land === "go" ? GO : RUST;
      g.fillStyle = css(accent);
      // Built from the parts that exist rather than from a template with holes
      // in it. `weakness` and `repeat` hand over uncleared quests, where `stars`
      // is 0 — and `★`.repeat(0) left the line reading "RUST · BASIC · " with a
      // separator pointing at nothing.
      const meta = [q.land.toUpperCase(), q.category.toUpperCase()];
      if (q.stars > 0) meta.push("★".repeat(q.stars));
      if (q.state === "cleared") meta.push("CLEARED");
      printf(g, fonts.stationSm, meta.join(" · "), x, cy, w, "left");
      cy += fonts.stationSm.height + Math.round(6 * s);
      g.fillStyle = css(Theme.cream);
      const titleLines = wrap(fonts.station, q.title.toUpperCase(), w);
      for (const line of titleLines) {
        printf(g, fonts.station, line, x, cy, w, "left");
        cy += fonts.station.height;
      }
      cy += Math.round(8 * s);
      // The concepts, because they are what the `why` is actually pointing at:
      // §7.3's `weakness` plan picks a quest because its concepts overlap the
      // kind you keep making, and showing them closes that loop on screen.
      if (q.concepts.length > 0) {
        g.fillStyle = css(Theme.cyan, 0.8);
        printf(g, fonts.stationSm, q.concepts.join(" · ").toUpperCase(), x, cy, w, "left");
        cy += fonts.stationSm.height + Math.round(8 * s);
      }
      const briefBottom = y + h - btnH - Math.round(10 * s) - Math.round(26 * s);
      if (cy < briefBottom) {
        g.fillStyle = css(Theme.cream, 0.7);
        const lines = wrap(fonts.small, q.brief, w - Math.round(4 * s));
        const fits = Math.floor((briefBottom - cy) / fonts.small.height);
        for (let i = 0; i < Math.min(fits, lines.length); i++) {
          printf(g, fonts.small, lines[i], x, cy + i * fonts.small.height, w, "left");
        }
      }
    }

    // --- the plan, as a row of pips ---------------------------------------
    const pipY = y + h - btnH - Math.round(26 * s);
    this.drawPlanStrip(g, [x, pipY, w, Math.round(18 * s)], s);

    this.drawActions(g, [x, y + h - btnH, w, btnH], s, [
      { id: "go", label: "GO IN", primary: true },
      { id: "skip", label: "SKIP" },
      { id: "finish", label: "FINISH" },
    ]);
    this.overflow = 0;
  }

  /**
   * The whole plan, as one strip of pips.
   *
   * §4.16's plan is fixed at creation, which means the player can be shown the
   * shape of the session they are in rather than one street at a time — "three
   * to go" is the difference between a drill and an endless queue.
   */
  private drawPlanStrip(g: Ctx, rect: Rect, s: number): void {
    if (!session) return;
    const [x, y, w, h] = rect;
    const n = Math.max(1, session.total);
    const gap = Math.round(4 * s);
    const pw = Math.max(6, Math.floor((w - gap * (n - 1)) / n));
    for (let i = 0; i < n; i++) {
      const px = x + i * (pw + gap);
      const state = i < session.position ? "done" : i === session.position ? "here" : "todo";
      fill(g, Theme.ink, px, y, pw, h, 0.8);
      if (state === "done") fill(g, Theme.admit, px + 1, y + 1, pw - 2, h - 2);
      else if (state === "here") fill(g, Theme.coin, px + 1, y + 1, pw - 2, h - 2);
      else fill(g, Theme.dim, px + 1, y + 1, pw - 2, h - 2, 0.35);
    }
  }

  private drawSummary(g: Ctx, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const [x, y, w, h] = rect;
    const sum = session?.summary;
    if (!sum) {
      drawNotice(g, this.app, rect, {
        head: "THAT IS THE PLAN DONE",
        body: "The server did not send a summary for it, which is no reflection on the work.",
        tone: "empty",
      });
      return;
    }
    let cy = y + Math.round(10 * s);
    g.fillStyle = css(Theme.coin);
    printf(g, fonts.station, "PLAN COMPLETE", x, cy, w, "left");
    cy += fonts.station.height + Math.round(12 * s);
    g.fillStyle = css(Theme.cream);
    printf(g, fonts.station, `${sum.cleared} CLEARED OF ${sum.attempted}`, x, cy, w, "left");
    cy += fonts.station.height + Math.round(14 * s);
    if (sum.kinds_improved.length > 0) {
      // The whole point of the mode, said back to the player in their own
      // taxonomy. `kinds_improved` is the only place the game ever tells
      // somebody they got *better at a kind of mistake* rather than at a quest.
      g.fillStyle = css(Theme.dim);
      printf(g, fonts.stationSm, "BETTER AT", x, cy, w, "left");
      cy += fonts.stationSm.height + Math.round(12 * s);
      clipped(g, x, cy, w, Math.max(0, y + h - cy), () => {
        for (const kind of sum.kinds_improved) {
          fill(g, Theme.admit, x, cy, Math.round(3 * s), fonts.station.height, 0.8);
          g.fillStyle = css(Theme.cream);
          printf(g, fonts.station, kind.toUpperCase(), x + Math.round(10 * s), cy, w, "left");
          cy += fonts.station.height + Math.round(6 * s);
        }
      });
    } else {
      g.fillStyle = css(Theme.cream, 0.6);
      printf(
        g,
        fonts.small,
        "No kind moved off the drill this time. A kind needs five clean submits in a row to " +
          "leave, so the run that finally does it is usually not the one you notice.",
        x,
        cy,
        w,
        "left",
      );
    }
  }

  private drawActions(
    g: Ctx,
    rect: Rect,
    s: number,
    items: ReadonlyArray<{ id: string; label: string; primary?: boolean }>,
  ): void {
    const fonts = ensureFonts(s);
    const [x, y, w, h] = rect;
    const gap = Math.round(6 * s);
    const bw = Math.floor((w - gap * (items.length - 1)) / items.length);
    for (let i = 0; i < items.length; i++) {
      const bx = x + i * (bw + gap);
      const item = items[i];
      pixBtn(g, fonts.button, bx, y, bw, h, item.label, {
        lit: item.primary,
        hover: this.acts.hovered === item.id,
        quiet: !item.primary,
      });
      this.acts.add({ id: item.id, rect: [bx, y, bw, h], label: item.label });
    }
  }

  resized(): void {
    this.scroll = 0;
  }
}
