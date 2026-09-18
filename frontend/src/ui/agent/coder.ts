/**
 * The Rust coder: one object per code screen that owns the whole agent.
 *
 * The sprite and its bubble (`sprite.ts`, drawn here on `layer.ts`), the
 * tips and the local advice (`ai/tips.ts`), the model session and its tools
 * (`ai/session.ts`, `ai/tools.ts`), the typist (`ai/typist.ts`), the room on
 * the server (`playground.chat.*`) and the panel (`panel.ts`). The screen
 * that owns the editor mounts it, ticks it, gives it a rectangle to fly in
 * and, when the panel is open, a rectangle to draw the panel in, and passes
 * it the pointer, wheel and keys first.
 *
 * The one rule (docs/agent.md §1): **nothing here calls a model unless a
 * person pressed something**, with AUTO the single, opt-in exception, and
 * that one is throttled hard.
 */
import type { App } from "../../app";
import type { Land } from "../../net/protocol";
import type { ChatMessage } from "../../net/protocol";
import { WireError } from "../../net/client";
import { ensureFonts, printf, wrap, width } from "../../engine/text";
import { css, Theme, type RGBA } from "../../engine/theme";
import { fill, type Ctx, type Rect } from "../../engine/ui";
import { reducedMotion } from "../../engine/motion";
import { t } from "../../i18n";
import { Editor, MAIN_FILE } from "../editor";
import { Buttons } from "../chrome";
import {
  PROVIDER_BOT,
  PROVIDER_NAME,
  readAuto,
  readKey,
  needsKey,
  readModel,
  readProvider,
  readShown,
} from "../../ai/prefs";
import { Session, type Listener, type Mood } from "../../ai/session";
import { Typist } from "../../ai/typist";
import { advise, nextTip, TIPS } from "../../ai/tips";
import type { Bench, RunReport } from "../../ai/tools";
import { image as makeImage } from "../../ai/providers";
import { burstPlan, coinPlan, pointerPlan } from "../../engine/burst";
import type { CodeFx } from "../codefx";
import type { AgentProbe } from "../../app";
import { Sprite, type Pt } from "./sprite";
import { AgentLayer } from "./layer";
import { Panel, type Item } from "./panel";
import { emptyRoom, fold, type Room, roomMove, type PadRef } from "./sync";

/** What the screen lends the agent. */
export interface Host {
  lang(): Land;
  /** The pad the room belongs to; null on a screen with no room (a quest). */
  roomId(): string | null;
  /**
   * Changes with every pad the screen moves to, saved or not — what tells a
   * NEW pad from the unsaved one before it, which `roomId` (null for both)
   * cannot. See `sync.roomMove`.
   */
  roomKey(): string;
  /**
   * Make the room exist: a fresh pad has no id until its first save, and the
   * first thing said on it must not be lost for that. Resolves to the id,
   * or null on a screen that has no rooms.
   */
  ensureRoom(): Promise<string | null>;
  /** The pad's name, for the line that says it now exists. */
  roomName(): string;
  /** RUN as the button does, or null where a run would count against the player. */
  run: ((source: string, stdin?: string) => Promise<RunReport>) | null;
  format: (() => Promise<{ changed: boolean; problem?: string }>) | null;
  /** The editor's text changed under the agent's hands: autosave, mirror. */
  touched(): void;
  /** A small sound. */
  chip: { blip(): void; fail(): void; coin(): void; select(): void; type(): void };
  /**
   * The screen's particle layer (`ui/codefx.ts`, three.js under WebGL), for
   * the coder's own effects: its exhaust, and a burst when it starts or
   * lands a program. Null when the screen has none yet.
   */
  fx(): CodeFx | null;
}

/** Seconds between the coder's own remarks while nobody is typing. */
const TIP_EVERY: [number, number] = [14, 26];
/** Idle seconds after a change before the text is read for advice. */
const ADVISE_AFTER = 4;
/** AUTO: idle seconds before a review may fire, and the floor between two. */
const AUTO_IDLE = 25;
const AUTO_EVERY = 180;
/** AUTO: how much the text must have changed since the last review, in characters. */
const AUTO_DELTA = 40;
/** How long a bubble stays, plus a share per character. */
const BUBBLE_BASE = 4.5;
const BUBBLE_PER_CHAR = 0.045;
/** The sprite's drawn size as a share of the shorter side of its box. */
const SIZE_SHARE = 0.22;
const SIZE_MIN = 40;
const SIZE_MAX = 84;
/** The room's cap on a photo's base64, under the frame's 4 MiB. */
const PHOTO_B64_MAX = 2_800_000;

export class Coder {
  private editor: Editor | null = null;
  private layer: AgentLayer | null = null;
  private readonly sprite = new Sprite(64, reducedMotion);
  readonly panel: Panel;
  private session: Session | null = null;
  private readonly typist = new Typist();
  /** Where the sprite may fly, set by the screen each frame. */
  private box: Rect = [0, 0, 100, 100];
  private cellV = 8;
  private t = 0;
  private sinceTip = 0;
  private nextTipAt = TIP_EVERY[0];
  private lastTip = -1;
  private sinceChange = 999;
  private advised = false;
  private readonly said = new Set<string>();
  private lastSource = "";
  private reviewedSource = "";
  private sinceCall = AUTO_EVERY;
  private mood: Mood = "idle";
  private moodSince = 0;
  /** Time banked towards the next exhaust ember, in seconds. */
  private exhaust = 0;
  /** Distance banked towards the next light along a flight, in virtual px. */
  private wakeCarry = 0;
  private wakeLast: Pt | null = null;
  /** Shockwave rings, born at a moment and a place, for a landed program. */
  private rings: Array<{ x: number; y: number; at: number }> = [];
  /** The bubble: what, and until when. */
  private bubble: { text: string; until: number; tone: "say" | "tip" | "busy" } | null = null;
  /** How present the sprite is, 0..1: eased in when agent mode opens, out when it closes. */
  private presence = 0;
  private wasActive = false;
  /** When the pointer last moved, on the coder's clock, for the calm. */
  private pointerAt = -Infinity;
  /** The last thing said, for a press that comes after the bubble has gone. */
  private lastSaid: { text: string; tone: "say" | "tip" } | null = null;
  private room: string | null = null;
  /** The pad as last seen, for `roomMove`. */
  private pad: PadRef | null = null;
  /** The room as the server has it, folded by id, with the sync cursor. */
  private held: Room = emptyRoom();
  /** The reply being streamed, as one growing item. */
  private live: Item | null = null;
  private offs: Array<() => void> = [];

