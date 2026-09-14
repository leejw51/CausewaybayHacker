/**
 * The playground: a scratchpad with a compiler behind it.
 *
 * No quest, no tests, no verdict (PROTOCOL §4.9c). You write Rust or Go, you
 * press RUN, and it prints what it prints. The one rule that separates this
 * screen from every other screen in the game is that **a playground run is not
 * part of your record** — it is not an attempt, it does not feed the drills and
 * it cannot cost a star. That is the opposite of the quest RUN rule and it is
 * deliberate: this is where somebody writes something broken on purpose to see
 * what the compiler says about it, and counting that against them would make
 * the scratchpad the most expensive screen in the game.
 *
 * The other rule is that **the text is the whole point**. There is no starter
 * to fall back on and nothing on the server to re-derive it from, so it is
 * saved three times over: on a debounce while typing, when the window loses
 * focus, and when the screen is left — and it is mirrored into `localStorage`
 * on every keystroke, so a reload or a dropped socket cannot cost work either.
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf, wrap } from "../engine/text";
import { css, Theme } from "../engine/theme";
import {
  btnBox,
  clipped,
  fill,
  inRect,
  panel,
  pixBtn,
  rowsIn,
  well,
  type Ctx,
  type Rect,
} from "../engine/ui";
import { Buttons, footer, frame, header, landColour, titledPanel, landName } from "../ui/chrome";
import { seconds, Tween } from "../engine/motion";
import { Editor, MAIN_FILE } from "../ui/editor";
import { Overlay } from "../ui/overlay";
import { LogBuffer } from "../net/logbuf";
import { WireError } from "../net/client";
import { isLand, LANDS, playerText } from "../net/protocol";
import { onLocale, t } from "../i18n";
import type { Land, PlaygroundRun, RunStage, SnippetBrief } from "../net/protocol";
import { LandsScene } from "./lands";

/** Where the open scratchpad is mirrored, so a reload opens it again. */
const LOCAL_KEY = "cwbhacker.playground";
/** How long after the last keystroke the autosave fires. */
const AUTOSAVE_AFTER = 2.5;

const STARTER: Record<Land, string> = {
  rust: 'fn main() {\n    println!("hello, causewaybay");\n}\n',
  go: 'package main\n\nimport "fmt"\n\nfunc main() {\n\tfmt.Println("hello, causewaybay")\n}\n',
  cpp: '#include <iostream>\n\nint main() {\n    std::cout << "hello, causewaybay\\n";\n}\n',
  python: 'print("hello, causewaybay")\n',
};

const OUTCOME: Record<PlaygroundRun["outcome"], () => string> = {
  ok: () => t("pg.ran"),
  compile_error: () => t("pg.didNotCompile"),
  runtime_error: () => t("pg.stopped"),
  timeout: () => t("pg.timedOut"),
  output_limit: () => t("pg.tooMuch"),
};

/**
 * The open scratchpad. `dirty` is mirrored with it: text that never reached the
 * server must be able to say so after a reload, or the next visit would fetch
 * the older server copy over the top of it and the loss would be silent.
 */
type Held = { id: string | null; name: string; lang: Land; source: string; dirty?: boolean };

export class PlaygroundScene implements Scene {
  readonly name = "playground";
  readonly mood = "lands" as const;
  /** Read by `App` to tint the city: the language you are writing in. */
  land: Land = "rust";

  private editor: Editor | null = null;
  private overlay: Overlay | null = null;
  private readonly stdinEl: HTMLTextAreaElement;
  private stdinOverlay: Overlay | null = null;
  /**
   * RENAME: the pad's own name, edited in place.
   *
   * A one-line field rather than a dialogue, because the name is already
   * drawn at the top of this panel and the honest way to change a thing you
   * can see is to type over it. Null when nobody is renaming.
   */
  private readonly nameEl: HTMLInputElement;
  private nameOverlay: Overlay | null = null;
  private renaming = false;

  private snippets: SnippetBrief[] = [];
  private held: Held = { id: null, name: "SCRATCH", lang: "rust", source: STARTER.rust };
  /** The unsaved pad's name, translated. The stored `name` stays as it is. */
  private heldName(): string {
    // A pad renamed before it was ever saved keeps the name it was given:
    // `SCRATCH` is the placeholder, not a name somebody chose.
    if (this.held.id === null && this.held.name === "SCRATCH") return t("pg.scratch");
    return this.held.name;
  }
  /** What the server last confirmed, so an identical save is not sent at all. */
  private savedSource = "";
  private savedLang: Land = "rust";
  private dirtyFor = 0;
  private dirty = false;
  private saving = false;
  private formatting = false;

  /**
   * CODE: the editor and nothing else.
   *
   * The bench is a list, an editor, a stdin box, a band of buttons and an
   * output panel, and on a phone held upright that is five things sharing
   * 700 pixels — the editor ends up a few lines tall and the screen is, in
   * the words of the report, very hard to use. This is the quest screen's
   * answer to the same problem, on the screen that needs it more: the one
   * place in the game where a person sits down to *write*.
   */
  private focus = false;

  private stage: RunStage | "idle" = "idle";
  private attemptId: string | null = null;
  private log = new LogBuffer("");
  private result: PlaygroundRun | null = null;
  /** What the *run* said. The output panel is its and nothing else's. */
  private status = "";
  /**
   * Lines back from the tail, not an absolute index — so the window keeps
   * showing the same *moment* as more output arrives, the way `quest.ts`'s
   * console scrollback does. 0 is "live", at the bottom.
   */
  private outputScroll = 0;
  private outputOverflow = 0;
  private outputRect: Rect = [0, 0, 0, 0];
  /**
   * What *saving* said, kept apart from `status` on purpose: an autosave that
   * fires two seconds after a keystroke must never overwrite the reason a run
   * did not work, which is exactly what it did the first time these shared a
   * line.
   */
  private saveNote = "";
  private t = 0;
  private readonly benchIn = new Tween(seconds("panel"));
  private readonly listIn = new Tween(seconds("panel"), seconds("stagger"));
  private readonly buttons = new Buttons();
  private readonly rows = new Buttons();
  private offs: Array<() => void> = [];
  private offLocale?: () => void;
  private readonly onBlur = () => void this.save();

