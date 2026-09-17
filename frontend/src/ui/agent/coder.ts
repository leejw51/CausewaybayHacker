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
import { css, Theme } from "../../engine/theme";
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
  readModel,
  readProvider,
} from "../../ai/prefs";
import { Session, type Listener, type Mood } from "../../ai/session";
import { Typist } from "../../ai/typist";
import { advise, nextTip, TIPS } from "../../ai/tips";
import type { Bench, RunReport } from "../../ai/tools";
import { image as makeImage } from "../../ai/providers";
import { Sprite, type Pt } from "./sprite";
import { AgentLayer } from "./layer";
import { Panel, type Item } from "./panel";

/** What the screen lends the agent. */
export interface Host {
  lang(): Land;
  /** The pad the room belongs to; null on a screen with no room (a quest). */
  roomId(): string | null;
  /** RUN as the button does, or null where a run would count against the player. */
  run: ((source: string, stdin?: string) => Promise<RunReport>) | null;
  format: (() => Promise<{ changed: boolean; problem?: string }>) | null;
  /** The editor's text changed under the agent's hands: autosave, mirror. */
  touched(): void;
  /** A small sound. */
  chip: { blip(): void; fail(): void; coin(): void; select(): void };
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
  /** The bubble: what, and until when. */
  private bubble: { text: string; until: number; tone: "say" | "tip" | "busy" } | null = null;
  private room: string | null = null;
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
    if (this.panel.open) this.syncRoom();
    this.host.chip.select();
  }

  /** The pad changed, or a new one was opened: a different room. */
  syncRoom(): void {
    const id = this.host.roomId();
    if (id === this.room) return;
    this.room = id;
    this.session?.clear();
    this.panel.items = [];
    this.said.clear();
    this.reviewedSource = "";
    if (id) void this.loadRoom(id);
  }

  private async loadRoom(id: string): Promise<void> {
    try {
      const res = await this.app.client.request("playground.chat.list", { id, limit: 200 });
      if (this.room !== id) return;
      this.panel.items = res.messages.map((m) => itemOf(m));
      this.panel.scroll = 0;
    } catch (e) {
      if (e instanceof WireError && e.payload.code === "not_found") {
        // A server without the room, or a pad it has not seen: the visit's
        // messages stay in the tab, and the panel says so once.
        this.panel.status = t("agent.roomFailed");
      }
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
      return res.message;
    } catch {
      return null;
    }
  }

  // -- the bench ---------------------------------------------------------------

  private bench(): Bench {
    const host = this.host;
    const typeIn = async (text: string) => {
      const ed = this.editor;
      if (!ed) return { typed: 0, total: text.length, stopped: true };
      this.sprite.typing(true);
      const ok = await this.typist.run(text, { type: (ch) => ed.typeAt(ch) }, () => host.touched());
      this.sprite.typing(false);
      if (ok) this.host.chip.coin();
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
      search: this.host.roomId()
        ? async (q) => {
            const res = await this.app.client.request("playground.chat.search", { q, limit: 8 });
            if (res.hits.length === 0) return "No notes match.";
            return res.hits
              .map(
                (h) =>
                  `[${h.snippet_name}] ${h.message.role} ${h.message.created_at.slice(0, 10)}: ${h.message.text.slice(0, 300)}`,
              )
              .join("\n");
          }
        : null,
      image: this.host.roomId()
        ? async (prompt) => {
            const provider = readProvider();
            if (!readKey(provider)) throw new Error("no api key");
            const ctl = new AbortController();
            const { b64, mime } = await makeImage(provider, readKey(provider), prompt, ctl.signal);
            const shrunk = await shrink(b64, mime);
            const msg = await this.post("agent", prompt, {
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
            this.panel.push(item);
            this.host.chip.coin();
            return t("agent.photoPosted");
          }
        : null,
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
    if (!readKey(provider)) {
      this.panel.status = t("agent.noKey", { provider: PROVIDER_NAME[provider] });
      this.panel.mode = "setup";
      this.panel.open = true;
      this.host.chip.fail();
      return;
    }
    this.panel.status = "";
    if (shown) {
      this.panel.push({ role: "user", text: shown });
      void this.post("user", shown);
    }
    this.sinceCall = 0;
    this.reviewedSource = this.editor.source;
    try {
      const reply = await session.ask(provider, text);
      if (reply.trim()) {
        this.say(reply, "say");
        void this.post("agent", reply);
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

  say(text: string, tone: "say" | "tip" | "busy"): void {
    const clean = text.replace(/\s+/g, " ").trim();
    if (!clean) return;
    this.bubble = {
      text: clean,
      tone,
      until: this.t + BUBBLE_BASE + Math.min(9, clean.length * BUBBLE_PER_CHAR),
    };
  }

  update(dt: number): void {
    this.t += dt;
    this.sinceTip += dt;
    this.sinceCall += dt;
    const src = this.editor?.source ?? "";
    if (src !== this.lastSource) {
      this.lastSource = src;
      this.sinceChange = 0;
      this.advised = false;
    } else this.sinceChange += dt;

    const busy = this.mood !== "idle" || this.typist.busy;
    if (!busy) {
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
    if (this.bubble && this.t > this.bubble.until) this.bubble = null;

    // The caret, for peek and typing.
    const c = this.editor?.caretClient();
    const v = c ? this.app.layout.toVirtual(c[0], c[1]) : null;
    if (v) this.sprite.caret = v;
    const cell = this.editor?.cellClient();
    if (cell) this.cellV = Math.max(4, cell[0] / (this.app.layout.cssScale || 1));
    this.sprite.size = this.spriteSize();
    this.sprite.update(dt, this.box, this.cellV);
  }

  private spriteSize(): number {
    const s = Math.min(this.box[2], this.box[3]) * SIZE_SHARE;
    return (
      Math.max(SIZE_MIN, Math.min(SIZE_MAX, s)) * Math.max(1, this.app.layout.uiScale() * 0.75)
    );
  }

  // -- drawing -----------------------------------------------------------------

  /** Where the sprite flies this frame: the editor's rectangle. */
  fly(box: Rect): void {
    this.box = box;
  }

  /** Paint the sprite and its bubble on the agent's own layer. Every frame. */
  draw(): void {
    const g = this.layer?.begin();
    if (!g) return;
    const s = this.app.layout.uiScale();
    const size = this.sprite.size;
    const x = this.sprite.x;
    const y = this.sprite.y + this.sprite.bob();
    const assets = this.app.assets;
    const ship = assets?.picture("agent_coder");
    const provider = readProvider();
    const bot = assets?.picture(PROVIDER_BOT[provider]);

    // The engine, under the ship: three flames, the middle one longest,
    // flickering with the clock. Drawn first so the ship sits on them.
    {
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
    }

    g.save();
    g.translate(x, y);
    if (this.sprite.facing < 0) g.scale(-1, 1);
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
    const above = at[1] - size * 0.6 - h - 4 >= this.box[1];
    const y = above ? at[1] - size * 0.6 - h - 4 : at[1] + size * 0.6 + 4;
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
    this.panel.draw(g, rect, s, {
      provider: readProvider(),
      busy: this.mood !== "idle" || this.typist.busy,
      canImage: this.host.roomId() !== null,
    });
  }

  controls(): Buttons {
    return this.panel.buttons;
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

function itemOf(m: ChatMessage): Item {
  return {
    role: m.role,
    text: m.text,
    photoUrl: m.photo_url,
    at: m.created_at,
  };
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