  constructor(
    private readonly app: App,
    private readonly host: Host,
  ) {
    this.panel = new Panel(app, {
      send: (text) => void this.send(text),
      write: (brief) => void this.write(brief),
      review: () => void this.review(),
      image: (brief) => void this.picture(brief),
      stop: () => this.stop(),
      clear: () => void this.clearRoom(),
      edit: (id, text) => void this.editMessage(id, text),
      delete: (id) => void this.deleteMessage(id),
      note: (text) => this.say(text, "say"),
    });
  }

  // -- lifecycle -------------------------------------------------------------

  /** After the screen has made its editor. Safe to call again with a new one. */
  mount(editor: Editor): void {
    this.editor = editor;
    this.layer?.destroy();
    this.layer = new AgentLayer(this.app.overlay, this.app.layout);
    this.panel.mount();
    this.lastSource = editor.source;
    this.session = new Session(this.bench(), this.listener());
    this.syncRoom();
    // A press on the sprite, wherever it is. Its canvas takes no pointer
    // events — it flies over the editor, which does — so the press is
    // caught on the way down, before whatever is under the sprite sees it.
    const down = (ev: PointerEvent) => {
      if (ev.button !== 0 || !readShown()) return;
      const v = this.app.layout.toVirtual(ev.clientX, ev.clientY);
      if (v && this.hits(v[0], v[1])) {
        ev.preventDefault();
        ev.stopPropagation();
        this.press();
      } else if (this.sprite.holding) {
        // A touch anywhere else lets it go; that touch is still whoever's it was.
        this.release();
      }
    };
    addEventListener("pointerdown", down, true);
    this.offs.push(() => removeEventListener("pointerdown", down, true));
    // A moving mouse slows the wander, so the sprite can be caught. A finger
    // does not move between taps, so touch is left out.
    const move = (ev: PointerEvent) => {
      if (ev.pointerType === "mouse") this.pointerAt = this.t;
    };
    addEventListener("pointermove", move, { capture: true, passive: true });
    this.offs.push(() => removeEventListener("pointermove", move, true));
  }

  /**
   * Agent mode: the sprite lives only while the panel is open. Off, it
   * fades out and stops; on, it arrives huge and shrinks to size.
   */
  get active(): boolean {
    return readShown() && this.panel.open;
  }

  /** Whether a virtual point is on the sprite. */
  hits(x: number, y: number): boolean {
    if (this.presence < 0.5) return false;
    const half = this.sprite.size * this.sprite.scale * 0.55;
    return (
      Math.abs(x - this.sprite.x) <= half && Math.abs(y - this.sprite.y - this.sprite.bob()) <= half
    );
  }

  /**
   * Touched: an idle sprite stops where it is so its bubble can be read,
   * and shows the last thing it said if the bubble has already gone. It
   * stays until a touch somewhere else. One at work is not interrupted.
   */
  press(): void {
    if (this.sprite.holding) return;
    if (!this.sprite.hold(true, this.box)) return;
    this.host.chip.select();
    if (!this.bubble) {
      if (this.lastSaid) this.say(this.lastSaid.text, this.lastSaid.tone);
      else this.say(t("agent.held"), "say");
    }
  }

  /** Touched elsewhere: off it flies, the bubble given a moment more. */
  release(): void {
    if (!this.sprite.holding) return;
    this.sprite.hold(false);
    if (this.bubble) this.bubble.until = Math.max(this.bubble.until, this.t + 2.5);
  }

  leave(): void {
    this.stop();
    this.layer?.destroy();
    this.layer = null;
    this.panel.leave();
    for (const off of this.offs) off();
    this.offs = [];
    this.editor = null;
    this.session = null;
  }

  get open(): boolean {
    return this.panel.open;
  }

  toggle(): void {
    this.panel.open = !this.panel.open;
    if (this.panel.open) {
      this.syncRoom();
      // Opening a room already held: ask for what came after the cursor —
      // another tab, the other client — and nothing that is already here.
      if (this.room && this.held.cursor > 0) void this.refreshRoom(this.room);
    }
    this.host.chip.select();
  }

  /** The pad changed, or a new one was opened: a different room. */
  syncRoom(): void {
    const to: PadRef = { key: this.host.roomKey(), id: this.host.roomId() };
    const move = roomMove(this.pad, to);
    if (move === "same") return;
    this.pad = to;
    const id = to.id;
    this.room = id;
    this.held = emptyRoom();
    // A fresh pad has no room until its first save, and the first thing
    // said on it is usually said before that. The pad getting its id is not
    // a different room, it is this room arriving: keep the conversation and
    // post what was said so far, in order, so the room starts complete.
    if (move === "arriving" && id && this.panel.items.length > 0) {
      const pending = this.panel.items.filter(
        (i) => i.id === undefined && (i.role === "user" || i.role === "agent") && !i.live,
      );
      void (async () => {
        for (const item of pending) {
          const m = await this.post(item.role as "user" | "agent", item.text);
          if (m) Object.assign(item, itemOf(m));
        }
      })();
      return;
    }
    this.session?.clear();
    this.panel.items = [];
    this.said.clear();
    this.reviewedSource = "";
    if (id) void this.loadRoom(id);
  }