  constructor(private readonly app: App) {
    const el = document.createElement("textarea");
    el.className = "cwb-field";
    el.spellcheck = false;
    el.placeholder = t("pg.stdinHint");
    this.offLocale = onLocale(() => {
      el.placeholder = t("pg.stdinHint");
    });
    this.stdinEl = el;

    const name = document.createElement("input");
    name.type = "text";
    name.className = "cwb-field";
    name.spellcheck = false;
    name.maxLength = 48;
    // Enter commits, Escape puts it back — the two keys anybody renaming a
    // file already has in their hands. Handled here rather than through the
    // canvas key path because this element has the focus while it is open.
    name.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") {
        ev.preventDefault();
        this.commitRename();
      } else if (ev.key === "Escape") {
        ev.preventDefault();
        this.renaming = false;
        this.nameOverlay?.hide();
      }
    });
    name.addEventListener("blur", () => {
      // Clicking away is not a cancel: it is the same as pressing Enter on a
      // field you have finished typing into.
      if (this.renaming) this.commitRename();
    });
    this.nameEl = name;
  }

  /** Take what is in the field, if it is anything. */
  private commitRename(): void {
    if (!this.renaming) return;
    this.renaming = false;
    this.nameOverlay?.hide();
    const want = this.nameEl.value.trim().slice(0, 48);
    if (!want || want === this.held.name) return;
    this.held.name = want;
    this.dirty = true;
    this.dirtyFor = 0;
    this.app.chip.select();
    // A pad the server knows about has to be told; an unsaved one carries the
    // name into its first save.
    if (this.held.id !== null) void this.save();
  }

  /** Open the field over the name, with the current one selected. */
  private startRename(): void {
    this.renaming = true;
    this.nameEl.value = this.held.id === null && this.held.name === "SCRATCH" ? "" : this.held.name;
    this.nameEl.placeholder = this.heldName();
    setTimeout(() => {
      this.nameEl.focus();
      this.nameEl.select();
    }, 0);
  }

  async enter(): Promise<void> {
    this.offs.push(
      this.app.client.on("run.stage", (p) => {
        if (this.attemptId && p.attempt_id !== this.attemptId) return;
        this.attemptId = p.attempt_id;
        this.stage = p.stage;
      }),
      this.app.client.on("run.log", (p) => {
        if (this.attemptId && p.attempt_id !== this.attemptId) return;
        if (!this.attemptId) {
          this.attemptId = p.attempt_id;
          this.log = new LogBuffer(p.attempt_id);
        }
        this.log.push(p.stream, p.chunk, p.seq);
      }),
    );
    addEventListener("blur", this.onBlur);

    // The local mirror first, because it is instant and it is the copy that
    // survives a server that is not answering.
    this.restoreLocal();
    this.mount();
    void this.refreshList();
    // Only when there is nothing local worth keeping. Loading the server's
    // snapshot over text that never got saved is exactly the loss this screen
    // is not allowed to have.
    if (this.held.id && !this.dirty) void this.load(this.held.id, true);
  }

  leave(): void {
    void this.save();
    removeEventListener("blur", this.onBlur);
    for (const off of this.offs) off();
    this.offs = [];
    this.offLocale?.();
    this.offLocale = undefined;
    this.overlay?.destroy();
    this.stdinOverlay?.destroy();
    this.nameOverlay?.destroy();
    this.editor?.destroy();
    this.app.chip.music("stop");
  }

  // -- the text ------------------------------------------------------------

  private mount(): void {
    this.land = this.held.lang;
    this.editor = new Editor(this.held.lang, this.held.source, () => this.touched());
    this.overlay = new Overlay(this.app.overlay, this.app.layout, this.editor.dom);
    this.stdinOverlay = new Overlay(this.app.overlay, this.app.layout, this.stdinEl);
    this.nameOverlay = new Overlay(this.app.overlay, this.app.layout, this.nameEl);
    this.nameOverlay.hide();
    queueMicrotask(() => this.editor?.focus());
  }

  /** A keystroke: mirror it locally now, and start the autosave clock. */
  private touched(): void {
    this.held.source = this.editor?.source ?? this.held.source;
    this.dirty = true;
    this.dirtyFor = 0;
    this.writeLocal();
  }

  private writeLocal(): void {
    try {
      localStorage.setItem(LOCAL_KEY, JSON.stringify({ ...this.held, dirty: this.dirty }));
    } catch {
      /* private browsing: the server copy is still the real one */
    }
  }

  private restoreLocal(): void {
    try {
      const raw = localStorage.getItem(LOCAL_KEY);
      if (!raw) return;
      const v = JSON.parse(raw) as Partial<Held>;
      if (typeof v.source !== "string") return;
      this.held = {
        id: typeof v.id === "string" ? v.id : null,
        name: typeof v.name === "string" ? v.name : "SCRATCH",
        lang: isLand(v.lang) ? v.lang : "rust",
        source: v.source,
        dirty: v.dirty === true,
      };
      // Unsaved text from last time is still unsaved: it stays on screen, it is
      // not fetched over, and the first autosave pushes it up.
      this.dirty = this.held.dirty === true;
    } catch {
      /* a corrupt mirror is not worth a screen full of error */
    }
  }

  // -- the server ----------------------------------------------------------

  private async refreshList(): Promise<void> {
    try {
      const res = await this.app.client.request("playground.list", {});
      this.snippets = res.snippets;
    } catch (e) {
      // A server without §4.9c yet: the scratchpad still works, it is just
      // this tab's until the calls land. Say so rather than showing nothing.
      this.snippets = [];
      if (e instanceof WireError && e.payload.code === "not_found") {
        this.saveNote = t("pg.noList");
      }
    }
  }

  private async load(id: string, quiet = false): Promise<void> {
    try {
      const res = await this.app.client.request("playground.load", { id });
      this.held = {
        id: res.snippet.id,
        name: res.snippet.name,
        lang: res.snippet.lang,
        source: res.snippet.source,
      };
      this.savedSource = res.snippet.source;
      this.savedLang = res.snippet.lang;
      this.dirty = false;
      this.land = res.snippet.lang;
      this.editor?.load(res.snippet.lang, res.snippet.source);
      this.writeLocal();
      this.result = null;
      this.log = new LogBuffer("");
      if (!quiet) this.app.chip.select();
    } catch (e) {
      if (!quiet)
        this.status = e instanceof WireError ? playerText(e.payload.code) : t("pg.openFailed");
    }
  }

  /**
   * Autosave. Cheap and idempotent by design (§4.9c), and skipped entirely
   * when nothing has changed — an autosave timer that posts the same bytes
   * every two seconds is a denial of service with good intentions.
   */
  private async save(): Promise<void> {
    if (this.saving) return;
    const source = this.editor?.source ?? this.held.source;
    this.held.source = source;
    this.writeLocal();
    if (!this.dirty || (source === this.savedSource && this.held.lang === this.savedLang)) {
      this.dirty = false;
      return;
    }
    this.saving = true;
    try {
      const res = await this.app.client.request("playground.save", {
        ...(this.held.id ? { id: this.held.id } : {}),
        lang: this.held.lang,
        source,
      });
      this.held.id = res.snippet.id;
      this.held.name = res.snippet.name;
      this.savedSource = source;
      this.savedLang = this.held.lang;
      this.dirty = false;
      this.saveNote = "saved";
      this.writeLocal();
      void this.refreshList();
    } catch (e) {
      // Not a disaster: the local mirror holds the text and the next timer
      // will try again. It is still said out loud, because "saved" and "not
      // saved" must never look the same.
      this.saveNote =
        e instanceof WireError && e.payload.code === "not_found"
          ? t("pg.localOnly")
          : t("pg.saveFailed");
    } finally {
      this.saving = false;
    }
  }

  private async run(): Promise<void> {
    if (this.stage !== "idle") return;
    const source = this.editor?.source ?? this.held.source;
    this.held.source = source;
    this.status = "";
    this.result = null;
    this.attemptId = null;
    this.log = new LogBuffer("");
    this.stage = "queued";
    this.app.chip.select();
    try {
      const res = await this.app.client.request("playground.run", {
        lang: this.held.lang,
        source,
        ...(this.stdinEl.value ? { stdin: this.stdinEl.value } : {}),
      });
      this.result = res.run;
      if (res.run.outcome === "ok") this.app.chip.coin();
      // No screen shake here, on purpose *and* because it could not land:
      // `App.shake` refuses while the overlay has children, and this screen
      // always has two. A failed compile in a scratchpad is also not a failure
      // — it is the thing you came here to read.
      else this.app.chip.fail();
    } catch (e) {
      this.status =
        e instanceof WireError && e.payload.code === "not_found"
          ? t("pg.noPlayground")
          : e instanceof WireError
            ? playerText(e.payload.code)
            : t("pg.runSilent");
      this.app.chip.fail();
    } finally {
      this.stage = "idle";
    }
  }

  /**
   * §4.9d, the same three outcomes as the quest screen: formatted (the caret
   * stays put), already tidy (nothing is touched), or it does not parse — in
   * which case the formatter's own line is shown quietly and the buffer is
   * left exactly as it is. Half-written code is the normal state of a
   * scratchpad, not a fault.
   */
  private async format(): Promise<void> {
    if (!this.editor || this.formatting) return;
    this.formatting = true;
    try {
      const res = await this.app.client.request("code.format", {
        lang: this.held.lang,
        source: this.editor.source,
      });
      if (res.problem) this.status = res.problem;
      else if (res.changed) {
        this.editor.replaceAll(res.source);
        this.touched();
        this.status = "";
        this.app.chip.blip();
      } else this.status = t("quest.alreadyTidy");
    } catch (e) {
      this.status =
        e instanceof WireError && e.payload.code === "not_found"
          ? t("quest.noFormat")
          : e instanceof WireError
            ? playerText(e.payload.code)
            : t("quest.formatSilent");
    } finally {
      this.formatting = false;
    }
  }

  private fresh(): void {
    void this.save();
    this.held = {
      id: null,
      name: "SCRATCH",
      lang: this.held.lang,
      source: STARTER[this.held.lang],
    };
    this.savedSource = "";
    this.dirty = true;
    this.result = null;
    this.log = new LogBuffer("");
    this.editor?.load(this.held.lang, this.held.source);
    this.writeLocal();
    this.app.chip.select();
  }

  private setLang(lang: Land): void {
    if (lang === this.held.lang) return;
    const source = this.editor?.source ?? this.held.source;
    // Only the untouched starter is swapped. Somebody who has written Go and
    // presses RUST wants their text in a Rust file, not their text deleted.
    const pristine = source.trim() === STARTER[this.held.lang].trim();
    this.held.lang = lang;
    this.land = lang;
    if (pristine) this.held.source = STARTER[lang];
    this.editor?.load(lang, this.held.source);
    this.dirty = true;
    this.dirtyFor = 0;
    this.writeLocal();
    this.app.chip.blip();
  }

  private async remove(): Promise<void> {
    const id = this.held.id;
    if (!id) return;
    try {
      await this.app.client.request("playground.delete", { id });
      this.held.id = null;
      this.saveNote = "deleted";
      void this.refreshList();
    } catch (e) {
      this.saveNote = e instanceof WireError ? playerText(e.payload.code) : t("pg.deleteFailed");
    }
  }

  // -- input ---------------------------------------------------------------

  key(name: string, ev: KeyboardEvent): void {
    if (name === "escape") return void this.app.go(new LandsScene(this.app), "back");
    if ((name === "return" || name === "kpenter") && (ev.ctrlKey || ev.metaKey)) {
      ev.preventDefault();
      void this.run();
    }
    if (name === "s" && (ev.ctrlKey || ev.metaKey)) {
      ev.preventDefault();
      void this.save();
    }
    if (name === "f" && (ev.ctrlKey || ev.metaKey) && ev.shiftKey) {
      ev.preventDefault();
      void this.format();
    }
  }

  controls(): Buttons[] {
    return [this.buttons, this.rows];
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    if (phase === "move") {
      this.buttons.hovered = this.buttons.hit(x, y)?.id ?? null;
      this.rows.hovered = this.rows.hit(x, y)?.id ?? null;
      return;
    }
    if (phase !== "down") return;
    const hit = this.buttons.hit(x, y) ?? this.rows.hit(x, y);
    if (!hit) return;
    if (this.display(hit.id)) return;
    if (hit.id === "code") {
      this.focus = true;
      this.app.chip.select();
      // Same race the quest screen has: a `focus()` inside a pointer handler
      // is undone by the browser's own blur on the way out of it.
      setTimeout(() => this.editor?.focus(), 0);
      return;
    }
    if (hit.id === "unfocus") {
      this.focus = false;
      this.app.chip.select();
      return;
    }
    if (hit.id === "rename") {
      this.startRename();
      return;
    }
    if (hit.id === "run") void this.run();
    else if (hit.id === "format") void this.format();
    else if (hit.id === "save") void this.save();
    else if (hit.id === "new") this.fresh();
    else if (hit.id === "delete") void this.remove();
    else if (hit.id === "back") void this.app.go(new LandsScene(this.app), "back");
    else if (isLand(hit.id)) this.setLang(hit.id);
    else if (hit.id.startsWith("snip:")) void this.load(hit.id.slice(5));
  }

  update(dt: number): void {
    this.t += dt;
    this.benchIn.update(dt);
    this.listIn.update(dt);
    // Clamped here rather than in the wheel handler, for the same reason
    // quest.ts clamps briefScroll here: the overflow is only known after a
    // frame has laid the lines out, and it changes as output streams in.
    this.outputScroll = Math.max(0, Math.min(this.outputScroll, this.outputOverflow));
    if (this.dirty) {
      this.dirtyFor += dt;
      if (this.dirtyFor >= AUTOSAVE_AFTER) {
        this.dirtyFor = 0;
        void this.save();
      }
    }
  }

  wheel(dy: number, x: number, y: number): void {
    if (inRect(x, y, this.outputRect)) {
      // Same convention as the quest console: positive dy is "further into
      // the past", so it *increases* how far back from the live tail we are.
      this.outputScroll = Math.max(
        0,
        Math.min(this.outputOverflow, this.outputScroll - Math.round(dy / 8)),
      );
    }
  }

  resized(): void {
    /* both overlays are placed from the current layout every frame */
  }

  // -- drawing -------------------------------------------------------------

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    this.drawRoom(g);
    if (this.focus) {
      this.buttons.reset();
      this.rows.reset();
      this.drawFocus(g, layout.uiScale());
      this.buttons.draw(g, ensureFonts(layout.uiScale()).stationSm);
      return;
    }
    header(g, this.app, t("pg.title", { name: this.heldName().toUpperCase() }));
    const f = frame(layout, layout.isPortrait() ? 0.26 : 0.26, 0.07);
    const s = f.scale;
    this.buttons.reset();
    this.rows.reset();
    this.drawList(g, f.left, s);
    this.drawBench(g, f.right, s);
    this.buttons.draw(g, ensureFonts(s).button);
    footer(g, layout, t("pg.footer"));
  }

  /**
   * Mei's own desk.
   *
   * `bg_playground` was made for this screen and this screen only — the room
   * the game opens in, deliberately the one room in the pack with no problem
   * in it — and nothing referenced it, so the scratchpad drew the generic
   * night city like every other screen. An asset made for one screen and not
   * wired to it is the same fault as a screen with no art, arrived at by a
   * longer road.
   *
   * Cover, never stretch: a 3:2 room pulled to a 0.6:1 window is the "three
   * unrelated rooms tiled down the page" the lands screen was reported for.
   * And the scrim is **lighter than every other screen's** — 0.5 against the
   * quest screen's 0.55 and the lands screen's effective 0.75 — because the
   * one asset this screen has is the room, and dimming it to the point where
   * it could be any dark blue would be drawing it and then covering it up.
   * (The LÖVE client settled on 0.52 for the same reason; this is the same
   * decision, taken against this client's own panels.)
   *
   * It is drawn on both paths, WebGL or not. The city behind is generic and
   * this is not, so there is nothing here for the parallax to add.
   */
  private drawRoom(g: Ctx): void {
    const { layout } = this.app;
    const room = this.app.assets?.picture("bg_playground", layout.isPortrait());
    if (!room) return;
    const k = Math.max(layout.vw / room.naturalWidth, layout.vh / room.naturalHeight);
    const aw = room.naturalWidth * k;
    const ah = room.naturalHeight * k;
    g.save();
    g.globalAlpha = 0.9;
    clipped(g, 0, 0, layout.vw, layout.vh, () =>
      g.drawImage(room, (layout.vw - aw) / 2, (layout.vh - ah) / 2, aw, ah),
    );
    g.restore();
    fill(g, Theme.void, 0, 0, layout.vw, layout.vh, 0.5);
  }

  /** The saved snippets, and the one line that says what this screen is. */
  private drawList(g: Ctx, rect: Rect, s: number): void {
    const fonts = ensureFonts(s);
    const inner = titledPanel(g, rect, t("pg.scratchpads"), Theme.coin);
    let y = inner[1];
    const pad = Math.round(8 * s);

    // The rule, stated once, where it cannot be missed. It is the opposite of
    // the quest screen's rule and the player has to be told which one they are
    // standing on.
    g.fillStyle = css(Theme.cream, 0.7);
    const note = t("pg.notScored");
    const lines = wrap(fonts.small, note, inner[2]);
    for (const line of lines) {
      printf(g, fonts.small, line, inner[0], y, inner[2], "left");
      y += fonts.small.height;
    }
    y += pad;

    const rowH = Math.max(this.app.layout.minTouchH(), fonts.small.height + Math.round(14 * s));
    const room = inner[1] + inner[3] - y - rowH - pad;
    clipped(g, inner[0], y, inner[2], Math.max(0, room), () => {
      let ry = y;
      for (const snip of this.snippets) {
        if (ry + rowH > y + room) break;
        const id = `snip:${snip.id}`;
        const open = snip.id === this.held.id;
        const hover = this.rows.hovered === id;
        fill(g, open ? Theme.navy : Theme.ink, inner[0], ry, inner[2], rowH - 2, open ? 0.95 : 0.5);
        fill(
          g,
          landColour(snip.lang),
          inner[0],
          ry,
          Math.round(4 * s),
          rowH - 2,
          open || hover ? 1 : 0.5,
        );
        // The language tag owns the right of the row, so the name is measured
        // against what is left of it. A server-assigned name is a date and it
        // is long enough to run straight under the tag otherwise.
        const tagW = Math.round(46 * s);
        g.fillStyle = css(open ? Theme.coin : Theme.cream, hover ? 1 : 0.85);
        printf(
          g,
          fonts.small,
          snip.name,
          inner[0] + Math.round(10 * s),
          ry + Math.round((rowH - fonts.small.height) / 2),
          inner[2] - Math.round(20 * s) - tagW,
          "left",
        );
        g.fillStyle = css(Theme.dim);
        printf(
          g,
          fonts.stationSm,
          landName(snip.lang),
          inner[0],
          ry + Math.round((rowH - fonts.stationSm.height) / 2),
          inner[2] - Math.round(8 * s),
          "right",
        );
        this.rows.add({ id, rect: [inner[0], ry, inner[2], rowH - 2], label: snip.name });
        ry += rowH;
      }
      if (this.snippets.length === 0) {
        g.fillStyle = css(Theme.dim);
        printf(g, fonts.small, t("pg.nothingSaved"), inner[0], y + pad, inner[2], "center");
      }
      if (this.saveNote) {
        g.fillStyle = css(Theme.coin, 0.85);
        printf(
          g,
          fonts.small,
          this.saveNote,
          inner[0],
          y + room - wrap(fonts.small, this.saveNote, inner[2]).length * fonts.small.height,
          inner[2],
          "left",
        );
      }
    });

    const [, nh] = btnBox(
      fonts.button,
      [t("pg.new")],
      0,
      fonts.button.size * 2,
      this.app.layout.minTouchH(),
    );
    // NEW, RENAME and whichever of DELETE applies, laid by the row helper so
    // three of them wrap in a narrow list panel instead of the third being
    // painted over the second's last letter.
    const list = [
      { id: "new", label: t("pg.new") },
      { id: "rename", label: t("pg.rename") },
      ...(this.held.id ? [{ id: "delete", label: t("pg.delete") }] : []),
    ];
    const listRows = rowsIn(
      fonts.button,
      list.map((b) => b.label),
      inner[2],
      this.app.layout.minTouchH(),
    );
    const listGap = Math.round(6 * s);
    const listH = listRows * nh + (listRows - 1) * listGap;
    this.buttons.row(
      fonts.button,
      [inner[0], inner[1] + inner[3] - listH, inner[2], listH],
      list,
      this.app.layout.minTouchH(),
    );
  }

  /**
   * The two display toggles, as buttons rather than only as keys.
   *
   * F1 and F11 have always done this on every screen; a key is not a control
   * on a phone, and this is the screen people reach for on a phone. Each says
   * the state it is **in**, not the state it would move to — a toggle whose
   * value is invisible gets pressed twice, once to find out and once to put
   * it back. The labels are the LÖVE client's, verbatim, because the two
   * clients should not disagree about what this button is called.
   */
  private displayItems(): Array<{ id: string; label: string; strong?: boolean }> {
    const choice = this.app.layout.choice;
    return [
      { id: "fullscreen", label: this.app.isFullscreen() ? "FULL" : "WINDOW" },
      {
        id: "orient",
        label: choice === null ? "AUTO" : choice === "portrait" ? "PORT" : "LAND",
        strong: choice !== null,
      },
    ];
  }

  /** Press one of them. Shared by the bench and by CODE. */
  private display(id: string): boolean {
    if (id === "fullscreen") {
      void this.app.toggleFullscreen().then((on) => {
        this.app.say(on ? t("app.fullscreenOn") : t("app.fullscreenOff"));
      });
      return true;
    }
    if (id === "orient") {
      this.app.cycleOrientation();
      return true;
    }
    return false;
  }

  /**
   * CODE: the editor, the few controls a writing hand uses, and nothing else.
   *
   * Modelled on the quest screen's mode of the same name, down to the DONE in
   * the corner — and with the same trap in it. `header()` is what clears and
   * re-sets `App.logoutRect`, this mode does not draw a header, and a stale
   * rect sits exactly where DONE does. Left alone, the button that ends a
   * writing session logs the player out.
   */
  private drawFocus(g: Ctx, s: number): void {
    const { layout } = this.app;
    this.app.logoutRect = null;
    this.app.logoutHover = false;
    // The bench's other DOM overlay is not drawn here and must not be left
    // floating over the editor: an element nobody placed this frame keeps the
    // rectangle it had in the framed layout.
    this.stdinOverlay?.hide();
    const fonts = ensureFonts(s);
    const f = fonts.stationSm;
    const pad = Math.round(6 * s);
    const done = t("pg.codeDone");
    const [dw, dh] = btnBox(f, [done], 0, f.size * 2, layout.minTouchH());
    const bx = layout.vw - pad - dw;

    const items = [
      {
        id: "run",
        label: this.stage === "idle" ? t("pg.run") : "…",
        dim: this.stage !== "idle",
        primary: this.stage === "idle",
      },
      { id: "format", label: t("pg.format"), dim: this.formatting },
      { id: "save", label: this.dirty ? t("pg.saveDirty") : t("pg.save") },
      { id: "rename", label: t("pg.rename") },
      ...this.displayItems(),
    ];
    const rowW = Math.max(f.size * 4, bx - pad * 2);
    const rows = rowsIn(
      f,
      items.map((i) => i.label),
      rowW,
      layout.minTouchH(),
    );
    const rowGap = Math.round(f.size * 0.5);
    const bandH = rows * dh + (rows - 1) * rowGap;
    const strip = pad + Math.max(bandH, dh) + Math.round(3 * s) + f.height + Math.round(4 * s);
    fill(g, Theme.ink, 0, 0, layout.vw, strip, 0.82);
    fill(g, Theme.dim, 0, strip, layout.vw, 1, 0.5);
    this.buttons.row(f, [pad, pad, rowW, bandH], items, layout.minTouchH());
    this.buttons.add({ id: "unfocus", rect: [bx, pad, dw, dh], label: done });

    // Which pad, in which language, and whether it is safe on the server —
    // the three things the framed screen says in its title that a person
    // writing still needs to know.
    const statusY = pad + Math.max(bandH, dh) + Math.round(3 * s);
    const note = this.saveNote || this.status;
    const status = `${MAIN_FILE[this.held.lang]}   ${this.heldName().toUpperCase()}${
      this.dirty ? `   ${t("pg.unsaved")}` : ""
    }${note ? `   ${note}` : ""}`;
    g.fillStyle = css(this.dirty ? Theme.coin : Theme.dim);
    printf(g, f, status, pad + Math.round(8 * s), statusY, layout.vw - pad * 2, "left");
    if (this.renaming) {
      const h = Math.max(layout.minTouchH(), f.height + 12);
      this.nameOverlay?.place(
        [pad, statusY - Math.round(2 * s), Math.min(layout.vw - pad * 2, Math.round(260 * s)), h],
        f.size,
      );
    } else {
      this.nameOverlay?.hide();
    }

    // Output only once there is any: a scratchpad whose whole purpose is to
    // run things must not hide what they printed, and an empty panel would
    // be spending the room this mode exists to hand to the editor.
    const hasOut = this.log.lines.length > 0 || this.result !== null;
    const outH = hasOut ? Math.round((layout.vh - strip) * (layout.isPortrait() ? 0.24 : 0.26)) : 0;
    const top = strip + Math.round(6 * s);
    const editorH = layout.vh - top - pad - (hasOut ? outH + pad : 0);
    well(g, pad, top, layout.vw - pad * 2, editorH);
    const editorRect: Rect = [pad + 4, top + 4, layout.vw - pad * 2 - 8, editorH - 8];
    if (this.editor) this.overlay?.place(editorRect, fonts.codeSm.size);
    else this.overlay?.hide();
    if (hasOut) {
      this.drawOutput(g, [pad, top + editorH + pad, layout.vw - pad * 2, outH], s);
    } else {
      this.outputRect = [0, 0, 0, 0];
    }
  }

  /** The editor, the stdin box, the buttons and whatever the program said. */
  private drawBench(g: Ctx, rect: Rect, s: number): void {
    const { layout } = this.app;
    const fonts = ensureFonts(s);
    const accent = landColour(this.held.lang);
    const label = MAIN_FILE[this.held.lang];
    const inner = titledPanel(g, rect, `${label}   ${this.stageLabel()}`, accent);
    // The field, when somebody is renaming: over the title of the panel whose
    // name it is, so the change happens where the name is written.
    if (this.renaming) {
      const h = Math.max(layout.minTouchH(), fonts.button.height + 12);
      this.nameOverlay?.place(
        [rect[0] + 8, rect[1] + 4, Math.min(rect[2] - 16, Math.round(260 * s)), h],
        fonts.button.size,
      );
    } else {
      this.nameOverlay?.hide();
    }

    const btnH = Math.max(layout.minTouchH(), fonts.button.height + 20);
    const gap = Math.round(8 * s);
    const stdinH = Math.max(Math.round(46 * s), fonts.codeSm.height * 2 + Math.round(16 * s));
    const outH = Math.round(inner[3] * (layout.isPortrait() ? 0.3 : 0.28));
    const actions = [
      {
        id: "run",
        label: this.stage === "idle" ? t("pg.run") : "…",
        dim: this.stage !== "idle",
        primary: this.stage === "idle",
      },
      { id: "format", label: t("pg.format"), dim: this.formatting },
      { id: "save", label: this.dirty ? t("pg.saveDirty") : t("pg.save") },
      // The way out of the crowding, on the screen that is crowded.
      { id: "code", label: t("pg.code") },
      ...this.displayItems(),
      { id: "back", label: t("pg.maps") },
    ];
    const labels = actions.map((a) => a.label);
    // The language buttons are laid out first and taken out of the row's
    // width, like SUBMIT on the quest screen: they are a *state*, not an
    // action, and the chosen one is painted lit so the screen says which file
    // you are in twice over. One box per land, each as wide as its own label.
    const langBoxes = LANDS.map((land) => {
      const label = t(`pg.${land}` as "pg.rust");
      const [bw, bh] = btnBox(fonts.button, [label], 0, fonts.button.size * 2, layout.minTouchH());
      return { land, label, bw, bh };
    });
    const langH = langBoxes[0].bh;
    const langGap = Math.round(fonts.button.size * 0.5);
    const langsW = langBoxes.reduce((n, b) => n + b.bw, 0) + langGap * (langBoxes.length - 1);
    // Beside the actions only when *all* of them still fit on one row next to
    // the four lands — not merely when RUN does. The old test asked about one
    // label and answered for the whole band, so in landscape, where the bench
    // is the narrow half of the frame, the lands took the width and the
    // actions came back seven rows of one button each: 380 pixels of buttons
    // over a panel 476 tall, and an editor at its 60-pixel floor. That is the
    // screen that was reported as very hard to use.
    const besideW = inner[2] - langsW - langGap * 2;
    const beside =
      besideW > 0 && rowsIn(fonts.button, labels, besideW, layout.minTouchH()) === 1;
    const rowW = beside ? besideW : inner[2];
    const rows = rowsIn(fonts.button, labels, rowW, layout.minTouchH());
    const rowGap = Math.round(fonts.button.size * 0.5);
    const langBand = beside ? 0 : langH + rowGap;
    const bandH = rows * btnH + (rows - 1) * rowGap + langBand;

    // **The editor is served first.** It used to be served last — whatever a
    // fixed stdin box, a percentage-of-panel output panel and however many
    // rows of buttons happened to leave — which is an editor that vanishes
    // exactly when the screen gets tight. It now claims a share of the panel
    // and the shortfall comes out of the output first, because the output
    // scrolls and the thing being typed into does not.
    const wantEditor = Math.round(inner[3] * (layout.isPortrait() ? 0.34 : 0.36));
    const minOut = fonts.codeSm.height * 3 + Math.round(10 * s);
    // Its label and one whole line of what you typed. Anything less is a box
    // that says STDIN over a sliver of a character, which is how it looked
    // when the editor was allowed to take the last of it.
    const minStdin = fonts.stationSm.height + fonts.codeSm.height + Math.round(12 * s);
    let outRoom = outH;
    let stdinRoom = stdinH;
    let editorH = inner[3] - bandH - stdinRoom - outRoom - gap * 3;
    if (editorH < wantEditor) {
      const fromOut = Math.min(wantEditor - editorH, Math.max(0, outRoom - minOut));
      outRoom -= fromOut;
      editorH += fromOut;
    }
    if (editorH < wantEditor) {
      const fromStdin = Math.min(wantEditor - editorH, Math.max(0, stdinRoom - minStdin));
      stdinRoom -= fromStdin;
      editorH += fromStdin;
    }
    editorH = Math.max(60, editorH);

    well(g, inner[0], inner[1], inner[2], editorH);
    const editorRect: Rect = [inner[0] + 4, inner[1] + 4, inner[2] - 8, editorH - 8];
    if (this.editor && this.benchIn.finished) this.overlay?.place(editorRect, fonts.codeSm.size);
    else this.overlay?.hide();

    // The stdin box. It matters here in a way it never does on a quest screen:
    // there is no test case to supply the input, so without this there is no
    // way to write a program that reads anything.
    const stdinY = inner[1] + editorH + gap;
    well(g, inner[0], stdinY, inner[2], stdinRoom, [0.06, 0.05, 0.14, 0.98]);
    g.fillStyle = css(Theme.dim);
    printf(
      g,
      fonts.stationSm,
      t("pg.stdin"),
      inner[0] + Math.round(6 * s),
      stdinY + Math.round(4 * s),
      inner[2],
      "left",
    );
    const stdinRect: Rect = [
      inner[0] + 4,
      stdinY + fonts.stationSm.height + Math.round(4 * s),
      inner[2] - 8,
      stdinRoom - fonts.stationSm.height - Math.round(8 * s),
    ];
    if (this.benchIn.finished) this.stdinOverlay?.place(stdinRect, fonts.codeSm.size);
    else this.stdinOverlay?.hide();

    const rowY = stdinY + stdinRoom + gap + langBand;
    this.buttons.row(
      fonts.button,
      [inner[0], rowY, rowW, bandH - langBand],
      actions,
      layout.minTouchH(),
    );

    // RUST | GO | C++ | PYTHON, at the far end of the band, laid right to left
    // so the last land sits flush with the edge whatever the labels measure.
    const langY = beside ? rowY + Math.round((btnH - langH) / 2) : rowY - langBand;
    let bx = inner[0] + inner[2];
    for (const { land: id, label, bw } of [...langBoxes].reverse()) {
      bx -= bw;
      const on = this.held.lang === id;
      const hover = this.buttons.hovered === id;
      if (on) {
        panel(g, bx, langY, bw, langH, landColour(id));
        g.fillStyle = css(Theme.ink);
        printf(
          g,
          fonts.button,
          label,
          bx,
          langY + 8 + Math.floor((langH - 8 - fonts.button.height) * 0.5),
          bw,
          "center",
        );
      } else {
        pixBtn(g, fonts.button, bx, langY, bw, langH, label, { hover, quiet: true });
      }
      this.buttons.add({ id, rect: [bx, langY, bw, langH], label });
      bx -= langGap;
    }

    // The actions start at `rowY` and are `bandH - langBand` tall — the land
    // band sits *above* `rowY`, and `rowY` already stepped over it. Adding the
    // whole of `bandH` here counted that band twice and pushed the output
    // panel off the bottom of the bench by exactly its height.
    const outTop = rowY + (bandH - langBand) + gap;
    this.drawOutput(
      g,
      [inner[0], outTop, inner[2], Math.max(24, inner[1] + inner[3] - outTop)],
      s,
    );
  }

  /** What the program printed, and what the compiler thought of it. */
  private drawOutput(g: Ctx, rect: Rect, s: number): void {
    const [x, y, w, h] = rect;
    const fonts = ensureFonts(s);
    const pad = Math.round(6 * s);
    let ty = y + pad;

    const r = this.result;
    if (r) {
      const ok = r.outcome === "ok";
      fill(g, ok ? Theme.admit : Theme.brick, x, y, w, Math.round(3 * s), 0.9);
      g.fillStyle = css(ok ? Theme.admit : Theme.red);
      printf(
        g,
        fonts.stationSm,
        OUTCOME[r.outcome](),
        x + pad,
        ty + Math.round(3 * s),
        w - pad * 2,
        "left",
      );
      g.fillStyle = css(Theme.dim);
      const exit = r.exit_code === null ? "" : t("pg.exit", { code: r.exit_code });
      printf(
        g,
        fonts.stationSm,
        t("pg.timings", { compile: r.compile_ms, run: r.run_ms, exit }),
        x,
        ty + Math.round(3 * s),
        w - pad,
        "right",
      );
      ty += fonts.stationSm.height + Math.round(6 * s);
    } else if (this.status) {
      // Wrapped, and the well starts under however many lines it took. A
      // status that says half a sentence is worse than one that says nothing.
      const lines = wrap(fonts.small, this.status, w - pad * 2);
      g.fillStyle = css(Theme.coin);
      for (const line of lines) {
        printf(g, fonts.small, line, x + pad, ty, w - pad * 2, "left");
        ty += fonts.small.height;
      }
      ty += Math.round(4 * s);
    }

    well(g, x, ty, w, Math.max(16, y + h - ty), [0.04, 0.03, 0.1, 0.98]);
    this.outputRect = [x, ty, w, y + h - ty];
    const lineH = fonts.codeSm.height;
    const room = Math.max(1, Math.floor((y + h - ty - pad * 2) / lineH));
    const out: Array<[string, readonly [number, number, number, number]]> = [];
    if (r) {
      for (const d of r.diagnostics) {
        const where = d.line === null ? "" : ` (${d.line}${d.col === null ? "" : ":" + d.col})`;
        out.push([`${d.kind}${d.code ? " " + d.code : ""}${where}  ${d.message}`, Theme.pink]);
      }
      for (const line of r.stdout.split("\n")) if (line) out.push([line, Theme.cream]);
      for (const line of r.stderr.split("\n")) if (line) out.push([line, Theme.red]);
    }
    // While it is still running, the compiler's own chatter is the progress bar.
    if (!r)
      for (const l of this.log.lines)
        out.push([l.text, l.stream === "stderr" ? Theme.red : Theme.dim]);
    if (out.length === 0) {
      this.outputOverflow = 0;
      g.fillStyle = css(Theme.dim);
      printf(g, fonts.codeSm, t("pg.nothingRun"), x + pad * 2, ty + pad, w - pad * 4, "left");
      return;
    }
    // `outputScroll` counts lines back from the tail (0 = live), so the same
    // *moment* stays on screen as more output streams in, rather than an
    // absolute index that would silently point somewhere else. This is the
    // fix for "cannot scroll" — the panel used to always show only the tail,
    // with nothing to move that window and no wheel handler to move it.
    this.outputOverflow = Math.max(0, out.length - room);
    const scroll = Math.min(this.outputScroll, this.outputOverflow);
    const end = out.length - scroll;
    const shown = out.slice(Math.max(0, end - room), end);
    clipped(g, x, ty, w, y + h - ty, () => {
      let ly = ty + pad;
      for (const [text, col] of shown) {
        g.fillStyle = css(col);
        printf(g, fonts.codeSm, text, x + pad * 2, ly, w - pad * 4, "left");
        ly += lineH;
      }
    });
    if (this.outputOverflow > 0) {
      // Same widget as the quest console's brief scrollbar: a track the full
      // height of the well, a thumb sized and placed by how much is hidden —
      // a panel that can scroll and does not say so is a panel nobody finds.
      const trackH = y + h - ty;
      const thumbH = Math.max(12, (trackH * trackH) / (trackH + this.outputOverflow * lineH));
      const frac = 1 - scroll / this.outputOverflow;
      fill(g, Theme.ink, x + w - 4, ty, 4, trackH, 0.5);
      fill(g, Theme.coin, x + w - 4, ty + (trackH - thumbH) * frac, 4, thumbH);
    }
  }

  private stageLabel(): string {
    if (this.stage === "idle") return this.dirty ? t("pg.unsaved") : "";
    const dots = ".".repeat(1 + (Math.floor(this.t * 3) % 3));
    return `${this.stage.toUpperCase()}${dots}`;
  }
}
