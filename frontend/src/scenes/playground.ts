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
 * focus, and when the screen is left — and it is mirrored into this tab's
 * `sessionStorage` on every keystroke, so a reload or a dropped socket cannot
 * cost work either.
 */
import type { App, Scene } from "../app";
import { elide, ensureFonts, inkBox, inkCentreY, printf, width, wrap } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { burstPlan } from "../engine/burst";
import { remoteSaveAction } from "../net/remote";
import {
  BTN_FRAME,
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
import {
  CODE_FACE_KEY,
  CODE_FONT_KEY,
  CODE_FONT_MAX,
  CODE_FONT_MIN,
  Editor,
  MAIN_FILE,
} from "../ui/editor";
import { CodeFx } from "../ui/codefx";
import { Coder } from "../ui/agent/coder";
import { CODE_FACE_NAME, CODE_FACES, getCodeFace, setCodeFace } from "../engine/text";
import { readNumberPref, writePref } from "../ui/prefs";
import { Overlay } from "../ui/overlay";
import { clipMessage, copyText, readText } from "../ui/clip";
import { LogBuffer } from "../net/logbuf";
import { WireError } from "../net/client";
import { isLand, LANDS, playerText } from "../net/protocol";
import { onLocale, t, tEn } from "../i18n";
import type { Land, PlaygroundRun, RunStage, SnippetBrief, Snippet } from "../net/protocol";
import { LandsScene } from "./lands";
import { isUnlocked, MAX_ACCOUNT_INDEX, signMessage, unlock, wipe } from "../wallet/wallet";
import { INDEX_PREF } from "./login";
import { deterministicUsername } from "../wallet/username";

/** Where the open scratchpad is mirrored, so a reload opens it again. */
/**
 * Where the local mirror of the open pad lives: **in this tab, under this
 * account**.
 *
 * It used to be one key in `localStorage` for the whole origin. With two tabs
 * signed in as two accounts — which is what the account index is for — one
 * account's unsaved draft was on offer to the other's playground, carrying
 * `id` with it: a snippet id belonging to somebody else, which the next
 * autosave would try to save into. The server scopes every snippet by address
 * and refuses (`snippets::get` — "somebody else's snippet is not found, not
 * forbidden"), so nothing could be corrupted; it would show the wrong text and
 * then fail.
 *
 * Two changes, and both are needed. `sessionStorage` puts the draft in the tab,
 * beside the session that owns it (`net/tabsession.ts`) — it still survives the
 * reload this exists for, and stops being visible to a tab practising as
 * somebody else. The address stays in the key because one tab can sign out and
 * back in as another account, and the draft must not follow it across.
 */
const LOCAL_KEY = (address: string) => `cwbhacker.playground.${address.toLowerCase()}`;

/**
 * The single shared key the mirror used before it was keyed by account.
 *
 * Removed rather than migrated. Whose draft it is cannot be known from the
 * outside, and handing it to whichever account opens the playground first
 * would be the bug this is fixing, with a coin toss in front of it. What is
 * lost is at most the few seconds since the last autosave, and only for
 * somebody who upgrades mid-keystroke.
 *
 * It is the one `localStorage` call left in this file, and it only deletes.
 */
const LEGACY_LOCAL_KEY = "cwbhacker.playground";
/** How long after the last keystroke the autosave fires. */
const AUTOSAVE_AFTER = 2.5;

const STARTER: Record<Land, string> = {
  rust: 'fn main() {\n    println!("hello, causewaybay");\n}\n',
  go: 'package main\n\nimport "fmt"\n\nfunc main() {\n\tfmt.Println("hello, causewaybay")\n}\n',
  cpp: '#include <iostream>\n\nint main() {\n    std::cout << "hello, causewaybay\\n";\n}\n',
  python: 'print("hello, causewaybay")\n',
};

/** The outcomes as the poster prints them: English, whatever the screen is in. */
const EN_OUTCOME: Record<PlaygroundRun["outcome"], string> = {
  ok: tEn("pg.ran"),
  compile_error: tEn("pg.didNotCompile"),
  runtime_error: tEn("pg.stopped"),
  timeout: tEn("pg.timedOut"),
  output_limit: tEn("pg.tooMuch"),
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
type Held = {
  id: string | null;
  name: string;
  lang: Land;
  source: string;
  /** What the program reads. Part of the pad, not of the session. */
  stdin: string;
  dirty?: boolean;
};

/**
 * The name an unsaved pad wears until somebody gives it one.
 *
 * A sentinel rather than a name: the screen shows it translated, the server
 * is never told it, and RENAME treats a pad still wearing it as unnamed.
 */
const SCRATCH = "SCRATCH";

/** How many pads there have to be before the list offers to narrow itself. */
const SEARCH_FROM = 5;

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
  /**
   * Narrowing the list by name.
   *
   * The pads are a flat list in most-recently-touched order, which is the
   * right order to have and the wrong one to hunt through: by the time
   * somebody has a dozen named scratchpads, the one they want is the one they
   * remember the name of. Shown once there are enough of them to be worth it.
   */
  private readonly searchEl: HTMLInputElement;
  private searchOverlay: Overlay | null = null;
  private query = "";

  private snippets: SnippetBrief[] = [];
  private held: Held = { id: null, name: SCRATCH, lang: "rust", source: STARTER.rust, stdin: "" };
  /** The unsaved pad's name, translated. The stored `name` stays as it is. */
  private heldName(): string {
    // A pad renamed before it was ever saved keeps the name it was given:
    // `SCRATCH` is the placeholder, not a name somebody chose.
    if (this.held.id === null && this.held.name === SCRATCH) return t("pg.scratch");
    return this.held.name;
  }
  /** What the server last confirmed, so an identical save is not sent at all. */
  /**
   * Bumped whenever `held` becomes a different pad — NEW, a pad opened from
   * the list, the tab's mirror restored, the held pad deleted. A save is the
   * same pad and does not bump it. The coder's room follows this, since two
   * unsaved pads both have `id: null` and are otherwise indistinguishable.
   */
  private padSerial = 0;
  private savedSource = "";
  private savedLang: Land = "rust";
  /**
   * The name the server last confirmed.
   *
   * Kept beside the source and the language for the same reason they are: a
   * save that cannot tell what changed either sends everything every time or
   * — as this one did — decides nothing changed and sends nothing at all.
   */
  private savedName = "";
  /** The input the server last confirmed, beside the source and the name. */
  private savedStdin = "";
  private dirtyFor = 0;
  private dirty = false;
  private saving = false;
  private formatting = false;
  /** POSTER is a render and a file write; a second press mid-way is ignored. */
  private postering = false;
  /** DISK READER's file picker. Made once; the browser owns the dialogue. */
  private readonly diskEl: HTMLInputElement;
  /**
   * POSTER's key field, for the tab that has no key.
   *
   * A session resumed from its token — a reload, a second tab, tomorrow —
   * knows who you are and cannot sign as you: the key was only ever in the
   * tab that logged in (SPEC §3.1). So the stamp asks for the phrase or the
   * private key here, in place, checks it derives the address that is signed
   * in, and holds it for the rest of the tab, the way login does. Masked,
   * emptied on every exit, never stored.
   */
  private readonly keyEl: HTMLInputElement;
  private keyOverlay: Overlay | null = null;
  private stamping = false;

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
  /**
   * How big the code is drawn, as a multiple of the screen's own size.
   *
   * The quest screen's control, on the screen people sit at for longest.
   * Shared with it through one preference, because the size somebody can
   * read is a fact about them rather than about which screen they are on.
   */
  private fontMul = readNumberPref(CODE_FONT_KEY, 1, CODE_FONT_MIN, CODE_FONT_MAX);

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
  /** Where the editor was last drawn, for an effect over it. */
  private editorRect: Rect = [0, 0, 0, 0];
  /**
   * What *saving* said, kept apart from `status` on purpose: an autosave that
   * fires two seconds after a keystroke must never overwrite the reason a run
   * did not work, which is exactly what it did the first time these shared a
   * line.
   */
  private saveNote = "";
  private t = 0;
  /** The typing effects, over the editor. See `ui/codefx.ts`. */
  private fx: CodeFx | null = null;
  /** The Rust coder: the AI agent that flies over the code (`ui/agent/coder.ts`). */
  private coder: Coder | null = null;
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
    el.addEventListener("input", () => {
      // The pad's input is part of the pad, so touching it is an edit like
      // any other: without this the autosave never carries what was typed.
      if (this.held.stdin === el.value) return;
      this.dirty = true;
      this.dirtyFor = 0;
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

    const find = document.createElement("input");
    find.type = "text";
    find.className = "cwb-field";
    find.spellcheck = false;
    find.maxLength = 48;
    find.placeholder = t("pg.search");
    find.addEventListener("input", () => {
      this.query = find.value;
    });
    find.addEventListener("keydown", (ev) => {
      // Escape empties it rather than leaving a filter nobody can see the
      // bottom of. Enter opens the only match, which is what a search box
      // that found one thing should do.
      if (ev.key === "Escape") {
        ev.preventDefault();
        find.value = "";
        this.query = "";
        find.blur();
      } else if (ev.key === "Enter") {
        ev.preventDefault();
        const hits = this.visibleSnippets();
        if (hits.length > 0) void this.load(hits[0].id);
        find.blur();
      }
    });
    this.offs.push(
      onLocale(() => {
        find.placeholder = t("pg.search");
      }),
    );
    this.searchEl = find;

    const disk = document.createElement("input");
    disk.type = "file";
    disk.accept = "image/*";
    disk.style.display = "none";
    disk.addEventListener("change", () => {
      const f = disk.files?.[0];
      disk.value = "";
      if (f) void this.readDisk(f);
    });
    document.body.appendChild(disk);
    this.diskEl = disk;

    const key = document.createElement("input");
    key.type = "password";
    key.className = "cwb-field";
    key.spellcheck = false;
    key.autocomplete = "off";
    key.placeholder = t("pg.stampKey");
    this.offs.push(
      onLocale(() => {
        key.placeholder = t("pg.stampKey");
      }),
    );
    key.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") {
        ev.preventDefault();
        this.stampWith(key.value);
      } else if (ev.key === "Escape") {
        ev.preventDefault();
        this.stopStamp();
      }
    });
    key.addEventListener("blur", () => {
      // Clicking away is a cancel here, unlike RENAME: nothing typed into a
      // key field should sit on screen unattended.
      if (this.stamping) this.stopStamp();
    });
    this.keyEl = key;
  }

  /** Ask for the key, in the slot the pad's name is edited in. */
  private startStamp(): void {
    this.stamping = true;
    this.keyEl.value = "";
    this.saveNote = t("pg.stampAsk");
    setTimeout(() => this.keyEl.focus(), 0);
  }

  /** Put the field away, and whatever was typed into it with it. */
  private stopStamp(): void {
    this.stamping = false;
    this.keyEl.value = "";
    this.keyOverlay?.hide();
  }

  /**
   * Take what was typed as the key: derive it at the account index login
   * used, and go on to the poster only if it is the account that is signed
   * in. Anything else is wiped again at once — a stranger's key must not be
   * left unlocked in a tab that is logged in as somebody else.
   */
  private stampWith(text: string): void {
    const typed = text.trim();
    this.stopStamp();
    if (!typed) return;
    const index = readNumberPref(INDEX_PREF, 0, 0, MAX_ACCOUNT_INDEX);
    let who;
    try {
      who = unlock(typed, index);
    } catch {
      this.saveNote = t("pg.stampBadKey");
      this.app.chip.fail();
      return;
    }
    const me = this.app.addressLabel;
    if (who.lower !== me.toLowerCase()) {
      wipe();
      this.saveNote = t("pg.stampWrongKey", { address: `${me.slice(0, 6)}…${me.slice(-4)}` });
      this.app.chip.fail();
      return;
    }
    this.app.chip.select();
    void this.poster();
  }

  /** The pads the list is showing: all of them, or those the query matches. */
  private visibleSnippets(): SnippetBrief[] {
    const q = this.query.trim().toLowerCase();
    if (!q) return this.snippets;
    return this.snippets.filter((s) => s.name.toLowerCase().includes(q));
  }

  /**
   * Whether the box is worth its row.
   *
   * Four pads fit on any screen and are read in one glance; a search field
   * over them is a control that costs height and saves nothing. It stays once
   * it is in use, or the act of filtering down to two results would take the
   * box away and strand the filter.
   */
  private searchable(): boolean {
    return this.snippets.length >= SEARCH_FROM || this.query !== "";
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

  /**
   * What the run said, as text.
   *
   * Canvas output is pixels: there is nothing in this panel to select with a
   * mouse, so this is the only way a compiler error leaves the screen — which
   * is the thing somebody wants to hand to an assistant and ask about.
   */
  private outputText(): string {
    const out: string[] = [];
    if (this.result) {
      out.push(OUTCOME[this.result.outcome]?.() ?? this.result.outcome);
      out.push("");
    }
    for (const line of this.log.lines) out.push(line.text);
    return out.join("\n").trim();
  }

  /** Say what the clipboard did, on the line that says what saving did. */
  private clipSaid(
    what: string,
    res: Awaited<ReturnType<typeof copyText>>,
    verb: "copy" | "paste",
  ) {
    this.saveNote = clipMessage(what, res, verb).text;
    if (res.ok) this.app.chip.blip();
    else this.app.chip.fail();
  }

  /** Copy, paste — the two halves of working with something else. */
  private async clip(which: "code" | "out" | "copyin" | "in" | "paste"): Promise<void> {
    if (which === "code") {
      return this.clipSaid(t("clip.yourCode"), await copyText(this.editor?.source ?? ""), "copy");
    }
    if (which === "out") {
      return this.clipSaid(t("clip.theOutput"), await copyText(this.outputText()), "copy");
    }
    if (which === "copyin") {
      return this.clipSaid(t("clip.theInput"), await copyText(this.stdinEl.value), "copy");
    }
    if (which === "in") {
      const res = await readText();
      if (res.ok) {
        this.stdinEl.value = res.text ?? "";
        this.held.stdin = this.stdinEl.value;
        this.dirty = true;
        this.dirtyFor = 0;
        return this.clipSaid(t("clip.theInput"), res, "paste");
      }
      // The shared "press Cmd+V instead" line is the editor's advice, and
      // following it here would put the program's *input* into its *source*.
      if (res.why === "unsupported") {
        this.saveNote = t("clip.pasteInputByKey");
        this.app.chip.fail();
        return;
      }
      return this.clipSaid(t("clip.theInput"), res, "paste");
    }
    const res = await readText();
    if (!res.ok || !this.editor) return this.clipSaid(t("clip.yourCode"), res, "paste");
    if (res.text === this.editor.source) {
      this.saveNote = t("clip.sameAlready");
      return;
    }
    this.editor.replaceAll(res.text ?? "");
    this.touched();
    this.clipSaid(t("clip.yourCode"), res, "paste");
  }

  /** One step of code size, kept on the same rails as the quest screen's. */
  private sizeFont(by: number): void {
    const next = Math.min(
      CODE_FONT_MAX,
      Math.max(CODE_FONT_MIN, Math.round((this.fontMul + by) * 100) / 100),
    );
    if (next === this.fontMul) return;
    this.fontMul = next;
    writePref(CODE_FONT_KEY, String(next));
    this.saveNote = t("quest.fontSize", { percent: Math.round(next * 100) });
    this.app.chip.blip();
  }

  /**
   * The face the code is set in, cycled by one button that says which it is.
   *
   * A preference, kept beside the size one and shared with the quest screen
   * for the same reason: this is a fact about the person, not about which
   * screen they are on.
   */
  private cycleFace(): void {
    const at = CODE_FACES.indexOf(getCodeFace());
    const next = CODE_FACES[(at + 1) % CODE_FACES.length];
    setCodeFace(next);
    writePref(CODE_FACE_KEY, next);
    this.app.remeasure();
    this.saveNote = t("pg.codeFace", { name: CODE_FACE_NAME[next] });
    this.app.chip.blip();
  }

  /**
   * POSTER: the pad as one square PNG, signed by the wallet, saved to disk.
   *
   * The signature is EIP-191 over **the source and only the source**, made
   * here because the key is here — `wallet.ts` hands out signatures and
   * nothing else, and the server is never asked. After a reload the session
   * is resumed from its token and the key is *not* in memory, so there is
   * nothing to sign with: the poster is still made, with the seal greyed out
   * and a note saying how to get a real one. Refusing to make it at all
   * would punish the person for the thing the login screen told them was
   * safe (the key never leaving the tab).
   *
   * The rest is in `ui/poster.ts`, loaded on the press: it pulls in the four
   * grammars' parsers for the colouring and nobody pays for that on the way
   * into the room.
   */
  private async poster(): Promise<void> {
    if (this.postering) return;
    if (!isUnlocked()) {
      // No key in this tab: ask for it, and come back here from `stampWith`.
      this.startStamp();
      return;
    }
    this.postering = true;
    try {
      const source = this.editor?.source ?? this.held.source;
      const address = this.app.addressLabel;
      const name = this.app.client.user?.name || deterministicUsername(address);
      const signature: string | null = signMessage(source);
      const r = this.result;
      const run = r
        ? {
            // English on the picture, whatever the screen is in: see `tEn`.
            outcome: EN_OUTCOME[r.outcome] ?? r.outcome,
            ok: r.outcome === "ok",
            compileError: r.outcome === "compile_error",
            timings: tEn("pg.timings", {
              compile: r.compile_ms,
              run: r.run_ms,
              exit: r.exit_code === null ? "" : tEn("pg.exit", { code: r.exit_code }),
            }),
            lines: this.log.lines,
          }
        : null;
      const at = new Date();
      const { makePoster, posterBytes, posterJpeg, posterFileName, savePoster } =
        await import("../ui/poster");
      const { canvas } = await makePoster({
        lang: this.held.lang,
        name: this.heldName(),
        file: MAIN_FILE[this.held.lang],
        source,
        run,
        user: { name, address },
        signature,
        at,
        words: {
          sideA: tEn("poster.sideA"),
          sideB: tEn("poster.sideB"),
          nothingRun: tEn("pg.nothingRun"),
          more: (n) => tEn("poster.more", { n }),
          by: tEn("poster.by"),
          unsigned: tEn("poster.unsigned"),
          how: tEn("poster.how"),
          hashed: tEn("poster.hashed"),
        },
        assets: this.app.assets,
      });
      const file = posterFileName(this.heldName(), at);
      // The proof, in the file: what was signed, by whom, and how — so the
      // picture can be checked without retyping 130 hex digits off it.
      const meta: Record<string, string> = {
        Title: this.heldName(),
        Author: name,
        Software: "Causewaybay Hacker",
        Source: source,
        Lang: this.held.lang,
        Signer: address,
        Comment: signature
          ? "Signature is EIP-191 personal_sign over Source, by Signer (Cronos EVM / Ethereum address)."
          : "Unsigned: no key was unlocked when this poster was made.",
      };
      if (signature) meta.Signature = signature;
      // Checked before it is written: the signature against the address, the
      // chunks against the program, and the label decoded off the very pixels
      // that will be saved. A failure is said and nothing is saved.
      const png = await posterBytes(canvas, meta);
      const { proveDisk, decodeLabelFrom } = await import("../ui/diskreader");
      const failed = proveDisk(png, decodeLabelFrom(canvas), source, address, signature);
      if (failed) {
        this.saveNote = t("pg.posterCheckFailed", { what: failed });
        this.app.chip.fail();
        return;
      }
      // Both: the PNG is the one with the proof in the file, the JPEG is the
      // one a gallery or a chat wants. Same picture, same label.
      const how = await savePoster(
        [
          { bytes: png, name: file, type: "image/png" },
          {
            bytes: await posterJpeg(canvas),
            name: file.replace(/\.png$/, ".jpg"),
            type: "image/jpeg",
          },
        ],
        this.app.layout.isPhone(),
      );
      this.saveNote =
        how === "shared" ? t("pg.posterShared") : t("pg.posterSaved", { file: `${file} + .jpg` });
      this.app.chip.blip();
    } catch (e) {
      console.warn("poster:", e);
      this.saveNote = t("pg.posterFailed");
      this.app.chip.fail();
    } finally {
      this.postering = false;
    }
  }

  /**
   * DISK READER: a poster back into a pad, with a verdict.
   *
   * The picker is the browser's; what comes back goes through
   * `ui/diskreader.ts` — the file's own text chunks if it is our PNG, the QR
   * label off its pixels if not — and the signature is checked against the
   * address the picture names. The program is opened as a **new, unsaved
   * pad** in its own language, named after the poster, so reading a disk
   * never overwrites what was being written; the status line says whose it
   * is and whether that holds.
   */
  private async readDisk(file: File): Promise<void> {
    try {
      const { readDisk, labelOf } = await import("../ui/diskreader");
      const bytes = new Uint8Array(await file.arrayBuffer());
      const disk = await readDisk(bytes, () => labelOf(file));
      if (!disk) {
        this.saveNote = t("pg.diskNone");
        this.app.chip.fail();
        return;
      }
      const short = `${disk.address.slice(0, 6)}…${disk.address.slice(-4)}`;
      if (disk.verdict === "hashed") {
        this.saveNote = t("pg.diskHashed", { address: short });
        this.app.chip.fail();
        return;
      }
      // A new pad, so nothing of the open one is lost under the disk.
      this.fresh();
      // The poster's own title when the file kept one; else the file's name
      // with what `posterFileName` added taken off again, so a JPEG of
      // `scratch` comes back as `scratch`, not `cwbhacker-scratch-20260916-1055`.
      this.held.name =
        disk.title?.trim().slice(0, 48) ||
        file.name
          .replace(/\.[^.]+$/, "")
          .replace(/^cwbhacker-/, "")
          .replace(/-\d{8}-\d{4}$/, "")
          .slice(0, 48) ||
        SCRATCH;
      this.held.lang = disk.lang;
      this.land = disk.lang;
      this.held.source = disk.source;
      this.editor?.load(disk.lang, disk.source);
      this.dirty = true;
      this.dirtyFor = 0;
      this.writeLocal();
      this.saveNote =
        disk.verdict === "verified"
          ? t("pg.diskVerified", { address: short })
          : disk.verdict === "forged"
            ? t("pg.diskForged", { address: short })
            : t("pg.diskUnsigned", { address: short });
      if (disk.verdict === "forged") this.app.chip.fail();
      else this.app.chip.blip();
    } catch (e) {
      console.warn("disk reader:", e);
      this.saveNote = t("pg.diskFailed");
      this.app.chip.fail();
    }
  }

  /** The two size buttons, for the bench and for CODE alike. */
  private fontItems(): Array<{ id: string; label: string; dim?: boolean }> {
    return [
      { id: "fontdown", label: t("quest.fontDown"), dim: this.fontMul <= CODE_FONT_MIN + 0.001 },
      { id: "fontup", label: t("quest.fontUp"), dim: this.fontMul >= CODE_FONT_MAX - 0.001 },
      // Says the face it is **in**, like every other toggle on this screen.
      { id: "face", label: CODE_FACE_NAME[getCodeFace()] },
    ];
  }

  /** Open the field over the name, with the current one selected. */
  private startRename(): void {
    this.renaming = true;
    this.nameEl.value = this.held.id === null && this.held.name === SCRATCH ? "" : this.held.name;
    this.nameEl.placeholder = this.heldName();
    setTimeout(() => {
      this.nameEl.focus();
      // Selected whole, with the caret at the **start** rather than the end.
      // Typing replaces the lot, which is the common case; one press of Left
      // or Home collapses to the front to edit what is there, where `select()`
      // leaves the caret at the end and makes the front the far side of the
      // word. `"backward"` is what puts it there.
      this.nameEl.setSelectionRange(0, this.nameEl.value.length, "backward");
    }, 0);
  }

  async enter(): Promise<void> {
    this.offs.push(
      // §4.22, §4.23: the same pad open on the tablet and the laptop. A save
      // or a room change on the other one arrives here.
      this.app.client.on("playground.updated", (p) => this.remoteSaved(p.snippet)),
      this.app.client.on("playground.chat.updated", (p) =>
        this.coder?.roomUpdated(p.id, p.message ?? null, p.cleared === true),
      ),
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
    this.diskEl.remove();
    this.stopStamp();
    this.keyOverlay?.destroy();
    this.overlay?.destroy();
    this.fx?.destroy();
    this.fx = null;
    this.coder?.leave();
    this.coder = null;
    this.stdinOverlay?.destroy();
    this.nameOverlay?.destroy();
    this.searchOverlay?.destroy();
    this.editor?.destroy();
    this.app.chip.music("stop");
  }

  // -- the text ------------------------------------------------------------

  private mount(): void {
    this.land = this.held.lang;
    this.editor = new Editor(this.held.lang, this.held.source, () => this.touched());
    this.overlay = new Overlay(this.app.overlay, this.app.layout, this.editor.dom);
    // After the editor, so it is painted over it; before the other overlays,
    // which are fields a person clicks into and must stay on top of it.
    this.fx?.destroy();
    this.fx = new CodeFx(this.app.overlay, this.app.layout, this.app.assets, this.app.chip);
    this.fx.attach(this.editor);
    // The agent's layer goes over the effects, and its fields over that;
    // the bench's own fields come after and stay on top of everything.
    this.coder?.leave();
    this.coder = new Coder(this.app, {
      lang: () => this.held.lang,
      roomId: () => this.held.id,
      roomKey: () => String(this.padSerial),
      roomName: () => this.heldName(),
      ensureRoom: async () => {
        if (this.held.id) return this.held.id;
        // An untouched starter has nothing to autosave; the room is a reason.
        this.dirty = true;
        await this.save();
        return this.held.id;
      },
      run: async (_source, stdin) => {
        if (stdin !== undefined) {
          this.stdinEl.value = stdin;
          this.held.stdin = stdin;
        }
        const r = await this.run();
        if (!r) throw new Error(this.status || "the run did not come back");
        return r;
      },
      format: async () => {
        if (!this.editor) return { changed: false, problem: "no editor" };
        const res = await this.app.client.request("code.format", {
          lang: this.held.lang,
          source: this.editor.source,
        });
        if (res.problem) return { changed: false, problem: res.problem };
        if (res.changed) {
          this.editor.replaceAll(res.source);
          this.touched();
        }
        return { changed: res.changed };
      },
      touched: () => this.touched(),
      chip: this.app.chip,
      fx: () => this.fx,
    });
    this.coder.mount(this.editor);
    this.stdinOverlay = new Overlay(this.app.overlay, this.app.layout, this.stdinEl);
    this.nameOverlay = new Overlay(this.app.overlay, this.app.layout, this.nameEl);
    this.nameOverlay.hide();
    this.searchOverlay = new Overlay(this.app.overlay, this.app.layout, this.searchEl);
    this.searchOverlay.hide();
    this.keyOverlay = new Overlay(this.app.overlay, this.app.layout, this.keyEl);
    this.keyOverlay.hide();
    queueMicrotask(() => this.editor?.focus());
  }

  /** A keystroke: mirror it locally now, and start the autosave clock. */
  private touched(): void {
    this.held.source = this.editor?.source ?? this.held.source;
    this.dirty = true;
    this.dirtyFor = 0;
    this.writeLocal();
  }

  /**
   * Whose mirror this is. Empty until login, and a draft with no owner is one
   * that cannot be handed back safely — so the mirror simply does not run.
   */
  private localKey(): string | null {
    const address = this.app.addressLabel;
    return address ? LOCAL_KEY(address) : null;
  }

  private writeLocal(): void {
    const key = this.localKey();
    if (!key) return;
    try {
      sessionStorage.setItem(key, JSON.stringify({ ...this.held, dirty: this.dirty }));
    } catch {
      /* private browsing: the server copy is still the real one */
    }
  }

  private restoreLocal(): void {
    const key = this.localKey();
    if (!key) return;
    try {
      // The unowned, origin-wide key from before this, on the way past.
      localStorage.removeItem(LEGACY_LOCAL_KEY);
      const raw = sessionStorage.getItem(key);
      if (!raw) return;
      const v = JSON.parse(raw) as Partial<Held>;
      if (typeof v.source !== "string") return;
      this.padSerial++;
      this.held = {
        id: typeof v.id === "string" ? v.id : null,
        name: typeof v.name === "string" ? v.name : SCRATCH,
        lang: isLand(v.lang) ? v.lang : "rust",
        source: v.source,
        stdin: typeof v.stdin === "string" ? v.stdin : "",
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
      this.padSerial++;
      this.held = {
        id: res.snippet.id,
        name: res.snippet.name,
        lang: res.snippet.lang,
        source: res.snippet.source,
        stdin: res.snippet.stdin ?? "",
      };
      this.stdinEl.value = this.held.stdin;
      this.savedStdin = this.held.stdin;
      this.savedSource = res.snippet.source;
      this.savedLang = res.snippet.lang;
      this.savedName = res.snippet.name;
      this.savedStdin = res.snippet.stdin ?? this.held.stdin;
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
    // A rename is a change even when not one character of the program moved.
    // Without this, RENAME on a saved pad went no further than the screen it
    // was typed on: the early return took it for an autosave with nothing to
    // do, and the list — which is the server's answer — never heard about it.
    // Stdin belongs to the pad: a scratchpad has no test cases, so this is
    // the only input its program will ever get, and reopening the pad without
    // it hands back a program that cannot be run.
    this.held.stdin = this.stdinEl.value;
    const named = this.held.name !== SCRATCH;
    const renamed = named && this.held.name !== this.savedName;
    const refed = this.held.stdin !== this.savedStdin;
    if (
      (!this.dirty && !renamed && !refed) ||
      (source === this.savedSource && this.held.lang === this.savedLang && !renamed && !refed)
    ) {
      this.dirty = false;
      return;
    }
    this.saving = true;
    try {
      const res = await this.app.client.request("playground.save", {
        ...(this.held.id ? { id: this.held.id } : {}),
        // Only when it is a name somebody chose. `SCRATCH` is the placeholder
        // an unsaved pad wears, and sending it would make the server call the
        // first save SCRATCH instead of naming it after the day.
        ...(named ? { name: this.held.name } : {}),
        lang: this.held.lang,
        source,
        stdin: this.held.stdin,
      });
      this.held.id = res.snippet.id;
      this.held.name = res.snippet.name;
      this.savedSource = source;
      this.savedLang = this.held.lang;
      this.savedName = res.snippet.name;
      this.savedStdin = res.snippet.stdin ?? this.held.stdin;
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

  private async run(): Promise<PlaygroundRun | null> {
    if (this.stage !== "idle") return null;
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
    return this.result;
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

  /**
   * This pad was saved on another of this user's devices (§4.22).
   *
   * Taken when nothing here is unsaved: the text, the input, the name and
   * the language, exactly as a `playground.load` would set them, with the
   * caret kept where it was (`replaceAll` narrows the change). When there
   * is unsaved typing here it is only said, and the next save from here is
   * the one that wins — see `remoteSaveAction`.
   */
  private remoteSaved(snippet: Snippet): void {
    const action = remoteSaveAction(this.held.id, snippet.id, this.dirty);
    if (action === "ignore") {
      void this.refreshList();
      return;
    }
    const changed =
      snippet.source !== (this.editor?.source ?? this.held.source) ||
      (snippet.stdin ?? "") !== this.stdinEl.value ||
      snippet.name !== this.held.name ||
      snippet.lang !== this.held.lang;
    if (!changed) return;
    if (action === "apply") {
      if (snippet.lang !== this.held.lang) {
        this.held.lang = snippet.lang;
        this.land = snippet.lang;
        this.editor?.load(snippet.lang, snippet.source);
      } else {
        this.editor?.replaceAll(snippet.source);
      }
      this.held.source = snippet.source;
      this.held.name = snippet.name;
      this.held.stdin = snippet.stdin ?? "";
      this.stdinEl.value = this.held.stdin;
      this.savedSource = snippet.source;
      this.savedLang = snippet.lang;
      this.savedName = snippet.name;
      this.savedStdin = this.held.stdin;
      this.dirty = false;
      this.writeLocal();
      this.saveNote = t("pg.updatedElsewhere");
    } else {
      this.saveNote = t("pg.updatedElsewhereUnsaved");
    }
    void this.refreshList();
    // The effect: a burst over the editor and a chime, so a change that
    // arrived from nowhere visible is seen to arrive.
    const [x, y, w, h] = this.editorRect;
    if (w > 0) this.fx?.play(burstPlan(x + w / 2, y + Math.min(h / 2, 80), 36));
    this.app.chip.coin();
  }

  private fresh(): void {
    void this.save();
    this.padSerial++;
    this.held = {
      id: null,
      name: SCRATCH,
      lang: this.held.lang,
      source: STARTER[this.held.lang],
      stdin: "",
    };
    this.stdinEl.value = "";
    this.savedStdin = "";
    this.savedSource = "";
    this.savedName = "";
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
    // The last run described a file that no longer exists. Leaving it up put
    // `main.rs:1:9 — expected one of `!` or `::`` under a panel titled
    // `main.go`, which reads as the wrong compiler having been used rather
    // than as an old answer nobody cleared away.
    this.result = null;
    this.log = new LogBuffer("");
    this.status = "";
    this.outputScroll = 0;
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
      // The room went with the pad; what is held is a new unsaved pad now.
      this.padSerial++;
      this.held.id = null;
      this.saveNote = "deleted";
      void this.refreshList();
    } catch (e) {
      this.saveNote = e instanceof WireError ? playerText(e.payload.code) : t("pg.deleteFailed");
    }
  }

  // -- input ---------------------------------------------------------------

  key(name: string, ev: KeyboardEvent): void {
    // Ctrl/Cmd+Shift+A: the agent, from anywhere on the screen — CODE mode
    // with the panel up and the caret in its field.
    if (name === "a" && (ev.ctrlKey || ev.metaKey) && ev.shiftKey && this.coder) {
      this.focus = true;
      this.coder.panel.open = true;
      this.coder.key(name, ev);
      return;
    }
    if (this.coder?.key(name, ev)) return;
    if (name === "escape") {
      if (this.focus && this.coder?.open) {
        this.coder.panel.open = false;
        this.coder.panel.hideFields();
        return;
      }
      return void this.app.go(new LandsScene(this.app), "back");
    }
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

  agent() {
    return this.coder?.probe() ?? null;
  }

  controls(): Buttons[] {
    return this.coder
      ? [this.buttons, this.rows, this.coder.controls()]
      : [this.buttons, this.rows];
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    // The agent's panel first: it is drawn over the bench and its buttons
    // are its own.
    if (this.focus && this.coder?.pointer(x, y, phase)) return;
    if (phase === "move") {
      this.buttons.hovered = this.buttons.hit(x, y)?.id ?? null;
      this.rows.hovered = this.rows.hit(x, y)?.id ?? null;
      return;
    }
    if (phase !== "down") return;
    const hit = this.buttons.hit(x, y) ?? this.rows.hit(x, y);
    if (!hit) return;
    if (this.display(hit.id)) return;
    if (hit.id === "agent") {
      // From the bench: into CODE with the panel up. In CODE: a toggle.
      if (!this.focus) {
        this.focus = true;
        if (this.coder) this.coder.panel.open = true;
        this.app.chip.select();
      } else this.coder?.toggle();
      return;
    }
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
    if (hit.id === "poster") return void this.poster();
    if (hit.id === "reader") return void this.diskEl.click();
    if (hit.id === "undo" || hit.id === "redo") {
      // A button press takes the focus off the editor; give it back so the
      // next keystroke goes on typing where the step left the caret.
      const stepped = hit.id === "undo" ? this.editor?.undo() : this.editor?.redo();
      if (stepped) this.app.chip.blip();
      this.editor?.focus();
      return;
    }
    if (hit.id === "copycode") return void this.clip("code");
    if (hit.id === "pastecode") return void this.clip("paste");
    if (hit.id === "copyout") return void this.clip("out");
    if (hit.id === "copyin") return void this.clip("copyin");
    if (hit.id === "pastein") return void this.clip("in");
    if (hit.id === "face") {
      this.cycleFace();
      return;
    }
    if (hit.id === "fontdown" || hit.id === "fontup") {
      this.sizeFont(hit.id === "fontup" ? 0.1 : -0.1);
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
    this.fx?.frame(dt);
    this.coder?.syncRoom();
    this.coder?.update(dt);
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
    if (this.focus && this.coder?.wheel(dy, x, y)) return;
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
      this.coder?.draw();
      return;
    }
    // The panel is CODE mode's; its fields must not linger over the bench.
    this.coder?.panel.hideFields();
    header(g, this.app, t("pg.title", { name: this.heldName().toUpperCase() }));
    // Full-bleed, like the map and the quest screen and for their reason:
    // this is a screen somebody works on, and room to read beats room to
    // look. The 7 % inset was spending a twentieth of the window on either
    // side of a bench whose editor was already the thing running out of room.
    const f = frame(layout, 0.26, 0);
    const s = f.scale;
    this.buttons.reset();
    this.rows.reset();
    this.drawList(g, f.left, s, f.portrait);
    this.drawBench(g, f.right, s);
    this.buttons.draw(g, ensureFonts(s).button);
    footer(g, layout, t("pg.footer"));
    this.coder?.draw();
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

  /**
   * The saved snippets, and the one line that says what this screen is.
   *
   * `stacked` is the frame's own decision rather than the window's, and it
   * picks the face the panel reads in. Side by side this is a full-height
   * column and the body face is right. **Stacked it is a quarter of the
   * window** — and `small` there (30·s, so 40 virtual px at the scale a
   * 1080x1750 window asks for) drew the rule *larger than the panel's own
   * title bar*, which is `stationSm`. Two lines of rule and a row and a half
   * of pads were the whole panel.
   *
   * So the stacked panel drops to `stationSm`: the small chrome face the title
   * bar and the language tag on every row already use. That is one step, not
   * an arbitrary shrink — in a CJK language the floor arithmetic in `text.ts`
   * pins `small` to 30·s and `stationSm` to max(20·s, 24·s) = 24·s, so this is
   * the smallest size Korean is allowed to be drawn at and no smaller.
   * Everything measured off the face follows it down — the row height, the
   * search well, the centring — so the panel holds four pads where it held
   * one and a half.
   */
  private drawList(g: Ctx, rect: Rect, s: number, stacked: boolean): void {
    const fonts = ensureFonts(s);
    const body = stacked ? fonts.stationSm : fonts.small;
    const inner = titledPanel(g, rect, t("pg.scratchpads"), Theme.coin);
    let y = inner[1];
    const pad = Math.round(8 * s);

    // What the buttons at the foot of this panel will take, measured before
    // anything above them is drawn — in portrait this panel is a quarter of
    // the window and the blurb ran straight under them.
    const listItems = [
      { id: "new", label: t("pg.new") },
      { id: "rename", label: t("pg.rename") },
      ...(this.held.id ? [{ id: "delete", label: t("pg.delete") }] : []),
    ];
    const [, listBtnH] = btnBox(
      fonts.button,
      listItems.map((b) => b.label),
      0,
      fonts.button.size * 2,
      this.app.layout.minTouchH(),
    );
    const listGap = Math.round(6 * s);
    const listRows = rowsIn(
      fonts.button,
      listItems.map((b) => b.label),
      inner[2],
      this.app.layout.minTouchH(),
    );
    const listH = listRows * listBtnH + (listRows - 1) * listGap;
    const listTop = inner[1] + inner[3] - listH;

    // The rule, stated once, where it cannot be missed. It is the opposite of
    // the quest screen's rule and the player has to be told which one they are
    // standing on. It gives up its room to the search box first: by the time
    // there are pads to hunt through, the rule has been read.
    const finding = this.searchable();
    const findH = finding
      ? Math.max(this.app.layout.minTouchH(), body.height + Math.round(14 * s))
      : 0;
    const noteRoom = listTop - pad - (finding ? findH + pad : 0);
    // Clipped to its room rather than trusted to stop: a Hangul line inks
    // below the nominal line height it is measured by, so "does the next line
    // fit?" let half a row of glyphs through and the buttons were drawn
    // across the middle of them.
    const noteTop = y;
    const noteH = Math.max(0, noteRoom - pad - noteTop);
    g.fillStyle = css(Theme.cream, 0.7);
    const note = t("pg.notScored");
    clipped(g, inner[0], noteTop, inner[2], noteH, () => {
      // Laid out on the **taller** of the nominal line box and what these
      // lines actually ink. The body face is Latin-only, so a Hangul line is
      // served by a fallback whose ink is half again the height it was
      // measured by: stepping by the nominal box let a line in that did not
      // fit, and the clip then sliced its glyphs through the middle.
      const lines = wrap(body, note, inner[2]);
      const step = lines.reduce((n, l) => {
        const ink = inkBox(body, l);
        return Math.max(n, ink.asc + ink.desc);
      }, body.height);
      let ny = noteTop;
      for (const line of lines) {
        if (ny + step > noteTop + noteH) break;
        printf(g, body, line, inner[0], ny, inner[2], "left");
        ny += step;
      }
      y = ny;
    });
    y += pad;

    if (finding) {
      well(g, inner[0], y, inner[2], findH, [0.06, 0.05, 0.14, 0.98]);
      this.searchOverlay?.place([inner[0] + 4, y + 3, inner[2] - 8, findH - 6], body.size);
      y += findH + pad;
    } else {
      this.searchOverlay?.hide();
    }

    const rowH = Math.max(this.app.layout.minTouchH(), body.height + Math.round(14 * s));
    const room = listTop - pad - y;
    clipped(g, inner[0], y, inner[2], Math.max(0, room), () => {
      let ry = y;
      const shown = this.visibleSnippets();
      for (const snip of shown) {
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
        // One line, elided: a name that wraps is a row drawn over the next one.
        const nameW = inner[2] - Math.round(20 * s) - tagW;
        printf(
          g,
          body,
          elide(body, snip.name, nameW),
          inner[0] + Math.round(10 * s),
          ry + Math.round((rowH - body.height) / 2),
          nameW,
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
      if (shown.length === 0) {
        g.fillStyle = css(Theme.dim);
        printf(
          g,
          body,
          this.snippets.length === 0 ? t("pg.nothingSaved") : t("pg.noMatch"),
          inner[0],
          y + pad,
          inner[2],
          "center",
        );
      }
      if (this.saveNote) {
        // One line, on its own band: the note used to wrap upward over the
        // rows, and a saved poster's file name made four lines of it.
        const ny = y + room - body.height - Math.round(4 * s);
        fill(
          g,
          Theme.ink,
          inner[0],
          ny - Math.round(2 * s),
          inner[2],
          body.height + Math.round(6 * s),
          0.9,
        );
        g.fillStyle = css(Theme.coin, 0.85);
        printf(
          g,
          body,
          elide(body, this.saveNote, inner[2] - Math.round(8 * s)),
          inner[0] + Math.round(4 * s),
          ny,
          inner[2],
          "left",
        );
      }
    });

    // NEW, RENAME and whichever of DELETE applies, laid by the row helper so
    // three of them wrap in a narrow list panel instead of the third being
    // painted over the second's last letter.
    this.buttons.row(
      fonts.button,
      [inner[0], listTop, inner[2], listH],
      listItems,
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
   * it back.
   *
   * Translated, where the LÖVE client's are not. That client draws a glyph
   * on each chip — a screen, a rotating rectangle — so `AUTO` on it is a
   * state next to a picture of what the state is about. Here the word is on
   * its own, and a button reading `AUTO` over a code editor says nothing
   * about orientation to anybody: it was reported as a missing control on a
   * screen that already had it.
   */
  private displayItems(): Array<{ id: string; label: string; strong?: boolean }> {
    const choice = this.app.layout.choice;
    return [
      { id: "fullscreen", label: this.app.isFullscreen() ? t("pg.full") : t("pg.window") },
      {
        id: "orient",
        label:
          choice === null
            ? t("pg.orientAuto")
            : choice === "portrait"
              ? t("pg.orientPort")
              : t("pg.orientLand"),
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
    this.searchOverlay?.hide();
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
      { id: "agent", label: t("agent.button"), strong: this.coder?.open ?? false },
      // The editor's own history, as buttons — for a phone, where there is
      // no Ctrl+Z. Client-side only (see `Editor.canUndo`).
      { id: "undo", label: t("quest.undo"), dim: !this.editor?.canUndo },
      { id: "redo", label: t("quest.redo"), dim: !this.editor?.canRedo },
      { id: "save", label: this.dirty ? t("pg.saveDirty") : t("pg.save") },
      { id: "rename", label: t("pg.rename") },
      // In and out of the screen. Nothing on a canvas can be selected with a
      // mouse, so without these the code and the compiler's answer cannot
      // leave it at all — which is what somebody pasting into an assistant
      // and pasting the reply back needs.
      { id: "copycode", label: t("quest.copyCode") },
      { id: "pastecode", label: t("quest.paste") },
      {
        id: "copyout",
        label: t("quest.copyOutput"),
        dim: !this.result && this.log.lines.length === 0,
      },
      { id: "copyin", label: t("pg.copyIn"), dim: this.stdinEl.value === "" },
      { id: "pastein", label: t("pg.pasteIn") },
      // Out of the screen as a picture: the pad, its output and a signature,
      // for showing off. Dimmed while one is being made.
      { id: "poster", label: t("pg.poster"), dim: this.postering },
      // And back in: a poster's program, with its signature checked.
      { id: "reader", label: t("pg.reader") },
      ...this.fontItems(),
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
    // **One line, elided.** `printf` wraps, the strip reserves the height of a
    // single line, and a long note — `이 서버에는 아직 저장되지 않습니다…` — put
    // its second line over the top of the editor.
    const statusW = layout.vw - pad * 2 - Math.round(8 * s);
    const shown = elide(f, status, statusW);
    g.fillStyle = css(this.dirty ? Theme.coin : Theme.dim);
    printf(g, f, shown, pad + Math.round(8 * s), statusY, statusW, "left");
    if (this.renaming) {
      const h = Math.max(layout.minTouchH(), f.height + 12);
      this.nameOverlay?.place(
        [pad, statusY - Math.round(2 * s), Math.min(layout.vw - pad * 2, Math.round(260 * s)), h],
        f.size,
      );
    } else {
      this.nameOverlay?.hide();
    }
    // The key field takes the same slot: wider, because a phrase is twelve
    // words, and never at the same time as the name.
    if (this.stamping) {
      const h = Math.max(layout.minTouchH(), f.height + 12);
      this.keyOverlay?.place(
        [pad, statusY - Math.round(2 * s), Math.min(layout.vw - pad * 2, Math.round(520 * s)), h],
        f.size,
      );
    } else {
      this.keyOverlay?.hide();
    }

    // Output only once there is any: a scratchpad whose whole purpose is to
    // run things must not hide what they printed, and an empty panel would
    // be spending the room this mode exists to hand to the editor.
    // **Beside the code when the window is wide, under it when it is tall.**
    //
    // A landscape window has width to spare and height to spare nothing: an
    // output pane stacked under the editor there takes a quarter of the few
    // lines the screen has, to show four lines of its own. Held upright it is
    // the other way round — the width is the scarce half, and a column of
    // output beside the code would be too narrow to read a compiler error in.
    // **Input and output keep each other company, across the short axis.**
    //
    // Wide window: the output is a column beside the code, and stdin sits at
    // the top of that same column — stacked with it, so the editor keeps its
    // width. Tall window: the output is a band under the code, and stdin
    // takes the left of that band — beside it, so the editor keeps its
    // height. Either way the pair costs the editor one dimension, not two.
    //
    // With nothing run yet there is no column or band to join, so stdin is a
    // line of its own above the editor: it is never hidden, because it is the
    // only way a program that reads is fed at all.
    const fedH = Math.max(layout.minTouchH(), fonts.codeSm.height + Math.round(10 * s));
    const hasOut = this.log.lines.length > 0 || this.result !== null;
    const wide = !layout.isPortrait();
    const gap = Math.round(5 * s);
    const bodyW = layout.vw - pad * 2;

    const fedLabel = t("pg.stdin");
    const labelW = Math.round(width(f, fedLabel) + 12 * s);
    // `h` because the box is not always one line: set beside the output it
    // matches the output's height, so the pair reads as one band rather than
    // as a full panel with a sliver next to it. The label sits on the first
    // line either way.
    const fed = (x: number, y: number, w: number, h = fedH) => {
      well(g, x, y, w, h, [0.06, 0.05, 0.14, 0.98]);
      g.fillStyle = css(Theme.dim);
      // **The label goes over the field when there is a field to go over.**
      // Beside it, `표준 입력` is two thirds of a narrow box's width and the
      // input is typed into the third that is left. On a single line there is
      // no room above, so there it stays alongside.
      const stacked = h >= fedH * 1.6;
      if (stacked) {
        printf(g, f, fedLabel, x + Math.round(6 * s), y + Math.round(3 * s), w, "left");
        const lh = f.height + Math.round(5 * s);
        this.stdinOverlay?.place([x + 4, y + lh, w - 8, h - lh - 4], fonts.codeSm.size);
      } else {
        printf(
          g,
          f,
          fedLabel,
          x + Math.round(6 * s),
          inkCentreY(f, fedLabel, y, fedH),
          labelW,
          "left",
        );
        this.stdinOverlay?.place([x + labelW, y + 3, w - labelW - 6, h - 6], fonts.codeSm.size);
      }
    };

    let top = strip + Math.round(6 * s);
    const agentOpen = this.coder?.open ?? false;
    if (!hasOut && !agentOpen) {
      fed(pad, top, bodyW);
      top += fedH + gap;
    }
    const bodyH = layout.vh - top - pad;
    let editorW = bodyW;
    let editorH = bodyH;
    let panel: Rect | null = null;
    // **The editor keeps the larger part, whatever else is up.** Three
    // things can share the window with it: the agent's panel, the input, and
    // the output. Wide, the editor is the left column and the other three
    // share the right one, the panel above the run. Tall, the editor is the
    // top and the others share the band under it, the panel to the left
    // of the run. Either way the editor gives up one dimension, once, and
    // the input travels with the output rather than taking a row of its own.
    if (agentOpen && wide) {
      const colW = Math.max(Math.round(260 * s), Math.round(bodyW * 0.42));
      editorW = bodyW - colW - pad;
      const x = pad + editorW + pad;
      if (hasOut) {
        const runH = Math.max(fedH * 2 + gap, Math.round(bodyH * 0.38));
        panel = [x, top, colW, bodyH - runH - gap];
        const y = top + bodyH - runH;
        const inH = Math.max(fedH, Math.round(runH * 0.3));
        fed(x, y, colW, inH);
        this.drawOutput(g, [x, y + inH + gap, colW, runH - inH - gap], s);
      } else {
        const inH = fedH;
        fed(x, top, colW, inH);
        panel = [x, top + inH + gap, colW, bodyH - inH - gap];
        this.outputRect = [0, 0, 0, 0];
      }
    } else if (agentOpen) {
      const bandH = Math.round(bodyH * (hasOut ? 0.5 : 0.44));
      editorH = bodyH - bandH - pad;
      const y = top + editorH + pad;
      if (hasOut) {
        const panelW = Math.round(bodyW * 0.55);
        panel = [pad, y, panelW, bandH];
        const rx = pad + panelW + pad;
        const rw = bodyW - panelW - pad;
        const inH = Math.max(fedH, Math.round(bandH * 0.3));
        fed(rx, y, rw, inH);
        this.drawOutput(g, [rx, y + inH + gap, rw, bandH - inH - gap], s);
      } else {
        fed(pad, y, bodyW);
        panel = [pad, y + fedH + gap, bodyW, bandH - fedH - gap];
        this.outputRect = [0, 0, 0, 0];
      }
    } else if (hasOut && wide) {
      const outW = Math.round(bodyW * 0.38);
      editorW = bodyW - outW - pad;
      const x = pad + editorW + pad;
      // A share of the column rather than a single line: input is usually
      // several lines — a count and then the numbers — and a box that shows
      // one of them is a box you cannot check what you typed in.
      const inH = Math.max(fedH, Math.round(bodyH * 0.26));
      fed(x, top, outW, inH);
      this.drawOutput(g, [x, top + inH + gap, outW, bodyH - inH - gap], s);
    } else if (hasOut) {
      const bandH = Math.max(fedH, Math.round(bodyH * 0.28));
      editorH = bodyH - bandH - pad;
      const y = top + editorH + pad;
      const inW = Math.round(bodyW * 0.4);
      fed(pad, y, inW, bandH);
      this.drawOutput(g, [pad + inW + pad, y, bodyW - inW - pad, bandH], s);
    } else {
      this.outputRect = [0, 0, 0, 0];
    }
    well(g, pad, top, editorW, editorH);
    const editorRect: Rect = [pad + 4, top + 4, editorW - 8, editorH - 8];
    this.editorRect = editorRect;
    if (this.editor) this.overlay?.place(editorRect, fonts.codeSm.size * this.fontMul);
    else this.overlay?.hide();
    this.coder?.fly([0, 0, layout.vw, layout.vh]);
    if (panel) this.coder?.drawPanel(g, panel, s);
    else this.coder?.panel.hideFields();
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
    if (this.stamping) {
      const h = Math.max(layout.minTouchH(), fonts.button.height + 12);
      this.keyOverlay?.place([rect[0] + 8, rect[1] + 4, rect[2] - 16, h], fonts.button.size);
    } else {
      this.keyOverlay?.hide();
    }

    const btnH = Math.max(layout.minTouchH(), fonts.button.height + 20);
    const gap = Math.round(8 * s);
    const stdinH = Math.max(Math.round(46 * s), fonts.codeSm.height * 2 + Math.round(16 * s));
    // A share of the panel, but never more of it than there is output to
    // read: eight lines and the timing line under them. Past that the pane
    // is reserving room for blank space, and the room comes straight out of
    // the editor — on a desktop the bench is large enough that 28 % of it
    // was a tall empty box under a program whose last brace was cut off.
    const outH = Math.min(
      Math.round(inner[3] * (layout.isPortrait() ? 0.3 : 0.28)),
      fonts.codeSm.height * 8 + fonts.stationSm.height + Math.round(16 * s),
    );
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
    // **Wrapped, not run off the edge.** The four were laid in one run from
    // the panel's right edge and simply kept going left; in Korean, where
    // the labels are wider, RUST ended up outside the bench entirely — drawn
    // past the left edge of a phone screen, unreachable. Lay them into as
    // many rows as they need.
    const langLines: Array<typeof langBoxes> = [];
    {
      let line: typeof langBoxes = [];
      let used = 0;
      for (const box of langBoxes) {
        const add = box.bw + (line.length ? langGap : 0);
        if (line.length && used + add > inner[2]) {
          langLines.push(line);
          line = [];
          used = 0;
        }
        line.push(box);
        used += box.bw + (line.length > 1 ? langGap : 0);
      }
      if (line.length) langLines.push(line);
    }
    const langRowsH = langLines.length * langH + (langLines.length - 1) * langGap;
    const minOut = fonts.codeSm.height * 3 + Math.round(10 * s);
    // Its label and one whole line of what you typed. Anything less is a box
    // that says STDIN over a sliver of a character, which is how it looked
    // when the editor was allowed to take the last of it.
    const minStdin = fonts.stationSm.height + fonts.codeSm.height + Math.round(12 * s);
    // **The band gives way before the editor does.**
    //
    // Eleven touch-sized buttons — four lands, four actions, CODE and the two
    // display toggles — is five rows on a phone held upright, and five rows
    // is most of the panel. Served in that order the editor came out at its
    // 60-pixel floor: one line of code, which is the screen that was
    // reported. So the optional ones are dropped from the *framed* bench
    // until the editor has its share, last-listed first. Nothing is lost:
    // CODE carries the display toggles and is one tap away, and ESC is MAPS.
    const core = [
      {
        id: "run",
        label: this.stage === "idle" ? t("pg.run") : "…",
        dim: this.stage !== "idle",
        primary: this.stage === "idle",
      },
      { id: "format", label: t("pg.format"), dim: this.formatting },
      { id: "save", label: this.dirty ? t("pg.saveDirty") : t("pg.save") },
      // The way out of the crowding, on the screen that is crowded. Never
      // dropped: on a phone it is the only way the editor gets the window.
      { id: "code", label: t("pg.code") },
      // Never dropped either. Text somebody cannot read is the one fault a
      // narrower screen must not be allowed to introduce, and these two are
      // the narrowest buttons on the row.
      ...this.fontItems(),
    ];
    const optional = [
      { id: "agent", label: t("agent.button") },
      { id: "poster", label: t("pg.poster"), dim: this.postering },
      { id: "reader", label: t("pg.reader") },
      ...this.displayItems(),
      { id: "back", label: t("pg.maps") },
    ];
    // Five code lines. Below that the editor is a label rather than a place
    // to write, and the bench is better off one button shorter.
    const editorFloor = fonts.codeSm.height * 5 + Math.round(12 * s);
    let actions = [...core, ...optional];
    const bandFor = (items: typeof actions) => {
      const ls = items.map((a) => a.label);
      const besideW0 = inner[2] - langsW - langGap * 2;
      const side = besideW0 > 0 && rowsIn(fonts.button, ls, besideW0, layout.minTouchH()) === 1;
      const w = side ? besideW0 : inner[2];
      const r = rowsIn(fonts.button, ls, w, layout.minTouchH());
      const g0 = Math.round(fonts.button.size * 0.5);
      return r * btnH + (r - 1) * g0 + (side ? 0 : langRowsH + g0);
    };
    for (let drop = 0; drop < optional.length; drop++) {
      const room = inner[3] - bandFor(actions) - minStdin - minOut - gap * 3;
      if (room >= editorFloor) break;
      actions = [...core, ...optional.slice(0, optional.length - 1 - drop)];
    }
    const labels = actions.map((a) => a.label);
    // Beside the actions only when *all* of them still fit on one row next to
    // the four lands — not merely when RUN does. The old test asked about one
    // label and answered for the whole band, so in landscape, where the bench
    // is the narrow half of the frame, the lands took the width and the
    // actions came back seven rows of one button each: 380 pixels of buttons
    // over a panel 476 tall, and an editor at its 60-pixel floor. That is the
    // screen that was reported as very hard to use.
    const besideW = inner[2] - langsW - langGap * 2;
    const beside = besideW > 0 && rowsIn(fonts.button, labels, besideW, layout.minTouchH()) === 1;
    const rowW = beside ? besideW : inner[2];
    const rows = rowsIn(fonts.button, labels, rowW, layout.minTouchH());
    const rowGap = Math.round(fonts.button.size * 0.5);
    const langBand = beside ? 0 : langRowsH + rowGap;
    const bandH = rows * btnH + (rows - 1) * rowGap + langBand;

    // **The editor is served first.** It used to be served last — whatever a
    // fixed stdin box, a percentage-of-panel output panel and however many
    // rows of buttons happened to leave — which is an editor that vanishes
    // exactly when the screen gets tight. It now claims a share of the panel
    // and the shortfall comes out of the output first, because the output
    // scrolls and the thing being typed into does not.
    const wantEditor = Math.round(inner[3] * (layout.isPortrait() ? 0.34 : 0.36));
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
    this.editorRect = editorRect;
    if (this.editor && this.benchIn.finished) {
      this.overlay?.place(editorRect, fonts.codeSm.size * this.fontMul);
    } else this.overlay?.hide();
    this.coder?.fly([0, 0, layout.vw, layout.vh]);

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
    const langTop = beside ? rowY + Math.round((btnH - langH) / 2) : rowY - langBand;
    langLines.forEach((line, li) => {
      const langY = langTop + li * (langH + langGap);
      let bx = inner[0] + inner[2];
      for (const { land: id, label, bw } of [...line].reverse()) {
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
            inkCentreY(fonts.button, label, langY + 8, langH - BTN_FRAME),
            bw,
            "center",
          );
        } else {
          pixBtn(g, fonts.button, bx, langY, bw, langH, label, { hover, quiet: true });
        }
        // Painted here, in the land's own colour when it is the live one, so
        // the row says which compiler will run this file. `painted` keeps
        // `Buttons.draw` from putting a plain button over the top of it.
        this.buttons.add({ id, rect: [bx, langY, bw, langH], label, painted: true });
        bx -= langGap;
      }
    });

    // The actions start at `rowY` and are `bandH - langBand` tall — the land
    // band sits *above* `rowY`, and `rowY` already stepped over it. Adding the
    // whole of `bandH` here counted that band twice and pushed the output
    // panel off the bottom of the bench by exactly its height.
    const outTop = rowY + (bandH - langBand) + gap;
    this.drawOutput(g, [inner[0], outTop, inner[2], Math.max(24, inner[1] + inner[3] - outTop)], s);
  }

  /** What the program printed, and what the compiler thought of it. */
  private drawOutput(g: Ctx, rect: Rect, s: number): void {
    const [x, y, w, h] = rect;
    const fonts = ensureFonts(s);
    const pad = Math.round(6 * s);
    // A plate under the whole panel, header included. The well below covers
    // only the log, so in CODE — where this sits straight on a photograph of
    // a room rather than inside a framed panel — the outcome and the timings
    // were read against a lit window. The LÖVE client has always drawn its
    // whole rect as a well and this is that, in the browser's terms.
    fill(g, Theme.ink, x, y, w, h, 0.78);
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
      const timings = t("pg.timings", { compile: r.compile_ms, run: r.run_ms, exit });
      // **Only on the same line when both fit on it.** The outcome is drawn
      // left and the timings right against the same baseline, which is one
      // line as long as the panel is wide. Beside the code it is not, and
      // `실행됐습니다` and `컴파일 970 ms …` were printed through each other.
      const together =
        width(fonts.stationSm, OUTCOME[r.outcome]()) + width(fonts.stationSm, timings) + pad * 3 <=
        w;
      if (!together) ty += fonts.stationSm.height + Math.round(2 * s);
      printf(
        g,
        fonts.stationSm,
        timings,
        together ? x : x + pad,
        ty + Math.round(3 * s),
        w - pad,
        together ? "right" : "left",
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
    const textW = w - pad * 4;
    // **Visual lines, not source lines.** Everything below is wrapped to the
    // panel's width *before* it is counted, so `room`, the scroll and the
    // overflow all speak of the lines that are drawn. `printf` wraps on its
    // own, but a loop that advanced one line height per entry then printed
    // the second visual line of a long diagnostic through the entry under
    // it — `ok` through `variable: \`rx\`` — which is what this used to do.
    const out: Array<[string, readonly [number, number, number, number]]> = [];
    const push = (text: string, col: readonly [number, number, number, number]) => {
      for (const line of wrap(fonts.codeSm, text, textW)) out.push([line, col]);
    };
    // A heading over each block, as the LÖVE client has always drawn them:
    // what the program wrote, what it wrote to stderr, and what the compiler
    // said, in that order — the program's own output is what RUN was pressed
    // for, and a page of warnings above it buried a one-line answer.
    const block = (
      label: string,
      lines: string[],
      col: readonly [number, number, number, number],
    ) => {
      if (lines.length === 0) return;
      if (out.length > 0) out.push(["", Theme.dim]);
      out.push([label, Theme.dim]);
      for (const line of lines) push(line, col);
    };
    if (r) {
      const nonEmpty = (s: string) => s.split("\n").filter((l) => l !== "");
      block(t("pg.outStdout"), nonEmpty(r.stdout), Theme.cream);
      block(t("pg.outStderr"), nonEmpty(r.stderr), Theme.red);
      block(
        t("pg.outCompiler"),
        r.diagnostics.map((d) => {
          const where = d.line === null ? "" : ` (${d.line}${d.col === null ? "" : ":" + d.col})`;
          return `${d.kind}${d.code ? " " + d.code : ""}${where}  ${d.message}`;
        }),
        Theme.pink,
      );
    }
    // While it is still running, the compiler's own chatter is the progress bar.
    if (!r)
      for (const l of this.log.lines) push(l.text, l.stream === "stderr" ? Theme.red : Theme.dim);
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
        // Already one visual line each (see `push`), so the limit here is a
        // guard and never wraps.
        printf(g, fonts.codeSm, text, x + pad * 2, ly, textW, "left");
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