  /**
   * The room changed on another of this user's connections (§4.23): one row
   * as the server recorded it — a post, an edit, a tombstone — or the room
   * cleared. Folded by id like a page of the list; nothing is asked back.
   */
  roomUpdated(id: string, message: ChatMessage | null, cleared: boolean): void {
    if (id !== this.room) return;
    if (cleared) {
      this.held = emptyRoom();
      this.panel.items = [];
      this.said.clear();
      this.session?.clear();
    } else if (message) {
      this.apply([message]);
    } else {
      return;
    }
    this.panel.status = t("agent.roomUpdated");
    this.host.chip.blip();
  }

  private async loadRoom(id: string): Promise<void> {
    try {
      const res = await this.app.client.request("playground.chat.list", { id, limit: 200 });
      if (this.room !== id) return;
      // Merged, not replaced: a message sent while this was in flight is
      // already on the screen, and it must keep its place.
      this.held = emptyRoom();
      this.apply(res.messages);
      this.panel.scroll = 0;
    } catch (e) {
      if (e instanceof WireError && e.payload.code === "not_found") {
        // A server without the room, or a pad it has not seen: the visit's
        // messages stay in the tab, and the panel says so once.
        this.panel.status = t("agent.roomFailed");
      }
    }
  }

  /**
   * What came after the cursor, folded in. Only messages this tab has not
   * seen are shown; the ones it posted itself came back with their ids.
   */
  private async refreshRoom(id: string): Promise<void> {
    try {
      const res = await this.app.client.request("playground.chat.list", {
        id,
        limit: 200,
        after: this.held.cursor,
      });
      if (this.room !== id) return;
      this.apply(res.messages);
    } catch {
      /* the room as held is still right; the next open asks again */
    }
  }

  /**
   * Fold a page into the room and show the difference: a message this tab
   * has not seen is appended, an edit replaces the text in place, a
   * tombstone takes the line away. The tab's own lines — tool notes, tips,
   * a reply still streaming — have no id and are left where they are.
   */
  private apply(page: readonly ChatMessage[]): void {
    const before = new Map(this.held.messages.map((m) => [m.id, m]));
    this.held = fold(this.held, page).room;
    const after = new Map(this.held.messages.map((m) => [m.id, m]));
    for (const m of page) {
      const at = this.panel.items.findIndex((i) => i.id === m.id);
      const now = after.get(m.id);
      if (!now) {
        if (at >= 0) this.panel.items.splice(at, 1);
        continue;
      }
      if (at >= 0) {
        this.panel.items[at] = { ...this.panel.items[at], ...itemOf(now) };
      } else if (!before.has(m.id)) {
        // The server's copy of something this tab said and has not yet
        // heard back about: the same words under the same name, still
        // without an id. Give it the id rather than showing it twice.
        const twin = this.panel.items.find(
          (i) => i.id === undefined && !i.live && i.role === now.role && i.text === now.text,
        );
        if (twin) Object.assign(twin, itemOf(now));
        else this.panel.push(itemOf(now));
      }
    }
  }

  private async editMessage(id: number, text: string): Promise<void> {
    const clean = text.trim();
    if (!clean) return;
    try {
      const res = await this.app.client.request("playground.chat.edit", {
        message_id: id,
        text: clean,
      });
      this.apply([res.message]);
      this.host.chip.blip();
    } catch (e) {
      this.panel.status = t("agent.editFailed", { why: reason(e) });
      this.host.chip.fail();
    }
  }

  private async deleteMessage(id: number): Promise<void> {
    try {
      const res = await this.app.client.request("playground.chat.delete", { message_id: id });
      this.apply([res.message]);
      this.panel.status = t("agent.deleted");
      this.host.chip.blip();
    } catch (e) {
      this.panel.status = t("agent.deleteFailed", { why: reason(e) });
      this.host.chip.fail();
    }
  }

  /** Post one message for keeps. Quiet on failure: the tab has it. */
  private async post(
    role: ChatMessage["role"],
    text: string,
    extra: { image_b64?: string; image_type?: "image/png" | "image/jpeg" | "image/webp" } = {},
  ): Promise<ChatMessage | null> {
    const id = this.room;
    if (!id) return null;
    try {
      const provider = readProvider();
      const res = await this.app.client.request("playground.chat.post", {
        id,
        role,
        text,
        ...(role === "agent" ? { provider, model: readModel(provider) } : {}),
        ...extra,
      });
      if (this.room === id) this.held = fold(this.held, [res.message]).room;
      return res.message;
    } catch {
      return null;
    }
  }

  // -- the bench ---------------------------------------------------------------

  private bench(): Bench {
    const host = this.host;
    const app = this.app;
    // eslint-disable-next-line @typescript-eslint/no-this-alias
    const self = this;
    const typeIn = async (text: string) => {
      const ed = this.editor;
      if (!ed) return { typed: 0, total: text.length, stopped: true };
      this.sprite.typing(true);
      this.sprite.roll();
      this.host.fx()?.play(burstPlan(this.sprite.x, this.sprite.y, 40));
      const ok = await this.typist.run(text, { type: (ch) => ed.typeAt(ch) }, () => {
        host.touched();
        this.sprite.kick();
        // A key tick every few characters: heard as typing, not as a
        // machine gun. The editor's own sparks carry the rest.
        if (this.typist.typed % 4 === 1) host.chip.type();
      });
      this.sprite.typing(false);
      if (ok) {
        this.host.chip.coin();
        this.sprite.roll();
        this.rings.push({ x: this.sprite.x, y: this.sprite.y, at: this.t });
        // A shower of coins from the coder to the caret: the program landed.
        const c = this.sprite.caret ?? [this.sprite.x, this.sprite.y + 40];
        this.host.fx()?.play(coinPlan(this.sprite.x, this.sprite.y, c[0], c[1], 18).plan);
        this.host.fx()?.play(burstPlan(this.sprite.x, this.sprite.y, 60));
      }
      return { typed: this.typist.typed, total: text.length, stopped: !ok };
    };
    return {
      get lang() {
        return host.lang();
      },
      get file() {
        return MAIN_FILE[host.lang()];
      },
      read: () => this.editor?.source ?? "",
      write: async (source) => {
        this.editor?.clearAll();
        return typeIn(source);
      },
      insert: (text) => typeIn(text),
      edit: async (find, replace) => {
        const ed = this.editor;
        if (!ed) return { ok: false, why: "no editor" };
        const src = ed.source;
        const at = src.indexOf(find);
        if (at < 0)
          return {
            ok: false,
            why: "`find` is not in the file. Call read_code and copy the span exactly.",
          };
        if (src.indexOf(find, at + 1) >= 0)
          return { ok: false, why: "`find` occurs more than once; include more surrounding text." };
        ed.cut(at, at + find.length);
        host.touched();
        const r = await typeIn(replace);
        return r.stopped ? { ok: false, why: "stopped by the person" } : { ok: true };
      },
      run: host.run
        ? async (stdin) => {
            const r = await host.run!(this.editor?.source ?? "", stdin);
            return r;
          }
        : null,
      format: host.format,
      // Decided when asked, not when mounted: a fresh pad has no room until
      // its first save, and the room arrives while this bench is in use.
      get search() {
        if (!host.roomId()) return null;
        return async (q: string) => {
          const res = await app.client.request("playground.chat.search", { q, limit: 8 });
          if (res.hits.length === 0) return "No notes match.";
          return res.hits
            .map(
              (h) =>
                `[${h.snippet_name}] ${h.message.role} ${h.message.created_at.slice(0, 10)}: ${h.message.text.slice(0, 300)}`,
            )
            .join("\n");
        };
      },
      get image() {
        if (!host.roomId()) return null;
        return async (prompt: string) => {
          const provider = readProvider();
          if (!readKey(provider)) throw new Error("no api key");
          const ctl = new AbortController();
          const { b64, mime } = await makeImage(provider, readKey(provider), prompt, ctl.signal);
          const shrunk = await shrink(b64, mime);
          const msg = await self.post("agent", prompt, {
            image_b64: shrunk.b64,
            image_type: shrunk.mime,
          });
          const item: Item = msg
            ? itemOf(msg)
            : {
                role: "agent",
                text: prompt,
                photoUrl: `data:${shrunk.mime};base64,${shrunk.b64}`,
              };
          self.panel.push(item);
          host.chip.coin();
          return t("agent.photoPosted");
        };
      },
    };
  }

  private listener(): Listener {
    return {
      text: (delta) => {
        if (!this.live) {
          this.live = { role: "agent", text: "", live: true };
          this.panel.push(this.live);
        }
        this.live.text += delta;
        this.panel.scroll = 0;
        // Spoken as it arrives, not once it is finished: the wait for a
        // model is the weakest moment on the screen, and words landing one
        // by one are the sign of life. The bubble keeps the tail.
        this.say(this.live.text, "say", true);
      },
      tool: (name, input) => {
        const note = typeof input.note === "string" ? input.note : "";
        const label =
          name === "write_code"
            ? note || "writing it…"
            : name === "edit_code"
              ? note || "editing…"
              : name === "run_code"
                ? note || t("agent.running")
                : name === "read_code"
                  ? "reading…"
                  : name === "make_image"
                    ? "painting…"
                    : name === "search_notes"
                      ? "searching the notes…"
                      : name === "format_code"
                        ? "tidying…"
                        : name;
        this.say(label, "busy");
        // A tool between two pieces of prose ends the live item: the next
        // words are a new bubble in the room, after the tool's own line.
        this.live = null;
        this.panel.push({ role: "tool", text: label });
      },
      toolDone: (name, text, error) => {
        if (name === "run_code") {
          const first = text.split("\n")[0];
          this.panel.push({ role: "tool", text: first, error });
          this.say(first.replace(/^outcome: /, ""), error ? "busy" : "say");
        } else if (error) {
          this.panel.push({ role: "tool", text, error: true });
        }
      },
      mood: (m) => {
        this.mood = m;
        this.moodSince = this.t;
        this.sprite.thinking(m === "thinking" || m === "running");
        if (m === "idle" && this.live) {
          this.live.live = false;
          this.live = null;
        }
      },
    };
  }

  // -- asking ------------------------------------------------------------------

  private async ask(text: string, shown: string | null = text): Promise<void> {
    const session = this.session;
    if (!session || !this.editor) return;
    if (session.busy || this.typist.busy) {
      this.panel.status = t("agent.busy");
      this.host.chip.fail();
      return;
    }
    const provider = readProvider();
    if (!readKey(provider) && needsKey(provider)) {
      this.panel.status = t("agent.noKey", { provider: PROVIDER_NAME[provider] });
      this.panel.mode = "setup";
      this.panel.open = true;
      this.host.chip.fail();
      return;
    }
    this.panel.status = "";
    // The room first, so the message has somewhere to be kept.
    if (!this.room) {
      const made = await this.host.ensureRoom();
      this.syncRoom();
      if (made) this.panel.status = t("agent.roomMade", { name: this.host.roomName() });
    }
    if (shown) {
      const mine: Item = { role: "user", text: shown };
      this.panel.push(mine);
      void this.post("user", shown).then((m) => {
        if (m) Object.assign(mine, itemOf(m));
      });
    }
    this.sinceCall = 0;
    this.reviewedSource = this.editor.source;
    try {
      const reply = await session.ask(provider, text);
      if (reply.trim()) {
        this.say(reply, "say");
        const said = [...this.panel.items]
          .reverse()
          .find((i) => i.role === "agent" && i.id === undefined);
        void this.post("agent", reply).then((m) => {
          if (m && said && said.text === reply) Object.assign(said, itemOf(m));
        });
      }
    } catch (e) {
      const why = e instanceof Error ? e.message : String(e);
      if (!/abort/i.test(why)) {
        this.panel.status = t("agent.failed", { why: why.slice(0, 120) });
        this.panel.push({ role: "tool", text: why.slice(0, 200), error: true });
        this.host.chip.fail();
      }
    } finally {
      if (this.live) {
        this.live.live = false;
        this.live = null;
      }
    }
  }

  send(text: string): Promise<void> {
    const clean = text.trim();
    if (!clean) return Promise.resolve();
    return this.ask(clean);
  }

  write(brief: string): Promise<void> {
    const b = brief.trim();
    const ask = b ? t("agent.writeAsk", { brief: b }) : t("agent.writeAskBlank");
    return this.ask(ask, b ? `${t("agent.write")}: ${b}` : t("agent.write"));
  }

  review(): Promise<void> {
    return this.ask(t("agent.reviewAsk"), t("agent.review"));
  }

  picture(brief: string): Promise<void> {
    const provider = readProvider();
    const b = brief.trim();
    if (!this.host.roomId() || !this.bench().image) {
      this.panel.status = t("agent.noImage", { provider: PROVIDER_NAME[provider] });
      this.host.chip.fail();
      return Promise.resolve();
    }
    if (provider === "anthropic") {
      this.panel.status = t("agent.noImage", { provider: PROVIDER_NAME[provider] });
      this.host.chip.fail();
      return Promise.resolve();
    }
    return this.ask(
      t("agent.imageAsk", { brief: b || "this program, as a scene" }),
      `${t("agent.image")}: ${b}`,
    );
  }

  stop(): void {
    this.session?.stop();
    this.typist.stop();
    this.sprite.typing(false);
    this.sprite.thinking(false);
    if (this.live) {
      this.live.live = false;
      this.live = null;
    }
    this.say(t("agent.stopped"), "busy");
  }

  private async clearRoom(): Promise<void> {
    this.stop();
    this.session?.clear();
    this.panel.items = [];
    this.said.clear();
    const id = this.room;
    if (id) {
      try {
        await this.app.client.request("playground.chat.clear", { id });
      } catch {
        /* the tab is clear either way */
      }
    }
    this.panel.status = t("agent.cleared");
    this.host.chip.blip();
  }

  // -- idle life ---------------------------------------------------------------

  say(text: string, tone: "say" | "tip" | "busy", streaming = false): void {
    const clean = text.replace(/\s+/g, " ").trim();
    if (!clean) return;
    // A reply still arriving shows its newest words; the whole of it is in
    // the room, and a bubble that grows past four lines only hides code.
    const shown = streaming && clean.length > 160 ? `…${clean.slice(-158)}` : clean;
    if (tone !== "busy") this.lastSaid = { text: shown, tone };
    this.bubble = {
      text: shown,
      tone,
      until: this.t + BUBBLE_BASE + Math.min(9, shown.length * BUBBLE_PER_CHAR),
    };
  }

  update(dt: number): void {
    this.t += dt;
    this.sinceTip += dt;
    this.sinceCall += dt;
    // Only in agent mode. Put away, or the panel closed: no flying, no
    // tips, no advice, no effects. The AUTO review is silenced with it — a
    // character that is off should not spend. The sprite fades rather than
    // pops, and arrives with a zoom.
    const active = this.active;
    if (active && !this.wasActive) this.sprite.enter();
    this.wasActive = active;
    this.presence += ((active ? 1 : 0) - this.presence) * (1 - Math.exp(-(active ? 7 : 4) * dt));
    if (this.presence < 0.002) this.presence = 0;
    this.layer?.setAlpha(this.presence);
    if (!active) {
      this.bubble = null;
      if (this.sprite.holding) this.sprite.hold(false);
      return;
    }
    this.sprite.calm(this.t - this.pointerAt < 1.4);
    const src = this.editor?.source ?? "";
    if (src !== this.lastSource) {
      this.lastSource = src;
      this.sinceChange = 0;
      this.advised = false;
    } else this.sinceChange += dt;

    const busy = this.mood !== "idle" || this.typist.busy;
    // Held for a reader: no tips or advice over the words being read.
    if (!busy && !this.sprite.holding) {
      // Advice: read the text once it has sat still.
      if (!this.advised && this.sinceChange >= ADVISE_AFTER && src.trim()) {
        this.advised = true;
        const fresh = advise(this.host.lang(), src).filter((a) => !this.said.has(a.id));
        if (fresh.length) {
          this.said.add(fresh[0].id);
          this.sprite.peek();
          this.say(fresh[0].text, "tip");
          this.sinceTip = 0;
        }
      }
      // A tip, now and then, while the person is not mid-thought.
      if (this.sinceTip >= this.nextTipAt && this.sinceChange >= 6) {
        this.sinceTip = 0;
        this.nextTipAt = TIP_EVERY[0] + Math.random() * (TIP_EVERY[1] - TIP_EVERY[0]);
        const lang = this.host.lang();
        this.lastTip = nextTip(lang, this.lastTip);
        if (Math.random() < 0.5) this.sprite.peek();
        this.say(TIPS[lang][this.lastTip], "tip");
      }
      // AUTO: the one call nobody pressed for, throttled three ways.
      if (
        readAuto() &&
        readKey(readProvider()) &&
        this.sinceChange >= AUTO_IDLE &&
        this.sinceCall >= AUTO_EVERY &&
        Math.abs(src.length - this.reviewedSource.length) >= AUTO_DELTA &&
        src.trim()
      ) {
        void this.review();
      }
    }
    if (this.mood === "thinking") {
      this.bubble = {
        text: t("agent.thinking", { s: Math.floor(this.t - this.moodSince) }),
        tone: "busy",
        until: this.t + 1,
      };
    } else if (this.typist.busy) {
      this.bubble = {
        text: t("agent.typing", { typed: this.typist.typed, total: this.typist.total }),
        tone: "busy",
        until: this.t + 1,
      };
    }
    // A bubble stays as long as the sprite is held for it.
    if (this.bubble && this.t > this.bubble.until && !this.sprite.holding) this.bubble = null;

    // The caret, for peek and typing.
    const c = this.editor?.caretClient();
    const v = c ? this.app.layout.toVirtual(c[0], c[1]) : null;
    if (v) this.sprite.caret = v;
    const cell = this.editor?.cellClient();
    if (cell) this.cellV = Math.max(4, cell[0] / (this.app.layout.cssScale || 1));
    this.sprite.size = this.spriteSize();
    this.sprite.update(dt, this.box, this.cellV);
    this.breathe(dt);
  }

  /**
   * The exhaust: embers from the engines into the particle layer, paced by
   * time, thrown downward in the ship's own frame and back the way it came,
   * more of them the harder it burns. Off under reduced motion, like the
   * smear it borrows.
   */
  private breathe(dt: number): void {
    const fx = this.host.fx();
    if (!fx || reducedMotion() || !this.active) return;
    const sp = this.sprite;
    // Takeoff and landing: a puff of sparks at each end of a flight.
    if (sp.tookOff) fx.play(burstPlan(sp.x, sp.y, 22));
    if (sp.landed) fx.play(burstPlan(sp.x, sp.y, 30));
    // The light along the way: embers left every few pixels of a flight,
    // paced by distance the way the pointer's own trail is, thrown back
    // along the direction of travel so they read as a wake.
    if (sp.flying) {
      const here: Pt = [sp.x, sp.y];
      if (this.wakeLast) {
        const dx = here[0] - this.wakeLast[0];
        const dy = here[1] - this.wakeLast[1];
        const dist = Math.hypot(dx, dy);
        this.wakeCarry += dist;
        const n = Math.min(8, Math.floor(this.wakeCarry / 6));
        if (n > 0) {
          this.wakeCarry -= n * 6;
          const vx = (dx / Math.max(dt, 1 / 240)) * -0.35;
          const vy = (dy / Math.max(dt, 1 / 240)) * -0.35;
          for (let i = 1; i <= n; i++) {
            const u = i / n;
            fx.play(pointerPlan(this.wakeLast[0] + dx * u, this.wakeLast[1] + dy * u, vx, vy));
          }
        }
      }
      this.wakeLast = here;
    } else {
      this.wakeLast = null;
      this.wakeCarry = 0;
    }
    const burn = sp.thrust();
    const every = 0.09 / burn;
    this.exhaust += dt;
    while (this.exhaust >= every) {
      this.exhaust -= every;
      const size = this.sprite.size * this.sprite.scale;
      const a = this.sprite.angle;
      const nozzles: Array<[number, number]> = [
        [-0.28, 0.42],
        [0, 0.42],
        [0.28, 0.42],
      ];
      for (const [nx, ny] of nozzles) {
        const lx = nx * size;
        const ly = ny * size;
        const x = this.sprite.x + lx * Math.cos(a) - ly * Math.sin(a);
        const y = this.sprite.y + this.sprite.bob() + lx * Math.sin(a) + ly * Math.cos(a);
        const vy = 140 * burn;
        fx.play(pointerPlan(x, y, -Math.sin(a) * vy - this.sprite.speed() * 0.3, Math.cos(a) * vy));
      }
    }
  }

  private spriteSize(): number {
    const s = Math.min(this.box[2], this.box[3]) * SIZE_SHARE;
    return (
      Math.max(SIZE_MIN, Math.min(SIZE_MAX, s)) * Math.max(1, this.app.layout.uiScale() * 0.75)
    );
  }

  // -- drawing -----------------------------------------------------------------

  /**
   * Where the sprite flies this frame. The whole screen: it is a character
   * of the room, not a widget of the editor, and a coder who only ever
   * hovers over the code is a cursor with a face. The caret still pulls it
   * in when there is work to watch.
   */
  fly(box: Rect): void {
    const p = this.panelRect;
    if (!p || !this.panel.open) {
      this.box = box;
      return;
    }
    // Out of the panel's way: the screen minus the column or band it
    // takes, so idle roaming never drifts over the room's text. The caret
    // still pulls the sprite wherever the code is.
    const [x, y, w, h] = box;
    if (p[2] >= w * 0.9) this.box = [x, y, w, Math.max(120, p[1] - y)];
    else if (p[0] > x + w / 2) this.box = [x, y, Math.max(160, p[0] - x), h];
    else if (p[0] + p[2] < x + w / 2)
      this.box = [p[0] + p[2], y, Math.max(160, x + w - p[0] - p[2]), h];
    else this.box = [x, y, w, Math.max(120, p[1] - y)];
  }

  /** Where the panel was drawn this frame, for `fly` to keep clear of. */
  private panelRect: Rect | null = null;

  /** Paint the sprite and its bubble on the agent's own layer. Every frame. */
  draw(): void {
    const g = this.layer?.begin();
    if (!g) return;
    if (this.presence <= 0) return;
    const s = this.app.layout.uiScale();
    const size = this.sprite.size;
    const x = this.sprite.x;
    const y = this.sprite.y + this.sprite.bob();
    const assets = this.app.assets;
    const ship = assets?.picture("agent_coder");
    const provider = readProvider();
    const bot = assets?.picture(PROVIDER_BOT[provider]);
    const zoom = this.sprite.scale;
    const [sqx, sqy] = this.sprite.squash();

    // The shockwaves: a ring per landed program, growing and fading over a
    // second, drawn under everything.
    this.rings = this.rings.filter((r) => this.t - r.at < 1);
    for (const r of this.rings) {
      const k = (this.t - r.at) / 1;
      const radius = size * (0.4 + 2.2 * (1 - Math.exp(-4 * k)));
      g.save();
      g.globalAlpha = (1 - k) * 0.8;
      g.strokeStyle = css(Theme.coin);
      g.lineWidth = Math.max(2, size * 0.06 * (1 - k));
      g.beginPath();
      g.arc(r.x, r.y, radius, 0, Math.PI * 2);
      g.stroke();
      g.restore();
    }

    this.drawRibbon(g, size, x);

    // The afterimages: where it has just been, fading back along the trail.
    if (ship) {
      const trail = this.sprite.trail;
      for (let i = 0; i < trail.length; i++) {
        const k = (i + 1) / (trail.length + 1);
        g.save();
        g.globalAlpha = 0.28 * k;
        g.translate(trail[i][0], trail[i][1]);
        g.rotate(this.sprite.angle * k);
        g.scale(this.sprite.facing * zoom * k, zoom * k);
        g.drawImage(ship, -size / 2, -size / 2, size, size);
        g.restore();
      }
    }

    // The engine, under the ship: three flames, the middle one longest,
    // flickering with the clock. Drawn first so the ship sits on them, and
    // in the ship's own frame so they tilt and zoom with it.
    {
      g.save();
      g.translate(x, y);
      g.rotate(this.sprite.angle);
      g.scale(zoom * sqx, zoom * sqy);
      g.translate(-x, -y);
      const burn = this.sprite.thrust();
      const flick = 0.75 + 0.25 * Math.sin(this.t * 37) * Math.cos(this.t * 23);
      const fw = Math.max(2, Math.round(size * 0.06));
      for (const [ox, k] of [
        [-0.28, 0.6],
        [0, 1],
        [0.28, 0.6],
      ] as const) {
        const fh = size * 0.22 * burn * k * flick;
        const fx = x + ox * size - fw / 2;
        const fy = y + size * 0.42;
        fill(g, Theme.cyan, fx, fy, fw, fh, 0.85);
        fill(g, Theme.cream, fx + fw * 0.25, fy, fw * 0.5, fh * 0.55, 0.9);
      }
      g.restore();
    }

    g.save();
    g.translate(x, y);
    g.rotate(this.sprite.angle);
    g.scale(this.sprite.facing * zoom * sqx, zoom * sqy);
    if (ship) g.drawImage(ship, -size / 2, -size / 2, size, size);
    else {
      fill(g, Theme.coin, -size / 2, -size / 2, size, size, 0.9);
    }
    g.restore();

    // The companion: half a ship, trailing behind, on a slower bob.
    if (bot) {
      const bs = size * 0.5;
      const bx = x - this.sprite.facing * size * 0.72;
      const by = y - size * 0.12 + Math.sin(this.t * 2.3) * 2.5;
      g.drawImage(bot, bx - bs / 2, by - bs / 2, bs, bs);
    }

    if (this.bubble) this.drawBubble(g, s, [x, y], size);
  }

  /**
   * The light ribbon: where it has flown in the last second, as one stroke
   * in three layers — a wide additive glow, a cyan body, a white core —
   * shifting from pink at the tail to cyan at the head, tapering and fading
   * with age, with sparks winking along it. Wide at the ship, gone at the
   * tail.
   */
  private drawRibbon(g: Ctx, size: number, headX: number): void {
    const wake = this.sprite.wake;
    if (wake.length < 2) return;
    const head = { x: headX, y: this.sprite.y, age: 0 };
    const pts = [...wake, head];
    const n = pts.length - 1;
    g.save();
    g.lineCap = "round";
    g.lineJoin = "round";
    const pass = (width: number, alpha: number, tone: (k: number) => string, add: boolean) => {
      g.globalCompositeOperation = add ? "lighter" : "source-over";
      for (let i = 1; i <= n; i++) {
        const p = pts[i];
        const k = i / n;
        const life = 1 - Math.min(1, p.age / 1.1);
        const a = alpha * k * life;
        if (a <= 0.01) continue;
        g.globalAlpha = a;
        g.strokeStyle = tone(k);
        g.lineWidth = Math.max(1, width * (0.25 + 0.75 * k) * life);
        g.beginPath();
        g.moveTo(pts[i - 1].x, pts[i - 1].y);
        g.lineTo(p.x, p.y);
        g.stroke();
      }
    };
    const blend = (k: number): string => css(mix(Theme.pink, Theme.cyan, k));
    pass(size * 1.1, 0.16, blend, true);
    pass(size * 0.42, 0.55, blend, false);
    pass(size * 0.12, 0.9, () => css(Theme.cream), false);
    // Sparks: a diamond every few points, each winking on its own clock.
    g.globalCompositeOperation = "lighter";
    for (let i = 2; i < n; i += 3) {
      const p = pts[i];
      const k = i / n;
      const life = 1 - Math.min(1, p.age / 1.1);
      const wink = 0.5 + 0.5 * Math.sin(this.t * 14 + i * 1.7);
      const r = Math.max(1.5, size * 0.11 * k * life) * (0.6 + 0.4 * wink);
      g.globalAlpha = 0.9 * life * wink;
      g.fillStyle = i % 2 ? css(Theme.cream) : blend(k);
      g.beginPath();
      g.moveTo(p.x, p.y - r);
      g.lineTo(p.x + r, p.y);
      g.lineTo(p.x, p.y + r);
      g.lineTo(p.x - r, p.y);
      g.closePath();
      g.fill();
    }
    g.restore();
  }

  private drawBubble(g: Ctx, s: number, at: Pt, size: number): void {
    const b = this.bubble!;
    const fonts = ensureFonts(s);
    const f = b.tone === "tip" ? fonts.small : fonts.stationSm;
    const pad = Math.round(6 * s);
    const maxW = Math.min(
      Math.round(300 * s),
      Math.max(Math.round(120 * s), this.box[2] - pad * 2),
    );
    let lines = wrap(f, b.text, maxW - pad * 2);
    if (lines.length > 4) {
      lines = lines.slice(0, 4);
      lines[3] = lines[3].replace(/.{2}$/, "…");
    }
    const tw = Math.max(...lines.map((l) => width(f, l)), f.size * 3);
    const w = tw + pad * 2;
    const h = lines.length * f.height + pad * 2;
    // Above the sprite when there is room, else below; kept inside the box.
    // And off the line the caret is on: a bubble over the line being read
    // or written is the one place it must not be, so of the two places it
    // could go, the one that clears the caret's row wins.
    const aboveY = at[1] - size * 0.6 - h - 4;
    const belowY = at[1] + size * 0.6 + 4;
    const caret = this.sprite.caret;
    const row = this.cellV * 1.6;
    const clears = (top: number) => !caret || top + h < caret[1] - row || top > caret[1] + row;
    const fitsAbove = aboveY >= this.box[1];
    const fitsBelow = belowY + h <= this.box[1] + this.box[3];
    let above = fitsAbove;
    if (fitsAbove && fitsBelow) {
      if (!clears(aboveY) && clears(belowY)) above = false;
    } else if (!fitsAbove && fitsBelow) above = false;
    const y = above ? aboveY : belowY;
    let x = at[0] - w / 2;
    x = Math.min(this.box[0] + this.box[2] - w - 2, Math.max(this.box[0] + 2, x));
    const face = b.tone === "tip" ? Theme.panel : b.tone === "busy" ? Theme.navy : Theme.cream;
    const ink = b.tone === "busy" ? Theme.cream : Theme.ink;
    fill(g, Theme.ink, x - 2, y - 2, w + 4, h + 4);
    fill(g, face, x, y, w, h);
    // The nub, towards the sprite.
    const nx = Math.min(x + w - 8, Math.max(x + 4, at[0] - 3));
    if (above) {
      fill(g, Theme.ink, nx - 2, y + h, 10, 2);
      fill(g, face, nx, y + h, 6, 2);
      fill(g, Theme.ink, nx, y + h + 2, 6, 2);
    } else {
      fill(g, Theme.ink, nx - 2, y - 4, 10, 2);
      fill(g, face, nx, y - 2, 6, 2);
    }
    g.fillStyle = css(ink);
    let ly = y + pad;
    for (const line of lines) {
      printf(g, f, line, x + pad, ly, tw, "left");
      ly += f.height;
    }
  }

  // -- the panel, delegated ------------------------------------------------------

  /** Carve the panel's share out of `rect`; the rest is the editor's. */
  split(rect: Rect, portrait: boolean, s: number): { editor: Rect; panel: Rect | null } {
    if (!this.panel.open) return { editor: rect, panel: null };
    const gap = Math.round(6 * s);
    if (portrait) {
      const ph = Math.round(rect[3] * 0.46);
      return {
        editor: [rect[0], rect[1], rect[2], rect[3] - ph - gap],
        panel: [rect[0], rect[1] + rect[3] - ph, rect[2], ph],
      };
    }
    const pw = Math.max(Math.round(260 * s), Math.round(rect[2] * 0.38));
    return {
      editor: [rect[0], rect[1], rect[2] - pw - gap, rect[3]],
      panel: [rect[0] + rect[2] - pw, rect[1], pw, rect[3]],
    };
  }

  drawPanel(g: Ctx, rect: Rect, s: number): void {
    this.panelRect = rect;
    this.panel.draw(g, rect, s, {
      provider: readProvider(),
      busy: this.mood !== "idle" || this.typist.busy,
      canImage: this.host.roomId() !== null,
    });
  }

  controls(): Buttons {
    return this.panel.buttons;
  }

  /** For the capture hook: where the sprite is and what it is doing. */
  probe(): AgentProbe {
    return {
      x: this.sprite.x,
      y: this.sprite.y + this.sprite.bob(),
      state: this.sprite.state,
      holding: this.sprite.holding,
      bubble: this.bubble?.text ?? null,
    };
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): boolean {
    return this.panel.pointer(x, y, phase);
  }

  wheel(dy: number, x: number, y: number): boolean {
    return this.panel.wheel(dy, x, y);
  }

  key(name: string, ev: KeyboardEvent): boolean {
    return this.panel.key(name, ev);
  }
}

/** A colour between two, by k. */
function mix(a: RGBA, b: RGBA, k: number): RGBA {
  return [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, 1];
}

function itemOf(m: ChatMessage): Item {
  return {
    id: m.id,
    role: m.role,
    text: m.text,
    photoUrl: m.photo_url,
    at: m.created_at,
    edited: m.edited,
  };
}

/** A failure's one line for the status row. */
function reason(e: unknown): string {
  if (e instanceof WireError) return e.payload.message?.slice(0, 80) ?? e.payload.code;
  return (e instanceof Error ? e.message : String(e)).slice(0, 80);
}

/**
 * A picture the room can take: under the frame cap, or re-encoded smaller.
 * A 1024² PNG from a provider is usually fine; a 4 MB one is not, and a JPEG
 * at 768 is the same picture to a chatroom.
 */
async function shrink(
  b64: string,
  mime: string,
): Promise<{ b64: string; mime: "image/png" | "image/jpeg" | "image/webp" }> {
  const known = (m: string): m is "image/png" | "image/jpeg" | "image/webp" =>
    m === "image/png" || m === "image/jpeg" || m === "image/webp";
  if (b64.length <= PHOTO_B64_MAX && known(mime)) return { b64, mime };
  const img = new Image();
  img.src = `data:${mime};base64,${b64}`;
  await img.decode();
  const k = Math.min(1, 768 / Math.max(img.naturalWidth, img.naturalHeight));
  const c = document.createElement("canvas");
  c.width = Math.max(1, Math.round(img.naturalWidth * k));
  c.height = Math.max(1, Math.round(img.naturalHeight * k));
  c.getContext("2d")?.drawImage(img, 0, 0, c.width, c.height);
  const url = c.toDataURL("image/jpeg", 0.88);
  return { b64: url.slice(url.indexOf(",") + 1), mime: "image/jpeg" };
}
